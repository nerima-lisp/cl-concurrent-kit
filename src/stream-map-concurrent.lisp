;;;; src/stream-map-concurrent.lisp
;;;;
;;;; CHANNEL-MAP-CONCURRENT and CHANNEL-MAP-UNORDERED: a single INPUT fanned
;;;; out to a worker pool and back into one output, preserving input order or
;;;; not. Unlike SRC/STREAM-FAN-IN.LISP's stages, neither reads from more than
;;;; one input channel at a time, so neither needs %RUN-DYNAMIC-SELECT --
;;;; each worker's own JOBS/RESULTS channels are enough.
(progn (in-package #:cl-concurrent-kit) (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1))))

(defun %worker-limit (parallelism executor)
  "How many of CHANNEL-MAP-CONCURRENT/CHANNEL-MAP-UNORDERED's workers to
start: PARALLELISM itself with no EXECUTOR, or PARALLELISM further bounded by
EXECUTOR's own thread count and queue capacity (if bounded) -- starting more
workers than EXECUTOR could ever run at once, or than its queue could ever
hold pending, would only leave the extras permanently queued behind it."
  (if executor
      (min parallelism
           (length (executor-threads executor))
           (or (executor-queue-capacity executor) parallelism))
      parallelism))

(defun channel-map-concurrent (parallelism function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to INPUT concurrently across up to PARALLELISM workers,
preserving input order in the output.

Returns two values: an output channel and a completion promise. With SCOPE,
each worker (and the coordinator that dispatches to them) is a tracked
child; a worker failure fails the whole stage. With EXECUTOR, workers run on
it -- their count is bounded by both PARALLELISM and EXECUTOR's own thread
count and queue capacity, if it is bounded -- but the coordinator itself
never runs on EXECUTOR, so a saturated worker pool cannot deadlock against
its own dispatcher."
  (check-type parallelism (integer 1 *))
  (check-type input channel)
  (let* ((output (make-channel :buffer-size buffer-size))
         (jobs (make-channel :buffer-size parallelism))
         (results (make-channel :buffer-size parallelism))
         (worker-completions nil)
         (worker-limit (%worker-limit parallelism executor)))
    (flet ((worker ()
             (loop
               (multiple-value-bind (job received-p) (recv jobs)
                 (unless received-p (return))
                 (destructuring-bind (index value) job
                   (handler-case
                       (send results (list index :value (funcall function value)))
                     (error (condition)
                       ;; The coordinator owns failure propagation. Reporting
                       ;; here prevents it waiting forever for a missing result.
                       (send results (list index :error condition))
                       (return-from worker nil))))))))
      ;; Register all workers synchronously: WITH-TASK-SCOPE may close as
      ;; soon as this call returns.
      (setf worker-completions
            (loop repeat worker-limit
                  collect (%start-channel-stage (function worker) :scope scope :executor executor)))
      (dolist (worker-completion worker-completions)
        (when (promise-settled-p worker-completion)
          (handler-case (await worker-completion)
            (error (condition)
              (close-channel jobs)
              (close-channel results)
              (close-channel output)
              (let ((completion (make-promise)))
                (deliver-error completion condition)
                (return-from channel-map-concurrent (values output completion)))))))
      (values
       output
       (with-channel-stage (:scope scope :executor nil :outputs (list jobs results output))
         (let ((next-index 0)
               (next-output-index 0)
               (submitted 0)
               (completed 0)
               (input-closed-p nil)
               (ready (make-hash-table)))
           (labels ((fill-jobs ()
                      ;; Keep up to PARALLELISM jobs in flight until INPUT closes.
                      (loop
                        while (and (not input-closed-p) (< (- submitted completed) parallelism))
                        do (multiple-value-bind (value received-p) (recv input)
                             (if received-p
                                 (progn
                                   (send jobs (list next-index value))
                                   (incf next-index)
                                   (incf submitted))
                                 (setf input-closed-p t)))))
                    (drain-ready-outputs ()
                      ;; Send every already-collected result in order, starting at
                      ;; NEXT-OUTPUT-INDEX, until the next one is still missing.
                      (loop
                        (multiple-value-bind (value available-p) (gethash next-output-index ready)
                          (unless available-p (return))
                          (remhash next-output-index ready)
                          (send output value)
                          (incf next-output-index))))
                    (collect-one-result ()
                      (destructuring-bind (index kind value) (recv results)
                        (incf completed)
                        (if (eq kind :error)
                            (error value)
                            (setf (gethash index ready) value))
                        (drain-ready-outputs))))
             (unwind-protect
                 (loop
                   (when scope (check-cancelled scope))
                   (fill-jobs)
                   (cond
                     ((< completed submitted) (collect-one-result))
                     (input-closed-p (return))))
               (close-channel jobs)))
           ;; A caller without a SCOPE still receives a completion promise
           ;; that settles only once every worker has actually exited.
           (unless scope
             (dolist (worker-completion worker-completions)
               (await worker-completion)))))))))

(defun channel-map-unordered (parallelism function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to INPUT concurrently across up to PARALLELISM workers,
emitting each result as soon as it completes rather than in input order.

Returns two values: an output channel and a completion promise. SCOPE and
EXECUTOR behavior, including the coordinator never itself running on
EXECUTOR, are the same as CHANNEL-MAP-CONCURRENT."
  (check-type parallelism (integer 1 *))
  (check-type input channel)
  (let* ((output (make-channel :buffer-size buffer-size))
         (jobs (make-channel :buffer-size parallelism))
         (results (make-channel :buffer-size parallelism))
         (worker-completions nil)
         (worker-limit (%worker-limit parallelism executor)))
    (flet ((worker ()
             (loop
               (multiple-value-bind (value received-p) (recv jobs)
                 (unless received-p (return))
                 (handler-case
                     (send results (list :value (funcall function value)))
                   (error (condition)
                     (send results (list :error condition))
                     (return-from worker nil)))))))
      (setf worker-completions
            (loop repeat worker-limit
                  collect (%start-channel-stage (function worker) :scope scope :executor executor)))
      (dolist (worker-completion worker-completions)
        (when (promise-settled-p worker-completion)
          (handler-case (await worker-completion)
            (error (condition)
              (close-channel jobs)
              (close-channel results)
              (close-channel output)
              (let ((completion (make-promise)))
                (deliver-error completion condition)
                (return-from channel-map-unordered (values output completion)))))))
      (values
       output
       (with-channel-stage (:scope scope :executor nil :outputs (list jobs results output))
         (let ((submitted 0)
               (completed 0)
               (input-closed-p nil))
           (labels ((fill-jobs ()
                      ;; Keep up to PARALLELISM jobs in flight until INPUT closes.
                      (loop
                        while (and (not input-closed-p) (< (- submitted completed) parallelism))
                        do (multiple-value-bind (value received-p) (recv input)
                             (if received-p
                                 (progn (send jobs value) (incf submitted))
                                 (setf input-closed-p t)))))
                    (collect-one-result ()
                      (destructuring-bind (kind value) (recv results)
                        (incf completed)
                        (if (eq kind :error)
                            (error value)
                            (send output value)))))
             (unwind-protect
                 (loop
                   (when scope (check-cancelled scope))
                   (fill-jobs)
                   (cond
                     ((< completed submitted) (collect-one-result))
                     (input-closed-p (return))))
               (close-channel jobs)))
           (unless scope
             (dolist (worker-completion worker-completions)
               (await worker-completion)))))))))

(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
