;;;; src/promise.lisp
;;;;
;;;; PROMISE is a write-once cell settled from one thread and read from
;;;; others: DELIVER/DELIVER-ERROR settle it (successfully or not), AWAIT
;;;; blocks until it is settled. FUTURE spawns a thread that settles a fresh
;;;; promise with the value (or condition) its body produces -- the
;;;; JS/Rust-style async handle built directly on the PRIMITIVES layer.
(in-package #:cl-concurrent-kit)

(defstruct (promise (:constructor %make-promise ()))
  (lock (make-lock :name "cl-concurrent-kit promise") :read-only t)
  (condition-variable (make-condition-variable :name "cl-concurrent-kit promise") :read-only t)
  ;; :PENDING -> :FULFILLED (via DELIVER) or :FAILED (via DELIVER-ERROR).
  ;; Never transitions once settled; see PROMISE-ALREADY-FULFILLED.
  (state :pending)
  (value nil)
  (failure nil))

(defun make-promise ()
  "Create a PROMISE with no value yet. Settle it with DELIVER or
DELIVER-ERROR; read it with AWAIT."
  (%make-promise))

(defun promise-settled-p (promise)
  "True once PROMISE has been settled by DELIVER or DELIVER-ERROR."
  (with-lock-held ((promise-lock promise))
    (not (eq (promise-state promise) :pending))))

(defun %settle (promise state value)
  (with-lock-held ((promise-lock promise))
    (unless (eq (promise-state promise) :pending)
      (error 'promise-already-fulfilled :promise promise))
    (setf (promise-state promise) state)
    (ecase state
      (:fulfilled (setf (promise-value promise) value))
      (:failed (setf (promise-failure promise) value)))
    (condition-broadcast (promise-condition-variable promise)))
  promise)

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
  (with-lock-held ((promise-lock promise))
    (let ((result (%wait-until (promise-condition-variable promise)
                                (promise-lock promise)
                                (lambda () (not (eq (promise-state promise) :pending)))
                                (%deadline-from-timeout timeout))))
      (when (eq result :timeout)
        (error 'operation-timed-out :operation :await :timeout timeout))
      (ecase (promise-state promise)
        (:fulfilled (promise-value promise))
        (:failed (error (promise-failure promise)))))))

(defmacro future (&body body)
  "Run BODY on a new thread and return a PROMISE for its outcome immediately.
AWAIT on the result blocks until BODY finishes and returns its value, or
re-signals whatever condition BODY let escape."
  `(%future (lambda () ,@body)))

(defun %future (thunk)
  (let ((promise (make-promise)))
    (make-thread (lambda ()
                   (handler-case (deliver promise (funcall thunk))
                     (error (c) (deliver-error promise c))))
                 :name "cl-concurrent-kit future")
    promise))
