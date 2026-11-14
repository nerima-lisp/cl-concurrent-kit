;;;; src/timeout.lisp
;;;;
;;;; Preemptive interruption and deadlines share one lifetime protocol.
;;;; Requests target an opaque scope object, implemented as a closure over
;;;; the target thread, its live state, and a mutex. Checking that state
;;;; and enqueueing an interrupt are one serialized operation. Closing the
;;;; scope uses the same mutex, then drains queued callbacks while they can
;;;; still see the live boundary but can no longer leave it.
;;;;
;;;; An interrupt transfers control without signaling inside user code.
;;;; The boundary reports the interruption after user cleanup has unwound.
;;;; All state transitions run without interrupts so a signal handler cannot
;;;; request a scope while its target holds that scope's mutex. A request
;;;; from a handler must be its last operation: delivery can precede return.
;;;; Ordinary requests are accepted once; forced requests can retry during
;;;; user cleanup. Only reaching this boundary's own cleanup closes it.
;;;; WITH-TIMEOUT adds a timer and uses exactly this same protocol.
(in-package #:cl-concurrent-kit)

(%define-kit-condition operation-interrupted
    ((scope "The interruptible scope that received the request.")
     (reason "The first accepted reason, replaced by each accepted forced reason."))
  ("Operation interrupted: ~S." (operation-interrupted-reason condition))
  "Signaled at an interruptible scope boundary after its body has unwound.")

(defun %call-with-interruptible-scope (thunk interrupted &optional (cleanup #'values))
  (let ((thread (current-thread))
        (lock (make-lock))
        (live t)
        (requested nil)
        (delivered nil)
        (reason nil)
        scope)
    (multiple-value-prog1
        (block boundary
          (sb-sys:without-interrupts
            (setf scope
                  (lambda (requested-reason force)
                    (sb-sys:without-interrupts
                      (with-lock-held (lock)
                        (when (and live (or force (not requested)))
                          ;; Acceptance and enqueue share the closing lock.
                          ;; A forced request supersedes the previously accepted
                          ;; reason even when that earlier callback is pending.
                          (setf requested t reason requested-reason)
                          (sb-thread:interrupt-thread
                           thread
                           (lambda ()
                             (sb-sys:without-interrupts
                               (when (with-lock-held (lock)
                                       (when live (setf delivered t)))
                                 ;; Keep the target live during user cleanup.
                                 ;; FORCE can retry if cleanup blocks or replaces
                                 ;; this transfer and resumes the body.
                                 (return-from boundary (values))))))
                          t)))))
            (unwind-protect
                (sb-sys:with-local-interrupts (funcall thunk scope))
              ;; This is the boundary's cleanup, reached only after the thunk
              ;; returns or its user cleanup finishes. Close before our own
              ;; cleanup so even FORCE cannot change a completed result.
              (with-lock-held (lock) (setf live nil))
              (unwind-protect (funcall cleanup)
                ;; Callback enqueue completed under the closing lock. When the
                ;; caller allows interrupts, drain the now-inert callbacks here.
                (sb-sys:with-local-interrupts nil)))))
      (when delivered
        (funcall interrupted scope reason)))))


(defmacro with-interruptible-scope ((scope) &body body)
  "Run BODY in the current thread, binding SCOPE to its interruption target.
An accepted request queues a direct transfer to this boundary. After BODY has
unwound, signal OPERATION-INTERRUPTED with SCOPE and the accepted reason.
Handlers inside BODY do not observe this condition. User cleanup can replace
the transfer or block it; a forced request can cut that cleanup short and retry
the transfer while the boundary is live. A request during BODY's error or THROW
cleanup can replace that exit. Normal completion preserves all values.

The boundary closes before its own cleanup. Acceptance alone does not prove
delivery: a queued callback can lose the race to closing and become inert.
WITHOUT-INTERRUPTS and GC can delay delivery. A caller prohibiting interrupts
also delays physical draining until it reenables them; the closed callbacks
remain inert. BODY must be safe to unwind asynchronously."
  `(%call-with-interruptible-scope
    (lambda (,scope) ,@body)
    (lambda (target reason)
      (error 'operation-interrupted :scope target :reason reason))))


(defun request-interruption (scope &key reason force)
  "Request interruption of SCOPE with REASON, defaulting to NIL.
Return NIL for a NIL or closed SCOPE. An ordinary request is accepted only
once. With FORCE non-NIL, accept and enqueue again while the boundary is live,
including during user cleanup or after cleanup has suppressed an earlier
transfer. FORCE can abandon remaining user cleanup. Each accepted forced
request replaces the reason; the latest accepted forced reason is reported.

T means accepted, not delivered: the boundary can close before a queued
callback executes. FORCE neither reopens a closed boundary nor overrides the
caller's interrupt prohibition. In a signal handler this call must be the last
operation, because enabling interrupts may deliver before the handler returns."
  (when scope (funcall scope reason force)))


(defun %call-with-timeout (duration thunk)
  (let ((seconds (and duration (cl-date-kit:duration-to-seconds duration))))
    (if (and seconds (plusp seconds))
        ;; The boundary can receive an outer interruption before its thunk
        ;; starts. Construct the unscheduled timer first so cleanup always
        ;; owns a real timer, including along that entry path.
        (let* (target
               (timer (sb-ext:make-timer
                       (lambda () (request-interruption target :reason :timeout))
                       :thread (current-thread))))
          (%call-with-interruptible-scope
           (lambda (scope)
             (setf target scope)
             (sb-ext:schedule-timer timer seconds)
             (funcall thunk))
           (lambda (scope reason)
             (declare (ignore scope reason))
             (error 'operation-timed-out :operation :with-timeout :timeout seconds))
           (lambda () (sb-ext:unschedule-timer timer))))
        (funcall thunk))))



(defmacro with-timeout (duration &body body)
  "Run BODY under a preemptive deadline of DURATION (a CL-DATE-KIT:DURATION).
Return all values on normal completion. On expiry, transfer control directly
to the boundary, unwind BODY, then signal OPERATION-TIMED-OUT with operation
:WITH-TIMEOUT and the timeout in seconds. Handlers inside BODY do not observe
this condition. A timer arriving after BODY has returned cannot change its
successful result. DURATION is evaluated once; NIL, zero and negative durations
run BODY without a deadline.

Nested deadlines have independent targets. A direct SB-EXT:WITH-TIMEOUT in
BODY keeps its own condition. WITHOUT-INTERRUPTS and GC may delay delivery.
As with WITH-INTERRUPTIBLE-SCOPE, BODY must be safe to unwind asynchronously;
for cooperative cancellation of resource-owning work, use WITH-TASK-SCOPE."
  `(%call-with-timeout ,duration (lambda () ,@body)))

