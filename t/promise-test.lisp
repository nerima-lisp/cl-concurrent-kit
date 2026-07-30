;;;; t/promise-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "promise"
  (it "is not settled until DELIVER or DELIVER-ERROR is called"
    (let ((promise (make-promise)))
      (expect (promise-settled-p promise) :to-be nil)
      (deliver promise 42)
      (expect (promise-settled-p promise) :to-be-truthy)))

  (it "AWAIT returns the value DELIVER settled it with"
    (let ((promise (make-promise)))
      (deliver promise :hello)
      (expect (await promise) :to-be :hello)))

  (it "AWAIT re-signals the condition DELIVER-ERROR settled it with"
    (let ((promise (make-promise))
          (marker (make-condition 'error)))
      (deliver-error promise marker)
      (handler-case
          (progn (await promise) (error "AWAIT should have signaled"))
        (error (c) (expect (eq c marker) :to-be-truthy)))))

  (it "signals PROMISE-ALREADY-FULFILLED when settled twice"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (signals promise-already-fulfilled (deliver promise 2))))

  (it "AWAIT with :TIMEOUT signals OPERATION-TIMED-OUT when never settled"
    (let ((promise (make-promise)))
      (signals operation-timed-out (await promise :timeout 0.05d0))))

  (it "AWAIT blocks until another thread delivers, then returns"
    (let* ((promise (make-promise))
           (thread (make-thread (lambda () (sleep 0.05) (deliver promise :from-thread)))))
      (expect (await promise) :to-be :from-thread)
      (join-thread thread))))

(describe "promise-all-settled"
  (it "settles immediately with an empty list for no input promises"
    (let ((aggregate (cl-concurrent-kit:promise-all-settled nil)))
      (expect (promise-settled-p aggregate) :to-be-truthy)
      (expect (await aggregate) :to-equal nil)))

  (it "preserves input order and records fulfilled and failed outcomes"
    (let* ((fulfilled (make-promise))
           (failed (make-promise))
           (condition (make-condition 'error))
           (aggregate (cl-concurrent-kit:promise-all-settled
                       (list fulfilled failed))))
      (deliver-error failed condition)
      (deliver fulfilled :value)
      (let ((settlements (await aggregate :timeout 1)))
        (with-soft-assertions
          (expect (mapcar #'cl-concurrent-kit:promise-settlement-state settlements)
                  :to-equal (list :fulfilled :failed))
          (expect (cl-concurrent-kit:promise-settlement-value (first settlements))
                  :to-be :value)
          (expect (cl-concurrent-kit:promise-settlement-condition (second settlements))
                  :to-be condition)))))
  (it-property "preserves input order and classifies every outcome, for any mix of fulfilled and failed inputs"
      ((outcomes (gen-list (gen-boolean) :min-length 0 :max-length 16)))
    (let* ((promises (loop repeat (length outcomes) collect (make-promise)))
           (aggregate (cl-concurrent-kit:promise-all-settled promises)))
      (loop for promise in promises
            for succeed-p in outcomes
            for index from 0
            do (if succeed-p
                   (deliver promise index)
                   (deliver-error promise (make-condition 'error))))
      (let ((settlements (await aggregate :timeout 1)))
        (expect (length settlements) :to-be (length outcomes))
        (loop for settlement in settlements
              for succeed-p in outcomes
              for index from 0
              do (if succeed-p
                     (progn
                       (expect (cl-concurrent-kit:promise-settlement-state settlement) :to-be :fulfilled)
                       (expect (cl-concurrent-kit:promise-settlement-value settlement) :to-be index))
                     (expect (cl-concurrent-kit:promise-settlement-state settlement) :to-be :failed)))))))

(describe "promise-race"
  (it "settles fulfilled with whichever promise fulfills first"
    (let* ((first (make-promise))
           (second (make-promise))
           (winner (promise-race (list first second))))
      (deliver first :first-value)
      (expect (await winner :timeout 1) :to-be :first-value)))

  (it "settles failed when the first to settle fails"
    (let* ((first (make-promise))
           (second (make-promise))
           (condition (make-condition 'error))
           (winner (promise-race (list first second))))
      (deliver-error first condition)
      (handler-case
          (progn (await winner :timeout 1) (error "AWAIT should have re-signaled"))
        (error (c) (expect (eq c condition) :to-be-truthy)))))

  (it "discards settlements after the first winner without signaling"
    (let* ((first (make-promise))
           (second (make-promise))
           (winner (promise-race (list first second))))
      (deliver first :first-value)
      (deliver second :second-value)
      (expect (await winner :timeout 1) :to-be :first-value)))

  (it "signals an error when given no promises"
    (signals error (promise-race nil))))

(describe "promise-then"
  (it "calls ON-FULFILLED with an already-settled promise's value as its continuation"
    (let ((promise (make-promise)))
      (deliver promise 21)
      (with-continuation-result (value next)
          (promise-then promise (lambda (v) (next (* v 2))))
        (expect value :to-be 42))))

  (it "settles the returned promise with ON-FULFILLED's return value"
    (let ((promise (make-promise)))
      (deliver promise 21)
      (expect (await (promise-then promise (lambda (v) (* v 2)))) :to-be 42)))

  (it "runs ON-REJECTED, not ON-FULFILLED, when the input promise fails"
    (let ((promise (make-promise))
          (condition (make-condition 'error)))
      (deliver-error promise condition)
      (expect (await (promise-then promise
                                    (lambda (v) (declare (ignore v)) :wrong-branch)
                                    (lambda (c) (list :caught (eq c condition)))))
              :to-equal (list :caught t))))

  (it "propagates the input promise's failure unchanged when ON-REJECTED is omitted"
    (let ((promise (make-promise))
          (condition (make-condition 'simple-error :format-control "boom")))
      (deliver-error promise condition)
      (let ((chained (promise-then promise (lambda (v) (declare (ignore v)) :wrong-branch))))
        (handler-case
            (progn (await chained) (error "AWAIT should have re-signaled"))
          (error (c) (expect (eq c condition) :to-be-truthy))))))

  (it "fails the returned promise when ON-FULFILLED itself signals"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (let ((chained (promise-then promise (lambda (v) (declare (ignore v)) (error "in handler")))))
        (signals error (await chained)))))

  (it "settles the returned promise once a not-yet-settled input promise later delivers"
    (let* ((promise (make-promise))
           (chained (promise-then promise (lambda (v) (1+ v)))))
      (expect (promise-settled-p chained) :to-be nil)
      (deliver promise 41)
      (expect (await chained :timeout 1) :to-be 42))))

(describe "future"
  (it "runs its body on another thread and AWAIT resolves to its value"
    (expect (await (future (+ 1 2 3))) :to-be 6))

  (it "propagates an error signaled in its body to AWAIT"
    (let ((f (future (error "boom in future"))))
      (signals error (await f)))))
