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
        (expect (await controller :timeout +test-timeout+) :to-be :released)
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
        (expect (await promise :timeout +test-timeout+) :to-be :still-active))))

  (it "returns a cancelled promise when SPAWN is called after scope closure"
    (let ((closed-scope nil))
      (with-task-scope (scope)
        (setf closed-scope scope))
      (let ((promise (spawn closed-scope (lambda () :should-not-run))))
        (expect (handler-case
                    (await promise :timeout +test-timeout+)
                  (task-cancelled () :rejected))
                :to-be :rejected))))

  (it "exposes failed task conditions through SCOPE-ERROR"
    (let ((marker (make-condition 'simple-error :format-control "task boom")))
      (handler-case
          (with-task-scope (scope)
            (spawn scope (lambda () (error marker))))
        (scope-error (condition)
          (let ((causes (scope-error-causes condition)))
            (expect (length causes) :to-be 1)
            (expect (eq (first causes) marker) :to-be-truthy))))))

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
            (wait-or-fail started "scope child did not start")
            (error "body boom"))
        (simple-error ()
          (setf body-error-observed-p t)))
      (expect body-error-observed-p :to-be-truthy)
      (expect (wait-on-semaphore cancelled :timeout 1) :to-be-truthy)))

  (it "exposes the cancelled scope to a sibling task"
    (let ((cancelled-observed-p nil)
          (cancelled-scope nil)
          (scope-from-body nil)
          (ready (make-semaphore)))
      (signals scope-error
        (with-task-scope (scope)
          (setf scope-from-body scope)
          (spawn scope
                 (lambda ()
                   (signal-semaphore ready)
                   (loop repeat 100
                         do (sleep 0.01)
                            (handler-case (check-cancelled scope)
                              (task-cancelled (condition)
                                (setf cancelled-observed-p t
                                      cancelled-scope (task-cancelled-scope condition))
                                (return))))))
          (wait-or-fail ready "sibling task did not start")
          (spawn scope (lambda () (error "sibling failure")))))
      (expect cancelled-observed-p :to-be-truthy)
      (expect (eq cancelled-scope scope-from-body) :to-be-truthy)))

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
              (wait-or-fail ready "first scope child did not start")
              (wait-or-fail ready "second scope child did not start")
              (setf controller
                    (future
                      (handler-case
                          (await first :timeout +test-timeout+)
                        (error ()
                          (signal-semaphore second-release)
                          :released))))
              (signal-semaphore first-release)))
        (scope-error (condition)
          (setf causes (scope-error-causes condition))))
      (expect (await controller :timeout +test-timeout+) :to-be :released)
      (expect (mapcar (function simple-condition-format-control) causes)
              :to-equal (list "first failure" "second failure"))))

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
          (wait-or-fail started "cancellable sibling did not start")
          (spawn scope (lambda () (error "sibling failure")))))
      (expect (wait-on-semaphore cancelled :timeout 1) :to-be-truthy)))

  (it "rejects a task spawned after the scope closes"
    (let ((scope (with-task-scope (scope) scope)))
      (let ((promise (spawn scope (lambda () :never-runs))))
        (signals task-cancelled
          (await promise :timeout +test-timeout+))))))

(describe "with-task-scope timeout"
  (it "signals OPERATION-TIMED-OUT when a child outlives WITH-TASK-SCOPE's :TIMEOUT"
    (let ((started (make-semaphore)))
      (signals operation-timed-out
        (with-task-scope (scope :timeout +test-timeout-expiry+)
          (spawn scope
                 (lambda ()
                   (signal-semaphore started)
                   (sleep 10)))
          (wait-or-fail started "scope child did not start")))))

  (it "does not signal OPERATION-TIMED-OUT when every child finishes within :TIMEOUT"
    (expect (with-task-scope (scope :timeout +test-timeout+)
              (await (spawn scope (lambda () :fast))))
            :to-be :fast))

  (it "bounds cleanup while cancelling a still-running child"
    (let ((started (make-semaphore))
          (release (make-semaphore))
          (finished (make-semaphore)))
      (unwind-protect
          (progn
            (signals operation-timed-out
              (with-task-scope (scope :timeout +test-timeout-brief+)
                (spawn
                  scope
                  (lambda ()
                    (signal-semaphore started)
                    (wait-on-semaphore release)
                    (signal-semaphore finished)))
                (wait-or-fail started "scope child did not start"))))
        (signal-semaphore release)
        (wait-or-fail finished "scope child did not finish")))))

