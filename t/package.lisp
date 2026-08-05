;;;; t/package.lisp
(defpackage #:cl-concurrent-kit/test (:use #:cl)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
   #:it #:expect #:signals #:run-all
   #:describe-concurrent
   #:it-property #:it-fuzz #:gen-integer #:gen-list #:gen-boolean
   #:with-continuation-result #:with-soft-assertions
   #:it-each #:around-each #:with-replaced-function)
  (:import-from #:cl-concurrent-kit
   ;; Threads / locks / condition variables / semaphores / atomics
   #:make-thread #:current-thread #:thread-name #:thread-alive-p #:join-thread
   #:lock #:make-lock #:with-lock-held
   #:make-condition-variable #:condition-wait #:condition-notify #:condition-broadcast
   #:make-semaphore #:wait-on-semaphore #:signal-semaphore
   #:make-atomic-counter #:atomic-counter-value #:atomic-counter-incf #:atomic-counter-decf
   ;; Preemptive deadlines
   #:with-timeout
   ;; Promises / futures
   #:make-promise #:promise-p #:promise-settled-p #:deliver #:deliver-error #:cancel-promise
   #:await #:future
   #:promise-then #:promise-catch #:promise-finally #:promise-race #:promise-all-settled
   #:promise-all #:promise-any #:promise-timeout
   #:promise-settlement-p #:promise-settlement-state #:promise-settlement-value
   #:promise-settlement-condition
   ;; Channels
   #:make-channel #:channel-p #:send #:recv #:try-send #:try-recv #:close-channel
   #:channel-closed-p
   ;; Select
   #:select
   ;; Executors
   #:make-executor #:executor-p #:submit #:try-submit #:shutdown-executor
   #:await-executor-termination #:with-executor #:executor-map
   #:executor-shutdown-p #:executor-terminated-p
   #:executor-queue-capacity #:executor-queue-depth #:executor-high-water-mark
   ;; Structured concurrency
   #:with-task-scope #:spawn #:check-cancelled
   ;; Countdown latches
   #:make-countdown-latch #:countdown-latch-count #:count-down #:await-latch
   ;; Cyclic barriers
   #:make-barrier #:barrier-parties #:barrier-number-waiting #:barrier-broken-p
   #:await-barrier #:reset-barrier
   ;; Reactive streams
   #:channel-producer #:channel-from-sequence
   #:channel-map #:channel-keep #:channel-filter #:channel-distinct-until-changed
   #:channel-debounce #:channel-flat-map #:channel-throttle #:channel-scan
   #:channel-reduce #:channel-collect #:channel-each #:channel-some #:channel-every
   #:channel-find
   #:channel-broadcast #:channel-take #:channel-drop #:channel-take-while #:channel-batch
   #:channel-partition-by
   #:channel-map-concurrent #:channel-map-unordered
   #:channel-merge #:channel-zip #:channel-concat #:channel-concat-map
   #:channel-merge-map #:channel-switch-map
   ;; Conditions
   #:cl-concurrent-kit-error
   #:operation-timed-out #:operation-timed-out-operation #:operation-timed-out-timeout
   #:promise-already-fulfilled #:promise-already-fulfilled-promise
   #:channel-closed #:channel-closed-channel
   #:executor-shut-down #:executor-shut-down-executor
   #:task-cancelled #:task-cancelled-scope
   #:scope-error #:scope-error-causes
   #:latch-count-underflow
   #:barrier-broken
   #:promise-cancelled #:promise-cancelled-promise #:promise-cancelled-reason
   #:promise-empty-input #:promise-all-failed #:promise-all-failed-causes
   #:executor-queue-full #:executor-queue-full-executor #:executor-queue-full-capacity)
  (:export #:run-tests))

(in-package #:cl-concurrent-kit/test)

(defparameter +test-timeout+ (cl-date-kit:duration-of-seconds 1)
  "The \"long enough that a correct wait won't hit it\" deadline used by nearly
every test in this suite that needs some bound to avoid hanging forever on a
real bug, without ever expecting to actually expire.")

(defparameter +test-timeout-long+ (cl-date-kit:duration-of-seconds 2)
  "Same role as +TEST-TIMEOUT+, doubled for suites whose own delay budget
needs more headroom.")

(defparameter +test-timeout-expiry+ (cl-date-kit:duration-of-millis 50)
  "The \"short enough that a test can deliberately let it expire\" deadline
used by tests asserting OPERATION-TIMED-OUT actually fires.")

(defparameter +test-timeout-brief+ (cl-date-kit:duration-of-millis 10)
  "Shorter than +TEST-TIMEOUT-EXPIRY+, for tests racing two expiries against
each other or wanting the tightest deliberate-expiry margin.")

(defun wait-or-fail (semaphore what)
  "WAIT-ON-SEMAPHORE for up to one second, signalling a plain ERROR naming
WHAT if it is never signalled -- the \"did the other thread reach its
checkpoint\" guard nearly every synchronization test in this suite needs
before it can safely act on state that thread owns."
  (unless (wait-on-semaphore semaphore :timeout 1)
    (error "~A" what)))

(defun run-tests ()
  "Run every registered spec, signalling on any failure so ASDF's TEST-OP
fails."
  (unless (run-all :reporter :spec :timeout-ms 20000)
    (error "cl-concurrent-kit test suite failed"))
  (format t "~&cl-concurrent-kit/test: successful completion with 0 failures~%")
  t)

(defun occupy-worker (executor)
  "Submit a task to EXECUTOR that blocks until released, wait for it to
actually claim a worker, and return a RELEASE semaphore the caller signals
once that task should finish. The confirmation this waits on is what several
tests below need before submitting further work of their own: a task still
merely queued, not yet claimed by a worker, would leave EXECUTOR-QUEUE-DEPTH
one higher than a caller expecting a single occupied worker plus its own
submissions."
  (let ((started (make-semaphore))
        (release (make-semaphore)))
    (submit executor (lambda () (signal-semaphore started) (wait-on-semaphore release)))
    (wait-or-fail started "occupied worker did not start")
    release))

(defmacro expect-signals ((condition-var condition-type) form &body checks)
  "Evaluate FORM, expecting it to signal a CONDITION-TYPE condition instead of
returning normally, and bind CONDITION-VAR to the caught condition for CHECKS
-- a body of further EXPECT forms -- to inspect. Fails the test with a plain
ERROR if FORM returns normally instead. The richer counterpart to cl-weave's
own SIGNALS: SIGNALS only checks that some condition of a given type was
signaled, while EXPECT-SIGNALS also hands the caller the condition itself, for
tests that must inspect which promise, channel, or executor a condition names."
  `(handler-case
       (progn ,form (error "expected ~S to signal ~S but it returned normally" ',form ',condition-type))
     (,condition-type (,condition-var)
       ,@checks)))

(defun drain-channel (channel &key (timeout +test-timeout+))
  "Receive every value from CHANNEL until it closes, returning them as a
list in receive order. Blocks up to TIMEOUT -- a CL-DATE-KIT:DURATION -- per
RECV, the common \"run a stage to completion and collect its output\" shape
nearly every stream stage test needs."
  (loop for value = (recv channel :timeout timeout)
        while value
        collect value))

(defmacro with-cancelled-scope ((scope) &body body)
  "Run BODY inside a fresh WITH-TASK-SCOPE that also SPAWNs a sibling task
which immediately fails, cancelling every other task in the scope
cooperatively, then swallow the resulting SCOPE-ERROR -- the common
\"confirm a blocked operation observes cancellation\" test shape. BODY is
responsible for recording whatever it needs to EXPECT afterward, since the
SCOPE-ERROR itself carries no information a caller here wants."
  `(handler-case
       (with-task-scope (,scope)
         (spawn ,scope (lambda () (error "boom")))
         ,@body)
     (scope-error () nil)))
