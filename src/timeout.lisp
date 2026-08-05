;;;; src/timeout.lisp
;;;;
;;;; The one PREEMPTIVE deadline in this library. Every other :TIMEOUT here
;;;; bounds a wait this library implements itself -- a CONDITION-WAIT inside
;;;; %WAIT-UNTIL, a semaphore inside SELECT -- and such a deadline is enforced
;;;; simply by declining to wait any longer. An arbitrary body is the case
;;;; that shape cannot reach: it may be computing, or blocked in a read this
;;;; library never sees, and nothing it does is under our control.
;;;;
;;;; SBCL does ship the missing mechanism. SB-EXT:WITH-TIMEOUT schedules a
;;;; timer that interrupts the running thread, so an arbitrary body really can
;;;; be bounded. What it does not do is speak this library's vocabulary: it
;;;; signals SB-EXT:TIMEOUT, which is a SERIOUS-CONDITION but deliberately NOT
;;;; an ERROR, so neither a caller's own (HANDLER-CASE ... (ERROR ...)) nor
;;;; the (HANDLER-CASE ... (CL-CONCURRENT-KIT-ERROR ...)) this library
;;;; promises catches it. This file is the translation that keeps SB-EXT out
;;;; of callers' handler clauses entirely.
(in-package #:cl-concurrent-kit)

(defun %call-with-timeout (duration thunk)
  "Implementation of WITH-TIMEOUT; see that macro for the contract."
  (let ((seconds (and duration (cl-date-kit:duration-to-seconds duration))))
    (if (and seconds (plusp seconds))
        ;; The deadline is computed BEFORE SB-EXT:WITH-TIMEOUT schedules its
        ;; timer, so it can only be earlier than the instant that timer fires,
        ;; never later -- the comparison below therefore never rejects this
        ;; call's own timeout over a rounding margin.
        (let ((deadline (%deadline-from-timeout seconds))
              (expired-p nil))
          (multiple-value-prog1
              (block attempt
                (handler-bind
                    ((sb-ext:timeout
                       (lambda (condition)
                         (declare (ignore condition))
                         ;; Claim this SB-EXT:TIMEOUT only if this call's own
                         ;; deadline has actually been reached. Anything earlier
                         ;; belongs to a timeout the body established, and
                         ;; declining lets it keep propagating to whoever did.
                         (when (>= (cl-boundary-kit:clock-monotonic *clock*) deadline)
                           (setf expired-p t)
                           (return-from attempt (values))))))
                  (sb-ext:with-timeout seconds (funcall thunk))))
            ;; Signaled after the BLOCK above has unwound rather than from
            ;; inside the handler: by then SB-EXT:WITH-TIMEOUT's own
            ;; UNWIND-PROTECT has unscheduled the timer and the asynchronous
            ;; interrupt's frames are gone, so a caller handling
            ;; OPERATION-TIMED-OUT sees an ordinary stack.
            (when expired-p
              (error 'operation-timed-out :operation :with-timeout :timeout seconds))))
        (funcall thunk))))

(defmacro with-timeout (duration &body body)
  "Run BODY under a preemptive deadline of DURATION (a CL-DATE-KIT:DURATION),
returning its values. If BODY has not finished by then it is interrupted and
OPERATION-TIMED-OUT is signaled, naming :WITH-TIMEOUT as the operation.

DURATION NIL, or a zero or negative-length duration, means no deadline at
all: BODY simply runs. Zero and negative match SB-EXT:WITH-TIMEOUT, which
schedules no timer unless its own seconds argument is strictly positive -- a
zero-length deadline that fired immediately would leave (WITH-TIMEOUT
(CL-DATE-KIT:DURATION-ZERO) ...) unable to run anything. NIL is this macro's
own addition, so a caller holding a timeout variable that is NIL for \"no
limit\" can pass it straight through, exactly as AWAIT, RECV, SEND and SELECT
already accept a NIL :TIMEOUT.

PREEMPTIVE, and how that differs from a scope. This macro interrupts BODY
wherever it happens to be, through SBCL's timer and SB-THREAD:INTERRUPT-THREAD.
WITH-TASK-SCOPE's cancellation is the opposite -- COOPERATIVE, reaching a task
only where that task calls CHECK-CANCELLED -- and that is a deliberate design
position rather than a missing feature (see src/scope.lisp): an asynchronous
interrupt can unwind BODY between any two instructions, so an UNWIND-PROTECT
inside BODY may be entered with its protected form only half finished.
SB-EXT:WITH-TIMEOUT's own docstring works that hazard through in detail. Bound
work that is safe to abandon at an arbitrary point with this macro; for work
that owns a resource, prefer a scope and CHECK-CANCELLED.

NESTING. A deadline established inside BODY -- by an inner WITH-TIMEOUT, or by
a direct SB-EXT:WITH-TIMEOUT -- is never reported as this one's, and this
one's is never reported as the inner one's. Each level claims an
SB-EXT:TIMEOUT only once its own deadline has actually been reached and
otherwise declines, so an inner expiry surfaces with the inner seconds and an
outer expiry with the outer seconds, whichever form is written outermost. Two
deadlines expiring in the same instant are genuinely indistinguishable, and
there the innermost claims it.

TELLING TWO DEADLINES APART. WITH-TASK-SCOPE's own :TIMEOUT signals this very
same OPERATION-TIMED-OUT, naming :WITH-TASK-SCOPE instead. A handler wrapping
a scope whose body contains a WITH-TIMEOUT therefore sees one condition type
standing for two different expiries, and must read
OPERATION-TIMED-OUT-OPERATION -- not the condition's class -- to tell which
fired. That is deliberate: every deadline in this library reports through the
one condition type, and the operation slot is how they are discriminated."
  `(%call-with-timeout ,duration (lambda () ,@body)))
