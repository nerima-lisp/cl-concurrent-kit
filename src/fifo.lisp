(progn
  (declaim (optimize
      (speed 3)
      (safety 1)
      (debug 0)
      (compilation-speed 0)
      #+sb-cover (sb-c:store-coverage-data 3)))
  (in-package #:cl-concurrent-kit))

(progn
  (defstruct (fifo-cell (:constructor %make-fifo-cell (value))) (value nil :read-only t)
    (previous nil :type (or null fifo-cell))
    (next nil :type (or null fifo-cell))
    (linked-p nil :type boolean))
  (defstruct (fifo (:constructor make-fifo ())) (head nil :type (or null fifo-cell))
    (tail nil :type (or null fifo-cell))))

(progn
  #-sb-cover
  (declaim (inline fifo-empty-p fifo-remove fifo-push fifo-pop fifo-detach))
  (defun fifo-empty-p (fifo)
    (declare (type fifo fifo))
    (null (fifo-head fifo)))
  (defun fifo-remove (fifo cell)
    (declare (type fifo fifo)
             (type fifo-cell cell))
    (when (fifo-cell-linked-p cell)
      (let ((previous (fifo-cell-previous cell))
            (next (fifo-cell-next cell)))
        (if previous (setf (fifo-cell-next previous) next)
          (setf (fifo-head fifo) next))
        (if next (setf (fifo-cell-previous next) previous)
          (setf (fifo-tail fifo) previous))
        (setf (fifo-cell-previous cell) nil
              (fifo-cell-next cell) nil
              (fifo-cell-linked-p cell) nil)
        t)))
  (defun fifo-detach (fifo)
    (declare (type fifo fifo))
    (when (fifo-head fifo)
      (let ((detached (make-fifo)))
        (setf (fifo-head detached) (fifo-head fifo)
              (fifo-tail detached) (fifo-tail fifo)
              (fifo-head fifo) nil
              (fifo-tail fifo) nil)
        detached)))
  (defun fifo-push (fifo value)
    (declare (type fifo fifo))
    (let ((cell (%make-fifo-cell value)))
      (if (fifo-tail fifo) (setf (fifo-cell-next (fifo-tail fifo)) cell
              (fifo-cell-previous cell) (fifo-tail fifo))
        (setf (fifo-head fifo) cell))
      (setf (fifo-tail fifo) cell
            (fifo-cell-linked-p cell) t)
      cell))
  (defun fifo-pop (fifo)
    (declare (type fifo fifo))
    (let ((cell (fifo-head fifo)))
      (when cell
        (let ((next (fifo-cell-next cell)))
          (setf (fifo-head fifo) next)
          (if next (setf (fifo-cell-previous next) nil)
            (setf (fifo-tail fifo) nil))
          (setf (fifo-cell-next cell) nil
                (fifo-cell-linked-p cell) nil)
          (fifo-cell-value cell))))))
