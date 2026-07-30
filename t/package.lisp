;;;; t/package.lisp
(defpackage #:cl-concurrent-kit/test (:use #:cl)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave #:it #:expect #:signals #:run-all)
  (:import-from
    #:cl-concurrent-kit
    #:make-thread
    #:thread-name
    #:thread-alive-p
    #:join-thread
    #:make-lock
    #:with-lock-held
    #:make-condition-variable
    #:condition-wait
    #:condition-notify
    #:condition-broadcast
    #:make-semaphore
    #:wait-on-semaphore
    #:signal-semaphore
    #:make-atomic-counter
    #:atomic-counter-value
    #:atomic-counter-incf
    #:atomic-counter-decf
    #:make-promise
    #:promise-p
    #:promise-settled-p
    #:deliver
    #:deliver-error
    #:await
    #:future
    #:promise-all-settled
    #:promise-settlement-p
    #:promise-settlement-state
    #:promise-settlement-value
    #:promise-settlement-condition
    #:make-channel
    #:channel-p
    #:send
    #:recv
    #:try-send
    #:try-recv
    #:close-channel
    #:channel-closed-p
    #:select
    #:make-executor
    #:executor-p
    #:submit
    #:shutdown-executor
    #:with-task-scope
    #:spawn
    #:check-cancelled
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
    #:scope-error-causes)
  (:export #:run-tests))

(in-package #:cl-concurrent-kit/test)

(defun run-tests ()
  "Run every registered spec, signalling on any failure so ASDF's TEST-OP
fails."
  (unless (run-all :reporter :spec :timeout-ms 20000)
    (error "cl-concurrent-kit test suite failed"))
  (format t "~&cl-concurrent-kit/test: successful completion with 0 failures~%")
  t)
