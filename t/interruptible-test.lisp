;;;; t/interruptible-test.lisp
(in-package #:cl-concurrent-kit/test)

(defun interruption-condition-of (thunk)
  (handler-case (progn (funcall thunk) nil)
    (cl-concurrent-kit::operation-interrupted (condition) condition)))

(describe-concurrent "interruptible scopes"
  (it "exports and documents each new public binding"
    (let ((reference (uiop:read-file-string
                      (asdf:system-relative-pathname "cl-concurrent-kit"
                                                     "docs/src/reference/api.md"))))
      (dolist (name '("WITH-INTERRUPTIBLE-SCOPE" "REQUEST-INTERRUPTION"
                      "OPERATION-INTERRUPTED" "OPERATION-INTERRUPTED-SCOPE"
                      "OPERATION-INTERRUPTED-REASON"))
        (multiple-value-bind (symbol status) (find-symbol name :cl-concurrent-kit)
          (expect status :to-be :external)
          (expect (or (fboundp symbol) (find-class symbol nil)) :to-be-truthy)
          (expect (search name reference) :to-be-truthy)))))

  (it "returns all normal values and ignores requests after exit"
    (let (saved)
      (expect (multiple-value-list
               (cl-concurrent-kit::with-interruptible-scope (scope)
                 (setf saved scope)
                 (values 1 2 3)))
              :to-equal '(1 2 3))
      (expect (cl-concurrent-kit::request-interruption saved :reason :late) :to-be nil)
      (sleep 0.01)
      (expect (cl-concurrent-kit::with-interruptible-scope (scope) (declare (ignore scope)) (+ 20 22)) :to-be 42)))

  (it "preserves another non-local exit and closes its scope"
    (let (saved)
      (expect (catch 'outside
                (cl-concurrent-kit::with-interruptible-scope (scope)
                  (setf saved scope)
                  (throw 'outside :original)))
              :to-be :original)
      (expect (cl-concurrent-kit::request-interruption saved) :to-be nil)))

  (it "interrupts ignore-errors without notifying body handlers and runs cleanup"
    (let ((ready (make-semaphore)) saved cleaned body-notified)
      (let ((thread
              (make-thread
               (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (handler-bind ((condition (lambda (condition)
                                                  (declare (ignore condition))
                                                  (setf body-notified t))))
                        (unwind-protect
                            (progn
                              (signal-semaphore ready)
                              (loop (ignore-errors (sleep 0.1))))
                          (setf cleaned t))))))))))
        (wait-or-fail ready "interruptible body did not start")
        (expect (cl-concurrent-kit::request-interruption saved :reason :keyboard)
                :to-be t)
        (let ((condition (join-thread thread :timeout 2)))
          (expect condition :to-be-truthy)
          (expect (cl-concurrent-kit::operation-interrupted-scope condition) :to-be saved)
          (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be :keyboard)
          (expect (search "KEYBOARD" (princ-to-string condition)) :to-be-truthy))
        (expect cleaned :to-be t)
        (expect body-notified :to-be nil))))

  (it "interrupts a computing body despite an ERROR handler-case"
    (let ((ready (make-semaphore)) saved)
      (let ((thread
              (make-thread
               (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (signal-semaphore ready)
                      (handler-case (loop) (error () :swallowed)))))))))
        (wait-or-fail ready "computing body did not start")
        (cl-concurrent-kit::request-interruption saved)
        (let ((condition (join-thread thread :timeout 2)))
          (expect condition :to-be-truthy)
          (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be nil)))))

  (it "delivers a target-thread handler request after that handler returns"
    (let ((ready (make-semaphore)) saved handler-returned)
      (let ((thread
              (make-thread
               (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (signal-semaphore ready)
                      (loop (sleep 0.1)))))))))
        (wait-or-fail ready "handler target did not start")
        (sb-thread:interrupt-thread
         thread (lambda ()
                  (cl-concurrent-kit::request-interruption saved :reason :signal)
                  (setf handler-returned t)))
        (let ((condition (join-thread thread :timeout 2)))
          (expect handler-returned :to-be t)
          (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be :signal)))))

  (it "keeps the first reason and defers delivery across WITHOUT-INTERRUPTS"
    (let ((ready (make-semaphore)) (release (make-semaphore)) saved first second)
      (let ((thread
              (make-thread
               (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (sb-sys:without-interrupts
                        (signal-semaphore ready)
                        (wait-or-fail release "protected body was not released"))
                      (loop (sleep 0.1)))))))))
        (wait-or-fail ready "protected body did not start")
        (setf first (cl-concurrent-kit::request-interruption saved :reason :first)
              second (cl-concurrent-kit::request-interruption saved :reason :second))
        (signal-semaphore release)
        (let ((condition (join-thread thread :timeout 2)))
          (expect first :to-be t)
          (expect second :to-be nil)
          (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be :first)))))

  (it "ignores a request arriving during boundary cleanup"
    (let (saved accepted)
      (expect
       (multiple-value-list
        (cl-concurrent-kit::%call-with-interruptible-scope
         (lambda (scope) (setf saved scope) (values :success 42))
         (lambda (scope reason)
           (declare (ignore scope reason))
           (error "A cleanup request interrupted a completed body"))
         (lambda ()
           (setf accepted
                 (cl-concurrent-kit::request-interruption saved :reason :late)))))
       :to-equal '(:success 42))
      (expect accepted :to-be nil)))

  (it "does not reinterrupt cleanup after a request has started unwinding"
    (let ((ready (make-semaphore)) (cleaning (make-semaphore))
          (release (make-semaphore)) saved cleaned)
      (let ((thread
              (make-thread
               (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (unwind-protect
                          (progn (signal-semaphore ready) (loop (sleep 0.1)))
                        (signal-semaphore cleaning)
                        (wait-or-fail release "cleanup was not released")
                        (setf cleaned t)))))))))
        (wait-or-fail ready "cleanup target did not start")
        (cl-concurrent-kit::request-interruption saved :reason :first)
        (wait-or-fail cleaning "cleanup did not start")
        (expect (cl-concurrent-kit::request-interruption saved :reason :second) :to-be nil)
        (signal-semaphore release)
        (expect (cl-concurrent-kit::operation-interrupted-reason
                 (join-thread thread :timeout 2)) :to-be :first)
        (expect cleaned :to-be t))))

  (it "unwinds an inner scope when the outer scope is interrupted"
    (let ((ready (make-semaphore)) outer inner cleaned)
      (let ((thread
              (make-thread
               (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf outer scope)
                      (cl-concurrent-kit::with-interruptible-scope (nested)
                        (setf inner nested)
                        (unwind-protect
                            (progn (signal-semaphore ready) (loop (sleep 0.1)))
                          (setf cleaned t))))))))))
        (wait-or-fail ready "nested scope did not start")
        (cl-concurrent-kit::request-interruption outer :reason :outer)
        (expect (cl-concurrent-kit::operation-interrupted-scope
                 (join-thread thread :timeout 2)) :to-be outer)
        (expect cleaned :to-be t)
        (expect (cl-concurrent-kit::request-interruption inner) :to-be nil))))

  (it "keeps nested scopes independent when only the inner is interrupted"
    (expect
     (cl-concurrent-kit::with-interruptible-scope (outer)
       (declare (ignore outer))
       (let ((condition
               (interruption-condition-of
                (lambda ()
                  (cl-concurrent-kit::with-interruptible-scope (inner)
                    (cl-concurrent-kit::request-interruption inner :reason :inner)
                    (loop (sleep 0.1)))))))
         (cl-concurrent-kit::operation-interrupted-reason condition)))
     :to-be :inner)))

