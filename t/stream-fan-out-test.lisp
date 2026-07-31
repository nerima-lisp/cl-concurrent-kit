;;;; t/stream-fan-out-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "channel-broadcast"
  (it "forwards every value to each of COUNT outputs, in order"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (outputs completion) (channel-broadcast input 2 :buffer-size 3)
        (expect (length outputs) :to-be 2)
        (dolist (output outputs)
          (expect (loop for value = (recv output :timeout 1) while value collect value)
                  :to-equal (list 1 2 3)))
        (await completion :timeout 1))))

  (it "keeps draining INPUT to the remaining outputs once one is closed"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (outputs completion) (channel-broadcast input 2 :buffer-size 3)
        (close-channel (first outputs))
        (expect (loop for value = (recv (second outputs) :timeout 1) while value collect value)
                :to-equal (list 1 2 3))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (outputs completion) (channel-broadcast input 1 :buffer-size 3 :scope scope)
          (expect (loop for value = (recv (first outputs) :timeout 1) while value collect value)
                  :to-equal (list 1 2 3))
          (await completion :timeout 1))))))

(describe "channel-take"
  (it "forwards at most COUNT values and leaves the rest on INPUT"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 2 3 4)) (send input x))
      (multiple-value-bind (output completion) (channel-take 2 input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list 1 2))
        (await completion :timeout 1)
        (expect (recv input :timeout 1) :to-be 3))))

  (it "closes the output early if INPUT closes before COUNT is reached"
    (let ((input (make-channel :buffer-size 1)))
      (send input 1)
      (close-channel input)
      (multiple-value-bind (output completion) (channel-take 5 input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list 1))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 2)))
      (dolist (x (list 1 2)) (send input x))
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-take 2 input :scope scope)
          (expect (loop for value = (recv output :timeout 1) while value collect value)
                  :to-equal (list 1 2))
          (await completion :timeout 1))))))

(describe "channel-drop"
  (it "discards the first COUNT values and forwards the rest"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 2 3 4)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-drop 2 input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list 3 4))
        (await completion :timeout 1)))))

(describe "channel-take-while"
  (it "forwards the matching prefix and consumes (without forwarding) the first non-match"
    (let ((input (make-channel :buffer-size 5)))
      (dolist (x (list 1 3 5 4 7)) (send input x))
      (multiple-value-bind (output completion) (channel-take-while (function oddp) input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list 1 3 5))
        (await completion :timeout 1)
        ;; 4 was RECV'd off INPUT to test it against PREDICATE, then
        ;; discarded rather than forwarded -- only the value after it
        ;; remains.
        (expect (recv input :timeout 1) :to-be 7))))

  (it "closes the output once INPUT drains, without ever failing PREDICATE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 3 5)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-take-while (function oddp) input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list 1 3 5))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 3 4)) (send input x))
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-take-while (function oddp) input :scope scope)
          (expect (loop for value = (recv output :timeout 1) while value collect value)
                  :to-equal (list 1 3))
          (await completion :timeout 1))))))

(describe "channel-batch"
  (it "groups values into ordered lists of SIZE elements"
    (let ((input (make-channel :buffer-size 6)))
      (dolist (x (list 1 2 3 4 5 6)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-batch 2 input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list (list 1 2) (list 3 4) (list 5 6)))
        (await completion :timeout 1))))

  (it "forwards a final partial batch when EMIT-PARTIAL is true"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-batch 2 input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list (list 1 2) (list 3)))
        (await completion :timeout 1))))

  (it "discards a final partial batch when EMIT-PARTIAL is false"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list 1 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-batch 2 input :emit-partial nil)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list (list 1 2)))
        (await completion :timeout 1))))

  (it "runs to completion with a live, uncancelled SCOPE"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list 1 2 3 4)) (send input x))
      (close-channel input)
      (with-task-scope (scope)
        (multiple-value-bind (output completion) (channel-batch 2 input :scope scope)
          (expect (loop for value = (recv output :timeout 1) while value collect value)
                  :to-equal (list (list 1 2) (list 3 4)))
          (await completion :timeout 1))))))
