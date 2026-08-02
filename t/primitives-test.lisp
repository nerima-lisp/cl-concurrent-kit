;;;; t/primitives-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe
  "threads"
  (it
    "runs its function on another thread and JOIN-THREAD returns its value"
    (let ((thread
          (make-thread
            (lambda ()
              (1+ 2)))))
      (expect (join-thread thread) :to-be 3)))
  (it
    "returns the name supplied to MAKE-THREAD"
    (let ((thread
          (make-thread
            (lambda ()
              :finished)
            :name
            "coverage-thread")))
      (expect (thread-name thread) :to-equal "coverage-thread")
      (join-thread thread)))
  (it
    "reports THREAD-ALIVE-P false once the thread function has returned"
    (let* ((lock (make-lock))
           (cv (make-condition-variable))
           (go-p nil)
           (thread
          (make-thread
            (lambda ()
              (with-lock-held
                (lock)
                (loop until go-p
                      do (condition-wait cv lock)))))))
      (expect (thread-alive-p thread) :to-be-truthy)
      (with-lock-held
        (lock)
        (setf go-p t)
        (condition-notify cv))
      (join-thread thread)
      (expect (thread-alive-p thread) :to-be nil)))
  (it "CURRENT-THREAD and THREAD-NAME identify the calling thread from within it"
    (let ((observed-thread nil)
          (observed-name nil))
      (join-thread
       (make-thread (lambda ()
                      (setf observed-thread (current-thread))
                      (setf observed-name (thread-name (current-thread))))
                    :name "cl-concurrent-kit primitives test thread"))
      (expect (thread-name observed-thread) :to-equal "cl-concurrent-kit primitives test thread")
      (expect observed-name :to-equal "cl-concurrent-kit primitives test thread"))))

(describe
  "locks"
  (it
    "serializes access so concurrent increments are not lost"
    (let ((lock (make-lock))
          (counter 0))
      (let ((threads
            (loop repeat 8
                  collect (make-thread
                (lambda ()
                  (dotimes (_ 1000)
                    (with-lock-held (lock) (incf counter))))))))
        (mapc #'join-thread threads))
      (expect counter :to-be 8000))))

(describe "the LOCK type"
  (it "is the type MAKE-LOCK returns"
    (expect (typep (make-lock) 'lock) :to-be-truthy))

  (it "is the type a named lock has too"
    (expect (typep (make-lock :name "cl-concurrent-kit lock type test") 'lock) :to-be-truthy))

  (it "rejects objects that are not locks"
    (expect (typep nil 'lock) :to-be nil)
    (expect (typep (make-semaphore) 'lock) :to-be nil)
    (expect (typep (make-condition-variable) 'lock) :to-be nil))

  (it "is usable in the DEFSTRUCT slot declaration consumers need it for"
    ;; The shape a consumer's optional-lock slot wants: declared without the
    ;; consumer naming SB-THREAD.
    (let ((slot-type '(or null lock)))
      (expect (typep (make-lock) slot-type) :to-be-truthy)
      (expect (typep nil slot-type) :to-be-truthy)
      (expect (typep :not-a-lock slot-type) :to-be nil))))

(describe
  "condition variables"
  (it
    "wakes a waiter via CONDITION-NOTIFY once the predicate holds"
    (let* ((lock (make-lock))
           (cv (make-condition-variable))
           (ready-p nil)
           (thread
             (make-thread
               (lambda ()
                 (with-lock-held
                   (lock)
                   (loop until ready-p
                         do (condition-wait cv lock))
                   :saw-it)))))
      (with-lock-held
        (lock)
        (setf ready-p t)
        (condition-notify cv))
      (expect (join-thread thread) :to-be :saw-it)))
  (it
    "CONDITION-WAIT returns NIL on timeout"
    (let ((lock (make-lock))
          (cv (make-condition-variable)))
      (with-lock-held
        (lock)
        (expect (condition-wait cv lock :timeout 0.05d0) :to-be nil)))))

(describe
  "semaphores"
  (it
    "blocks in WAIT-ON-SEMAPHORE until SIGNAL-SEMAPHORE"
    (let* ((semaphore (make-semaphore))
           (thread
          (make-thread
            (lambda ()
              (wait-on-semaphore semaphore)
              :woke))))
      (signal-semaphore semaphore)
      (expect (join-thread thread) :to-be :woke)))
  (it
    "WAIT-ON-SEMAPHORE returns NIL on timeout when never signaled"
    (let ((semaphore (make-semaphore)))
      (expect (wait-on-semaphore semaphore :timeout 0.05d0) :to-be nil))))

(describe
  "atomic counters"
  (it
    "starts at the given initial value"
    (expect (atomic-counter-value (make-atomic-counter 5)) :to-be 5))
  (it
    "ATOMIC-COUNTER-INCF/DECF are atomic under concurrent access from many threads"
    (let* ((counter (make-atomic-counter))
           (threads
          (loop repeat 8
                collect (make-thread
              (lambda ()
                (dotimes (_ 1000)
                  (atomic-counter-incf counter)))))))
      (mapc #'join-thread threads)
      (expect (atomic-counter-value counter) :to-be 8000)
      (let ((down-threads
            (loop repeat 8
                  collect (make-thread
                (lambda ()
                  (dotimes (_ 1000)
                    (atomic-counter-decf counter)))))))
        (mapc #'join-thread down-threads))
      (expect (atomic-counter-value counter) :to-be 0))))

(describe
  "additional primitive behavior"
  (it
    "accepts the supplied JOIN-THREAD default for a normally completed thread"
    (let ((thread
          (make-thread
            (lambda ()
              :completed))))
      (expect (join-thread thread :default :failed) :to-be :completed)))
  (it
    "uses MAKE-SEMAPHORE initial count as immediately available permits"
    (let ((semaphore (make-semaphore :count 2)))
      (expect (wait-on-semaphore semaphore :timeout 0.1d0) :to-be-truthy)
      (expect (wait-on-semaphore semaphore :timeout 0.1d0) :to-be-truthy)
      (expect (wait-on-semaphore semaphore :timeout 0.01d0) :to-be nil)))
  (it
    "wakes every condition-variable waiter after CONDITION-BROADCAST"
    (let* ((lock (make-lock))
           (condition-variable (make-condition-variable))
           (ready (make-semaphore))
           (release-p nil)
           (waiters
          (loop repeat 2
                collect (make-thread
              (lambda ()
                (with-lock-held
                  (lock)
                  (signal-semaphore ready)
                  (loop until release-p
                        do (condition-wait condition-variable lock))
                  :released))))))
      (expect (wait-on-semaphore ready :timeout 1) :to-be-truthy)
      (expect (wait-on-semaphore ready :timeout 1) :to-be-truthy)
      (with-lock-held
        (lock)
        (setf release-p t)
        (condition-broadcast condition-variable))
      (expect
        (mapcar (function join-thread) waiters)
        :to-equal
        (list :released :released))))
  (it
    "applies explicit deltas in atomic counter operations"
    (let ((counter (make-atomic-counter)))
      (atomic-counter-incf counter 3)
      (atomic-counter-decf counter 2)
      (expect (atomic-counter-value counter) :to-be 1))))
