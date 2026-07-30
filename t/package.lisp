;;;; t/package.lisp
(defpackage #:cl-concurrent-kit/test
  (:use #:cl)
  ;; DESCRIBE clashes with CL:DESCRIBE; nothing else needs shadowing.
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
   #:make-promise #:promise-settled-p #:deliver #:deliver-error #:await
   #:promise-then #:promise-race #:future
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
