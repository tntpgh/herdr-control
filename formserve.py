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

Deliberately minimal: no TLS, no external binding, no persistent credential.
/submit does require a random per-run token (embedded only in the page we
actually served, checked with a constant-time comparison) so a local process
that never loaded the page cannot blind-POST a fabricated answer — see
build_handler() below. This is a single-shot loopback server for one local
human, torn down the moment it has an answer. Keep it that way — the moment
it binds anything but 127.0.0.1 it becomes a reachable RPC endpoint into your
terminal.
"""
from __future__ import annotations

import argparse
import fcntl
import hmac
import html as html_module
import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent

sys.path.insert(0, str(HERE / "lib"))
from record_store import NotClaimable, claim_and_update  # noqa: E402
from form_theme import force_dark  # noqa: E402
from form_schema import parse_schema, validate_answers  # noqa: E402

# Injected before </body> so a served page needs no boilerplate to answer back.
SHIM = """
<input type="hidden" id="__formserve_token" value="{{FORMSERVE_TOKEN}}">
<input type="hidden" id="__formserve_request_id" value="{{FORMSERVE_REQUEST_ID}}">
<script>
(function () {
  if (window.submitAnswers) return;
  window.submitAnswers = function (answers) {
    var body = Object.assign({}, answers === undefined ? {} : answers);
    // The token lives only in the page we actually served (see the /submit
    // handler for why); folding it into every submit here means a page using
    // the documented submitAnswers() helper closes the gap for free, without
    // the page author needing to know the token exists.
    body.__formserve_token = document.getElementById("__formserve_token").value;
    return fetch("/submit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then(function (r) {
      return r.text().then(function (t) {
        var data = {};
        try { data = JSON.parse(t); } catch (e) {}
        if (!r.ok) throw new Error((data && data.error) || (r.status + ": " + t));
        document.querySelectorAll("button,input,select,textarea").forEach(function (el) {
          el.disabled = true;
        });
        var banner = document.createElement("div");
        banner.setAttribute("role", "status");
        banner.style.cssText =
          "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
          "font:600 14px system-ui,-apple-system,sans-serif;text-align:center;" +
          "background:#1f6e7e;color:#fff";
        var saved = data.answers || {};
        var pairs = Object.keys(saved).map(function (k) { return k + "=" + saved[k]; }).join(", ");
        banner.textContent = body.cancelled
          ? "Cancelled. You can close this pane."
          : "Saved: " + pairs + ". You can close this pane.";
        document.body.appendChild(banner);
        if (window.__herdrClearFormDraft) window.__herdrClearFormDraft();
        return true;
      });
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
<script>
// Draft preservation (Terrence, 2026-10-29; tightened by the conductor the
// same day): a form restart or restyle must never silently DROP unsaved
// edits, but must never silently APPLY one either. sessionStorage only --
// nothing server-side, nothing auto-submitted, nothing auto-restored.
//
// Keyed by the request's own stable identity (the SOURCE filename, never
// the per-run registry id -- a restart mints a brand new id, which would
// defeat the whole point) AND a hash of the form's current semantic schema
// (headings/legends, option values, and the field name+type set). Either
// changing -- a different request, or the same request now asking a
// different question -- produces a different storage key by construction,
// so a stale draft is never even looked up: fails closed, not a migration.
//
// Sensitive and hidden fields are never captured: password/hidden types,
// plus any field whose name/id/autocomplete reads as a credential.
(function () {
  var REQUEST_ID = (document.getElementById("__formserve_request_id") || {}).value || "";
  var SENSITIVE_RE = /token|secret|password|passwd|credential|api[_-]?key|private[_-]?key|ssn|ccnum|card[_-]?number|cvv/i;
  function isSensitive(el) {
    if (el.type === "password" || el.type === "hidden") return true;
    var ac = (el.autocomplete || "").toLowerCase();
    if (ac === "current-password" || ac === "new-password" || ac.indexOf("cc-") === 0) return true;
    return SENSITIVE_RE.test(el.name || "") || SENSITIVE_RE.test(el.id || "");
  }
  function fields() {
    return Array.prototype.slice.call(document.querySelectorAll("input,textarea,select"))
      .filter(function (el) { return !isSensitive(el) && (el.name || el.id); });
  }
  function fieldKey(el) { return el.name || el.id; }
  function hashOf(s) {
    var h = 5381;
    for (var i = 0; i < s.length; i++) { h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; }
    return h.toString(36);
  }
  function schemaOf(current) {
    // h1/h2/legend/label: a rewritten question, section heading, or option
    // label changes this even when the underlying name/type/value does not
    // -- "reworded questions can reuse an old draft" (independent audit,
    // 2026-10-29) was exactly a label changing with everything else held
    // fixed.
    var headings = Array.prototype.slice.call(document.querySelectorAll("h1,h2,legend,label"))
      .map(function (el) { return (el.textContent || "").trim(); });
    // Both the VALUE and the visible text: an <option value=x>Old</option>
    // reworded to <option value=x>New</option> has an unchanged value but a
    // different meaning to a human.
    var options = Array.prototype.slice.call(document.querySelectorAll("option,input[type=radio],input[type=checkbox]"))
      .map(function (el) { return (el.value || "") + "|" + (el.textContent || "").trim(); }).sort();
    var fieldSig = current.map(function (el) { return fieldKey(el) + ":" + el.type; }).sort();
    return hashOf(JSON.stringify({ h: headings, o: options, f: fieldSig }));
  }
  var current = fields();
  var key = "herdr-form-draft:" + REQUEST_ID + ":" + schemaOf(current);
  function clearDraft() { try { sessionStorage.removeItem(key); } catch (e) {} }
  function saveDraft() {
    var data = {};
    current.forEach(function (el) {
      var k = fieldKey(el);
      if (el.type === "checkbox" || el.type === "radio") { if (el.checked) data[k] = el.value; }
      else { data[k] = el.value; }
    });
    try { sessionStorage.setItem(key, JSON.stringify(data)); } catch (e) {}
  }
  var draft = null;
  try {
    var raw = sessionStorage.getItem(key);
    if (raw) draft = JSON.parse(raw);
  } catch (e) { draft = null; }
  // A non-empty, schema-matching draft exists -- OFFER it. Nothing is
  // applied to a field until the human clicks Restore.
  if (draft && Object.keys(draft).length) {
    document.addEventListener("DOMContentLoaded", function () {
      var bar = document.createElement("div");
      bar.setAttribute("role", "status");
      bar.style.cssText = "position:fixed;left:0;right:0;top:0;z-index:99998;padding:8px 16px;" +
        "font:600 13px system-ui,-apple-system,sans-serif;text-align:center;background:#3a5a3a;color:#fff";
      var msg = document.createElement("span");
      msg.textContent = "Unsaved edits found from before this page reloaded. ";
      var btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = "Restore";
      btn.style.cssText = "margin-left:8px;padding:2px 10px;font:600 12px system-ui,sans-serif;" +
        "border:1px solid #fff;border-radius:3px;background:transparent;color:#fff;cursor:pointer";
      btn.addEventListener("click", function () {
        current.forEach(function (el) {
          var k = fieldKey(el);
          if (!(k in draft)) return;
          if (el.type === "checkbox" || el.type === "radio") { el.checked = el.value === draft[k]; }
          else { el.value = draft[k]; }
        });
        bar.textContent = "Restored.";
        bar.style.background = "#1f6e7e";
      });
      bar.appendChild(msg);
      bar.appendChild(btn);
      document.body.insertBefore(bar, document.body.firstChild);
    });
  }
  current.forEach(function (el) {
    el.addEventListener("input", saveDraft);
    el.addEventListener("change", saveDraft);
  });
  window.__herdrClearFormDraft = clearDraft;
})();
</script>
"""


def build_handler(html: bytes, result: dict, done: threading.Event, token: str, schema: dict):
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
            # No auth on this endpoint (see the module docstring) means any
            # local process that can reach 127.0.0.1:<port> during the up-to-4h
            # serving window could otherwise POST a fabricated answer and, with
            # --deliver, have it typed straight into a live agent pane — a local
            # prompt-injection primitive. The per-run token is unguessable
            # (secrets.token_urlsafe), embedded only in the HTML we actually
            # served (SHIM above), and never logged (log_message stays
            # silenced). A submit that doesn't carry a matching token did not
            # come from someone who loaded this page, so it is rejected before
            # the payload is ever stored or delivered. compare_digest avoids
            # leaking the token's value through response-timing differences.
            submitted = payload.pop("__formserve_token", None) if isinstance(payload, dict) else None
            if not isinstance(submitted, str) or not hmac.compare_digest(submitted, token):
                self._send(403, b"forbidden: missing or invalid token")
                return
            # Validate BEFORE claiming status=answered (contract point 2): a
            # row that fails validation stays `open` so the human can retry,
            # rather than recording a plausible-looking but wrong answer the
            # way the pilot form's name mismatch did on 2026-10-18.
            cancelled = isinstance(payload, dict) and payload.get("cancelled") is True
            if not cancelled:
                err = validate_answers(schema, payload)
                if err:
                    self._send(400, json.dumps({"ok": False, "error": err}).encode(),
                               "application/json")
                    return
            # CLAIM BEFORE ACKNOWLEDGING. Two-model review, 2026-09-09: the 200
            # used to go out here unconditionally, the claim happened later in
            # main(), and when the hub had already recorded a different answer
            # this process printed and DELIVERED the losing one to the agent
            # anyway - the record was protected, the agent got a contradictory
            # decision. Now the durable claim is the acknowledgement: a loser
            # gets 409 with the canonical outcome and nothing is delivered.
            status = "cancelled" if cancelled else "answered"
            outcome, row = update_form(result.get("registry"), status=status, answers=payload)
            if outcome == "lost":
                self._send(409, json.dumps({"ok": False, "already": row.get("status"),
                                            "via": row.get("answered_via"),
                                            "answers": row.get("answers")}).encode(),
                           "application/json")
                return
            # Readback: the persisted row, not the in-memory payload, so the
            # confirmation and stdout reflect what actually landed on disk.
            persisted = row.get("answers", payload) if outcome == "won" else payload
            result["answers"] = persisted
            result["claimed"] = outcome          # "won", or "unregistered" when no hub record exists
            self._send(200, json.dumps({"ok": True, "answers": persisted}).encode(),
                       "application/json")
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
        # `--reply`, not a brief. Form answers are BY CONSTRUCTION an answer to
        # something the agent asked, and hub.py anchors "did it do what I last
        # asked?" to the last `brief_delivered`: recording this as a brief moves
        # the anchor past the worker's own completion evidence, so answering a
        # form parked the task in Needs-attention as `stalled` forever (a
        # finished worker never writes another `_done`). hub.py's notify_owner
        # is the twin of this call and does the same thing; send-to-agent.sh
        # records no event at all, so it takes no flag.
        cmd = ["bash", str(leaf), "--reply", target, text]
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


# ---- hub registry ------------------------------------------------------------
# hub.py's /decisions inbox lists every form this script serves: one JSON file
# per run under ~/.local/state/herdr/forms/, written at start (status open),
# rewritten on submit (answered, with the answers) or timeout (expired). The
# hub treats "open but the port no longer answers" as gone. Registry failures
# never affect the form itself — the human's page comes first.
FORMS_DIR = Path(os.environ.get("HERDR_STATE_ROOT", Path.home() / ".local/state/herdr")) / "forms"
# herdr-action.sh writes and answers its own action-request forms here
# (run_state_root()/action-forms, lib/run-registry.sh): run_state_root() is
# `${HERDR_RUN_STATE_DIR:-$HOME/.local/state/herdr/runs}` (lib/run-registry.sh
# :50-52) -- a DIFFERENT variable from HERDR_STATE_ROOT above, and several
# suites set them to different scratch dirs. Deriving this from the wrong one
# would miss a hand copy under the real action-forms dir whenever an operator
# overrides HERDR_RUN_STATE_DIR.
ACTION_FORMS_DIR = Path(os.environ.get("HERDR_RUN_STATE_DIR",
                                       Path.home() / ".local/state/herdr/runs")) / "action-forms"
# Same file lib/run-registry.sh's registry_db() resolves to.
ACTION_REGISTRY_DB = ACTION_FORMS_DIR.parent / "registry.sqlite3"


_ACTION_FORM_ID_RE = re.compile(r"^(?P<id>.+)-\d+$")


def action_form_request_id(form: Path) -> str:
    """The <request_id> herdr-action.sh encoded into `<request_id>-N.html`
    (herdr-action.sh:405). Falls back to the whole stem for a name that
    doesn't fit the pattern, which then simply never matches a real request.
    """
    m = _ACTION_FORM_ID_RE.match(form.stem)
    return m.group("id") if m else form.stem


def is_herdr_actions_own_serve(form: Path, request_id: str) -> bool:
    """True only for herdr-action.sh's OWN, current call on its OWN file:
    the caller's --request-id must name the id encoded in the filename, AND
    that id must still be a real row in the SAME registry herdr-action.sh
    uses (lib/run-registry.sh's action_requests table) -- not merely a
    plausible-looking filename, which a hand copy can trivially reproduce.
    Read-only connection; formserve never writes to the control-plane registry.

    Residual limitation (REVIEW-FORMSERVE-3e67f75.md, C1), accepted rather
    than closed: this binds to an ARGUMENT (--request-id) and a DATABASE
    ROW, not to the calling process. A same-UID hand copy of the html named
    exactly `<id>-N.html`, served with `--request-id <id>` while that id is
    still a live pending row, passes this check -- nothing here proves the
    caller is actually herdr-action.sh's own backgrounded formserve
    invocation. This guard stops the incident shape (a copy with a WRONG,
    unrelated heading/title mislabeling the hub, or a copy recorded under
    the wrong id) and accidental duplication; it is not a security boundary
    against a same-UID process that deliberately reproduces both the
    filename and the flag. Closing that would need a per-serve nonce minted
    by herdr-action.sh and written into the row alongside request_id, passed
    back on the formserve command line and checked here instead of/beside
    request_id -- out of scope for this round.
    """
    if not request_id or request_id != action_form_request_id(form):
        return False
    if not ACTION_REGISTRY_DB.is_file():
        return False
    try:
        con = sqlite3.connect(f"file:{ACTION_REGISTRY_DB}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return False
    try:
        row = con.execute("SELECT 1 FROM action_requests WHERE request_id = ? LIMIT 1",
                          (request_id,)).fetchone()
        return row is not None
    except sqlite3.Error:
        return False
    finally:
        con.close()


_HEADING_RE = re.compile(rb"<h[12][^>]*>(.*?)</h[12]>", re.I | re.S)
_TITLE_TAG_RE = re.compile(rb"<title[^>]*>(.*?)</title>", re.I | re.S)


def _clean_text(raw: bytes) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", raw.decode("utf-8", "replace"))).strip()


def resolve_title(html_bytes: bytes, fallback: str, explicit: str | None) -> tuple[str, str | None]:
    """Decide the title recorded for this form. Returns (title, refusal_reason).

    refusal_reason is None unless the page must not be served: incident
    2026-10-30, two hook-mode forms were built by copying another form's
    <head>, so the hub listed a live approval form under a stranger's title
    while the page itself showed the right heading. The heading is what the
    human actually reads, so it wins and is what gets recorded — but a
    disagreeing <title> is evidence of exactly that copy-paste mistake, so
    refuse rather than silently mislabel the hub's list. --title overrides.
    """
    if explicit is not None:
        return explicit, None
    heading_match = _HEADING_RE.search(html_bytes)
    heading = _clean_text(heading_match.group(1)) if heading_match else ""
    title_match = _TITLE_TAG_RE.search(html_bytes)
    title_tag = _clean_text(title_match.group(1)) if title_match else ""
    if heading and title_tag and heading != title_tag:
        return "", (f"<title> says {title_tag!r} but the first heading (<h1>/<h2>) says "
                     f"{heading!r} — looks like the <head> was copied from another form. "
                     f"Fix the mismatch, or pass --title to record one explicitly.")
    return heading or title_tag or fallback, None


def register_form(form: Path, html_bytes: bytes, url: str, port: int, timeout: float, title: str,
                  token: str = "", deliver_to: str = "", schema: dict | None = None,
                  request_id: str = "") -> Path | None:
    """Register the form AND hand the hub a copy it can serve itself.

    The HTML copy plus the token are what make the decision outlive this
    process. Without them, this port dying — on submit by design, or on a kill
    or a sleep by accident — left the form listed `open` at a URL that no
    longer answered (observed 2026-09-09: the eBay Hunter `rev 1` form, marked
    `gone`, unanswerable). The hub serves the same bytes at
    /decisions/<id> for as long as the registry row exists.
    """
    try:
        FORMS_DIR.mkdir(parents=True, exist_ok=True)
        now = time.time()
        path = FORMS_DIR / f"{time.strftime('%Y%m%dT%H%M%S', time.gmtime(now))}-{port}.json"
        try:
            (FORMS_DIR / f"{path.stem}.html").write_bytes(html_bytes)
            hub_url = f"http://127.0.0.1:8600/decisions/{path.stem}"
        except OSError as e:
            print(f"formserve: hub copy not written ({e}); only this port can answer",
                  file=sys.stderr)
            hub_url = ""
        path.write_text(json.dumps({
            "id": path.stem, "title": title, "url": url, "port": port,
            "form_path": str(form), "pid": os.getpid(), "status": "open",
            "token": token, "deliver_to": deliver_to, "hub_url": hub_url,
            "schema": schema or {}, "request_id": request_id,
            "created_at": int(now * 1000),
            "expires_at": int((now + timeout) * 1000) if timeout > 0 else None,
        }, indent=1))
        return path
    except OSError as e:
        print(f"formserve: hub registry not written ({e}); the form itself is unaffected", file=sys.stderr)
        return None


def update_form(path: Path | None, **fields) -> tuple[str, dict]:
    """Record an outcome, unless the hub already recorded one.

    Both surfaces can accept the same form, so the write is claim-once: the
    status re-read, the guard and the write happen under one lock and land via
    atomic rename (lib/record_store.py). The previous read-then-write could not
    honour its own "first writer wins" comment — hub.py and this process could
    both see `open` and the slower one would overwrite the recorded answer,
    losing `answered_via`, the field that says where the human actually
    answered.

    `status=expired` is the deliberate exception: expiry is allowed to stamp a
    form that is still open, and must never overwrite a real answer — which is
    exactly `require_status="open"`. Expiry means still-unanswered, never
    declined.

    Returns (outcome, row):
      ("won", row)          this call recorded the outcome
      ("lost", row)         another surface already did; row is the canonical record
      ("unregistered", {})  no hub record exists (hub was unreachable at start)
      ("unavailable", {})   the record exists but could not be read/written
    Callers MUST branch on this. The first version returned None and swallowed
    NotClaimable with a stderr line, and main() then printed and delivered the
    losing answer as if it had won (two-model review, 2026-09-09).
    """
    if path is None:
        return "unregistered", {}

    def _apply(row: dict) -> dict:
        row.update(fields, answered_at=int(time.time() * 1000))
        row.setdefault("answered_via", "port")
        return row

    try:
        return "won", claim_and_update(path, _apply)
    except NotClaimable as e:
        print(f"formserve: already {e.state} via "
              f"{e.row.get('answered_via', 'another surface')}; not overwriting", file=sys.stderr)
        return "lost", e.row
    except (OSError, json.JSONDecodeError) as e:
        print(f"formserve: hub registry not updated ({e})", file=sys.stderr)
        return "unavailable", {}


def unanswerable_reasons(raw: str) -> list[str]:
    """Why this HTML could never record an answer. Empty list = it can.

    Written after 2026-09-17, when THREE of the day's forms were served,
    listed `open`, announced to Terrence, and could not be answered at all —
    one of them sat dead for 19 hours. Every failure was silent: the page
    rendered perfectly, so "verify it rendered" (the skill's own check) passed.
    The Send button just did nothing.

    The three real shapes, each caught below:
      1. No call to `submitAnswers()` anywhere. That call is the ENTIRE
         contract with this script — the shim below defines the function, the
         form has to invoke it. A form with a `type=submit` button and no
         handler does a native browser submit, which posts form-encoded data
         with no token and records nothing.
      2. `<button form="f">` with no `<form id="f">`. The button is associated
         with a form that does not exist, so clicking it fires no event at all,
         anywhere.
      3. `<form onsubmit="return false">` with no handler — the form actively
         cancels its own submission.

    Checked against the SOURCE file, which must never define submitAnswers
    itself (this script and the hub each inject their own), so a bare
    occurrence of the name is the page's call site.
    """
    reasons = []
    if not re.search(r"submitAnswers\s*\(", raw):
        reasons.append("nothing calls submitAnswers() — the Send button would "
                       "do a native form post, which carries no token and "
                       "records nothing")
    form_ids = set(re.findall(r"<form[^>]*\bid=[\"']([^\"']+)", raw, re.I))
    for ref in set(re.findall(r"<(?:button|input)[^>]*\bform=[\"']([^\"']+)", raw, re.I)):
        if ref not in form_ids:
            reasons.append(f"a submit control says form=\"{ref}\" but no "
                           f"<form id=\"{ref}\"> exists, so clicking it fires "
                           f"no event")
    for tag in re.findall(r"<form[^>]*>", raw, re.I):
        if re.search(r"onsubmit\s*=\s*[\"'][^\"']*return\s+false", tag, re.I) \
                and not re.search(r"submitAnswers\s*\(", raw):
            reasons.append("the <form> cancels its own submit (onsubmit=return "
                           "false) and nothing calls submitAnswers()")
    return reasons



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
    ap.add_argument("--request-id", default="",
                    help="the upstream request this form answers (herdr-action.sh's "
                         "action_requests.request_id); bound into the draft-preservation "
                         "key alongside the form's own path so two forms that happen to "
                         "share a basename never share a draft")
    ap.add_argument("--title",
                    help="record this title verbatim instead of deriving one from the page; "
                         "required to serve a page whose <title> disagrees with its first "
                         "<h1>/<h2>")
    args = ap.parse_args()

    form = Path(args.form).expanduser().resolve()
    if not form.is_file():
        print(f"formserve: no such file: {form}", file=sys.stderr)
        return 2

    # herdr-action.sh writes and answers these itself, bound to the request id
    # via claim-once (lib/run-registry.sh). A hand-served copy can collect a
    # human answer that herdr-action then correctly refuses as unbound to any
    # request -- but herdr-action.sh's OWN call on its OWN file, naming the
    # SAME request id that is still a real row in its registry, must go
    # through: that is this guard's only legitimate caller.
    if form.is_relative_to(ACTION_FORMS_DIR.resolve()) \
            and not is_herdr_actions_own_serve(form, args.request_id):
        ar_id = action_form_request_id(form)
        print(f"formserve: {form}: herdr-action serves this form itself; "
              f"use herdr-action.sh show {ar_id} for its id", file=sys.stderr)
        return 2

    raw_html = form.read_bytes()

    # Refuse to serve a form nobody can answer. A configuration error, so it
    # exits 2 like the missing-file case above rather than serving a dead page:
    # the failure this replaces was invisible — the decision appeared in the
    # inbox, rendered correctly, and silently swallowed every click.
    dead = unanswerable_reasons(raw_html.decode("utf-8", errors="replace"))
    if dead:
        print(f"formserve: {form} cannot record an answer:", file=sys.stderr)
        for reason in dead:
            print(f"  - {reason}", file=sys.stderr)
        print("  fix: give the <form> an id and add the one required script —\n"
              "       document.getElementById('f').addEventListener('submit', e => {\n"
              "         e.preventDefault();\n"
              "         const fd = new FormData(e.target);\n"
              "         window.submitAnswers({ q1: fd.get('q1'), notes: fd.get('notes') });\n"
              "       });\n"
              "  see examples/form-template.html", file=sys.stderr)
        return 2

    # The hub list shows this title; a disagreeing <title> means the <head>
    # was copied from another form's page (incident 2026-10-30) and the hub
    # would mislabel a live decision. Refuse rather than guess which one is
    # right; --title records one explicitly and skips the check.
    title, title_error = resolve_title(raw_html, form.stem, args.title)
    if title_error:
        print(f"formserve: {form}: {title_error}", file=sys.stderr)
        return 2

    # Unguessable per-run secret (see the /submit handler for why this exists)
    # — generated fresh every invocation so it cannot be reused across runs or
    # guessed from a previous one.
    token = secrets.token_urlsafe(24)
    shim = SHIM.replace("{{FORMSERVE_TOKEN}}", token) \
               .replace("{{FORMSERVE_REQUEST_ID}}",
                        html_module.escape(f"{args.request_id}:{form}", quote=True)).encode()

    # Required-field schema derived from the SOURCE markup, not the page's own
    # script — the thing that lied in the 2026-10-18 incident. Computed once,
    # used by this process's own /submit AND stored on the registry row so
    # the hub's /decisions/<id>/submit validates from the same source.
    schema = parse_schema(raw_html.decode("utf-8", errors="replace"))
    # The hub gets the PRISTINE bytes: it appends its own shim, whose
    # submitAnswers() posts to /decisions/<id>/submit. Handing it this
    # process's shimmed copy would point the hub's page at /submit on the hub,
    # which is a 404 — the form would render and then fail to send.
    html = force_dark(raw_html.decode("utf-8", errors="replace")).encode()
    lowered = html.lower()
    if b"</body>" in lowered:
        cut = lowered.rindex(b"</body>")
        html = html[:cut] + shim + html[cut:]
    else:
        html = html + shim

    result: dict = {}
    done = threading.Event()

    # 127.0.0.1, never 0.0.0.0 — see the module docstring.
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port),
                                build_handler(html, result, done, token, schema))
    port = httpd.server_address[1]
    url = f"http://127.0.0.1:{port}/"

    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    print(f"formserve: serving {form.name} at {url}", file=sys.stderr)
    registry = register_form(form, raw_html, url, port, args.timeout, title,
                             token=token, deliver_to=args.deliver or "", schema=schema,
                             request_id=args.request_id)
    result["registry"] = registry            # the handler claims against it before any 200
    # Held open for this process's entire lifetime, never closed: the kernel
    # releases the lock the instant this process exits or dies, which is what
    # lets hub.py tell "this exact run is still alive" from "a LATER,
    # unrelated run now happens to be reusing this id's port" -- a pid number
    # alone is reusable across runs, this lock is not (conductor, 2026-10-29).
    if registry is not None:
        try:
            _draft_lock_fh = open(FORMS_DIR / f"{registry.stem}.lock", "w")
            fcntl.flock(_draft_lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            print(f"formserve: liveness lock not held ({e}); this form may read as "
                  "gone sooner than it should", file=sys.stderr)

    if not args.no_open:
        open_in_pane(url)

    # Wait on BOTH surfaces. The port is one place the human can answer; the
    # hub is the other, and it writes the same record. Before this, a hub
    # answer left this process waiting out its full timeout and then printing
    # "the question is still unanswered" over a recorded human decision
    # (two-model review, 2026-09-09). Poll the record every few seconds; a
    # terminal status from anywhere ends the wait.
    deadline = None if args.timeout <= 0 else time.monotonic() + args.timeout
    hub_row: dict | None = None
    try:
        while True:
            remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
            if done.wait(timeout=5.0 if remaining is None else min(5.0, remaining)):
                break
            if registry is not None:
                try:
                    row = json.loads(registry.read_text())
                    if row.get("status") in ("answered", "expired", "withdrawn") and row.get("answered_via") != "port":
                        hub_row = row
                        break
                except (OSError, json.JSONDecodeError):
                    pass
            if remaining is not None and remaining <= 0:
                break
    except KeyboardInterrupt:
        print("formserve: interrupted", file=sys.stderr)
    finally:
        httpd.shutdown()
        httpd.server_close()

    if hub_row is not None:
        # The other surface recorded the outcome. Report THAT - it is the human's
        # decision - and deliver it, exactly as if it had arrived here.
        if hub_row.get("status") == "answered":
            answers = hub_row.get("answers") or {}
            print(f"formserve: answered via {hub_row.get('answered_via', 'hub')}; delivering that answer",
                  file=sys.stderr)
            print(json.dumps(answers, indent=2, sort_keys=True))
            if args.deliver:
                deliver(args.deliver, url, answers)
            return 0
        if hub_row.get("status") == "withdrawn":
            # herdr-action.sh withdrew the request (its task ended first).
            # Stop serving live radio buttons for a question nobody can act on.
            print(f"formserve: withdrawn, not answered ({hub_row.get('withdrawn_reason', 'no reason recorded')})",
                  file=sys.stderr)
            return 1
        print("formserve: the hub recorded this form as EXPIRED; still unanswered.", file=sys.stderr)
        return 1

    if not done.is_set():
        # Word this carefully. "No answers submitted" reads as "the human
        # declined", and an agent acting on that would proceed as if it had an
        # answer it does not have. The form EXPIRED; nobody said anything.
        outcome, row = update_form(registry, status="expired")
        if outcome == "lost" and row.get("status") == "answered":
            # Answered elsewhere in the last few seconds: a real decision beats
            # our expiry, and record_store already refused to overwrite it.
            answers = row.get("answers") or {}
            print(json.dumps(answers, indent=2, sort_keys=True))
            if args.deliver:
                deliver(args.deliver, url, answers)
            return 0
        print(f"formserve: form EXPIRED after {args.timeout}s with no submission. "
              f"This is not a decline — the page stopped being reachable and the "
              f"question is still unanswered. Re-serve it, or raise --timeout.",
              file=sys.stderr)
        return 1

    # The handler already claimed the record under lock before it sent the 200;
    # result["answers"] is therefore the persisted winner, never a loser.
    answers = result.get("answers", {})
    print(json.dumps(answers, indent=2, sort_keys=True))
    if args.deliver:
        deliver(args.deliver, url, answers)
    return 0


if __name__ == "__main__":
    sys.exit(main())
