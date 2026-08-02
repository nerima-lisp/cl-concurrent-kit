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
            (wait-or-fail started "executor worker did not start")
            (setf shutdown-thread
                  (make-thread
                   (lambda ()
                     (shutdown-executor executor :wait t)
                     (signal-semaphore shutdown-finished))))
            (expect (wait-on-semaphore shutdown-finished :timeout 0.05) :to-be nil)
            (signal-semaphore release)
            (wait-or-fail shutdown-finished "shutdown did not wait for the active task")
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
          (ran-p nil)
          release)
      (unwind-protect
          (progn
            (setf release (occupy-worker executor))
            (let ((result (submit executor (lambda () (setf ran-p t)))))
              (shutdown-executor executor :cancel-pending t)
              (expect-signals (condition executor-shut-down) (await result :timeout 1) (expect (eq (executor-shut-down-executor condition) executor) :to-be-truthy))
              (expect ran-p :to-be nil)))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t))))
  (it
    "rejects every task detached from the pending queue"
    (let ((executor (make-executor :size 1))
          (ran 0)
          release)
      (unwind-protect
          (let (results)
            (setf release (occupy-worker executor))
            (setf results (loop repeat 8 collect (submit executor (lambda () (incf ran)))))
            (shutdown-executor executor :cancel-pending t)
            (dolist (result results)
              (signals executor-shut-down (await result :timeout 1)))
            (expect ran :to-be 0))
        (when release (signal-semaphore release))
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
          (expect-signals (condition executor-shut-down) (await result :timeout 1) (expect (eq (executor-shut-down-executor condition) executor) :to-be-truthy))
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
              (wait-or-fail started "executor worker did not start")
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
            (expect (wait-on-semaphore stopped :timeout 1) :to-be-truthy))
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
            (wait-or-fail started "executor worker did not start")
            (signals operation-timed-out
              (shutdown-executor executor :wait t :timeout 0.01))
            (expect
              (thread-alive-p
                (first (cl-concurrent-kit::executor-threads executor)))
              :to-be-truthy))
        (signal-semaphore release)
        (wait-or-fail finished "executor worker did not finish")
        (shutdown-executor executor :wait t :timeout 1)))))

(describe "executor observability"
  (it "reports EXECUTOR-SHUTDOWN-P and EXECUTOR-TERMINATED-P across their lifecycle"
    (let ((executor (make-executor :size 1)))
      (expect (executor-shutdown-p executor) :to-be nil)
      (expect (executor-terminated-p executor) :to-be nil)
      (shutdown-executor executor :wait t :timeout 1)
      (expect (executor-shutdown-p executor) :to-be-truthy)
      (expect (executor-terminated-p executor) :to-be-truthy)))

  (it "reports EXECUTOR-QUEUE-CAPACITY as NIL for the default unbounded executor"
    (let ((executor (make-executor :size 1)))
      (unwind-protect
          (expect (executor-queue-capacity executor) :to-be nil)
        (shutdown-executor executor :wait t :timeout 1))))

  (it "tracks EXECUTOR-QUEUE-DEPTH and EXECUTOR-HIGH-WATER-MARK as tasks queue and drain"
    (let ((executor (make-executor :size 1))
          (queued (make-semaphore))
          release)
      (unwind-protect
          (progn
            ;; OCCUPY-WORKER's own confirmation that the sole worker has
            ;; actually claimed this task matters here specifically: without
            ;; it, all three tasks could still be sitting in the queue
            ;; together when a slow-to-schedule worker thread finally
            ;; starts, making the peak depth below 3 rather than the 2 this
            ;; asserts.
            (setf release (occupy-worker executor))
            (submit executor (lambda () (signal-semaphore queued)))
            (submit executor (lambda () (signal-semaphore queued)))
            (loop until (>= (executor-queue-depth executor) 2) do (sleep 0.001))
            (expect (executor-queue-depth executor) :to-be 2)
            (expect (executor-high-water-mark executor) :to-be 2)
            (signal-semaphore release)
            (wait-or-fail queued "first queued task did not run")
            (wait-or-fail queued "second queued task did not run")
            (loop until (zerop (executor-queue-depth executor)) do (sleep 0.001))
            (expect (executor-queue-depth executor) :to-be 0)
            (expect (executor-high-water-mark executor) :to-be 2))
        ;; Unblock the first task even if an EXPECT above failed and
        ;; unwound before its own (SIGNAL-SEMAPHORE RELEASE) ran -- an extra
        ;; signal here is harmless once the happy path already consumed the
        ;; first one, but skipping it entirely would leave the worker
        ;; blocked forever and SHUTDOWN-EXECUTOR :WAIT T below hanging with
        ;; it instead of reporting the real EXPECT failure. RELEASE can also
        ;; still be NIL here, if OCCUPY-WORKER's own guard is what unwound
        ;; this form.
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t :timeout 1))))

  (it "grows an unbounded queue's ring buffer past its initial capacity"
    (let ((executor (make-executor :size 1))
          (ran 0)
          release)
      (unwind-protect
          (progn
            (setf release (occupy-worker executor))
            (dotimes (i 100) (declare (ignore i)) (submit executor (lambda () (incf ran))))
            (expect (executor-queue-depth executor) :to-be 100)
            (signal-semaphore release)
            (loop until (zerop (executor-queue-depth executor)) do (sleep 0.001))
            (expect ran :to-be 100))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t :timeout 1)))))

