;;;; t/primitives-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "threads"
  (it "runs its function on another thread and JOIN-THREAD returns its value"
    (let ((thread (make-thread (lambda () (+ 1 2)))))
      (expect (join-thread thread) :to-be 3)))

  (it "reports THREAD-ALIVE-P false once the thread's function has returned"
    (let* ((lock (make-lock))
           (cv (make-condition-variable))
           (go-p nil)
           (thread (make-thread
                    (lambda ()
                      (with-lock-held (lock)
                        (loop until go-p do (condition-wait cv lock)))))))
      (expect (thread-alive-p thread) :to-be-truthy)
      (with-lock-held (lock)
        (setf go-p t)
        (condition-notify cv))
      (join-thread thread)
      (expect (thread-alive-p thread) :to-be nil))))

(describe "locks"
  (it "serializes access so concurrent increments are not lost"
    (let ((lock (make-lock))
          (counter 0))
      (let ((threads (loop repeat 8
                            collect (make-thread
                                     (lambda ()
                                       (dotimes (_ 1000)
                                         (with-lock-held (lock)
                                           (incf counter))))))))
        (mapc #'join-thread threads))
      (expect counter :to-be 8000))))

(describe "condition variables"
  (it "wakes a waiter via CONDITION-NOTIFY once the predicate holds"
    (let* ((lock (make-lock))
           (cv (make-condition-variable))
           (ready-p nil)
           (thread (make-thread
                    (lambda ()
                      (with-lock-held (lock)
                        (loop until ready-p do (condition-wait cv lock))
                        :saw-it)))))
      (with-lock-held (lock)
        (setf ready-p t)
        (condition-notify cv))
      (expect (join-thread thread) :to-be :saw-it)))

  (it "CONDITION-WAIT returns NIL, without reacquiring the lock, on timeout"
    (let ((lock (make-lock))
          (cv (make-condition-variable)))
      (with-lock-held (lock)
        (expect (condition-wait cv lock :timeout 0.05d0) :to-be nil)))))

(describe "semaphores"
  (it "blocks in WAIT-ON-SEMAPHORE until SIGNAL-SEMAPHORE"
    (let* ((semaphore (make-semaphore))
           (thread (make-thread (lambda () (wait-on-semaphore semaphore) :woke))))
      (signal-semaphore semaphore)
      (expect (join-thread thread) :to-be :woke)))

  (it "WAIT-ON-SEMAPHORE returns NIL on timeout when never signaled"
    (let ((semaphore (make-semaphore)))
      (expect (wait-on-semaphore semaphore :timeout 0.05d0) :to-be nil))))

(describe "atomic counters"
  (it "starts at the given initial value"
    (expect (atomic-counter-value (make-atomic-counter 5)) :to-be 5))

  (it "ATOMIC-COUNTER-INCF/DECF are atomic under concurrent access from many threads"
    (let* ((counter (make-atomic-counter))
           (threads (loop repeat 8
                           collect (make-thread
                                    (lambda () (dotimes (_ 1000) (atomic-counter-incf counter)))))))
      (mapc #'join-thread threads)
      (expect (atomic-counter-value counter) :to-be 8000)
      (let ((down-threads (loop repeat 8
                                 collect (make-thread
                                          (lambda () (dotimes (_ 1000) (atomic-counter-decf counter)))))))
        (mapc #'join-thread down-threads))
      (expect (atomic-counter-value counter) :to-be 0))))
