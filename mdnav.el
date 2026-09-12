;;; mdnav.el --- Live markdown preview via a local pandoc server  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Antonio Camas Maestre

;; Author: Antonio Camas Maestre <antoniocamas@hotmail.com>
;; Version: 0.3.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: docs, tools, processes
;; URL: https://github.com/antoniocamas/mdnav

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Markdown navigation: live browser preview of markdown files, powered
;; by pandoc and a small per-session HTTP server.
;;
;; Overview
;; --------
;;
;; `M-x mdnav' previews the markdown file in the current buffer in your
;; system browser.  The first preview of an Emacs session lazily starts
;; a local server (a child process that dies with Emacs) listening on
;; 127.0.0.1 with a random port and a random secret URL token.  The
;; browser URL mirrors the file system under your home directory:
;;
;;     http://127.0.0.1:PORT/TOKEN/Workspace/project/README.md
;;                          ->  $HOME/Workspace/project/README.md
;;
;; Because URLs mirror paths, markdown links between documents navigate
;; verbatim (clicking them asks the server to render the target file on
;; demand) and images load from the source tree directly -- no link
;; rewriting, no copying files around.  Files ending in .md (or
;; .markdown) are rendered by pandoc; every other file is served
;; statically.
;;
;; With `mdnav-auto-rerender' non-nil (the default), previewing also
;; arms a buffer-local hook so that every save re-signals the server:
;; open tabs reload by themselves -- no F5.  `M-x mdnav-stop' detaches
;; the current buffer from this; the server keeps running for other
;; buffers.
;;
;; `M-x mdnav-export-file' is the fallback path: it renders the buffer
;; to a single self-contained HTML file (CSS and images inlined) under
;; `mdnav-staging-root' and opens it over file://, exactly like a
;; classic pandoc export.  Use it to share one portable file, or when
;; you do not want the server.
;;
;; Security model
;; --------------
;;
;; The server binds to loopback only, rejects requests whose Host header
;; is not 127.0.0.1/localhost (DNS-rebinding defense), and requires the
;; per-session 128-bit token in every URL.  Within those rules the
;; token-bearing URL can read any file under your home directory, so
;; treat preview URLs as private: they expire when Emacs exits (no
;; state is persisted across sessions).  There are no directory
;; listings; unknown paths return 404.
;;
;; Dependencies (Debian/Ubuntu packages, no pip involved)
;; -------------------------------------------------------
;;
;;     sudo apt install pandoc python3
;;
;; The server script (mdnav-server.py) uses only the Python standard
;; library and is located next to this file.
;;
;; Automatic cleanup of staging files
;; ----------------------------------
;;
;; Preview/export files live under `mdnav-staging-root' (default
;; ~/tmp-markdown/), which must stay a non-hidden directory under your
;; home so snap-packaged browsers can read it.  The elisp side creates
;; everything on demand; the only external piece is a systemd *user*
;; tmpfiles rule that deletes stale content after 7 days.  One-time
;; setup on a new machine:
;;
;; 1. Create ~/.config/user-tmpfiles.d/emacs-markdown.conf containing:
;;
;;         # Creates the directory when missing and removes its contents
;;         # after 7 days.  Runs daily and again at login.
;;         d %h/tmp-markdown 0700 USER GROUP 7d -
;;
;;    (replace USER GROUP with your user and group names)
;;
;; 2. Enable the daily cleanup timer:
;;
;;         systemctl --user enable --now systemd-tmpfiles-clean.timer
;;
;; 3. Apply the rule once (creates the directory):
;;
;;         systemd-tmpfiles --user --create
;;
;; Do not "simplify" the rule to `R %h/tmp-markdown - - - 7d` or expect
;; `D` to empty the directory: on systemd 255 R lines with an age field
;; never remove anything, and D does not empty existing directories at
;; runtime.  Age-based cleaning only works via the d-type age field.
;;
;; Reserved names
;; --------------
;;
;; The URL path segment `__mdnav__' directly after the token is a
;; reserved namespace (live-reload stream, stylesheet); a real
;; ~/__mdnav__/ directory would be shadowed by it.

;;; Code:

(require 'browse-url)
(require 'url-util)

(defgroup mdnav nil
  "Live markdown preview via a per-session local pandoc server."
  :group 'tools
  :prefix "mdnav-")

(defconst mdnav--directory
  (file-name-directory (or load-file-name (locate-library "mdnav")))
  "Directory of this package, resolved once at load time.
Never derive it from the current buffer or a calling file: both
change with the context in which a command runs.")

(defcustom mdnav-staging-root "~/tmp-markdown/"
  "Root of the staging tree for preview and export files.
Each Emacs session gets its own subtree `<root>/<instance-id>/'
created on demand.  Must stay a non-hidden path under your home
directory so snap-packaged browsers can read exported files."
  :type 'directory
  :group 'mdnav)

