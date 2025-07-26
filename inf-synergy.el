;;; inf-synergy.el -- Drive `synergy` shell from Emacs

;; Copyright (c) 2025, Richard Loveland

;; Author: Richard Loveland <r@rmloveland.com>

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; From https://jem.fandom.com/wiki/Synergy:
;;
;; > Synergy is a highly technologically advanced artificial
;; > intelligence.  She can understand what others say and still have
;; > her own opinions.

;; This code provides a `comint-mode' based interface to AI chatbots
;; (a.k.a., Synergy).  It is based on the built-in `shell-mode'. Right
;; now it is hardcoded to the `synergy` program in this directory,
;; which speaks to Anthropic's API, but it could probably be
;; generalized rather easily, as it is just providing a very generic
;; "command interpreter" interface that could have as its backend
;; almost anything that provides a prompt matching
;; `synergy-prompt-pattern'.  There is probably more work needed to
;; get this up to snuff (completion? syntax highlighting?), but it
;; works.  It even "works" on Windows (modulo bugs in the way the
;; prompt is displayed).

;; To use it, run `M-x run-synergy`.

;;; Code:

(require 'comint)
(require 'time-stamp)



;; Synergy group customization variables

(defgroup inf-synergy nil
  "Running Synergy from within an Emacs buffer."
  :group 'processes)

(defcustom synergy-file-name "synergy"
  "File name to use for the Synergy client."
  :type 'file
  :group 'inf-synergy)

(defcustom synergy-buffer "*synergy*"
  "The (probable) name of the current Synergy (tm) buffer."
  :type 'string
  :group 'inf-synergy)

(defcustom inferior-synergy-mode-hook '()
  "Hook for customizing `inferior-synergy-mode'."
  :type 'hook
  :group 'inf-synergy)

