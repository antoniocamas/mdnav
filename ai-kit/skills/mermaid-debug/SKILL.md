---
name: mermaid-debug
description: Diagnose a mermaid diagram that fails to render or shows "Syntax error in text" / aria-roledescription="error". Determines whether the diagram's own syntax is invalid or mermaid is receiving corrupted input from an upstream rendering pipeline. Scoped to mermaid syntax/rendering diagnosis only — not to fixing whatever upstream tool produced the corrupted input. Trigger on "mermaid syntax error", "diagram won't render", "syntax error in text", "aria-roledescription error", "mermaid rendering broken".
---

# Mermaid Debug

## Reproduce

In a browser: open devtools console on the rendering page and look for an error SVG
(`aria-roledescription="error"`) plus any console errors.

Headless, via Chrome DevTools Protocol (no npm packages needed — Node has a global
`WebSocket` client):

1. `chromium --headless=new --remote-debugging-port=9222 --no-sandbox about:blank`
2. `PUT http://localhost:9222/json/new?<url>` → returns `webSocketDebuggerUrl`
3. Connect over that URL; send `Runtime.enable`, `Page.enable`, then `Page.navigate`
4. Listen for `Runtime.consoleAPICalled` and `Runtime.exceptionThrown` to capture errors
   mermaid logs internally and any page-level JS exceptions

Wait ≥1.5s after navigation before evaluating anything — mermaid's bundle is multi-MB;
evaluating too early gives a false "mermaid is not defined".

## Isolate: syntax bug vs. pipeline bug

1. Get the diagram's intended source verbatim (the fenced code block / source file).
2. Test syntax alone, bypassing the DOM: `await mermaid.parse(intendedSourceText)` via
   `Runtime.evaluate` with `awaitPromise: true`.
   - Throws → the syntax is genuinely invalid. Fix the diagram; stop here.
   - Resolves → syntax is valid. The failure is downstream — continue.
3. Capture what mermaid actually received: read the rendering element's `textContent` and
   `innerHTML` (`document.querySelector('.mermaid').textContent` / `.innerHTML`).
4. Diff that against the intended source. Common corruptions: a nested tag (`<code>`,
   `<span>`) leaking into the text, unresolved HTML entities, mismatched quote characters,
   collapsed/mangled whitespace, mojibake from a wrong charset.
5. Confirm which side is guilty: `mermaid.render('t1', intendedSourceText)` succeeds while
   `mermaid.render('t2', capturedText)` fails — proof the break is between source and DOM,
   not in mermaid or the diagram.

## Verify a fix

Re-run the reproduction against the real page, not a synthetic snippet:

1. Re-fetch/re-render the page.
2. Confirm the SVG's `aria-roledescription` is a real diagram type (`flowchart-v2`,
   `sequenceDiagram`, ...), not `"error"`.
3. Confirm no `Runtime.exceptionThrown` fires during the reproduction.
