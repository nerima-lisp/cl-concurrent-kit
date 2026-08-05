;;;; t/timeout-test.lisp
(in-package #:cl-concurrent-kit/test)

;;; Every expiry assertion below captures the condition into a variable and
;;; then asserts on it, rather than asserting inside a HANDLER-CASE clause: a
;;; clause that never runs makes its assertions vanish instead of fail, which
;;; is exactly the regression these specs exist to catch.
(defun timeout-condition-of (thunk)
  "Run THUNK and return the OPERATION-TIMED-OUT it signals, or NIL if it
returns without signaling one."
  (handler-case (progn (funcall thunk) nil)
    (operation-timed-out (condition) condition)))

(describe-concurrent "WITH-TIMEOUT expiry"
  (it "signals OPERATION-TIMED-OUT when the body outlasts the deadline"
    (signals operation-timed-out (with-timeout +test-timeout-expiry+ (sleep 5))))

  (it "reports :WITH-TIMEOUT and the seconds it was given"
    (let ((condition (timeout-condition-of (lambda () (with-timeout +test-timeout-expiry+ (sleep 5))))))
      (expect condition :to-be-truthy)
      (expect (operation-timed-out-operation condition) :to-be :with-timeout)
      (expect (operation-timed-out-timeout condition) :to-be 1/20)))

  (it "signals an ERROR, so SB-EXT:TIMEOUT never reaches the caller"
    ;; SB-EXT:TIMEOUT is a SERIOUS-CONDITION but deliberately not an ERROR, so
    ;; a caller's own (HANDLER-CASE ... (ERROR ...)) would miss it entirely.
    ;; Translating it is why this macro exists over SB-EXT:WITH-TIMEOUT.
    (expect (handler-case (progn (with-timeout +test-timeout-expiry+ (sleep 5)) :no-condition)
              (error (condition) (typep condition 'cl-concurrent-kit-error)))
            :to-be-truthy))

  (it "stops running the body once the deadline passes"
    (let ((finished-p nil))
      (signals operation-timed-out
               (with-timeout +test-timeout-expiry+ (sleep 5) (setf finished-p t)))
      (expect finished-p :to-be nil))))

(describe-concurrent "WITH-TIMEOUT without expiry"
  (it "returns the body's value when it finishes in time"
    (expect (with-timeout (cl-date-kit:duration-of-seconds 5) (+ 1 2)) :to-be 3))

  (it "passes every value through, not just the first"
    (expect (multiple-value-list (with-timeout (cl-date-kit:duration-of-seconds 5) (values 1 2 3))) :to-equal (list 1 2 3)))

  (it "unschedules its timer, so work after the deadline would have passed is undisturbed"
    (expect (with-timeout +test-timeout-expiry+ :done) :to-be :done)
    (sleep 0.2)
    (expect (with-timeout (cl-date-kit:duration-of-seconds 5) :still-running) :to-be :still-running))

  (it "lets a condition signaled by the body propagate unchanged"
    (signals latch-count-underflow
             (with-timeout (cl-date-kit:duration-of-seconds 5) (count-down (make-countdown-latch 0))))))

(describe-concurrent "WITH-TIMEOUT with no deadline"
  (it "runs the body with no deadline at all when SECONDS is NIL"
    (expect (with-timeout nil (sleep 0.1) :ran) :to-be :ran))

  (it "runs the body with no deadline at all when SECONDS is zero"
    ;; Matching SB-EXT:WITH-TIMEOUT, which schedules no timer unless its
    ;; argument is strictly positive: a zero-second deadline that fired at once
    ;; would leave (WITH-TIMEOUT 0 ...) unable to run anything.
    (expect (with-timeout (cl-date-kit:duration-zero) (sleep 0.1) :ran) :to-be :ran))

  (it "runs the body with no deadline at all when SECONDS is negative"
    (expect (with-timeout (cl-date-kit:duration-of-seconds -1) (sleep 0.1) :ran) :to-be :ran))

  (it "accepts a runtime NIL, not only a literal one"
    (let ((timeout nil))
      (expect (with-timeout timeout (sleep 0.1) :ran) :to-be :ran)))

  (it "evaluates SECONDS exactly once"
    (let ((evaluations 0))
      (expect (with-timeout (progn (incf evaluations) (cl-date-kit:duration-of-seconds 5)) :ran) :to-be :ran)
      (expect evaluations :to-be 1))))

(describe-concurrent "WITH-TIMEOUT nesting"
  (it "reports the inner deadline when the inner one expires first"
    (let ((condition (timeout-condition-of
                      (lambda () (with-timeout (cl-date-kit:duration-of-seconds 10) (with-timeout +test-timeout-expiry+ (sleep 5)))))))
      (expect condition :to-be-truthy)
      (expect (operation-timed-out-timeout condition) :to-be 1/20)))

  (it "reports the outer deadline when the outer one expires first"
    ;; The inner form's handler sees the outer form's SB-EXT:TIMEOUT first,
    ;; being the innermost handler established. It must decline it -- its own
    ;; deadline has not been reached -- rather than claim the expiry and
    ;; misreport 10 seconds as the budget that ran out.
    (let ((condition (timeout-condition-of
                      (lambda () (with-timeout +test-timeout-expiry+ (with-timeout (cl-date-kit:duration-of-seconds 10) (sleep 5)))))))
      (expect condition :to-be-truthy)
      (expect (operation-timed-out-timeout condition) :to-be 1/20)))

  (it "leaves an SB-EXT:WITH-TIMEOUT established by the body itself alone"
    ;; A body that establishes its own deadline directly against SB-EXT gets
    ;; that condition back, not this macro's translation of it.
    (expect (handler-case (with-timeout (cl-date-kit:duration-of-seconds 10) (sb-ext:with-timeout 0.05 (sleep 5)))
              (sb-ext:timeout () :body-own-timeout)
              (operation-timed-out () :claimed-by-with-timeout))
            :to-be :body-own-timeout))

  (it "still bounds the outer body after an inner deadline has come and gone"
    (let ((condition (timeout-condition-of
                      (lambda ()
                        (with-timeout (cl-date-kit:duration-of-millis 300)
                          (handler-case (with-timeout +test-timeout-expiry+ (sleep 5))
                            (operation-timed-out () nil))
                          (sleep 5))))))
      (expect condition :to-be-truthy)
      (expect (operation-timed-out-timeout condition) :to-be 3/10))))

