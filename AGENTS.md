# AGENTS.md — working on mdnav

**mdnav** ("markdown navigation") is an Emacs package for live browser
preview of markdown files: a per-session local server renders files with
pandoc on demand, mirrors the filesystem under `$HOME` behind a secret
token so links navigate verbatim, and pushes zero-F5 reloads to open
tabs when buffers are saved.

Guidance for coding agents contributing to this repository. User-facing
documentation is `README.md`; the full behavioral spec is the Commentary
section of `mdnav.el`. The design history lives outside this repo (the
author's `markdown_plan.md`, phase 2).

## Layout and responsibilities

- `mdnav.el` — the entire Emacs side: customize group, autoloaded
  commands (`mdnav`, `mdnav-stop`, `mdnav-export-file`), server
  lifecycle, save-hook, cleanup. Package name == file name == `provide`.
- `mdnav-server.py` — per-session HTTP server: loopback bind, token
  gate, on-demand pandoc rendering, static passthrough, staging
  watcher, SSE reload stream, orphan self-exit. Python standard library
  only — never add pip dependencies.
- `github-markdown.css` — stylesheet shipped with the package; linked
  from every rendered page, inlined by the export command.
- `mermaid.min.js` — vendored mermaid UMD build; served only to pages
  containing a ```` ```mermaid ```` fenced code block, inlined by the
  export command under the same condition. Update by re-downloading
  the pinned version from jsdelivr (`mermaid@<version>/dist/mermaid.min.js`)
  — never add it as a pip/npm dependency.

## Protocol between the two sides

- Emacs spawns `python3 mdnav-server.py --port N --token HEX32
  --staging DIR --css PATH --parent-pid PID --pandoc-arg=ARG ...` with
  `make-process` (`:noquery t`, pipe connection).
- Handshake on stdout: `MDNAV-READY <port>` on success;
  `MDNAV-BIND-FAILED …` + exit 3 on port collision (Emacs retries with
  a fresh random port, ≤5 attempts).
- URL scheme: `http://127.0.0.1:PORT/TOKEN/<path-under-$HOME>`.
  `.md`/`.markdown` render on demand; everything else is served
  statically; `__mdnav__` directly after the token is reserved
  (`events` = SSE, `github-markdown.css` = stylesheet,
  `mermaid.min.js` = diagram renderer).
- Live reload: the buffer-local `after-save-hook` renders a staged copy
  into the session's staging subtree — the browser never fetches it;
  its appearance in the watched subtree is only the change signal that
  triggers the SSE broadcast.

## Invariants — do not break

- **Security model:** loopback-only bind; `Host` must be exactly
  `127.0.0.1:PORT` or `localhost:PORT` (else empty 403); token mismatch
  is an empty **404** (never 403 — token validity must not be an
  oracle); paths resolve via `realpath` and must stay inside `$HOME`
  (symlinks out are rejected); directories and unknown paths 404 with
  no listings, ever.
- **Per-session identity:** port and ≥128-bit token are random per
  Emacs session, generated on the elisp side, never persisted anywhere.
- **Lazy start:** no server until the first preview command; it is a
  child of Emacs and must die with it (`kill-emacs-hook` + the
  `--parent-pid` ppid watch cover graceful and crashed exit).
- **Server mode drops `--embed-resources`** (the server delivers
  images/CSS directly); only `mdnav-export-file` adds it.
- **Package boundaries:** never touch `markdown-mode-map` or require
  `markdown-mode` from the package — keybindings belong to user config.
  All public symbols prefixed `mdnav-`, private ones `mdnav--`.
- **Portability:** `Package-Requires: ((emacs "28.1"))`; keep
  byte-compile and `package-lint` clean; `lexical-binding: t`.

## Verification

```sh
# Byte-compile (must be warning-free)
emacs -Q --batch -L . --eval '(byte-compile-file "mdnav.el")'

# package-lint (install it once from MELPA); must report "No issues found"

# Standalone server smoke: fixed port/token, then probe
python3 mdnav-server.py --port 45671 --token 0123456789abcdef0123456789abcdef \
  --staging ~/tmp-markdown/mdnav-selftest --css github-markdown.css \
  --mermaid-js mermaid.min.js --parent-pid $$ \
  --pandoc-arg=-f --pandoc-arg=markdown+tex_math_dollars+emoji \
  --pandoc-arg=-t --pandoc-arg=html5 --pandoc-arg=-s \
  --pandoc-arg=--highlight-style --pandoc-arg=tango --pandoc-arg=--mathml
curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' \
  http://127.0.0.1:45671/<token>/some/file.md     # expect 403
curl -sN --max-time 5 http://127.0.0.1:45671/<token>/__mdnav__/events  # SSE

# Full client flow in batch Emacs (starts server, fetches preview URL,
# checks save-hook staging, shutdown):
emacs -Q --batch -L . --eval '(progn (require (quote mdnav)) … )'
```

## Gotchas learned the hard way

- **`--pandoc-arg` must use the `--pandoc-arg=VALUE` form** — argparse
  rejects option-looking values passed as a separate argument, which
  silently kills every start attempt when pandoc args contain flags
  like `--mathml`.
- **Package-directory resolution happens once at load time**
  (`mdnav--directory` defconst). Never derive it from
  `buffer-file-name` (any visited buffer) or `load-file-name` at
  runtime (points at whichever file is being loaded, e.g. a test
  harness). Both bugs shipped and were caught in testing.
- **Recompile before testing**: batch Emacs prefers a stale `.elc` over
  a newer `.el` only with a warning it prints once — delete or
  recompile after edits.
- **Batch-Emacs test harness quirks:** with `emacs --batch -l script.el
  -- a b`, the leading `--` is itself the first element of
  `command-line-args-left`; `with-temp-file` switches to a buffer with
  no file name, so compute buffer-derived values before it; set
  `no_proxy=127.0.0.1,localhost` before using `url-retrieve` against
  the server.
- **The SSE endpoint sits directly after the token**
  (`/TOKEN/__mdnav__/events`), not relative to a file URL.
- Two same-basename files in different directories are distinct in
  server mode (paths are mirrored) but still collide in
  `mdnav-export-file` output (flat `<basename>.html`) — known,
  documented trade-off.

## Release flow

1. Bump the `Version` header in `mdnav.el` if user-visible.
2. Commit and push to `main`.
3. Users update with `M-x package-vc-upgrade` (the installed package is
   a clone of this repository). MELPA, if ever added, is a one-line
   recipe pointing here.
