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
            (flet ((on-input (value received-p)
                     (if received-p
                         (let ((inner (funcall function value)))
                           (check-type inner channel)
                           (push inner inner-channels))
                         (setf input-open-p nil))))
              (loop while (or input-open-p inner-channels)
                    do (when scope (check-cancelled scope))
                       (let ((clauses (%channel-merge-clauses inner-channels output)))
                         (when (and input-open-p (< (length inner-channels) parallelism))
                           (push (cons input (function on-input)) clauses))
                         (let ((result (%run-dynamic-select clauses)))
                           (when (and (consp result) (not (car result)))
                             (setf inner-channels (delete (cdr result) inner-channels :count 1))))))))))
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
            (flet ((on-input (value received-p)
                     (if received-p
                         (let ((next (funcall function value)))
                           (check-type next channel)
                           (setf inner next))
                         (setf input-open-p nil)))
                   (on-inner (value received-p)
                     (if received-p
                         (send output value)
                         (setf inner nil))))
              (loop while (or input-open-p inner)
                    do (when scope (check-cancelled scope))
                       (let ((clauses nil))
                         (when input-open-p
                           (push (cons input (function on-input)) clauses))
                         (when inner
                           (push (cons inner (function on-inner)) clauses))
                         (%run-dynamic-select clauses)))))))
      :scope scope :executor executor :outputs (list output)))))
(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
