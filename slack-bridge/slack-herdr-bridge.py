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
  HERDR_BRIDGE_TEAM          T0123     (STRONGLY recommended — bind the allowlist
                                        to one workspace; member ids are unique
                                        per workspace, not globally)
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

# Delivery/answering scripts are resolved RELATIVE TO THIS FILE, then allowed to
# be overridden by env. The relative default is what makes a plain checkout work
# with no configuration; the override exists because this repo is also shipped as
# an APM-managed skill copy under ~/.claude/skills/herdr-ops/, and whichever copy
# launchd happens to point at is the copy whose scripts run.
#
# That bit us for real (2026-08-01): the LaunchAgent pointed at the APM copy, so
# every Slack reply was answered by ITS herdr-select.sh — which predated the
# command-policy gate and the three-phase approval records. Outbound alerts came
# from this checkout while inbound replies came from the other copy, and nothing
# anywhere said so. Setting HERDR_DELIVER_BIN/HERDR_SELECT_BIN lets an operator
# point a daemon at a specific checkout without editing an APM-managed file,
# which hand-edits would lose on the next `apm update` anyway.
DELIVER = os.environ.get("HERDR_DELIVER_BIN") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "herdr-deliver.sh")
STATE_DIR = os.environ.get("HERDR_BRIDGE_STATE", os.path.expanduser("~/.config/herdr-bridge"))
# Other components in this repo (herdr-notify.sh, herdr-select.sh) `mkdir -p`
# this directory before writing to it, so its mode ends up wherever the calling
# process's umask happens to leave it — permissive by default unless that
# umask is already 077. registry.jsonl/pending.jsonl/selections.jsonl here map
# Slack thread timestamps and authorised choices to live agent panes, so a
# co-resident local user who can read or write it can hijack reply routing
# regardless of which script's umask was in effect when the dir was first
# created. This daemon reads from the same directory, so it owns making the
# mode explicit too: create it if missing and force 0700 unconditionally,
# rather than trusting whatever mode it was already left in.
os.makedirs(STATE_DIR, exist_ok=True)
os.chmod(STATE_DIR, 0o700)
REGISTRY = os.path.join(STATE_DIR, "registry.jsonl")
TARGET_RE = re.compile(r"^\s*(w[0-9A-Za-z]+:[pt][0-9]+)\s+(.*)$", re.S)
MENTION_RE = re.compile(r"^\s*<@[^>]+>\s*")
# A reply that is nothing but a number (optionally "2." or "option 2").
CHOICE_RE = re.compile(r"^\s*(?:option\s*)?([0-9]{1,2})\.?\s*$", re.I)


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
# Slack member ids are unique per WORKSPACE, not globally. In a Slack Connect or
# shared channel, an external-org user posts under their home-org id — so a
# foreign account that happens to carry our allowlisted id would pass the only
# check we have. Binding the workspace closes that.
TEAM = os.environ.get("HERDR_BRIDGE_TEAM", "").strip()
if not ALLOW:
    sys.exit("refusing to start: set HERDR_BRIDGE_ALLOW_USERS to a comma-separated allowlist of Slack user ids")
if not TEAM:
    print("WARNING: HERDR_BRIDGE_TEAM unset — the allowlist is not bound to a workspace. "
          "Set it to your Slack team id (Txxxxxxxx) so a same-id user from another "
          "workspace cannot pass the allowlist.", file=sys.stderr, flush=True)

app = App(token=os.environ["SLACK_BOT_TOKEN"])


SELECT = os.environ.get("HERDR_SELECT_BIN") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "herdr-select.sh")


def select_option(pane, choice, via):
    """Answer a numbered prompt. ONE implementation for both the threaded-number
    route and the buttons, so a choice cannot mean different things depending on
    how it was made. herdr-select validates that the option is actually on offer
    and records it before pressing anything."""
    try:
        r = subprocess.run(
            ["bash", SELECT, pane, str(choice)],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "HERDR_SELECT_VIA": via},
        )
    except subprocess.TimeoutExpired:
        return False, "herdr-select timed out"
    out = (r.stdout + r.stderr).strip().splitlines()
    return r.returncode == 0, (out[-1] if out else f"exit {r.returncode}")


