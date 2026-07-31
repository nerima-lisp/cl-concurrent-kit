;;;; t/package.lisp
(defpackage #:cl-concurrent-kit/test (:use #:cl)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
   #:it #:expect #:signals #:run-all
   #:it-property #:gen-integer #:gen-list #:gen-boolean
   #:with-continuation-result #:with-soft-assertions)
  (:import-from #:cl-concurrent-kit
   ;; Threads / locks / condition variables / semaphores / atomics
   #:make-thread #:current-thread #:thread-name #:thread-alive-p #:join-thread
   #:make-lock #:with-lock-held
   #:make-condition-variable #:condition-wait #:condition-notify #:condition-broadcast
   #:make-semaphore #:wait-on-semaphore #:signal-semaphore
   #:make-atomic-counter #:atomic-counter-value #:atomic-counter-incf #:atomic-counter-decf
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
   ;; Conditions
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
