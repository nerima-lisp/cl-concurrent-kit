;;;; src/scope-execution.lisp
;;;;
;;;; SPAWN's dispatch: registering a %SCOPE-CHILD (src/scope-state.lisp) for
;;;; FUNCTION and running it either on a dedicated thread or on an EXECUTOR,
;;;; wiring either path back to SCOPE's own bookkeeping through
;;;; %SCOPE-CHILD-SETTLED so a child that fails -- or is cancelled -- is
;;;; accounted for identically regardless of how it ran.
(in-package #:cl-concurrent-kit)

(defun spawn (scope function &key executor)
  "Start FUNCTION as a child of SCOPE and return its promise. If SCOPE has
already been cancelled or is closing -- by a sibling's failure, or because
its WITH-TASK-SCOPE has already returned -- the returned promise is
immediately rejected with TASK-CANCELLED and FUNCTION never runs.

When EXECUTOR is supplied, queue the child on that executor. The optional
executor is intentionally accepted here rather than by WITH-TASK-SCOPE so one
scope can coordinate children with different execution policies."
  (let ((promise (make-promise)))
    (spawn-child scope function executor promise)
    promise))

(defun spawn-child (scope function executor promise)
  "SPAWN's dispatch: register a %SCOPE-CHILD for FUNCTION and hand it to
%SPAWN-EXECUTOR-CHILD or %SPAWN-THREAD-CHILD depending on whether EXECUTOR was
supplied, or reject PROMISE outright if SCOPE did not accept a new child."
  (let ((child (%make-scope-child)))
    (if (%scope-add-child scope child)
        (if executor
            (%spawn-executor-child executor scope child function promise)
            (%spawn-thread-child scope child function promise))
        (deliver-error promise (make-condition 'task-cancelled :scope scope)))))

(defun %spawn-executor-child (executor scope child function promise)
  "Queue FUNCTION on EXECUTOR and wire CHILD's cancellation to
%EXECUTOR-TASK-CANCEL, so SCOPE cancelling CHILD reaches a task still sitting
in EXECUTOR's queue exactly as it would a dedicated thread running
CHECK-CANCELLED. %SCOPE-CHILD-SETTLED runs as the task's ON-SETTLE callback,
whether it ran to completion or was cancelled before a worker claimed it, so
both outcomes reach SCOPE's bookkeeping identically."
  (handler-case
      (multiple-value-bind (submitted-promise task)
          (%submit executor
                   (lambda () (funcall function))
                   :promise promise
                   :on-settle
                   (lambda (state outcome)
                     (%scope-child-settled scope child state outcome)))
        (%scope-set-child-cancel
         scope child
         (lambda ()
           (%executor-task-cancel task (make-condition 'task-cancelled :scope scope))))
        submitted-promise)
    (error (condition)
      (%scope-remove-child scope child)
      (error condition))))

(defun %spawn-thread-child (scope child function promise)
  "Run FUNCTION on a dedicated thread, delivering its outcome to PROMISE via
%DELIVER-ON-THREAD and settling CHILD's scope bookkeeping through
%SCOPE-CHILD-SETTLED once it is done, the same as the EXECUTOR path above. If
MAKE-THREAD itself signals -- thread creation failing, not FUNCTION -- CHILD
is removed from SCOPE before re-signaling, exactly as the EXECUTOR path's own
HANDLER-CASE does for a rejected SUBMIT."
  (handler-case
      (%deliver-on-thread
       promise
       (lambda ()
         (multiple-value-bind (state outcome)
             (handler-case (values :fulfilled (funcall function))
               (error (condition) (values :failed condition)))
           (%scope-child-settled scope child state outcome)
           (ecase state
             (:fulfilled outcome)
             (:failed (error outcome)))))
       :name "cl-concurrent-kit scope task")
    (error (condition)
      (%scope-remove-child scope child)
      (error condition))))
