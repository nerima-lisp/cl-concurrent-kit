;;;; src/fifo.lisp
;;;;
;;;; An intrusive doubly-linked FIFO queue, shared by CHANNEL's buffer
;;;; (src/channel.lisp) and the executor's internal work queue
;;;; (src/executor.lisp). Not part of the public API.
;;;;
;;;; Each FIFO-CELL knows its own place in the list, so removing a specific
;;;; cell (FIFO-REMOVE, used to cancel a pending executor task) is O(1)
;;;; instead of an O(N) list scan, and detaching every cell at once
;;;; (FIFO-DETACH, used to drain the queue on executor shutdown) is O(1)
;;;; regardless of queue length.
(in-package #:cl-concurrent-kit)

(defstruct (fifo-cell (:constructor %make-fifo-cell (value)))
  (value nil :read-only t)
  (previous nil :type (or null fifo-cell))
  (next nil :type (or null fifo-cell))
  (linked-p nil :type boolean))

(defstruct (fifo (:constructor make-fifo ()))
  (head nil :type (or null fifo-cell))
  (tail nil :type (or null fifo-cell)))

(defun fifo-empty-p (fifo)
  (declare (type fifo fifo))
  (null (fifo-head fifo)))

(defun fifo-push (fifo value)
  "Append VALUE to FIFO's tail and return the new FIFO-CELL, so callers that
need to cancel a specific entry later (e.g. the executor's pending queue)
can hand it back to FIFO-REMOVE."
  (declare (type fifo fifo))
  (let ((cell (%make-fifo-cell value)))
    (if (fifo-tail fifo)
        (setf (fifo-cell-next (fifo-tail fifo)) cell
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
        (if next
            (setf (fifo-cell-previous next) nil)
            (setf (fifo-tail fifo) nil))
        (setf (fifo-cell-next cell) nil
              (fifo-cell-linked-p cell) nil))
      (fifo-cell-value cell))))

(defun fifo-remove (fifo cell)
  "Remove CELL from FIFO in O(1), wherever it currently sits in the list.
A no-op (returns NIL) if CELL has already been removed or popped."
  (declare (type fifo fifo)
           (type fifo-cell cell))
  (when (fifo-cell-linked-p cell)
    (let ((previous (fifo-cell-previous cell))
          (next (fifo-cell-next cell)))
      (if previous
          (setf (fifo-cell-next previous) next)
          (setf (fifo-head fifo) next))
      (if next
          (setf (fifo-cell-previous next) previous)
          (setf (fifo-tail fifo) previous))
      (setf (fifo-cell-previous cell) nil
            (fifo-cell-next cell) nil
            (fifo-cell-linked-p cell) nil)
      t)))

(defun fifo-detach (fifo)
  "Remove every cell currently in FIFO and return them as a fresh FIFO of
their own, in O(1) -- used to drain the whole queue at once (e.g. cancelling
every pending executor task on shutdown) without popping one cell at a time.
Returns NIL, leaving FIFO untouched, if FIFO was already empty."
  (declare (type fifo fifo))
  (when (fifo-head fifo)
    (let ((detached (make-fifo)))
      (setf (fifo-head detached) (fifo-head fifo)
            (fifo-tail detached) (fifo-tail fifo)
            (fifo-head fifo) nil
            (fifo-tail fifo) nil)
      detached)))
