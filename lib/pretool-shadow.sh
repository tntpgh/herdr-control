#!/usr/bin/env bash
# lib/pretool-shadow.sh — the hook-time verdict for one worker tool call.
#
# Design: docs/design/pretool-approval.md. Today a registered worker's tool
# call reaches a decision through omp's approval menu, a screen scrape, a
# prompt_id correlation and a keypress. The target is for the omp `tool_call`
# hook to decide on the EXACT input instead. This file computes that decision
# with the SAME policy the menu path uses (lib/scoped-policy.sh peer_decide ->
# lib/command-policy.sh + lib/task-manifest.sh + the #3b grant + code by
# reference). It is not a second classifier: every shell verdict comes from
# peer_decide, and the only rules written here are the per-TOOL table (which
# tools are shell, which are file writes #159 already contains, which are
# switched off for workers).
#
# SHADOW MODE ONLY. agent-hooks/omp-herdr-control.ts runs this detached, after
# the existing guards have already returned, and ignores the result: nothing
# here can block, allow, or change a current approval outcome. The verdict is
# appended to the registry as a `pretool_verdict` event so
# scripts/shadow-compare.sh can measure it against what the menu path actually
# did.
#
# Usage: pretool-shadow.sh [--record]   (payload JSON on stdin)
#   payload: {tool, call_id, input, cwd, guard_block, t0_ms}
#     guard_block: the reason string of a block the hook's existing guards
#                  (pretool-registration, #159 write scope) returned, or null.
#     t0_ms:       Date.now() when the hook fired, for latency accounting.
#   identity: HERDR_TASK_ID, HERDR_RUN_ID, HERDR_PANE_ID — the hook passes the
#             values it captured at module load, never a later process.env.
# Prints ONE JSON line: {verdict, policy, reason, authority, ...}.
# Exit 0 when the verdict is `allow`, 8 otherwise (the future enforcing hook's
# contract; the shadow hook discards it). --record also appends the event.
#
# Verdicts: allow | escalate (a conductor may review) | reserved (human-only) |
#           deny (classifier deny; nobody approves) | block (tool off for
#           workers, identity unproven, or an existing guard blocked it).
#
# Secrets: tool input can carry tokens. The event never stores raw input: it
# stores sha256 digests of the exact input and command, and for bash a
# redacted, length-capped copy of the command (withheld entirely when the
# policy itself says it carries a credential). File contents are never stored.
#
# Not a containment boundary (docs/approval-policy.md rule 7): a same-user
# process can write the registry and the files judged here.
set -uo pipefail

_ps_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ps_dir/scoped-policy.sh"
. "$_ps_dir/pane-guard.sh"

PS_CMD_CAP=2000

# Same shapes smart-name.sh strips from pane scrapes before they leave the
# machine, plus private-key blocks and URL userinfo.
pretool_redact() {                      # text -> redacted, capped text
  printf '%s' "$1" | LC_ALL=C sed -E \
    's/(sk|rk|pk)-[A-Za-z0-9_-]{16,}/[redacted-key]/g;
     s/(gh[posru]|xox[baprs]|github_pat)[-_][A-Za-z0-9_]{16,}/[redacted-token]/g;
     s/AKIA[0-9A-Z]{12,}/[redacted-aws]/g;
     s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[redacted-jwt]/g;
     s/[Bb]earer[[:space:]]+[A-Za-z0-9._~+\/=-]{8,}/Bearer [redacted]/g;
     s#(://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[redacted]@#g;
     s/-----BEGIN [A-Z ]*PRIVATE KEY-----/[redacted-private-key]/g;
     s/(([Aa]pi[_-]?[Kk]ey|[Tt]oken|[Pp]assword|[Pp]asswd|[Ss]ecret|[Cc]redential)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1[redacted]/g' \
    | head -c "$PS_CMD_CAP"
}

_ps_sha() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

_ps_now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null; }

