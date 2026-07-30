;;;; t/select-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe
  "select"
  (it
    "chooses a RECV clause whose channel already has a value"
    (let ((empty (make-channel :buffer-size 1))
          (ready (make-channel :buffer-size 1)))
      (send ready :from-ready)
      (expect
        (select ((recv empty) (v) (list :empty v)) ((recv ready) (v) (list :ready v)))
        :to-equal
        `(:ready :from-ready))))
  (it
    "runs :DEFAULT for blocked receive and send clauses"
    (let ((empty (make-channel :buffer-size 1))
          (full (make-channel :buffer-size 1)))
      (send full :occupied)
      (expect
        (select ((recv empty) (value) (list :recv value)) (:default () :nothing-ready))
        :to-be
        :nothing-ready)
      (expect
        (select ((send full :next) () :sent) (:default () :nothing-ready))
        :to-be
        :nothing-ready)
      (expect (recv full) :to-be :occupied)))
  (it
    "blocks until another thread makes a clause ready"
    (let* ((channel (make-channel))
           (producer
          (make-thread
            (lambda ()
              (sleep 0.05)
              (send channel :delayed)))))
      (expect (select ((recv channel) (v) v)) :to-be :delayed)
      (join-thread producer)))
  (it
    "runs :TIMEOUT for blocked receive and send clauses"
    (let ((empty (make-channel :buffer-size 1))
          (full (make-channel :buffer-size 1)))
      (send full :occupied)
      (expect
        (select ((recv empty) (value) (list :recv value)) (:timeout 0.05d0 () :gave-up))
        :to-be
        :gave-up)
      (expect
        (select ((send full :next) () :sent) (:timeout 0.05d0 () :gave-up))
        :to-be
        :gave-up)
      (expect (recv full) :to-be :occupied)))
  (it
    "runs :TIMEOUT without waiting when its deadline has already expired"
    (let ((channel (make-channel :buffer-size 1)))
      (expect
        (select ((recv channel) (v) (list :recv v)) (:timeout 0 () :expired))
        :to-be
        :expired)))
  (it
    "can select on a SEND clause"
    (let* ((channel (make-channel))
           (consumer (future (recv channel))))
      (expect (select ((send channel :sent-via-select) () :sent)) :to-be :sent)
      (expect (await consumer :timeout 1) :to-be :sent-via-select)))
  (it
    "does not choose an unready SEND clause; falls through to DEFAULT instead"
    (let ((channel (make-channel :buffer-size 1)))
      (send channel :occupies-the-only-slot)
      (expect
        (select ((send channel :blocked) () :sent) (:default () :fell-through))
        :to-be
        :fell-through)))
  (it
    "selects closed receives and signals for closed sends"
    (let ((channel (make-channel)))
      (close-channel channel)
      (expect
        (select ((recv channel) (value) (list :closed value)) (:default () :default))
        :to-equal
        `(:closed nil))
      (signals
        channel-closed
        (select ((send channel :value) () :sent) (:default () :default)))))
  (it
    "rejects a SELECT form that combines :DEFAULT and :TIMEOUT"
    (signals
      error
      (macroexpand-1 `(select (:default () :default) (:timeout 0.01d0 () :timed-out)))))
  (it
    "rejects a SELECT form with no channel operation"
    (signals error (macroexpand-1 `(select))))
  (it
    "supports an unbound RECV value and rejects duplicate special clauses"
    (expect
      (macroexpand-1 `(select ((recv channel) () :received) (:default () :default)))
      :to-be-truthy)
    (signals
      error
      (macroexpand-1
        `(select
          ((recv channel) () :received)
          (:default () :first)
          (:default () :second))))
    (signals
      error
      (macroexpand-1
        `(select
          ((recv channel) () :received)
          (:default ())
          (:default ()))))
    (signals
      error
      (macroexpand-1
        `(select
          ((recv channel) () :received)
          (:timeout 0.01d0 () :first)
          (:timeout 0.02d0 () :second))))))

