;;;; src/stream-partition.lisp
;;;;
;;;; CHANNEL-PARTITION-BY groups consecutive INPUT values sharing a KEY into
;;;; ordered lists. Built on SRC/STREAM.LISP's stage machinery -- see its
;;;; header comment for the shared :SCOPE/cancellation contract.
(in-package #:cl-concurrent-kit)

(defun channel-partition-by (key input &key (buffer-size 0) scope executor)
  "Group consecutive INPUT values whose KEY results are EQL into ordered
lists, emitting each completed group as soon as a differing key (or INPUT
closing) ends it. KEY is evaluated once per input value.

Returns two values: an output channel and a completion promise. With SCOPE,
the stage is a tracked child; with EXECUTOR, it runs on that executor."
  (check-type key function)
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (let ((group-reversed nil)
                (group-key nil)
                (group-p nil))
            (labels ((flush-group ()
                       (when group-p
                         (send output (nreverse group-reversed))
                         (setf group-reversed nil group-key nil group-p nil))))
              (%consume-channel (value input scope (progn (flush-group) nil))
                (let ((value-key (funcall key value)))
                  (if (and group-p (not (eql value-key group-key)))
                      (progn
                        (flush-group)
                        (setf group-reversed (list value) group-key value-key group-p t))
                      (progn
                        (unless group-p (setf group-key value-key group-p t))
                        (push value group-reversed)))))))))
      :scope scope :executor executor :outputs (list output)))))
