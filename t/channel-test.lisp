;;;; t/channel-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe-concurrent
  "unbuffered channel"
  (it "recognizes CHANNEL values" (let ((channel (make-channel))) (expect (channel-p channel) :to-be-truthy) (expect (channel-p :not-a-channel) :to-be nil)))
  (it
    "rendezvous: SEND does not return until a RECV takes the value"
    (let* ((channel (make-channel))
           (sender (future (send channel :payload))))
      (signals operation-timed-out (await sender :timeout +test-timeout-expiry+))
      (expect (recv channel) :to-be :payload)
      (expect (await sender :timeout +test-timeout+) :to-be-truthy)))
  (it
    "RECV blocks until a SEND provides a value"
    (let* ((channel (make-channel))
           (receiver (future (recv channel))))
      (signals operation-timed-out (await receiver :timeout +test-timeout-expiry+))
      (send channel :arrived)
      (expect (await receiver :timeout +test-timeout+) :to-be :arrived)))
  (it
    "retracts an unreceived send when its timeout expires"
    (let ((channel (make-channel)))
      (signals operation-timed-out (send channel :value :timeout +test-timeout-expiry+))
      (multiple-value-bind (value received-p closed-p) (try-recv channel)
        (declare (ignore value))
        (expect received-p :to-be nil)
        (expect closed-p :to-be nil))))
  (it
    "separately wakes an acknowledged sender and a capacity waiter"
    (let* ((channel (make-channel))
           (first-sender (future (send channel :first))))
      (signals operation-timed-out (await first-sender :timeout +test-timeout-expiry+))
      (let ((second-sender (future (send channel :second))))
        (signals operation-timed-out (await second-sender :timeout +test-timeout-expiry+))
        (expect (recv channel) :to-be :first)
        (expect (await first-sender :timeout +test-timeout+) :to-be-truthy)
        (expect (recv channel) :to-be :second)
        (expect (await second-sender :timeout +test-timeout+) :to-be-truthy))))
  (progn
    (it
      "delivers TRY-SEND values after a close"
      (let ((channel (make-channel)))
        (expect (try-send channel :queued) :to-be-truthy)
        (close-channel channel)
        (multiple-value-bind (value received-p closed-p) (try-recv channel)
          (expect value :to-be :queued)
          (expect received-p :to-be-truthy)
          (expect closed-p :to-be nil))))
    (it
      "reports the RECV timeout without leaving a pending operation"
      (let ((channel (make-channel)))
        (expect-signals (condition operation-timed-out) (recv channel :timeout +test-timeout-expiry+)
          (expect (operation-timed-out-operation condition) :to-be :recv)
          (expect (operation-timed-out-timeout condition) :to-be 1/20))))))

(describe-concurrent
  "buffered channel"
  (it
    "TRY-SEND succeeds up to BUFFER-SIZE, then reports no room"
    (let ((channel (make-channel :buffer-size 2)))
      (expect (try-send channel 1) :to-be-truthy)
      (expect (try-send channel 2) :to-be-truthy)
      (expect (try-send channel 3) :to-be nil)))
  (it
    "RECV drains values in FIFO order"
    (let ((channel (make-channel :buffer-size 3)))
      (send channel :a)
      (send channel :b)
      (expect (recv channel) :to-be :a)
      (expect (recv channel) :to-be :b)))

  (it-property "RECV returns every buffered value in the order it was SENT, for any batch"
      ((values (gen-list (gen-integer :min -1000 :max 1000) :min-length 0 :max-length 32)))
    (let ((channel (make-channel :buffer-size (max 1 (length values)))))
      (dolist (value values) (send channel value))
      (expect (loop repeat (length values) collect (recv channel)) :to-equal values)))
  (it "blocks SEND once the buffer is full, then wakes it when RECV frees a slot"
    (let* ((channel (make-channel :buffer-size 1)))
      (send channel :first)
      (let ((blocked-sender (future (send channel :second))))
        (signals operation-timed-out (await blocked-sender :timeout +test-timeout-expiry+))
        (expect (recv channel) :to-be :first)
        (expect (await blocked-sender :timeout +test-timeout+) :to-be-truthy)
        (expect (recv channel) :to-be :second))))
  (it
    "reports the SEND timeout while the buffered channel remains full"
    (let ((channel (make-channel :buffer-size 1)))
      (send channel :first)
      (expect-signals (condition operation-timed-out) (send channel :second :timeout +test-timeout-expiry+)
        (expect (operation-timed-out-operation condition) :to-be :send)
        (expect (operation-timed-out-timeout condition) :to-be 1/20))
      (expect (recv channel) :to-be :first))))

