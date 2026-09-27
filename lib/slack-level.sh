#!/usr/bin/env bash
# slack-level.sh — which alerts are allowed to reach Slack.
#
# Provides: slack_level                       -> all | errors | off
#           slack_should_send <class>         0 = post it, 1 = suppress it
#           slack_log_suppressed <class> <level> <pane> <text>
#
# Why (2026-09-26, operator request): Slack got a message for nearly every
# worker prompt that needed input, and the conductor or a peer resolves almost
# all of them without a person. Measured over the 7 days before this change:
# 3216 blocked episodes, 3125 (97%) resolved within 90s, 19 still open after
# 15 minutes. A channel that fires on the 97% hides the 19. So Slack now gets
# only ERROR classes — situations the automation cannot fix itself — and
# everything else stays on the hub (127.0.0.1:8600) and in the registry, with
# one local log line per suppressed send so nothing disappears silently.
#
# Every call to slack-bridge/herdr-notify.sh passes `--class <name>`:
#
#   ERROR (posted at level `errors`, the default)
#     human-stale    a prompt only a human may answer, still open after
#                    HERDR_HUMAN_ALERT_S (default 300s)
#     stuck          a worker still blocked on the same prompt after
#                    HERDR_STUCK_ALERT_S (default 900s)
#     wake-fail      the conductor wake failed delivery and the prompt is still
#                    open after HERDR_WAKE_FAIL_ALERT_S (lib/push-wake.sh)
#     control-plane  the hub's herdr subscription is down (hub-connection-alert.sh)
#     deploy         a deploy is overdue past the drift threshold (deploy-drift-alert.sh)
#     unwatched      a prompt from a session with no herdr pane (claude-notify.sh
#                    without HERDR_PANE_ID): no conductor, edge or re-check can
#                    see it, so a person is the only resolver
#     crash          reserved for a component reporting its own crash
#     human-action   a hook-approval worker's human-only action request
#                    (herdr-action.sh tick, docs/design/pretool-approval.md): one
#                    post per request; the decision itself is a hub form
#
#   NOT AN ERROR (suppressed at `errors`, logged)
#     needs-input    a prompt the conductor/peer path is expected to answer
#     held           an allow-class prompt that outlived the peer grace window
#     info           anything informational
#     (none)         an unclassified call — logged as `unclassified`
#
# Any OTHER non-empty class is treated as an error and posted. A typo in a
# class name must fail toward the operator hearing about it, never toward
# silence; only the explicit non-error names above (and a missing class) are
# suppressed.
#
# Level, from HERDR_SLACK_LEVEL (env, else config.sh, else `errors`):
#   errors  error classes only (default)
#   all     every call posts — the pre-2026-09-26 behaviour
#   off     nothing posts; every call is logged as suppressed
# An unrecognised value falls back to `errors`, never to `off`.
[ -n "${_HERDR_SLACK_LEVEL_SH:-}" ] && return 0
_HERDR_SLACK_LEVEL_SH=1
_sl_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

slack_level() {
  local lvl="${HERDR_SLACK_LEVEL:-}"
  # config.sh is read in a SUBSHELL: sourcing it here would also rewrite PATH
  # and HERDR_MAIN_PANE_ID in whichever hook sourced this file.
  [ -n "$lvl" ] || lvl="$( . "$_sl_root/config.sh" >/dev/null 2>&1; printf '%s' "${HERDR_SLACK_LEVEL:-}" )"
  case "$lvl" in
    all|errors|off) printf '%s\n' "$lvl" ;;
    *) printf 'errors\n' ;;
  esac
}

slack_class_is_error() {
  case "${1:-}" in
    ''|needs-input|held|info) return 1 ;;
    *) return 0 ;;
  esac
}

slack_should_send() {
  case "$(slack_level)" in
    all) return 0 ;;
    off) return 1 ;;
    *)   slack_class_is_error "${1:-}" ;;
  esac
}

slack_suppressed_log() {
  printf '%s/slack-suppressed.jsonl\n' "${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"
}

slack_log_suppressed() {
  local class="${1:-}" level="$2" pane="$3" text="$4" log
  log="$(slack_suppressed_log)"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg class "${class:-unclassified}" \
     --arg level "$level" --arg pane "$pane" --arg text "${text:0:300}" \
     '{at:$at,class:$class,level:$level,pane:$pane,text:$text}' >> "$log" 2>/dev/null || true
  if [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$log" > "$log.trim" 2>/dev/null && mv "$log.trim" "$log" 2>/dev/null || true
  fi
}
