;;;; t/executor-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "executor"
  (it "recognizes EXECUTOR values and runs a submitted thunk"
  (let ((executor (make-executor :size 2)))
    (unwind-protect
         (progn
           (expect (executor-p executor) :to-be-truthy)
           (expect (executor-p :not-an-executor) :to-be nil)
           (expect (await (submit executor (lambda () (* 6 7)))) :to-be 42))
      (shutdown-executor executor :wait t))))

  (it "propagates an error from the thunk to AWAIT"
    (let* ((executor (make-executor :size 2))
           (result (submit executor (lambda () (error "task failure")))))
      (signals error (await result))
      (shutdown-executor executor :wait t)))

  (it "runs many submitted tasks across a small worker pool"
    (let* ((executor (make-executor :size 3))
           ;; LOOPs numeric FOR mutates one binding of I in place rather than
           ;; making a fresh one per iteration, so each closure must capture
           ;; its own copy via LET or every task would square whatever I had
           ;; reached (usually 21) by the time a worker got to it.
           (promises (loop for i from 1 to 20 collect (let ((i i)) (submit executor (lambda () (* i i)))))))
      (expect (loop for i from 1 to 20 for p in promises always (= (await p) (* i i)))
              :to-be-truthy)
      (shutdown-executor executor :wait t)))

  (it "still runs tasks queued before SHUTDOWN-EXECUTOR is called"
    (let* ((executor (make-executor :size 1))
           (result (submit executor (lambda () :queued-before-shutdown))))
      (shutdown-executor executor :wait t)
      (expect (await result) :to-be :queued-before-shutdown)))

  (it "waits for active work when shutdown is requested with WAIT"
    (let ((executor (make-executor :size 1))
          (started (make-semaphore))
          (release (make-semaphore))
          (shutdown-finished (make-semaphore))
          (result nil)
          (shutdown-thread nil))
      (unwind-protect
          (progn
            (setf result
                  (submit executor
                          (lambda ()
                            (signal-semaphore started)
                            (wait-on-semaphore release)
                            :completed)))
            (unless (wait-on-semaphore started :timeout 1)
              (error "executor worker did not start"))
            (setf shutdown-thread
                  (make-thread
                   (lambda ()
                     (shutdown-executor executor :wait t)
                     (signal-semaphore shutdown-finished))))
            (expect (wait-on-semaphore shutdown-finished :timeout 0.05) :to-be nil)
            (signal-semaphore release)
            (unless (wait-on-semaphore shutdown-finished :timeout 1)
              (error "shutdown did not wait for the active task"))
            (expect (await result :timeout 1) :to-be :completed)
            (join-thread shutdown-thread)
            (setf shutdown-thread nil))
        (signal-semaphore release)
        (when shutdown-thread
          (join-thread shutdown-thread))
        (shutdown-executor executor :wait t)))))

(describe
  "executor shutdown"
  (it
    "exposes the executor when cancellation rejects queued work"
    (let ((executor (make-executor :size 1))
          (started (make-semaphore))
          (release (make-semaphore))
          (ran-p nil))
      (unwind-protect (progn
          (submit
            executor
            (lambda ()
              (signal-semaphore started)
              (wait-on-semaphore release)))
          (unless (wait-on-semaphore started :timeout 1)
            (error "executor worker did not start"))
          (let ((result
                (submit
                  executor
                  (lambda ()
                    (setf ran-p t)))))
            (shutdown-executor executor :cancel-pending t)
            (handler-case (progn
                (await result :timeout 1)
                (error "cancelled task should have failed"))
              (executor-shut-down (condition)
                (expect (eq (executor-shut-down-executor condition) executor) :to-be-truthy)))
            (expect ran-p :to-be nil)))
        (signal-semaphore release)
        (shutdown-executor executor :wait t))))
  (it
    "rejects every task detached from the pending queue"
    (let ((executor (make-executor :size 1))
          (started (make-semaphore))
          (release (make-semaphore))
          (ran 0))
      (unwind-protect (progn
          (submit
            executor
            (lambda ()
              (signal-semaphore started)
              (wait-on-semaphore release)))
          (unless (wait-on-semaphore started :timeout 1)
            (error "executor worker did not start"))
          (let ((results
                (loop repeat 8
                      collect (submit
                    executor
                    (lambda ()
                      (incf ran))))))
            (shutdown-executor executor :cancel-pending t)
            (dolist (result results)
              (signals executor-shut-down (await result :timeout 1)))
            (expect ran :to-be 0)))
        (signal-semaphore release)
        (shutdown-executor executor :wait t))))
  (it
    "settles submissions made after shutdown"
    (let ((executor (make-executor :size 1)))
      (shutdown-executor executor :wait t)
      (signals
        executor-shut-down
        (await
          (submit
            executor
            (lambda ()
              :never-runs))
          :timeout
          1)))))

