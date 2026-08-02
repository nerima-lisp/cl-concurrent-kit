;;;; src/scope.lisp
;;;;
;;;; Structured concurrency (Kotlin coroutine scopes, Swift task groups,
;;;; Python trio nurseries): WITH-TASK-SCOPE guarantees every task SPAWNed
;;;; within its body has finished -- successfully, by error, or cancelled --
;;;; before it returns, and a failed task's condition always resurfaces
;;;; somewhere, instead of being silently dropped on a detached thread.
;;;;
;;;; Cancellation here is COOPERATIVE: a scope trips a flag, and SPAWNed work
;;;; must call CHECK-CANCELLED at points where stopping early is safe. That is
;;;; a choice, not a missing mechanism -- src/timeout.lisp's WITH-TIMEOUT does
;;;; forcibly interrupt a running SBCL thread, through a timer and
;;;; SB-THREAD:INTERRUPT-THREAD, so the capability exists and is deliberately
;;;; not used here. An asynchronous interrupt lands between two arbitrary
;;;; instructions, which means it can unwind a task whose UNWIND-PROTECT has
;;;; not yet recorded the resource its cleanup would release
;;;; (SB-EXT:WITH-TIMEOUT's own docstring works that hazard through). A scope
;;;; exists precisely to guarantee that every child it started has finished
;;;; and been accounted for, and that guarantee is worth more than reclaiming
;;;; a task a few moments earlier. See src/scope-state.lisp for TASK-SCOPE's
;;;; own bookkeeping and src/scope-execution.lisp for SPAWN's dispatch.
(in-package #:cl-concurrent-kit)

(defmacro with-task-scope ((scope-var &key timeout) &body body)
  "Bind SCOPE-VAR to a fresh task scope and run BODY inline -- not through an
intervening closure, so a CHECK-CANCELLED or SPAWN call in BODY is a direct
call rather than one more indirection through a stored function -- for the
dynamic extent of BODY. Every task started with (SPAWN SCOPE-VAR ...) is
guaranteed to have finished before WITH-TASK-SCOPE returns.

TIMEOUT (seconds) bounds only the wait for already-running children once
BODY itself has returned or signalled; on expiry every remaining child is
cancelled cooperatively and OPERATION-TIMED-OUT is signaled, naming
:WITH-TASK-SCOPE as the operation. WITH-TIMEOUT signals that same condition
type naming :WITH-TIMEOUT, so a handler around a scope whose BODY uses
WITH-TIMEOUT must read OPERATION-TIMED-OUT-OPERATION to tell which of the two
deadlines expired.

If BODY itself signals, that condition propagates after every child has been
cancelled and awaited; if BODY returns normally but one or more children
failed, WITH-TASK-SCOPE signals SCOPE-ERROR once they have all finished."
  (let ((body-completed-p (gensym "BODY-COMPLETED-P"))
        (results (gensym "RESULTS")))
    `(let ((,scope-var (%make-task-scope))
           (,body-completed-p nil)
           (,results nil))
       (unwind-protect
           (progn
             (setf ,results (multiple-value-list (locally ,@body)))
             (setf ,body-completed-p t))
         ;; Reached on both a normal return and a non-local exit from BODY.
         ;; Close the scope first, so a child racing to SPAWN onto it right
         ;; as BODY exits is rejected outright instead of possibly slipping
         ;; in after %SCOPE-AWAIT-CHILDREN below has already taken its
         ;; snapshot of "no children left".
         (%scope-close ,scope-var)
         ;; Only the abnormal-exit case trips cancellation here: a child that
         ;; has already failed trips it itself (in SPAWN, above), and a body
         ;; that simply returned while children are still running should let
         ;; them finish on their own rather than being cancelled out from
         ;; under it.
         (unless ,body-completed-p
           (%scope-cancel ,scope-var))
         (handler-case
             (%scope-await-children ,scope-var :timeout ,timeout)
           (operation-timed-out (condition)
             (%scope-cancel ,scope-var)
             (error condition))))
       (when ,body-completed-p
         (%scope-signal-failures ,scope-var)
         (values-list ,results)))))
