;;;; src/scope-state.lisp
;;;;
;;;; TASK-SCOPE's own bookkeeping: the struct, its children, its
;;;; cancellation flag, and the conditions its failed children signaled.
;;;; SPAWN and WITH-TASK-SCOPE (src/scope.lisp) are built entirely on the
;;;; functions here; splitting the two apart is what lets scope.lisp read as
;;;; "dispatch a child, run the macro" without this underneath it.
(in-package #:cl-concurrent-kit)

(defstruct (task-scope (:constructor %make-task-scope ()))
  (lock (make-lock :name "cl-concurrent-kit scope") :read-only t)
  ;; Broadcast whenever a child is removed, so %SCOPE-AWAIT-CHILDREN can wait
  ;; on one predicate (zero children left) instead of one promise per child.
  (condition-variable (make-condition-variable :name "cl-concurrent-kit scope")
                       :read-only t)
  ;; Active child records, keyed by the child object itself. Completed
  ;; children remove themselves so their cancellation closures are not retained.
  (children (make-hash-table :test (function eq)) :read-only t)
  (cancelled-p nil)
  ;; Conditions signaled by failed children, oldest first (reversed on read).
  (failures nil))

(defstruct (%scope-child (:constructor %make-scope-child (completion)))
  (completion nil :read-only t)
  (cancel nil))

(defmacro %with-scope-lock ((scope) &body body)
  "Hold SCOPE's own lock for the dynamic extent of BODY."
  `(with-lock-held ((task-scope-lock ,scope)) ,@body))

(defun check-cancelled (scope)
  "Signal TASK-CANCELLED if SCOPE has been cancelled -- because a sibling
task failed, because WITH-TASK-SCOPE's body exited abnormally, or because
WITH-TASK-SCOPE has already returned. Call this periodically from within
long-running SPAWNed work, at points where stopping early is safe."
  (when (%with-scope-lock (scope) (task-scope-cancelled-p scope))
    (error 'task-cancelled :scope scope)))

(defun %scope-cancel (scope)
  "Mark SCOPE cancelled and request cancellation of its active children."
  (let ((cancellers nil))
    (%with-scope-lock (scope)
      (unless (task-scope-cancelled-p scope)
        (setf (task-scope-cancelled-p scope) t
              cancellers
              (loop for child being the hash-keys of (task-scope-children scope)
                    for cancel = (%scope-child-cancel child)
                    when cancel collect cancel))))
    (dolist (cancel cancellers)
      (funcall cancel))))

(defun %scope-record-failure (scope condition)
  (%with-scope-lock (scope)
    (push condition (task-scope-failures scope))))

(defun %scope-add-child (scope child)
  (let ((cancel nil))
    (%with-scope-lock (scope)
      (setf (gethash child (task-scope-children scope)) t)
      (when (task-scope-cancelled-p scope)
        (setf cancel (%scope-child-cancel child))))
    (when cancel
      (funcall cancel))))

(defun %scope-remove-child (scope child)
  (%with-scope-lock (scope)
    (when (remhash child (task-scope-children scope))
      (condition-broadcast (task-scope-condition-variable scope)))))

(defun %scope-set-child-cancel (scope child cancel)
  (let ((cancel-now nil))
    (%with-scope-lock (scope)
      (setf (%scope-child-cancel child) cancel)
      (when (and (gethash child (task-scope-children scope))
                 (task-scope-cancelled-p scope))
        (setf cancel-now cancel)))
    (when cancel-now
      (funcall cancel-now))))

(defun %scope-await-children (scope &key timeout)
  "Block until every child SPAWNed on SCOPE has finished, or signal
OPERATION-TIMED-OUT after TIMEOUT seconds -- WITH-TASK-SCOPE's own :TIMEOUT.
On a timeout, SCOPE's own cancellation (its caller's job, not this
function's) is what stops the children this stopped waiting for."
  (%with-scope-lock (scope)
    (%with-deadline-wait (done (task-scope-condition-variable scope) (task-scope-lock scope)
                          (lambda () (zerop (hash-table-count (task-scope-children scope))))
                          (%deadline-from-timeout timeout) timeout :with-task-scope)
      done)))

(defun %scope-signal-failures (scope)
  (let ((failures (%with-scope-lock (scope) (reverse (task-scope-failures scope)))))
    (when failures
      (error 'scope-error :causes failures))))
