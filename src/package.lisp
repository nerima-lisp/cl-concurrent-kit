;;;; src/package.lisp
;;;;
;;;; The single public package. Layers build on each other in the order they
;;;; are listed below (and loaded, per cl-concurrent-kit.asd's :serial t):
;;;; primitives wrap sb-thread; promises, channels, executors, and scopes are
;;;; built on primitives alone, not on each other, except where noted.
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
   #:task-cancelled
   #:task-cancelled-scope
   #:scope-error
   #:scope-error-causes))

(in-package #:cl-concurrent-kit)
