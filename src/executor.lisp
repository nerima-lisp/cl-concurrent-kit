;;;; src/executor.lisp
;;;;
;;;; A fixed-size worker pool (Java's ExecutorService): SUBMIT hands a thunk
;;;; to whichever worker is free and returns a PROMISE for it immediately,
;;;; instead of PROMISE/FUTURE's one-thread-per-task cost.
(progn (in-package #:cl-concurrent-kit) (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1))))

;;; An unbounded blocking queue for pending tasks. Deliberately not the
;;; public CHANNEL: CHANNEL's SEND applies backpressure once a bounded buffer
;;; fills, which SUBMIT should not do, and an unbuffered CHANNEL would make
;;; SUBMIT block until a worker is free to take it -- also not the contract
;;; here. Uses a growable ring buffer to avoid per-submission allocation.
(defstruct (%work-queue (:constructor %make-work-queue (capacity buffer)))
  "Internal task queue used by EXECUTOR."
  (lock (make-lock "cl-concurrent-kit executor queue") :read-only t)
  (condition-variable (make-condition-variable) :read-only t)
  (buffer nil :type (simple-array t (*)))
  (head 0 :type fixnum)
  (tail 0 :type fixnum)
  ;; NIL means unbounded; otherwise submissions fail fast when full.
  (capacity nil :read-only t :type (or null (integer 1 *)))
  (count 0 :type (integer 0 #.most-positive-fixnum))
  (high-water-mark 0 :type (integer 0 #.most-positive-fixnum))
  (closed-p nil))

(defmacro %with-work-queue-lock ((queue) &body body)
  "Hold QUEUE's own lock for the dynamic extent of BODY."
  `(with-lock-held ((%work-queue-lock ,queue)) ,@body))

(progn
  (defun %work-queue-grow (queue)
    "Double QUEUE's ring while preserving FIFO order; called under its lock."
    (let* ((old-buffer (%work-queue-buffer queue))
           (old-length (length old-buffer))
           (count (%work-queue-count queue))
           (new-length (min (or (%work-queue-capacity queue) #.most-positive-fixnum)
                            (* 2 old-length)))
           (new-buffer (make-array new-length))
           (old-index (%work-queue-head queue)))
      (dotimes (index count)
        (setf (aref new-buffer index) (aref old-buffer old-index)
              old-index (if (= old-index (1- old-length)) 0 (1+ old-index))))
      (setf (%work-queue-buffer queue) new-buffer
            (%work-queue-head queue) 0
            (%work-queue-tail queue) count)))

  (defun %work-queue-push (queue task)
    "Enqueue TASK without per-submission consing."
    (%with-work-queue-lock (queue)
      (cond
        ((%work-queue-closed-p queue) (values nil :closed))
        ((and (%work-queue-capacity queue)
              (>= (%work-queue-count queue) (%work-queue-capacity queue)))
         (values nil :full))
        (t
         (when (= (%work-queue-count queue) (length (%work-queue-buffer queue)))
           (%work-queue-grow queue))
         (let ((buffer (%work-queue-buffer queue))
               (tail (%work-queue-tail queue)))
           (setf (aref buffer tail) task
                 (%work-queue-tail queue) (if (= tail (1- (length buffer))) 0 (1+ tail))))
         (let ((count (incf (%work-queue-count queue))))
           (when (> count (%work-queue-high-water-mark queue))
             (setf (%work-queue-high-water-mark queue) count)))
         (condition-notify (%work-queue-condition-variable queue))
         (values t nil))))))

(defun %work-queue-pop (queue)
  "Block until a task is available or QUEUE is closed and drained. Returns
(VALUES TASK T) or (VALUES NIL NIL)."
  (%with-work-queue-lock (queue)
    (loop until (or (plusp (%work-queue-count queue)) (%work-queue-closed-p queue))
          do (condition-wait (%work-queue-condition-variable queue) (%work-queue-lock queue)))
    (if (zerop (%work-queue-count queue))
        (values nil nil)
        (let* ((buffer (%work-queue-buffer queue))
               (head (%work-queue-head queue))
               (task (aref buffer head)))
          (setf (aref buffer head) nil
                (%work-queue-head queue) (if (= head (1- (length buffer))) 0 (1+ head)))
          (decf (%work-queue-count queue))
          (values task t)))))

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

(defun executor-shutdown-p (executor)
  "True once SHUTDOWN-EXECUTOR has been called on EXECUTOR -- a momentary,
lock-free-adjacent snapshot, like CHANNEL-CLOSED-P."
  (%with-work-queue-lock ((executor-queue executor)) (%work-queue-closed-p (executor-queue executor))))

(defun executor-terminated-p (executor)
  "True once every one of EXECUTOR's worker threads has exited."
  (every (lambda (thread) (not (thread-alive-p thread))) (executor-threads executor)))

(defun executor-queue-capacity (executor)
  "The bound MAKE-EXECUTOR's :QUEUE-CAPACITY gave EXECUTOR's queue, or NIL if
it is unbounded (the default)."
  (%work-queue-capacity (executor-queue executor)))

(defun executor-queue-depth (executor)
  "A snapshot of how many tasks are currently queued on EXECUTOR, waiting for
a free worker."
  (%with-work-queue-lock ((executor-queue executor)) (%work-queue-count (executor-queue executor))))

(defun executor-high-water-mark (executor)
  "The largest EXECUTOR-QUEUE-DEPTH EXECUTOR's queue has ever reached."
  (%with-work-queue-lock ((executor-queue executor))
    (%work-queue-high-water-mark (executor-queue executor))))

(defun submit (executor thunk)
  "Queue THUNK to run on one of EXECUTOR's worker threads and return a
PROMISE for its outcome. AWAIT on the result blocks until THUNK runs and
returns its value, or re-signals whatever condition THUNK let escape.

SUBMIT never blocks and never signals synchronously: if EXECUTOR has shut
down, or its optional :QUEUE-CAPACITY (see MAKE-EXECUTOR) is already full,
THUNK never runs and the returned promise is rejected immediately instead,
with EXECUTOR-SHUT-DOWN or EXECUTOR-QUEUE-FULL respectively. Use TRY-SUBMIT
to learn which happened without inspecting the promise."
  (values (%submit executor thunk)))

(defun try-submit (executor thunk)
  "Like SUBMIT, but also returns whether THUNK was actually accepted onto
EXECUTOR's queue as a second value, sparing the caller an AWAIT (or a
HANDLER-CASE around one) just to find out."
  (multiple-value-bind (promise task accepted-p) (%submit executor thunk)
    (declare (ignore task))
    (values promise accepted-p)))

(defun await-executor-termination (executor &key timeout)
  "Block until every one of EXECUTOR's worker threads has exited, or signal
OPERATION-TIMED-OUT after TIMEOUT seconds. Signals EXECUTOR-SHUT-DOWN instead
of blocking if called from one of EXECUTOR's own worker threads -- a worker
cannot wait for its own thread, or a sibling it might itself be blocking, to
exit.

This does not request shutdown itself -- call SHUTDOWN-EXECUTOR first (with
or without :WAIT) if EXECUTOR is still accepting work, or its workers will
never exit for this to observe."
  (when (member (current-thread) (executor-threads executor) :test (function eq))
    (error 'executor-shut-down :executor executor))
  (let ((deadline (%deadline-from-timeout timeout))
        (timeout-marker (gensym "JOIN-TIMEOUT-")))
    (dolist (thread (executor-threads executor))
      (if deadline
          (let ((remaining (%seconds-until-deadline deadline)))
            (let ((result (join-thread thread :default timeout-marker :timeout remaining)))
              (when (and (eq result timeout-marker) (thread-alive-p thread))
                (error 'operation-timed-out
                       :operation :await-executor-termination
                       :timeout timeout))))
          (join-thread thread))))
  (values))

(defun shutdown-executor (executor &key wait cancel-pending timeout)
  "Stop EXECUTOR from accepting new work. With CANCEL-PENDING true, reject
queued tasks without running them. When WAIT is true, block until every worker
thread has exited (via AWAIT-EXECUTOR-TERMINATION, whose own :TIMEOUT and
worker-reentrancy behavior this shares). TIMEOUT bounds that wait in seconds
and signals OPERATION-TIMED-OUT if any worker remains alive past that
deadline."
  (%work-queue-close executor cancel-pending)
  (when wait
    (await-executor-termination executor :timeout timeout))
  (values))

(defmacro with-executor ((var &key (size 4) (name "cl-concurrent-kit executor")
                          queue-capacity shutdown-timeout)
                          &body body)
  "Bind VAR to a fresh executor -- as MAKE-EXECUTOR would build from SIZE,
NAME, and QUEUE-CAPACITY -- for the dynamic extent of BODY, then shut it down
and wait for every worker to exit -- letting any already-queued work finish
first, exactly like SHUTDOWN-EXECUTOR without :CANCEL-PENDING -- whether BODY
returns normally or signals. SHUTDOWN-TIMEOUT bounds that final wait in
seconds, as SHUTDOWN-EXECUTOR's own :TIMEOUT would."
  `(let ((,var (make-executor :size ,size :name ,name :queue-capacity ,queue-capacity)))
     (unwind-protect (locally ,@body)
       (shutdown-executor ,var :wait t :timeout ,shutdown-timeout))))

(defun executor-map (executor function sequence &key max-in-flight)
  "Apply FUNCTION to each element of SEQUENCE, running up to MAX-IN-FLIGHT
calls concurrently on EXECUTOR (unbounded -- i.e. every call submitted at
once -- when MAX-IN-FLIGHT is NIL, the default), and return an ordered list
of every result once all have completed. If any call signals, that condition
propagates once every already-submitted call has itself settled, without
attempting to cancel calls already running."
  (check-type max-in-flight (or null (integer 1 *)))
  (let* ((items (coerce sequence 'vector))
         (count (length items))
         (semaphore (and max-in-flight (make-semaphore :count max-in-flight)))
         (promises (make-array count)))
    (dotimes (index count)
      (when semaphore (wait-on-semaphore semaphore))
      (let ((thunk (let ((item (aref items index)))
                     (lambda () (funcall function item)))))
        (setf (aref promises index)
              (if semaphore
                  (%submit executor
                            thunk
                            :on-settle
                            (lambda (state outcome)
                              (declare (ignore state outcome))
                              (signal-semaphore semaphore)))
                  (submit executor thunk)))))
    (map 'list (function await) promises)))

(defun make-executor (&key (size 4) (name "cl-concurrent-kit executor") queue-capacity)
  "Create an executor with SIZE worker threads.

QUEUE-CAPACITY is NIL for an unbounded queue or a positive integer that makes
SUBMIT fail fast with EXECUTOR-QUEUE-FULL when the queue is full."
  (check-type size (integer 1))
  (check-type queue-capacity (or null (integer 1 *)))
  (let ((queue (%make-work-queue queue-capacity
                                 (make-array (if queue-capacity
                                                 (min queue-capacity 64)
                                                 64))))
        (threads nil))
    (handler-case
        (progn
          (loop repeat size
                do (push (make-thread (lambda () (%executor-worker-loop queue))
                                      :name name)
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
    (multiple-value-bind (accepted-p reason) (%work-queue-push (executor-queue executor) task)
      (unless accepted-p
        (%executor-task-cancel
         task
         (ecase reason
           (:closed (make-condition 'executor-shut-down :executor executor))
           (:full (make-condition 'executor-queue-full
                                   :executor executor
                                   :capacity (executor-queue-capacity executor))))))
      (values promise task accepted-p))))

(defun %work-queue-close (executor cancel-pending) "Close EXECUTOR queue and cancel pending tasks outside its lock." (let ((queue (executor-queue executor)) (cancelled-buffer nil) (cancelled-head 0) (cancelled-count 0)) (%with-work-queue-lock (queue) (when (and cancel-pending (plusp (%work-queue-count queue))) (setf cancelled-buffer (%work-queue-buffer queue) cancelled-head (%work-queue-head queue) cancelled-count (%work-queue-count queue) (%work-queue-count queue) 0 (%work-queue-head queue) 0 (%work-queue-tail queue) 0)) (setf (%work-queue-closed-p queue) t) (condition-broadcast (%work-queue-condition-variable queue))) (when cancelled-buffer (let ((condition (make-condition (quote executor-shut-down) :executor executor)) (buffer-length (length cancelled-buffer)) (index cancelled-head)) (dotimes (offset cancelled-count) (declare (ignore offset)) (let ((task (aref cancelled-buffer index))) (setf (aref cancelled-buffer index) nil index (if (= index (1- buffer-length)) 0 (1+ index))) (%executor-task-cancel task condition)))))))
(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
