;;;; src/promise.lisp
;;;;
;;;; PROMISE is a write-once cell settled from one thread and read from
;;;; others: DELIVER/DELIVER-ERROR settle it (successfully or not), AWAIT
;;;; blocks until it is settled. FUTURE spawns a thread that settles a fresh
;;;; promise with the value (or condition) its body produces -- the
;;;; JS/Rust-style async handle built directly on the PRIMITIVES layer.
(progn
  (declaim (optimize
      (speed 3)
      (safety 1)
      (debug 0)
      (compilation-speed 0)
      #+sb-cover (sb-c:store-coverage-data 3)))
  (in-package #:cl-concurrent-kit))

(defstruct (promise (:constructor %make-promise ())) (lock (make-lock :name "cl-concurrent-kit promise") :read-only t)
  (condition-variable
    (make-condition-variable :name "cl-concurrent-kit promise")
    :read-only
    t)
  (state :pending)
  (value nil)
  (failure nil)
  (observers nil)
  (observer-tail nil))

(defstruct (promise-settlement
    (:constructor %make-promise-settlement (state value condition))) "The outcome of one input to PROMISE-ALL-SETTLED.

STATE is either :FULFILLED or :FAILED.  VALUE is meaningful for fulfilled
settlements, and CONDITION is meaningful for failed settlements."
  (state :fulfilled :read-only t)
  (value nil :read-only t)
  (condition nil :read-only t))

(defun make-promise ()
  "Create a PROMISE with no value yet. Settle it with DELIVER or
DELIVER-ERROR; read it with AWAIT."
  (%make-promise))

(defun promise-settled-p (promise)
  "True once PROMISE has been settled by DELIVER or DELIVER-ERROR."
  (with-lock-held
    ((promise-lock promise))
    (not (eq (promise-state promise) :pending))))

(defun %settle (promise state value)
  (let (observers
        first-error)
    (with-lock-held
      ((promise-lock promise))
      (unless (eq (promise-state promise) :pending)
        (error (quote promise-already-fulfilled) :promise promise))
      (setf (promise-state promise) state
            observers (promise-observers promise)
            (promise-observers promise) nil
            (promise-observer-tail promise) nil)
      (ecase state
        (:fulfilled
          (setf (promise-value promise) value))
        (:failed
          (setf (promise-failure promise) value)))
      (condition-broadcast (promise-condition-variable promise)))
    (dolist (observer observers)
      (handler-case (funcall observer state value)
        (error (condition)
          (unless first-error
            (setf first-error condition)))))
    (when first-error
      (error first-error)))
  promise)

(defun %observe-promise (promise observer)
  "Call OBSERVER with the settled PROMISE state and outcome."
  (let (state
        outcome)
    (with-lock-held
      ((promise-lock promise))
      (if (eq (promise-state promise) :pending) (let ((entry (list observer)))
          (if (promise-observer-tail promise) (setf (cdr (promise-observer-tail promise)) entry)
            (setf (promise-observers promise) entry))
          (setf (promise-observer-tail promise) entry))
        (setf state (promise-state promise)
              outcome (ecase state
            (:fulfilled (promise-value promise))
            (:failed (promise-failure promise))))))
    (when state
      (funcall observer state outcome))))

(defun deliver (promise value)
  "Settle PROMISE successfully with VALUE. Signals PROMISE-ALREADY-FULFILLED
if PROMISE was already settled."
  (%settle promise :fulfilled value))

(defun deliver-error (promise condition)
  "Settle PROMISE as failed with CONDITION: AWAIT re-signals CONDITION instead
of returning a value. Signals PROMISE-ALREADY-FULFILLED if PROMISE was already
settled."
  (%settle promise :failed condition))

(defun await (promise &key timeout)
  "Block until PROMISE is settled, then return the value DELIVER was called
with, or re-signal the condition DELIVER-ERROR was called with. With TIMEOUT
(seconds), signals OPERATION-TIMED-OUT if PROMISE is not settled in time."
  (with-lock-held
    ((promise-lock promise))
    (let ((result
          (%wait-until
            ((promise-condition-variable promise)
              (promise-lock promise)
              (%deadline-from-timeout timeout))
            (not (eq (promise-state promise) :pending)))))
      (when (eq result :timeout)
        (error 'operation-timed-out :operation :await :timeout timeout))
      (ecase (promise-state promise)
        (:fulfilled (promise-value promise))
        (:failed (error (promise-failure promise)))))))

(defun promise-all-settled (promises)
  "Return a PROMISE fulfilled after every PROMISE in PROMISES settles.

Its value is a list of PROMISE-SETTLEMENT records in the same order as
PROMISES. Failed inputs produce :FAILED records instead of failing the
aggregate promise."
  (let* ((promises (coerce promises 'list))
         (count (length promises))
         (aggregate (make-promise)))
    (dolist (promise promises)
      (check-type promise promise))
    (if (zerop count) (deliver aggregate nil)
      (let ((lock (make-lock :name "cl-concurrent-kit promise all settled"))
            (remaining count)
            (settlements (make-array count)))
        (loop for promise in promises
              for index from 0
              do (let ((index index))
            (%observe-promise
              promise
              (lambda (state outcome)
                (let (complete)
                  (with-lock-held
                    (lock)
                    (setf (aref settlements index) (ecase state
                        (:fulfilled (%make-promise-settlement :fulfilled outcome nil))
                        (:failed (%make-promise-settlement :failed nil outcome))))
                    (setf complete (zerop (decf remaining))))
                  (when complete
                    (deliver aggregate (coerce settlements 'list))))))))))
    aggregate))

(defmacro future (&body body)
  "Run BODY on a new thread and return a PROMISE for its outcome immediately.
AWAIT on the result blocks until BODY finishes and returns its value, or
re-signals whatever condition BODY let escape."
  (let ((promise (gensym "PROMISE-")))
    `(let ((,promise (make-promise)))
       (make-thread
        (lambda ()
          (multiple-value-bind (state outcome)
              (handler-case
                  (values :fulfilled (locally ,@body))
                (error (condition)
                  (values :failed condition)))
            (ecase state
              (:fulfilled (deliver ,promise outcome))
              (:failed (deliver-error ,promise outcome)))))
       :name "cl-concurrent-kit future")
       ,promise)))
