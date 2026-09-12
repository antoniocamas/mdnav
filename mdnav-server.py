#!/usr/bin/env python3
"""mdnav preview server -- one instance per Emacs session.

Emacs starts this script with a random port, a random secret URL
token and a private staging subtree.  The server:

  * binds to 127.0.0.1 only and rejects requests whose Host header
    is not 127.0.0.1/localhost (DNS-rebinding defense),
  * requires the token as the first URL path segment (404 on
    mismatch, so token validity is not an oracle),
  * mirrors the filesystem under $HOME: .md/.markdown files are
    rendered by pandoc on demand, everything else is served
    statically, directories and unknown paths are 404 (no listings),
  * watches the staging subtree and pushes "reload" events over
    Server-Sent Events so open tabs refresh themselves when Emacs
    re-renders on save,
  * exits and removes its staging subtree when its parent Emacs
    process disappears (crash safety).

Standard library only; no third-party dependencies.
"""

import argparse
import hmac
import mimetypes
import os
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.realpath(os.path.expanduser("~"))
RENDER_EXTENSIONS = (".md", ".markdown")
KEEPALIVE_SECONDS = 15.0
PANDOC_TIMEOUT = 30


class PandocError(Exception):
    """Raised when the on-demand pandoc render fails."""


class ReloadBus:
    """Generation counter: the watcher bumps it, SSE clients wait on it."""

    def __init__(self):
        self._condition = threading.Condition()
        self.generation = 0

    def publish(self):
        """Announce a change to every waiting SSE client."""
        with self._condition:
            self.generation += 1
            self._condition.notify_all()

    def wait(self, last_seen, timeout):
        """Block until the generation passes LAST_SEEN or TIMEOUT expires."""
        with self._condition:
            if self.generation <= last_seen:
                self._condition.wait(timeout)
            return self.generation


BUS = ReloadBus()


def snapshot(root):
    """Return {path: (mtime_ns, size)} for every file under ROOT."""
    state = {}
    try:
        with os.scandir(root) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    state.update(snapshot(entry.path))
                elif entry.is_file():
                    info = entry.stat(follow_symlinks=False)
                    state[entry.path] = (info.st_mtime_ns, info.st_size)
    except FileNotFoundError:
        pass
    return state


def watcher(staging, interval, parent_pid):
    """Daemon thread: poll STAGING for changes, watch out for orphaning.

    When the parent Emacs process goes away (crash -- no
    kill-emacs-hook ran), delete the staging subtree and exit the
    whole process; no server, port or token outlives its session.
    """
    previous = snapshot(staging)
    while True:
        time.sleep(interval)
        if os.getppid() != parent_pid:
            shutil.rmtree(staging, ignore_errors=True)
            os._exit(0)
        current = snapshot(staging)
        if current != previous:
            previous = current
            BUS.publish()


def render_markdown(source, pandoc_args, token):
    """Render SOURCE with pandoc and return postprocessed HTML.

    The stylesheet href is token-absolute (depth-independent), the
    body gets the markdown-body class the GitHub CSS is scoped to,
    and a small script subscribes the page to the reload stream.
    """
    argv = [
        "pandoc",
        *pandoc_args,
        "--css", f"/{token}/__mdnav__/github-markdown.css",
        "--metadata",
        f"pagetitle={os.path.splitext(os.path.basename(source))[0]}",
        source,
    ]
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=PANDOC_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        raise PandocError(
            f"pandoc timed out after {PANDOC_TIMEOUT}s on {source}"
        ) from None
    if proc.returncode != 0:
        detail = proc.stderr.strip() or "no diagnostic output"
        raise PandocError(f"pandoc failed on {source}:\n{detail[:4096]}")
    html = proc.stdout
    # Scope the GitHub CSS to the body (pandoc 3.1 has no body-class
    # template variable yet).
    html = re.sub(r"<body\b", '<body class="markdown-body">', html, count=1)
    # Pandoc always wraps fenced code blocks in <code>, even for a
    # language (mermaid) it applies no syntax highlighting to.
    # Mermaid's client-side auto-render reads the block's innerHTML, so
    # a nested <code> tag becomes part of the "diagram source" and
    # breaks diagram-type detection -- strip it for mermaid blocks only.
    html = re.sub(
        r'<pre class="mermaid"><code>(.*?)</code></pre>',
        r'<pre class="mermaid">\1</pre>',
        html,
        flags=re.S,
    )
    script = (
        "<script>\n"
        f"(function(){{var e=new EventSource('/{token}/__mdnav__/events');"
        "e.onmessage=function(){location.reload()};})();\n"
        "</script>\n"
    )
    if '<pre class="mermaid">' in html:
        script += (
            f'<script src="/{token}/__mdnav__/mermaid.min.js"></script>\n'
            "<script>mermaid.initialize({startOnLoad:true});</script>\n"
        )
    if "</body>" in html:
        html = html.replace("</body>", script + "</body>", 1)
    else:
        html += script
    return html


class Config:
    """This server instance's configuration, set once in main()."""

    def __init__(self):
        self.port = 0
        self.token = b""  # bytes; compared with hmac.compare_digest
        self.pandoc_args = []
        self.css_path = ""
        self.mermaid_js_path = ""


