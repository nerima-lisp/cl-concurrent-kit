;;;; t/select-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "select"
  (it "chooses the first ready RECV clause in source order"
    (let ((empty (make-channel :buffer-size 1))
          (first-ready (make-channel :buffer-size 1))
          (second-ready (make-channel :buffer-size 1)))
      (send first-ready :from-first)
      (send second-ready :from-second)
      (expect (select
                ((recv empty) (v) (list :empty v))
                ((recv first-ready) (v) (list :first v))
                ((recv second-ready) (v) (list :second v)))
              :to-equal (list :first :from-first))))

  (it "runs :DEFAULT immediately when nothing is ready"
    (let ((channel (make-channel :buffer-size 1)))
      (expect (select
                ((recv channel) (v) (list :recv v))
                (:default () :nothing-ready))
              :to-be :nothing-ready)))

  (it "blocks until another thread makes a clause ready"
    (let* ((channel (make-channel))
           (producer (make-thread (lambda () (sleep 0.05) (send channel :delayed)))))
      (expect (select ((recv channel) (v) v)) :to-be :delayed)
      (join-thread producer)))

  (it "runs :TIMEOUT when nothing becomes ready in time"
    (let ((channel (make-channel :buffer-size 1)))
      (expect (select
                ((recv channel) (v) (list :recv v))
                (:timeout 0.05 () :gave-up))
              :to-be :gave-up)))

  (it "runs :TIMEOUT without waiting when its deadline has already expired"
    (let ((channel (make-channel :buffer-size 1)))
      (expect (select
                ((recv channel) (v) (list :recv v))
                (:timeout 0 () :expired))
              :to-be :expired)))

  (it "can select on a SEND clause"
    (let* ((channel (make-channel))
           (consumer (future (recv channel))))
      (expect (select ((send channel :sent-via-select) () :sent)) :to-be :sent)
      (expect (await consumer :timeout 1) :to-be :sent-via-select)))
  (it "does not choose an unready SEND clause; falls through to DEFAULT instead"
    (let ((channel (make-channel :buffer-size 1)))
      (send channel :occupies-the-only-slot)
      (expect (select
                ((send channel :blocked) () :sent)
                (:default () :fell-through))
              :to-be :fell-through))))
