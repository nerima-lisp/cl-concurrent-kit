;;;; src/timeout.lisp
;;;;
;;;; Preemptive interruption and deadlines share one lifetime protocol.
;;;; Requests target an opaque scope object, implemented as a closure over
;;;; the target thread, its active state, and a mutex. Checking that state
;;;; and enqueueing an interrupt are one serialized operation. Closing the
;;;; scope uses the same mutex, then drains queued callbacks while they can
;;;; still see the live boundary but can no longer leave it.
;;;;
;;;; An interrupt transfers control without signaling inside user code.
;;;; The boundary reports the interruption after user cleanup has unwound.
;;;; All state transitions run without interrupts so a signal handler cannot
;;;; request a scope while its target holds that scope's mutex. A request
;;;; from such a handler queues its callback; SBCL runs that callback after
;;;; the handler returns. Closing before the non-local exit also prevents
;;;; repeated requests from interrupting cleanup a second time.
;;;; WITH-TIMEOUT adds a timer and uses exactly this same protocol.
(in-package #:cl-concurrent-kit)

(%define-kit-condition operation-interrupted
    ((scope "The interruptible scope that received the request.")
     (reason "The reason supplied by the first accepted request, or NIL."))
  ("Operation interrupted: ~S." (operation-interrupted-reason condition))
  "Signaled at an interruptible scope boundary after its body has unwound.")

(defun %call-with-interruptible-scope (thunk interrupted &optional (cleanup #'values))
  (let ((thread (current-thread))
        (lock (make-lock))
        (active t)
        (requested nil)
        (interrupted-p nil)
        (reason nil)
        scope)
    (multiple-value-prog1
        (block boundary
          (sb-sys:without-interrupts
            (setf scope
                  (lambda (requested-reason)
                    (sb-sys:without-interrupts
                      (with-lock-held (lock)
                        (when (and active (not requested))
                          (setf requested t)
                          ;; Enqueue under the same lock as deactivation: a
                          ;; requester cannot pause here and enqueue after exit.
                          (sb-thread:interrupt-thread
                           thread
                           (lambda ()
                             (sb-sys:without-interrupts
                               (when (with-lock-held (lock)
                                       (when active
                                         ;; Close before unwinding user cleanup
                                         ;; so another request cannot cut it short.
                                         (setf active nil
                                               interrupted-p t
                                               reason requested-reason)
                                         t))
                                 (return-from boundary (values))))))
                          t)))))
            (unwind-protect
                (sb-sys:with-local-interrupts (funcall thunk scope))
              ;; WITH-LOCAL-INTERRUPTS restores the disabled state before
              ;; control reaches here, including on a normal body return.
              (with-lock-held (lock) (setf active nil))
              (unwind-protect (funcall cleanup)
                ;; Every accepted callback has already been queued, and now
                ;; observes an inactive scope while the boundary still exists.
                (sb-sys:with-local-interrupts nil)))))
      (when interrupted-p
        (funcall interrupted scope reason)))))

(defmacro with-interruptible-scope ((scope) &body body)
  "Run BODY in the current thread, binding SCOPE to its interruption target.
REQUEST-INTERRUPTION transfers control directly to this boundary, unwinds BODY,
then signals OPERATION-INTERRUPTED with the scope and request reason. Handlers
inside BODY cannot intercept that condition. Normal return preserves all values.
Requests after BODY has returned are ignored. WITHOUT-INTERRUPTS and GC can
delay delivery; asynchronous interruption requires an unwind-safe BODY."
  `(%call-with-interruptible-scope
    (lambda (,scope) ,@body)
    (lambda (target reason)
      (error 'operation-interrupted :scope target :reason reason))))

(defun request-interruption (scope &key reason)
  "Request interruption of SCOPE with REASON, defaulting to NIL.
Return T for the first accepted request, or NIL for an inactive scope or a
duplicate request. The first accepted reason wins. Delivery is queued even
on the target thread, so a requesting signal handler returns before delivery."
  (funcall scope reason))

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
:WITH-TIMEOUT and the timeout in seconds. Handlers inside BODY cannot swallow
this interruption. A timer arriving after BODY has returned cannot change its
successful result. DURATION is evaluated once; NIL, zero and negative durations
run BODY without a deadline.

Nested deadlines have independent targets. A direct SB-EXT:WITH-TIMEOUT in
BODY keeps its own condition. WITHOUT-INTERRUPTS and GC may delay delivery.
As with WITH-INTERRUPTIBLE-SCOPE, BODY must be safe to unwind asynchronously;
for cooperative cancellation of resource-owning work, use WITH-TASK-SCOPE."
  `(%call-with-timeout ,duration (lambda () ,@body)))

