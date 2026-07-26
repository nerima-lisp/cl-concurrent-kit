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
;;;; must call CHECK-CANCELLED at points where stopping early is safe.
(in-package #:cl-concurrent-kit)

(defstruct (task-scope (:constructor %make-task-scope ()))
  (lock (make-lock :name "cl-concurrent-kit scope") :read-only t)
  (children nil)
  (cancelled-p nil)
  ;; Conditions signaled by failed children, oldest first (reversed on read).
  (failures nil))

(defun check-cancelled (scope)
  "Signal TASK-CANCELLED if SCOPE has been cancelled -- because a sibling
task failed, or because WITH-TASK-SCOPE's body exited abnormally. Call this
periodically from within long-running SPAWNed work, at points where stopping
early is safe."
  (when (with-lock-held ((task-scope-lock scope)) (task-scope-cancelled-p scope))
    (error 'task-cancelled :scope scope)))

(defun %scope-cancel (scope)
  (with-lock-held ((task-scope-lock scope))
    (setf (task-scope-cancelled-p scope) t)))

(defun %scope-record-failure (scope condition)
  (with-lock-held ((task-scope-lock scope))
    (push condition (task-scope-failures scope))))

(defun spawn (scope function)
  "Start FUNCTION on a new thread tracked by SCOPE and return a PROMISE for
its outcome. If FUNCTION signals an error, every other task in SCOPE has its
next CHECK-CANCELLED trip, and -- once WITH-TASK-SCOPE's body has returned
and every task has finished -- that error resurfaces wrapped in a
SCOPE-ERROR."
  (let ((promise (make-promise))
        (thread nil))
    (setf thread
          (make-thread
           (lambda ()
             (handler-case (deliver promise (funcall function))
               (error (c)
                 (deliver-error promise c)
                 (%scope-record-failure scope c)
                 (%scope-cancel scope))))
           :name "cl-concurrent-kit scope task"))
    (with-lock-held ((task-scope-lock scope))
      (push thread (task-scope-children scope)))
    promise))

(defun %scope-await-children (scope)
  (dolist (thread (with-lock-held ((task-scope-lock scope)) (task-scope-children scope)))
    ;; JOIN-THREAD alone -- not a separate pending-count -- is the wait: it
    ;; already blocks until the child's UNWIND-PROTECT-wrapped handler-case
    ;; above has fully run.
    (join-thread thread)))

(defun %scope-signal-failures (scope)
  (let ((failures (with-lock-held ((task-scope-lock scope)) (reverse (task-scope-failures scope)))))
    (when failures
      (error 'scope-error :causes failures))))

(defun %call-with-task-scope (function)
  (let ((scope (%make-task-scope))
        (body-completed-p nil)
        (results nil))
    (unwind-protect
        (progn
          (setf results (multiple-value-list (funcall function scope)))
          (setf body-completed-p t))
      ;; Reached on both a normal return and a non-local exit from FUNCTION.
      ;; Only the abnormal-exit case trips cancellation here: a child that
      ;; has already failed trips it itself (in SPAWN, above), and a body
      ;; that simply returned while children are still running should let
      ;; them finish on their own rather than being cancelled out from under
      ;; it.
      (unless body-completed-p
        (%scope-cancel scope))
      (%scope-await-children scope))
    (when body-completed-p
      (%scope-signal-failures scope)
      (values-list results))))

(defmacro with-task-scope ((scope-var) &body body)
  "Bind SCOPE-VAR to a fresh task scope for the dynamic extent of BODY. Every
task started with (SPAWN SCOPE-VAR ...) is guaranteed to have finished before
WITH-TASK-SCOPE returns. If BODY itself signals, that condition propagates
after every child has been cancelled and awaited; if BODY returns normally
but one or more children failed, WITH-TASK-SCOPE signals SCOPE-ERROR once
they have all finished."
  `(%call-with-task-scope (lambda (,scope-var) ,@body)))
