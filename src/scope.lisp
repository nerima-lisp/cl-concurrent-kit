;;;; src/scope.lisp
;;;;
;;;; Structured concurrency (Kotlin coroutine scopes, Swift task groups,
;;;; Python trio nurseries): WITH-TASK-SCOPE guarantees every task SPAWNed
;;;; within its body has finished -- successfully, by error, or cancelled --
;;;; before it returns, and a failed task's condition always resurfaces
;;;; somewhere, instead of being silently dropped on a detached thread.
;;;;
;;;; cl-concurrent-kit cannot forcibly interrupt a running SBCL thread, so
;;;; cancellation here is cooperative: a scope trips a flag, and SPAWNed work
;;;; must call CHECK-CANCELLED at points where stopping early is safe. See
;;;; src/scope-state.lisp for TASK-SCOPE's own bookkeeping.
(in-package #:cl-concurrent-kit)

(defun spawn (scope function &key executor)
  "Start FUNCTION as a child of SCOPE and return its promise. If SCOPE has
already been cancelled -- by a sibling's failure, or because its
WITH-TASK-SCOPE has already returned -- the returned promise is immediately
rejected with TASK-CANCELLED and FUNCTION never runs.

When EXECUTOR is supplied, queue the child on that executor.  The optional
executor is intentionally accepted here rather than by WITH-TASK-SCOPE so one
scope can coordinate children with different execution policies."
  (let ((promise (make-promise)))
   (if (%with-scope-lock (scope) (task-scope-cancelled-p scope))
       (deliver-error promise (make-condition 'task-cancelled :scope scope))
       (spawn-child scope function executor promise))
   promise))

(defun spawn-child (scope function executor promise)
  "SPAWN's dispatch once SCOPE is known not to be cancelled yet: register a
%SCOPE-CHILD for FUNCTION and hand it to %SPAWN-EXECUTOR-CHILD or
%SPAWN-THREAD-CHILD depending on whether EXECUTOR was supplied."
  (let* ((completion (make-promise))
         (child (%make-scope-child completion)))
    (%scope-add-child scope child)
    (if executor
        (%spawn-executor-child executor scope child function promise completion)
        (%spawn-thread-child scope child function promise))))

(defun %spawn-executor-child (executor scope child function promise completion)
  "Queue FUNCTION on EXECUTOR and wire CHILD's cancellation to
%EXECUTOR-TASK-CANCEL, so SCOPE cancelling CHILD reaches a task still sitting
in EXECUTOR's queue exactly as it would a dedicated thread running
CHECK-CANCELLED."
  (handler-case
      (multiple-value-bind (submitted-promise task)
          (%submit executor
                   (lambda () (%scope-run-child scope child function))
                   :promise promise
                   :on-cancel
                   (lambda (condition)
                     (unwind-protect
                          (unless (typep condition 'task-cancelled)
                            (%scope-record-failure scope condition)
                            (%scope-cancel scope))
                       (deliver completion t)
                       (%scope-remove-child scope child))))
        (%scope-set-child-cancel
         scope child
         (lambda ()
           (%executor-task-cancel task (make-condition 'task-cancelled :scope scope))))
        submitted-promise)
    (error (condition)
      (%scope-remove-child scope child)
      (error condition))))

(defun %spawn-thread-child (scope child function promise)
  "Run FUNCTION on a dedicated thread, delivering its outcome to PROMISE."
  (%deliver-on-thread promise
                       (lambda () (%scope-run-child scope child function))
                       :name "cl-concurrent-kit scope task"))

(defun %scope-run-child (scope child function)
  (unwind-protect
       (handler-case
           (funcall function)
         (error (condition)
           (%scope-record-failure scope condition)
           (%scope-cancel scope)
           (error condition)))
    (deliver (%scope-child-completion child) t)
    (%scope-remove-child scope child)))

(defmacro with-task-scope ((scope-var &key timeout) &body body)
  "Bind SCOPE-VAR to a fresh task scope and run BODY inline -- not through an
intervening closure, so a CHECK-CANCELLED or SPAWN call in BODY is a direct
call rather than one more indirection through a stored function -- for the
dynamic extent of BODY. Every task started with (SPAWN SCOPE-VAR ...) is
guaranteed to have finished before WITH-TASK-SCOPE returns.

TIMEOUT (seconds) bounds only the wait for already-running children once
BODY itself has returned or signalled; on expiry every remaining child is
cancelled cooperatively and OPERATION-TIMED-OUT is signaled.

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
         ;; Only the abnormal-exit case trips cancellation here: a child that
         ;; has already failed trips it itself (in SPAWN, above), and a body
         ;; that simply returned while children are still running should let
         ;; them finish on their own rather than being cancelled out from
         ;; under it.
         (unless ,body-completed-p
           (%scope-cancel ,scope-var))
         (%scope-await-children ,scope-var :timeout ,timeout)
         ;; Every child has now finished, so SCOPE-VAR is done either way.
         ;; Mark it cancelled (a no-op if the block above already did) so a
         ;; reference to it that escaped WITH-TASK-SCOPE's dynamic extent
         ;; cannot SPAWN new work onto it.
         (%scope-cancel ,scope-var))
       (when ,body-completed-p
         (%scope-signal-failures ,scope-var)
         (values-list ,results)))))
