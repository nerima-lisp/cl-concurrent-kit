;;;; t/scope-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "with-task-scope"
  (it "returns the body values when every task succeeds"
    (expect (multiple-value-list
             (with-task-scope (scope)
               (declare (ignore scope))
               (values :first :second :third)))
            :to-equal (list :first :second :third)))

  (it "waits for every spawned task to finish before returning"
    (let ((finished (list))
          (ready (make-semaphore))
          (release (make-semaphore))
          (lock (make-lock)))
      (let ((controller
              (future
                (dotimes (i 5)
                  (declare (ignore i))
                  (wait-on-semaphore ready))
                (dotimes (i 5)
                  (declare (ignore i))
                  (signal-semaphore release))
                :released)))
        (with-task-scope (scope)
          (dotimes (i 5)
            (let ((i i))
              (spawn scope
                     (lambda ()
                       (signal-semaphore ready)
                       (wait-on-semaphore release)
                       (with-lock-held (lock) (push i finished)))))))
        (expect (await controller :timeout 1) :to-be :released)
        (expect (sort finished (function <)) :to-equal (list 0 1 2 3 4)))))

  (it "makes each SPAWNed task result available via its returned promise"
    (with-task-scope (scope)
      (let ((promise (spawn scope (lambda () (+ 20 22)))))
        (expect (await promise) :to-be 42))))

  (it "allows CHECK-CANCELLED before scope cancellation"
    (with-task-scope (scope)
      (let ((promise
              (spawn scope
                     (lambda ()
                       (check-cancelled scope)
                       :still-active))))
        (expect (await promise :timeout 1) :to-be :still-active))))

  (it "returns a cancelled promise when SPAWN is called after scope closure"
    (let ((closed-scope nil))
      (with-task-scope (scope)
        (setf closed-scope scope))
      (let ((promise (spawn closed-scope (lambda () :should-not-run))))
        (expect (handler-case
                    (await promise :timeout 1)
                  (task-cancelled () :rejected))
                :to-be :rejected))))

  (it "signals SCOPE-ERROR wrapping a failed task condition"
    (signals scope-error
      (with-task-scope (scope)
        (spawn scope (lambda () (error "task boom")))))
    (handler-case
        (with-task-scope (scope)
          (spawn scope (lambda () (error "task boom"))))
      (scope-error (condition)
        (expect (length (scope-error-causes condition)) :to-be 1))))

  (it "cancels and awaits a running child when the body signals"
    (let ((started (make-semaphore))
          (cancelled (make-semaphore))
          (body-error-observed-p nil))
      (handler-case
          (with-task-scope (scope)
            (spawn scope
                   (lambda ()
                     (signal-semaphore started)
                     (loop
                       (handler-case
                           (check-cancelled scope)
                         (task-cancelled ()
                           (signal-semaphore cancelled)
                           (return :cancelled)))
                       (sleep 0.001))))
            (unless (wait-on-semaphore started :timeout 1)
              (error "scope child did not start"))
            (error "body boom"))
        (simple-error ()
          (setf body-error-observed-p t)))
      (expect body-error-observed-p :to-be-truthy)
      (expect (wait-on-semaphore cancelled :timeout 1) :to-be-truthy)))

  (it "aggregates child failures in failure order"
    (let ((ready (make-semaphore))
          (first-release (make-semaphore))
          (second-release (make-semaphore))
          (controller nil)
          (causes nil))
      (handler-case
          (with-task-scope (scope)
            (let ((first
                    (spawn scope
                           (lambda ()
                             (signal-semaphore ready)
                             (wait-on-semaphore first-release)
                             (error "first failure"))))
                  (second
                    (spawn scope
                           (lambda ()
                             (signal-semaphore ready)
                             (wait-on-semaphore second-release)
                             (error "second failure")))))
              (declare (ignore second))
              (unless (wait-on-semaphore ready :timeout 1)
                (error "first scope child did not start"))
              (unless (wait-on-semaphore ready :timeout 1)
                (error "second scope child did not start"))
              (setf controller
                    (future
                      (handler-case
                          (await first :timeout 1)
                        (error ()
                          (signal-semaphore second-release)
                          :released))))
              (signal-semaphore first-release)))
        (scope-error (condition)
          (setf causes (scope-error-causes condition))))
      (expect (await controller :timeout 1) :to-be :released)
      (expect (mapcar (function simple-condition-format-control) causes)
              :to-equal (list "first failure" "second failure"))))

  (it "signals OPERATION-TIMED-OUT when a child outlives WITH-TASK-SCOPE's :TIMEOUT"
    (let ((started (make-semaphore)))
      (signals operation-timed-out
        (with-task-scope (scope :timeout 0.05d0)
          (spawn scope
                 (lambda ()
                   (signal-semaphore started)
                   (sleep 10)))
          (unless (wait-on-semaphore started :timeout 1)
            (error "scope child did not start"))))))

  (it "does not signal OPERATION-TIMED-OUT when every child finishes within :TIMEOUT"
    (expect (with-task-scope (scope :timeout 1)
              (await (spawn scope (lambda () :fast))))
            :to-be :fast))

  (it "trips CHECK-CANCELLED for a sibling after another task fails"
    (let ((started (make-semaphore))
          (cancelled (make-semaphore)))
      (signals scope-error
        (with-task-scope (scope)
          (spawn scope
                 (lambda ()
                   (signal-semaphore started)
                   (loop
                     (handler-case
                         (check-cancelled scope)
                       (task-cancelled ()
                         (signal-semaphore cancelled)
                         (return :cancelled)))
                     (sleep 0.001))))
          (unless (wait-on-semaphore started :timeout 1)
            (error "cancellable sibling did not start"))
          (spawn scope (lambda () (error "sibling failure")))))
      (expect (wait-on-semaphore cancelled :timeout 1) :to-be-truthy))))

