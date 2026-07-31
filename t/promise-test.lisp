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
      (progn (expect (length observed) :to-be 3) (expect (aref observed 0) :to-be :first) (expect (aref observed 1) :to-be :second) (expect (aref observed 2) :to-be :third))))
  (it
    "UNOBSERVE-PROMISE removes a non-first observer without disturbing the others"
    (let ((promise (make-promise))
          (observed (list)))
      (let ((first-observer (lambda (state outcome) (declare (ignore state outcome)) (push :first observed)))
            (second-observer (lambda (state outcome) (declare (ignore state outcome)) (push :second observed))))
        (cl-concurrent-kit::%observe-promise promise first-observer)
        (cl-concurrent-kit::%observe-promise promise second-observer)
        (cl-concurrent-kit::%unobserve-promise promise second-observer)
        (deliver promise :value)
        (expect observed :to-equal (list :first)))))
  (it
    "DELIVER-IF-PENDING is a no-op against an already-settled promise"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (cl-concurrent-kit::%deliver-if-pending promise 2)
      (expect (await promise) :to-be 1)))
  (it
    "DELIVER-ERROR-IF-PENDING is a no-op against an already-settled promise"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (cl-concurrent-kit::%deliver-error-if-pending promise (make-condition (quote error)))
      (expect (await promise) :to-be 1))))

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
                     (expect (cl-concurrent-kit:promise-settlement-state settlement) :to-be :failed))))))
  (it "notifies later observers before re-signaling an earlier observer failure"
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
          (expect (promise-settlement-value (first settlements)) :to-be :value))))))

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

(describe "cancel-promise"
  (it "settles a pending promise as failed with PROMISE-CANCELLED"
    (let ((promise (make-promise)))
      (cancel-promise promise :because)
      (handler-case (progn (await promise) (error "AWAIT should have signaled"))
        (promise-cancelled (condition)
          (expect (eq (promise-cancelled-promise condition) promise) :to-be-truthy)
          (expect (promise-cancelled-reason condition) :to-be :because)))))

  (it "signals PROMISE-ALREADY-FULFILLED against an already-settled promise"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (signals promise-already-fulfilled (cancel-promise promise)))))

