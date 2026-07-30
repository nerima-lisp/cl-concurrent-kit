;;;; t/scope-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "with-task-scope"
  (it "returns the body's value when every task succeeds"
    (expect (with-task-scope (scope) (declare (ignore scope)) :done) :to-be :done))

  (it "waits for every spawned task to finish before returning"
    (let ((finished (list))
          (lock (make-lock)))
      (with-task-scope (scope)
        ;; DOTIMES mutates one binding of I in place, so each closure needs
        ;; its own copy via LET -- otherwise every task would see I already
        ;; at 5 by the time a thread got around to running it.
        (dotimes (i 5)
          (let ((i i))
            (spawn scope (lambda ()
                           (sleep (* i 0.01))
                           (with-lock-held (lock) (push i finished)))))))
      (expect (sort finished #'<) :to-equal '(0 1 2 3 4))))

  (it "makes each SPAWNed task's own result available via its returned promise"
    (with-task-scope (scope)
      (let ((p (spawn scope (lambda () (+ 20 22)))))
        (expect (await p) :to-be 42))))

  (it "exposes failed task conditions through SCOPE-ERROR"
  (let ((marker (make-condition 'simple-error :format-control "task boom")))
    (handler-case
        (with-task-scope (scope)
          (spawn scope (lambda () (error marker))))
      (scope-error (condition)
        (let ((causes (scope-error-causes condition)))
          (expect (length causes) :to-be 1)
          (expect (eq (first causes) marker) :to-be-truthy))))))

  (it "propagates the body's own error instead of wrapping it in SCOPE-ERROR"
    (signals simple-error
      (with-task-scope (scope)
        (declare (ignore scope))
        (error "body boom"))))

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
        (unless (wait-on-semaphore ready :timeout 1)
          (error "sibling task did not start"))
        (spawn scope (lambda () (error "sibling failure")))))
    (expect cancelled-observed-p :to-be-truthy)
    (expect (eq cancelled-scope scope-from-body) :to-be-truthy)))

  (it "rejects a task spawned after the scope closes"
    (let ((scope (with-task-scope (scope) scope)))
      (let ((promise (spawn scope (lambda () :never-runs))))
        (signals task-cancelled
          (await promise :timeout 1))))))

(describe "scope executor integration"
  (it "settles a queued child when executor shutdown cancels it"
    (let ((executor (make-executor :size 1))
          (started (make-semaphore))
          (release (make-semaphore)))
      (unwind-protect
          (progn
            (submit executor
                    (lambda ()
                      (signal-semaphore started)
                      (wait-on-semaphore release)))
            (unless (wait-on-semaphore started :timeout 1)
              (error "executor worker did not start"))
            (signals scope-error
              (with-task-scope (scope)
                (spawn scope (lambda () :never-runs) :executor executor)
                (shutdown-executor executor :cancel-pending t))))
        (signal-semaphore release)
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
                   :timeout 1))))))

  (it "runs a child on an executor and preserves its result"
    (let ((executor (make-executor :size 1)))
      (unwind-protect
          (with-task-scope (scope)
            (expect (await (spawn scope (lambda () 42) :executor executor)
                           :timeout 1)
                    :to-be 42))
        (shutdown-executor executor :wait t))))

  (it "removes a child registration when executor submission is invalid"
    (with-task-scope (scope)
      (signals type-error
        (spawn scope (lambda () :never-runs) :executor :not-an-executor)))))

(progn
  (describe
    "scope cancellation outcomes"
    (it
      "reports a voluntarily signaled TASK-CANCELLED condition as a failure"
      (let ((scope nil)
            (captured nil))
        (handler-case
            (with-task-scope (current-scope)
              (setf scope current-scope)
              (spawn
                current-scope
                (lambda ()
                  (error (quote task-cancelled) :scope current-scope))))
          (scope-error (condition)
            (setf captured condition)))
        (let ((causes (scope-error-causes captured)))
          (expect (length causes) :to-be 1)
          (expect (typep (first causes) (quote task-cancelled)) :to-be-truthy)
          (expect (eq (task-cancelled-scope (first causes)) scope) :to-be-truthy)))))
  (describe
    "scope cancellation internals"
    (it
      "cancels a child that registers after scope cancellation"
      (let ((scope (cl-concurrent-kit::%make-task-scope))
            (child (list nil))
            (cancelled nil))
        (cl-concurrent-kit::%scope-add-child scope child)
        (cl-concurrent-kit::%scope-cancel scope)
        (cl-concurrent-kit::%scope-set-child-cancel
          scope child (lambda () (setf cancelled t)))
        (expect cancelled :to-be-truthy)))
    (it
      "removes the child registration when direct thread creation fails"
      (let ((scope (cl-concurrent-kit::%make-task-scope))
            (original-make-thread
              (symbol-function (quote cl-concurrent-kit:make-thread))))
        (unwind-protect
            (progn
              (setf (symbol-function (quote cl-concurrent-kit:make-thread))
                    (lambda (&rest arguments)
                      (declare (ignore arguments))
                      (error "thread creation failed")))
              (signals simple-error
                (spawn scope (lambda () :never-runs)))
              (expect
                (hash-table-count
                  (cl-concurrent-kit::task-scope-children scope))
                :to-be
                0))
          (setf (symbol-function (quote cl-concurrent-kit:make-thread))
                original-make-thread))))))

(describe
  "scope timeout"
  (it
    "bounds cleanup while cancelling a still-running child"
    (let ((started (make-semaphore))
          (release (make-semaphore))
          (finished (make-semaphore)))
      (unwind-protect
          (progn
            (signals operation-timed-out
              (with-task-scope (scope :timeout 0.01)
                (spawn
                  scope
                  (lambda ()
                    (signal-semaphore started)
                    (wait-on-semaphore release)
                    (signal-semaphore finished)))
                (unless (wait-on-semaphore started :timeout 1)
                  (error "scope child did not start")))))
        (signal-semaphore release)
        (unless (wait-on-semaphore finished :timeout 1)
          (error "scope child did not finish"))))))
