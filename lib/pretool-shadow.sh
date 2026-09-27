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
# recorded as a `pretool_verdict` row in pretool-shadow.sqlite3 (see Storage) so
# scripts/shadow-compare.sh can measure it against what the menu path actually
# did.
#
# Usage: pretool-shadow.sh [--record] [--enforce]   (payload JSON on stdin)
#   --enforce: hook-approval tasks only (see pretool_enforce below); prints
#   {decision, reason, request_id, verdict} for the hook instead of the row.
#   payload: {tool, call_id, input, cwd, guard_block, t0_ms}
#     guard_block: the reason string of a block the hook's existing guards
#                  (pretool-registration, #159 write scope) returned, or null.
#     t0_ms:       Date.now() when the hook fired, for latency accounting.
#   identity: HERDR_TASK_ID, HERDR_RUN_ID, HERDR_PANE_ID — the hook passes the
#             values it captured at module load, never a later process.env.
# Prints ONE JSON line: {verdict, policy, reason, authority, ...}.
# Exit 0 when the verdict is `allow`, 8 otherwise (the future enforcing hook's
# contract; the shadow hook discards it). --record also stores the row.
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
# Storage: the control-plane registry is READ ONLY here (identity, manifest,
# file_approvals); registry_init is never run by this file, so no shadow child
# takes a registry write lock. Verdicts go to a separate SQLite file,
# pretool-shadow.sqlite3, beside the registry (pretool_shadow_db), so a burst
# of parallel tool calls can only contend with other shadow writers — never
# with push-wake, the alert gate or herdr-select — and never enters
# events_since's window. A write that loses a lock race is dropped (shadow
# data, not a gate).
#
# Not a containment boundary (docs/approval-policy.md rule 7): a same-user
# process can write the registry and the files judged here.
set -uo pipefail

_ps_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ps_dir/scoped-policy.sh"
. "$_ps_dir/pane-guard.sh"
. "$_ps_dir/action-request.sh"

# Hook-approval reservations join the ONE policy through its own operator-rule
# channel (lib/hook-approval-rules.tsv: tighten-only; a match is human-only).
# Without them a hook worker's bash could write the registry or a decision form
# and approve its own request, so enforce mode refuses when they are missing.
_PS_RULES="$(grep -v '^#' "$_ps_dir/hook-approval-rules.tsv" 2>/dev/null)"
if [ -n "$_PS_RULES" ]; then
  HERDR_POLICY_EXTRA_RULES="${HERDR_POLICY_EXTRA_RULES:+$HERDR_POLICY_EXTRA_RULES
}$_PS_RULES"
  export HERDR_POLICY_EXTRA_RULES
fi

PS_CMD_CAP=2000

