;;;; t/select-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "select"
  (it "chooses a RECV clause whose channel already has a value"
    (let ((empty (make-channel :buffer-size 1))
          (ready (make-channel :buffer-size 1)))
      (send ready :from-ready)
      (expect (select
                ((recv empty) (v) (list :empty v))
                ((recv ready) (v) (list :ready v)))
              :to-equal '(:ready :from-ready))))

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

  (it "can select on a SEND clause"
    (let* ((channel (make-channel))
           (consumer (future (recv channel))))
      (expect (select ((send channel :sent-via-select) () :sent)) :to-be :sent)
      (expect (await consumer :timeout 1) :to-be :sent-via-select))))