(defcustom mdnav-css
  (expand-file-name "github-markdown.css" mdnav--directory)
  "GitHub-style stylesheet linked from every rendered page.
`mdnav-export-file' inlines it into the exported HTML; the server
serves it at a reserved URL.  Defaults to the copy shipped with
this package."
  :type 'file
  :group 'mdnav)

(defcustom mdnav-mermaid-js
  (expand-file-name "mermaid.min.js" mdnav--directory)
  "Vendored mermaid.js used to render ```mermaid fenced code blocks.
Loaded client-side only on pages that contain a mermaid diagram.
`mdnav-export-file' inlines it into the exported HTML; the server
serves it at a reserved URL.  Defaults to the copy shipped with
this package."
  :type 'file
  :group 'mdnav)

(defcustom mdnav-pandoc-args
  (list "-f" "markdown+tex_math_dollars+emoji"
        "-t" "html5" "-s"
        "--highlight-style" "tango"
        "--mathml")
  "Base arguments passed to pandoc for every render.
`mdnav-export-file' additionally adds --embed-resources."
  :type '(repeat string)
  :group 'mdnav)

(defcustom mdnav-auto-rerender t
  "When non-nil, previewing a buffer makes open tabs reload on save.
`mdnav-stop' detaches the current buffer again."
  :type 'boolean
  :group 'mdnav)

(defvar mdnav--server-process nil
  "Process object of this session's preview server, nil when not running.")

(defvar mdnav--port nil
  "Loopback port of this session's preview server.")

(defvar mdnav--token nil
  "Secret URL token of this session's preview server.")

(defvar mdnav--staging-dir nil
  "This session's staging subtree under `mdnav-staging-root'.")

(defvar mdnav--ready-p nil
  "Non-nil once the server has reported MDNAV-READY.")

(defvar mdnav--start-failed-p nil
  "Non-nil when a server start attempt failed (e.g. port in use).")

(defvar mdnav--shutting-down-p nil
  "Non-nil while `mdnav--shutdown' is tearing the server down.")

(defvar mdnav--filter-acc ""
  "Unprocessed server stdout, kept by `mdnav--server-filter'.")

(defconst mdnav--server-buffer "*mdnav-server*"
  "Name of the server process buffer.")

(defconst mdnav--pandoc-buffer "*mdnav-pandoc*"
  "Name of the buffer collecting pandoc diagnostics.")

;;;; Internal helpers

(defun mdnav--script ()
  "Return the absolute name of the bundled Python server script."
  (expand-file-name "mdnav-server.py" mdnav--directory))

(defun mdnav--random-hex (nbytes)
  "Return NBYTES bytes of random data as a lowercase hex string.
NBYTES is rounded up to a multiple of two."
  (let ((draws (/ (+ nbytes 1) 2))
        (hex "")
        (i 0))
    (while (< i draws)
      (setq hex (concat hex (format "%04x" (random 65536)))
            i (1+ i)))
    hex))

(defun mdnav--random-port ()
  "Return a random TCP port in the dynamic/registered range."
  (+ 32768 (random 28232)))

(defun mdnav--check-external-deps ()
  "Verify that the external programs mdnav needs are on PATH."
  (dolist (program '("python3" "pandoc"))
    (unless (executable-find program)
      (user-error
       "mdnav needs the `%s' program; install it with apt (e.g. on Debian/Ubuntu: sudo apt install %s)"
       program program))))

(defun mdnav--check-file ()
  "Signal a `user-error' unless the current buffer is previewable."
  (unless (buffer-file-name)
    (user-error "mdnav requires a file-visiting buffer"))
  (when (file-remote-p (buffer-file-name))
    (user-error "mdnav does not work on remote files"))
  (let ((true-file (file-truename (buffer-file-name)))
        (home (expand-file-name "~")))
    (unless (string-prefix-p (concat home "/") true-file)
      (user-error "mdnav serves only files under %s; use M-x mdnav-export-file"
                  home))))

(defun mdnav--buffer-url ()
  "Return the preview URL of the current buffer's file.
The path mirrors the file's location under the home directory."
  (let ((rel (file-relative-name
              (file-truename (buffer-file-name))
              (expand-file-name "~"))))
    (concat (format "http://127.0.0.1:%d/" mdnav--port)
            mdnav--token "/"
            (mapconcat #'url-hexify-string (split-string rel "/" t) "/"))))

(defun mdnav--staged-path (input-file)
  "Return the staging-subtree HTML path mirroring INPUT-FILE.
The mirror layout keeps same-basename files in different
directories distinct."
  (let* ((rel (file-relative-name
               (file-truename input-file)
               (expand-file-name "~")))
         (target (concat (file-name-sans-extension rel) ".html")))
    (expand-file-name target mdnav--staging-dir)))

(defun mdnav--run-pandoc (input-file output-file &optional embed)
  "Run pandoc on INPUT-FILE, writing OUTPUT-FILE.
With EMBED non-nil, add --embed-resources (self-contained output).
Return non-nil when pandoc succeeded; diagnostics land in
`mdnav--pandoc-buffer'."
  (let ((args (append mdnav-pandoc-args
                      (when (file-exists-p mdnav-css)
                        (list "--css" (expand-file-name mdnav-css)))
                      (when embed '("--embed-resources"))
                      (list "--metadata"
                            (concat "pagetitle="
                                    (file-name-base input-file))
                            "-o" output-file
                            input-file))))
    (with-current-buffer (get-buffer-create mdnav--pandoc-buffer)
      (erase-buffer))
    (zerop (apply #'call-process
                  "pandoc" nil mdnav--pandoc-buffer nil args))))

(defun mdnav--unwrap-mermaid-code (html-file)
  "Strip pandoc's <code> wrapper from `<pre class=\"mermaid\">' blocks.
Mermaid's client-side auto-render reads a matching element's raw
`innerHTML'; pandoc always wraps fenced code blocks in <code>, even
for a language (mermaid) it applies no syntax highlighting to, so
that nested tag becomes part of the \"diagram source\" and breaks
diagram-type detection."
  (with-temp-buffer
    (insert-file-contents html-file)
    (goto-char (point-min))
    (while (re-search-forward
            "<pre class=\"mermaid\"><code>\\(\\(?:.\\|\n\\)*?\\)</code></pre>"
            nil t)
      (replace-match "<pre class=\"mermaid\">\\1</pre>" t nil))
    (write-region (point-min) (point-max) html-file)))

(defun mdnav--inline-mermaid (html-file)
  "Inline `mdnav-mermaid-js' into HTML-FILE when it has a mermaid diagram.
Only touched when a `<pre class=\"mermaid\">' block is present, so
plain documents stay untouched.  Used by `mdnav-export-file',
whose output has no server to fetch the script from."
  (with-temp-buffer
    (insert-file-contents html-file)
    (goto-char (point-min))
    (when (search-forward "<pre class=\"mermaid\">" nil t)
      (goto-char (point-max))
      (when (search-backward "</body>" nil t)
        (goto-char (match-beginning 0))
        (insert "<script>\n"
                (with-temp-buffer
                  (insert-file-contents mdnav-mermaid-js)
                  (buffer-string))
                "\n</script>\n"
                "<script>mermaid.initialize({startOnLoad:true});</script>\n"))
      (write-region (point-min) (point-max) html-file))))

(defun mdnav--stamp-body-class (html-file)
  "Add the `markdown-body' class to the <body> tag of HTML-FILE in place.
The GitHub CSS is scoped to `.markdown-body', but pandoc 3.1's
default template has no body-class support (newer pandocs accept
`--variable body-class=markdown-body'; drop this when the system
pandoc supports it)."
  (with-temp-buffer
    (insert-file-contents html-file)
    (goto-char (point-min))
    (when (search-forward "<body>" nil t)
      (replace-match "<body class=\"markdown-body\">" t t)
      (write-region (point-min) (point-max) html-file))))

;;;; Server lifecycle

(defun mdnav--reset-state ()
  "Clear all per-session server state variables."
  (setq mdnav--server-process nil
        mdnav--port nil
        mdnav--token nil
        mdnav--staging-dir nil
        mdnav--ready-p nil
        mdnav--start-failed-p nil
        mdnav--filter-acc ""))

(defun mdnav--server-filter (process string)
  "Handle PROCESS stdout STRING: log it, watch for handshake lines."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (goto-char (point-max))
      (insert string)))
  (setq mdnav--filter-acc (concat mdnav--filter-acc string))
  (when (string-match "MDNAV-READY" mdnav--filter-acc)
    (setq mdnav--ready-p t))
  (when (string-match "MDNAV-BIND-FAILED" mdnav--filter-acc)
    (setq mdnav--start-failed-p t))
  ;; Keep only a possible partial trailing line.
  (if (string-match "\n" mdnav--filter-acc)
      (setq mdnav--filter-acc (substring mdnav--filter-acc (match-end 0)))
    (when (> (length mdnav--filter-acc) 4096)
      (setq mdnav--filter-acc ""))))

(defun mdnav--server-sentinel (_process event)
  "React to a server status change described by EVENT."
  (cond
   (mdnav--shutting-down-p
    ;; Expected death during `mdnav--shutdown'; nothing to do.
    nil)
   ((not mdnav--ready-p)
    ;; Died during startup (e.g. port in use, exit 3).  Flag it so the
    ;; start loop can retry on a fresh port.
    (setq mdnav--start-failed-p t))
   (t
    (let ((dir mdnav--staging-dir)
          (note (replace-regexp-in-string "\n" "" event)))
      (mdnav--reset-state)
      (when dir
        (ignore-errors (delete-directory dir t)))
      (message
       "mdnav: server exited unexpectedly (%s); it will restart on the next preview"
       note)))))

(defun mdnav--server-argv (port token staging)
  "Return the argv starting the server on PORT with TOKEN and STAGING.
Pandoc arguments ride along in --pandoc-arg=VALUE form because
argparse rejects option-looking values after a separate flag."
  (append
   (list "python3" (mdnav--script)
         "--port" (number-to-string port)
         "--token" token
         "--staging" staging
         "--css" (expand-file-name mdnav-css)
         "--mermaid-js" (expand-file-name mdnav-mermaid-js)
         "--parent-pid" (number-to-string (emacs-pid)))
   (mapcar (lambda (arg) (concat "--pandoc-arg=" arg))
           mdnav-pandoc-args)))

(defun mdnav--start-server-attempt ()
  "Try once to start the preview server on a fresh random port.
Return non-nil when the server reports readiness."
  (let ((port (mdnav--random-port))
        (token (mdnav--random-hex 16))
        (id (format "mdnav-%d-%s" (emacs-pid) (mdnav--random-hex 4)))
        staging process)
    (setq staging (expand-file-name
                   id (expand-file-name mdnav-staging-root))
          mdnav--port port
          mdnav--token token
          mdnav--staging-dir staging
          mdnav--ready-p nil
          mdnav--start-failed-p nil
          mdnav--filter-acc "")
    (make-directory staging t)
    (let ((process-connection-type nil))
      (setq process (make-process
                     :name "mdnav-server"
                     :buffer (get-buffer-create mdnav--server-buffer)
                     :command (mdnav--server-argv port token staging)
                     :noquery t
                     :filter #'mdnav--server-filter
                     :sentinel #'mdnav--server-sentinel))
      (setq mdnav--server-process process)
      (let ((ticks 0))
        (while (and (not mdnav--ready-p)
                    (not mdnav--start-failed-p)
                    (< ticks 30)               ; 30 x 0.1s = 3s
                    (process-live-p process))
          (accept-process-output process 0.1)
          (setq ticks (1+ ticks))))
      (if mdnav--ready-p
          t
        ;; Never became ready: clean this attempt up before retrying.
        (ignore-errors (delete-process process))
        (ignore-errors (delete-directory staging t))
        (setq mdnav--server-process nil)
        nil))))

(defun mdnav--ensure-server ()
  "Make sure the preview server is running, starting it if needed.
Retries with fresh random ports when the chosen port is taken.
Signal an error when the server cannot be started at all."
  (unless (and (process-live-p mdnav--server-process) mdnav--ready-p)
    (mdnav--reset-state)
    (let ((attempts-left 5)
          (started nil))
      (while (and (not started) (> attempts-left 0))
        (setq attempts-left (1- attempts-left))
        (setq started (mdnav--start-server-attempt)))
      (unless started
        (error "mdnav: could not start the preview server (see %s)"
               mdnav--server-buffer)))))

(defun mdnav--shutdown ()
  "Stop the server and delete this session's staging subtree.
Installed on `kill-emacs-hook'."
  (setq mdnav--shutting-down-p t)
  (when (process-live-p mdnav--server-process)
    (ignore-errors (signal-process mdnav--server-process 'SIGTERM))
    (sit-for 0.1)
    (ignore-errors (delete-process mdnav--server-process)))
  (let ((dir mdnav--staging-dir))
    (when dir
      (ignore-errors (delete-directory dir t))))
  (setq mdnav--shutting-down-p nil))

(add-hook 'kill-emacs-hook #'mdnav--shutdown)

;;;; Save-hook re-render

(defun mdnav--render-on-save ()
  "Re-render this buffer's markdown into the staging subtree.
The browser never fetches the staged file -- every preview URL is
rendered fresh by the server from the real source file.  The
staged file appearing in the watched subtree is only the change
signal that makes open tabs reload.  Failure is quiet on purpose:
a message, never a popped buffer."
  (let ((input (buffer-file-name)))
    (when (and input mdnav--staging-dir)
      (condition-case nil
          (let ((html (mdnav--staged-path input)))
            (make-directory (file-name-directory html) t)
            (if (and (mdnav--run-pandoc input html)
                     (progn (mdnav--stamp-body-class html) t))
                html
              (message "mdnav: pandoc failed for %s (see %s)"
                       input mdnav--pandoc-buffer)
              nil))
        (error nil)))))

;;;; Commands

;;;###autoload
(defun mdnav ()
  "Live-preview this markdown file in a browser tab.
Starts the per-session preview server if this is the first preview
(random port and secret URL token, valid until Emacs exits) and
opens the rendered page.  Markdown links navigate to other files;
other files (images, ...) are served as-is.  With
`mdnav-auto-rerender' non-nil, open tabs reload automatically
after each save of this buffer."
  (interactive)
  (mdnav--check-file)
  (mdnav--check-external-deps)
  (mdnav--ensure-server)
  (browse-url (mdnav--buffer-url))
  (when mdnav-auto-rerender
    (add-hook 'after-save-hook #'mdnav--render-on-save nil t)))

;;;###autoload
(defun mdnav-restart ()
  "Stop the preview server and start a fresh one.
Use this after updating mdnav (e.g. `package-vc-upgrade') to pick up
code changes without restarting Emacs -- the running server is a
separate process holding the old code in memory, so simply reloading
`mdnav.el' does not affect it.  The new server gets a new random port
and token, so open preview tabs are left pointing at a dead URL;
re-run `mdnav' in each buffer you want to keep previewing."
  (interactive)
  (mdnav--check-external-deps)
  (when (process-live-p mdnav--server-process)
    (mdnav--shutdown))
  (mdnav--ensure-server)
  (message "mdnav: server restarted"))

;;;###autoload
(defun mdnav-stop ()
  "Stop auto-reloading the preview of this buffer on save.
The preview server itself keeps running for other buffers; it
exits with Emacs."
  (interactive)
  (remove-hook 'after-save-hook #'mdnav--render-on-save t))

;;;###autoload
(defun mdnav-export-file ()
  "Export this buffer to one self-contained HTML file and open it.
CSS and images are inlined (--embed-resources), producing a
single portable file under `mdnav-staging-root'.  Also the
preview fallback when no server is wanted."
  (interactive)
  (unless (buffer-file-name)
    (user-error "mdnav-export-file requires a file-visiting buffer"))
  (mdnav--check-external-deps)
  (let* ((input (buffer-file-name))
         (html (expand-file-name
                (concat (file-name-base input) ".html")
                (expand-file-name mdnav-staging-root))))
    (make-directory (file-name-directory html) t)
    (if (mdnav--run-pandoc input html 'embed)
        (progn
          (mdnav--stamp-body-class html)
          (mdnav--unwrap-mermaid-code html)
          (mdnav--inline-mermaid html)
          (browse-url (browse-url-file-url html))
          html)
      (pop-to-buffer mdnav--pandoc-buffer)
      (user-error "pandoc failed -- see %s" mdnav--pandoc-buffer))))

(provide 'mdnav)
;;; mdnav.el ends here