# The shapes smart-name.sh strips from pane scrapes, plus credential-carrying
# flags (curl -u user:pass, mysql -p<pw>, sshpass -p, --password/--token=…),
# Authorization headers, NAME=value where NAME says key/token/secret/password
# (any case), private-key blocks and URL userinfo. perl for case-insensitive
# matching (BSD sed has no /I).
pretool_redact() {                      # text -> redacted, capped text
  printf '%s' "$1" | LC_ALL=C perl -0777 -pe '
    s/\b(?:sk|rk|pk)-[A-Za-z0-9_-]{16,}/[redacted-key]/g;
    s/\b(?:gh[posru]|xox[baprs]|github_pat)[-_][A-Za-z0-9_]{16,}/[redacted-token]/g;
    s/\bAKIA[0-9A-Z]{12,}/[redacted-aws]/g;
    s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[redacted-jwt]/g;
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/[redacted-private-key]/gs;
    s/(authorization\s*:\s*)[^\x27"\n]+/$1\[redacted]/gi;
    s/\b(bearer|basic|token)(\s+)[A-Za-z0-9._~+\/=-]{8,}/$1$2\[redacted]/gi;
    s#(://)[^/@\s]+:[^/@\s]+@#$1\[redacted]@#g;
    s/((?:^|\s)(?:-u|--user|--proxy-user)(?:\s+|=)?)[\x27"]?[^\s:\x27"]*:[^\s\x27"]+[\x27"]?/$1\[redacted]/g;
    s/(\b(?:mysql|mysqldump|mariadb|mysqladmin)\b[^|;&\n]*?\s-p)(?!\s)[^\s]+/$1\[redacted]/gi;
    s/(\bsshpass\s+-p\s*)\S+/$1\[redacted]/gi;
    s/(--[A-Za-z0-9-]*(?:password|passwd|passphrase|token|secret|api-?key|auth)[A-Za-z0-9-]*(?:=|\s+))\S+/$1\[redacted]/gi;
    s/(\b[A-Za-z0-9_.-]*(?:api[_-]?key|access[_-]?key|token|password|passwd|passphrase|secret|credential|auth)[A-Za-z0-9_]*\s*[=:]\s*)[^\s]+/$1\[redacted]/gi;
  ' 2>/dev/null | head -c "$PS_CMD_CAP"
}

# Shadow verdict store: its own file, never the control-plane registry.
pretool_shadow_db() { printf '%s/pretool-shadow.sqlite3\n' "$(run_state_root)"; }

_ps_shadow_sql() {
  sqlite3 -batch -noheader -cmd ".timeout ${HERDR_SHADOW_BUSY_MS:-2000}" "$(pretool_shadow_db)" "$@"
}

pretool_shadow_append() {               # run_id task_id payload event_id
  _ps_shadow_sql "PRAGMA journal_mode=WAL;" >/dev/null 2>&1
  _ps_shadow_sql "CREATE TABLE IF NOT EXISTS pretool_verdicts (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
      run_id TEXT NOT NULL DEFAULT '', task_id TEXT NOT NULL DEFAULT '',
      type TEXT NOT NULL DEFAULT 'pretool_verdict', occurred_at TEXT NOT NULL, payload TEXT NOT NULL);
    INSERT OR IGNORE INTO pretool_verdicts(event_id, run_id, task_id, occurred_at, payload)
      VALUES ($(_sq "$4"), $(_sq "$1"), $(_sq "$2"), $(_sq "$(_now_iso)"), $(_sq "$3"));" >/dev/null 2>&1
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
  # Read-only use of the registry: mark it ready so no helper here (read_task,
  # file_approval_state inside peer_decide) runs registry_init's writes. The
  # one exception is a registry not yet migrated to v6 (no tasks.approval):
  # read_task needs that column, so the first shadow child after a deploy runs
  # registry_init's idempotent migration once instead of failing every call.
  if [ ! -r "$(registry_db)" ] || ! _sql "SELECT count(*) FROM tasks LIMIT 1;" >/dev/null 2>&1; then
    PS_REGISTRY_OK=0; _ps_id_fail "registry unreadable ($(registry_db))"; return 1
  fi
  if ! _sql "SELECT approval FROM tasks LIMIT 0;" >/dev/null 2>&1 \
     || ! _sql "SELECT 1 FROM action_requests LIMIT 0;" >/dev/null 2>&1; then
    registry_init >/dev/null 2>&1 || { PS_REGISTRY_OK=0; _ps_id_fail "registry not migrated and migration failed"; return 1; }
  fi
  _HERDR_REGISTRY_READY=1
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
_ps_lower_scheme() {                    # text -> same text with a URL scheme lowercased
  case "$1" in
    *://*) printf '%s://%s' "$(printf '%s' "${1%%://*}" | tr '[:upper:]' '[:lower:]')" "${1#*://}" ;;
    *) printf '%s' "$1" ;;
  esac
}

