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
;;; here. Reuses the shared FIFO utility (src/fifo.lisp).
(defstruct (%work-queue (:constructor %make-work-queue ()))
  (lock (make-lock :name "cl-concurrent-kit executor queue") :read-only t)
  (condition-variable (make-condition-variable :name "cl-concurrent-kit executor queue")
                       :read-only t)
  (fifo (make-fifo) :read-only t)
  (closed-p nil))

(defmacro %with-work-queue-lock ((queue) &body body)
  "Hold QUEUE's own lock for the dynamic extent of BODY."
  `(with-lock-held ((%work-queue-lock ,queue)) ,@body))

(defun %work-queue-push (queue task)
  "Enqueue TASK unless QUEUE has been closed. Returns true when accepted."
  (%with-work-queue-lock (queue)
    (unless (%work-queue-closed-p queue)
      (fifo-push (%work-queue-fifo queue) task)
      (condition-notify (%work-queue-condition-variable queue))
      t)))

(defun %work-queue-pop (queue)
  "Block until a task is available or QUEUE is closed and drained. Returns
(VALUES TASK T) or (VALUES NIL NIL)."
  (%with-work-queue-lock (queue)
    (loop until (or (not (fifo-empty-p (%work-queue-fifo queue))) (%work-queue-closed-p queue))
          do (condition-wait (%work-queue-condition-variable queue) (%work-queue-lock queue)))
    (if (fifo-empty-p (%work-queue-fifo queue))
        (values nil nil)
        (values (fifo-pop (%work-queue-fifo queue)) t))))

;;; Executor
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let (#+sbcl (sb-ext:*evaluator-mode* :interpret))
    (eval '(defstruct (executor (:constructor %make-executor (queue threads)))
            (queue nil :read-only t)
            (threads nil :read-only t)))))

(defun %worker-loop (queue)
  "Run queued tasks without allowing settlement callbacks to kill this worker."
  (loop
    (multiple-value-bind (task more-p) (%work-queue-pop queue)
      (unless more-p
        (return))
      (handler-case (%executor-task-run task)
        (error (condition)
          (format *error-output*
                  "cl-concurrent-kit executor task settlement callback signaled ~A~%"
                  condition))))))

(defun submit (executor thunk)
  "Queue THUNK to run on one of EXECUTOR's worker threads and return a
PROMISE for its outcome. AWAIT on the result blocks until THUNK runs and
returns its value, or re-signals whatever condition THUNK let escape."
  (%submit executor thunk))

(defun shutdown-executor (executor &key wait cancel-pending timeout)
  "Stop EXECUTOR from accepting new work. With CANCEL-PENDING true, reject
queued tasks without running them. When WAIT is true, block until every worker
thread has exited. TIMEOUT bounds the total join duration in seconds and
signals OPERATION-TIMED-OUT if any worker remains alive past that deadline. If
called by a worker of EXECUTOR, shutdown starts but EXECUTOR-SHUT-DOWN is
signaled instead of joining the current thread."
  (%work-queue-close executor cancel-pending)
  (when wait
    (when (member (current-thread) (executor-threads executor) :test (function eq))
      (error 'executor-shut-down :executor executor))
    (let ((deadline (%deadline-from-timeout timeout))
          (timeout-marker (gensym "JOIN-TIMEOUT-")))
      (dolist (thread (executor-threads executor))
        (if deadline
            (let ((remaining
                    (max 0.0d0
                         (/ (- deadline (get-internal-real-time))
                            (float internal-time-units-per-second 0.0d0)))))
              (let ((result (join-thread thread :default timeout-marker :timeout remaining)))
                (when (and (eq result timeout-marker) (thread-alive-p thread))
                  (error 'operation-timed-out
                         :operation :shutdown-executor
                         :timeout timeout))))
            (join-thread thread)))))
  (values))

(defun make-executor (&key (size 4) (name "cl-concurrent-kit executor"))
  "Create an executor backed by SIZE worker threads sharing one task queue.
SUBMIT never blocks on backpressure; call SHUTDOWN-EXECUTOR once no more work
will be submitted so the workers can exit. If worker startup fails, already
started workers are shut down before the creation error is re-signaled."
  (check-type size (integer 1))
  (let ((queue (%make-work-queue))
        (threads nil))
    (handler-case
        (progn
          (loop repeat size
                do (push (make-thread (lambda () (%worker-loop queue)) :name name)
                         threads))
          (%make-executor queue (nreverse threads)))
      (error (condition)
        (shutdown-executor (%make-executor queue threads) :wait t)
        (error condition)))))

(defstruct (%executor-task (:constructor %make-executor-task (thunk promise on-settle)))
  (state :pending :type symbol)
  (thunk nil :read-only t)
  (promise nil :read-only t)
  (on-settle nil :read-only t))

(defun %executor-task-settle (task state outcome)
  "Settle TASK's public promise, then run its bookkeeping callback."
  (unwind-protect
      (ecase state
        (:fulfilled (deliver (%executor-task-promise task) outcome))
        (:failed (deliver-error (%executor-task-promise task) outcome)))
    (when (%executor-task-on-settle task)
      (funcall (%executor-task-on-settle task) state outcome))))

(defun %executor-task-run (task)
  "Claim and execute TASK at most once."
  (when (eq :pending
            (sb-ext:compare-and-swap (%executor-task-state task) :pending :running))
    (multiple-value-bind (state outcome)
        (handler-case
            (values :fulfilled (funcall (%executor-task-thunk task)))
          (error (condition)
            (values :failed condition)))
      (%executor-task-settle task state outcome))))

(defun %executor-task-cancel (task condition)
  "Cancel TASK only when it has not been claimed by a worker."
  (when (eq :pending
            (sb-ext:compare-and-swap (%executor-task-state task) :pending :cancelled))
    (%executor-task-settle task :failed condition)
    t))

(defun %submit (executor thunk &key promise on-settle)
  (let* ((promise (or promise (make-promise)))
         (task (%make-executor-task thunk promise on-settle)))
    (unless (%work-queue-push (executor-queue executor) task)
      (%executor-task-cancel task (make-condition 'executor-shut-down :executor executor)))
    (values promise task)))

(defun %work-queue-close (executor cancel-pending)
  (let ((queue (executor-queue executor))
        cancelled-tasks)
    (%with-work-queue-lock (queue)
      (when cancel-pending
        (setf cancelled-tasks (fifo-detach (%work-queue-fifo queue))))
      (setf (%work-queue-closed-p queue) t)
      (condition-broadcast (%work-queue-condition-variable queue)))
    (when cancelled-tasks
      (let ((condition (make-condition 'executor-shut-down :executor executor)))
        (loop for task = (fifo-pop cancelled-tasks)
              while task
              do (%executor-task-cancel task condition))))))
