;;;; src/package.lisp
;;;;
;;;; The single public package. Layers build on each other in the order they
;;;; are loaded (per cl-concurrent-kit.asd's :serial t): primitives wrap
;;;; sb-thread; fifo is a private queue shared by channel and executor;
;;;; promises (split into promise and promise-combinators), channels,
;;;; executors, and scopes (split into scope-state and scope) are built on
;;;; primitives alone, not on each other, except where noted.
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

;; SPEED 1 (SBCL's default) is what triggers this, confirmed by bisection: at
;; SPEED 0 the whole system compiles in milliseconds; at SPEED 1 or above,
;; SBCL 2.6.0's constraint-propagation pass on SRC/SCOPE.LISP's SPAWN-CHILD
;; -- once SRC/SELECT.LISP, SRC/EXECUTOR.LISP, and SRC/SCOPE-STATE.LISP have
;; all already contributed their own type information to the same image --
;; does not return in any practical time. This lock-and-condition-variable
;; coordination code is never the bottleneck a caller notices (the mutex
;; acquisition and OS-level wait it wraps dominate every measurable cost by
;; orders of magnitude), so trading SPEED for a compiler that terminates
;; costs nothing real. Global, not local to one file: the pathology is
;; triggered by type information SBCL already carried in from files compiled
;; earlier in this same image, so a per-file declaim on SCOPE.LISP alone does
;; not avoid it.
(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))

(in-package #:cl-concurrent-kit)
