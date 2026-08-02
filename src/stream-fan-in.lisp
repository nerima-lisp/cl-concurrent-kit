;;;; src/stream-fan-in.lisp
;;;;
;;;; Many-inputs, one-output stream stages. Built on SRC/STREAM.LISP's stage
;;;; machinery -- see its header comment for the shared :SCOPE/cancellation
;;;; contract every stage here follows.
;;;;
;;;; CHANNEL-MERGE, CHANNEL-MERGE-MAP, and CHANNEL-SWITCH-MAP all need fair
;;;; multiplexing over a channel set whose SIZE changes at runtime (inputs
;;;; close and are dropped; CHANNEL-MERGE-MAP/CHANNEL-SWITCH-MAP open new
;;;; inner channels as FUNCTION returns them). SRC/SELECT.LISP's SELECT
;;;; macro cannot express that: its clause count is fixed at macroexpansion
;;;; time. %RUN-DYNAMIC-SELECT below is a small runtime multiplexer built
;;;; directly on the same private waiter registration SELECT itself uses
;;;; (src/channel.lisp's %CHANNEL-ADD-WAITER/%CHANNEL-REMOVE-WAITER), so a
;;;; dynamic clause set still sleeps between probes instead of busy-polling.
(progn (in-package #:cl-concurrent-kit) (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1))))

(defun %try-dynamic-select-clauses (clauses)
  "Try each of CLAUSES (a list of (CHANNEL . HANDLER) conses) once via
TRY-RECV. Return (VALUES RESULT T) from the first ready clause -- a value
arrived, or the channel closed and fully drained -- calling HANDLER with
VALUE and RECEIVED-P, or (VALUES NIL NIL) if none are ready yet."
  (dolist (clause clauses (values nil nil))
    (multiple-value-bind (value received-p closed-p) (try-recv (car clause))
      (when (or received-p closed-p)
        (return (values (funcall (cdr clause) value received-p) t))))))

(defun %run-dynamic-select (clauses)
  "Fairly wait on CLAUSES (a list of (CHANNEL . HANDLER) conses) until one
becomes ready, then return its HANDLER's result. Like SELECT, sleeps between
probes via a private waiter semaphore rather than busy-polling."
  (multiple-value-bind (result ready-p) (%try-dynamic-select-clauses clauses)
    (when ready-p
      (return-from %run-dynamic-select result)))
  (let ((waiter (make-semaphore)))
    (unwind-protect
        (progn
          (dolist (clause clauses)
            (%channel-add-waiter (car clause) waiter +channel-notify-recv+))
          (loop
            (multiple-value-bind (result ready-p) (%try-dynamic-select-clauses clauses)
              (when ready-p
                (return result)))
            (wait-on-semaphore waiter)))
      (dolist (clause clauses)
        (%channel-remove-waiter (car clause) waiter)))))

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
       (%start-channel-stage
        (lambda ()
          (%with-closed-stage-outputs ((list output))
            (let ((next-index 0)
                  (next-output-index 0)
                  (submitted 0)
                  (completed 0)
                  (input-closed-p nil)
                  (ready (make-hash-table)))
              (unwind-protect
                  (loop
                    (when scope (check-cancelled scope))
                    (loop
                      while (and (not input-closed-p) (< (- submitted completed) parallelism))
                      do (multiple-value-bind (value received-p) (recv input)
                           (if received-p
                               (progn
                                 (send jobs (list next-index value))
                                 (incf next-index)
                                 (incf submitted))
                               (setf input-closed-p t))))
                    (cond
                      ((< completed submitted)
                       (destructuring-bind (index kind value) (recv results)
                         (incf completed)
                         (if (eq kind :error)
                             (error value)
                             (setf (gethash index ready) value))
                         (loop
                           (multiple-value-bind (next-value available-p) (gethash next-output-index ready)
                             (unless available-p (return))
                             (remhash next-output-index ready)
                             (send output next-value)
                             (incf next-output-index)))))
                      (input-closed-p (return))))
                (close-channel jobs))
              ;; A caller without a SCOPE still receives a completion promise
              ;; that settles only once every worker has actually exited.
              (unless scope
                (dolist (worker-completion worker-completions)
                  (await worker-completion))))))
        :scope scope :executor nil :outputs (list jobs results output))))))

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
       (%start-channel-stage
        (lambda ()
          (%with-closed-stage-outputs ((list output))
            (let ((submitted 0)
                  (completed 0)
                  (input-closed-p nil))
              (unwind-protect
                  (loop
                    (when scope (check-cancelled scope))
                    (loop
                      while (and (not input-closed-p) (< (- submitted completed) parallelism))
                      do (multiple-value-bind (value received-p) (recv input)
                           (if received-p
                               (progn (send jobs value) (incf submitted))
                               (setf input-closed-p t))))
                    (cond
                      ((< completed submitted)
                       (destructuring-bind (kind value) (recv results)
                         (incf completed)
                         (if (eq kind :error)
                             (error value)
                             (send output value))))
                      (input-closed-p (return))))
                (close-channel jobs))
              (unless scope
                (dolist (worker-completion worker-completions)
                  (await worker-completion))))))
        :scope scope :executor nil :outputs (list jobs results output))))))

