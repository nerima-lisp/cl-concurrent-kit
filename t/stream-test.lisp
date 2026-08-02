;;;; t/stream-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "channel-producer"
  (it "sends every value BODY emits through EMIT, then closes"
    (multiple-value-bind (output completion)
        (channel-producer (emit)
          (funcall emit 1)
          (funcall emit 2)
          (funcall emit 3))
      (expect (drain-channel output :timeout 1)
              :to-equal (list 1 2 3))
      (await completion :timeout 1))))

(describe "channel-from-sequence"
  (it "emits a snapshot of SEQUENCE in order, then closes"
    (let ((source (list 1 2 3)))
      (multiple-value-bind (output completion) (channel-from-sequence source)
        (setf (first source) :mutated-after-the-fact)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 2 3))
        (await completion :timeout 1)))))

(describe "channel-map"
  (it "applies FUNCTION to every value and closes the output once INPUT closes"
    (let ((input (make-channel :buffer-size 3)))
      (send input 1) (send input 2) (send input 3) (close-channel input)
      (multiple-value-bind (output completion) (channel-map (lambda (x) (* x x)) input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 4 9))
        (await completion :timeout 1))))

  (it "fails the completion promise when FUNCTION signals"
    (let ((input (make-channel :buffer-size 1)))
      (send input 1)
      (multiple-value-bind (output completion) (channel-map (lambda (x) (declare (ignore x)) (error "boom")) input)
        (declare (ignore output))
        (signals error (await completion :timeout 1)))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (send input 1) (send input 2) (send input 3) (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-map (lambda (x) (* x x)) input :scope scope)
          (expect (drain-channel output :timeout 1)
                  :to-equal (list 1 4 9))
          (await completion :timeout 1)))))

  (it "fails the completion promise synchronously when starting the stage itself fails"
    (let ((input (make-channel)))
      (multiple-value-bind (output completion)
          (channel-map (function identity) input :executor :not-an-executor)
        (signals error (await completion :timeout 1))
        (expect (channel-closed-p output) :to-be-truthy)))))

(describe "channel-keep"
  (it "forwards only FUNCTION's non-NIL results"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 2 3 4)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-keep (lambda (x) (and (evenp x) (* x 10))) input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 20 40))
        (await completion :timeout 1)))))

(describe "channel-filter"
  (it "forwards only values PREDICATE accepts"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 2 3 4)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-filter (function evenp) input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 2 4))
        (await completion :timeout 1)))))

(describe "channel-distinct-until-changed"
  (it "drops consecutive duplicates under the default TEST/KEY"
    (let ((input (make-channel :buffer-size 6)))
      (dolist (x (list 1 1 2 2 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-distinct-until-changed input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 2 3))
        (await completion :timeout 1))))

  (it "compares by KEY under TEST"
    (let ((input (make-channel :buffer-size 3)))
      (send input (list :a 1)) (send input (list :b 1)) (send input (list :c 2))
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-distinct-until-changed input :key (function second) :test (function eql))
        (expect (mapcar (function first) (drain-channel output :timeout 1))
                :to-equal (list :a :c))
        (await completion :timeout 1)))))

(describe "channel-flat-map"
  (it "forwards every value of each returned sequence, in order"
    (let ((input (make-channel :buffer-size 2)))
      (send input 1) (send input 2) (close-channel input)
      (multiple-value-bind (output completion) (channel-flat-map (lambda (x) (list x (* x 10))) input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 10 2 20))
        (await completion :timeout 1)))))

(describe "channel-scan"
  (it "emits each successive accumulator, not the initial value"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-scan (function +) 0 input)
        (expect (drain-channel output :timeout 1)
                :to-equal (list 1 3 6))
        (await completion :timeout 1)))))

(describe "channel-reduce"
  (it "resolves to the final accumulator once INPUT closes"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (expect (await (channel-reduce (function +) 0 input) :timeout 1) :to-be 6)))

  (it "resolves to INITIAL-VALUE for an empty, already-closed INPUT"
    (let ((input (make-channel)))
      (close-channel input)
      (expect (await (channel-reduce (function +) 42 input) :timeout 1) :to-be 42)))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (expect (await (channel-reduce (function +) 0 input :scope scope) :timeout 1) :to-be 6)))))

(describe "channel-collect"
  (it "resolves to every value in input order"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list :a :b :c)) (send input x))
      (close-channel input)
      (expect (await (channel-collect input) :timeout 1) :to-equal (list :a :b :c))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list :a :b :c)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (expect (await (channel-collect input :scope scope) :timeout 1) :to-equal (list :a :b :c))))))

