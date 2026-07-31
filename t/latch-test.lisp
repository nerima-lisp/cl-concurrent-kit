;;;; t/latch-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "countdown latch"
  (it "is already open when created with a zero count"
    (let ((latch (make-countdown-latch 0)))
      (expect (await-latch latch :timeout 1) :to-be-truthy)))

  (it "opens once its count reaches zero and reports the remaining count"
    (let ((latch (make-countdown-latch 2)))
      (expect (count-down latch) :to-be 1)
      (expect (count-down latch) :to-be 0)
      (expect (await-latch latch :timeout 1) :to-be-truthy)))

  (it "accepts a DECREMENT greater than one"
    (let ((latch (make-countdown-latch 3)))
      (expect (count-down latch 3) :to-be 0)
      (expect (await-latch latch :timeout 1) :to-be-truthy)))

  (it "signals LATCH-COUNT-UNDERFLOW rather than going negative"
    (let ((latch (make-countdown-latch 1)))
      (signals latch-count-underflow (count-down latch 2))
      (expect (countdown-latch-count latch) :to-be 1)))

  (it "wakes a blocked AWAIT-LATCH once COUNT-DOWN reaches zero"
    (let ((latch (make-countdown-latch 1))
          (opened (make-semaphore)))
      (let ((waiter (future
                       (await-latch latch :timeout 1)
                       (signal-semaphore opened))))
        (expect (wait-on-semaphore opened :timeout 0.05) :to-be nil)
        (count-down latch)
        (expect (wait-on-semaphore opened :timeout 1) :to-be-truthy)
        (await waiter :timeout 1))))

  (it "signals OPERATION-TIMED-OUT when it does not open in time"
    (let ((latch (make-countdown-latch 1)))
      (signals operation-timed-out (await-latch latch :timeout 0.01))))

  (it "signals TASK-CANCELLED when its SCOPE is cancelled first"
    (let ((latch (make-countdown-latch 1))
          (cancelled-p nil))
      (handler-case
          (with-task-scope (scope)
            (spawn scope (lambda () (error "boom")))
            (handler-case (await-latch latch :timeout 1 :scope scope)
              (task-cancelled () (setf cancelled-p t))))
        (scope-error () nil))
      (expect cancelled-p :to-be-truthy)))

  (it "signals TASK-CANCELLED immediately when its SCOPE is already cancelled before the call"
    (let ((latch (make-countdown-latch 1))
          (scope (cl-concurrent-kit::%make-task-scope)))
      (cl-concurrent-kit::%scope-cancel scope)
      (signals task-cancelled (await-latch latch :timeout 1 :scope scope)))))

(describe "barrier"
  (it "releases every party once PARTIES have arrived, 0 to the last"
    (let ((barrier (make-barrier 3))
          (results (list))
          (lock (make-lock)))
      (let ((parties
              (loop repeat 3
                    collect (future
                              (let ((index (await-barrier barrier :timeout 1)))
                                (with-lock-held (lock) (push index results)))))))
        (dolist (party parties) (await party :timeout 1))
        (expect (sort results (function <)) :to-equal (list 0 1 2)))))

  (it "reports BARRIER-PARTIES and a BARRIER-NUMBER-WAITING snapshot"
    (let ((barrier (make-barrier 2))
          (arrived (make-semaphore)))
      (expect (barrier-parties barrier) :to-be 2)
      (let ((waiter (future
                       (signal-semaphore arrived)
                       (await-barrier barrier :timeout 1))))
        (wait-or-fail arrived "party did not start")
        (loop until (plusp (barrier-number-waiting barrier)) do (sleep 0.001))
        (expect (barrier-number-waiting barrier) :to-be 1)
        (await-barrier barrier :timeout 1)
        (await waiter :timeout 1))))

  (it "starts a fresh generation once the previous one releases"
    (let ((barrier (make-barrier 2)))
      (let ((first
              (loop repeat 2 collect (future (await-barrier barrier :timeout 1)))))
        (dolist (party first) (await party :timeout 1)))
      (let ((second
              (loop repeat 2 collect (future (await-barrier barrier :timeout 1)))))
        (dolist (party second) (expect (await party :timeout 1) :to-be-truthy)))))

  (it "breaks the generation and signals BARRIER-BROKEN on timeout"
    ;; Three parties are required; only the sibling and this thread arrive,
    ;; so this thread's own AWAIT-BARRIER genuinely never sees the third and
    ;; times out for real -- with just two parties total, the second arrival
    ;; would always complete the barrier instead.
    (let ((barrier (make-barrier 3))
          (sibling-ready (make-semaphore))
          (sibling-broken-p nil))
      (let ((sibling
              (future
                (signal-semaphore sibling-ready)
                (handler-case (await-barrier barrier :timeout 1)
                  (barrier-broken () (setf sibling-broken-p t))))))
        (wait-or-fail sibling-ready "sibling did not start")
        (loop until (plusp (barrier-number-waiting barrier)) do (sleep 0.001))
        (signals operation-timed-out (await-barrier barrier :timeout 0.01))
        (await sibling :timeout 1)
        (expect sibling-broken-p :to-be-truthy)
        (expect (barrier-broken-p barrier) :to-be-truthy))))

  (it "signals TASK-CANCELLED and breaks the barrier when its SCOPE is cancelled"
    (let ((barrier (make-barrier 2))
          (cancelled-p nil))
      (handler-case
          (with-task-scope (scope)
            (spawn scope (lambda () (error "boom")))
            (handler-case (await-barrier barrier :timeout 1 :scope scope)
              (task-cancelled () (setf cancelled-p t))))
        (scope-error () nil))
      (expect cancelled-p :to-be-truthy)
      (expect (barrier-broken-p barrier) :to-be-truthy)))

  (it "permits a fresh generation again after RESET-BARRIER"
    (let ((barrier (make-barrier 2)))
      (signals operation-timed-out (await-barrier barrier :timeout 0.01))
      (expect (barrier-broken-p barrier) :to-be-truthy)
      (reset-barrier barrier)
      (expect (barrier-broken-p barrier) :to-be nil)
      (let ((parties (loop repeat 2 collect (future (await-barrier barrier :timeout 1)))))
        (dolist (party parties) (expect (await party :timeout 1) :to-be-truthy)))))

  (it "signals BARRIER-BROKEN immediately when already broken before the call"
    (let ((barrier (make-barrier 2)))
      (signals operation-timed-out (await-barrier barrier :timeout 0.01))
      (expect (barrier-broken-p barrier) :to-be-truthy)
      (signals barrier-broken (await-barrier barrier :timeout 1))
      (expect (barrier-broken-p barrier) :to-be-truthy))))