_ps_read_paths() {                      # input-json tool
  local p r globs=""
  # A glob/find pattern names the files it reads; a grep pattern is a regex
  # over their contents, not a path, so it is not judged as one.
  case "$2" in glob|find) globs=1 ;; esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="$(_ps_lower_scheme "$p")"
    case "$p" in
      ssh://*)
        PS_VERDICT=block PS_POLICY=tool-table PS_REASON="remote host access (ssh://) is not in a worker's scope; ask your conductor"; return ;;
      file://*) p="${p#file://}"; p="${p#localhost}" ;;
      *://*) continue ;;
    esac
    r="$(conductor_reserved_reason "cat -- $p" 2>/dev/null)"
    case "$r" in
      credential*) PS_VERDICT=reserved PS_POLICY=command-policy PS_REASON="$r (read of $p)"; return ;;
    esac
  done < <(printf '%s' "$1" | jq -r --arg g "$globs" '
      [.path?, .file_path?, .paths?[]?, .pattern_path?]
      + (if $g == "1" then [.pattern?, .glob?, (((.path? // ".") | tostring) + "/" + ((.pattern? // .glob? // "") | tostring))] else [] end)
      | map(select(type=="string")) | .[]' 2>/dev/null)
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
        # A service env (BASH_ENV, GIT_CONFIG_*, …) changes what runs and is
        # not part of the text the policy judges.
        if [ "$PS_VERDICT" = allow ] && [ "$(printf '%s' "$input" | jq -r '(.env // {}) | length' 2>/dev/null)" != 0 ]; then
          PS_VERDICT=escalate PS_REASON="the call sets service environment variables, which the command policy does not judge"
        fi
      fi ;;
    eval|python|js|javascript|repl|notebook_eval)
      PS_VERDICT=block PS_REASON="eval runs arbitrary code with no text the policy can judge; disabled for workers — write the code to a file under your worktree and run it via bash (code by reference)" ;;
    write)
      # omp resolves URL schemes case-insensitively (Xd:// dispatches the
      # device), so the scheme is lowercased before the table.
      case "$(_ps_lower_scheme "$(printf '%s' "$input" | jq -r '.path // empty' 2>/dev/null)")" in
        proc://*)
          # Text written to a running job's stdin may be read by a shell:
          # judge it as a command.
          PS_CMD="$(printf '%s' "$input" | jq -r '.content // empty' 2>/dev/null)"
          if [ -z "${PS_CMD//[[:space:]]/}" ]; then PS_VERDICT=allow PS_REASON="empty write to a job's stdin"
          else _ps_bash "$PS_CMD"; fi ;;
        xd://*)
          dev="$(printf '%s' "$input" | jq -r '.path' | sed -E 's#^[A-Za-z]+://##; s#[/?\#].*$##' | tr '[:upper:]' '[:lower:]')"
          _ps_device "$dev" ;;
        *://*)
          case "$(_ps_lower_scheme "$(printf '%s' "$input" | jq -r '.path' 2>/dev/null)")" in
            agent://*|local://*|file://*) PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="write to $(printf '%s' "$input" | jq -r '.path' | sed -E 's#://.*#://#'); containment enforced by the #159 write-scope guard" ;;
            *) PS_VERDICT=escalate PS_REASON="write to an unrecognised URL scheme: a conductor must review it" ;;
          esac ;;
        *) PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="file write; worktree containment enforced by the #159 write-scope guard" ;;
      esac ;;
    edit|ast_edit|multiedit|notebook|notebook_edit|apply_patch|lsp)
      PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="file mutation; worktree containment enforced by the #159 write-scope guard" ;;
    read|grep|glob|find|ast_grep|search)
      PS_VERDICT=allow PS_REASON="read-only tool"
      _ps_read_paths "$input" "$norm" ;;
    hub)
      # omp's hub is a process supervisor as well as a message bus:
      # start/restart launch an arbitrary program, so they are judged as the
      # command line they run. Observers and stopping one's own jobs are
      # allowed; a message to another pane is a peer message.
      op="$(printf '%s' "$input" | jq -r '.op // empty' 2>/dev/null)"
      case "$op" in
        # `send` is omp's in-process peer message (delivered to an agent id in
        # this omp process, never typed into a herdr pane); the recipient's own
        # tool calls are judged by this same hook.
        wait|inbox|list|jobs|logs|ps|describe|status|cancel|stop|send)
          PS_VERDICT=allow PS_REASON="hub $op: observe, message a peer agent, or stop own jobs" ;;
        start|restart)
          PS_CMD="$(printf '%s' "$input" | jq -r '[.application // ""] + (.args // [] | map(tostring)) | map(@sh) | join(" ")' 2>/dev/null)"
          if [ -z "$(printf '%s' "$input" | jq -r '.application // empty' 2>/dev/null)" ]; then
            PS_VERDICT=escalate PS_REASON="hub $op with no application: a conductor must review it"
          else
            _ps_bash "$PS_CMD"
            if [ "$PS_VERDICT" = allow ] && [ "$(printf '%s' "$input" | jq -r '(.env // {}) | length' 2>/dev/null)" != 0 ]; then
              PS_VERDICT=escalate PS_REASON="the service sets environment variables, which the command policy does not judge"
            fi
          fi ;;
        *) PS_VERDICT=escalate PS_REASON="hub op '${op:-?}' is not known to be safe: a conductor must review it" ;;
      esac ;;
    todo|wait|ask|checkpoint|rewind|resolve|web_search|security_scan|new_context|context_notes|taskoutput|taskget|tasklist|bashoutput)
      PS_VERDICT=allow PS_REASON="no host side effect beyond this session" ;;
    learn)
      # Terrence, 2026-09-27 (hook-cutover decision q4): a lesson future
      # sessions load (Main's included) is saved only after the conductor
      # reviews it.
      PS_VERDICT=escalate PS_REASON="a lesson that future sessions load is saved only after your conductor reviews it" ;;
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
    '')
      PS_VERDICT=block PS_REASON="a tool call with no tool name" ;;
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
    --arg mode "${PS_MODE:-shadow}" --arg dec "${PS_DECISION:-}" --arg rid "${PS_REQUEST_ID:-}" \
    '{schema:1, mode:$mode, tool:$tool, call_id:$call, verdict:$v, policy:$pol, reason:$r,
      authority:$auth, command:$cmd, command_sha256:$csha, input_sha256:$isha, cwd:$cwd, pane:$pane,
      code_path:$cp, code_sha256:$cs, elapsed_ms:(($el|tonumber?) // null)}
     + (if $mode == "enforce" then {decision:$dec, request_id:$rid} else {} end)'
}