(describe "channel-each"
  (it "runs FUNCTION on every value in order and resolves to NIL"
    (let ((input (make-channel :buffer-size 3))
          (seen (list)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (expect (await (channel-each (lambda (x) (push x seen)) input) :timeout 1) :to-be nil)
      (expect (nreverse seen) :to-equal (list 1 2 3))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3))
          (seen (list)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (await (channel-each (lambda (x) (push x seen)) input :scope scope) :timeout 1))
      (expect (nreverse seen) :to-equal (list 1 2 3)))))

(describe "channel-some"
  (it "resolves to the first truthy PREDICATE result"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 3 4 5)) (send input x))
      (close-channel input)
      (expect (await (channel-some (function evenp) input) :timeout 1) :to-be-truthy)))

  (it "resolves to NIL once INPUT closes without a match"
    (let ((input (make-channel :buffer-size 2)))
      (dolist (x (list 1 3)) (send input x))
      (close-channel input)
      (expect (await (channel-some (function evenp) input) :timeout 1) :to-be nil)))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 3 4 5)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (expect (await (channel-some (function evenp) input :scope scope) :timeout 1) :to-be-truthy)))))

(describe "channel-every"
  (it "resolves to T when every value satisfies PREDICATE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 2 4 6)) (send input x))
      (close-channel input)
      (expect (await (channel-every (function evenp) input) :timeout 1) :to-be-truthy)))

  (it "resolves to NIL at the first value that fails PREDICATE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 2 3 4)) (send input x))
      (close-channel input)
      (expect (await (channel-every (function evenp) input) :timeout 1) :to-be nil)))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 2 4 6)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (expect (await (channel-every (function evenp) input :scope scope) :timeout 1) :to-be-truthy)))))

(describe "channel-find"
  (it "resolves to the first matching value"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (expect (await (channel-find (function evenp) input) :timeout 1) :to-be 2)))

  (it "resolves to NIL once INPUT closes without a match"
    (let ((input (make-channel :buffer-size 2)))
      (dolist (x (list 1 3)) (send input x))
      (close-channel input)
      (expect (await (channel-find (function evenp) input) :timeout 1) :to-be nil)))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (expect (await (channel-find (function evenp) input :scope scope) :timeout 1) :to-be 2)))))

(describe "channel-throttle"
  (it "emits the first value in a window immediately and drops the rest until it elapses"
    (let ((input (make-channel :buffer-size 3)))
      (send input :first)
      (send input :dropped)
      (multiple-value-bind (output completion) (channel-throttle 0.2 input)
        (expect (recv output :timeout 1) :to-be :first)
        (sleep 0.25)
        (send input :second)
        (close-channel input)
        (expect (recv output :timeout 1) :to-be :second)
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 1)))
      (send input :only)
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-throttle 0.01 input :scope scope)
          (expect (recv output :timeout 1) :to-be :only)
          (await completion :timeout 1))))))

(describe "channel-debounce"
  (it "emits only the latest value once INTERVAL passes with nothing newer"
    (let ((input (make-channel :buffer-size 3)))
      (multiple-value-bind (output completion) (channel-debounce 0.05 input)
        (send input 1)
        (send input 2)
        (send input 3)
        (expect (recv output :timeout 1) :to-be 3)
        (close-channel input)
        (await completion :timeout 1))))

  (it "flushes a still-pending value once INPUT closes"
    (let ((input (make-channel :buffer-size 1)))
      (multiple-value-bind (output completion) (channel-debounce 5 input)
        (send input :only)
        (close-channel input)
        (expect (recv output :timeout 1) :to-be :only)
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 1)))
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-debounce 0.05 input :scope scope)
          (send input :only)
          (close-channel input)
          (expect (recv output :timeout 1) :to-be :only)
          (await completion :timeout 1))))))

(describe "stream stage cancellation"
  (it "closes the output channel via its SCOPE waker when cancelled before ever running"
    ;; A stage already running cannot be interrupted mid-RECV (see this
    ;; file's own header comment) -- so this exercises the path that CAN be
    ;; cancelled outright: a stage SPAWNed onto a busy EXECUTOR, still
    ;; queued and not yet claimed by a worker, when its SCOPE is cancelled.
    (let ((input (make-channel))
          (executor (make-executor :size 1))
          release)
      (unwind-protect
          (progn
            (setf release (occupy-worker executor))
            (with-cancelled-scope (scope)
              (multiple-value-bind (output completion)
                  (channel-map (function identity) input :scope scope :executor executor)
                (declare (ignore completion))
                (expect (nth-value 1 (recv output :timeout 1)) :to-be nil))))
        (when release (signal-semaphore release))
        (shutdown-executor executor :wait t :timeout 1)))))
