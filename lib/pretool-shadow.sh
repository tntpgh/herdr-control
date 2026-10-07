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

# _ps_plain_write_verdict <path> -> sets PS_VERDICT/PS_POLICY/PS_REASON (and
# PS_CMD, for the audit record) for a `write` tool call whose target is an
# ordinary filesystem path (not a proc:///xd:///other-scheme target, already
# routed elsewhere in pretool_decide's `write)` case). The #159 guard
# (agent-hooks/omp-herdr-control.ts, checked earlier via `guard_block` —
# see pretool_decide) has ALREADY confined this call inside the worktree,
# which permits all of `.handoffs/**` there; a manifest naming
# `handoffs_write` (spawn-task.sh, research/explore job classes — N8,
# lib/command-policy.sh) narrows a write-restricted task further, to
# exactly its one `.handoffs/<name>` deliverable.
#
# This is the SAME narrowing `_cp_write_menu_verdict` applies for the menu
# path, mirrored here because the input this judges is the STRUCTURED,
# untruncated `input.path` the omp `tool_call` hook handed us — never a
# scraped, possibly-clipped approval panel (the failure this replaces:
# task_20261002T191316Z_54877_5893, SPEC.md). An empty/missing path
# escalates rather than falling through to containment-159's broad allow —
# "unknown" must never read as "allowed".
_ps_plain_write_verdict() {
  local path="$1" wt manifest hw abs wt_abs rel real real_wt
  # No PS_CMD here: pretool_enforce's escalate path treats a non-empty
  # PS_CMD as a COMMAND whose bytes must resolve to a reviewable script
  # (code_ref_inspect) -- a write tool call is a path+content, not a
  # command, and setting it made every escalation here refuse outright
  # ("runs a script that cannot be resolved for review") instead of
  # creating a reviewable action_requests row. The structured `input`
  # (and its input_sha256) already carries the path for the audit record.
  wt="$(printf '%s' "$PS_TASK_JSON" | jq -r '.worktree // empty' 2>/dev/null)"
  manifest="$(printf '%s' "$PS_TASK_JSON" | jq -r '.manifest // empty' 2>/dev/null)"
  hw="$(printf '%s' "$manifest" | jq -r '.handoffs_write // empty' 2>/dev/null)"
  if [ -z "$hw" ]; then
    PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="file write; worktree containment enforced by the #159 write-scope guard"
    return
  fi
  PS_POLICY=handoffs-write
  if [ -z "${path//[[:space:]]/}" ]; then
    PS_VERDICT=escalate PS_REASON="write call carries no usable structured path — a conductor must review it"
    return
  fi
  if [ -z "$wt" ]; then
    PS_VERDICT=escalate PS_REASON="worker worktree unknown — cannot judge write path containment"
    return
  fi
  case "$path" in
    /*) abs="$path" ;;
    '~'*) PS_VERDICT=escalate PS_REASON="this task's manifest restricts its write tool to .handoffs/$hw only"; return ;;
    *) abs="$wt/$path" ;;
  esac
  abs="$(_cp_lexical_abspath "$abs")"
  wt_abs="$(_cp_lexical_abspath "$wt")"
  rel=".handoffs/$hw"
  if [ "$abs" != "$wt_abs/$rel" ]; then
    PS_VERDICT=escalate PS_REASON="this task's manifest restricts its write tool to .handoffs/$hw only"
    return
  fi
  # R3-4/R4-2 equivalent (lib/command-policy.sh): the lexical check alone
  # cannot see a symlink planted AT this exact path, OR ABOVE it (F5,
  # security review PR #220: .handoffs itself replaced by a directory
  # symlink, with ANSWER.md not yet existing, passed the OLD `-e`/`-L`
  # gate below since the leaf was neither). realpath resolves every
  # ancestor component even when the leaf itself is missing, so run the
  # comparison unconditionally; refuse when the real, symlink-resolved
  # location differs from the lexical one. Compare against the worktree's
  # OWN resolved root (macOS /tmp -> /private/tmp, etc.) so only a symlink
  # inside the write target's path — not an ancestor of the worktree
  # itself — can cause a mismatch.
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$wt/$rel" 2>/dev/null)"
  real_wt="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$wt" 2>/dev/null)"
  if [ -z "$real" ] || [ -z "$real_wt" ] || [ "$real" != "$real_wt/$rel" ]; then
    PS_VERDICT=escalate PS_REASON="this task's one allowed .handoffs file is a symlink to somewhere else — remains human-only"
    return
  fi
  PS_VERDICT=allow PS_REASON="exact match for this task's one allowed deliverable (.handoffs/$hw)"
}

# F3 (REVIEW-220): the write tool above is narrowed to .handoffs/<hw>, but a
# bash call went straight to peer_decide, which knows nothing about
# handoffs_write — so `echo x > src/a.py`, `tee`, `cp`, `sed -i`, `ln -s`
# all auto-allowed anywhere inside the worktree for a research/explore task.
# The outer hook (#184, workerWriteScopeBlock) only proves "inside the
# worktree", never "is the deliverable". `_ps_bash_handoffs_verdict <cmd>
# <cwd> <hw>` runs AFTER peer_decide said allow and can only tighten it.
# CLOSED WORLD (security review F3-1/2/4): the #184 parser is a denylist of
# write-shaped verbs (command-policy.sh, "non-exhaustive"), so "no target
# found" never meant "writes nothing" — `tar -xf a.tar`, `cc -o src/x`,
# `env -S "python3 -c ..."` all named no target. For a task whose only
# legitimate writes are its deliverable and scratch, every segment's command
# word must instead be on _PS_HW_SAFE (reads, plus the few writers whose
# every target the parser does extract), and then:
#   - every TARGET must be exactly <wt>/.handoffs/<hw>, or untracked scratch
#     under <wt>/tmp/ or /tmp/ — resolved ON DISK (realpath anchored on the
#     trusted parent, no symlink or multiply-linked leaf), never lexically;
#   - COMPUTED/UNPARSED, a parser failure, or a segment with no locatable
#     command word (all launchers, e.g. `env -S ...`) escalates.
# Anything else — interpreters, shells, compilers, archivers, package
# runners, sed/awk, cp/mv/ln — escalates to the conductor. Reads stay allowed.
# No `cd`: omp's bash is a persistent shell, so a `cd` in one call would move
# every later call away from the cwd this check resolves targets against.
_PS_HW_SAFE=' cat head tail wc ls grep egrep fgrep rg find echo printf tee pwd sort cut tr diff cmp
 stat file basename dirname realpath readlink date true false test [ jq column nl comm fold expand
 shasum sha256sum mkdir touch git '
_ps_bash_handoffs_verdict() {           # command cwd hw ; only ever tightens an allow
  local cmd="$1" cwd="$2" hw="$3" wt wt_abs line kind val seg root a targets
  # Round 7 (herdr-control#254 PR comment): the SAME shared text-anywhere
  # gate classify_command's peer_decide path now runs FIRST
  # (`_cp_exec_name_or_opaque_present`, lib/command-policy.sh) — called
  # directly here too, not only inherited through peer_decide, so this
  # tighten-only check cannot itself be the reason a handoffs-restricted
  # task's own narrower per-segment walk below (which only recognizes
  # `git`/`git-*` as the command word, not an arbitrary launcher chain or
  # heredoc/here-string hiding it) misses the same shapes round 6's
  # review found.
  if _cp_exec_name_or_opaque_present "$cmd"; then
    PS_VERDICT=escalate PS_POLICY=handoffs-write
    PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; the command text carries an exec-capable variable NAME, git config KEY, unquoted brace-expansion word, or \$'…' ANSI-C word — a conductor must review it"
    return
  fi
  wt="$(printf '%s' "$PS_TASK_JSON" | jq -r '.worktree // empty' 2>/dev/null)"
  if [ -z "$wt" ]; then
    PS_VERDICT=escalate PS_POLICY=handoffs-write PS_REASON="worker worktree unknown — cannot judge this task's bash write scope"; return
  fi
  wt_abs="$(_cp_lexical_abspath "$wt")"
  [ -n "$cwd" ] || cwd="$wt_abs"
  # R2-1: a command substitution's body is collapsed to @SUB@ before either
  # the segment walk or the target parser sees it, so `cat "$(echo x >
  # src/a)"` would read as a bare `cat`. Nothing a research task needs.
  case "$(_cp_protect_text "$cmd")" in
    *@SUB@*)
      PS_VERDICT=escalate PS_POLICY=handoffs-write
      PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; a command substitution runs code this policy cannot see — a conductor must review it"
      return ;;
  esac
  while IFS= read -r seg; do
    [ -n "${seg//[[:space:]]/}" ] || continue
    if ! _cp_locate_command_word "$seg"; then
      PS_VERDICT=escalate PS_POLICY=handoffs-write
      PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; a command segment has no command word this policy can identify — a conductor must review it"
      return
    fi
    # R2-3: the command word must be the segment's FIRST word. A launcher
    # (`env -C dir`, `nice`, `timeout`) or a leading assignment
    # (`GIT_EXTERNAL_DIFF=x git diff`) changes where or what the allowed
    # command runs, and target resolution would not follow it.
    local -a _hw_toks
    set -f; read -r -a _hw_toks <<<"$seg"; set +f
    if [ "${_hw_toks[0]:-}" != "${_CP_LOC[0]:-}" ]; then
      PS_VERDICT=escalate PS_POLICY=handoffs-write
      PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; '${_hw_toks[0]:-}' wraps or prefixes '$_cp_wcmd' — a conductor must review it"
      return
    fi
    case "$_PS_HW_SAFE" in
      *" $_cp_wcmd "*) ;;
      *)
        PS_VERDICT=escalate PS_POLICY=handoffs-write
        PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; '$_cp_wcmd' is not on the read/scratch command list — a conductor must review it"
        return ;;
    esac
    # find/git are reads only without their own writing/exec options.
    # git calls the SAME shared allowlist function
    # lib/command-policy.sh's top-level exec-opt escalation rule uses
    # (`_cp_git_unsafe_tokens`) instead of keeping its own duplicate glob
    # list here: the old `git:-[!-]*[oCc]*`/`git:-O*`/
    # `git:--open-files-in-pager*`/`git:-c*`/`git:--config-env*` globs
    # matched a lowercase o/C/c anywhere in a short-option cluster but
    # missed `-C`, `--git-dir`, `--work-tree`, the attached short form
    # `-ccore.pager=...`, and grep's `--open-files-in-pag=...`
    # abbreviation — one shared function so classifier and shadow cannot
    # disagree again.
    for a in "${_CP_LOC[@]:1}"; do
      case "$_cp_wcmd:$a" in
        find:-exec*|find:-ok*|find:-delete|find:-fprint*|find:-fls|rg:--pre*)
          PS_VERDICT=escalate PS_POLICY=handoffs-write
          PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; '$_cp_wcmd $a' can write or run code — a conductor must review it"
          return ;;
      esac
    done
    if [ "$_cp_wcmd" = git ]; then
      if _cp_git_unsafe_tokens "${_CP_LOC[@]:1}"; then
        PS_VERDICT=escalate PS_POLICY=handoffs-write
        PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; 'git ${_CP_LOC[*]:1}' can write or run code — a conductor must review it"
        return
      fi
      case " ${_CP_LOC[1]:-} " in
        " log "|" show "|" diff "|" status "|" grep "|" ls-files "|" rev-parse "|" blame "|" cat-file "|" ls-tree "|" describe "|" shortlog ") ;;
        *)
          PS_VERDICT=escalate PS_POLICY=handoffs-write
          PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; 'git ${_CP_LOC[1]:-}' is not a read-only git verb — a conductor must review it"
          return ;;
      esac
    fi
  done < <(_cp_walk_segments "$cmd")
  # F3-5: capture the parser's output and status; a failure is never "no targets".
  if ! targets="$(bash_write_targets "$cmd" "$cwd")"; then
    PS_VERDICT=escalate PS_POLICY=handoffs-write PS_REASON="the bash write-target parser failed — a conductor must review it"; return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="${line%%$'\t'*}" val="${line#*$'\t'}"
    if [ "$kind" != TARGET ]; then
      PS_VERDICT=escalate PS_POLICY=handoffs-write
      PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; a write target cannot be read statically ($kind) — a conductor must review it"
      return
    fi
    # Every allowed target is checked on disk, never lexically: its real
    # (symlink-resolved) location must stay under the real root, and an
    # existing leaf must be neither a symlink nor a multiply-linked file —
    # `cp -s`/`cp -l`/an earlier plant into scratch must not turn a later
    # redirect into a write somewhere else.
    # mode: exact (the deliverable) | under (scratch). The anchor is the
    # REAL path of a trusted directory plus a literal suffix, so a symlinked
    # `.handoffs` or `tmp` (pointing into src/) can never become the root.
    # /tmp itself is a system symlink to /private/tmp on macOS; trusted.
    case "$val" in
      "$wt_abs/.handoffs/$hw") root="$wt|.handoffs/$hw|exact" ;;
      "$wt_abs/tmp/"*) root="$wt|tmp|under" ;;
      /tmp/*|/private/tmp/*) root="/tmp||under" ;;
      *)
        PS_VERDICT=escalate PS_POLICY=handoffs-write
        PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; this command writes ${val#"$wt_abs"/} — a conductor must review it"
        return ;;
    esac
    if ! python3 - "$val" "$root" <<'PY' 2>/dev/null
import os, stat, sys
p = sys.argv[1]
base, suffix, mode = sys.argv[2].split("|")
anchor = os.path.realpath(base) + ("/" + suffix if suffix else "")
rp = os.path.realpath(p)
if mode == "exact":
    if rp != anchor:
        sys.exit(1)
elif not rp.startswith(anchor + "/"):
    sys.exit(1)
try:
    st = os.lstat(p)
except FileNotFoundError:
    sys.exit(0)
if stat.S_ISLNK(st.st_mode) or (not stat.S_ISDIR(st.st_mode) and st.st_nlink != 1):
    sys.exit(1)
PY
    then
      PS_VERDICT=escalate PS_POLICY=handoffs-write
      PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; ${val#"$wt_abs"/} is (or resolves through) a symlink or hard link — a conductor must review it"
      return
    fi
    # Scratch is untracked by definition: a tracked file under tmp/ (some
    # repos ship one) is a project file, not scratch.
    case "$val" in
      "$wt_abs/tmp/"*)
        if git -C "$wt" ls-files --error-unmatch -- "${val#"$wt_abs"/}" >/dev/null 2>&1; then
          PS_VERDICT=escalate PS_POLICY=handoffs-write
          PS_REASON="this task's manifest restricts writes to .handoffs/$hw only; ${val#"$wt_abs"/} is a tracked file, not scratch — a conductor must review it"
          return
        fi ;;
    esac
  done <<<"$targets"
}

pretool_decide() {                      # payload-json -> sets PS_* ; 0 allow, 8 not
  local payload="$1" tool norm input guard dev cmd op manifest hw
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
  # R2 (security review PR #220 round 2): hoisted here (not just inside the
  # write case) so EVERY dispatch path that can reach a write-capable
  # device -- write xd://, the bare xd_<dev> tool name, and the bare
  # <dev> tool name (retain, notepad_append, ...) -- can gate on the same
  # handoffs_write restriction, not just the one this PR originally fixed.
  manifest="$(printf '%s' "$PS_TASK_JSON" | jq -r '.manifest // empty' 2>/dev/null)"
  hw="$(printf '%s' "$manifest" | jq -r '.handoffs_write // empty' 2>/dev/null)"
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
        # F3: a write-restricted (handoffs_write) task's bash is narrowed
        # the same way its write tool is; this can only tighten an allow —
        # or, when the top-level command-policy verdict already escalated
        # (e.g. the git -O/-c/--config-env/env-prefix exec-option rule,
        # which applies to every task, not just a handoffs_write one), swap
        # in the more specific "restricts writes to .handoffs/$hw only"
        # reason instead of the generic one. _ps_bash_handoffs_verdict never
        # sets `allow` itself (see its own header), so running it on an
        # already-escalated verdict can only leave that escalation in place
        # or escalate further — never loosen it.
        if [ -n "$hw" ] && { [ "$PS_VERDICT" = allow ] || [ "$PS_VERDICT" = escalate ]; }; then
          # omp runs bash in input.cwd (relative to the session cwd) or the session cwd.
          op="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
          cmd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
          case "$op" in /*) ;; '') op="$cmd" ;; *) op="${cmd:+$cmd/}$op" ;; esac
          _ps_bash_handoffs_verdict "$PS_CMD" "$op" "$hw"
        fi
      fi ;;
    eval|python|js|javascript|repl|notebook_eval)
      PS_VERDICT=block PS_REASON="eval runs arbitrary code with no text the policy can judge; disabled for workers — write the code to a file under your worktree and run it via bash (code by reference)" ;;
    write)
      # F4 (security review PR #220): every `.path` extraction below goes
      # through a bash $(...) command substitution, which SILENTLY STRIPS a
      # trailing newline -- so a path judged as the clean string would not
      # be the literal bytes omp actually writes to (node fs does not strip
      # it). Test the RAW json for ANY embedded control byte (round 2 (R4):
      # NOT just \n -- \0 survives the same $(...) stripping on this
      # machine's bash and is otherwise a harmless no-op path component,
      # but judging it is still wrong) here, before that stripping can
      # happen, and refuse outright rather than judge a string that might
      # not match the real write target.
      if [ "$(printf '%s' "$input" | jq -r '((.path // "") | test("[\\x00-\\x1f]")) // false' 2>/dev/null)" = true ]; then
        PS_VERDICT=escalate PS_REASON="write path contains a control byte, which a later \$(...) substitution can silently drop — the judged string could differ from what omp actually writes; a conductor must review it"
      else
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
          if [ -n "$hw" ]; then
            # F2: a write-restricted task's write tool may touch exactly
            # one file -- no xd:// device writes THAT file, so none of
            # them can be a blanket allow once handoffs_write narrows the
            # tool (menu mode escalated every xd:// device but notepad_*).
            PS_VERDICT=escalate PS_REASON="this task's manifest restricts its write tool to .handoffs/$hw only; xd://$dev is not that file — a conductor must review it"
          else
            _ps_device "$dev"
          fi ;;
        file://*)
          # F1: file:// names a REAL filesystem path with the same power
          # as a plain path (unlike agent:///local://, below, which are
          # not raw filesystem writes) -- judge it exactly like one
          # instead of the blanket containment-159 allow this used to
          # fall into, which bypassed handoffs_write narrowing entirely.
          _ps_plain_write_verdict "$(printf '%s' "$input" | jq -r '.path' 2>/dev/null | sed -E 's#^[Ff][Ii][Ll][Ee]://##')" ;;
        *://*)
          case "$(_ps_lower_scheme "$(printf '%s' "$input" | jq -r '.path' 2>/dev/null)")" in
            agent://*) PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="write to $(printf '%s' "$input" | jq -r '.path' | sed -E 's#://.*#://#'); containment enforced by the #159 write-scope guard" ;;
            local://*)
              if [ -n "$hw" ]; then
                # R2 (security review PR #220 round 2): local:// is omp's
                # per-session artifact directory -- not the one allowed
                # file either, so it gets the same treatment as xd:// above
                # once handoffs_write narrows the write tool.
                PS_VERDICT=escalate PS_REASON="this task's manifest restricts its write tool to .handoffs/$hw only; local:// is not that file — a conductor must review it"
              else
                PS_VERDICT=allow PS_POLICY=containment-159 PS_REASON="write to $(printf '%s' "$input" | jq -r '.path' | sed -E 's#://.*#://#'); containment enforced by the #159 write-scope guard"
              fi ;;
            *) PS_VERDICT=escalate PS_REASON="write to an unrecognised URL scheme: a conductor must review it" ;;
          esac ;;
        *) _ps_plain_write_verdict "$(printf '%s' "$input" | jq -r '.path // empty' 2>/dev/null)" ;;
      esac
      fi ;;
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
      # R2 (security review PR #220 round 2): the SAME device reached as a
      # bare `xd_<dev>` tool name (not through `write xd://...`) bypassed
      # the handoffs_write gate above entirely.
      if [ -n "$hw" ]; then
        PS_VERDICT=escalate PS_REASON="this task's manifest restricts its write tool to .handoffs/$hw only; xd://${norm#xd_} is not that file — a conductor must review it"
      else
        _ps_device "${norm#xd_}"
      fi ;;
    notepad_append|notepad_priority|notepad_read|notepad_stats|fleet_status|pr_ready|handoff_debt|single_copy_scan|worktree_debt|suite_wired|decisions_open|project_status|recall|reflect|retain|report_issue)
      # R2: same gate for the BARE device tool name (e.g. `retain`, which
      # writes the global memory bank -- not the one allowed file either).
      if [ -n "$hw" ]; then
        PS_VERDICT=escalate PS_REASON="this task's manifest restricts its write tool to .handoffs/$hw only; xd://$norm is not that file — a conductor must review it"
      else
        _ps_device "$norm"
      fi ;;
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
