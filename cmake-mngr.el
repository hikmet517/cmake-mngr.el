;;; cmake-mngr.el --- Manage cmake projects -*- lexical-binding: t -*-

;; Author: Hikmet Altıntaş (hikmet1517@gmail.com)
;; Keywords: tools, extensions
;; URL: "https://github.com/hikmet517/cmake-mngr.el"

;;; Commentary:
;; TODO: Write here


;; TODO:
;; suggestions using cmake vars' types
;; test in windows, test without selectrum/helm etc.
;; use `compile' interface

;;; Code:


;;;; Libraries

(require 'seq)
(require 'subr-x)

;;;; Variables

(defvar cmake-mngr-projects (list)
  "Currently opened cmake projects.")

;;;; Constants

(defconst cmake-mngr-cache-buffer-name "*cmake-mngr-cache-variables <%s>*"
  "Buffer name for cache variables.")

(defconst cmake-mngr-configure-buffer-name "*cmake-mngr-configure <%s>*"
  "Buffer name for the output of configure command.")

(defconst cmake-mngr-build-buffer-name "*cmake-mngr-build <%s>*"
  "Buffer name for the output of build command.")

;;;; User options

(defgroup cmake-mngr nil
  "Cmake-mngr customization."
  :group 'cmake-mngr
  :prefix "cmake-mngr-"
  :link '(url-link "https://github.com/hikmet517/cmake-mngr.el"))

(defcustom cmake-mngr-build-dir-search-list '("build" "bin" "out")
  "List of directories to search for cmake build directory.
Should be non-nil."
  :type '(repeat directory)
  :group 'cmake-mngr)

(defcustom cmake-mngr-global-configure-args '("-DCMAKE_EXPORT_COMPILE_COMMANDS=1")
  "Argument to pass during configuration."
  :type '(repeat string)
  :group 'cmake-mngr)

(defcustom cmake-mngr-global-build-args '()
  "Argument to pass during build."
  :type '(repeat string)
  :group 'cmake-mngr)


;;;; Functions

(defun cmake-mngr--parse-cache-file (filepath)
  "Parse given CMakeCache.txt file in FILEPATH as '(key type value)."
  (when (file-readable-p filepath)
    (let ((content (with-temp-buffer
                     (insert-file-contents filepath)
                     (split-string (buffer-string) "\n" t)))
          (res '()))
      (dolist (line content)
        (when (and (not (string-prefix-p "#" line))
                   (not (string-prefix-p "//" line))
                   (seq-contains-p line ?=))
          (let* ((kv (split-string line "=" t))
                 (kt (split-string (car kv) ":" t)))
            (push (list (car kt)
                        (cadr kt)
                        (cadr kv))
                  res))))
      (reverse res))))


(defun cmake-mngr--get-available-generators ()
  "Find available generators by parsing 'cmake --help'."
  (let ((str (shell-command-to-string "cmake --help")))
    (when str
      (let* ((ss (replace-regexp-in-string "\n[[:space:]]*=" "=" str))
             (found (string-match "The following generators are available" ss))
             (slist (when found (cdr (split-string (substring ss found) "\n" t))))
             (filt (when slist (seq-filter (lambda (s) (seq-contains-p s ?=)) slist)))
             (gens (when filt (mapcar (lambda (s) (string-trim
                                                   (car (split-string s "=" t))))
                                      filt))))
        (mapcar (lambda (s) (string-trim-left s "* ")) gens)))))


(defun cmake-mngr--get-available-targets ()
  "Find available targets by parsing 'cmake --build build-dir --help'."
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((build-dir (gethash "Build Dir" project))
           (targets '())
           (cmd (concat "cmake --build " (shell-quote-argument build-dir) " --target help"))
           (str (shell-command-to-string cmd)))
      (message "%s" (length (split-string str "\n" t)))
      (dolist (line (split-string str "\n" t))
        (when (string-prefix-p "... " line)
          (setq targets (cons (car
                               (split-string
                                (string-trim-left line (regexp-quote "... "))))
                              targets))))
      (reverse targets))))


(defun cmake-mngr--find-project-dir (filepath)
  "Find cmake project root for buffer with the path FILEPATH."
  (let ((dirpath filepath)
        (dir-found nil)
        (is-top nil))
    (while (and dirpath (not is-top))
      (setq dirpath (file-name-directory (string-trim-right dirpath "/")))
      (if (file-exists-p (expand-file-name "CMakeLists.txt" dirpath))
          (setq dir-found dirpath)
        (when dir-found
          (setq is-top t))))
    dir-found))


(defun cmake-mngr--get-sub-dirs (dir)
  "Get full paths of subdirectories of given directory DIR."
  (let* ((subs (directory-files dir))
         (subs-filt (seq-filter (lambda (s)
                                  (and (not (equal s "."))
                                       (not (equal s ".."))
                                       (file-directory-p (expand-file-name s dir))))
                                subs)))
    (mapcar (lambda (s) (file-name-as-directory (expand-file-name s dir))) subs-filt)))


(defun cmake-mngr--find-project-build-dir (project-dir)
  "Get cmake project build directory by searching the path of PROJECT-DIR.

First, search for sub-directories that contain 'CMakeCache.txt', If there is
none, look for if any of the directories listed in
`cmake-mngr-build-dir-search-list' exists.  If nothing found return nil."
  (let ((build-dir nil)
        (sub-dirs (cmake-mngr--get-sub-dirs project-dir)))
    ;; search for sub directories that contain cache file
    (setq build-dir (seq-find (lambda (s)
                                (file-exists-p (expand-file-name "CMakeCache.txt" s)))
                              sub-dirs))
    ;; search for cmake-mngr-build-dir-search-list
    (unless build-dir
      (setq build-dir (seq-find #'file-exists-p
                                (mapcar (lambda (s)
                                          (file-name-as-directory
                                           (expand-file-name s project-dir)))
                                        cmake-mngr-build-dir-search-list))))
    build-dir))