# ---- identity: fail closed ---------------------------------------------------
# Sets PS_TASK_JSON on success; on failure sets PS_VERDICT=block PS_POLICY=identity.
_ps_identity() {
  PS_TASK_JSON=""
  local st reg_pane reg_birth live
  _ps_id_fail() { PS_VERDICT=block PS_POLICY=identity PS_REASON="identity: $1"; return 1; }
  [ -n "${HERDR_TASK_ID:-}" ] || _ps_id_fail "HERDR_TASK_ID is not set" || return 1
  [ -n "${HERDR_RUN_ID:-}" ] || _ps_id_fail "HERDR_TASK_ID is set but HERDR_RUN_ID is not" || return 1
  [ -n "${HERDR_PANE_ID:-}" ] || _ps_id_fail "HERDR_PANE_ID is not set" || return 1
  if ! registry_init >/dev/null 2>&1; then
    PS_REGISTRY_OK=0; _ps_id_fail "registry unreadable ($(registry_db))"; return 1
  fi
  PS_TASK_JSON="$(read_task "$HERDR_RUN_ID" "$HERDR_TASK_ID" 2>/dev/null)" || PS_TASK_JSON=""
  if [ -z "$PS_TASK_JSON" ]; then _ps_id_fail "no registry row for $HERDR_RUN_ID/$HERDR_TASK_ID"; return 1; fi
  st="$(printf '%s' "$PS_TASK_JSON" | jq -r '.state // empty' 2>/dev/null)"
  case "$st" in
    starting|running|blocked) ;;
    *) _ps_id_fail "task state is '${st:-unknown}', not active"; return 1 ;;
  esac
  reg_pane="$(printf '%s' "$PS_TASK_JSON" | jq -r '.pane_id // empty' 2>/dev/null)"
  reg_birth="$(printf '%s' "$PS_TASK_JSON" | jq -r '.pane_birth // empty' 2>/dev/null)"
  if [ "$reg_pane" != "$HERDR_PANE_ID" ]; then
    _ps_id_fail "pane $HERDR_PANE_ID is not the registered pane ${reg_pane:-<none>}"; return 1
  fi
  [ -n "$reg_birth" ] || _ps_id_fail "registry row has no pane_birth" || return 1
  live="$(pane_birth_now "$HERDR_PANE_ID" 2>/dev/null)"
  [ -n "$live" ] || _ps_id_fail "pane generation unverifiable (herdr pane list has no $HERDR_PANE_ID)" || return 1
  [ "$live" = "$reg_birth" ] || _ps_id_fail "pane $HERDR_PANE_ID was recycled (registered $reg_birth, live $live)" || return 1
  return 0
}

# ---- the per-tool table ------------------------------------------------------
# Device names reached as `write xd://<dev>`, as a tool named `xd_<dev>`, or as
# a bare tool name. Sets PS_VERDICT/PS_POLICY/PS_REASON.
_ps_device() {                          # device-name
  case "$1" in
    notepad_append|notepad_priority|ast_edit|lsp)
      PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="file mutation; worktree containment enforced by the #159 write-scope guard" ;;
    notepad_read|notepad_stats|fleet_status|pr_ready|handoff_debt|single_copy_scan|worktree_debt|suite_wired|decisions_open|project_status|recall|reflect|retain|report_issue)
      PS_VERDICT=allow PS_POLICY=tool-table PS_REASON="read-only or session-memory device" ;;
    secret_present)
      PS_VERDICT=reserved PS_POLICY=tool-table PS_REASON="credential access remains human-only; workers hold no credentials" ;;
    memory_edit)
      PS_VERDICT=block PS_POLICY=tool-table PS_REASON="memory curation (forget/invalidate) is the conductor's; send the correction to your conductor" ;;
    debug|browser|computer)
      PS_VERDICT=block PS_POLICY=tool-table PS_REASON="$1 runs or drives processes with no text the policy can judge; disabled for workers — use a script file run via bash" ;;
    *)
      PS_VERDICT=escalate PS_POLICY=tool-table PS_REASON="unknown device '$1': a conductor must review it" ;;
  esac
}

