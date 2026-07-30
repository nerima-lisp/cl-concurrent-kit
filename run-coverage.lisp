(progn
  (format *error-output* "coverage: bootstrap~%")
  (finish-output *error-output*)
  (require :sb-cover)
  (format *error-output* "coverage: sb-cover~%")
  (finish-output *error-output*)
  (require :asdf)
  (format *error-output* "coverage: asdf~%")
  (finish-output *error-output*)
  (pushnew :sb-cover *features*)
  nil)

(sb-cover:enable-coverage-logging)

(progn
  (defun script-directory ()
    (make-pathname :name nil :type nil :defaults *load-pathname*))
  (defun source-root ()
    (or
      (let ((value (uiop:getenv "CL_CONCURRENT_KIT_SOURCE_ROOT")))
        (and value (uiop:ensure-directory-pathname value)))
      (truename (merge-pathnames "./" (script-directory)))))
  (defun output-directory ()
    (uiop:ensure-directory-pathname
      (or
        (first uiop:*command-line-arguments*)
        (error "Usage: sbcl --script run-coverage.lisp OUTPUT-DIRECTORY"))))
  (defun source-files (root)
    (mapcar
      (lambda (relative)
        (truename (merge-pathnames relative root)))
      (list
        #P"src/package.lisp"
        #P"src/conditions.lisp"
        #P"src/primitives.lisp"
        #P"src/fifo.lisp"
        #P"src/promise.lisp"
        #P"src/channel.lisp"
        #P"src/select.lisp"
        #P"src/executor.lisp"
        #P"src/scope-state.lisp"
        #P"src/scope-execution.lisp"
        #P"src/scope.lisp")))
  (defun discard-non-source-coverage-records (source-names)
    (let ((table (sb-cover::code-coverage-hashtable))
          (discarded nil))
      (maphash
        (lambda (filename record)
          (declare (ignore record))
          (unless (member (namestring (truename filename)) source-names :test (function string=))
            (push filename discarded)))
        table)
      (dolist (filename discarded)
        (remhash filename table))))
  (let ((root (source-root))
        (output-directory (output-directory)))
    (ensure-directories-exist output-directory)
    (let ((*package* (find-package :asdf)))
      (load (merge-pathnames #P"cl-concurrent-kit.asd" root)))
    (format *error-output* "coverage: compile~%")
    (finish-output *error-output*)
    (asdf:compile-system "cl-concurrent-kit" :force t)
    (format *error-output* "coverage: load~%")
    (finish-output *error-output*)
    (asdf:load-system "cl-concurrent-kit" :force t)
    (format *error-output* "coverage: test~%")
    (finish-output *error-output*)
    (asdf:test-system "cl-concurrent-kit")
    (format *error-output* "coverage: report~%")
    (finish-output *error-output*)
    (let ((source-names (mapcar (function namestring) (source-files root))))
      (discard-non-source-coverage-records source-names)
      (sb-cover:report
        (merge-pathnames #P"html/" output-directory)
        :if-matches
        (lambda (filename)
          (member filename source-names :test (function string=))))
      (sb-cover:lcov-report (merge-pathnames #P"lcov.info" output-directory)))
    (format t "Coverage report written to ~A~%" output-directory)))
