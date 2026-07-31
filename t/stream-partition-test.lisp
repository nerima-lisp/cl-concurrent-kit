;;;; t/stream-partition-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "channel-partition-by"
  (it "groups consecutive values with an EQL KEY, emitting each group in order"
    (let ((input (make-channel :buffer-size 6)))
      (dolist (x (list 1 1 2 2 2 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-partition-by (function identity) input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list (list 1 1) (list 2 2 2) (list 3)))
        (await completion :timeout 1))))

  (it "starts a new group once KEY changes back to an earlier value"
    (let ((input (make-channel :buffer-size 4)))
      (dolist (x (list :a :a :b :a)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion) (channel-partition-by (function identity) input)
        (expect (loop for value = (recv output :timeout 1) while value collect value)
                :to-equal (list (list :a :a) (list :b) (list :a)))
        (await completion :timeout 1))))

  (it "emits the final group once INPUT closes"
    (let ((input (make-channel :buffer-size 3)))
      (dolist (x (list :odd 1 3)) (send input x))
      (close-channel input)
      (multiple-value-bind (output completion)
          (channel-partition-by (lambda (x) (declare (ignore x)) :group) input)
        (expect (recv output :timeout 1) :to-equal (list :odd 1 3))
        (await completion :timeout 1)))))
