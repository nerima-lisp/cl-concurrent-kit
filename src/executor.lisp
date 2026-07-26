;;;; src/executor.lisp
;;;;
;;;; A fixed-size worker pool (Java's ExecutorService): SUBMIT hands a thunk
;;;; to whichever worker is free and returns a PROMISE for it immediately,
;;;; instead of PROMISE/FUTURE's one-thread-per-task cost.
(in-package #:cl-concurrent-kit)

;;; An unbounded blocking queue for pending tasks. Deliberately not the
;;; public CHANNEL: CHANNEL's SEND applies backpressure once a bounded buffer
;;; fills, which SUBMIT should not do, and an unbuffered CHANNEL would make
;;; SUBMIT block until a worker is free to take it -- also not the contract
;;; here. Reuses CHANNEL's internal FIFO (src/channel.lisp).

(defstruct (%work-queue (:constructor %make-work-queue ()))
  (lock (make-lock :name "cl-concurrent-kit executor queue") :read-only t)
  (condition-variable (make-condition-variable :name "cl-concurrent-kit executor queue")
                       :read-only t)
  (fifo (make-fifo) :read-only t)
  (closed-p nil))

(defun %work-queue-push (queue task)
  (with-lock-held ((%work-queue-lock queue))
    (fifo-push (%work-queue-fifo queue) task)
    (condition-notify (%work-queue-condition-variable queue))))

(defun %work-queue-pop (queue)
  "Block until a task is available or QUEUE is closed and drained. Returns
(VALUES TASK T) or (VALUES NIL NIL)."
  (with-lock-held ((%work-queue-lock queue))
    (loop until (or (not (fifo-empty-p (%work-queue-fifo queue))) (%work-queue-closed-p queue))
          do (condition-wait (%work-queue-condition-variable queue) (%work-queue-lock queue)))
    (if (fifo-empty-p (%work-queue-fifo queue))
        (values nil nil)
        (values (fifo-pop (%work-queue-fifo queue)) t))))

(defun %work-queue-close (queue)
  (with-lock-held ((%work-queue-lock queue))
    (setf (%work-queue-closed-p queue) t)
    (condition-broadcast (%work-queue-condition-variable queue))))

;;; Executor

(defstruct (executor (:constructor %make-executor (queue threads)))
  (queue nil :read-only t)
  (threads nil :read-only t))

(defun %worker-loop (queue)
  (loop
    (multiple-value-bind (task more-p) (%work-queue-pop queue)
      (unless more-p (return))
      (funcall task))))

(defun make-executor (&key (size 4) (name "cl-concurrent-kit executor"))
  "Create an executor backed by SIZE worker threads sharing one task queue.
SUBMIT never blocks on backpressure; call SHUTDOWN-EXECUTOR once no more work
will be submitted so the workers can exit."
  (check-type size (integer 1))
  (let ((queue (%make-work-queue)))
    (%make-executor
     queue
     (loop repeat size
           collect (make-thread (lambda () (%worker-loop queue))
                                 :name name)))))

(defun submit (executor thunk)
  "Queue THUNK to run on one of EXECUTOR's worker threads and return a
PROMISE for its outcome. AWAIT on the result blocks until THUNK runs and
returns its value, or re-signals whatever condition THUNK let escape."
  (let ((promise (make-promise)))
    (%work-queue-push (executor-queue executor)
                       (lambda ()
                         (handler-case (deliver promise (funcall thunk))
                           (error (c) (deliver-error promise c)))))
    promise))

(defun shutdown-executor (executor &key wait)
  "Stop EXECUTOR from accepting new work; tasks already queued still run.
When WAIT is true, block until every worker thread has exited."
  (%work-queue-close (executor-queue executor))
  (when wait
    (dolist (thread (executor-threads executor))
      (join-thread thread)))
  (values))
