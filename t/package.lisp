;;;; t/package.lisp
(defpackage #:cl-concurrent-kit/test
  (:use #:cl)
  ;; DESCRIBE clashes with CL:DESCRIBE; nothing else needs shadowing.
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
   #:it #:expect #:signals #:run-all)
  (:import-from #:cl-concurrent-kit
   ;; Threads / locks / condition variables / semaphores / atomics
   #:make-thread #:current-thread #:thread-alive-p #:join-thread
   #:make-lock #:with-lock-held
   #:make-condition-variable #:condition-wait #:condition-notify #:condition-broadcast
   #:make-semaphore #:wait-on-semaphore #:signal-semaphore
   #:make-atomic-counter #:atomic-counter-value #:atomic-counter-incf #:atomic-counter-decf
   ;; Promises / futures
   #:make-promise #:promise-settled-p #:deliver #:deliver-error #:await #:future
   ;; Channels
   #:make-channel #:send #:recv #:try-send #:try-recv #:close-channel #:channel-closed-p
   ;; Select
   #:select
   ;; Executors
   #:make-executor #:submit #:shutdown-executor
   ;; Structured concurrency
   #:with-task-scope #:spawn #:check-cancelled
   ;; Conditions
   #:operation-timed-out #:promise-already-fulfilled #:channel-closed
   #:task-cancelled #:scope-error #:scope-error-causes)
  (:export #:run-tests))

(in-package #:cl-concurrent-kit/test)

(defun run-tests ()
  "Run every registered spec, signalling on any failure so ASDF's TEST-OP
fails."
  (unless (run-all :reporter :spec :timeout-ms 20000)
    (error "cl-concurrent-kit test suite failed"))
  (format t "~&cl-concurrent-kit/test: successful completion with 0 failures~%")
  t)