# Read-side path check: a credential path the ONE reserved list recognises is
# human-only through the read tool too. Only the credential class is taken from
# conductor_reserved_reason: its policy-filename rules are about EDITING those
# files and would make reading them reserved (backlog iii).
_ps_read_paths() {                      # input-json
  local p r
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      ssh://*|SSH://*)
        PS_VERDICT=block PS_POLICY=tool-table PS_REASON="remote host access (ssh://) is not in a worker's scope; ask your conductor"; return ;;
      *://*) continue ;;
    esac
    r="$(conductor_reserved_reason "cat -- $p" 2>/dev/null)"
    case "$r" in
      credential*) PS_VERDICT=reserved PS_POLICY=command-policy PS_REASON="$r (read of $p)"; return ;;
    esac
  done < <(printf '%s' "$1" | jq -r '[.path?, .file_path?, .paths?[]?, .pattern_path?] | map(select(type=="string")) | .[]' 2>/dev/null)
}

_ps_bash() {                            # command
  local cmd="$1"
  PS_POLICY=command-policy
  peer_decide "$cmd" "$PS_TASK_JSON"
  PS_VERDICT="$PD_VERDICT" PS_REASON="$PD_REASON" PS_AUTHORITY="$PD_AUTHORITY"
  PS_CODE_PATH="${PD_CODE_PATH:-}" PS_CODE_SHA="${PD_CODE_SHA:-}"
  case "$PS_VERDICT" in allow|escalate|reserved|deny) ;; *) PS_VERDICT=escalate ;; esac
}

pretool_decide() {                      # payload-json -> sets PS_* ; 0 allow, 8 not
  local payload="$1" tool norm input guard dev cmd op
  PS_VERDICT=escalate PS_POLICY=tool-table PS_REASON="" PS_AUTHORITY="" PS_REGISTRY_OK=1
  PS_CODE_PATH="" PS_CODE_SHA="" PS_CMD="" PS_TOOL=""
  tool="$(printf '%s' "$payload" | jq -r '.tool // empty' 2>/dev/null)"
  input="$(printf '%s' "$payload" | jq -c '.input // {}' 2>/dev/null)"; [ -n "$input" ] || input='{}'
  guard="$(printf '%s' "$payload" | jq -r '.guard_block // empty' 2>/dev/null)"
  PS_TOOL="$tool"
  norm="$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')"
  case "$norm" in bash|shell) PS_CMD="$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null)" ;; esac

  _ps_identity || return 8
  if [ -n "$guard" ]; then
    PS_VERDICT=block PS_POLICY=hook-guard PS_REASON="$guard"; return 8
  fi

  case "$norm" in
    bash|shell)
      if [ -z "${PS_CMD//[[:space:]]/}" ]; then
        PS_VERDICT=block PS_REASON="bash call with no command"
      else
        _ps_bash "$PS_CMD"
      fi ;;
    eval|python|js|javascript|repl|notebook_eval)
      PS_VERDICT=block PS_REASON="eval runs arbitrary code with no text the policy can judge; disabled for workers — write the code to a file under your worktree and run it via bash (code by reference)" ;;
    write)
      case "$(printf '%s' "$input" | jq -r '.path // empty' 2>/dev/null)" in
        xd://*|XD://*)
          dev="$(printf '%s' "$input" | jq -r '.path' | sed -E 's#^[xX][dD]://##; s#[/?].*$##')"
          _ps_device "$dev" ;;
        *) PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="file write; worktree containment enforced by the #159 write-scope guard" ;;
      esac ;;
    edit|ast_edit|multiedit|notebook|notebook_edit|apply_patch|lsp)
      PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="file mutation; worktree containment enforced by the #159 write-scope guard" ;;
    read|grep|glob|find|ast_grep|search)
      PS_VERDICT=allow PS_REASON="read-only tool"
      _ps_read_paths "$input" ;;
    todo|wait|ask|checkpoint|rewind|hub|resolve|web_search|security_scan|learn|new_context|context_notes|taskoutput|taskget|tasklist|bashoutput)
      PS_VERDICT=allow PS_REASON="no host side effect beyond this session" ;;
    github)
      op="$(printf '%s' "$input" | jq -r '.op // empty' 2>/dev/null)"
      case "$op" in
        repo_view|file_read|search_*|run_watch) PS_VERDICT=allow PS_REASON="github read op $op" ;;
        *) PS_VERDICT=block PS_REASON="github op '${op:-?}' mutates; use bash git/gh so command-policy and the ownership grant judge the exact command" ;;
      esac ;;
    browser|computer|debug|generate_image|tts|ida|manage_skill|memory_edit|secret_present)
      _ps_device "$norm"
      case "$norm" in
        generate_image|tts) PS_VERDICT=block PS_REASON="$norm spends money on a paid API; new spending is human-only" ;;
        ida|manage_skill) PS_VERDICT=block PS_REASON="$norm is not a worker tool (skills are shared config; ask your conductor)" ;;
      esac ;;
    xd_*)
      _ps_device "${norm#xd_}" ;;
    notepad_append|notepad_priority|notepad_read|notepad_stats|fleet_status|pr_ready|handoff_debt|single_copy_scan|worktree_debt|suite_wired|decisions_open|project_status|recall|reflect|retain|report_issue)
      _ps_device "$norm" ;;
    mcp__*)
      PS_VERDICT=allow PS_REASON="read-only MCP observer (the registration guard blocks every other MCP tool)" ;;
    *)
      PS_VERDICT=escalate PS_REASON="unknown tool '$tool': a conductor must review it" ;;
  esac
  [ "$PS_VERDICT" = allow ] && return 0
  return 8
}

