#!/usr/bin/env python3
"""Slack -> herdr reply bridge.

Lets you answer the orchestrator (or any worker) from Slack: reply in the bridge
channel and it lands in the right herdr agent. Outbound notifications already work
(OMC/OMX walk profile); this is the missing inbound leg.

How a message is routed:
  - "w8:p2 <text>"  -> that pane/tab id gets <text>
  - "<text>"         -> the single currently-BLOCKED agent (what the orch is
                        waiting on). If 0 or >1 are blocked, it says so and asks
                        you to name a pane.
Delivery goes through herdr-deliver.sh -> send-to-agent.sh (robust submit).

Security: fail-closed. Requires an allowlist of Slack user ids
(HERDR_BRIDGE_ALLOW_USERS); messages from anyone else are ignored. Optionally
restrict to one channel (HERDR_BRIDGE_CHANNEL).

Env:
  SLACK_BOT_TOKEN            xoxb-...  (bot token; scope chat:write + read)
  SLACK_APP_TOKEN            xapp-...  (app-level token; scope connections:write)
  HERDR_BRIDGE_ALLOW_USERS   U0123,U0456   (REQUIRED — comma-separated Slack user ids)
  HERDR_BRIDGE_CHANNEL       C0789     (optional — only handle this channel)

Run via run-bridge.sh (which sources tokens from 1Password). Needs slack_bolt
(pip install -r requirements.txt).
"""
import json
import os
import re
import subprocess
import sys

try:
    from slack_bolt import App
    from slack_bolt.adapter.socket_mode import SocketModeHandler
except ImportError:
    sys.exit("slack_bolt not installed — pip install -r requirements.txt (in a venv)")

DELIVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "herdr-deliver.sh")
REGISTRY = os.path.join(
    os.environ.get("HERDR_BRIDGE_STATE", os.path.expanduser("~/.config/herdr-bridge")),
    "registry.jsonl",
)
TARGET_RE = re.compile(r"^\s*(w[0-9A-Za-z]+:[pt][0-9]+)\s+(.*)$", re.S)
MENTION_RE = re.compile(r"^\s*<@[^>]+>\s*")


def pane_for_thread(thread_ts):
    """A reply threaded under an alert routes to that alert's pane (herdr-notify
    recorded ts->pane). Last match wins."""
    if not thread_ts:
        return None
    try:
        with open(REGISTRY) as f:
            lines = f.readlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("ts") == thread_ts:
            return rec.get("pane")
    return None

ALLOW = {u.strip() for u in os.environ.get("HERDR_BRIDGE_ALLOW_USERS", "").split(",") if u.strip()}
CHANNEL = os.environ.get("HERDR_BRIDGE_CHANNEL", "").strip()
if not ALLOW:
    sys.exit("refusing to start: set HERDR_BRIDGE_ALLOW_USERS to a comma-separated allowlist of Slack user ids")

app = App(token=os.environ["SLACK_BOT_TOKEN"])


def deliver(target, text):
    """Call herdr-deliver.sh; return (ok, message)."""
    try:
        r = subprocess.run(
            ["bash", DELIVER, target, text],
            capture_output=True, text=True, timeout=45,
        )
    except subprocess.TimeoutExpired:
        return False, "herdr-deliver timed out"
    out = (r.stdout + r.stderr).strip().splitlines()
    msg = out[-1] if out else f"exit {r.returncode}"
    return r.returncode == 0, msg


@app.event("message")
def on_message(event, say, logger):
    if event.get("subtype") or event.get("bot_id"):
        return  # edits/joins/bot echoes
    user = event.get("user", "")
    if user not in ALLOW:
        logger.info("ignoring message from unauthorized user %s", user)
        return
    if CHANNEL and event.get("channel") != CHANNEL:
        return

    raw = MENTION_RE.sub("", event.get("text", "")).strip()
    if not raw:
        return
    reply_ts = event.get("ts")
    thread_ts = event.get("thread_ts")  # present only on a threaded reply

    # Routing precedence:
    #   1) reply threaded under an alert -> that alert's pane (registry)
    #   2) explicit "w8:p2 <text>" prefix
    #   3) the single blocked agent
    target = pane_for_thread(thread_ts)
    text = raw
    if target is None:
        m = TARGET_RE.match(raw)
        if m:
            target, text = m.group(1), m.group(2).strip()
        else:
            target = "--blocked"
    if not text:
        say(text=":warning: empty message, nothing sent", thread_ts=thread_ts or reply_ts)
        return

    ok, info = deliver(target, text)
    icon = ":white_check_mark:" if ok else ":warning:"
    say(text=f"{icon} {info}", thread_ts=thread_ts or reply_ts)


if __name__ == "__main__":
    print(f"herdr bridge up — allowlist={sorted(ALLOW)} channel={CHANNEL or 'any'} deliver={DELIVER}", flush=True)
    SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()
