;;;; src/stream-fan-out.lisp
;;;;
;;;; One-input, many-outputs stream stages: CHANNEL-BROADCAST replicates
;;;; every input value to several channels; CHANNEL-TAKE/-DROP/-TAKE-WHILE/
;;;; -BATCH slice a single output channel's worth of values out of INPUT.
;;;; Built on SRC/STREAM.LISP's stage machinery -- see its header comment for
;;;; the shared :SCOPE/cancellation contract every stage here follows.
(in-package #:cl-concurrent-kit)

(defun channel-broadcast (input count &key (buffer-size 0) scope executor)
  "Forward every INPUT value to each of COUNT fresh output channels.

Returns two values: a list of output channels and a completion promise.
Every output receives values in input order. The stage sends to outputs in
list order, so every output participates in backpressure -- a slow consumer
delays later values for all consumers. Closing an output unsubscribes it;
the remaining open outputs keep receiving later values. If every output is
closed, the stage still drains INPUT until it closes; supply SCOPE if that
draining must be cancellable. Every output channel closes once INPUT drains,
including when the stage fails or SCOPE is cancelled. With SCOPE, the stage
is a tracked child; with EXECUTOR, it runs on that executor."
  (check-type input channel)
  (check-type count (integer 0 *))
  (let ((outputs (loop repeat count collect (make-channel :buffer-size buffer-size))))
    (values
     outputs
     (with-channel-stage (:scope scope :executor executor :outputs outputs)
       (let ((active-outputs outputs))
         (%consume-channel (value input scope nil)
           (dolist (output active-outputs)
             (handler-case (send output value)
               (channel-closed ()
                 (setf active-outputs (remove output active-outputs :count 1)))))))))))

(defun channel-take (count input &key (buffer-size 0) scope executor)
  "Forward at most COUNT values from INPUT without consuming later values.

Returns two values: an output channel and a completion promise. The output
closes after COUNT forwarded values, or once INPUT closes and drains,
whichever comes first. INPUT stays open, and any values beyond the limit
remain available to another receiver. With SCOPE, the stage is a tracked
child; with EXECUTOR, it runs on that executor."
  (check-type count (integer 0 *))
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size))
        (remaining count))
    (values
     output
     (with-channel-stage (:scope scope :executor executor :outputs (list output))
       (when (plusp remaining)
         (%consume-channel (value input scope nil)
           (send output value)
           (when (zerop (decf remaining)) (return))))))))

(defun channel-drop (count input &key (buffer-size 0) scope executor)
  "Discard the first COUNT input values, then forward every remaining value.

Returns two values: an output channel and a completion promise. The output
closes once INPUT drains; INPUT stays open. With SCOPE, the stage is a
tracked child; with EXECUTOR, it runs on that executor."
  (check-type count (integer 0 *))
  (check-type input channel)
  (let ((remaining count))
    (%make-channel-stage
     input buffer-size scope executor
     (lambda (value)
       (if (plusp remaining)
           (progn (decf remaining) (values nil nil))
           (values value t))))))

(defun channel-take-while (predicate input &key (buffer-size 0) scope executor)
  "Forward INPUT's matching prefix and consume its first non-matching value.

Returns two values: an output channel and a completion promise. Once
PREDICATE returns false for a value, the output closes and that value (and
everything after it) remains available to another receiver. With SCOPE, the
stage is a tracked child; with EXECUTOR, it runs on that executor."
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (with-channel-stage (:scope scope :executor executor :outputs (list output))
       (%consume-channel (value input scope nil)
         (unless (funcall predicate value) (return))
         (send output value))))))

(defun channel-batch (size input &key (buffer-size 0) (emit-partial t) scope executor)
  "Forward INPUT values as ordered lists of up to SIZE elements.

Returns two values: an output channel and a completion promise. A completed
batch always contains exactly SIZE values. When EMIT-PARTIAL is true, a
final incomplete batch is forwarded once INPUT closes; otherwise it is
discarded. With SCOPE, the stage is a tracked child; with EXECUTOR, it runs
on that executor."
  (check-type size (integer 1 *))
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (with-channel-stage (:scope scope :executor executor :outputs (list output))
       (let ((batch nil)
             (batch-size 0))
         (%consume-channel (value input scope
                             (progn
                               (when (and batch emit-partial)
                                 (send output (nreverse batch)))
                               nil))
           (push value batch)
           (incf batch-size)
           (when (= batch-size size)
             (send output (nreverse batch))
             (setf batch nil batch-size 0))))))))
