(progn
  #.(progn (require :asdf) (require :sb-cover) nil)

  (defun script-directory ()
    (make-pathname :name nil
                   :type nil
                   :defaults (or *load-truename*
                                 *compile-file-truename*
                                 (error "Unable to determine the script location"))))

  (defun source-root ()
    "This project's own root, honoring CL_CONCURRENT_KIT_SOURCE_ROOT when set.
Necessary because this script itself may run from a location that is not the
project root -- e.g. copied into the Nix store as its own derivation by
flake.nix's coverage check/app, which passes the real checkout separately
rather than relying on this script's own store path."
    (uiop:ensure-directory-pathname
     (let ((override (uiop:getenv "CL_CONCURRENT_KIT_SOURCE_ROOT")))
       (if override
           (uiop:parse-native-namestring override)
           (script-directory)))))

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
    "True for FILE under ROOT's src/ directory -- this project's own sources,
never cl-weave's or the test suite's -- so coverage instrumentation on a
dependency or on the tests themselves never dilutes this project's own
number."
    (uiop:subpathp (uiop:parse-native-namestring file) (merge-pathnames "src/" root)))

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

  (let* ((root (source-root))
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