(describe "scope executor cancellation"
  (it "settles a queued child when executor shutdown removes it"
    (let ((executor (make-executor :size 1))
          (started (make-semaphore))
          (release (make-semaphore))
          (queued (make-semaphore))
          (ran-p nil))
      (unwind-protect
          (progn
            (submit executor
                    (lambda ()
                      (signal-semaphore started)
                      (wait-on-semaphore release)))
            (unless (wait-on-semaphore started :timeout 1)
              (error "executor worker did not start"))
            (let ((scope-result
                    (future
                      (handler-case
                          (with-task-scope (scope)
                            (spawn scope (lambda () (setf ran-p t)) :executor executor)
                            (signal-semaphore queued))
                        (scope-error () :scope-failed)))))
              (unless (wait-on-semaphore queued :timeout 1)
                (error "scope child was not queued"))
              (shutdown-executor executor :cancel-pending t)
              (expect (await scope-result :timeout 1) :to-be :scope-failed)
              (expect ran-p :to-be nil)))
        (signal-semaphore release)
        (shutdown-executor executor :wait t)))))

(describe "scope active child tracking"
  (it "removes a child after it settles"
    (let ((scope (cl-concurrent-kit::%make-task-scope)))
      (await (spawn scope (lambda () :done)) :timeout 1)
      (expect (hash-table-count
               (cl-concurrent-kit::task-scope-children scope))
              :to-be 0)))

  (it "cancels only children still active at the snapshot"
    (let* ((scope (cl-concurrent-kit::%make-task-scope))
           (settled-cancellations 0)
           (active-cancellations 0)
           (settled (cl-concurrent-kit::%make-scope-child
                     (make-promise)))
           (active (cl-concurrent-kit::%make-scope-child
                    (make-promise))))
      (cl-concurrent-kit::%scope-add-child scope settled)
      (cl-concurrent-kit::%scope-add-child scope active)
      (cl-concurrent-kit::%scope-set-child-cancel
       scope settled (lambda () (incf settled-cancellations)))
      (cl-concurrent-kit::%scope-set-child-cancel
       scope active (lambda () (incf active-cancellations)))
      (cl-concurrent-kit::%scope-remove-child scope settled)
      (cl-concurrent-kit::%scope-cancel scope)
      (expect settled-cancellations :to-be 0)
      (expect active-cancellations :to-be 1))))
