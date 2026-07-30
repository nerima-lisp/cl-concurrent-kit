(progn
  (declaim (optimize
      (speed 3)
      (safety 1)
      (debug 0)
      (compilation-speed 0)
      #+sb-cover (sb-c:store-coverage-data 3)))
  (in-package #:cl-concurrent-kit))

(defstruct (task-scope (:constructor %make-task-scope ())) (lock (make-lock :name "cl-concurrent-kit scope") :read-only t)
  (condition-variable
    (make-condition-variable :name "cl-concurrent-kit scope")
    :read-only
    t)
  (children (make-hash-table :test (function eq)) :read-only t)
  (closing-p nil)
  (cancelled-p nil)
  (failures nil))

(defun %scope-add-child (scope child)
  "Register CHILD and return true, or reject it after SCOPE starts closing."
  (with-lock-held
    ((task-scope-lock scope))
    (unless (task-scope-closing-p scope)
      (setf (gethash child (task-scope-children scope)) t)
      t)))

(defun %scope-remove-child (scope child)
  (with-lock-held
    ((task-scope-lock scope))
    (when (remhash child (task-scope-children scope))
      (condition-broadcast (task-scope-condition-variable scope)))))

(defun %scope-set-child-cancel (scope child cancel)
  (let ((cancel-now nil))
    (with-lock-held
      ((task-scope-lock scope))
      (when (gethash child (task-scope-children scope))
        (setf (car child) cancel
              cancel-now (task-scope-cancelled-p scope))))
    (when cancel-now
      (funcall cancel))))

(defun %scope-child-settled (scope child state outcome)
  "Record a child result after its public promise has been settled."
  (unless (or
      (eq state :fulfilled)
      (and
        (typep outcome 'task-cancelled)
        (with-lock-held ((task-scope-lock scope)) (task-scope-cancelled-p scope))))
    (%scope-record-failure scope outcome)
    (%scope-cancel scope))
  (%scope-remove-child scope child))

(defun %scope-close (scope)
  (with-lock-held
    ((task-scope-lock scope))
    (setf (task-scope-closing-p scope) t)))

(defun %scope-await-children (scope &key timeout)
  "Wait for every child, or signal OPERATION-TIMED-OUT after TIMEOUT seconds."
  (with-lock-held
    ((task-scope-lock scope))
    (let ((result
            (%wait-until
              ((task-scope-condition-variable scope)
               (task-scope-lock scope)
               (%deadline-from-timeout timeout))
              (when (zerop (hash-table-count (task-scope-children scope)))
                t))))
      (when (eq result :timeout)
        (error (quote operation-timed-out)
               :operation :with-task-scope
               :timeout timeout)))))

(defun %scope-record-failure (scope condition)
  (with-lock-held
    ((task-scope-lock scope))
    (push condition (task-scope-failures scope))))