(defun cmake-mngr--get-project ()
  "Get project's data structure for current buffer.

If it already found before (added to `cmake-mngr-projects') returns
this.  Otherwise, searches directory structure of current buffer.  If
found, data is added to `cmake-mngr-projects' and returned, otherwise returns nil."
  (let* ((filepath (buffer-file-name))
         (project-data (when filepath
                         (cdr (assoc
                               (file-name-directory filepath)
                               cmake-mngr-projects
                               'string-prefix-p)))))
    (when (and (not project-data) filepath)
      (let ((project-dir (cmake-mngr--find-project-dir filepath)))
        (when project-dir
          (let* ((root-name (file-name-base
                             (directory-file-name project-dir)))
                 (build-dir (cmake-mngr--find-project-build-dir project-dir)))
            (setq project-data (make-hash-table :test 'equal))
            (puthash "Root Name" root-name project-data)
            (puthash "Project Dir" project-dir project-data)
            (puthash "Generator" nil project-data)
            (puthash "Build Dir" build-dir project-data)
            (puthash "Target" nil project-data)
            (puthash "Custom Vars" (make-hash-table :test 'equal) project-data)
            (push (cons project-dir project-data) cmake-mngr-projects)))))
    project-data))


;;;###autoload
(defun cmake-mngr-create-symlink-to-compile-commands ()
  "Create a symlink that points to 'compile_commands.json' (needed for lsp to work)."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((project-dir (gethash "Project Dir" project))
           (build-dir (gethash "Build Dir" project))
           (json-file (when build-dir
                        (expand-file-name "compile_commands.json" build-dir))))
      (if (and build-dir
               json-file
               (file-exists-p build-dir)
               (file-exists-p json-file))
          (start-process "create-symlink" nil "ln" "-s" json-file "-t" project-dir)
        (error "Cannot found build directory or 'compile_commands.json'")))))


;;;###autoload
(defun cmake-mngr-show-cache-variables ()
  "Show cmake cache variable in a buffer."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((build-dir (gethash "Build Dir" project))
           (buf-name (format cmake-mngr-cache-buffer-name (gethash "Root Name" project)))
           (cache-file (when build-dir (expand-file-name "CMakeCache.txt" build-dir)))
           (cache-vars (when cache-file (cmake-mngr--parse-cache-file cache-file))))
      (when cache-vars
        (let ((buf (get-buffer-create buf-name)))
          (with-current-buffer buf
            (when buffer-read-only
              (setq buffer-read-only nil)
              (erase-buffer))
            (dolist (d cache-vars)
              (insert (format "%s:%s=%s\n"
                              (or (elt d 0) "")
                              (or (elt d 1) "")
                              (or (elt d 2) ""))))
            (text-mode)
            (setq buffer-read-only t))
          (display-buffer buf))))))


;;;###autoload
(defun cmake-mngr-configure ()
  "Configure current project."
  (interactive)
  (let* ((project (cmake-mngr--get-project))
         (build-dir (when project (gethash "Build Dir" project)))
         (buf-name (format cmake-mngr-configure-buffer-name (gethash "Root Name" project))))
    (unless project
      (error "Cannot find cmake project for this file"))
    (unless build-dir
      (setq build-dir (cmake-mngr-set-build-directory)))
    (when (and build-dir (not (file-exists-p build-dir)))
      (make-directory build-dir))
    (when (and build-dir (file-exists-p build-dir))
      (let* ((args (append (list "-S" (gethash "Project Dir" project)
                                 "-B" (gethash "Build Dir" project))
                           (let ((gen (gethash "Generator" project)))
                             (when gen (list "-G" gen)))))
             (custom-args (let ((c (list)))
                            (maphash (lambda (k v) (push (format "-D%s=%s" k v) c))
                                     (gethash "Custom Vars" project))
                            c))
             (all-args (append args cmake-mngr-global-configure-args custom-args))
             (cmd (concat "cmake " (combine-and-quote-strings all-args))))
        (message "Cmake configure command: %s" cmd)
        (async-shell-command cmd buf-name)))))


;;;###autoload
(defun cmake-mngr-build ()
  "Build current project."
  (interactive)
  (let* ((project (cmake-mngr--get-project))
         (build-dir (when project (gethash "Build Dir" project)))
         (cache-file (when build-dir (expand-file-name "CMakeCache.txt" build-dir)))
         (buf-name (format cmake-mngr-build-buffer-name (gethash "Root Name" project))))
    (unless project
      (error "Cannot find cmake project for this file"))
    (unless (and build-dir
                 (file-exists-p build-dir)
                 (file-exists-p cache-file))
      (when (yes-or-no-p "Need to configure first, configure now? ")
        (cmake-mngr-configure)))
    (when (and build-dir
               (file-exists-p build-dir)
               (file-exists-p cache-file))
      (let* ((args (append (list "--build" build-dir)
                           (let ((tgt (gethash "Target" project)))
                             (when tgt (list "--target" tgt)))
                           cmake-mngr-global-build-args))
             (cmd (concat "cmake " (combine-and-quote-strings args)))
             (compilation-buffer-name-function))
        (message "Cmake build command: %s" cmd)
        (async-shell-command cmd buf-name)))))


;;;###autoload
(defun cmake-mngr-select-build-type ()
  "Get cmake build type from user."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let ((type (completing-read "Select cmake build type: "
                                 '("Debug" "Release" "MinSizeRel" "RelWithDebInfo")
                                 nil
                                 t))
          (custom (gethash "Custom Vars" project)))
      (when (and custom type)
        (puthash "CMAKE_BUILD_TYPE" type custom)))))


;;;###autoload
(defun cmake-mngr-set-generator ()
  "Set generator for current project."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((generators (cmake-mngr--get-available-generators))
           (choice (completing-read "Select a generator: "
                                    generators)))
      (when (and choice (not (string-equal choice "")))
        (puthash "Generator" choice project)))))


;;;###autoload
(defun cmake-mngr-set-target ()
  "Set target for current project."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((targets (cmake-mngr--get-available-targets))
           (choice (completing-read "Select a target: "
                                    targets)))
      (when (and choice (not (string-equal choice "")))
        (puthash "Target" choice project)))))


