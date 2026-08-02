;;;; t/stream-fan-in-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "channel-map-concurrent"
  (it "preserves input order in the output despite out-of-order completion"
    (let ((input (make-channel :buffer-size 3)))
      (send input 0.03) (send input 0.01) (send input 0.02)
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-map-concurrent 3 (lambda (delay) (sleep delay) delay) input)
        (expect (drain-channel output :timeout 2)
                :to-equal (list 0.03 0.01 0.02))
        (await completion :timeout 2))))

  (it "fails the completion promise when a worker's FUNCTION signals"
    (let ((input (make-channel :buffer-size 2)))
      (send input 1) (send input 2)
      (close-channel input)
      ;; OUTPUT needs a reader (or its own buffer): job 1's result is ready
      ;; to deliver before job 2's error is discovered, and an unread,
      ;; unbuffered OUTPUT would block that delivery forever, never
      ;; reaching -- let alone failing on -- job 2 at all.
      (multiple-value-bind (output completion)
          (channel-map-concurrent 2 (lambda (x) (when (= x 2) (error "boom")) x) input
                                   :buffer-size 2)
        (declare (ignore output))
        (signals error (await completion :timeout 2)))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion)
            (channel-map-concurrent 2 (function identity) input :scope scope)
          (expect (sort (drain-channel output :timeout 2) (function <))
                  :to-equal (list 1 2 3))
          (await completion :timeout 2)))))

  (it "bounds worker count by the EXECUTOR's own thread and queue capacity"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-executor (executor :size 2)
        (multiple-value-bind (output completion)
            (channel-map-concurrent 5 (lambda (x) (* x x)) input :executor executor)
          (expect (sort (drain-channel output :timeout 2) (function <))
                  :to-equal (list 1 4 9))
          (await completion :timeout 2)))))

  (it "fails the completion promise synchronously when a worker fails to start on an already shut-down EXECUTOR"
    (let ((input (make-channel))
          (executor (make-executor :size 1)))
      (shutdown-executor executor :wait t)
      (multiple-value-bind (output completion) (channel-map-concurrent 2 (function identity) input :executor executor)
        (signals executor-shut-down (await completion :timeout 1))
        (expect (nth-value 1 (recv output :timeout 1)) :to-be nil)))))

(describe "channel-map-unordered"
  (it "fails the completion promise when a worker's FUNCTION signals"
    (let ((input (make-channel :buffer-size 2)))
      (send input 1) (send input 2)
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-map-unordered 2 (lambda (x) (when (= x 2) (error "boom")) x) input
                                  :buffer-size 2)
        (declare (ignore output))
        (signals error (await completion :timeout 2)))))

  (it "emits results in completion order rather than input order"
    (let ((input (make-channel :buffer-size 2)))
      ;; The slower job (0.05s) is submitted first; with two workers running
      ;; concurrently, the faster (second, 0s) job should complete -- and so
      ;; be emitted -- first.
      (send input 0.05) (send input 0.0)
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-map-unordered 2 (lambda (delay) (sleep delay) delay) input)
        (expect (recv output :timeout 2) :to-be 0.0)
        (expect (recv output :timeout 2) :to-be 0.05)
        (await completion :timeout 2))))

  (it "emits the same set of results as its input, regardless of order"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 2 3 4)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-map-unordered 4 (lambda (x) (* x x)) input)
        (expect (sort (drain-channel output :timeout 2) (function <))
                :to-equal (list 1 4 9 16))
        (await completion :timeout 2))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion)
            (channel-map-unordered 2 (function identity) input :scope scope)
          (expect (sort (drain-channel output :timeout 2) (function <))
                  :to-equal (list 1 2 3))
          (await completion :timeout 2)))))

  (it "bounds worker count by the EXECUTOR's own thread and queue capacity"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-executor (executor :size 2)
        (multiple-value-bind (output completion)
            (channel-map-unordered 5 (lambda (x) (* x x)) input :executor executor)
          (expect (sort (drain-channel output :timeout 2) (function <))
                  :to-equal (list 1 4 9))
          (await completion :timeout 2)))))

  (it "fails the completion promise synchronously when a worker fails to start on an already shut-down EXECUTOR"
    (let ((input (make-channel))
          (executor (make-executor :size 1)))
      (shutdown-executor executor :wait t)
      (multiple-value-bind (output completion) (channel-map-unordered 2 (function identity) input :executor executor)
        (signals executor-shut-down (await completion :timeout 1))
        (expect (nth-value 1 (recv output :timeout 1)) :to-be nil)))))

(describe "channel-merge"
  (it "forwards every value from every input, preserving each input's own order"
    (let ((a (make-channel :buffer-size 2))
          (b (make-channel :buffer-size 2)))
      (send a 1) (send a 2) (close-channel a)
      (send b :x) (send b :y) (close-channel b)
      (multiple-value-bind (output completion) (channel-merge (list a b))
        (let ((received (drain-channel output :timeout 1)))
          (expect (sort (remove-if-not (function numberp) received) (function <)) :to-equal (list 1 2))
          (expect (remove-if-not (function keywordp) received) :to-equal (list :x :y)))
        (await completion :timeout 1))))

  (it "closes the output only once every input is closed and drained"
    (let ((a (make-channel :buffer-size 1))
          (b (make-channel :buffer-size 1)))
      (send a :only)
      (close-channel a)
      (multiple-value-bind (output completion) (channel-merge (list a b))
        (expect (recv output :timeout 1) :to-be :only)
        (signals operation-timed-out (recv output :timeout 0.05))
        (close-channel b)
        (expect (nth-value 1 (recv output :timeout 1)) :to-be nil)
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((a (make-channel :buffer-size 2))
          (b (make-channel :buffer-size 2)))
      (send a 1) (send a 2) (close-channel a)
      (close-channel b)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-merge (list a b) :scope scope)
          (expect (sort (drain-channel output :timeout 1) (function <))
                  :to-equal (list 1 2))
          (await completion :timeout 1))))))

