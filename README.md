# mdnav

Markdown navigation: live browser preview of markdown files from
Emacs, powered by [pandoc](https://pandoc.org) and a tiny per-session
HTTP server.

## Commands

| Command | Key (suggested) | What it does |
|---|---|---|
| `M-x mdnav` | `C-c C-c v` / `C-c C-v` | Preview the current buffer in your browser. First call starts the server. |
| `M-x mdnav-stop` | `C-c C-u` | Stop auto-reloading this buffer's preview on save (server keeps running). |
| `M-x mdnav-export-file` | — | Write one self-contained HTML file (CSS and images inlined) under `~/tmp-markdown/` and open it. |

Configuration lives in the `mdnav` customize group: staging root,
stylesheet, pandoc arguments, and the auto-rerender default.

## What you get

- **Links work verbatim.** Preview URLs mirror your home directory
  (`http://127.0.0.1:PORT/TOKEN/Workspace/project/README.md` maps to
  `~/Workspace/project/README.md`), so relative links between documents
  and image references navigate as-is. Files are rendered by pandoc on
  demand — nothing is ever stale.
- **Zero-F5 live reload.** Saving the buffer in Emacs pushes a reload to
  every open preview tab (Server-Sent Events).
- **Session-scoped server.** Nothing runs until the first preview of an
  Emacs session; the server is a child process that exits with Emacs.
  If Emacs is killed outright, the server notices its parent is gone,
  deletes its staging directory and exits by itself.
- GitHub-style CSS, syntax highlighting, offline MathML math — pandoc's
  standalone HTML pipeline.
- **Inline Mermaid diagrams.** ` ```mermaid ` fenced code blocks render
  as live diagrams in the preview, via a vendored `mermaid.js` loaded
  only on pages that use it. `mdnav-export-file` inlines it too, so the
  exported HTML stays self-contained.

## Security model

The server binds to `127.0.0.1` only, rejects requests whose `Host`
header is not `127.0.0.1`/`localhost` (DNS-rebinding defense), and
requires a random 128-bit token in every URL; ports and tokens are
regenerated each Emacs session and never persisted. There are no
directory listings. Within those rules a preview URL can read any file
under your home directory — treat preview URLs as private; they expire
when Emacs exits.

## Install

Emacs 29+:

```elisp
(unless (package-installed-p 'mdnav)
  (package-vc-install "https://github.com/antoniocamas/mdnav"))
(require 'mdnav)
```

Suggested keybindings in `markdown-mode`:

```elisp
(define-key markdown-mode-map (kbd "C-c C-c v") #'mdnav)
(define-key markdown-mode-map (kbd "C-c C-v")   #'mdnav)
(define-key markdown-mode-map (kbd "C-c C-u")   #'mdnav-stop)
```

## Updating

The installed package is a git clone of this repository:

```
M-x package-vc-upgrade
```

(or `package-vc-refresh` after editing the checked-out sources in
`~/.emacs.d/elpa/mdnav/` directly).

## Dependencies

Standard Debian/Ubuntu packages — no pip, no npm:

```sh
sudo apt install pandoc python3
```

The server (`mdnav-server.py`) uses only the Python standard library.
If either program is missing, `M-x mdnav` fails with a message naming
the missing package.

## Troubleshooting

- **The preview tab stopped reloading.** The server may have died; run
  `M-x mdnav` again — it cold-starts a fresh server, port and token.
  Tabs holding the old URL need one manual refresh after that.
- **A page shows a pandoc error.** Rendering errors are returned in the
  page itself (HTTP 500 with pandoc's stderr) — fix the markdown and
  save; the tab reloads.
- **Where do the files go?** Staging subtrees under `~/tmp-markdown/`
  (one per Emacs session, removed when Emacs exits). To sweep stale
  files automatically after 7 days, see the systemd tmpfiles one-time
  setup in the Commentary section of `mdnav.el`.

## License

GPL-3.0-or-later.
