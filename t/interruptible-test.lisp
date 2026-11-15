;;;; t/interruptible-test.lisp
(in-package #:cl-concurrent-kit/test)

(defun interruption-condition-of (thunk)
  (handler-case (progn (funcall thunk) nil)
    (cl-concurrent-kit::operation-interrupted (condition) condition)))

(defmacro with-interruption-worker ((thread thunk) &body checks)
  `(let ((,thread (make-thread
                    (lambda ()
                      (handler-case (funcall ,thunk)
                        (serious-condition (condition) condition))))))
     (unwind-protect (progn ,@checks)
       ;; A failed assertion must not leave a computing or cleanup worker alive.
       ;; The worker can finish between THREAD-ALIVE-P and TERMINATE-THREAD.
       (handler-case
           (when (thread-alive-p ,thread) (sb-thread:terminate-thread ,thread))
         (sb-thread:interrupt-thread-error () nil))
       (join-thread ,thread :timeout 2 :default nil)
       (expect (thread-alive-p ,thread) :to-be nil))))



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
      (with-interruption-worker (thread (lambda ()
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
                          (setf cleaned t)))))))) (wait-or-fail ready "interruptible body did not start")
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
      (with-interruption-worker (thread (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (signal-semaphore ready)
                      (handler-case (loop) (error () :swallowed))))))) (wait-or-fail ready "computing body did not start")
        (cl-concurrent-kit::request-interruption saved)
        (let ((condition (join-thread thread :timeout 2)))
          (expect condition :to-be-truthy)
          (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be nil)))))

  (it "uses a target-thread handler request as its last action"
    (let ((ready (make-semaphore)) saved handler-entered)
      (with-interruption-worker (thread (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (signal-semaphore ready)
                      (loop (sleep 0.1))))))) (wait-or-fail ready "handler target did not start")
        (sb-thread:interrupt-thread
         thread (lambda ()
                  (setf handler-entered t)
                  (cl-concurrent-kit::request-interruption saved :reason :signal)))
        (let ((condition (join-thread thread :timeout 2)))
          (expect handler-entered :to-be t)
          (expect (cl-concurrent-kit::operation-interrupted-reason condition) :to-be :signal)))))

  (it "keeps the first reason and defers delivery across WITHOUT-INTERRUPTS"
    (let ((ready (make-semaphore)) (release (make-semaphore)) saved first second)
      (with-interruption-worker (thread (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (sb-sys:without-interrupts
                        (signal-semaphore ready)
                        (wait-or-fail release "protected body was not released"))
                      (loop (sleep 0.1))))))) (wait-or-fail ready "protected body did not start")
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
      (with-interruption-worker (thread (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf saved scope)
                      (unwind-protect
                          (progn (signal-semaphore ready) (loop (sleep 0.1)))
                        (signal-semaphore cleaning)
                        (wait-or-fail release "cleanup was not released")
                        (setf cleaned t))))))) (wait-or-fail ready "cleanup target did not start")
        (cl-concurrent-kit::request-interruption saved :reason :first)
        (wait-or-fail cleaning "cleanup did not start")
        (expect (cl-concurrent-kit::request-interruption saved :reason :second) :to-be nil)
        (signal-semaphore release)
        (expect (cl-concurrent-kit::operation-interrupted-reason
                 (join-thread thread :timeout 2)) :to-be :first)
        (expect cleaned :to-be t))))

  (it "unwinds an inner scope when the outer scope is interrupted"
    (let ((ready (make-semaphore)) outer inner cleaned)
      (with-interruption-worker (thread (lambda ()
                 (interruption-condition-of
                  (lambda ()
                    (cl-concurrent-kit::with-interruptible-scope (scope)
                      (setf outer scope)
                      (cl-concurrent-kit::with-interruptible-scope (nested)
                        (setf inner nested)
                        (unwind-protect
                            (progn (signal-semaphore ready) (loop (sleep 0.1)))
                          (setf cleaned t)))))))) (wait-or-fail ready "nested scope did not start")
        (cl-concurrent-kit::request-interruption outer :reason :outer)
        (expect (cl-concurrent-kit::operation-interrupted-scope
                 (join-thread thread :timeout 2)) :to-be outer)
        (expect cleaned :to-be t)
        (expect (cl-concurrent-kit::request-interruption inner) :to-be nil))))

  (it "keeps nested scopes independent when only the inner is interrupted"
    (with-interruption-worker
        (thread
         (lambda ()
           (cl-concurrent-kit:with-interruptible-scope (outer)
             (declare (ignore outer))
             (let ((condition
                     (interruption-condition-of
                      (lambda ()
                        (cl-concurrent-kit:with-interruptible-scope (inner)
                          (cl-concurrent-kit:request-interruption inner :reason :inner)
                          (loop (sleep 0.1)))))))
               (cl-concurrent-kit:operation-interrupted-reason condition)))))
      (expect (join-thread thread :timeout 2) :to-be :inner))))

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


  (it "cannot notify a serious-condition handler in the body and runs cleanup"
    (let ((observed 0) cleaned)
      (with-interruption-worker
          (thread
           (lambda ()
             (handler-case
                 (with-timeout +test-timeout-expiry+
                   (handler-bind ((serious-condition
                                    (lambda (condition)
                                      (declare (ignore condition))
                                      (incf observed))))
                     (unwind-protect (loop (ignore-errors (sleep 0.1)))
                       (setf cleaned t))))
               (operation-timed-out (condition) condition))))
        (let ((condition (join-thread thread :timeout 2)))
          (expect (typep condition 'operation-timed-out) :to-be t))
        (expect observed :to-be 0)
        (expect cleaned :to-be t))))

  (it "delivers an expired deadline when a protected body reenables interrupts"
    (with-interruption-worker
        (thread (lambda ()
                  (timeout-condition-of
                   (lambda ()
                     (with-timeout +test-timeout-expiry+
                       (sb-sys:without-interrupts (sleep 0.1))
                       (loop (sleep 0.1)))))))
      (expect (typep (join-thread thread :timeout 2) 'operation-timed-out) :to-be t))
    (expect (with-timeout (cl-date-kit:duration-of-seconds 5) (+ 20 22)) :to-be 42)))

(describe-concurrent "forced interruption requests"
  (it "ignores a NIL scope with either request mode"
    (expect (cl-concurrent-kit:request-interruption nil) :to-be nil)
    (expect (cl-concurrent-kit:request-interruption nil :reason :absent :force t) :to-be nil))

  (it "ignores forced requests after a normal boundary has closed"
    (let (saved)
      (expect (cl-concurrent-kit:with-interruptible-scope (scope)
                (setf saved scope)
                :completed)
              :to-be :completed)
      (expect (cl-concurrent-kit:request-interruption saved :reason :late :force t) :to-be nil)
      (expect (cl-concurrent-kit:with-interruptible-scope (scope)
                (declare (ignore scope)) (+ 20 22)) :to-be 42)))

  (it "rejects forced requests during the boundary's own cleanup"
    (let (saved accepted)
      (expect
       (cl-concurrent-kit::%call-with-interruptible-scope
        (lambda (scope) (setf saved scope) :completed)
        (lambda (scope reason)
          (declare (ignore scope reason))
          (error "A closed boundary accepted an interruption"))
        (lambda ()
          (setf accepted
                (cl-concurrent-kit:request-interruption saved :reason :late :force t))))
       :to-be :completed)
      (expect accepted :to-be nil)))

  (it "reaches a live boundary while the first interruption is blocked in cleanup"
    (let ((ready (make-semaphore)) (cleaning (make-semaphore))
          (release (make-semaphore)) saved cleanup-finished)
      (with-interruption-worker
          (thread
           (lambda ()
             (interruption-condition-of
              (lambda ()
                (cl-concurrent-kit:with-interruptible-scope (scope)
                  (setf saved scope)
                  (unwind-protect
                      (progn (signal-semaphore ready) (loop (sleep 0.1)))
                    (signal-semaphore cleaning)
                    (wait-on-semaphore release)
                    (setf cleanup-finished t)))))))
        (unwind-protect
             (progn
               (wait-or-fail ready "force target did not start")
               (expect (cl-concurrent-kit:request-interruption saved :reason :first) :to-be t)
               (wait-or-fail cleaning "force target did not enter cleanup")
               (expect (cl-concurrent-kit:request-interruption saved :reason :ordinary) :to-be nil)
               (expect (cl-concurrent-kit:request-interruption saved :reason :forced :force t) :to-be t)
               (let ((condition (join-thread thread :timeout 2)))
                 (expect condition :to-be-truthy)
                 (expect (cl-concurrent-kit:operation-interrupted-reason condition) :to-be :forced))
               (expect cleanup-finished :to-be nil)
               (expect (cl-concurrent-kit:request-interruption saved :force t) :to-be nil))
          (signal-semaphore release)))))

  (it-each ((:error) (:throw))
      "escapes when cleanup suppresses the original transfer with ~A"
      (replacement)
    (let ((ready (make-semaphore)) (resumed (make-semaphore))
          (stop (make-semaphore)) saved)
      (with-interruption-worker
          (thread
           (lambda ()
             (interruption-condition-of
              (lambda ()
                (cl-concurrent-kit:with-interruptible-scope (scope)
                  (setf saved scope)
                  (flet ((body ()
                           (signal-semaphore ready)
                           (loop until (wait-on-semaphore stop :timeout 0.1))))
                    (ecase replacement
                      (:error
                       (handler-case (unwind-protect (body) (error "cleanup replaced interruption"))
                         (simple-error () nil)))
                      (:throw
                       (catch 'replacement
                         (unwind-protect (body) (throw 'replacement :replaced)))))
                    (signal-semaphore resumed)
                    (loop until (wait-on-semaphore stop :timeout 0.1))))))))
        (unwind-protect
             (progn
               (wait-or-fail ready "replacement target did not start")
               (cl-concurrent-kit:request-interruption saved :reason :first)
               (wait-or-fail resumed "cleanup did not replace the original transfer")
               (expect (cl-concurrent-kit:request-interruption saved :reason :ordinary) :to-be nil)
               (expect (cl-concurrent-kit:request-interruption saved :reason :forced :force t) :to-be t)
               (let ((condition (join-thread thread :timeout 2)))
                 (expect condition :to-be-truthy)
                 (expect (cl-concurrent-kit:operation-interrupted-reason condition) :to-be :forced)))
          (signal-semaphore stop)
          (signal-semaphore stop)))))

  (it "uses the latest accepted forced reason even before the first delivery"
    (let ((ready (make-semaphore)) (release (make-semaphore)) saved)
      (with-interruption-worker
          (thread
           (lambda ()
             (interruption-condition-of
              (lambda ()
                (cl-concurrent-kit:with-interruptible-scope (scope)
                  (setf saved scope)
                  (sb-sys:without-interrupts
                    (signal-semaphore ready)
                    (wait-or-fail release "pending-force target was not released"))
                  (loop (sleep 0.1)))))))
        (unwind-protect
             (progn
               (wait-or-fail ready "pending-force target did not start")
               (expect (cl-concurrent-kit:request-interruption saved :reason :normal) :to-be t)
               (expect (cl-concurrent-kit:request-interruption saved :reason :force-one :force t) :to-be t)
               (expect (cl-concurrent-kit:request-interruption saved :reason :force-two :force t) :to-be t)
               (expect (cl-concurrent-kit:request-interruption saved :reason :ordinary) :to-be nil)
               (signal-semaphore release)
               (expect (cl-concurrent-kit:operation-interrupted-reason
                        (join-thread thread :timeout 2)) :to-be :force-two))
          (signal-semaphore release)))))

  (it "a forced first request also rejects a later ordinary request"
    (let ((ready (make-semaphore)) (release (make-semaphore)) saved)
      (with-interruption-worker
          (thread
           (lambda ()
             (interruption-condition-of
              (lambda ()
                (cl-concurrent-kit:with-interruptible-scope (scope)
                  (setf saved scope)
                  (sb-sys:without-interrupts
                    (signal-semaphore ready)
                    (wait-or-fail release "first-force target was not released"))
                  (loop (sleep 0.1)))))))
        (unwind-protect
             (progn
               (wait-or-fail ready "first-force target did not start")
               (expect (cl-concurrent-kit:request-interruption saved :reason :forced :force t) :to-be t)
               (expect (cl-concurrent-kit:request-interruption saved :reason :ordinary) :to-be nil)
               (signal-semaphore release)
               (expect (cl-concurrent-kit:operation-interrupted-reason
                        (join-thread thread :timeout 2)) :to-be :forced))
          (signal-semaphore release)))))

  (it-each ((:error) (:throw))
      "an ordinary first request can replace a ~A exit during user cleanup"
      (original)
    (let ((cleaning (make-semaphore)) (release (make-semaphore)) saved)
      (with-interruption-worker
          (thread
           (lambda ()
             (interruption-condition-of
              (lambda ()
                (catch 'original
                  (cl-concurrent-kit:with-interruptible-scope (scope)
                    (setf saved scope)
                    (unwind-protect
                        (ecase original
                          (:error (error "original body failure"))
                          (:throw (throw 'original :original)))
                      (signal-semaphore cleaning)
                      (wait-on-semaphore release))))))))
        (unwind-protect
             (progn
               (wait-or-fail cleaning "body exit did not reach user cleanup")
               (expect (cl-concurrent-kit:request-interruption saved :reason :replacement) :to-be t)
               (expect (cl-concurrent-kit:operation-interrupted-reason
                        (join-thread thread :timeout 2)) :to-be :replacement))
          (signal-semaphore release))))))


(describe "POSIX interruption handler"
  (it "uses a real signal and requests interruption as the handler's last action"
    (let* ((source (asdf:system-source-file "cl-concurrent-kit"))
           (child (asdf:system-relative-pathname "cl-concurrent-kit"
                                                 "t/interruptible-signal-child.lisp"))
           (process
             (uiop:launch-program
              (list (namestring sb-ext:*runtime-pathname*)
                    "--noinform" "--no-sysinit" "--no-userinit" "--disable-debugger"
                    "--script" (namestring child) (namestring source))
              :input :stream :output :stream :error-output :output)))
      (unwind-protect
           (progn
             ;; The existing 20s testcase deadline also bounds child startup.
             (loop for line = (read-line (uiop:process-info-output process) nil nil)
                   collect line into startup
                   when (null line)
                     do (error "POSIX child exited before readiness: ~{~A~%~}" startup)
                   until (string= line "K2-POSIX-READY"))
             (with-interruption-worker
                 (thread
                  (lambda ()
                    (let ((output (uiop:slurp-stream-string (uiop:process-info-output process))))
                      (values (uiop:wait-process process) output))))
               (write-char #\g (uiop:process-info-input process))
               (finish-output (uiop:process-info-input process))
               (multiple-value-bind (exit output) (join-thread thread :timeout 2)
                 (unless (zerop exit) (error "POSIX child failed: ~A" output))
                 (expect exit :to-be 0)
                 (expect (search "POSIX last-action interruption verified" output) :to-be-truthy))))
        (when (uiop:process-alive-p process)
          (uiop:terminate-process process :urgent t))
        (close (uiop:process-info-input process) :abort t)
        (close (uiop:process-info-output process) :abort t)
        (uiop:wait-process process)))))

(describe-concurrent "WITH-TIMEOUT injectable clock"
  (it "rearms an early timer and expires after the bound clock advances"
    (let ((early (make-semaphore))
          (reached-early nil)
          (clock-calls 0))
      (with-interruption-worker
          (thread
           (lambda ()
             (let ((now 100))
               (let ((cl-concurrent-kit:*clock*
                       (lambda ()
                         (when (= (incf clock-calls) 2)
                           (signal-semaphore early))
                         now)))
                 (with-timeout +test-timeout-expiry+
                   (setf reached-early (wait-on-semaphore early :timeout 1))
                   (incf now internal-time-units-per-second)
                   (sleep 5))))))
        (let ((condition (join-thread thread :timeout 2)))
          (expect reached-early :to-be-truthy)
          (expect (>= clock-calls 3) :to-be t)
          (expect (typep condition 'operation-timed-out) :to-be t)
          (expect (operation-timed-out-timeout condition) :to-be 1/20)))))

  (it "keeps the entry clock when the body rebinds the special variable"
    (let ((entry-calls 0)
          (body-clock-calls 0))
      (with-interruption-worker
          (thread
           (lambda ()
             (let ((cl-concurrent-kit:*clock*
                     (lambda ()
                       (* (incf entry-calls) internal-time-units-per-second))))
               (with-timeout +test-timeout-expiry+
                 (let ((cl-concurrent-kit:*clock*
                         (lambda ()
                           (incf body-clock-calls)
                           (error "The timeout used the body's clock."))))
                   (loop (sleep 0.1)))))))
        (let ((condition (join-thread thread :timeout 2)))
          (expect (>= entry-calls 2) :to-be t)
          (expect body-clock-calls :to-be 0)
          (expect (typep condition 'operation-timed-out) :to-be t)))))

  (it "does not read the clock or rearm a callback after closure"
    (with-interruption-worker
        (thread
         (lambda ()
           (let ((clock-calls 0)
                 (before (sb-ext:list-all-timers))
                 timer callback)
             (let ((cl-concurrent-kit:*clock*
                     (lambda () (incf clock-calls) 100)))
               (with-timeout (cl-date-kit:duration-of-seconds 5)
                 ;; SBCL has no public callback/thread readers. Retain this
                 ;; actual timer callback to exercise a late invocation.
                 (setf timer
                       (find-if
                        (lambda (candidate)
                          (and (not (member candidate before))
                               (eq (sb-impl::%timer-thread candidate)
                                   (current-thread))))
                        (sb-ext:list-all-timers))
                       callback (sb-impl::%timer-function timer))))
             (let ((calls-before clock-calls))
               (funcall callback)
               (values calls-before clock-calls
                       (sb-ext:timer-scheduled-p timer))))))
      (multiple-value-bind (before after scheduled) (join-thread thread :timeout 2)
        (expect before :to-be 1)
        (expect after :to-be before)
        (expect scheduled :to-be nil)))))

(describe-concurrent "interruptible scope barrier cancellation"
  (it "preserves cancellation before barrier arrival inside an interruptible scope"
    (let ((barrier (make-barrier 2))
          (task-scope (cl-concurrent-kit::%make-task-scope)))
      (cl-concurrent-kit::%scope-cancel task-scope)
      (cl-concurrent-kit:with-interruptible-scope (target)
        (declare (ignore target))
        (signals task-cancelled
          (await-barrier barrier :timeout +test-timeout+ :scope task-scope)))
      (expect (barrier-broken-p barrier) :to-be-truthy)
      (expect (barrier-number-waiting barrier) :to-be 0)
      (signals barrier-broken
        (await-barrier barrier :timeout +test-timeout+)))))

(describe-concurrent "interruptible barrier waits"
  (it "breaks an interrupted generation and wakes its other waiter"
    (let ((barrier (make-barrier 3))
          (ready (make-semaphore))
          target)
      (with-interruption-worker
          (sibling (lambda () (await-barrier barrier)))
        (with-interruption-worker
            (thread
             (lambda ()
               (cl-concurrent-kit:with-interruptible-scope (scope)
                 (setf target scope)
                 (signal-semaphore ready)
                 (await-barrier barrier))))
          (wait-or-fail ready "interruptible barrier waiter did not start")
          (expect (loop repeat 1000
                        when (= (barrier-number-waiting barrier) 2) return t
                        do (sleep 0.001)
                        finally (return nil)) :to-be t)
          (expect (cl-concurrent-kit:request-interruption target :reason :barrier)
                  :to-be t)
          (expect (typep (join-thread thread :timeout 2)
                         'cl-concurrent-kit:operation-interrupted) :to-be t)
          (expect (barrier-number-waiting barrier) :to-be 0)
          (expect (barrier-broken-p barrier) :to-be t)
          (expect (typep (join-thread sibling :timeout 2) 'barrier-broken) :to-be t)
          (signals barrier-broken (await-barrier barrier :timeout +test-timeout+))))))

  (it "does not break a newer generation when an old waiter unwinds late"
    (let ((barrier (make-barrier 2))
          (ready (make-semaphore))
          (paused (make-semaphore))
          (resume (make-semaphore))
          target)
      (with-interruption-worker
          (old-waiter
           (lambda ()
             (cl-concurrent-kit:with-interruptible-scope (scope)
               (setf target scope)
               (signal-semaphore ready)
               (await-barrier barrier))))
        (unwind-protect
            (progn
              (wait-or-fail ready "old barrier waiter did not start")
              (expect (loop repeat 1000
                            when (= (barrier-number-waiting barrier) 1) return t
                            do (sleep 0.001)
                            finally (return nil)) :to-be t)
              ;; Holding the mutex ensures the paused waiter cannot own it.
              ;; Finish its generation before requesting the old scope's exit.
              (with-lock-held ((cl-concurrent-kit::%barrier-lock barrier))
                (sb-thread:interrupt-thread
                 old-waiter
                 (lambda ()
                   (signal-semaphore paused)
                   (wait-on-semaphore resume :timeout 1)))
                (wait-or-fail paused "old barrier waiter did not pause"))
              (expect (await-barrier barrier :timeout +test-timeout+) :to-be 0)
              (with-interruption-worker
                  (new-waiter (lambda () (await-barrier barrier)))
                (expect (loop repeat 1000
                              when (= (barrier-number-waiting barrier) 1) return t
                              do (sleep 0.001)
                              finally (return nil)) :to-be t)
                (expect (cl-concurrent-kit:request-interruption target :reason :late)
                        :to-be t)
                (signal-semaphore resume)
                (expect (typep (join-thread old-waiter :timeout 2)
                               'cl-concurrent-kit:operation-interrupted) :to-be t)
                (expect (barrier-broken-p barrier) :to-be nil)
                (expect (barrier-number-waiting barrier) :to-be 1)
                (expect (await-barrier barrier :timeout +test-timeout+) :to-be 0)
                (expect (join-thread new-waiter :timeout 2) :to-be 1)
                (expect (barrier-number-waiting barrier) :to-be 0)))
          (signal-semaphore resume))))))