# ---- enforce mode (hook-approval tasks only) ----------------------------------
# Only called by the omp hook for a task whose REGISTRY ROW says approval=hook
# (or whose launch env claims it — which can only make this refuse, never
# allow). Turns the verdict into the hook's answer:
#   allow            -> run it
#   escalate/reserved -> a one-shot grant already approved for these exact
#                       bytes is consumed and the call runs; otherwise an
#                       action request is (found or) created and it is blocked
#   deny/block       -> blocked, nobody can approve it
# Sets PS_DECISION (allow|block), PS_WORKER_REASON, PS_REQUEST_ID.
_ps_request_command() {                 # input-json session-cwd -> text the reviewer sees
  local where env
  if [ -n "$PS_CMD" ]; then
    # Everything the grant binds is shown: the directory it runs in and any
    # service env, not just the command text.
    case "$(printf '%s' "$PS_TOOL" | tr '[:upper:]' '[:lower:]')" in
      bash|shell) where="(in $(printf '%s' "$1" | jq -r --arg c "$2" '.cwd // $c' 2>/dev/null)) " ;;
      *) where="(stdin of $(printf '%s' "$1" | jq -r '.path // "?"' 2>/dev/null)) " ;;
    esac
    env="$(printf '%s' "$1" | jq -r '(.env // {}) | to_entries | map(.key + "=" + (.value|tostring)) | join(" ")' 2>/dev/null)"
    case "$PS_REASON" in
      credential*|*"credential-value"*) printf '%s[credential withheld] %s' "$where" "$(pretool_redact "$PS_CMD")" ;;
      *) printf '%s%s' "$where" "$PS_CMD" ;;
    esac
    [ -n "$env" ] && printf '\n[env] %s' "$env"
    return 0
  else
    printf '%s %s' "$PS_TOOL" "$(printf '%s' "$1" | jq -cS 'if type=="object" then del(.i) else . end' 2>/dev/null | head -c 20000)"
  fi
}