(defcustom synergy-prompt-pattern "^USER > "
  "Regular expression that matches the Synergy shell prompt."
  :type 'regexp
  :group 'inf-synergy)

(defcustom synergy-history-file-name (expand-file-name "~/Dropbox/Code/personal/config/synergy-history")
  "History file for previous inputs to Synergy."
  :type 'file
  :group 'inf-synergy)

(defcustom synergy-push-command ",push %s"
  "Template for issuing commands to push a file onto Synergy's file context."
  :type 'string
  :group 'inf-synergy)

(defcustom synergy-cd-command ",cd %s"
  "Template for issuing commands to change Synergy's current working directory."
  :type 'string
  :group 'inf-synergy)



;; Inferior Synergy mode definition

(defvar inferior-synergy-mode-map
  (let ((map (nconc (make-sparse-keymap) comint-mode-map)))
    (define-key map (kbd "C-c C-f") 'synergy-forward-command)
    (define-key map (kbd "C-c C-b") 'synergy-backward-command)
    map))

(defvar synergy-font-lock-keywords
  '(("[ \t]\\([+-][^ \t\n]+\\)" 1 font-lock-comment-face)
    ("^[^ \t\n]+:.*" . font-lock-string-face)
    ("^\\[[1-9][0-9]*\\]" . font-lock-string-face))
  "Additional expressions to highlight in synergy mode.")

(define-derived-mode inferior-synergy-mode comint-mode "synergy"
  "Major mode for interacting with an inferior synergy shell."
  (setq comint-prompt-regexp synergy-prompt-pattern)
  (setq comint-use-prompt-regexp t)
  (setq comint-process-echoes t)
  (setq comint-scroll-to-bottom-on-output t)
  (set (make-local-variable 'paragraph-separate) "\\'")
  (set (make-local-variable 'paragraph-start) comint-prompt-regexp)
  (set (make-local-variable 'font-lock-defaults) '(synergy-font-lock-keywords t))
  (when (ring-empty-p comint-input-ring)
    ;; Arrange to write out the input ring on exit
    (set-process-sentinel (get-buffer-process (current-buffer))
                          #'synergy-write-history-on-exit)))



;; Custom comint input sender function that allows for multiline input

(define-key inferior-synergy-mode-map (kbd "RET") #'comint-send-input)
(define-key inferior-synergy-mode-map (kbd "<S-return>") #'newline-and-indent)

(defun synergy-customize-input-sender ()
  "Set up Comint mode input sender for the Synergy REPL."
  (setq-local comint-input-sender #'synergy-input-sender))

(add-hook 'inferior-synergy-mode-hook #'synergy-customize-input-sender)

(defun synergy-input-sender (the-proc the-string)
  "Send the entire current input string - from the prompt to (point)."
  (let ((the-string* (replace-regexp-in-string "\n" " " the-string)))
    ;; Add to input history
    (ring-insert comint-input-ring the-string*)
    (comint-send-string the-proc (concat the-string* "\n"))))

;; Turn on warn highlighting for lines longer than a predefined
;; limit. We have determined via experimentation that comint mode
;; buffers completely hang and print nothing but '^G' characters if
;; you enter a line longer than 1005 characters. This code is
;; gratefully snarfed from https://stackoverflow.com/a/6344617

(defun font-lock-width-keyword (width)
  "Return a font-lock style keyword for a string beyond width WIDTH
   that uses 'font-lock-warning-face'."
  `((,(format "^%s\\(.+\\)" (make-string width ?.))
     (1 font-lock-warning-face t))))

(font-lock-add-keywords 'inferior-synergy-mode (font-lock-width-keyword 999))



;; Process management

(defun synergy-interactively-start-process (&optional _cmd)
  "Start an inferior Synergy process.  Return the process started.
Since this command is run implicitly, always ask the user for the
command to run."
  (save-window-excursion
    (run-synergy (read-string "Run Synergy: " synergy-file-name))))

(defun synergy-proc ()
  "Return the current Synergy process, starting one if necessary.
See variable `synergy-buffer'."
  (unless (and synergy-buffer
               (get-buffer synergy-buffer)
               (comint-check-proc synergy-buffer))
    (synergy-interactively-start-process))
  (or (synergy-get-process)
      (error "No current process.  See variable `synergy-buffer'")))

(defun synergy-get-process ()
  "Return the current Synergy process or nil if none is running."
  (get-buffer-process (if (eq major-mode 'inferior-synergy-mode)
                          (current-buffer)
                        synergy-buffer)))

(defun synergy-write-history-on-exit (process event)
  "Called when the Synergy process is stopped.

Writes the input history to a history file
`comint-input-ring-file-name' using `comint-write-input-ring'
and inserts a short message in the Synergy buffer.

This function is a sentinel watching the 'synergy' interpreter process.
Sentinels will always get the two parameters PROCESS and EVENT."
  ;; Write history.
  (setq comint-input-ring-file-name synergy-history-file-name)
  (comint-write-input-ring)
  (let ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (insert (format "\nProcess %s %s\n" process event))))))



;; Switch to SYNERGY from anywhere else

(defun synergy-create-or-switch ()
  "Switch to the inferior Synergy buffer so we can talk to her.
If `synergy-buffer' does not exist or is not alive, create it."
  (interactive)
  (if (and synergy-buffer (get-buffer synergy-buffer) (comint-check-proc synergy-buffer))
      (switch-to-buffer-other-window synergy-buffer)
    (progn
      (run-synergy)
      (switch-to-buffer synergy-buffer))))

(define-key global-map (kbd "C-x C-a y") #'synergy-create-or-switch)



;; Push current region, buffer, etc. onto the Synergy REPL's file
;; context stack

(defun synergy-push-region (start end)
  "Make a temporary file with contents of START and END.
Then, push the temp file onto Synergy's file context stack."
  (interactive "r")
  (let* ((the-temp-dir (getenv "TMPDIR"))
         (the-file (concat the-temp-dir
                           (replace-regexp-in-string "\\( \\|:\\)" "-" (time-stamp-string))
                           "-"
                           (replace-regexp-in-string "\\(\*\\| \\|:\\|\<\\|\>\\|\\/\\)" "-" (buffer-name (current-buffer)))
                           ".txt"))
         (the-string (buffer-substring-no-properties start end)))
    (with-temp-file the-file
      (insert the-string))
    (sleep-for 1)
    (if (file-exists-p the-file)
        (progn (message "Pushing file '%s' onto synergy file context stack." the-file)
               (comint-send-string (synergy-proc)
                                   (format synergy-push-command the-file))
               (comint-send-string (synergy-proc) "\n"))
      (error "File does not exist: %s" the-file))))

(defun synergy-push-buffer ()
  "Push the current buffer onto Synergy's file context stack.
If there's no file associated with the buffer, add a temp file to
Synergy's file context using `synergy-push-region'."
  (interactive)
  (let ((the-buffer-file (buffer-file-name (current-buffer))))
    (if the-buffer-file
        (progn (message "Pushing file '%s' onto synergy file context stack." the-buffer-file)
               (comint-send-string (synergy-proc) (format synergy-push-command the-buffer-file))
               (comint-send-string (synergy-proc) "\n"))
      (synergy-push-region (point-min) (point-max)))))

(defun synergy-push-dired-marked-files ()
  "Push all marked files in the current Dired buffer to Synergy's file context.
If no files are marked, push the file at point."
  (interactive)
  (unless (or (eq major-mode 'dired-mode)
              (eq major-mode 'locate-mode))
    (user-error "Not in a Dired buffer"))
  (let* ((marked-files (dired-get-marked-files))
         (files-to-push (or marked-files
                            (list (dired-get-filename nil t)))))
    (if (null files-to-push)
        (user-error "No files to push")
      (dolist (file files-to-push)
        (unless (file-exists-p file)
          (user-error "File does not exist: %s" file))

        (message "Pushing file '%s' onto Synergy file context stack." file)
        (comint-send-string (synergy-proc)
                            (format synergy-push-command file))
        (comint-send-string (synergy-proc) "\n")
        (sleep-for 3))

      (message "Pushed %d file(s) to Synergy context" (length files-to-push)))))

(defun synergy-push ()
  "Push the current region or buffer onto Synergy's file context stack.
If a region is active, push the region; otherwise, push the entire buffer."
  (interactive)
  (if (or (eq major-mode 'dired-mode)
          (eq major-mode 'locate-mode))
      (call-interactively #'synergy-push-dired-marked-files)
    (if (use-region-p)
        (call-interactively #'synergy-push-region)
      (call-interactively #'synergy-push-buffer))))

(define-key global-map (kbd "C-x C-a p") #'synergy-push)



;; Copy code from Markdown blocks

(defun synergy-copy-code-block ()
  "Copy contents of current Markdown code block.
Assumes Github flavored markdown, e.g., ```perl\n...\n```."
  (interactive)
  (let ((start)
        (end))
    (save-excursion
      ;; NB. Code blocks often start at beginning of line, but may
      ;; sometimes be indented as part of a larger formatted list of
      ;; topics under discussion.
      (re-search-backward "\\(^\\| +\\)```\\([a-zA-Z]+\\)?
")
      (forward-line 1)
      (setq start (point))
      (re-search-forward "\\(^\\| +\\)```
")
      (forward-line -1)
      (setq end (point))
      (copy-region-as-kill start end))))

(define-key inferior-synergy-mode-map (kbd "C-x M-w") #'synergy-copy-code-block)



;; REPL Niceties

(defun synergy-complete-or-indent ()
  "In Inferior Synergy Mode, toggle complete the filename (if it is one).
Otherwise, indent as normal."
  (interactive)
  (if (thing-at-point 'filename)
      (comint-dynamic-complete-filename)
    (indent-for-tab-command)))

(define-key inferior-synergy-mode-map (kbd "TAB") #'synergy-complete-or-indent)

;; Helper function to set buffer-local default-directory
(defun synergy--set-buffer-pwd (buffer-name new-pwd)
  "Set buffer-local `default-directory` for BUFFER-NAME to NEW-PWD.
Internal helper. Ensures NEW-PWD is an absolute, valid directory path."
  (let ((target-buffer (get-buffer buffer-name))
        (absolute-pwd (expand-file-name new-pwd)))
    (unless (file-directory-p absolute-pwd)
      (error "Path is not a valid directory: %s" absolute-pwd))
    (if target-buffer
        (with-current-buffer target-buffer
          (setq-local default-directory absolute-pwd) ; Use setq-local
          ;; Optional: Add hooks or calls if other modes need notification
          (message "Buffer '%s' default-directory set to %s" buffer-name absolute-pwd))
      (warn "Buffer '%s' not found for setting default-directory." buffer-name))))

;; Revised interactive command
(defun synergy-cd (&optional dir)
  "Set Synergy REPL's CWD and update `*synergy*` buffer's `default-directory`.
If DIR is nil or called interactively, uses the current buffer's
`default-directory`. Otherwise, uses the provided DIR string."
  (interactive (list default-directory)) ; Use current buffer's dir interactively
  (let* ((target-dir (or dir default-directory))
         (absolute-dir (expand-file-name target-dir))
         (synergy-buffer-name "*synergy*") ; Consistent buffer name
         (proc (synergy-proc))) ; Assumes synergy-proc returns the process
    (unless proc
      (error "Synergy process not running or not found by synergy-proc"))
    (unless (file-directory-p absolute-dir)
      (error "Target path is not a valid directory: %s" absolute-dir))

    ;; 1. Send the command to the Synergy REPL process
    (message "Setting '%s' as Synergy's current working directory" absolute-dir)
    (comint-send-string proc (format synergy-cd-command absolute-dir))
    (comint-send-string proc "\n")

    ;; 2. Update the *synergy* buffer's default-directory to match
    (synergy--set-buffer-pwd synergy-buffer-name absolute-dir)))

(define-key global-map (kbd "C-x C-a c") #'synergy-cd)



;; Starting the actual chat REPL

;;;###autoload
(defun run-synergy (&optional buffer)
  "Run an inferior Synergy shell, with I/O through BUFFER.
\(Buffer defaults to '*synergy*').
Interactively, a prefix arg means to prompt for BUFFER.
If `default-directory' is a remote file name, it is also prompted
to change if called with a prefix arg.

If BUFFER exists but Synergy process is not running, open new Synergy shell.
If BUFFER exists and Synergy process is running, just switch to BUFFER.

Program used comes from variable `synergy-file-name',
or (if that is nil) from `synergy-file-name'.

The buffer is put in `inferior-synergy-mode'.

See also the variable `synergy-prompt-pattern'.

\(Type \\[describe-mode] in the Synergy buffer for a list of commands.)"
  (interactive
   (list
    (and current-prefix-arg
         (prog1
             (read-buffer "Synergy buffer: "
                          ;; If the current buffer is an inactive
                          ;; Synergy buffer, use it as the default.
                          (if (and (eq major-mode 'inferior-synergy-mode)
                                   (null (get-buffer-process (current-buffer))))
                              (buffer-name)
                            (generate-new-buffer-name "*synergy*")))
           (if (file-remote-p default-directory)
               ;; It must be possible to declare a local default-directory.
               ;; FIXME: This can't be right: it changes the default-directory
               ;; of the current-buffer rather than of the *synergy* buffer.
               (setq default-directory
                     (expand-file-name
                      (read-directory-name
                       "Default directory: " default-directory default-directory
                       t nil))))))))
  (setq buffer (if (or buffer (not (derived-mode-p 'inferior-synergy-mode))
                       (comint-check-proc (current-buffer)))
                   (get-buffer-create (or buffer "*synergy*"))
                 ;; If the current buffer is a dead Synergy buffer, use it.
                 (current-buffer)))

  ;; The buffer's window must be correctly set when we call comint (so
  ;; that comint sets the COLUMNS env var properly).
  (pop-to-buffer buffer)
  (unless (comint-check-proc buffer)
    (let* ((prog synergy-file-name)
           (name (file-name-nondirectory prog))
           (process-environment
            ;; We must munge the process environment on Windows to
            ;; avoid using the cmdproxy.exe that ships with Emacs,
            ;; since it breaks the `synergy` command.
            (if (eq system-type 'windows-nt)
                (mapcar (lambda (x)
                          (if (string-match-p "^SHELL=C:" x)
                              "SHELL=C:\\WINDOWS\\system32\\cmd.exe"
                            x))
                        process-environment)
              process-environment)))
      (make-comint-in-buffer "synergy" buffer prog)
      (inferior-synergy-mode)))
  buffer)

(provide 'inf-synergy)

;;; inf-synergy.el ends here
