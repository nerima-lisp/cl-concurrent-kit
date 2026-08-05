;;;; src/package.lisp
;;;;
;;;; The single public package. Layers build on each other in the order they
;;;; are loaded (per cl-concurrent-kit.asd's :serial t): primitives wrap
;;;; sb-thread; promises (split into promise and promise-combinators),
;;;; channels, executors, and scopes (split into scope-state and scope) are
;;;; built on primitives alone, not on each other, except where noted.
;;;; CHANNEL and the executor's internal queue each keep their own
;;;; preallocated ring buffer rather than sharing a queue implementation.
(defpackage #:cl-concurrent-kit
  (:use #:cl)
  (:export
   ;; Threads
   #:make-thread
   #:current-thread
   #:thread-name
   #:thread-alive-p
   #:join-thread

   ;; Locks
   #:lock
   #:make-lock
   #:with-lock-held

   ;; Condition variables
   #:make-condition-variable
   #:condition-wait
   #:condition-notify
   #:condition-broadcast

   ;; Semaphores
   #:make-semaphore
   #:wait-on-semaphore
   #:signal-semaphore

   ;; Atomic counters
   #:make-atomic-counter
   #:atomic-counter-value
   #:atomic-counter-incf
   #:atomic-counter-decf

   ;; Preemptive deadlines
   #:with-timeout

   ;; Deadline clock, rebound to a CL-BOUNDARY-KIT:FAKE-CLOCK in tests
   #:*clock*

   ;; Promises / futures
   #:make-promise
   #:promise-p
   #:promise-settled-p
   #:promise-all-settled
   #:promise-settlement
   #:promise-settlement-p
   #:promise-settlement-state
   #:promise-settlement-value
   #:promise-settlement-condition
   #:deliver
   #:deliver-error
   #:cancel-promise
   #:await
   #:promise-then
   #:promise-catch
   #:promise-finally
   #:promise-race
   #:promise-all
   #:promise-any
   #:promise-timeout
   #:future

   ;; Channels (CSP)
   #:make-channel
   #:channel-p
   #:send
   #:recv
   #:try-send
   #:try-recv
   #:close-channel
   #:channel-closed-p

   ;; Select
   #:select

   ;; Executors (thread pools)
   #:make-executor
   #:executor-p
   #:submit
   #:try-submit
   #:shutdown-executor
   #:await-executor-termination
   #:with-executor
   #:executor-map
   #:executor-shutdown-p
   #:executor-terminated-p
   #:executor-queue-capacity
   #:executor-queue-depth
   #:executor-high-water-mark

   ;; Structured concurrency
   #:with-task-scope
   #:spawn
   #:check-cancelled

   ;; Countdown latches
   #:make-countdown-latch
   #:countdown-latch-p
   #:countdown-latch-count
   #:count-down
   #:await-latch

   ;; Cyclic barriers
   #:make-barrier
   #:barrier-p
   #:barrier-parties
   #:barrier-number-waiting
   #:barrier-broken-p
   #:await-barrier
   #:reset-barrier

   ;; Reactive streams (built on channels)
   #:channel-producer
   #:channel-from-sequence
   #:channel-map
   #:channel-keep
   #:channel-filter
   #:channel-distinct-until-changed
   #:channel-debounce
   #:channel-flat-map
   #:channel-throttle
   #:channel-scan
   #:channel-reduce
   #:channel-collect
   #:channel-each
   #:channel-some
   #:channel-every
   #:channel-find
   #:channel-broadcast
   #:channel-take
   #:channel-drop
   #:channel-take-while
   #:channel-batch
   #:channel-partition-by
   #:channel-map-concurrent
   #:channel-map-unordered
   #:channel-merge
   #:channel-zip
   #:channel-concat
   #:channel-concat-map
   #:channel-merge-map
   #:channel-switch-map

   ;; Conditions
   #:cl-concurrent-kit-error
   #:operation-timed-out
   #:operation-timed-out-operation
   #:operation-timed-out-timeout
   #:promise-already-fulfilled
   #:promise-already-fulfilled-promise
   #:channel-closed
   #:channel-closed-channel
   #:executor-shut-down
   #:executor-shut-down-executor
   #:task-cancelled
   #:task-cancelled-scope
   #:scope-error
   #:scope-error-causes
   #:latch-count-underflow
   #:latch-count-underflow-latch
   #:latch-count-underflow-count
   #:latch-count-underflow-decrement
   #:barrier-broken
   #:barrier-broken-barrier
   #:promise-cancelled
   #:promise-cancelled-promise
   #:promise-cancelled-reason
   #:promise-empty-input
   #:promise-empty-input-operation
   #:promise-all-failed
   #:promise-all-failed-causes
   #:executor-queue-full
   #:executor-queue-full-executor
   #:executor-queue-full-capacity))

;; This file used to carry a global (DECLAIM (OPTIMIZE (SPEED 0) ...)) here.
;; It has moved to cl-concurrent-kit.asd's :AROUND-COMPILE, whose comment
;; records both why the policy exists and why a DECLAIM was the wrong place
;; for it. Nothing replaces it here on purpose: a DECLAIM in this file is
;; either too narrow (SBCL scopes an OPTIMIZE proclamation to the file being
;; compiled or loaded, so it never reached the other sixteen) or, if it were
;; not, too broad (it would still be in force for whatever a consumer compiles
;; after loading us).

(in-package #:cl-concurrent-kit)
