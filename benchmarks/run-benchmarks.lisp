(require :asdf)

(defun script-directory ()
  (make-pathname :name nil :type nil :defaults *load-pathname*))

(defun source-root ()
  (or
    (let ((value (uiop:getenv "CL_CONCURRENT_KIT_SOURCE_ROOT")))
      (and value (uiop:ensure-directory-pathname value)))
    (truename (merge-pathnames "../" (script-directory)))))

(let ((*package* (find-package :asdf)))
  (load (merge-pathnames #P"cl-concurrent-kit.asd" (source-root))))

(asdf:load-system "cl-concurrent-kit")

(in-package #:cl-concurrent-kit)

(defparameter +benchmark-samples+ 5)

(defun elapsed-seconds (start end)
  (/ (- end start) internal-time-units-per-second))

(defun median (values)
  (let ((sorted (sort (copy-seq values) #'<)))
    (elt sorted (floor (length sorted) 2))))

(defun sample-benchmark (thunk)
  (let ((start (get-internal-real-time))
        #+sbcl (bytes-before (sb-ext:get-bytes-consed)))
    (funcall thunk)
    (values
      (elapsed-seconds start (get-internal-real-time))
      #+sbcl (- (sb-ext:get-bytes-consed) bytes-before)
      #-sbcl 0)))

(defun report-benchmark (name iterations operations thunk)
  (funcall thunk)
  (let ((seconds nil)
        (bytes-consed nil))
    (dotimes (sample +benchmark-samples+)
      (declare (ignore sample))
      (sb-ext:gc :full t)
      (multiple-value-bind (elapsed consed) (sample-benchmark thunk)
        (push elapsed seconds)
        (push consed bytes-consed)))
    (let* ((median-seconds (median seconds))
           (minimum-seconds (reduce #'min seconds))
           (median-bytes (median bytes-consed))
           (operations-per-second (/ operations median-seconds)))
      (format
        *error-output*
        "~A: ~D samples, min=~,6Fs median=~,6Fs median-bytes-consed=~D~%"
        name
        +benchmark-samples+
        minimum-seconds
        median-seconds
        median-bytes)
      (format
        t
        "~A~C~D~C~D~C~,9F~C~,3F~%"
        name
        #\Tab
        iterations
        #\Tab
        operations
        #\Tab
        median-seconds
        #\Tab
        operations-per-second))))

(defun benchmark-atomic-counter (iterations)
  (let ((counter (make-atomic-counter)))
    (report-benchmark
      "atomic-counter-incf"
      iterations
      iterations
      (lambda ()
        (dotimes (index iterations)
          (declare (ignore index))
          (atomic-counter-incf counter))))))

(defun benchmark-buffered-channel (iterations)
  (let ((channel (make-channel :buffer-size 1)))
    (report-benchmark
      "buffered-channel-round-trip"
      iterations
      (* 2 iterations)
      (lambda ()
        (dotimes (index iterations)
          (send channel index)
          (recv channel))))))

(defun benchmark-select-ready-recv (iterations)
  (let ((channel (make-channel :buffer-size 1)))
    (report-benchmark
      "select-ready-recv"
      iterations
      (* 2 iterations)
      (lambda ()
        (dotimes (index iterations)
          (send channel index)
          (select ((recv channel) (value) value)))))))

(defun benchmark-executor (iterations)
  (let ((executor (make-executor :size 4)))
    (unwind-protect (report-benchmark
        "executor-submit-await"
        iterations
        (* 2 iterations)
        (lambda ()
          (dotimes (index iterations)
            (declare (ignore index))
            (await
              (submit
                executor
                (lambda ()
                  nil))))))
      (shutdown-executor executor :wait t))))

(defun main ()
  (let ((iterations
        (or
          (ignore-errors (parse-integer (first uiop:*command-line-arguments*)))
          1000000)))
    (format
      t
      "name~Citerations~Coperations~Cseconds~Coperations-per-second~%"
      #\Tab
      #\Tab
      #\Tab
      #\Tab)
    (benchmark-atomic-counter iterations)
    (benchmark-buffered-channel iterations)
    (benchmark-select-ready-recv iterations)
    (benchmark-executor iterations)))

(main)
