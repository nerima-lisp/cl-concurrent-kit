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
   #:await
   #:promise-then
   #:promise-race
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
   #:shutdown-executor

   ;; Structured concurrency
   #:with-task-scope
   #:spawn
   #:check-cancelled

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
   #:scope-error-causes))

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
