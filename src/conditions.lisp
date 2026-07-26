;;;; src/conditions.lisp
(in-package #:cl-concurrent-kit)

(define-condition cl-concurrent-kit-error (error) ()
  (:documentation "Base condition for every error CL-CONCURRENT-KIT signals.
Catch this to handle any failure from this library without naming each
specific condition."))

(define-condition operation-timed-out (cl-concurrent-kit-error)
  ((operation :initarg :operation :reader operation-timed-out-operation
              :documentation "A keyword naming the operation that timed out, e.g. :AWAIT,
:RECV, :SEND, or :SELECT.")
   (timeout :initarg :timeout :reader operation-timed-out-timeout
            :documentation "The timeout, in seconds, that elapsed."))
  (:report (lambda (condition stream)
             (format stream "~S timed out after ~,3F seconds."
                     (operation-timed-out-operation condition)
                     (operation-timed-out-timeout condition))))
  (:documentation "Signaled by AWAIT, RECV, SEND, or SELECT when a :TIMEOUT
argument elapses before the operation completes."))

(define-condition promise-already-fulfilled (cl-concurrent-kit-error)
  ((promise :initarg :promise :reader promise-already-fulfilled-promise
            :documentation "The promise DELIVER or DELIVER-ERROR was called on a second time."))
  (:report (lambda (condition stream)
             (format stream "Promise ~S is already settled; a promise can only be delivered once."
                     (promise-already-fulfilled-promise condition))))
  (:documentation "Signaled by DELIVER or DELIVER-ERROR when called on a
promise that has already been settled -- catches the common bug of a value
being computed and delivered more than once."))

(define-condition channel-closed (cl-concurrent-kit-error)
  ((channel :initarg :channel :reader channel-closed-channel
            :documentation "The channel SEND or TRY-SEND was called on after it was closed."))
  (:report (lambda (condition stream)
             (format stream "Cannot send on closed channel ~S." (channel-closed-channel condition))))
  (:documentation "Signaled by SEND or TRY-SEND on a channel that CLOSE-CHANNEL
has already been called on. RECV keeps draining any values sent before the
channel closed instead of signaling this; only sending after close is an
error."))

(define-condition task-cancelled (cl-concurrent-kit-error)
  ((scope :initarg :scope :reader task-cancelled-scope
          :documentation "The scope whose cancellation CHECK-CANCELLED observed."))
  (:report (lambda (condition stream)
             (format stream "Task cancelled: its enclosing scope ~S was cancelled."
                     (task-cancelled-scope condition))))
  (:documentation "Signaled by CHECK-CANCELLED when called from within a task
whose scope has been cancelled, either because a sibling task failed or
because WITH-TASK-SCOPE's body exited abnormally."))

(define-condition scope-error (cl-concurrent-kit-error)
  ((causes :initarg :causes :reader scope-error-causes
           :documentation "A list of the conditions signaled by the scope's failed child
tasks, oldest first."))
  (:report (lambda (condition stream)
             (let ((causes (scope-error-causes condition)))
               (format stream "~D task~:P failed in scope; first failure: ~A"
                       (length causes) (first causes)))))
  (:documentation "Signaled by WITH-TASK-SCOPE when its body completes
normally but one or more tasks SPAWNed within it failed. Each element of
CAUSES is the condition a failed task signaled."))