(describe "bounded executor queue"
  (it "reports the configured EXECUTOR-QUEUE-CAPACITY"
    (let ((executor (make-executor :size 1 :queue-capacity 2)))
      (unwind-protect
          (expect (executor-queue-capacity executor) :to-be 2)
        (shutdown-executor executor :wait t :timeout 1))))

  (it "rejects SUBMIT once the queue is full, settling the promise with EXECUTOR-QUEUE-FULL"
    (let ((executor (make-executor :size 1 :queue-capacity 1))
          release)
      (unwind-protect
          (progn
            ;; See the TRY-SUBMIT test below for why OCCUPY-WORKER's own
            ;; confirmation matters here: it is what stands between task1
            ;; actually occupying the sole worker and merely being queued
            ;; alongside task2.
            (setf release (occupy-worker executor))
            (submit executor (lambda () nil))
            (loop until (= (executor-queue-depth executor) 1) do (sleep 0.001))
            (let ((rejected (submit executor (lambda () nil))))
              (expect-signals (condition executor-queue-full) (await rejected :timeout 1)
                (expect (eq (executor-queue-full-executor condition) executor) :to-be-truthy)
                (expect (executor-queue-full-capacity condition) :to-be 1))))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t :timeout 1))))

  (it "TRY-SUBMIT returns ACCEPTED-P false instead of a rejected promise's condition"
    (let ((executor (make-executor :size 1 :queue-capacity 1))
          release)
      (unwind-protect
          (progn
            ;; OCCUPY-WORKER's own confirmation that the sole worker has
            ;; actually claimed task1 matters here specifically: without it,
            ;; submitting task2 next could lose the race for the one
            ;; capacity slot task1 still occupies while merely queued (not
            ;; yet claimed), get silently rejected, and leave nothing to
            ;; ever bring EXECUTOR-QUEUE-DEPTH back to 1 for the unbounded
            ;; loop below to observe.
            (setf release (occupy-worker executor))
            (submit executor (lambda () nil))
            (loop until (= (executor-queue-depth executor) 1) do (sleep 0.001))
            (multiple-value-bind (promise accepted-p) (try-submit executor (lambda () nil))
              (expect accepted-p :to-be nil)
              (signals executor-queue-full (await promise :timeout 1))))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t :timeout 1))))

  (it "TRY-SUBMIT returns ACCEPTED-P true when there is room"
    (let ((executor (make-executor :size 1 :queue-capacity 4)))
      (unwind-protect
          (multiple-value-bind (promise accepted-p) (try-submit executor (lambda () :ok))
            (expect accepted-p :to-be-truthy)
            (expect (await promise :timeout 1) :to-be :ok))
        (shutdown-executor executor :wait t :timeout 1)))))

(describe "await-executor-termination"
  (it "blocks until every worker has exited after shutdown"
    (let ((executor (make-executor :size 2)))
      (shutdown-executor executor)
      (await-executor-termination executor :timeout 1)
      (expect (executor-terminated-p executor) :to-be-truthy)))

  (it "signals EXECUTOR-SHUT-DOWN rather than joining the current worker"
    (let ((executor (make-executor :size 1))
          (observed-p nil))
      (unwind-protect
          (let ((task (submit executor
                               (lambda ()
                                 (handler-case (await-executor-termination executor :timeout 1)
                                   (executor-shut-down () (setf observed-p t)))))))
            (shutdown-executor executor)
            (await task :timeout 1)
            (expect observed-p :to-be-truthy))
        (shutdown-executor executor :wait t :timeout 1)))))

(describe "with-executor"
  (it "returns BODY's values and shuts the executor down once BODY returns"
    (let ((executor-from-body nil))
      (expect (with-executor (executor :size 2)
                (setf executor-from-body executor)
                :the-result)
              :to-be :the-result)
      (expect (executor-terminated-p executor-from-body) :to-be-truthy)))

  (it "waits for already-queued work to finish rather than cancelling it"
    (let ((ran-p nil))
      (with-executor (executor :size 1)
        (submit executor (lambda () (sleep 0.02) (setf ran-p t))))
      (expect ran-p :to-be-truthy)))

  (it "still shuts the executor down when BODY signals"
    (let ((executor-from-body nil))
      (signals simple-error
        (with-executor (executor :size 1)
          (setf executor-from-body executor)
          (error "boom in body")))
      (expect (executor-terminated-p executor-from-body) :to-be-truthy))))

(describe "executor-map"
  (it "returns results in input order once every call has fulfilled"
    (with-executor (executor :size 3)
      (expect (executor-map executor (lambda (x) (* x x)) (list 1 2 3 4 5))
              :to-equal (list 1 4 9 16 25))))

  (it "bounds concurrency to MAX-IN-FLIGHT"
    (with-executor (executor :size 8)
      (let ((in-flight 0)
            (max-observed 0)
            (lock (make-lock)))
        (executor-map executor
                       (lambda (x)
                         (declare (ignore x))
                         (with-lock-held (lock)
                           (incf in-flight)
                           (setf max-observed (max max-observed in-flight)))
                         (sleep 0.02)
                         (with-lock-held (lock) (decf in-flight)))
                       (list 1 2 3 4 5 6)
                       :max-in-flight 2)
        (expect (<= max-observed 2) :to-be-truthy))))

  (it "propagates the first in-order failure once every submitted call has settled"
    (with-executor (executor :size 4)
      (signals simple-error
        (executor-map executor
                       (lambda (x) (when (= x 2) (error "boom")) x)
                       (list 1 2 3))))))