pretool_payload_json() {                # payload-json elapsed-ms -> event/stdout JSON
  local payload="$1" elapsed="$2" cmd_store="" cmd_sha="" in_sha
  in_sha="$(_ps_sha "$(printf '%s' "$payload" | jq -c '.input // {}' 2>/dev/null)")"
  if [ -n "$PS_CMD" ]; then
    cmd_sha="$(_ps_sha "$PS_CMD")"
    case "$PS_REASON" in
      credential*|*"credential-value"*) cmd_store="[withheld: the policy says this command carries or resolves a credential]" ;;
      *) cmd_store="$(pretool_redact "$PS_CMD")" ;;
    esac
  fi
  jq -nc --arg tool "$PS_TOOL" --arg call "$(printf '%s' "$payload" | jq -r '.call_id // empty' 2>/dev/null)" \
    --arg v "$PS_VERDICT" --arg pol "$PS_POLICY" --arg r "$(pretool_redact "$PS_REASON")" --arg auth "$PS_AUTHORITY" \
    --arg cmd "$cmd_store" --arg csha "$cmd_sha" --arg isha "$in_sha" \
    --arg cwd "$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)" \
    --arg pane "${HERDR_PANE_ID:-}" --arg cp "$PS_CODE_PATH" --arg cs "$PS_CODE_SHA" --arg el "$elapsed" \
    '{schema:1, mode:"shadow", tool:$tool, call_id:$call, verdict:$v, policy:$pol, reason:$r,
      authority:$auth, command:$cmd, command_sha256:$csha, input_sha256:$isha, cwd:$cwd, pane:$pane,
      code_path:$cp, code_sha256:$cs, elapsed_ms:(($el|tonumber?) // null)}'
}

pretool_shadow_main() {
  local record=0 payload rc t0 now elapsed="" out eid call
  [ "${1:-}" = --record ] && record=1
  payload="$(cat)"
  printf '%s' "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || payload='{}'
  pretool_decide "$payload"; rc=$?
  t0="$(printf '%s' "$payload" | jq -r '.t0_ms // empty' 2>/dev/null)"
  now="$(_ps_now_ms)"
  case "$t0$now" in ''|*[!0-9]*) ;; *) [ -n "$t0" ] && [ -n "$now" ] && elapsed=$((now - t0)) ;; esac
  out="$(pretool_payload_json "$payload" "$elapsed")"
  printf '%s\n' "$out"
  if [ "$record" = 1 ] && [ "${PS_REGISTRY_OK:-1}" = 1 ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    call="$(printf '%s' "$payload" | jq -r '.call_id // empty' 2>/dev/null)"
    eid=""
    [ -n "$call" ] && eid="ptv_${HERDR_TASK_ID}_$(_ps_sha "$call" | cut -c1-16)"
    append_event "${HERDR_RUN_ID:-}" "$HERDR_TASK_ID" pretool_verdict "$out" "$eid" >/dev/null 2>&1 || true
  fi
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pretool_shadow_main "$@"
  exit $?
fi