(describe "channel-zip"
  (it "combines one value from every input into ordered tuples"
    (let ((a (make-channel :buffer-size 2))
          (b (make-channel :buffer-size 2)))
      (dolist (x (list 1 2)) (send a x))
      (dolist (x (list :a :b)) (send b x))
      (close-channel a)
      (close-channel b)
      (multiple-value-bind (output completion) (channel-zip (list a b))
        (expect (drain-channel output :timeout 1)
                :to-equal (list (list 1 :a) (list 2 :b)))
        (await completion :timeout 1))))

  (it "stops at the shortest input"
    (let ((a (make-channel :buffer-size 3))
          (b (make-channel :buffer-size 1)))
      (dolist (x (list 1 2 3)) (send a x))
      (send b :only)
      (close-channel a)
      (close-channel b)
      (multiple-value-bind (output completion) (channel-zip (list a b))
        (expect (drain-channel output :timeout 1)
                :to-equal (list (list 1 :only)))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((a (make-channel :buffer-size 2))
          (b (make-channel :buffer-size 2)))
      (dolist (x (list 1 2)) (send a x))
      (dolist (x (list :a :b)) (send b x))
      (close-channel a)
      (close-channel b)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-zip (list a b) :scope scope)
          (expect (drain-channel output :timeout 1)
                  :to-equal (list (list 1 :a) (list 2 :b)))
          (await completion :timeout 1))))))

(describe "channel-concat"
  (it "drains each channel fully, in collection order, before the next"
    (let ((a (make-channel :buffer-size 2))
          (b (make-channel :buffer-size 2)))
      (send a 1) (send a 2) (close-channel a)
      (send b 3) (send b 4) (close-channel b)
      (multiple-value-bind (output completion) (channel-concat (list a b))
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 2 3 4))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((a (make-channel :buffer-size 2))
          (b (make-channel :buffer-size 2)))
      (send a 1) (send a 2) (close-channel a)
      (send b 3) (send b 4) (close-channel b)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-concat (list a b) :scope scope)
          (expect (drain-channel output :timeout 1)
                  :to-equal (list 1 2 3 4))
          (await completion :timeout 1))))))

(describe "channel-concat-map"
  (it "applies FUNCTION and drains each returned channel fully before the next value"
    (let ((input (make-channel :buffer-size 2)))
      (send input 1) (send input 2)
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-concat-map (lambda (x) (nth-value 0 (channel-from-sequence (list x (* x 10))))) input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 10 2 20))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 2)))
      (send input 1) (send input 2)
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion)
            (channel-concat-map (lambda (x) (nth-value 0 (channel-from-sequence (list x (* x 10)))))
                                 input :scope scope)
          (expect (drain-channel output :timeout 1)
                  :to-equal (list 1 10 2 20))
          (await completion :timeout 1))))))

(describe "channel-merge-map"
  (it "merges values from every inner channel FUNCTION returns"
    (let ((input (make-channel :buffer-size 2)))
      (send input (list 1 2))
      (send input (list 3 4))
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-merge-map (lambda (xs) (nth-value 0 (channel-from-sequence xs))) input :parallelism 2)
        (expect (sort (drain-channel output :timeout 1) (function <))
                :to-equal (list 1 2 3 4))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 2)))
      (send input (list 1 2))
      (send input (list 3 4))
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion)
            (channel-merge-map (lambda (xs) (nth-value 0 (channel-from-sequence xs))) input
                                :parallelism 2 :scope scope)
          (expect (sort (drain-channel output :timeout 1) (function <))
                  :to-equal (list 1 2 3 4))
          (await completion :timeout 1))))))

(describe "channel-switch-map"
  (it "forwards only the most recently returned inner channel's values"
    ;; Both inner channels are already queued on INPUT before the stage
    ;; starts, and neither has a value yet -- so the switch to SECOND-INNER
    ;; is guaranteed to happen before FIRST-INNER ever has anything to
    ;; offer, with no race between "switch" and "first-inner produces a
    ;; value" to resolve.
    (let ((input (make-channel :buffer-size 2))
          (first-inner (make-channel :buffer-size 1))
          (second-inner (make-channel :buffer-size 1)))
      (send input first-inner)
      (send input second-inner)
      (close-channel input)
      (multiple-value-bind (output completion) (channel-switch-map (function identity) input)
        (declare (ignore completion))
        (send second-inner :from-second)
        (expect (recv output :timeout 1) :to-be :from-second)
        ;; FIRST-INNER was switched away from before it ever produced a
        ;; value; sent even now, it should never reach OUTPUT.
        (send first-inner :from-first)
        (signals operation-timed-out (recv output :timeout 0.1)))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 1))
          (inner (make-channel :buffer-size 1)))
      (send input inner)
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-switch-map (function identity) input :scope scope)
          (send inner :value)
          (close-channel inner)
          (expect (recv output :timeout 1) :to-be :value)
          (await completion :timeout 1))))))
