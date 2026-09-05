;;;; src/executor-work-queue.lisp
;;;;
;;;; Growable FIFO queue behind EXECUTOR. It is separate from CHANNEL because
;;;; SUBMIT must not apply channel backpressure; bounded queues report :FULL.
;;;; This file precedes executor.lisp because its lock macro is used there.
(progn (in-package #:cl-concurrent-kit) (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1))))

(defstruct (%work-queue (:constructor %make-work-queue (capacity buffer)))
  "Internal task queue used by EXECUTOR."
  (lock (make-lock :name "cl-concurrent-kit executor queue") :read-only t)
  (condition-variable (make-condition-variable :name "cl-concurrent-kit executor queue")
                       :read-only t)
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

(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