(describe
  "executor worker safety"
  (it
    "signals EXECUTOR-SHUT-DOWN rather than joining the current worker"
    (let ((executor (make-executor :size 1)))
      (unwind-protect (let ((result
              (submit
                executor
                (lambda ()
                  (shutdown-executor executor :wait t)))))
          (handler-case (progn
              (await result :timeout 1)
              (error "worker shutdown should signal EXECUTOR-SHUT-DOWN"))
            (executor-shut-down (condition)
              (expect (eq (executor-shut-down-executor condition) executor) :to-be-truthy)))
          (shutdown-executor executor :wait t))
        (shutdown-executor executor :wait t)))))

(progn
  (progn
    (describe
      "executor worker liveness"
      (it
        "continues after a promise observer signals an error"
        (let ((executor (make-executor :size 1))
              (started (make-semaphore))
              (release (make-semaphore)))
          (unwind-protect (progn
              (submit
                executor
                (lambda ()
                  (signal-semaphore started)
                  (wait-on-semaphore release)))
              (unless (wait-on-semaphore started :timeout 1)
                (error "executor worker did not start"))
              (let ((watched
                    (submit
                      executor
                      (lambda ()
                        :watched))))
                (cl-concurrent-kit::%observe-promise
                  watched
                  (lambda (state outcome)
                    (declare (ignore state outcome))
                    (error "observer failure")))
                (signal-semaphore release)
                (expect (await watched :timeout 1) :to-be :watched)
                (expect
                  (await
                    (submit
                      executor
                      (lambda ()
                        :after-observer))
                    :timeout
                    1)
                  :to-be
                  :after-observer)))
            (signal-semaphore release)
            (shutdown-executor executor :wait t))))
      (it
        "continues after an on-settle callback signals an error"
        (let ((executor (make-executor :size 1)))
          (unwind-protect (progn
              (multiple-value-bind (promise task) (cl-concurrent-kit::%submit
                  executor
                  (lambda ()
                    :settled)
                  :on-settle
                  (lambda (state outcome)
                    (declare (ignore state outcome))
                    (error "on-settle failure")))
                (declare (ignore task))
                (expect (await promise :timeout 1) :to-be :settled))
              (expect
                (await
                  (submit
                    executor
                    (lambda ()
                      :after-on-settle))
                  :timeout
                  1)
                :to-be
                :after-on-settle))
            (shutdown-executor executor :wait t)))))
    (describe
      "executor task transition"
      (it
        "runs a contested pending task exactly once"
        (let* ((promise (make-promise))
               (runs 0)
               (start (make-semaphore))
               (task
              (cl-concurrent-kit::%make-executor-task
                (lambda ()
                  (incf runs)
                  :ran)
                promise
                nil))
               (first
              (make-thread
                (lambda ()
                  (wait-on-semaphore start)
                  (cl-concurrent-kit::%executor-task-run task))))
               (second
              (make-thread
                (lambda ()
                  (wait-on-semaphore start)
                  (cl-concurrent-kit::%executor-task-run task)))))
          (signal-semaphore start 2)
          (join-thread first)
          (join-thread second)
          (expect runs :to-be 1)
          (expect (await promise :timeout 1) :to-be :ran)))))
  (describe
    "executor creation"
    (it
      "stops workers started before a later worker creation failure"
      (let ((original-make-thread (symbol-function (quote cl-concurrent-kit:make-thread)))
            (calls 0)
            (stopped (make-semaphore)))
        (unwind-protect (progn
            (setf (symbol-function (quote cl-concurrent-kit:make-thread)) (lambda (function &key name arguments)
                (incf calls)
                (if (= calls 2) (error "thread creation failed")
                  (funcall
                    original-make-thread
                    (lambda ()
                      (unwind-protect (apply function arguments)
                        (signal-semaphore stopped)))
                    :name
                    name))))
            (signals simple-error (make-executor :size 2))
            (expect (wait-on-semaphore stopped :timeout 1) :to-be t))
          (setf (symbol-function (quote cl-concurrent-kit:make-thread)) original-make-thread))))))

(describe
  "executor shutdown timeout"
  (it
    "bounds the total worker join duration"
    (let ((executor (make-executor :size 1))
          (started (make-semaphore))
          (release (make-semaphore))
          (finished (make-semaphore)))
      (unwind-protect
          (progn
            (submit
              executor
              (lambda ()
                (signal-semaphore started)
                (wait-on-semaphore release)
                (signal-semaphore finished)))
            (unless (wait-on-semaphore started :timeout 1)
              (error "executor worker did not start"))
            (signals operation-timed-out
              (shutdown-executor executor :wait t :timeout 0.01))
            (expect
              (thread-alive-p
                (first (cl-concurrent-kit::executor-threads executor)))
              :to-be-truthy))
        (signal-semaphore release)
        (unless (wait-on-semaphore finished :timeout 1)
          (error "executor worker did not finish"))
        (shutdown-executor executor :wait t :timeout 1)))))
