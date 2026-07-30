(progn
  #.(progn (require :asdf) (require :sb-cover) nil)
  (defun script-directory ()
    (make-pathname :name nil
                   :type nil
                   :defaults (or *load-truename*
                                 *compile-file-truename*
                                 (error "Unable to determine the script location"))))

  (defun configure-local-source-registry (root)
    (asdf:initialize-source-registry
     `(:source-registry
       (:tree ,root)
       :inherit-configuration)))

  (defun output-directory ()
    (let ((argument (first (uiop:command-line-arguments))))
      (ensure-directories-exist
       (if argument
           (uiop:ensure-directory-pathname (uiop:parse-native-namestring argument))
           (merge-pathnames "coverage/" (uiop:getcwd))))))

  (defun configure-isolated-output-cache (directory)
    (let ((cache (merge-pathnames "asdf-cache/" directory)))
      (ensure-directories-exist cache)
      (asdf:initialize-output-translations
       `(:output-translations
         (t ,cache)
         :ignore-inherited-configuration))))

  (defun source-file-p (file root)
    (uiop:subpathnamep (uiop:parse-native-namestring file) root))

  (defun discard-ineligible-coverage-records (root)
    (let ((table (sb-cover::code-coverage-hashtable))
          (discarded-files nil))
      (maphash (lambda (file coverage)
                 (declare (ignore coverage))
                 (unless (source-file-p file root)
                   (push file discarded-files)))
               table)
      (dolist (file discarded-files)
        (remhash file table))))

  (let* ((root (script-directory))
         (output (output-directory)))
    (configure-local-source-registry root)
    (configure-isolated-output-cache output)
    (declaim (optimize (sb-cover:store-coverage-data 3)))
    (asdf:load-system "cl-concurrent-kit" :force t)
    (declaim (optimize (sb-cover:store-coverage-data 0)))
    (asdf:test-system "cl-concurrent-kit")
    (discard-ineligible-coverage-records root)
    (sb-cover:report (merge-pathnames "html/" output)
                      :if-matches (lambda (file)
                                    (source-file-p file root)))
    (sb-cover:lcov-report (merge-pathnames "lcov.info" output))
    (format t "Coverage reports written to ~A~%" output)
    (uiop:quit 0)))
