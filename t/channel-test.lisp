;;;; t/channel-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "unbuffered channel"
  (it "rendezvous: SEND does not return until a RECV takes the value"
    (let* ((channel (make-channel))
           (sender (future (send channel :payload))))
      ;; Nobody has RECV'd yet, so the future's SEND must still be blocked.
      (signals operation-timed-out (await sender :timeout 0.05d0))
      (expect (recv channel) :to-be :payload)
      ;; Now that RECV has taken it, SEND's future settles.
      (expect (await sender :timeout 1) :to-be-truthy)))

  (it "RECV blocks until a SEND provides a value"
    (let* ((channel (make-channel))
           (receiver (future (recv channel))))
      (signals operation-timed-out (await receiver :timeout 0.05d0))
      (send channel :arrived)
      (expect (await receiver :timeout 1) :to-be :arrived))))

(describe "buffered channel"
  (it "TRY-SEND succeeds up to BUFFER-SIZE, then reports no room"
    (let ((channel (make-channel :buffer-size 2)))
      (expect (try-send channel 1) :to-be-truthy)
      (expect (try-send channel 2) :to-be-truthy)
      (expect (try-send channel 3) :to-be nil)))

  (it "RECV drains values in FIFO order"
    (let ((channel (make-channel :buffer-size 3)))
      (send channel :a)
      (send channel :b)
      (expect (recv channel) :to-be :a)
      (expect (recv channel) :to-be :b)))

  (it-property "RECV returns every buffered value in the order it was SENT, for any batch"
      ((values (gen-list (gen-integer :min -1000 :max 1000) :min-length 0 :max-length 32)))
    (let ((channel (make-channel :buffer-size (max 1 (length values)))))
      (dolist (value values) (send channel value))
      (expect (loop repeat (length values) collect (recv channel)) :to-equal values))))

(describe "closing a channel"
  (it "lets RECV drain already-buffered values, then reports closed"
    (let ((channel (make-channel :buffer-size 2)))
      (send channel :queued)
      (close-channel channel)
      (multiple-value-bind (value ok-p) (recv channel)
        (expect value :to-be :queued)
        (expect ok-p :to-be-truthy))
      (multiple-value-bind (value ok-p) (recv channel)
        (expect value :to-be nil)
        (expect ok-p :to-be nil))))

  (it "signals CHANNEL-CLOSED on SEND or TRY-SEND after close"
    (let ((channel (make-channel)))
      (close-channel channel)
      (signals channel-closed (send channel :too-late))
      (signals channel-closed (try-send channel :too-late))))

  (it "is idempotent"
    (let ((channel (make-channel)))
      (close-channel channel)
      (close-channel channel)
      (expect (channel-closed-p channel) :to-be-truthy))))

(describe "try-recv"
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

(describe "channel SELECT waiter registration"
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