def authorized(user, team, logger, what):
    """The same gate for messages and button clicks. A button is not inherently
    trustworthy just because Slack rendered it — the payload still says who
    clicked, and that is what we check."""
    if user not in ALLOW:
        logger.info("ignoring %s from unauthorized user %s", what, user)
        return False
    # The module docstring promises fail-closed. Before this fix, `TEAM and
    # team != TEAM` only ran the workspace comparison when TEAM was truthy —
    # with TEAM unset the whole condition was falsy and execution fell through
    # to `return True`, meaning the one scenario this check exists for (a
    # Slack Connect / shared-channel user carrying our allowlisted member id
    # from a DIFFERENT workspace, per docs/AGENTS.md and SKILL.md) sailed
    # straight through with the binding silently disabled. The startup
    # warning already tells the operator why; the runtime now has to actually
    # match it: with no TEAM configured we cannot verify the workspace at
    # all, so refuse everything rather than authorize on an unverifiable
    # claim.
    if not TEAM:
        logger.warning("REFUSED %s: HERDR_BRIDGE_TEAM unset — refusing all traffic (fail closed)", what)
        return False
    if team != TEAM:
        logger.warning("REFUSED %s: team %r != HERDR_BRIDGE_TEAM %r", what, team, TEAM)
        return False
    return True


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


def message_team(event, body):
    """The workspace a message actually came from.

    `event["team"]` is author attribution and is not always present (it varies
    by message shape). Falling back to the envelope's team_id means a legitimate
    message is not silently dropped just because the inner field is missing,
    while a message we genuinely cannot attribute returns None and is refused.
    """
    return event.get("team") or event.get("user_team") or (body or {}).get("team_id")


@app.event("message")
def on_message(event, say, logger, body):
    if event.get("subtype") or event.get("bot_id"):
        return  # edits/joins/bot echoes
    # The workspace is checked BEFORE the id is trusted: same id, different team
    # is a different human. Unattributable is refused, and logged at WARNING —
    # a silent drop of a legitimate reply is indistinguishable from the bridge
    # being down, and you would have no way to tell which.
    if not authorized(event.get("user", ""), message_team(event, body), logger, "message"):
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

    # A bare number in a thread under an alert is a CHOICE, not a message. It
    # goes through herdr-select (which checks the option is really on offer and
    # records it) instead of being typed into the composer, where the digit would
    # be text and the Enter after it would accept whatever was highlighted.
    if target and CHOICE_RE.match(raw):
        ok, info = select_option(target, CHOICE_RE.match(raw).group(1), "slack-reply")
        say(text=f"{':white_check_mark:' if ok else ':warning:'} {info}",
            thread_ts=thread_ts or reply_ts)
        return

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


@app.action(re.compile(r"^herdr_choice_[0-9]+$"))
def on_choice_button(ack, body, say, logger):
    """Button route into the same selection path as a threaded number.

    Requires Interactivity to be enabled on the Slack app; until then Slack
    renders the buttons but never delivers the click, and the numbered-reply
    route is what actually works. Nothing here is load-bearing for that route.
    """
    ack()
    user = (body.get("user") or {}).get("id", "")
    team = (body.get("team") or {}).get("id") or body.get("team_id")
    if not authorized(user, team, logger, "button click"):
        return
    # HERDR_BRIDGE_CHANNEL was previously enforced only on the message path
    # (on_message) — a button click arrives as a separate Slack event with its
    # own payload shape, so that restriction never applied here, and an
    # otherwise-allowlisted user's click from outside the configured channel
    # (a DM, or a channel they were added to later) would still be honored.
    # Interactive payloads carry the channel under body["channel"]["id"]
    # rather than body["channel"] directly, so the check is shaped to match
    # that, but it is the same enforcement as the message path.
    if CHANNEL and (body.get("channel") or {}).get("id") != CHANNEL:
        return
    action = (body.get("actions") or [{}])[0]
    value = action.get("value", "")
    # value is "<pane>|<n>", written by herdr-notify. Parse defensively: it comes
    # back from Slack, so treat it as input rather than as something we know.
    pane, _, choice = value.partition("|")
    if not pane or not choice.isdigit():
        logger.warning("ignoring button with malformed value %r", value)
        return
    ok, info = select_option(pane, choice, "slack-button")
    thread_ts = (body.get("message") or {}).get("ts")
    say(text=f"{':white_check_mark:' if ok else ':warning:'} {info}", thread_ts=thread_ts)


if __name__ == "__main__":
    print(f"herdr bridge up — allowlist={sorted(ALLOW)} team={TEAM or 'ANY (unbound)'} "
          f"channel={CHANNEL or 'any'} deliver={DELIVER}", flush=True)
    SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()