(describe "scope executor integration"
  (it "settles a queued child when executor shutdown cancels it"
    (let ((executor (make-executor :size 1))
          release)
      (unwind-protect
          (progn
            (setf release (occupy-worker executor))
            (signals scope-error
              (with-task-scope (scope)
                (spawn scope (lambda () :never-runs) :executor executor)
                (shutdown-executor executor :cancel-pending t))))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t))))

  (it "waits for an immediately rejected executor child before reporting failure"
    (let ((executor (make-executor :size 1)))
      (shutdown-executor executor :wait t)
      (signals scope-error
        (with-task-scope (scope)
          (signals executor-shut-down
            (await (spawn scope
                          (lambda () :never-runs)
                          :executor executor)
                   :timeout +test-timeout+))))))

  (it "runs a child on an executor and preserves its result"
    (let ((executor (make-executor :size 1)))
      (unwind-protect
          (with-task-scope (scope)
            (expect (await (spawn scope (lambda () 42) :executor executor)
                           :timeout +test-timeout+)
                    :to-be 42))
        (shutdown-executor executor :wait t))))

  (it "removes a child registration when executor submission is invalid"
    (with-task-scope (scope)
      (signals type-error
        (spawn scope (lambda () :never-runs) :executor :not-an-executor)))))

(describe "with-task-scope executor children"
  (it "runs a spawned child on the given executor to completion and delivers its result"
    (let ((executor (make-executor :size 1)))
      (unwind-protect
          (expect (with-task-scope (scope)
                    (await (spawn scope (lambda () (+ 20 22)) :executor executor) :timeout +test-timeout+))
                  :to-be 42)
        (shutdown-executor executor :wait t))))

  (it "removes the child registration and re-signals when submitting to EXECUTOR itself fails"
    (with-task-scope (scope)
      (signals error (spawn scope (lambda () :unreachable) :executor "not-an-executor"))
      (expect (hash-table-count (cl-concurrent-kit::task-scope-children scope)) :to-be 0))))

(describe "scope executor cancellation"
  (it "settles a queued child when executor shutdown removes it"
    (let ((executor (make-executor :size 1))
          (queued (make-semaphore))
          (ran-p nil)
          release)
      (unwind-protect
          (progn
            (setf release (occupy-worker executor))
            (let ((scope-result
                    (future
                      (handler-case
                          (with-task-scope (scope)
                            (spawn scope (lambda () (setf ran-p t)) :executor executor)
                            (signal-semaphore queued))
                        (scope-error () :scope-failed)))))
              (wait-or-fail queued "scope child was not queued")
              (shutdown-executor executor :cancel-pending t)
              (expect (await scope-result :timeout +test-timeout+) :to-be :scope-failed)
              (expect ran-p :to-be nil)))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t))))
  (it "cancels a still-queued executor child without re-recording its own cancellation as a failure"
    (let ((executor (make-executor :size 1))
          (queued (make-semaphore))
          (ran-p nil)
          (body-error-observed-p nil)
          release)
      (unwind-protect
          (progn
            (setf release (occupy-worker executor))
            (handler-case
                (with-task-scope (scope)
                  (spawn scope (lambda () (setf ran-p t)) :executor executor)
                  (signal-semaphore queued)
                  (wait-or-fail queued "scope child was not queued")
                  (error "body boom"))
              (simple-error () (setf body-error-observed-p t)))
            (expect body-error-observed-p :to-be-truthy)
            (expect ran-p :to-be nil))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t)))))

