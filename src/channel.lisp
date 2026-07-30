;;;; src/channel.lisp
;;;;
;;;; A CSP-style channel. BUFFER-SIZE 0 is Go's unbuffered channel: SEND
;;;; blocks until a RECV has actually taken the value back out, so SEND
;;;; returning is a synchronization point, not just "enqueued somewhere".
;;;; BUFFER-SIZE N > 0 is a bounded queue: SEND only blocks once N values are
;;;; already waiting. Both share one implementation below by treating
;;;; unbuffered as "capacity 1, and SEND additionally waits for the drain".
(progn
  (declaim (optimize
      (speed 3)
      (safety 1)
      (debug 0)
      (compilation-speed 0)
      #+sb-cover (sb-c:store-coverage-data 3)))
  (in-package #:cl-concurrent-kit))

;;; Channel
(progn
  (defstruct (channel (:constructor %make-channel (buffer-size capacity)))
  (lock (make-lock :name "cl-concurrent-kit channel") :read-only t)
  (send-condition-variable
   (make-condition-variable :name "cl-concurrent-kit channel send")
   :read-only t)
  (recv-condition-variable
   (make-condition-variable :name "cl-concurrent-kit channel recv")
   :read-only t)
  (rendezvous-condition-variable
   (make-condition-variable :name "cl-concurrent-kit channel rendezvous")
   :read-only t)
  (buffer-size 0 :read-only t :type (integer 0 #.most-positive-fixnum))
  (capacity 1 :read-only t :type (integer 1 #.most-positive-fixnum))
  (queue (make-fifo) :read-only t)
  (count 0 :type (integer 0 #.most-positive-fixnum))
  (closed-p nil)
  (waiters (make-hash-table :test (function eq)) :read-only t)
  (waiter-count 0 :type fixnum))
  (defstruct (%channel-message (:constructor %make-channel-message (value))) (value nil :read-only t)
    (received-p nil)))

(setf (documentation 'channel-closed-p 'function) "True once CLOSE-CHANNEL has been called on CHANNEL. A momentary,
lock-free read -- like THREAD-ALIVE-P, treat it as advisory rather than
linearized with concurrent SEND/RECV.")

(defun make-channel (&key (buffer-size 0))
  "Create a channel. BUFFER-SIZE 0 (the default) is an unbuffered, CSP-style
rendezvous channel: SEND blocks until a RECV takes the value. BUFFER-SIZE N >
0 lets up to N values queue up before SEND blocks."
  (check-type buffer-size (integer 0 #.most-positive-fixnum))
  (%make-channel buffer-size (max 1 buffer-size)))

(progn
  (defconstant +channel-notify-send+ #b0001)
  (defconstant +channel-notify-recv+ #b0010)
  (defconstant +channel-notify-rendezvous+ #b0100)
  (defconstant +channel-notify-close+ #b1000)
  )

(defmacro %channel-notify (channel notifications)
  "Expand the locked channel notification fast path at each state transition.
CHANNEL and NOTIFICATIONS are evaluated exactly once. Waiters carry an interest
mask, so a state transition signals only SELECT operations that can retry."
  (let ((channel-variable (gensym "CHANNEL-"))
        (notifications-variable (gensym "NOTIFICATIONS-"))
        (close-variable (gensym "CLOSE-P-")))
    `(let* ((,channel-variable ,channel)
            (,notifications-variable ,notifications)
            (,close-variable
              (logtest +channel-notify-close+ ,notifications-variable)))
       (declare
        (type channel ,channel-variable)
        (type (unsigned-byte 4) ,notifications-variable))
       (if ,close-variable
           (progn
             (condition-broadcast
              (channel-send-condition-variable ,channel-variable))
             (condition-broadcast
              (channel-recv-condition-variable ,channel-variable))
             (condition-broadcast
              (channel-rendezvous-condition-variable ,channel-variable)))
           (progn
             (when (logtest +channel-notify-send+ ,notifications-variable)
               (condition-notify
                (channel-send-condition-variable ,channel-variable)))
             (when (logtest +channel-notify-recv+ ,notifications-variable)
               (condition-notify
                (channel-recv-condition-variable ,channel-variable)))
             (when (logtest +channel-notify-rendezvous+ ,notifications-variable)
               (condition-notify
                (channel-rendezvous-condition-variable ,channel-variable)))))
       (when (plusp (channel-waiter-count ,channel-variable))
         (maphash
          (lambda (semaphore interests)
            (when (or ,close-variable
                      (logtest ,notifications-variable interests))
              (signal-semaphore semaphore)))
          (channel-waiters ,channel-variable))))))

(defun %channel-add-waiter (channel semaphore &optional (interests #b0111))
  "Register SEMAPHORE for channel events in INTERESTS while CHANNEL is locked."
  (check-type interests (unsigned-byte 3))
  (with-lock-held
    ((channel-lock channel))
    (multiple-value-bind (registered-interests present-p)
        (gethash semaphore (channel-waiters channel))
      (if present-p
          (setf (gethash semaphore (channel-waiters channel))
                (logior (the (unsigned-byte 3) registered-interests) interests))
          (progn
            (setf (gethash semaphore (channel-waiters channel)) interests)
            (incf (channel-waiter-count channel)))))))

(defun %channel-remove-waiter (channel semaphore)
  (with-lock-held
    ((channel-lock channel))
    (when (remhash semaphore (channel-waiters channel))
      (decf (channel-waiter-count channel)))))

(defun send (channel value &key timeout)
  "Send VALUE on CHANNEL, blocking while it is full (buffered) or until a RECV takes VALUE back out (unbuffered). With TIMEOUT (seconds), signals OPERATION-TIMED-OUT if it does not complete in time. Signals CHANNEL-CLOSED if CHANNEL is already closed."
  (with-lock-held
    ((channel-lock channel))
    (let* ((deadline (%deadline-from-timeout timeout))
           (unbuffered-p (zerop (channel-buffer-size channel)))
           (entry
          (if unbuffered-p (%make-channel-message value)
            value))
           (cell nil)
           (capacity (channel-capacity channel)))
      (case (%wait-until
          ((channel-send-condition-variable channel) (channel-lock channel) deadline)
          (cond
            ((channel-closed-p channel) :closed)
            ((< (channel-count channel) capacity) :ready)))
        (:timeout (error (quote operation-timed-out) :operation :send :timeout timeout))
        (:closed (error (quote channel-closed) :channel channel)))
      (setf cell (fifo-push (channel-queue channel) entry))
      (incf (channel-count channel))
      (%channel-notify channel +channel-notify-recv+)
      (when (and
          unbuffered-p
          (eq
            :timeout
            (%wait-until
              ((channel-rendezvous-condition-variable channel)
                (channel-lock channel)
                deadline)
              (%channel-message-received-p entry))))
        (unless (%channel-message-received-p entry)
          (when (fifo-remove (channel-queue channel) cell)
            (decf (channel-count channel))
            (%channel-notify channel +channel-notify-send+))
          (error (quote operation-timed-out) :operation :send :timeout timeout)))))
  t)

(defun recv (channel &key timeout)
  "Receive a value from CHANNEL, blocking until one is available or CHANNEL is closed. Returns (VALUES VALUE T), or (VALUES NIL NIL) once CHANNEL is closed and every value sent before the close has been drained. With TIMEOUT (seconds), signals OPERATION-TIMED-OUT if neither happens in time."
  (with-lock-held
    ((channel-lock channel))
    (let* ((deadline (%deadline-from-timeout timeout))
           (ready
          (%wait-until
            ((channel-recv-condition-variable channel) (channel-lock channel) deadline)
            (cond
              ((plusp (channel-count channel)) :ready)
              ((channel-closed-p channel) :closed)))))
      (case ready
        (:timeout (error (quote operation-timed-out) :operation :recv :timeout timeout))
        (:closed (values nil nil))
        (:ready
          (let* ((entry (fifo-pop (channel-queue channel)))
                 (unbuffered-p (zerop (channel-buffer-size channel))))
            (decf (channel-count channel))
            (when unbuffered-p
              (setf (%channel-message-received-p entry) t))
            (%channel-notify
  channel
  (if unbuffered-p
      (logior +channel-notify-send+ +channel-notify-rendezvous+)
      +channel-notify-send+))
            (values
              (if unbuffered-p (%channel-message-value entry)
                entry)
              t)))))))

(progn
  #-sb-cover
  (declaim (inline try-send try-recv))
  (defun try-send (channel value)
    "Non-blocking SEND: deposit VALUE and return T if room is immediately available, else return NIL. Unlike SEND, does not wait for an unbuffered channel value to actually be received. Signals CHANNEL-CLOSED if CHANNEL is already closed."
    (declare (type channel channel))
    (with-lock-held
      ((channel-lock channel))
      (when (channel-closed-p channel)
        (error (quote channel-closed) :channel channel))
      (when (< (channel-count channel) (channel-capacity channel))
        (fifo-push
          (channel-queue channel)
          (if (zerop (channel-buffer-size channel)) (%make-channel-message value)
            value))
        (incf (channel-count channel))
        (%channel-notify channel +channel-notify-recv+)
        t))))

(defun try-recv (channel)
  "Non-blocking RECV. Returns (VALUES VALUE T NIL) if a value was immediately available, (VALUES NIL NIL T) if CHANNEL is closed and every buffered value has been drained, or (VALUES NIL NIL NIL) if nothing is available right now but CHANNEL may still produce more."
  (declare (type channel channel))
  (with-lock-held
    ((channel-lock channel))
    (cond
      ((plusp (channel-count channel))
        (let* ((entry (fifo-pop (channel-queue channel)))
               (unbuffered-p (zerop (channel-buffer-size channel))))
          (decf (channel-count channel))
          (when unbuffered-p
            (setf (%channel-message-received-p entry) t))
          (%channel-notify
  channel
  (if unbuffered-p
      (logior +channel-notify-send+ +channel-notify-rendezvous+)
      +channel-notify-send+))
          (values
            (if unbuffered-p (%channel-message-value entry)
              entry)
            t
            nil)))
      ((channel-closed-p channel) (values nil nil t))
      (t (values nil nil nil)))))

(defun close-channel (channel)
  "Close CHANNEL: further SEND or TRY-SEND calls signal CHANNEL-CLOSED, but
RECV/TRY-RECV keep draining any values already queued. Idempotent."
  (with-lock-held
    ((channel-lock channel))
    (unless (channel-closed-p channel)
      (setf (channel-closed-p channel) t)
      (%channel-notify channel +channel-notify-close+)))
  channel)
