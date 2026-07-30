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
(progn (declaim (optimize (speed 3) (safety 1) (debug 0) (compilation-speed 0) #+sb-cover (sb-c:store-coverage-data 3))) (in-package #:cl-concurrent-kit))

(defun check-cancelled (scope)
  "Signal TASK-CANCELLED if SCOPE has been cancelled -- because a sibling
task failed, or because WITH-TASK-SCOPE's body exited abnormally. Call this
periodically from within long-running SPAWNed work, at points where stopping
early is safe."
  (when (with-lock-held ((task-scope-lock scope)) (task-scope-cancelled-p scope))
    (error 'task-cancelled :scope scope)))

(defun %scope-signal-failures (scope)
  (let ((failures
        (with-lock-held ((task-scope-lock scope)) (reverse (task-scope-failures scope)))))
    (when failures
      (error 'scope-error :causes failures))))

(defmacro with-task-scope ((scope-var &key timeout) &body body)
  "Execute BODY with a lexical task scope and await its children before exit.

TIMEOUT bounds the cleanup wait in seconds. On expiry the scope is cancelled
cooperatively and OPERATION-TIMED-OUT is signaled."
  (let ((scope (gensym "SCOPE-"))
        (timeout-var (gensym "TIMEOUT-"))
        (body-completed-p (gensym "BODY-COMPLETED-P-"))
        (results (gensym "RESULTS-")))
    `(let ((,timeout-var ,timeout)
           (,scope (%make-task-scope))
           (,body-completed-p nil)
           (,results nil))
       (let ((,scope-var ,scope))
         (unwind-protect
              (progn
                (setf ,results
                      (multiple-value-list
                       (locally
                         ,@body)))
                (setf ,body-completed-p t))
           (%scope-close ,scope)
           (unless ,body-completed-p
             (%scope-cancel ,scope))
           (handler-case
               (%scope-await-children ,scope :timeout ,timeout-var)
             (operation-timed-out (condition)
               (%scope-cancel ,scope)
               (error condition))))
         (when ,body-completed-p
           (%scope-signal-failures ,scope)
           (values-list ,results))))))
