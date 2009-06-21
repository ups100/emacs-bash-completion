
(require 'comint)

;;if [[ ( -z "$INSIDE_EMACS" || "$EMACS_BASH_COMPLETE" = "t" ) && -f /etc/bash_c;;ompletion ]]; then
;;  echo -n "BASH completion..."
;;  . /etc/bash_completion
;;  echo "ON"
;;fi

(defvar bash-completion-prog "bash"
  "Command-line to execute bash")

(defvar bash-completion-process-timeout 2.5)
(defvar bash-completion-initial-timeout 30
  "Timeout value to apply when talking to bash for the first time.
The first thing bash is supposed to do is process /etc/bash_complete,
which typically takes a long time.")

(defvar bash-completion-process nil
  "Bash process object")
(defvar bash-completion-alist nil
  "Maps from command name to the 'complete' arguments.

For example if the following completion is defined in bash:
  complete -F _cdargs_aliases cdb
the following entry is added to `bash-completion-alist':
 (\"cdb\" . (\"-F\" \"_cdargs\"))

See `bash-completion-add-to-alist'.
")

(defconst bash-completion-wordbreaks-str "\"'@><=;|&(:")
(defconst bash-completion-wordbreaks (append bash-completion-wordbreaks-str nil))

(defun bash-completion-setup ()
  (add-hook 'shell-dynamic-complete-functions
	    'bash-completion-dynamic-complete)
  (add-hook 'shell-command-complete-functions
	    'bash-completion-dynamic-complete))

;;;###autoload
(defun bash-completion-dynamic-complete ()
  "Bash completion function for `comint-complete-dynamic-functions'.

Call bash to do the completion."
  (when (not (window-minibuffer-p))
    (message "Bash completion..."))
  (let* ( (pos (point))
	  (start (bash-completion-line-beginning-position))
	  (end (line-end-position))
	  (line (buffer-substring-no-properties start end))
	  (wordsplit)
	  (cword)
	  (words)
	  (stub)
	  ;; Override configuration for comint-dynamic-simple-complete.
	  ;; Bash adds a space suffix automatically.
	  (comint-completion-addsuffix nil) )
    (save-excursion
      (setq wordsplit (bash-completion-split start end pos))
      (setq cword (car wordsplit))
      (setq words (cdr wordsplit))
      (setq stub (nth cword words)))
    (let ((completions (bash-completion-comm line (- pos start) words cword)))
      (if completions
	  (comint-dynamic-simple-complete stub completions)
	;; try default completion after a wordbreak
	(let ((after-wordbreak (bash-completion-after-last-wordbreak stub)))
	  (when (not (equal stub after-wordbreak))
	    (bash-completion-send (concat (bash-completion-cd-command-prefix) "compgen -o default -- " after-wordbreak))
	    (comint-dynamic-simple-complete after-wordbreak (bash-completion-extract after-wordbreak))))))))

(defun bash-completion-line-beginning-position (&optional start)
  (save-excursion
    (let ((start (or start (comint-line-beginning-position)))
	  (end (line-end-position)))
      (goto-char end)
      (if (search-backward-regexp "\\(;\\|\\(&&\\)\\|\\(||\\)\\)[ \t\n]" start t)
	  (match-end 0)
	start))))

(defun bash-completion-join (words)
  "Join WORDS into a shell line, escaped all words with single quotes"
  (if words
      (mapconcat
       'bash-completion-quote
       words " ")
    ""))

(defun bash-completion-quote (word)
  (if (string-match "^[a-zA-Z0-9_./-]*$" word)
      word
    (concat "'"
	    (replace-regexp-in-string "'" "'\\''" word :literal t)
	    "'")))

(defun bash-completion-escape (word)
  (if (string-match "^['\"]" word)
      word
    (replace-regexp-in-string "\\([ '\"]\\)" "\\\\\\1" word)))

(defun bash-completion-split (start end pos)
  "Split LINE like bash would do, keep track of current word at POS.

Return a list containing the words and the number of the word
at POS, the current word: ( (word1 word2 ...) . wordnum )"
  (bash-completion-split-postprocess
   (bash-completion-split-raw start end) start pos))

(defun bash-completion-split-strings (accum)
  (mapcar 'bash-completion-split-raw-get-str accum))

(defun bash-completion-split-postprocess (accum start pos)
  (if (null pos)
      (cons nil (bash-completion-split-strings accum))
    ;; find position
    (let ((index 0) (strings nil) (current nil) (accum-rest accum) (cword nil))
      (while accum-rest
	(setq current (car accum-rest))
	(setq accum-rest (cdr accum-rest))
	(unless cword
	  (let ((range (bash-completion-split-raw-get-range current)))
	    (cond
	     ((and (>= pos (car range))
		   (<= pos (cdr range)))
	      (setq cword index))
	     ((< pos (car range))
	      (setq cword index)
	      (push "" strings)))))
	(push (bash-completion-split-raw-get-str current) strings)
	(setq index (1+ index)))
      (unless cword
	(setq cword index)
	(push "" strings))
      (cons cword (nreverse strings)))))

(defsubst bash-completion-split-raw-get-range (current)
  (cons (cdr (assq 'start current)) (cdr (assq 'end current))))

(defsubst bash-completion-split-raw-set-end (current)
  (setcdr (assq 'end current) (point)))

(defsubst bash-completion-split-raw-append-str (current str)
  (let* ((str-cons (assq 'str current)) (straccum (cdr str-cons)))
    (setcdr str-cons (concat straccum str))))

(defsubst bash-completion-split-raw-get-str (current)
  (cdr (assq 'str current)))

(defun bash-completion-split-raw (start end)
  (save-excursion
    (goto-char start)
    (nreverse (bash-completion-split-raw-new-element end nil))))

(defun bash-completion-split-raw-new-element (end accum)
  (skip-chars-forward " \t\n\r" end)
  (if (< (point) end)
      (bash-completion-split-raw-0 end accum (list (cons 'str "")
						   (cons 'start (point))
						   (cons 'end nil)))
    accum))

(defun bash-completion-split-raw-0 (end accum current)
  (let ( (char-start (char-after))
	 (quote nil) )
    (when (and char-start (or (= char-start ?') (= char-start ?\")))
      (forward-char)
      (setq quote char-start))
    (bash-completion-split-raw-1 end quote accum current)))

(defun bash-completion-split-raw-1 (end quote accum current)
  (let ((local-start (point)))
    (when (= (skip-chars-forward "[;&|]" end) 0)
      (skip-chars-forward (bash-completion-nonsep quote) end))
    (bash-completion-split-raw-append-str
     current
     (buffer-substring-no-properties local-start (point))))
  (cond
   ;; an escaped char, skip, whatever it is
   ((and (char-before) (= ?\\ (char-before)))
    (forward-char)
    (let ((straccum (bash-completion-split-raw-get-str current)))
      (aset straccum (1- (length straccum)) (char-before)))
    (bash-completion-split-raw-1 end quote accum current))
   ;; opening quote
   ((and (not quote) (char-after) (or (= ?' (char-after)) (= ?\" (char-after))))
    (bash-completion-split-raw-0 end accum current))
   ;; closing quote
   ((and quote (char-after) (= quote (char-after)))
    (forward-char)
    (bash-completion-split-raw-0 end accum current))
   ;; space inside a quote
   ((and quote (char-after) (not (= quote (char-after))))
    (forward-char)
    (bash-completion-split-raw-append-str current (char-to-string (char-before)))
    (bash-completion-split-raw-1 end quote accum current))
   ;; word end
   (t
    (bash-completion-split-raw-set-end current)
    (push current accum)
    (bash-completion-split-raw-new-element end accum))))

(defconst bash-completion-nonsep-alist
  '((nil . "^ \t\n\r;&|'\"")
    (?' . "^ \t\n\r'")
    (?\" . "^ \t\n\r\"")))

(defun bash-completion-nonsep (quote)
  (cdr (assq quote bash-completion-nonsep-alist)))

(defun bash-completion-comm (line pos words cword)
  "Set LINE, POS, WORDS and CWORD, call bash completion, return the result.

This function starts a separate bash process if necessary, sets up the
completion environment (COMP_LINE, COMP_POINT, COMP_WORDS, COMP_CWORD) and
calls compgen.

The result is a list of candidates, which might be empty."
  (bash-completion-send (concat (bash-completion-generate-line line pos words cword) " 2>/dev/null"))
  (bash-completion-extract (nth cword words)))

(defun bash-completion-extract (stub)
  (let ((bash-completion-prefix stub))
    (mapcar 'bash-completion-fix
	    (with-current-buffer (bash-completion-buffer)
	      (split-string (buffer-string) "\n" t)))))

(defun bash-completion-fix (str &optional prefix)
  (let ((prefix (or prefix bash-completion-prefix))
	(suffix ""))
    (bash-completion-addsuffix
     (let* ((rebuilt)
	    (rest (cond
		   ((bash-completion-starts-with str prefix)
		    (substring str (length prefix)))
		   ;; bash expands the home directory automatically. This is confusing
		   ;; for comint-dynamic-simple-complete
		   ((and (bash-completion-starts-with prefix "~")
			 (bash-completion-starts-with str (expand-file-name "~")))
		    (substring (concat "~" (substring str (length (expand-file-name "~"))))
			       (length prefix)))
		   ;; bash sometimes just prints whatever needs to be expanded,
		   ;; for example: "export PATH=<complete>". Prepend the old
		   ;; prefix to avoid confusing comint-dynamic-simple-complete
		   ((bash-completion-starts-with
		     (setq rebuilt (concat (bash-completion-before-last-wordbreak prefix) str))
		     prefix)
		    (substring rebuilt (length prefix)))
		   (t str))))
       (when (bash-completion-ends-with rest " ")
	 (setq rest (substring rest 0 -1))
	 (setq suffix " "))
       (concat prefix (bash-completion-escape rest) suffix)))))

(defun bash-completion-before-last-wordbreak (str)
  (car (bash-completion-last-wordbreak-split str)))

(defun bash-completion-after-last-wordbreak (str)
  (cdr (bash-completion-last-wordbreak-split str)))

(defun bash-completion-last-wordbreak-split (str)
  (catch 'bash-completion-return
    (let ((end (- (length str) 1)))
      (while (> end 0)
	(when (memq (aref str end) bash-completion-wordbreaks)
	  (throw 'bash-completion-return (cons (substring str 0 (1+ end)) (substring str (1+ end)))))
	(setq end (1- end))))
      (cons "" str)))

(defun bash-completion-ends-with (str suffix)
  (let ((suffix-len (length suffix))
	(str-len (length str)))
    (or
     (= 0 suffix-len)
     (and
      (>= str-len suffix-len)
      (equal (substring str (- suffix-len)) suffix)))))

(defun bash-completion-starts-with (str prefix)
  (let ((prefix-len (length prefix))
	(str-len (length str)))
    (and
     (>= str-len prefix-len)
     (equal (substring str 0 prefix-len) prefix))))

(defun bash-completion-addsuffix (str)
  (if (and (null (string-match (concat "[" (regexp-quote bash-completion-wordbreaks-str) "/ ]$") str))
	   (file-accessible-directory-p (expand-file-name str default-directory)))
      (progn
	(concat str "/"))
    str))

(defun bash-completion-require-process ()
  (if (bash-completion-is-running)
      bash-completion-process
    ;; start process
    (let ((process))
      (unwind-protect
	  (progn
	    (setenv "EMACS_BASH_COMPLETE" "t")
	    (setq process
		  (start-process
		   "*bash-completion*"
		   (generate-new-buffer-name " bash-completion")
		   bash-completion-prog
		   "--noediting"))
	    (set-process-query-on-exit-flag process nil)
	    (let* ((shell-name (file-name-nondirectory bash-completion-prog))
		   (startfile1 (concat "~/.emacs_" shell-name ".sh"))
		   (startfile2 (concat "~/.emacs.d/init_" shell-name ".sh")))
	      (cond
	       ((file-exists-p startfile1)
		(process-send-string process (concat ". " startfile1 "\n")))
	       ((file-exists-p startfile2)
		(process-send-string process (concat ". " startfile2 "\n")))))
	    (bash-completion-send "PS1='\v'" process bash-completion-initial-timeout)
	    (bash-completion-send "function __bash_complete_wrapper { eval $__BASH_COMPLETE_WRAPPER; }" process)
	    ;; attempt to turn off unexpected status messages from bash
	    ;; if the current version of bash does not support these options,
	    ;; the command will fail silently and be ignored
	    (bash-completion-send "shopt -u mailwarn; shopt -u checkjobs" process)
	    ;; some bash completion functions use quote_readline to double-quote
	    ;; strings - which compgen understands but only in some environment.
	    ;; disable this dreadful business to get a saner way of handling
	    ;; spaces.
	    (bash-completion-send "function quote_readline { echo \"$1\"; }" process)
	    (bash-completion-send "complete -p" process)
	    (bash-completion-build-alist (process-buffer process))
	    (setq bash-completion-process process)
	    (setq process nil)
	    bash-completion-process)
	;; finally
	(progn
	  (setenv "EMACS_BASH_COMPLETE" nil)
	  (when process
	    (condition-case err
		(bash-completion-kill process)
	      (error nil))))))))

(defun bash-completion-cd-command-prefix ()
  (if default-directory
      (concat "cd 2>/dev/null " (bash-completion-quote (expand-file-name default-directory)) " ; ")
    ""))

(defun bash-completion-generate-line (line pos words cword)
  (concat
   (bash-completion-cd-command-prefix)
   (let* ( (command-name (file-name-nondirectory (car words)))
	   (compgen-args (cdr (assoc command-name bash-completion-alist))) )
     (if (not compgen-args)
	 ;; no custom completion. use default completion
	 (if (= cword 0)
	     ;; a command. let emacs expand executable, let bash expand builtins, aliases and functions
	     (concat (bash-completion-join (list "compgen" "-S" " " "-b" "-a" "-A" "function" (car words))))
	   ;; argument
	   (bash-completion-join (list "compgen" "-o" "default" (nth cword words))))
       ;; custom completion
       (let* ( (args (copy-tree compgen-args))
	       (function (or (member "-F" args) (member "-C" args))) )
	 (if function
	     (let ((function-name (car (cdr function))))
	       (setcar function "-F")
	       (setcar (cdr function) "__bash_complete_wrapper")
	       (format "__BASH_COMPLETE_WRAPPER=%s compgen %s -- %s"
		       (bash-completion-quote (format "COMP_LINE=%s; COMP_POINT=%s; COMP_CWORD=%s; COMP_WORDS=( %s ); %s \"${COMP_WORDS[@]}\""
						    (bash-completion-quote line) pos cword (bash-completion-join words)
						    (bash-completion-quote function-name)))
		       (bash-completion-join args)
		       (bash-completion-quote (nth cword words))))
	   (format "compgen %s -- %s" (bash-completion-join args) (nth cword words))))))))

(defun bash-completion-reset ()
  (interactive)
  (bash-completion-kill bash-completion-process)
  (setq bash-completion-process nil))

(defun bash-completion-kill (process)
  (when process
    (when (eq 'run (process-status process))
      (kill-process process))
    (let ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
	(kill-buffer buffer)))))

(defun bash-completion-buffer ()
  (process-buffer (bash-completion-require-process)))

(defun bash-completion-is-running ()
  (and bash-completion-process (eq 'run (process-status bash-completion-process))))

(defun bash-completion-send (commandline &optional process timeout)
  ;;(message commandline)
  (let ((process (or process (bash-completion-require-process)))
	(timeout (or timeout bash-completion-process-timeout)))
    (with-current-buffer (process-buffer process)
      (erase-buffer)
      (process-send-string process (concat commandline "\n"))
      (while (not (progn (goto-char 1) (search-forward "\v" nil t)))
	(unless (accept-process-output process timeout)
	  (error "Timeout while waiting for an answer from bash-completion process")))
      (goto-char (point-max))
      (delete-backward-char 1))))

(defun bash-completion-build-alist (buffer)
  "Build `bash-completion-alist' with the content of BUFFER.

BUFFER should contains the output of:
  complete -p

Return `bash-completion-alist'."
  (with-current-buffer buffer
    (save-excursion
      (setq bash-completion-alist nil)
      (goto-char (point-max))
      (while (= 0 (forward-line -1))
	(bash-completion-add-to-alist
	 (cdr (bash-completion-split (line-beginning-position) (line-end-position) nil))))))
  bash-completion-alist)

(defun bash-completion-add-to-alist (words)
  "Add split 'complete' line WORDS to `bash-completion-add-to-alist'.

This parses the complete command-line arguments as output by
  complete -p

This does not work on arbitrary 'complete' calls.

Lines that do not start with the word complete are skipped.

Return `bash-completion-alist'."
  (when (string= "complete" (car words))
    (let* ( (reverse-wordsrest (nreverse (cdr words)))
	    (command (car reverse-wordsrest))
	    (options (nreverse (cdr reverse-wordsrest))) )
      (when (and command options)
	(push (cons command options) bash-completion-alist))))
  bash-completion-alist)

(provide 'bash-completion)
