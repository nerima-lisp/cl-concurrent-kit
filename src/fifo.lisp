;;;; src/fifo.lisp
;;;;
;;;; A minimal FIFO queue, shared by CHANNEL's buffer (src/channel.lisp) and
;;;; the executor's internal work queue (src/executor.lisp). Not part of the
;;;; public API.
(in-package #:cl-concurrent-kit)

(defstruct (fifo (:constructor make-fifo ()))
  (head nil)
  (tail nil))

(defun fifo-empty-p (fifo)
  (null (fifo-head fifo)))

(defun fifo-push (fifo item)
  (let ((cell (list item)))
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
