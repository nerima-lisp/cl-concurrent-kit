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
  (condition-variable (make-condition-variable :name "cl-concurrent-kit promise")
                       :read-only t)
  (state :pending)
  (value nil)
  (failure nil)
  ;; Observers are called after settlement has released LOCK. OBSERVER-TAIL
  ;; lets %OBSERVE-PROMISE append in O(1) instead of PUSHing and paying for
  ;; an NREVERSE in %SETTLE once observers can number in the hundreds (e.g.
  ;; PROMISE-ALL-SETTLED/PROMISE-RACE over a large input).
  (observers nil)
  (observer-tail nil))

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
  "Settle PROMISE, then notify every registered observer with STATE and
VALUE. An observer that signals does not stop the rest from being notified --
its condition is remembered and re-signaled only after every observer has had
a chance to run, so one broken PROMISE-THEN/PROMISE-ALL-SETTLED continuation
cannot silently suppress delivery to unrelated ones."
  (let (observers
        first-error)
    (with-lock-held
      ((promise-lock promise))
      (unless (eq (promise-state promise) :pending)
        (error 'promise-already-fulfilled :promise promise))
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
  "Call OBSERVER with PROMISE's state and outcome after it settles -- with
PROMISE's own OBSERVER-TAIL, in O(1) whether OBSERVER is registered before or
after settlement.

This private helper ensures observers registered concurrently with settlement
are either retained for notification or called after the settled state is
read. Shared by AWAIT's callers indirectly (via DELIVER/DELIVER-ERROR) and
directly by src/promise-combinators.lisp's PROMISE-THEN, PROMISE-RACE, and
PROMISE-ALL-SETTLED, none of which spawn a thread or poll."
  (let (state
        outcome)
    (with-lock-held
      ((promise-lock promise))
      (if (eq (promise-state promise) :pending)
          (let ((entry (list observer)))
            (if (promise-observer-tail promise)
                (setf (cdr (promise-observer-tail promise)) entry)
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

(defmacro future (&body body)
  "Run BODY on a new thread and return a PROMISE for its outcome immediately.
AWAIT on the result blocks until BODY finishes and returns its value, or
re-signals whatever condition BODY let escape."
  `(%future
    (lambda ()
      ,@body)))

(defun %deliver-on-thread (promise thunk &key name)
  "Run THUNK on a new thread named NAME, settling PROMISE with its return
value via DELIVER, or with the condition it signals via DELIVER-ERROR.
Returns PROMISE immediately, without waiting for THUNK to run.

Shared by %FUTURE (a fresh PROMISE) and SRC/SCOPE-EXECUTION.LISP's
%SPAWN-THREAD-CHILD (a PROMISE SPAWN already created), the two places this
package hands a thunk to a dedicated thread rather than an EXECUTOR."
  (make-thread
   (lambda ()
     (handler-case (deliver promise (funcall thunk))
       (error (condition) (deliver-error promise condition))))
   :name name)
  promise)

(defun %future (thunk)
  (%deliver-on-thread (make-promise) thunk :name "cl-concurrent-kit future"))
