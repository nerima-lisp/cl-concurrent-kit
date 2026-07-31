;;;; src/conditions.lisp
;;;;
;;;; Every condition below is generated through %DEFINE-KIT-CONDITION: a
;;;; slot's reader name and a :REPORT method's boilerplate lambda used to be
;;;; hand-written five times, once per condition, and have drifted from each
;;;; other before (a missing :READER, an inconsistent reader name). The macro
;;;; makes the convention the only way to spell a condition here at all.
(in-package #:cl-concurrent-kit)

(define-condition cl-concurrent-kit-error (error) ()
  (:documentation "Base condition for every error CL-CONCURRENT-KIT signals.
Catch this to handle any failure from this library without naming each
specific condition."))

(defmacro %define-kit-condition (name (&rest slots) (report-control &rest report-args)
                                 &optional documentation)
  "Define NAME as a CL-CONCURRENT-KIT-ERROR subclass with one slot per entry
of SLOTS, each (SLOT-NAME SLOT-DOCUMENTATION). A slot's initarg is the
keyword of the same name and its reader is NAME-SLOT-NAME -- exactly the
convention every condition in this file already followed by hand.

REPORT-CONTROL and REPORT-ARGS become a :REPORT method's FORMAT call, with
CONDITION bound around them; REPORT-ARGS forms may refer to CONDITION freely
-- that capture is deliberate, the same anaphor DEFINE-CONDITION's own
:REPORT lambda offers, not an accidental one this macro should guard against."
  `(define-condition ,name (cl-concurrent-kit-error)
     ,(mapcar (lambda (slot)
                (destructuring-bind (slot-name slot-documentation) slot
                  `(,slot-name :initarg ,(intern (symbol-name slot-name) :keyword)
                               :reader ,(intern (format nil "~A-~A" name slot-name))
                               :documentation ,slot-documentation)))
              slots)
     (:report (lambda (condition stream)
                (declare (ignorable condition))
                (format stream ,report-control ,@report-args)))
     ,@(when documentation `((:documentation ,documentation)))))

(%define-kit-condition operation-timed-out
    ((operation "A keyword naming the operation that timed out, e.g. :AWAIT,
:RECV, :SEND, :SELECT, or :WITH-TASK-SCOPE.")
     (timeout "The timeout, in seconds, that elapsed."))
  ("~S timed out after ~,3F seconds."
   (operation-timed-out-operation condition)
   (operation-timed-out-timeout condition))
  "Signaled by AWAIT, RECV, SEND, SELECT, or WITH-TASK-SCOPE when a :TIMEOUT
argument elapses before the operation completes.")

(%define-kit-condition promise-already-fulfilled
    ((promise "The promise DELIVER or DELIVER-ERROR was called on a second time."))
  ("Promise ~S is already settled; a promise can only be delivered once."
   (promise-already-fulfilled-promise condition))
  "Signaled by DELIVER or DELIVER-ERROR when called on a promise that has
already been settled -- catches the common bug of a value being computed and
delivered more than once.")

(%define-kit-condition channel-closed
    ((channel "The channel SEND or TRY-SEND was called on after it was closed."))
  ("Cannot send on closed channel ~S." (channel-closed-channel condition))
  "Signaled by SEND or TRY-SEND on a channel that CLOSE-CHANNEL has already
been called on. RECV keeps draining any values sent before the channel closed
instead of signaling this; only sending after close is an error.")

(%define-kit-condition executor-shut-down
    ((executor "The executor that rejected or cancelled the task."))
  ("Executor ~S has shut down." (executor-shut-down-executor condition))
  "Delivered through a submitted promise when its executor no longer accepts
work.")

(%define-kit-condition executor-queue-full
    ((executor "The executor whose bounded queue rejected the task.")
     (capacity "The QUEUE-CAPACITY MAKE-EXECUTOR gave EXECUTOR."))
  ("Executor ~S has reached its pending task capacity of ~D."
   (executor-queue-full-executor condition)
   (executor-queue-full-capacity condition))
  "Delivered through a submitted promise by SUBMIT/TRY-SUBMIT when a bounded
executor's queue is already full. Never signaled for an unbounded executor
(MAKE-EXECUTOR's default).")

(%define-kit-condition task-cancelled
    ((scope "The scope whose cancellation CHECK-CANCELLED observed."))
  ("Task cancelled: its enclosing scope ~S was cancelled."
   (task-cancelled-scope condition))
  "Signaled by CHECK-CANCELLED when called from within a task whose scope has
been cancelled, either because a sibling task failed or because
WITH-TASK-SCOPE's body exited abnormally.")

(%define-kit-condition scope-error
    ((causes "A list of the conditions signaled by the scope's failed child tasks,
oldest first."))
  ("~D task~:P failed in scope; first failure: ~A"
   (length (scope-error-causes condition))
   (first (scope-error-causes condition)))
  "Signaled by WITH-TASK-SCOPE when its body completes normally but one or
more tasks SPAWNed within it failed. Each element of CAUSES is the condition
a failed task signaled.")

(%define-kit-condition latch-count-underflow
    ((latch "The countdown latch COUNT-DOWN was called on.")
     (count "The latch's count before this call.")
     (decrement "The decrement that would have taken the count below zero."))
  ("Cannot decrement countdown latch ~S by ~D: only ~D remain."
   (latch-count-underflow-latch condition)
   (latch-count-underflow-decrement condition)
   (latch-count-underflow-count condition))
  "Signaled by COUNT-DOWN when DECREMENT would reduce a countdown latch's
count below zero.")

(%define-kit-condition barrier-broken
    ((barrier "The barrier AWAIT-BARRIER was called on."))
  ("Barrier ~S is broken; reset it with RESET-BARRIER before using it again."
   (barrier-broken-barrier condition))
  "Signaled by AWAIT-BARRIER when another participant timed out or was
cancelled, or RESET-BARRIER abandoned the current generation.")

(%define-kit-condition promise-cancelled
    ((promise "The promise CANCEL-PROMISE was called on.")
     (reason "The optional reason supplied to CANCEL-PROMISE, or NIL."))
  ("Promise ~S was cancelled~@[ (~A)~]."
   (promise-cancelled-promise condition)
   (promise-cancelled-reason condition))
  "Signaled by AWAIT after CANCEL-PROMISE settles a pending promise.
Cancellation settles only the promise and never preempts a FUTURE thread
already running.")

(%define-kit-condition promise-empty-input
    ((operation "A keyword naming the combinator that received no promises,
e.g. :PROMISE-ANY."))
  ("~S requires at least one promise." (promise-empty-input-operation condition))
  "Signaled when PROMISE-ANY receives no promises.")

(%define-kit-condition promise-all-failed
    ((causes "A list of the conditions every input promise to PROMISE-ANY
failed with, in input order."))
  ("Every promise failed; first failure: ~A"
   (first (promise-all-failed-causes condition)))
  "Signaled by PROMISE-ANY when every input promise fails.")