(describe-concurrent
  "closing a channel"
  (it
    "lets RECV drain already-buffered values, then reports closed"
    (let ((channel (make-channel :buffer-size 2)))
      (send channel :queued)
      (close-channel channel)
      (multiple-value-bind (value ok-p) (recv channel)
        (with-soft-assertions
          (expect value :to-be :queued)
          (expect ok-p :to-be-truthy)))
      (multiple-value-bind (value ok-p) (recv channel)
        (with-soft-assertions
          (expect value :to-be nil)
          (expect ok-p :to-be nil)))))
  (it
    "wakes blocked senders and receivers"
    (let* ((send-channel (make-channel :buffer-size 1))
           (recv-channel (make-channel))
           (sender nil)
           (receiver nil))
      (send send-channel :occupied)
      (setf sender (future (send send-channel :blocked)))
      (setf receiver (future (recv recv-channel)))
      (signals operation-timed-out (await sender :timeout +test-timeout-expiry+))
      (signals operation-timed-out (await receiver :timeout +test-timeout-expiry+))
      (close-channel send-channel)
      (close-channel recv-channel)
      (signals channel-closed (await sender :timeout +test-timeout+))
      (multiple-value-bind (value received-p) (await receiver :timeout +test-timeout+)
        (expect value :to-be nil)
        (expect received-p :to-be nil))))
  (it "signals CHANNEL-CLOSED on SEND or TRY-SEND after close"
    (let ((channel (make-channel)))
      (close-channel channel)
      (expect-signals (condition channel-closed) (send channel :too-late) (expect (eq (channel-closed-channel condition) channel) :to-be-truthy))
      (signals channel-closed (try-send channel :too-late))))
  (it
    "is idempotent"
    (let ((channel (make-channel)))
      (close-channel channel)
      (close-channel channel)
      (expect (channel-closed-p channel) :to-be-truthy))))

(describe-concurrent "try-recv"
  (it "distinguishes not-yet-ready from closed-and-drained"
    (let ((channel (make-channel :buffer-size 1)))
      (multiple-value-bind (value ok-p closed-p) (try-recv channel)
        (declare (ignore value))
        (expect ok-p :to-be nil)
        (expect closed-p :to-be nil))
      (close-channel channel)
      (multiple-value-bind (value ok-p closed-p) (try-recv channel)
        (declare (ignore value))
        (expect ok-p :to-be nil)
        (expect closed-p :to-be-truthy)))))

  (describe-concurrent "channel SELECT waiter registration"
  (it "deduplicates repeated registration of the same SELECT waiter"
    (let ((channel (make-channel))
          (waiter (make-semaphore)))
      (cl-concurrent-kit::%channel-add-waiter channel waiter)
      (cl-concurrent-kit::%channel-add-waiter channel waiter)
      (expect (hash-table-count
               (cl-concurrent-kit::channel-waiters channel))
              :to-be 1)
      (cl-concurrent-kit::%channel-remove-waiter channel waiter)
      (expect (hash-table-count
               (cl-concurrent-kit::channel-waiters channel))
              :to-be 0))))

(describe-concurrent "channel ring-buffer invariants" (it "preserves FIFO order across repeated ring wraparound" (let ((channel (make-channel :buffer-size 3))) (dotimes (round 8) (let ((base (* round 3))) (send channel base) (send channel (1+ base)) (send channel (+ base 2)) (expect (recv channel) :to-be base) (expect (recv channel) :to-be (1+ base)) (expect (recv channel) :to-be (+ base 2)))))))
