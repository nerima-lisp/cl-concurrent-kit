;;;; t/promise-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe
  "promise"
  (it
    "recognizes PROMISE values"
    (let ((promise (make-promise)))
      (expect (promise-p promise) :to-be-truthy)
      (expect (promise-p :not-a-promise) :to-be nil)))
  (it
    "is not settled until DELIVER or DELIVER-ERROR is called"
    (let ((promise (make-promise)))
      (expect (promise-settled-p promise) :to-be nil)
      (deliver promise 42)
      (expect (promise-settled-p promise) :to-be-truthy)))
  (it
    "AWAIT returns the value DELIVER settled it with"
    (let ((promise (make-promise)))
      (deliver promise :hello)
      (expect (await promise) :to-be :hello)))
  (it
    "AWAIT re-signals the condition DELIVER-ERROR settled it with"
    (let ((promise (make-promise))
          (marker (make-condition (quote error))))
      (deliver-error promise marker)
      (handler-case (progn
          (await promise)
          (error "AWAIT should have signaled"))
        (error (c)
          (expect (eq c marker) :to-be-truthy)))))
  (it
    "exposes the promise in PROMISE-ALREADY-FULFILLED"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (handler-case (progn
          (deliver promise 2)
          (error "DELIVER should have signaled"))
        (promise-already-fulfilled (condition)
          (expect
            (eq (promise-already-fulfilled-promise condition) promise)
            :to-be-truthy)))))
  (it
    "exposes AWAIT timeout details"
    (let ((promise (make-promise))
          (timeout 0.05d0))
      (handler-case (progn
          (await promise :timeout timeout)
          (error "AWAIT should have timed out"))
        (operation-timed-out (condition)
          (expect (operation-timed-out-operation condition) :to-be :await)
          (expect (operation-timed-out-timeout condition) :to-be timeout)))))
  (it
    "AWAIT blocks until another thread delivers, then returns"
    (let* ((promise (make-promise))
           (thread
          (make-thread
            (lambda ()
              (sleep 0.05)
              (deliver promise :from-thread)))))
      (expect (await promise) :to-be :from-thread)
      (join-thread thread)))
  (it
    "notifies pending observers in registration order"
    (let ((promise (make-promise))
          (observed (make-array 0 :adjustable t :fill-pointer 0)))
      (dolist (value (list :first :second :third))
        (let ((value value))
          (cl-concurrent-kit::%observe-promise
            promise
            (lambda (state outcome)
              (declare (ignore state outcome))
              (vector-push-extend value observed)))))
      (deliver promise :value)
      (progn (expect (length observed) :to-be 3) (expect (aref observed 0) :to-be :first) (expect (aref observed 1) :to-be :second) (expect (aref observed 2) :to-be :third)))))

(describe
  "future"
  (it
    "runs its body on another thread and AWAIT resolves to its value"
    (expect (await (future (+ 1 2 3))) :to-be 6))
  (it
    "accepts declaration forms in its body"
    (expect (await (future
                    (declare (optimize (speed 3)))
                    (+ 3 4)))
            :to-be 7))
  (it
    "propagates an error signaled in its body to AWAIT"
    (let ((f (future (error "boom in future"))))
      (signals error (await f)))))

(describe
  "promise-all-settled"
  (it
    "fulfills immediately with NIL for no input promises"
    (expect (await (promise-all-settled (quote ()))) :to-be nil))
  (it
    "preserves input order and records both fulfillment and failure"
    (let ((first (make-promise))
          (second (make-promise)))
      (let ((aggregate (promise-all-settled (list first second))))
        (deliver-error second (make-condition (quote error)))
        (deliver first :first)
        (let ((settlements (await aggregate)))
          (expect (length settlements) :to-be 2)
          (expect (promise-settlement-p (first settlements)) :to-be-truthy)
          (expect (promise-settlement-state (first settlements)) :to-be :fulfilled)
          (expect (promise-settlement-value (first settlements)) :to-be :first)
          (expect (promise-settlement-state (second settlements)) :to-be :failed)
          (expect (promise-settlement-condition (second settlements)) :to-be-truthy)))))
  (it
    "notifies later observers before re-signaling an earlier observer failure"
    (let ((promise (make-promise)))
      (cl-concurrent-kit::%observe-promise
        promise
        (lambda (state outcome)
          (declare (ignore state outcome))
          (error "failing observer")))
      (let ((aggregate (promise-all-settled (list promise))))
        (signals error (deliver promise :value))
        (expect (promise-settled-p aggregate) :to-be-truthy)
        (let ((settlements (await aggregate)))
          (expect (promise-settlement-state (first settlements)) :to-be :fulfilled)
          (expect (promise-settlement-value (first settlements)) :to-be :value)))))
  (it
    "observes input promises that settled before aggregation"
    (let ((fulfilled (make-promise))
          (failed (make-promise)))
      (deliver fulfilled :ready)
      (deliver-error failed (make-condition (quote error)))
      (let ((settlements (await (promise-all-settled (list fulfilled failed)))))
        (expect (promise-settlement-state (first settlements)) :to-be :fulfilled)
        (expect (promise-settlement-value (first settlements)) :to-be :ready)
        (expect (promise-settlement-state (second settlements)) :to-be :failed)
        (expect (promise-settlement-condition (second settlements)) :to-be-truthy)))))