(defun %channel-merge-clauses (inputs output)
  "Build %RUN-DYNAMIC-SELECT clauses forwarding whichever of INPUTS becomes
ready to OUTPUT. Each clause's handler returns (RECEIVED-P . CHANNEL), so
the caller can drop a closed channel from the next round's INPUTS."
  (mapcar (lambda (input)
            (cons input
                  (lambda (value received-p)
                    (when received-p (send output value))
                    (cons received-p input))))
          inputs))

(defmacro %with-channel-list-stage ((inputs-var channels output-var buffer-size scope executor)
                                     &body body)
  "Validate CHANNELS as a list of CHANNEL values bound to INPUTS-VAR, create
OUTPUT-VAR as a fresh channel of BUFFER-SIZE, and return (VALUES OUTPUT-VAR
completion-promise) for a stage running BODY that closes OUTPUT-VAR on every
exit path. Shared setup/teardown behind CHANNEL-MERGE, CHANNEL-ZIP, and
CHANNEL-CONCAT below, which differ only in how they read from INPUTS-VAR and
write to OUTPUT-VAR."
  `(let ((,inputs-var (coerce ,channels 'list))
         (,output-var (make-channel :buffer-size ,buffer-size)))
     (dolist (input ,inputs-var) (check-type input channel))
     (values
      ,output-var
      (%start-channel-stage
       (lambda ()
         (%with-closed-stage-outputs ((list ,output-var))
           ,@body))
       :scope ,scope :executor ,executor :outputs (list ,output-var)))))

(defun channel-merge (channels &key (buffer-size 0) scope executor)
  "Forward values from CHANNELS to one output channel until every input has
closed and drained.

Returns two values: an output channel and a completion promise. Values from
each individual input preserve their receive order; values from different
inputs are selected fairly and so have no fixed relative order. The output
channel closes only once every input is closed and drained. With SCOPE, the
stage is a tracked child; with EXECUTOR, it runs on that executor."
  (%with-channel-list-stage (inputs channels output buffer-size scope executor)
    (loop while inputs
          do (when scope (check-cancelled scope))
             (let ((result (%run-dynamic-select (%channel-merge-clauses inputs output))))
               (unless (car result)
                 (setf inputs (delete (cdr result) inputs :count 1)))))))

(defun %channel-zip-tuple (inputs)
  "Receive one value from every one of INPUTS, in order.

Returns the tuple (a list, in INPUTS' order) and T once complete, or NIL and
NIL if some input closed before the tuple was complete."
  (let ((tuple nil))
    (dolist (input inputs (values (nreverse tuple) t))
      (multiple-value-bind (value received-p) (recv input)
        (unless received-p (return (values nil nil)))
        (push value tuple)))))

(defun channel-zip (channels &key (buffer-size 0) scope executor)
  "Combine CHANNELS into ordered lists, each containing one value from every
input, received in collection order while a tuple is being built.

Returns two values: an output channel and a completion promise. The stage
stops at the first closed-and-drained input, so its output has the length of
the shortest input -- and values already received toward an incomplete
final tuple are consumed and discarded when a later input closes. With
SCOPE, the stage is a tracked child; with EXECUTOR, it runs on that
executor."
  (%with-channel-list-stage (inputs channels output buffer-size scope executor)
    (unless (null inputs)
      (loop
        (when scope (check-cancelled scope))
        (multiple-value-bind (tuple complete-p) (%channel-zip-tuple inputs)
          (unless complete-p (return))
          (send output tuple))))))

(defun channel-concat (channels &key (buffer-size 0) scope executor)
  "Forward CHANNELS one at a time, preserving both collection order and each
channel's own receive order.

Returns two values: an output channel and a completion promise. The stage
fully drains each channel before advancing to the next, and closes its
output once the final input closes. With SCOPE, the stage is a tracked
child; with EXECUTOR, it runs on that executor."
  (%with-channel-list-stage (inputs channels output buffer-size scope executor)
    (dolist (input inputs)
      (loop
        (when scope (check-cancelled scope))
        (multiple-value-bind (value received-p) (recv input)
          (unless received-p (return))
          (send output value))))))

(defun channel-concat-map (function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to each INPUT value and fully drain each returned channel,
in order, before moving on to the next INPUT value.

Returns two values: an output channel and a completion promise. With SCOPE,
the stage is a tracked child; with EXECUTOR, it runs on that executor."
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (loop
            (when scope (check-cancelled scope))
            (multiple-value-bind (value received-p) (recv input)
              (unless received-p (return))
              (let ((inner (funcall function value)))
                (check-type inner channel)
                (loop
                  (multiple-value-bind (inner-value inner-received-p) (recv inner)
                    (unless inner-received-p (return))
                    (send output inner-value))))))))
      :scope scope :executor executor :outputs (list output)))))

(defun channel-merge-map (function input &key (parallelism 4) (buffer-size 0) scope executor)
  "Apply FUNCTION to each INPUT value, expecting a channel back, and merge up
to PARALLELISM of those inner channels into one output as they each produce
values -- CHANNEL-FLAT-MAP's concurrent, interleaving counterpart.

Returns two values: an output channel and a completion promise. With SCOPE,
the stage is a tracked child; with EXECUTOR, it runs on that executor."
  (check-type parallelism (integer 1 *))
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (let ((inner-channels nil)
                (input-open-p t))
            (loop while (or input-open-p inner-channels)
                  do (when scope (check-cancelled scope))
                     (let ((clauses (%channel-merge-clauses inner-channels output)))
                       (when (and input-open-p (< (length inner-channels) parallelism))
                         (push
                          (cons input
                                (lambda (value received-p)
                                  (if received-p
                                      (let ((inner (funcall function value)))
                                        (check-type inner channel)
                                        (push inner inner-channels))
                                      (setf input-open-p nil))))
                          clauses))
                       (let ((result (%run-dynamic-select clauses)))
                         (when (and (consp result) (not (car result)))
                           (setf inner-channels (delete (cdr result) inner-channels :count 1)))))))))
      :scope scope :executor executor :outputs (list output)))))

(defun channel-switch-map (function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to each INPUT value, expecting a channel back, and forward
only the most recently returned one -- an earlier still-open inner channel
is simply stopped being read from (not closed) once a newer one arrives.

Returns two values: an output channel and a completion promise. With SCOPE,
the stage is a tracked child; with EXECUTOR, it runs on that executor."
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (let ((inner nil)
                (input-open-p t))
            (loop while (or input-open-p inner)
                  do (when scope (check-cancelled scope))
                     (let ((clauses nil))
                       (when input-open-p
                         (push
                          (cons input
                                (lambda (value received-p)
                                  (if received-p
                                      (let ((next (funcall function value)))
                                        (check-type next channel)
                                        (setf inner next))
                                      (setf input-open-p nil))))
                          clauses))
                       (when inner
                         (push
                          (cons inner
                                (lambda (value received-p)
                                  (if received-p
                                      (send output value)
                                      (setf inner nil))))
                          clauses))
                       (%run-dynamic-select clauses))))))
      :scope scope :executor executor :outputs (list output)))))
(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