(describe "scope cancellation outcomes"
  (it "reports a voluntarily signaled TASK-CANCELLED condition as a failure"
    (let ((scope nil)
          (captured nil))
      (handler-case
          (with-task-scope (current-scope)
            (setf scope current-scope)
            (spawn
              current-scope
              (lambda ()
                (error 'task-cancelled :scope current-scope))))
        (scope-error (condition)
          (setf captured condition)))
      (let ((causes (scope-error-causes captured)))
        (expect (length causes) :to-be 1)
        (expect (typep (first causes) 'task-cancelled) :to-be-truthy)
        (expect (eq (task-cancelled-scope (first causes)) scope) :to-be-truthy)))))

(describe "scope cancellation internals"
  (it "cancels a child that registers after scope cancellation"
    (let ((scope (cl-concurrent-kit::%make-task-scope))
          (child (cl-concurrent-kit::%make-scope-child))
          (cancelled nil))
      (cl-concurrent-kit::%scope-add-child scope child)
      (cl-concurrent-kit::%scope-cancel scope)
      (cl-concurrent-kit::%scope-set-child-cancel
        scope child (lambda () (setf cancelled t)))
      (expect cancelled :to-be-truthy)))
  (it "removes the child registration when direct thread creation fails"
    (let ((scope (cl-concurrent-kit::%make-task-scope)))
      (with-replaced-function (cl-concurrent-kit:make-thread
           (lambda (&rest arguments)
             (declare (ignore arguments))
             (error "thread creation failed")))
        (signals simple-error
          (spawn scope (lambda () :never-runs)))
        (expect
          (hash-table-count
            (cl-concurrent-kit::task-scope-children scope))
          :to-be
          0)))))

(describe "scope active child tracking"
  (it "removes a child after it settles"
    (let ((scope (cl-concurrent-kit::%make-task-scope)))
      (await (spawn scope (lambda () :done)) :timeout +test-timeout+)
      (expect (hash-table-count
               (cl-concurrent-kit::task-scope-children scope))
              :to-be 0)))

  (it "cancels only children still active at the snapshot"
    (let* ((scope (cl-concurrent-kit::%make-task-scope))
           (settled-cancellations 0)
           (active-cancellations 0)
           (settled (cl-concurrent-kit::%make-scope-child))
           (active (cl-concurrent-kit::%make-scope-child)))
      (cl-concurrent-kit::%scope-add-child scope settled)
      (cl-concurrent-kit::%scope-add-child scope active)
      (cl-concurrent-kit::%scope-set-child-cancel
       scope settled (lambda () (incf settled-cancellations)))
      (cl-concurrent-kit::%scope-set-child-cancel
       scope active (lambda () (incf active-cancellations)))
      (cl-concurrent-kit::%scope-remove-child scope settled)
      (cl-concurrent-kit::%scope-cancel scope)
      (expect settled-cancellations :to-be 0)
      (expect active-cancellations :to-be 1)))
  (it "invokes a child's cancel immediately when added to an already-cancelled scope"
    (let* ((scope (cl-concurrent-kit::%make-task-scope))
           (cancellations 0)
           (child (cl-concurrent-kit::%make-scope-child)))
      (cl-concurrent-kit::%scope-cancel scope)
      (setf (cl-concurrent-kit::%scope-child-cancel child)
            (lambda () (incf cancellations)))
      (cl-concurrent-kit::%scope-add-child scope child)
      (expect cancellations :to-be 1)))
  (it "is idempotent when removed twice, and fires SET-CHILD-CANCEL immediately once already cancelled"
    (let* ((scope (cl-concurrent-kit::%make-task-scope))
           (child (cl-concurrent-kit::%make-scope-child))
           (cancellations 0))
      (cl-concurrent-kit::%scope-add-child scope child)
      (cl-concurrent-kit::%scope-remove-child scope child)
      (cl-concurrent-kit::%scope-remove-child scope child)
      (expect (hash-table-count (cl-concurrent-kit::task-scope-children scope)) :to-be 0)
      (cl-concurrent-kit::%scope-add-child scope child)
      (cl-concurrent-kit::%scope-cancel scope)
      (cl-concurrent-kit::%scope-set-child-cancel scope child (lambda () (incf cancellations)))
      (expect cancellations :to-be 1)))
  (it "does not fire SET-CHILD-CANCEL for a child no longer tracked by the scope"
    (let* ((scope (cl-concurrent-kit::%make-task-scope))
           (child (cl-concurrent-kit::%make-scope-child))
           (cancellations 0))
      (cl-concurrent-kit::%scope-add-child scope child)
      (cl-concurrent-kit::%scope-remove-child scope child)
      (cl-concurrent-kit::%scope-cancel scope)
      (cl-concurrent-kit::%scope-set-child-cancel scope child (lambda () (incf cancellations)))
      (expect cancellations :to-be 0))))