CONFIG = Config()


class Handler(BaseHTTPRequestHandler):
    """Loopback-only handler serving $HOME behind a per-session token."""

    protocol_version = "HTTP/1.1"
    server_version = "mdnav"

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        """Stay silent; stdout belongs to the Emacs handshake."""

    # -- plumbing ---------------------------------------------------------

    def _reject(self, code):
        """Answer with an empty body of CODE and exact length zero."""
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_bytes(self, code, ctype, body):
        """Answer with a fully buffered body and exact Content-Length."""
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- routing ----------------------------------------------------------

    def do_GET(self):
        host = self.headers.get("Host", "")
        if host not in (f"127.0.0.1:{CONFIG.port}",
                        f"localhost:{CONFIG.port}"):
            self._reject(403)
            return
        path = urllib.parse.urlsplit(self.path).path
        parts = path.lstrip("/").split("/", 1)
        got = parts[0].encode("utf-8", "surrogateescape")
        if not hmac.compare_digest(got, CONFIG.token):
            self._reject(404)
            return
        rest = parts[1] if len(parts) > 1 else ""
        if rest == "__mdnav__/events":
            self._stream_events()
        elif rest == "__mdnav__/github-markdown.css":
            self._serve_file(CONFIG.css_path, "text/css; charset=utf-8")
        elif rest == "__mdnav__/mermaid.min.js":
            self._serve_file(
                CONFIG.mermaid_js_path, "text/javascript; charset=utf-8"
            )
        else:
            self._serve_mirror(rest)

    # -- endpoints --------------------------------------------------------

    def _serve_mirror(self, rest):
        """Map a URL path to a file under HOME and serve or render it."""
        segments = []
        for raw in rest.split("/"):
            decoded = urllib.parse.unquote(raw)
            if decoded in ("", "."):
                continue
            if decoded == ".." or "/" in decoded or "\x00" in decoded:
                self._reject(404)
                return
            segments.append(decoded)
        rel = posixpath.normpath("/".join(segments))
        if rel == "." or rel.startswith("../"):
            self._reject(404)
            return
        target = os.path.realpath(os.path.join(HOME, rel))
        if target != HOME and not target.startswith(HOME + os.sep):
            # Symlink resolving outside $HOME is containment-rejected.
            self._reject(404)
            return
        if not os.path.isfile(target):
            # Includes directories: no listings, ever.
            self._reject(404)
            return
        if target.lower().endswith(RENDER_EXTENSIONS):
            self._serve_markdown(target)
        else:
            self._serve_file(target)

    def _serve_markdown(self, source):
        try:
            html = render_markdown(
                source, CONFIG.pandoc_args, CONFIG.token.decode("ascii")
            )
        except PandocError as exc:
            self._send_bytes(
                500, "text/plain; charset=utf-8", str(exc).encode("utf-8")
            )
            return
        self._send_bytes(200, "text/html; charset=utf-8", html.encode("utf-8"))

    def _serve_file(self, path, forced_ctype=None):
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except OSError:
            self._reject(404)
            return
        ctype = forced_ctype
        if ctype is None:
            ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
            if ctype.startswith("text/"):
                ctype += "; charset=utf-8"
        self._send_bytes(200, ctype, body)

    def _stream_events(self):
        """Push reload events over SSE until the client disconnects."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        last_seen = BUS.generation
        try:
            while True:
                current = BUS.wait(last_seen, KEEPALIVE_SECONDS)
                if current != last_seen:
                    last_seen = current
                    self.wfile.write(b"data: reload\n\n")
                else:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return


def main():
    parser = argparse.ArgumentParser(
        description="mdnav preview server (started by mdnav.el)"
    )
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--staging", required=True)
    parser.add_argument("--css", required=True)
    parser.add_argument("--mermaid-js", required=True)
    parser.add_argument("--parent-pid", type=int, default=None)
    parser.add_argument("--pandoc-arg", action="append", default=[],
                        help="pandoc argument, repeatable")
    parser.add_argument("--poll-interval", type=float, default=0.4,
                        help="staging watch interval in seconds (testing)")
    args = parser.parse_args()

    # Emacs reads our stdout through a pipe: every handshake print is
    # flushed explicitly so lines are visible immediately.
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as exc:
        print(f"MDNAV-BIND-FAILED {exc}", flush=True)
        sys.exit(3)

    CONFIG.port = server.server_address[1]
    CONFIG.token = args.token.encode("ascii")
    CONFIG.pandoc_args = args.pandoc_arg
    CONFIG.css_path = os.path.realpath(args.css)
    CONFIG.mermaid_js_path = os.path.realpath(args.mermaid_js)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    threading.Thread(
        target=watcher,
        daemon=True,
        args=(
            args.staging,
            args.poll_interval,
            args.parent_pid if args.parent_pid is not None else os.getppid(),
        ),
    ).start()

    print(f"MDNAV-READY {CONFIG.port}", flush=True)
    try:
        server.serve_forever()
    except SystemExit:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
