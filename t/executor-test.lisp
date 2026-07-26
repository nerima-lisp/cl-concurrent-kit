;;;; t/executor-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "executor"
  (it "runs a submitted thunk on a worker thread and AWAIT resolves to its value"
    (let ((executor (make-executor :size 2)))
      (expect (await (submit executor (lambda () (* 6 7)))) :to-be 42)
      (shutdown-executor executor :wait t)))

  (it "propagates an error from the thunk to AWAIT"
    (let* ((executor (make-executor :size 2))
           (result (submit executor (lambda () (error "task failure")))))
      (signals error (await result))
      (shutdown-executor executor :wait t)))

  (it "runs many submitted tasks across a small worker pool"
    (let* ((executor (make-executor :size 3))
           ;; LOOP's numeric FOR mutates one binding of I in place rather than
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
      (expect (await result) :to-be :queued-before-shutdown))))