(describe
  "select argument evaluation"
  (it
    "evaluates SEND channel and value forms once before retries"
    (let ((channel (make-channel :buffer-size 1))
          (channel-evaluations 0)
          (value-evaluations 0))
      (send channel :occupied)
      (expect
        (select
          ((send
              (progn
                (incf channel-evaluations)
                channel)
              (progn
                (incf value-evaluations)
                :next))
            ()
            :sent)
          (:timeout 0.02d0 () :timed-out))
        :to-be
        :timed-out)
      (expect channel-evaluations :to-be 1)
      (expect value-evaluations :to-be 1)
      (expect (recv channel) :to-be :occupied)))
  (it
    "evaluates a TIMEOUT form once before probing ready clauses"
    (let ((channel (make-channel :buffer-size 1))
          (timeout-evaluations 0))
      (send channel :ready)
      (expect
        (select
          ((recv channel) (value) value)
          (:timeout
            (progn
              (incf timeout-evaluations)
              1)
            ()
            :timed-out))
        :to-be
        :ready)
      (expect timeout-evaluations :to-be 1)))
  (it
    "expands clause dispatch without runtime handler closures"
    (let ((expanded
          (prin1-to-string
            (macroexpand-1 (quote (select ((recv channel) (value) value)))))))
      (expect (search "LAMBDA" expanded) :to-be nil)
      (expect (search "FUNCALL" expanded) :to-be nil)))
  (it
    "removes its waiter after a timeout"
    (let ((channel (make-channel)))
      (expect
        (select ((recv channel) (value) value) (:timeout 0.01 () nil))
        :to-be
        nil)
      (expect
        (hash-table-count (cl-concurrent-kit::channel-waiters channel))
        :to-be
        0)))
  (it
  "registers unioned interests and signals only matching waiters"
  (let ((channel (make-channel :buffer-size 1))
        (send-waiter (make-semaphore))
        (recv-waiter (make-semaphore))
        (both-waiter (make-semaphore)))
    (unwind-protect
        (progn
          (cl-concurrent-kit::%channel-add-waiter
            channel send-waiter cl-concurrent-kit::+channel-notify-send+)
          (cl-concurrent-kit::%channel-add-waiter
            channel recv-waiter cl-concurrent-kit::+channel-notify-recv+)
          (cl-concurrent-kit::%channel-add-waiter
            channel both-waiter cl-concurrent-kit::+channel-notify-send+)
          (cl-concurrent-kit::%channel-add-waiter
            channel both-waiter cl-concurrent-kit::+channel-notify-recv+)
          (expect
            (hash-table-count (cl-concurrent-kit::channel-waiters channel))
            :to-be
            3)
          (expect (cl-concurrent-kit::channel-waiter-count channel) :to-be 3)
          (try-send channel :value)
          (expect (wait-on-semaphore recv-waiter :timeout 0.01d0) :to-be-truthy)
          (expect (wait-on-semaphore both-waiter :timeout 0.01d0) :to-be-truthy)
          (expect (wait-on-semaphore send-waiter :timeout 0.01d0) :to-be nil)
          (try-recv channel)
          (expect (wait-on-semaphore send-waiter :timeout 0.01d0) :to-be-truthy)
          (expect (wait-on-semaphore both-waiter :timeout 0.01d0) :to-be-truthy))
      (cl-concurrent-kit::%channel-remove-waiter channel send-waiter)
      (cl-concurrent-kit::%channel-remove-waiter channel recv-waiter)
      (cl-concurrent-kit::%channel-remove-waiter channel both-waiter))))
  (it
    "accepts declarations in every selected clause body"
    (let ((ready (make-channel :buffer-size 1))
          (sendable (make-channel :buffer-size 1))
          (blocked (make-channel)))
      (send ready :ready)
      (expect
        (select
          ((recv ready)
            ()
            (declare (optimize (speed 3)))
            :received))
        :to-be
        :received)
      (expect
        (select
          ((send sendable :value)
            ()
            (declare (optimize (speed 3)))
            :sent))
        :to-be
        :sent)
      (expect
        (select
          ((recv blocked) () :received)
          (:default
            ()
            (declare (optimize (speed 3)))
            :default))
        :to-be
        :default)
      (expect
        (select
          ((recv blocked) () :received)
          (:timeout
            0
            ()
            (declare (optimize (speed 3)))
            :timeout))
        :to-be
        :timeout))))

(describe
  "select direct probes"
  (it
    "expands direct probes without a runtime operation table"
    (let ((expanded
          (prin1-to-string
            (macroexpand-1
              (quote
                (select
                  ((recv first-channel) (value) value)
                  ((send second-channel :value) () :sent)))))))
      (expect (search "%RUN-SELECT" expanded) :to-be nil)
      (expect (search "%SELECT-READY" expanded) :to-be nil)
      (expect (search "%TRY-CLAUSE" expanded) :to-be nil)
      (expect (search "VECTOR" expanded) :to-be nil)
      (expect (search "TRY-RECV" expanded) :to-be-truthy)
      (expect (search "TRY-SEND" expanded) :to-be-truthy)))
  (it
    "chooses the earliest ready clause in declaration order"
    (let ((first-channel (make-channel :buffer-size 1))
          (second-channel (make-channel :buffer-size 1)))
      (send first-channel :first)
      (send second-channel :second)
      (expect
        (select
          ((recv first-channel) (value) (list :first value))
          ((recv second-channel) (value) (list :second value)))
        :to-equal
        (list :first :first))
      (expect (recv second-channel) :to-be :second)))
  (it
    "removes duplicate-channel waiters after a timeout"
    (let ((channel (make-channel)))
      (expect
        (select
          ((recv channel) (value) value)
          ((recv channel) (value) value)
          (:timeout 0.01d0 () :timed-out))
        :to-be
        :timed-out)
      (expect
        (hash-table-count (cl-concurrent-kit::channel-waiters channel))
        :to-be
        0)
      (expect (cl-concurrent-kit::channel-waiter-count channel) :to-be 0))))
