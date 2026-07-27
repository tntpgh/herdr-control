#!/usr/bin/env python3
"""formserve.py — serve a local HTML form/console and collect the answers back.

The point: stop shipping interactive pages to a hosted artifact just to look at
them. A hosted page renders in a browser that has no session with anything local,
cannot talk back to the terminal, and needs an account to view. A page served on
loopback renders in the Herdr browser pane immediately, needs no login, and can
POST its answers straight back to the agent that asked the question.

    formserve.py FORM.html [--deliver TARGET] [--port N] [--timeout SECS]

What it does:
  1. serves FORM.html on 127.0.0.1 (loopback only, never a routable interface)
  2. opens it in the Herdr browser pane (via preview.sh, unless --no-open)
  3. blocks until the page POSTs to /submit, or --timeout elapses
  4. prints the submitted JSON to stdout
  5. with --deliver, hands that JSON to the agent pane TARGET using the
     existing herdr-deliver.sh, which already knows how to get text into a
     Claude Code composer and actually submit it

The page contract — one function, injected automatically, no boilerplate:

    window.submitAnswers({ decision: "action-scoped", confirmed: true })

It returns a promise, disables further submits, and shows a confirmation. A page
can also just POST JSON to /submit itself; the helper is a convenience.

Deliberately NOT included: no auth, no TLS, no external binding. This is a
single-shot loopback server for one local human, torn down the moment it has an
answer. Keep it that way — the moment it binds anything but 127.0.0.1 it becomes
an unauthenticated RPC endpoint into your terminal.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Injected before </body> so a served page needs no boilerplate to answer back.
SHIM = """
<script>
(function () {
  if (window.submitAnswers) return;
  window.submitAnswers = function (answers) {
    return fetch("/submit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(answers === undefined ? {} : answers),
    }).then(function (r) {
      if (!r.ok) throw new Error("submit failed: " + r.status);
      document.querySelectorAll("button,input,select,textarea").forEach(function (el) {
        el.disabled = true;
      });
      var banner = document.createElement("div");
      banner.setAttribute("role", "status");
      banner.style.cssText =
        "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
        "font:600 14px system-ui,-apple-system,sans-serif;text-align:center;" +
        "background:#1f6e7e;color:#fff";
      banner.textContent = "Answers sent back to the terminal. You can close this pane.";
      document.body.appendChild(banner);
      return true;
    }).catch(function (e) {
      // Surfacing the failure matters: a silent one leaves the agent blocking on
      // a submit that never arrives, which reads as a hang rather than an error.
      var banner = document.createElement("div");
      banner.style.cssText =
        "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
        "font:600 14px system-ui,sans-serif;text-align:center;background:#a83a2f;color:#fff";
      banner.textContent = "Could not send answers: " + e.message;
      document.body.appendChild(banner);
      throw e;
    });
  };
})();
</script>
"""


def build_handler(html: bytes, result: dict, done: threading.Event):
    class Handler(BaseHTTPRequestHandler):
        # default logging writes a line per asset request into the agent's stdout
        def log_message(self, *_args):
            pass

        def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            # this page is regenerated per run; a cached copy would silently show
            # yesterday's questions
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                self._send(200, html, "text/html; charset=utf-8")
            elif path == "/healthz":
                self._send(200, b"ok")
            else:
                self._send(404, b"not found")

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/submit":
                self._send(404, b"not found")
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = 0
            raw = self.rfile.read(n) if n > 0 else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except Exception as exc:
                self._send(400, f"bad json: {exc}".encode())
                return
            result["answers"] = payload
            self._send(200, b'{"ok":true}', "application/json")
            # let the response flush before the server is torn down
            done.set()

    return Handler


def open_in_pane(url: str) -> bool:
    preview = HERE / "preview.sh"
    if not preview.exists():
        print(f"formserve: {preview} not found; open {url} yourself", file=sys.stderr)
        return False
    try:
        proc = subprocess.run(["bash", str(preview), "url", url],
                              capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        print("formserve: preview.sh timed out; open the URL yourself", file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(f"formserve: could not open the pane: {proc.stderr.strip()}", file=sys.stderr)
        return False
    return True


def deliver(target: str, url: str, answers: dict) -> None:
    """Hand the answers to an agent pane using the EXISTING delivery leaf.

    herdr-deliver.sh already handles the two ways this strands otherwise: a
    reaped background task splitting type from Enter, and Claude Code collapsing
    a large paste to '[Pasted text #N]' and absorbing the submit. Reimplementing
    that here would be the reuse mistake this repo keeps re-learning."""
    script = HERE / "send-to-agent.sh"
    leaf = HERE / "herdr-deliver.sh"
    body = json.dumps(answers, indent=2, sort_keys=True)
    text = f"Form answers from {url}:\n{body}"
    cmd = None
    if leaf.exists():
        cmd = ["bash", str(leaf), target, text]
    elif script.exists():
        cmd = ["bash", str(script), target, text]
    if not cmd:
        print("formserve: no delivery script found; answers printed above only",
              file=sys.stderr)
        return
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        # Do not swallow this: the caller believes the answers were delivered.
        print(f"formserve: DELIVERY FAILED (exit {proc.returncode}) to {target}: "
              f"{(proc.stderr or proc.stdout).strip()[:300]}", file=sys.stderr)
    else:
        print(f"formserve: delivered to {target}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("form", help="path to the HTML file to serve")
    ap.add_argument("--port", type=int, default=0,
                    help="port (default 0 = pick a free one)")
    ap.add_argument("--deliver", metavar="TARGET",
                    help="herdr pane/tab/label to send the answers to when submitted")
    # 4 hours, not minutes. This waits on a HUMAN: the form has to outlive
    # reading the message that announced it, getting coffee, and finishing the
    # thing they were already doing. A 900s default meant the page could vanish
    # mid-read and the agent would report "no answers submitted" as though the
    # human had declined — which happened on the very first live run.
    ap.add_argument("--timeout", type=float, default=14400.0,
                    help="seconds to wait for a submit (default 14400 = 4h; 0 = forever)")
    ap.add_argument("--no-open", action="store_true",
                    help="do not open the Herdr browser pane; just print the URL")
    args = ap.parse_args()

    form = Path(args.form).expanduser().resolve()
    if not form.is_file():
        print(f"formserve: no such file: {form}", file=sys.stderr)
        return 2

    html = form.read_bytes()
    lowered = html.lower()
    if b"</body>" in lowered:
        cut = lowered.rindex(b"</body>")
        html = html[:cut] + SHIM.encode() + html[cut:]
    else:
        html = html + SHIM.encode()

    result: dict = {}
    done = threading.Event()

    # 127.0.0.1, never 0.0.0.0 — see the module docstring.
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port),
                                build_handler(html, result, done))
    port = httpd.server_address[1]
    url = f"http://127.0.0.1:{port}/"

    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    print(f"formserve: serving {form.name} at {url}", file=sys.stderr)

    if not args.no_open:
        open_in_pane(url)

    timeout = None if args.timeout <= 0 else args.timeout
    try:
        submitted = done.wait(timeout=timeout)
    except KeyboardInterrupt:
        submitted = False
        print("formserve: interrupted", file=sys.stderr)
    finally:
        httpd.shutdown()
        httpd.server_close()

    if not submitted:
        # Word this carefully. "No answers submitted" reads as "the human
        # declined", and an agent acting on that would proceed as if it had an
        # answer it does not have. The form EXPIRED; nobody said anything.
        print(f"formserve: form EXPIRED after {args.timeout}s with no submission. "
              f"This is not a decline — the page stopped being reachable and the "
              f"question is still unanswered. Re-serve it, or raise --timeout.",
              file=sys.stderr)
        return 1

    answers = result.get("answers", {})
    print(json.dumps(answers, indent=2, sort_keys=True))
    if args.deliver:
        deliver(args.deliver, url, answers)
    return 0


if __name__ == "__main__":
    sys.exit(main())
