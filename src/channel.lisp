;;;; src/channel.lisp
;;;;
;;;; A CSP-style channel. BUFFER-SIZE 0 is Go's unbuffered channel: SEND
;;;; blocks until a RECV has actually taken the value back out, so SEND
;;;; returning is a synchronization point, not just "enqueued somewhere".
;;;; BUFFER-SIZE N > 0 is a bounded queue: SEND only blocks once N values are
;;;; already waiting. Both share one implementation below by treating
;;;; unbuffered as "capacity 1, and SEND additionally waits for the drain".
(in-package #:cl-concurrent-kit)

;;; A minimal FIFO, shared with the executor's internal work queue
;;; (src/executor.lisp). Not part of the public API.

(defstruct (fifo (:constructor make-fifo ()))
  (head nil)
  (tail nil))

(defun fifo-empty-p (fifo)
  (null (fifo-head fifo)))

(defun fifo-push (fifo item)
  (let ((cell (cons item nil)))
    (if (fifo-tail fifo)
        (setf (cdr (fifo-tail fifo)) cell)
        (setf (fifo-head fifo) cell))
    (setf (fifo-tail fifo) cell))
  (values))

(defun fifo-pop (fifo)
  (let ((cell (fifo-head fifo)))
    (setf (fifo-head fifo) (cdr cell))
    (unless (fifo-head fifo) (setf (fifo-tail fifo) nil))
    (car cell)))

(defstruct (channel (:constructor %make-channel (buffer-size)))
  (lock (make-lock :name "cl-concurrent-kit channel") :read-only t)
  (send-condition-variable
   (make-condition-variable :name "cl-concurrent-kit channel send")
   :read-only t)
  (recv-condition-variable
   (make-condition-variable :name "cl-concurrent-kit channel recv")
   :read-only t)
  (buffer-size 0 :read-only t :type (integer 0))
  (queue (make-fifo) :read-only t)
  (count 0 :type (integer 0))
  (closed-p nil)
  ;; Semaphores registered by in-progress SELECT calls (src/select.lisp).
  (waiters (make-hash-table :test (function eq)) :read-only t))

;;; Channel



(setf (documentation 'channel-closed-p 'function)
      "True once CLOSE-CHANNEL has been called on CHANNEL. A momentary,
lock-free read -- like THREAD-ALIVE-P, treat it as advisory rather than
linearized with concurrent SEND/RECV.")

(defun make-channel (&key (buffer-size 0))
  "Create a channel. BUFFER-SIZE 0 (the default) is an unbuffered, CSP-style
rendezvous channel: SEND blocks until a RECV takes the value. BUFFER-SIZE N >
0 lets up to N values queue up before SEND blocks."
  (check-type buffer-size (integer 0))
  (%make-channel buffer-size))

(defun %channel-add-waiter (channel semaphore)
  (with-lock-held ((channel-lock channel))
    (setf (gethash semaphore (channel-waiters channel)) t)))

(defun %channel-notify (channel condition-variable)
  (condition-notify condition-variable)
  (maphash (lambda (waiter present-p)
             (declare (ignore present-p))
             (signal-semaphore waiter))
           (channel-waiters channel)))

(defun %channel-broadcast (channel)
  (condition-broadcast (channel-send-condition-variable channel))
  (condition-broadcast (channel-recv-condition-variable channel))
  (maphash (lambda (waiter present-p)
             (declare (ignore present-p))
             (signal-semaphore waiter))
           (channel-waiters channel)))

(defun %channel-remove-waiter (channel semaphore)
  (with-lock-held ((channel-lock channel))
    (remhash semaphore (channel-waiters channel))))

(defun send (channel value &key timeout)
  "Send VALUE on CHANNEL, blocking while it is full (buffered) or until a
RECV takes VALUE back out (unbuffered). With TIMEOUT (seconds), signals
OPERATION-TIMED-OUT if it does not complete in time. Signals CHANNEL-CLOSED
if CHANNEL is already closed."
  (with-lock-held ((channel-lock channel))
    (let ((deadline (%deadline-from-timeout timeout))
          ;; An unbuffered channel is modeled as a single-slot buffer: SEND
          ;; may deposit a value whenever the slot is empty, exactly like a
          ;; buffered channel of capacity 1.
          (capacity (max 1 (channel-buffer-size channel))))
      (let ((room (%wait-until (channel-send-condition-variable channel) (channel-lock channel)
                                (lambda ()
                                  (cond ((channel-closed-p channel) :closed)
                                        ((< (channel-count channel) capacity) t)))
                                deadline)))
        (case room
          (:timeout (error 'operation-timed-out :operation :send :timeout timeout))
          (:closed (error 'channel-closed :channel channel))))
      (fifo-push (channel-queue channel) value)
      (incf (channel-count channel))
      (%channel-notify channel (channel-recv-condition-variable channel))
      (when (zerop (channel-buffer-size channel))
        ;; The capacity-1 trick above only models the queuing half of an
        ;; unbuffered channel. What makes it a rendezvous rather than a
        ;; buffer-size-1 channel is this: SEND does not return until a RECV
        ;; has actually taken the value back out again.
        ;;
        ;; Known limitation: this second wait only reacts to a timeout, not
        ;; to a concurrent CLOSE-CHANNEL -- closing a channel out from under
        ;; your own in-flight unbuffered SEND is not a supported pattern (as
        ;; in Go, only the sending side should close a channel).
        (when (eq :timeout
                  (%wait-until (channel-send-condition-variable channel) (channel-lock channel)
                               (lambda () (zerop (channel-count channel)))
                               deadline))
          (error 'operation-timed-out :operation :send :timeout timeout)))))
  t)

(defun recv (channel &key timeout)
  "Receive a value from CHANNEL, blocking until one is available or CHANNEL
is closed. Returns (VALUES VALUE T), or (VALUES NIL NIL) once CHANNEL is
closed and every value sent before the close has been drained. With TIMEOUT
(seconds), signals OPERATION-TIMED-OUT if neither happens in time."
  (with-lock-held ((channel-lock channel))
    (let* ((deadline (%deadline-from-timeout timeout))
           (ready (%wait-until (channel-recv-condition-variable channel) (channel-lock channel)
                                (lambda ()
                                  (cond ((plusp (channel-count channel)) :ready)
                                        ((channel-closed-p channel) :closed)))
                                deadline)))
      (case ready
        (:timeout (error 'operation-timed-out :operation :recv :timeout timeout))
        (:closed (values nil nil))
        (:ready
         (let ((value (fifo-pop (channel-queue channel))))
           (decf (channel-count channel))
           (%channel-notify channel (channel-send-condition-variable channel))
           (values value t)))))))

(defun try-send (channel value)
  "Non-blocking SEND: deposit VALUE and return T if room is immediately
available, else return NIL. Unlike SEND, does not wait for an unbuffered
channel's value to actually be received -- that confirmation is exactly what
blocking costs buy, and TRY-SEND trades it away for a non-blocking guarantee.
Signals CHANNEL-CLOSED if CHANNEL is already closed."
  (with-lock-held ((channel-lock channel))
    (when (channel-closed-p channel)
      (error 'channel-closed :channel channel))
    (if (< (channel-count channel) (max 1 (channel-buffer-size channel)))
        (progn
          (fifo-push (channel-queue channel) value)
          (incf (channel-count channel))
          (%channel-notify channel (channel-recv-condition-variable channel))
          t)
        nil)))

(defun try-recv (channel)
  "Non-blocking RECV. Returns (VALUES VALUE T NIL) if a value was
immediately available, (VALUES NIL NIL T) if CHANNEL is closed and every
buffered value has been drained, or (VALUES NIL NIL NIL) if nothing is
available right now but CHANNEL may still produce more."
  (with-lock-held ((channel-lock channel))
    (cond
      ((plusp (channel-count channel))
       (let ((value (fifo-pop (channel-queue channel))))
         (decf (channel-count channel))
         (%channel-notify channel (channel-send-condition-variable channel))
         (values value t nil)))
      ((channel-closed-p channel) (values nil nil t))
      (t (values nil nil nil)))))

(defun close-channel (channel)
  "Close CHANNEL: further SEND or TRY-SEND calls signal CHANNEL-CLOSED, but
RECV/TRY-RECV keep draining any values already queued. Idempotent."
  (with-lock-held ((channel-lock channel))
    (setf (channel-closed-p channel) t)
    (%channel-broadcast channel))
  channel)