;;;###autoload
(defun cmake-mngr-set-build-directory ()
  "Set cmake build directory."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((proj-dir (gethash "Project Dir" project))
           (build-dir (gethash "Build Dir" project))
           (build-dir-name (when build-dir
                             (directory-file-name (string-trim-left build-dir proj-dir))))
           (choice (completing-read
                    (if build-dir (format "Select cmake build directory (default %s): "
                                          build-dir-name)
                      "Select cmake build directory: ")
                    cmake-mngr-build-dir-search-list ; COLLECTION
                    nil nil nil nil ; PREDICATE REQUIRE-MATCH INITIAL-INPUT HIST
                    build-dir-name)))
      (when (and choice (not (equal choice "")))
        (setq build-dir (file-name-as-directory (expand-file-name choice proj-dir)))
        (puthash "Build Dir" build-dir project)
        build-dir))))


;;;###autoload
(defun cmake-mngr-set-variable ()
  "Set a cmake variable as KEY=VALUE.

These variables will be passed to cmake during configuration as -DKEY=VALUE."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let* ((build-dir (gethash "Build Dir" project))
           (cache-file (when build-dir (expand-file-name "CMakeCache.txt" build-dir)))
           (cache-vars (when cache-file (cmake-mngr--parse-cache-file cache-file)))
           (key (completing-read "Variable: "
                                 (when cache-vars (mapcar #'car cache-vars))))
           (dflt (when (and cache-vars key) (car (last (assoc key cache-vars)))))
           (val (completing-read "Value: "
                                 (when dflt (list dflt)))))
      (let ((custom-vars (gethash "Custom Vars" project)))
        (when (and custom-vars key val)
          (puthash key val custom-vars)
          (message "Need to reconfigure now!"))))))


;;;###autoload
(defun cmake-mngr-clear-build-directory ()
  "Remove current build directory and all the files inside."
  (interactive)
  (let ((project (cmake-mngr--get-project)))
    (unless project
      (error "Cannot find cmake project for this file"))
    (let ((build-dir (gethash "Build Dir" project)))
      (when (and build-dir (file-exists-p build-dir))
        (delete-directory build-dir t)))))


;;;###autoload
(defun cmake-mngr-reset ()
  "Reset internal data."
  (interactive)
  (setq cmake-mngr-projects '()))


(provide 'cmake-mngr)
;;; cmake-mngr.el ends here