pretool_enforce() {                     # payload-json (after pretool_decide) -> 0 allow, 8 block
  local payload="$1" input cwd sha route kind cmd approval here_root
  PS_DECISION=block PS_WORKER_REASON="" PS_REQUEST_ID=""
  approval="$(printf '%s' "$PS_TASK_JSON" | jq -r '.approval // empty' 2>/dev/null)"
  if [ "$PS_POLICY" = identity ] || [ -z "$PS_TASK_JSON" ]; then
    PS_WORKER_REASON="herdr hook-approval: refused — $PS_REASON. The pre-tool check cannot prove this session is a live registered hook-approval worker, so nothing runs. Stop and tell your conductor."
    return 8
  fi
  if [ "$approval" != hook ]; then
    PS_VERDICT=block PS_POLICY=identity
    PS_REASON="identity: this session was launched for hook approval but its registry row says approval=${approval:-menu}"
    PS_WORKER_REASON="herdr hook-approval: refused — $PS_REASON. Nothing runs; tell your conductor."
    return 8
  fi
  if [ -z "$_PS_RULES" ]; then
    PS_VERDICT=block PS_POLICY=identity PS_REASON="lib/hook-approval-rules.tsv is missing"
    PS_WORKER_REASON="herdr hook-approval: refused — the hook-approval policy rules are missing, so nothing runs. Tell your conductor."
    return 8
  fi
  case "$PS_VERDICT" in
    allow) PS_DECISION=allow; return 0 ;;
    escalate|reserved) ;;
    deny)
      PS_WORKER_REASON="herdr: refused — ${PS_REASON}. Nobody can approve this. Do not retry it or work around it; change approach or end your turn."
      return 8 ;;
    *)
      PS_WORKER_REASON="herdr: refused — ${PS_REASON}. Do not retry it or work around it."
      return 8 ;;
  esac
  input="$(printf '%s' "$payload" | jq -c '.input // {}' 2>/dev/null)"
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
  sha="$(pretool_action_sha "$PS_TOOL" "$input" "$cwd")"
  # A grant must bind every byte the call runs. A script the command executes
  # is part of that: its sha256 is folded into the grant key, so a script
  # rewritten between the request and the re-issue does not match. A script
  # that cannot be resolved (missing, $-built, more than one) or that runs
  # other local files cannot be bound, so it is refused with no request.
  if [ -n "$PS_CMD" ]; then
    local crc wt_row
    wt_row="$(printf '%s' "$PS_TASK_JSON" | jq -r '.worktree // empty' 2>/dev/null)"
    local cref_cmd="$PS_CMD" in_cwd
    in_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
    # An explicit tool cwd is where the command runs, so a relative script is
    # resolved against it (the bash tool's own `cd <dir> &&` equivalent).
    case "$in_cwd" in /*) cref_cmd="cd $(printf '%q' "$in_cwd") && $PS_CMD" ;; esac
    code_ref_inspect "$cref_cmd" "$wt_row"; crc=$?
    case "$crc" in
      0)
        case "$PD_CODE_CONTENT_REASON" in
          nested:*)
            PS_WORKER_REASON="herdr: refused — ${PD_CODE_PATH} runs other local files, so no approval can be bound to what actually runs. Inline them into one script and run that. Do not retry this call."
            return 8 ;;
        esac
        sha="$(printf '%s\n%s:%s' "$sha" "$PD_CODE_PATH" "$PD_CODE_SHA" | shasum -a 256 | cut -d' ' -f1)" ;;
      1) ;;
      *)
        PS_WORKER_REASON="herdr: refused — ${PS_REASON}. It runs a script that cannot be resolved for review (missing, built from \$variables, or more than one script), so no approval could be bound to its bytes. Write it as ONE script file under your worktree and run it as: cd <your worktree> && bash <file>. Do not retry this exact call."
        return 8 ;;
    esac
  fi
  route=conductor; [ "$PS_VERDICT" = reserved ] && route=human
  kind=once; [ -n "$PS_CODE_PATH" ] && [ "$PS_VERDICT" = escalate ] && kind=file
  cmd="$(_ps_request_command "$input" "$cwd")"
  if ! action_request_resolve "$HERDR_RUN_ID" "$HERDR_TASK_ID" "$PS_TOOL" "$sha" "$cmd" "$PS_VERDICT" \
       "$PS_REASON" "$route" "$kind" "$PS_CODE_PATH" "$PS_CODE_SHA"; then
    PS_WORKER_REASON="herdr: not run — ${PS_REASON}. The request could not be recorded (registry write failed), so nothing runs. Tell your conductor."
    return 8
  fi
  PS_REQUEST_ID="$AR_REQUEST_ID"
  case "$AR_STATE" in
    consumed)
      PS_DECISION=allow
      PS_REASON="approved request $AR_REQUEST_ID consumed (one-shot grant for these exact bytes)"
      return 0 ;;
    declined)
      PS_WORKER_REASON="herdr: not run — request $AR_REQUEST_ID for this exact call was DECLINED (${AR_WHO:-reviewer}): ${AR_WHY:-no reason given}. Do not retry it or work around it; change approach or end your turn."
      return 8 ;;
    pending)
      PS_WORKER_REASON="herdr: not run — still waiting on request $AR_REQUEST_ID (${PS_REASON}). Do not retry it or work around it; continue other work or end your turn. The answer arrives in this pane as [HERDR-ACTION] $AR_REQUEST_ID." ;;
    new)
      if [ "$route" = human ]; then
        PS_WORKER_REASON="herdr: not run — ${PS_REASON}. This is human-only: requested as $AR_REQUEST_ID for Terrence (Slack + hub decision form). Do not retry it or work around it; continue other work or end your turn. The answer arrives in this pane as [HERDR-ACTION] $AR_REQUEST_ID; if approved, re-issue the IDENTICAL call."
      else
        PS_WORKER_REASON="herdr: not run — ${PS_REASON}. Requested as $AR_REQUEST_ID for your conductor. Do not retry it or work around it; continue other work or end your turn. The answer arrives in this pane as [HERDR-ACTION] $AR_REQUEST_ID; if approved, re-issue the IDENTICAL call (same command and arguments, byte for byte)."
      fi
      # Wake the conductor now (detached, every fd closed so the hook's
      # spawnSync is not held open); the hub's tick is the backstop and
      # owns the human route (it holds the Slack credential).
      here_root="$(cd "$_ps_dir/.." && pwd)"
      if [ "$route" = conductor ] && [ -z "${HERDR_ACTION_NO_SURFACE:-}" ]; then
        ( nohup bash "$here_root/herdr-action.sh" surface "$AR_REQUEST_ID" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
      fi ;;
  esac
  return 8
}

pretool_shadow_main() {
  local record=0 enforce=0 payload rc t0 now elapsed="" out eid call a
  for a in "$@"; do
    case "$a" in --record) record=1 ;; --enforce) enforce=1 ;; esac
  done
  payload="$(cat)"
  printf '%s' "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || payload='{}'
  pretool_decide "$payload"; rc=$?
  if [ "$enforce" = 1 ]; then
    PS_MODE=enforce
    pretool_enforce "$payload"; rc=$?
  fi
  t0="$(printf '%s' "$payload" | jq -r '.t0_ms // empty' 2>/dev/null)"
  now="$(_ps_now_ms)"
  case "$t0$now" in ''|*[!0-9]*) ;; *) [ -n "$t0" ] && [ -n "$now" ] && elapsed=$((now - t0)) ;; esac
  out="$(pretool_payload_json "$payload" "$elapsed")"
  if [ "$enforce" = 1 ]; then
    # The hook reads ONE line: {decision, reason, request_id}. The reason is
    # what the worker is told; it is never shown a secret it did not type.
    jq -nc --arg d "$PS_DECISION" --arg r "$PS_WORKER_REASON" --arg id "$PS_REQUEST_ID" \
      --arg v "$PS_VERDICT" '{decision:$d, reason:$r, request_id:$id, verdict:$v}'
  else
    printf '%s\n' "$out"
  fi
  if [ "$record" = 1 ] && [ "${PS_REGISTRY_OK:-1}" = 1 ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    call="$(printf '%s' "$payload" | jq -r '.call_id // empty' 2>/dev/null)"
    eid="$(gen_id ptv)"
    [ -n "$call" ] && eid="ptv_${HERDR_TASK_ID}_$(_ps_sha "$call" | cut -c1-16)"
    pretool_shadow_append "${HERDR_RUN_ID:-}" "$HERDR_TASK_ID" "$out" "$eid" || true
  fi
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pretool_shadow_main "$@"
  exit $?
fi
