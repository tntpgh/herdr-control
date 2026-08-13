#!/usr/bin/env bash
# run.sh — unattended Gmail triage sentinel for tnt@teamthurber.com.
#
# Plain `claude -p` (Claude Code CLI), deliberately NOT routed through OMC
# skills/hooks — this must keep working independent of the oh-my-claudecode
# layer. Locked down the same way knowledge-base/server/agent_runner.py locks
# its KB sentinels down, learned from that codebase's own hard lesson (run
# 3025: an allow-list alone did not hold, because `claude -p` inherits the
# operator's ~/.claude.json permissions unless you strip them):
#   1. --strict-mcp-config + a generated, single-server MCP config — never
#      inherits any other configured MCP server or credential.
#   2. --allowed-tools names EXACTLY four Gmail tools, one of them a mutator
#      (batch_modify_gmail_message_labels — archive/mark-read only; the
#      prompt is told never to add the TRASH label and there is no delete/
#      send/draft tool in the allow-list at all).
#   3. --disallowed-tools denies Bash/Edit/Write/Task/WebFetch/Skill outright
#      — the authoritative lock for built-ins, per agent_runner.py's finding
#      that a deny-list is what actually holds, not the allow-list.
#   4. --permission-mode dontAsk — executes only the allow-listed tools, denies
#      everything else with no prompt (an unattended run must never hang
#      waiting on a human).
#
# Secrets: only OP_SERVICE_ACCOUNT_TOKEN needs to reach this script (via the
# launchd plist's EnvironmentVariables) — everything else is `op read` at
# run time, never baked in.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/gmail-triage.log"
mkdir -p "$LOG_DIR"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(_ts)" "$*" >>"$LOG_FILE"; }

log "=== gmail-triage run.sh starting ==="

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  log "FATAL: OP_SERVICE_ACCOUNT_TOKEN not set in environment — cannot read secrets, refusing to run."
  exit 1
fi

GOOGLE_OAUTH_CLIENT_ID="$(op read 'op://secrets/google-workspace-oauth-client-id/credential' 2>>"$LOG_FILE")"
GOOGLE_OAUTH_CLIENT_SECRET="$(op read 'op://secrets/google-workspace-oauth-client-secret/credential' 2>>"$LOG_FILE")"
if [ -z "$GOOGLE_OAUTH_CLIENT_ID" ] || [ -z "$GOOGLE_OAUTH_CLIENT_SECRET" ]; then
  log "FATAL: could not read Google OAuth client id/secret from 1Password — refusing to run."
  exit 1
fi

UVX_BIN="$(command -v uvx || echo /opt/homebrew/bin/uvx)"
if [ ! -x "$UVX_BIN" ]; then
  log "FATAL: uvx not found — cannot start workspace-mcp."
  exit 1
fi

CFG="$(mktemp "${TMPDIR:-/tmp}/gmail-triage-mcp.XXXXXX.json")"
chmod 600 "$CFG"
cat >"$CFG" <<EOF
{
  "mcpServers": {
    "google-workspace": {
      "command": "$UVX_BIN",
      "args": ["workspace-mcp", "--tool-tier", "complete"],
      "env": {
        "GOOGLE_OAUTH_CLIENT_ID": "$GOOGLE_OAUTH_CLIENT_ID",
        "GOOGLE_OAUTH_CLIENT_SECRET": "$GOOGLE_OAUTH_CLIENT_SECRET",
        "OAUTHLIB_INSECURE_TRANSPORT": "1",
        "USER_GOOGLE_EMAIL": "tnt@teamthurber.com"
      }
    }
  }
}
EOF

ALLOWED_TOOLS="mcp__google-workspace__search_gmail_messages,mcp__google-workspace__get_gmail_messages_content_batch,mcp__google-workspace__get_gmail_thread_content,mcp__google-workspace__batch_modify_gmail_message_labels"
DISALLOWED_TOOLS="Bash,Edit,Write,Task,WebFetch,Skill,NotebookEdit"
MODEL="${GMAIL_TRIAGE_MODEL:-claude-sonnet-4-5}"
TIMEOUT_S="${GMAIL_TRIAGE_TIMEOUT_S:-1500}"

CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
if [ ! -x "$CLAUDE_BIN" ]; then
  log "FATAL: claude CLI not found on PATH."
  rm -f "$CFG"
  exit 1
fi

PROMPT="$(cat "$HERE/triage-prompt.md")"
PROMPT="${PROMPT//\{\{DATE\}\}/$(date +%Y-%m-%d)}"

TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || echo /opt/homebrew/opt/coreutils/libexec/gnubin/timeout)"
log "invoking claude -p (model=$MODEL timeout=${TIMEOUT_S}s, timeout_bin=$TIMEOUT_BIN)"
REPORT="$("$TIMEOUT_BIN" "$TIMEOUT_S" "$CLAUDE_BIN" -p "$PROMPT" \
  --model "$MODEL" \
  --strict-mcp-config --mcp-config "$CFG" \
  --allowed-tools "$ALLOWED_TOOLS" \
  --disallowed-tools "$DISALLOWED_TOOLS" \
  --permission-mode dontAsk 2>>"$LOG_FILE")"
RC=$?
rm -f "$CFG"   # holds the OAuth client secret — never leave it on disk

{
  echo "--- report ($(_ts)) exit=$RC ---"
  echo "$REPORT"
  echo "--- end report ---"
} >>"$LOG_FILE"

if [ "$RC" -ne 0 ] || [ -z "$REPORT" ]; then
  log "run FAILED (exit=$RC, empty=$([ -z "$REPORT" ] && echo yes || echo no))"
  NOTIFY_TEXT="gmail-triage FAILED (exit=$RC) — check $LOG_FILE"
else
  log "run OK"
  NOTIFY_TEXT="$REPORT"
fi

# Slack delivery — plain herdr-notify.sh (NOT an OMC hook), so this keeps
# working with OMC absent or removed. Best-effort: a notify failure must not
# make the triage itself look like it failed.
if [ -f "$HOME/.config/herdr-bridge.env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.config/herdr-bridge.env"
  bash "$HOME/Code/herdr-control/slack-bridge/herdr-notify.sh" "$NOTIFY_TEXT" >>"$LOG_FILE" 2>&1 \
    || log "WARNING: slack notify failed (non-fatal, see log above)"
else
  log "WARNING: no ~/.config/herdr-bridge.env — skipped Slack notify"
fi

log "=== gmail-triage run.sh done (exit=$RC) ==="
exit "$RC"
