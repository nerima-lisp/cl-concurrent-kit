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
  ;; Active child records, keyed by the child object itself.  Completed
  ;; children remove themselves so their cancellation closures are not retained.
  (children (make-hash-table :test (function eq)) :read-only t)
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
  "Mark SCOPE cancelled and request cancellation of its active children."
  (let ((cancellers nil))
    (with-lock-held ((task-scope-lock scope))
      (unless (task-scope-cancelled-p scope)
        (setf (task-scope-cancelled-p scope) t
              cancellers
              (loop for child being the hash-keys of (task-scope-children scope)
                    for cancel = (%scope-child-cancel child)
                    when cancel collect cancel))))
    (dolist (cancel cancellers)
      (funcall cancel))))

(defun %scope-record-failure (scope condition)
  (with-lock-held ((task-scope-lock scope))
    (push condition (task-scope-failures scope))))

(defun spawn (scope function &key executor)
  "Start FUNCTION as a child of SCOPE and return its promise.

When EXECUTOR is supplied, queue the child on that executor.  The optional
executor is intentionally accepted here rather than by WITH-TASK-SCOPE so one
scope can coordinate children with different execution policies."
  (let* ((promise (make-promise))
         (completion (make-promise))
         (child (%make-scope-child completion)))
    (%scope-add-child scope child)
    (if executor
        (handler-case
            (multiple-value-bind (submitted-promise task)
                (%submit executor
                         (lambda () (%scope-run-child scope child function))
                         :promise promise
                         :on-cancel
                         (lambda (condition)
                           (unwind-protect
                                (unless (typep condition (quote task-cancelled))
                                  (%scope-record-failure scope condition)
                                  (%scope-cancel scope))
                             (deliver completion t)
                             (%scope-remove-child scope child))))
              (%scope-set-child-cancel
               scope child
               (lambda ()
                 (%executor-task-cancel
                  task
                  (make-condition (quote task-cancelled) :scope scope))))
              submitted-promise)
          (error (condition)
            (%scope-remove-child scope child)
            (error condition)))
        (progn
          (make-thread
           (lambda ()
             (handler-case
                 (deliver promise (%scope-run-child scope child function))
               (error (condition)
                 (deliver-error promise condition))))
           :name "cl-concurrent-kit scope task")
          promise))))

(defun %scope-await-children (scope)
  (let ((children nil))
    (with-lock-held ((task-scope-lock scope))
      (maphash (lambda (child present-p)
                 (declare (ignore present-p))
                 (push child children))
               (task-scope-children scope)))
    (dolist (child children)
      (await (%scope-child-completion child)))))

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

(defstruct (%scope-child (:constructor %make-scope-child (completion)))
  (completion nil :read-only t)
  (cancel nil))

(defun %scope-add-child (scope child)
  (let ((cancel nil))
    (with-lock-held ((task-scope-lock scope))
      (setf (gethash child (task-scope-children scope)) t)
      (when (task-scope-cancelled-p scope)
        (setf cancel (%scope-child-cancel child))))
    (when cancel
      (funcall cancel))))

(defun %scope-remove-child (scope child)
  (with-lock-held ((task-scope-lock scope))
    (remhash child (task-scope-children scope))))

(defun %scope-set-child-cancel (scope child cancel)
  (let ((cancel-now nil))
    (with-lock-held ((task-scope-lock scope))
      (setf (%scope-child-cancel child) cancel)
      (when (and (gethash child (task-scope-children scope))
                 (task-scope-cancelled-p scope))
        (setf cancel-now cancel)))
    (when cancel-now
      (funcall cancel-now))))

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
