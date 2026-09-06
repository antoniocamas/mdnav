# mdnav

Markdown navigation: live browser preview of markdown files from
Emacs, powered by [pandoc](https://pandoc.org) and a tiny per-session
HTTP server.

## What you get

- `M-x mdnav` — preview the markdown file in the current buffer in your
  system browser.
- **Links work verbatim.** URLs mirror your home directory
  (`http://127.0.0.1:PORT/TOKEN/Workspace/project/README.md` maps to
  `~/Workspace/project/README.md`), so relative links between documents
  and image references navigate as-is. Files are rendered by pandoc on
  demand — nothing is ever stale.
- **Zero-F5 live reload.** Saving the buffer in Emacs pushes a reload to
  every open preview tab (Server-Sent Events). `M-x mdnav-stop` detaches
  the current buffer.
- `M-x mdnav-export-file` — classic fallback: one self-contained HTML
  file (CSS and images inlined) for sharing, or for when you don't want
  a server.
- GitHub-style CSS, syntax highlighting, offline MathML math — the same
  rendering pipeline as pandoc's standalone HTML output.

## Security model

The server binds to `127.0.0.1` only, rejects requests whose `Host`
header is not `127.0.0.1`/`localhost` (DNS-rebinding defense), and
requires a random 128-bit token in every URL; ports and tokens are
regenerated each Emacs session and never persisted. There are no
directory listings. Within those rules a preview URL can read any file
under your home directory — treat preview URLs as private; they expire
when Emacs exits. If Emacs is killed outright, the server notices its
parent is gone, removes its staging directory and exits.

## Install

```elisp
;; Emacs 29+: install straight from this repository
(unless (package-installed-p 'mdnav)
  (package-vc-install "https://github.com/antoniocamas/mdnav"))
(require 'mdnav)
```

Then bind it, e.g. in `markdown-mode`:

```elisp
(define-key markdown-mode-map (kbd "C-c C-c v") #'mdnav)
(define-key markdown-mode-map (kbd "C-c C-v")   #'mdnav)
(define-key markdown-mode-map (kbd "C-c C-u")   #'mdnav-stop)
```

## Dependencies

Standard Debian/Ubuntu packages — no pip, no npm:

```sh
sudo apt install pandoc python3
```

The server (`mdnav-server.py`) uses only the Python standard library.

Optional: preview/export files collect under `~/tmp-markdown/` and can
be swept automatically after 7 days by a systemd *user* tmpfiles rule —
see the Commentary section of `mdnav.el` for the one-time setup.

## License

GPL-3.0-or-later.