(describe-concurrent "WITH-TIMEOUT interruptible boundary"
  (it "preserves an outer interruption delivered before the timeout body starts"
    (let ((condition
            (interruption-condition-of
             (lambda ()
               (cl-concurrent-kit::with-interruptible-scope (outer)
                 (sb-sys:without-interrupts
                   (cl-concurrent-kit::request-interruption outer :reason :outer)
                   (sb-sys:allow-with-interrupts
                     (with-timeout (cl-date-kit:duration-of-seconds 5)
                       (error "The inner body must not start")))))))))
      (expect condition :to-be-truthy)
      (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be :outer)))

  (it "preserves the caller's interrupt prohibition and makes its queued callback inert"
    (let (saved accepted result trace)
      (sb-sys:without-interrupts
        (setf result
              (cl-concurrent-kit::with-interruptible-scope (scope)
                (setf saved scope
                      accepted (cl-concurrent-kit::request-interruption scope :reason :queued))
                ;; FIFO puts this marker after the scope's own callback.
                (sb-thread:interrupt-thread (current-thread)
                                            (lambda () (push :queue-tail trace)))
                :success))
        (push :returned trace))
      (push :reenabled trace)
      (expect accepted :to-be t)
      (expect result :to-be :success)
      (expect (reverse trace) :to-equal '(:returned :queue-tail :reenabled))
      (expect (cl-concurrent-kit::request-interruption saved) :to-be nil)))


  (it "cannot be swallowed by ignore-errors and runs cleanup"
    (let (cleaned)
      (signals operation-timed-out
        (with-timeout +test-timeout-expiry+
          (unwind-protect (loop (ignore-errors (sleep 0.1)))
            (setf cleaned t))))
      (expect cleaned :to-be t)))

  (it "delivers an expired deadline when a protected body reenables interrupts"
    (signals operation-timed-out
      (with-timeout +test-timeout-expiry+
        (sb-sys:without-interrupts (sleep 0.1))
        (loop (sleep 0.1))))
    (expect (with-timeout (cl-date-kit:duration-of-seconds 5) (+ 20 22)) :to-be 42)))