(describe "promise-catch"
  (it "passes a fulfilled promise's value through unchanged"
    (let ((promise (make-promise)))
      (deliver promise 42)
      (expect (await (promise-catch promise (lambda (c) (declare (ignore c)) :wrong-branch)))
              :to-be 42)))

  (it "settles the result with ON-REJECTED's return value when the input fails"
    (let ((promise (make-promise))
          (condition (make-condition 'simple-error :format-control "boom")))
      (deliver-error promise condition)
      (expect (await (promise-catch promise (lambda (c) (list :recovered (eq c condition)))))
              :to-equal (list :recovered t))))

  (it "fails the result when ON-REJECTED itself signals"
    (let ((promise (make-promise)))
      (deliver-error promise (make-condition 'simple-error :format-control "boom"))
      (let ((chained (promise-catch promise (lambda (c) (declare (ignore c)) (error "in handler")))))
        (signals error (await chained))))))

(describe "promise-finally"
  (it "runs FUNCTION and mirrors a fulfilled input's own value, not FUNCTION's"
    (let ((promise (make-promise))
          (ran-p nil))
      (deliver promise 42)
      (expect (await (promise-finally promise (lambda () (setf ran-p t) :ignored))) :to-be 42)
      (expect ran-p :to-be-truthy)))

  (it "runs FUNCTION and mirrors a failed input's own condition, not FUNCTION's return"
    (let ((promise (make-promise))
          (condition (make-condition 'simple-error :format-control "boom"))
          (ran-p nil))
      (deliver-error promise condition)
      (let ((chained (promise-finally promise (lambda () (setf ran-p t) :ignored))))
        (handler-case (progn (await chained) (error "AWAIT should have re-signaled"))
          (error (c) (expect (eq c condition) :to-be-truthy))))
      (expect ran-p :to-be-truthy)))

  (it "fails the result when FUNCTION itself signals, even for a fulfilled input"
    (let ((promise (make-promise)))
      (deliver promise 1)
      (let ((chained (promise-finally promise (lambda () (error "in finally")))))
        (signals error (await chained))))))

(describe "promise-all"
  (it "fulfills immediately with NIL for no input promises"
    (expect (await (promise-all nil) :timeout 1) :to-be nil))

  (it "fulfills with every value in input order once all inputs fulfill"
    (let ((promises (list (make-promise) (make-promise) (make-promise))))
      (let ((combined (promise-all promises)))
        (deliver (third promises) 3)
        (deliver (first promises) 1)
        (deliver (second promises) 2)
        (expect (await combined :timeout 1) :to-equal (list 1 2 3)))))

  (it "fails as soon as any input fails, without waiting for the rest"
    (let* ((never-settles (make-promise))
           (failing (make-promise))
           (condition (make-condition 'simple-error :format-control "boom"))
           (combined (promise-all (list never-settles failing))))
      (deliver-error failing condition)
      (handler-case (progn (await combined :timeout 1) (error "AWAIT should have re-signaled"))
        (error (c) (expect (eq c condition) :to-be-truthy)))))

  (it "unregisters an observer registered on a still-pending input after the outcome is already decided"
    (let* ((already-failed (make-promise))
           (pending (make-promise))
           (condition (make-condition 'simple-error :format-control "boom")))
      ;; ALREADY-FAILED is settled BEFORE PROMISE-ALL is even called, so its
      ;; observer fires -- and decides the aggregate -- synchronously inside
      ;; PROMISE-ALL's own registration loop, before PENDING's observer is
      ;; ever registered.
      (deliver-error already-failed condition)
      (let ((combined (promise-all (list already-failed pending))))
        (handler-case (progn (await combined :timeout 1) (error "AWAIT should have re-signaled"))
          (error (c) (expect (eq c condition) :to-be-truthy)))
        ;; PENDING's observer was unregistered as soon as it was registered,
        ;; since the outcome was already decided by ALREADY-FAILED --
        ;; delivering it now must not raise or otherwise disturb the
        ;; already-settled result.
        (deliver pending :too-late)
        (expect (promise-settled-p combined) :to-be-truthy)))))

(describe "promise-any"
  (it "signals PROMISE-EMPTY-INPUT for no input promises"
    (signals promise-empty-input (promise-any nil)))

  (it "fulfills with whichever input fulfills first"
    (let ((promises (list (make-promise) (make-promise))))
      (let ((first-to-win (promise-any promises)))
        (deliver (second promises) :winner)
        (expect (await first-to-win :timeout 1) :to-be :winner))))

  (it "fails with PROMISE-ALL-FAILED once every input has failed"
    (let* ((first-input (make-promise))
           (second-input (make-promise))
           (first-condition (make-condition 'simple-error :format-control "first"))
           (second-condition (make-condition 'simple-error :format-control "second"))
           (combined (promise-any (list first-input second-input))))
      (deliver-error first-input first-condition)
      (deliver-error second-input second-condition)
      (handler-case (progn (await combined :timeout 1) (error "AWAIT should have signaled"))
        (promise-all-failed (condition)
          (expect (promise-all-failed-causes condition)
                  :to-equal (list first-condition second-condition))))))

  (it "unregisters an observer registered on a still-pending input after the outcome is already decided"
    (let ((already-fulfilled (make-promise))
          (pending (make-promise)))
      ;; ALREADY-FULFILLED is settled BEFORE PROMISE-ANY is even called, so
      ;; its observer fires -- and decides the winner -- synchronously inside
      ;; PROMISE-ANY's own registration loop, before PENDING's observer is
      ;; ever registered.
      (deliver already-fulfilled :winner)
      (let ((combined (promise-any (list already-fulfilled pending))))
        (expect (await combined :timeout 1) :to-be :winner)
        ;; PENDING's observer was unregistered as soon as it was registered,
        ;; since the outcome was already decided by ALREADY-FULFILLED --
        ;; delivering it now must not raise or otherwise disturb the result.
        (deliver pending :too-late)
        (expect (await combined :timeout 1) :to-be :winner)))))

(describe "promise-timeout"
  (it "mirrors a promise that settles before the timeout elapses"
    (let ((promise (make-promise)))
      (deliver promise :in-time)
      (expect (await (promise-timeout promise 1) :timeout 1) :to-be :in-time)))

  (it "signals OPERATION-TIMED-OUT once the timeout elapses first"
    (let ((promise (make-promise)))
      (signals operation-timed-out (await (promise-timeout promise 0.01) :timeout 1))))

  (it "mirrors a promise that fails before the timeout elapses"
    (let ((promise (make-promise))
          (condition (make-condition 'simple-error :format-control "boom")))
      (deliver-error promise condition)
      (handler-case (progn (await (promise-timeout promise 1) :timeout 1) (error "AWAIT should have re-signaled"))
        (error (c) (expect (eq c condition) :to-be-truthy)))))

  (it "does not resettle the timed-out result when the source delivers late"
    (let ((promise (make-promise)))
      (let ((timed (promise-timeout promise 0.01)))
        (signals operation-timed-out (await timed :timeout 1))
        ;; PROMISE-TIMEOUT's observer already unregistered itself on timeout,
        ;; so delivering PROMISE afterward must not raise anything -- its own
        ;; delivery attempt against the already-settled TIMED is silently
        ;; ignored rather than propagating PROMISE-ALREADY-FULFILLED.
        (deliver promise :too-late)
        (signals operation-timed-out (await timed :timeout 1))))))
