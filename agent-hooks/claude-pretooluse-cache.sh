#!/usr/bin/env bash
# claude-pretooluse-cache.sh — PreToolUse -> cache {tool, input, ts} keyed by
# session_id, so claude-notify.sh's Notification handler can show WHAT is
# being approved, not just THAT something needs approval.
#
# Why a separate hook instead of teaching claude-notify.sh to read tool
# details itself: Claude Code's Notification event fires with only
# {session_id, message, title, cwd} on stdin — no tool_name/tool_input at
# all. PreToolUse is the only event that carries them, and it fires
# immediately before the SAME permission check that (when permission is
# required) triggers Notification next for that identical call. Caching here
# and reading there in claude-notify.sh recovers what the single Notification
# payload is missing, without guessing at UI text or scraping the pane.
#
# Deliberately dumb: one small file per session, overwritten every call, no
# aggregation, best-effort pruning of finished-session leftovers. Must never
# block or fail the tool call it fires for (PreToolUse hooks that error can
# block the tool) — reads stdin, writes best-effort, always exits 0.
set -uo pipefail

input="$(cat 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$session_id" ] || exit 0

dir="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}/last-tool"
mkdir -p "$dir" 2>/dev/null || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
tool_input="$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null || printf '{}')"
now=$(date +%s)

# Write-then-rename: claude-notify.sh reads this concurrently from another
# hook invocation, and a half-written file read mid-`jq` would just fail
# closed (empty summary) — but there is no reason to risk it when a rename is
# free.
jq -cn --arg tool "$tool_name" --argjson input "$tool_input" --argjson ts "$now" \
  '{tool: $tool, input: $input, ts: $ts}' >"$dir/$session_id.json.tmp" 2>/dev/null \
  && mv -f "$dir/$session_id.json.tmp" "$dir/$session_id.json" 2>/dev/null

# Best-effort hygiene: prune caches from sessions that finished a day+ ago —
# cheap, and keeps this directory from growing unbounded across months.
find "$dir" -maxdepth 1 -name '*.json' -mtime +1 -delete 2>/dev/null || true

exit 0
