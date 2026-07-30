(progn
  (declaim (optimize
      (speed 3)
      (safety 1)
      (debug 0)
      (compilation-speed 0)
      #+sb-cover (sb-c:store-coverage-data 3)))
  (in-package #:cl-concurrent-kit))

(defun spawn (scope function &key executor)
  "Start FUNCTION as a child of SCOPE and return a PROMISE for its outcome.
Children are registered before submission, so scope shutdown cannot miss them."
  (let ((promise (make-promise))
        (child (list nil)))
    (unless (%scope-add-child scope child)
      (deliver-error promise (make-condition (quote task-cancelled) :scope scope))
      (return-from spawn promise))
    (if executor (handler-case (multiple-value-bind (submitted-promise task) (%submit
            executor
            (lambda ()
              (funcall function))
            :promise
            promise
            :on-settle
            (lambda (state outcome)
              (%scope-child-settled scope child state outcome)))
          (%scope-set-child-cancel
            scope
            child
            (lambda ()
              (%executor-task-cancel
                task
                (make-condition (quote task-cancelled) :scope scope))))
          submitted-promise)
        (error (condition)
          (%scope-remove-child scope child)
          (error condition)))
      (handler-case (progn
          (make-thread
            (lambda ()
              (multiple-value-bind (state outcome) (handler-case (values :fulfilled (funcall function))
                  (error (condition)
                    (values :failed condition)))
                (unwind-protect (ecase state
                    (:fulfilled (deliver promise outcome))
                    (:failed (deliver-error promise outcome)))
                  (%scope-child-settled scope child state outcome))))
            :name
            "cl-concurrent-kit scope task")
          promise)
        (error (condition)
          (%scope-remove-child scope child)
          (error condition))))))

(defun %scope-cancel (scope)
  (let ((cancellers nil))
    (with-lock-held
      ((task-scope-lock scope))
      (unless (task-scope-cancelled-p scope)
        (setf (task-scope-cancelled-p scope) t
              cancellers (loop for child being the hash-keys of (task-scope-children scope)
                for cancel = (car child)
                when cancel
                  collect cancel))))
    (dolist (cancel cancellers)
      (funcall cancel))))
