#!/usr/bin/env bash
# lib/engineering-stage3.sh — Stage-3 ("FIX") mechanics for the Engineering
# Evolution Loop (thurber-os docs/engineering-evolution-loop-charter.md §3
# Stage 3, §4 safety boundaries; gate G-ELOOP-E2). Shared implementation for
# stage3-execute.sh.
#
# Reuses lib/engineering-ledger.sh's sanitizers (ledger_sanitize_signature/
# ledger_sanitize_label) and lock primitives (ledger_lock_acquire/release)
# instead of reimplementing sanitization or locking a second time.
# shellcheck shell=bash

_stage3_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_stage3_repo_dir=$(cd "$_stage3_lib_dir/.." && pwd)
. "$_stage3_lib_dir/engineering-ledger.sh"

stage3_now() { ledger_now; }

# ---- allowlist --------------------------------------------------------------
# EXACTLY the three classes DECIDED 2026-08-10 (Terrence, served decisions
# form) — docs/gate-registry.yaml G-ELOOP-E2 evidence block +
# docs/decision-ledger-2026-08-16-record.md. Do not expand without a fresh,
# equally durable decision — see charter §7 Phase 3/4. Class slugs here are
# the canonical contract stage2-diagnose.sh's brief also documents; a
# Stage-2 finding using any other slug is not-allowlisted by construction.
STAGE3_ALLOWLIST_CLASSES="schema_nullability_mismatch dead_code missing_error_observability"

stage3_class_allowed() {  # <class> -> exit 0 if allowlisted
  local c="$1" a
  for a in $STAGE3_ALLOWLIST_CLASSES; do
    [ "$c" = "$a" ] && return 0
  done
  return 1
}

# ---- repo scope ---------------------------------------------------------
# Reuses the SAME override env vars lib/engineering-ledger.sh already reads
# for these three repos' paths (ENGINEERING_LEDGER_*_REPO), rather than
# inventing a second set of Stage-3-only variables for the same machine
# fact ("where does repo X live").
stage3_repo_dir_for() {  # <repo-name> -> path on stdout, exit 1 if unknown
  case "$1" in
    knowledge-base) printf '%s\n' "${ENGINEERING_LEDGER_KB_REPO:-$HOME/Code/knowledge-base}" ;;
    tourguide) printf '%s\n' "${ENGINEERING_LEDGER_TOURGUIDE_REPO:-$HOME/Code/tourguide}" ;;
    thurber-ai) printf '%s\n' "${ENGINEERING_LEDGER_THURBER_AI_REPO:-$HOME/Code/thurber-ai}" ;;
    *) return 1 ;;
  esac
}

# ---- denylist -----------------------------------------------------------
# Every entry: "<file-extended-regex><TAB><content-extended-regex-or-empty>".
# An empty content pattern denies the WHOLE file unconditionally (the file
# IS the unsafe surface, e.g. a ZipForms-write-only connector). A non-empty
# content pattern only denies when the file path matches AND a grep of the
# file's actual content also matches — line_hint from Stage-2 is a guess,
# not trustworthy enough to narrow the safety scan to a window around it, so
# the whole file is scanned.
#
# Sourced from real code, not guessed (this session's own grep, 2026-08-20):
#   - self-heal-cross-system-proposal-2026-08-01.md §5d: ZipForms field
#     writes, entity-graph dedup/merge, anything reaching kb.action_queue's
#     outbound-send path.
#   - charter §3 Stage 3 / §4: "same reasoning" extended to thurber-ai's
#     dispatch/tier/policy/send code (single outbound chokepoint).
# Any finding whose file matches is skipped and logged loudly
# (skipped-denylist), never silently — see stage3_process_finding.
read -r -d '' STAGE3_DENYLIST <<'EOF' || true
connectors/zipforms_playwright\.py	
connectors/zipforms_txn\.py	
connectors/zipforms_deal_sync\.py	
server/mcp_server\.py	write_zipforms_fields|set_credential
server/api_server\.py	_handle_zipforms_approve|zipforms_approve
server/entity_graph\.py	_phase6_dedup|_phase6d_disambiguate_first_names|_merge_entit
server/actions\.py	_send_row|emit_action
server/action_classifier\.py	
src/dispatch/dispatcher\.ts	
src/tools/communication/classifyTier\.ts	
src/tools/communication/composeDraft\.ts	
src/agents/TransactionAgent\.ts	dispatch\(
src/workflows/.*\.ts	dispatch\(
EOF

# stage3_denylist_check <repo_dir> <file> -> exit 0 (allowed, nothing
# printed) or exit 1 (denied, prints the matched pattern on stdout for the
# audit trail).
stage3_denylist_check() {
  local repo_dir="$1" file="$2" file_re content_re abs
  while IFS=$'\t' read -r file_re content_re; do
    [ -n "$file_re" ] || continue
    printf '%s' "$file" | grep -Eq "$file_re" || continue
    if [ -z "$content_re" ]; then
      printf '%s\n' "$file_re"
      return 1
    fi
    abs="$repo_dir/$file"
    if [ -f "$abs" ] && grep -Eq "$content_re" "$abs" 2>/dev/null; then
      printf '%s (content: %s)\n' "$file_re" "$content_re"
      return 1
    fi
  done <<<"$STAGE3_DENYLIST"
  return 0
}

# ---- rate limiting --------------------------------------------------------
# Starting numbers are tourguide's own self_heal.mjs constants
# (cloudflare/worker/src/utils/self_heal.mjs: COOLDOWN_DAYS=7,
# RECOVER_RATE_CAP_PER_HOUR=30), per charter §4 "reuse tourguide self_heal.mjs's
# numbers as a starting point" — not invented here.
STAGE3_COOLDOWN_DAYS=7
STAGE3_RATE_CAP_PER_HOUR=30

stage3_state_file() { printf '%s/rate-state.json\n' "$1"; }  # <state_dir> -> path

stage3_rate_init() {  # <state_file> -- create the JSON store if missing
  local f="$1"
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")" && printf '{"signatures":{},"fired":[]}\n' >"$f"; }
}

# stage3_iso_to_epoch <iso8601> -> epoch seconds on stdout. Tries BSD date
# (real macOS, the deploy target) first, then GNU date (dev/sandbox
# environments) — mirrors the same portability need lib/engineering-ledger.sh
# sidesteps by never doing epoch arithmetic; Stage-3's cooldown math needs it.
stage3_iso_to_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
  date -u -d "$1" +%s 2>/dev/null
}

stage3_iso_minus_seconds() {  # <iso8601> <seconds> -> iso8601 on stdout
  local epoch
  epoch=$(stage3_iso_to_epoch "$1") || { printf '%s\n' "$1"; return 1; }
  date -u -j -f '%s' "$((epoch - $2))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -d "@$((epoch - $2))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# stage3_rate_check <state_file> <signature> <now_iso> -> exit 0 (allowed) or
# 1 (rate-limited, prints the reason on stdout). Read-only: never records —
# callers only record on an actual fire (stage3_process_finding), so a
# dry-run check never consumes rate-limit budget.
stage3_rate_check() {
  local f="$1" sig="$2" now="$3" last_fired hourly_count cutoff
  stage3_rate_init "$f"
  last_fired=$(jq -r --arg s "$sig" '.signatures[$s] // empty' "$f" 2>/dev/null)
  if [ -n "$last_fired" ]; then
    local last_epoch now_epoch
    last_epoch=$(stage3_iso_to_epoch "$last_fired") || last_epoch=0
    now_epoch=$(stage3_iso_to_epoch "$now") || now_epoch=0
    if [ $((now_epoch - last_epoch)) -lt $((STAGE3_COOLDOWN_DAYS * 86400)) ]; then
      printf 'cooldown: signature last fired %s, %sd cooldown not yet elapsed\n' "$last_fired" "$STAGE3_COOLDOWN_DAYS"
      return 1
    fi
  fi
  cutoff=$(stage3_iso_minus_seconds "$now" 3600)
  hourly_count=$(jq -r --arg cutoff "$cutoff" '[.fired[] | select(. >= $cutoff)] | length' "$f" 2>/dev/null)
  [ -n "$hourly_count" ] || hourly_count=0
  if [ "$hourly_count" -ge "$STAGE3_RATE_CAP_PER_HOUR" ]; then
    printf 'global cap: %s fires in the trailing hour (cap %s/hr)\n' "$hourly_count" "$STAGE3_RATE_CAP_PER_HOUR"
    return 1
  fi
  return 0
}

# stage3_rate_record <state_file> <signature> <now_iso> -- records a real
# fire. Lock-protected (ledger_lock_acquire/release, reused from
# lib/engineering-ledger.sh) so two concurrent stage3-execute.sh runs cannot
# interleave a read-modify-write and silently drop each other's fire.
stage3_rate_record() {
  local f="$1" sig="$2" now="$3" state_dir lock_dir tmp
  stage3_rate_init "$f"
  state_dir=$(dirname "$f")
  lock_dir="$state_dir/.rate.lock"
  ledger_lock_acquire "$lock_dir" || { printf 'stage3: timed out waiting for rate-state lock\n' >&2; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/stage3-rate.XXXXXX") || { ledger_lock_release "$lock_dir"; return 1; }
  if jq --arg s "$sig" --arg now "$now" \
      '.signatures[$s] = $now | .fired = ((.fired // []) + [$now])' \
      "$f" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    ledger_lock_release "$lock_dir"
    return 1
  fi
  ledger_lock_release "$lock_dir"
}

# stage3_signature_for <repo> <file> <class> -> stable rate-limit + audit key.
# Uses ledger_sanitize_label (not ledger_sanitize_signature — that function
# retains only the text before the first ':', which is right for a Sentry-
# style "ErrorClass: message" title but would truncate this composite key to
# just $repo).
stage3_signature_for() {
  printf '%s/%s/%s' "$1" "$2" "$3" | ledger_sanitize_label
}

stage3_branch_name_for() {  # <signature> <now_iso> -> branch name
  local sig="$1" now="$2" slug ts
  slug=$(printf '%s' "$sig" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40)
  ts=$(printf '%s' "$now" | tr -dc '0-9')
  printf 'evolution-loop/stage3-fix-%s-%s\n' "$slug" "$ts"
}

# ---- Stage-2 doc parsing --------------------------------------------------
STAGE3_FENCE_TAG='stage3-findings'

# stage3_extract_findings <doc_path> -> the fenced block's JSON array on
# stdout, exit 0, if a well-formed ```stage3-findings block exists and every
# element carries repo/file/class/fix_summary as strings. Exit 1 (nothing on
# stdout) otherwise — callers MUST fail closed on 1, never fall back to
# guessing from prose.
stage3_extract_findings() {
  local doc="$1" block
  [ -f "$doc" ] || return 1
  block=$(awk -v tag="$STAGE3_FENCE_TAG" '
    $0 ~ "^```" tag "[[:space:]]*$" { found=1; next }
    found && /^```[[:space:]]*$/ { found=0 }
    found { print }
  ' "$doc")
  [ -n "$block" ] || return 1
  printf '%s' "$block" | jq -e '
    type == "array"
    and all(.[]; (.repo|type=="string") and (.file|type=="string")
                 and (.class|type=="string") and (.fix_summary|type=="string"))
  ' >/dev/null 2>&1 || return 1
  printf '%s\n' "$block"
}

# ---- audit trail ----------------------------------------------------------
STAGE3_AUDIT_SCHEMA=1

# stage3_audit_entry <decision> <repo> <file> <line_hint-or-null> <class>
#   <signature> <reason> <doc_path> [<branch>] -> one sanitized JSON line.
# file/class/reason go through ledger_sanitize_label (reused, not
# reimplemented) before ever reaching disk.
stage3_audit_entry() {
  local decision="$1" repo="$2" file="$3" line_hint="$4" class="$5" sig="$6" reason="$7" doc="$8" branch="${9:-}"
  local safe_file safe_class safe_reason lh
  safe_file=$(printf '%s' "$file" | ledger_sanitize_label)
  safe_class=$(printf '%s' "$class" | ledger_sanitize_label)
  safe_reason=$(printf '%s' "$reason" | ledger_sanitize_label)
  lh="$line_hint"
  [[ "$lh" =~ ^[0-9]+$ ]] || lh=null
  jq -nc \
    --argjson schema "$STAGE3_AUDIT_SCHEMA" --arg ts "$(stage3_now)" \
    --arg decision "$decision" --arg repo "$repo" --arg file "$safe_file" \
    --argjson line_hint "$lh" --arg class "$safe_class" \
    --arg signature "$sig" --arg reason "$safe_reason" --arg doc "$doc" --arg branch "$branch" \
    '{schema:$schema, ts:$ts, decision:$decision, repo:$repo, file:$file,
      line_hint:$line_hint, class:$class, signature:$signature, reason:$reason,
      doc:$doc, branch:(if ($branch|length)>0 then $branch else null end)}'
}

# ---- verification hints per repo ------------------------------------------
# Not invented tooling — each repo's own already-documented cheap gate:
# kb-debug skill (ruff+py_compile), tourguide-ops skill (node --check +
# node --test), thurber-ai's TypeScript build (tsc --noEmit + npm test).
stage3_verification_hint_for() {  # <repo> -> plain-English instruction
  case "$1" in
    knowledge-base)
      printf 'ruff check <file> && python -m py_compile <file>, then run the single most relevant existing pytest module for the touched code and confirm it passes (this repo'"'"'s own pre-commit gate)\n' ;;
    tourguide)
      printf 'node --check <file>, then npm test (or node --test <relevant test file> if narrower) and confirm it passes\n' ;;
    thurber-ai)
      printf 'npx tsc --noEmit, then npm test and confirm it passes\n' ;;
    *)
      printf 'run this repo'"'"'s own existing test suite for the touched module and confirm it passes\n' ;;
  esac
}

# stage3_build_prompt <repo> <file> <line_hint> <class> <fix_summary> ->
# the fully bounded task prompt handed to spawn-task.sh's worker.
stage3_build_prompt() {
  local repo="$1" file="$2" line_hint="$3" class="$4" fix_summary="$5" verify loc
  verify=$(stage3_verification_hint_for "$repo")
  loc="$file"
  [ -n "$line_hint" ] && loc="$file (near line $line_hint -- confirm the exact location yourself; this is a Stage-2 hint, not verified)"
  cat <<PROMPT
Bounded Stage-3 fix, Engineering Evolution Loop (thurber-os
docs/engineering-evolution-loop-charter.md §3 Stage 3, gate G-ELOOP-E2).

This task was auto-generated from a Stage-2 Fable-5 proposal-doc finding
that already passed the E2 allowlist + denylist + rate-limit gates -- it is
scoped tight on purpose. Stay inside this scope; do not go looking for
other issues in this repo.

Target: ${loc}
Bug class: ${class}
Stage-2 summary: ${fix_summary}

Your job:
1. Read the target file and confirm the finding is real -- Stage-2 is a
   proposal pass, not verified code. If it's wrong, already fixed, or you
   disagree with the classification, say so in the PR description and stop
   there; do not invent a fix for a finding that doesn't hold up.
2. Make the smallest correct fix for exactly this one finding. No adjacent
   refactors, no unrelated cleanup, no scope growth.
3. Verify: ${verify}
4. Open a PR. Never merge it yourself and never push to this repo's default
   branch directly -- PR-only, human-merged (charter §4 safety boundary).
   Your job ends at an opened PR.

Constraints:
- This finding already cleared the E2 safety denylist for this repo, but
  that gate is file-path-based only. If the real fix turns out to require
  touching ZipForms field-write code, entity-graph merge/dedup code,
  kb.action_queue's outbound-send path, or thurber-ai's dispatch/tier/
  policy/send code, STOP and open the PR as a report-only / no-fix
  description instead -- never patch those surfaces, even if the fix looks
  small.
- Never write client-facing content or trigger a business action.
- Never edit docs/gate-registry.yaml or .omc/gate-registry.yaml.
PROMPT
}

# ---- worker spawn (overridable) --------------------------------------------
# Reuses the EXACT existing spawn-task.sh + send-to-agent.sh two-step pattern
# stage2-diagnose.sh already uses: spawn-task.sh creates the worktree/tab and
# prints "pane=<id>"; the brief is delivered afterward via send-to-agent.sh's
# "@<file>" convention (Claude/omp's own @-file reference syntax reads it),
# since spawn-task.sh's own argv is a launch command, not a place to hand a
# multi-paragraph prompt.
#
# Overridable on purpose: verify-engineering-stage3.sh replaces this function
# with a stub before calling stage3_process_finding, so tests exercise the
# real gating logic and inspect exactly what WOULD have been spawned without
# ever launching a real worker.
stage3_spawn_worker() {  # <repo> <repo_dir> <branch> <prompt_text> -> prints spawn-task.sh + delivery output; exit 0/1
  local repo_dir="$2" branch="$3" prompt="$4" brief_file spawn_out pane
  brief_file=$(mktemp "${TMPDIR:-/tmp}/stage3-brief.XXXXXX.md") || return 1
  printf '%s\n' "$prompt" >"$brief_file"
  spawn_out=$("$_stage3_repo_dir/spawn-task.sh" "$repo_dir" "$branch" debug 2>&1) || {
    printf '%s\n' "$spawn_out" >&2
    return 1
  }
  printf '%s\n' "$spawn_out"
  pane=$(printf '%s' "$spawn_out" | sed -n 's/.*pane=\([^[:space:]]*\).*/\1/p' | head -1)
  if [ -n "$pane" ]; then
    "$_stage3_repo_dir/send-to-agent.sh" "$pane" "@$brief_file" \
      || printf 'stage3: send-to-agent.sh failed for %s -- brief left at %s\n' "$pane" "$brief_file" >&2
  else
    printf 'stage3: could not parse a pane id from spawn-task.sh output -- brief left at %s\n' "$brief_file" >&2
  fi
  return 0
}

# ---- the one entry point stage3-execute.sh (and tests) call ---------------
# stage3_process_finding <state_dir> <audit_log> <doc_path> <finding_json>
#   <now_iso> [<dry_run:0|1>]
# -> prints the decision word on stdout:
#    fired | dry-run-would-fire | skipped-not-allowlisted |
#    skipped-denylist | skipped-rate-limited | skipped-spawn-failed
# Always writes exactly one sanitized audit line. Only a real (non-dry-run)
# `fired` decision calls stage3_spawn_worker and records the rate-limit hit.
stage3_process_finding() {
  local state_dir="$1" audit_log="$2" doc="$3" finding="$4" now="$5" dry_run="${6:-0}"
  local repo file line_hint class fix_summary sig repo_dir deny_reason rate_reason
  local decision reason branch="" pane_info state_file

  repo=$(jq -r '.repo' <<<"$finding")
  file=$(jq -r '.file' <<<"$finding")
  line_hint=$(jq -r '.line_hint // empty' <<<"$finding")
  [[ "$line_hint" =~ ^[0-9]+$ ]] || line_hint=""
  class=$(jq -r '.class' <<<"$finding")
  fix_summary=$(jq -r '.fix_summary // .one_line_fix_summary // ""' <<<"$finding")
  sig=$(stage3_signature_for "$repo" "$file" "$class")
  state_file=$(stage3_state_file "$state_dir")

  if ! stage3_class_allowed "$class"; then
    decision=skipped-not-allowlisted
    reason="class '$class' not in allowlist ($STAGE3_ALLOWLIST_CLASSES)"
  elif ! repo_dir=$(stage3_repo_dir_for "$repo"); then
    decision=skipped-not-allowlisted
    reason="repo '$repo' not in scope (knowledge-base|tourguide|thurber-ai)"
  elif ! deny_reason=$(stage3_denylist_check "$repo_dir" "$file"); then
    decision=skipped-denylist
    reason="denylist match: $deny_reason"
  elif ! rate_reason=$(stage3_rate_check "$state_file" "$sig" "$now"); then
    decision=skipped-rate-limited
    reason="$rate_reason"
  else
    decision=fired
    reason=ok
  fi

  if [ "$decision" = fired ]; then
    branch=$(stage3_branch_name_for "$sig" "$now")
    if [ "$dry_run" -eq 1 ]; then
      decision=dry-run-would-fire
      reason="would spawn $branch (dry-run: not spawned, rate-limit not recorded)"
    else
      local prompt
      prompt=$(stage3_build_prompt "$repo" "$file" "$line_hint" "$class" "$fix_summary")
      if pane_info=$(stage3_spawn_worker "$repo" "$repo_dir" "$branch" "$prompt"); then
        stage3_rate_record "$state_file" "$sig" "$now"
        reason="spawned $branch"
      else
        decision=skipped-spawn-failed
        reason="stage3_spawn_worker failed for $branch"
      fi
    fi
  fi

  mkdir -p "$state_dir"
  stage3_audit_entry "$decision" "$repo" "$file" "${line_hint:-null}" "$class" "$sig" "$reason" "$doc" "$branch" >>"$audit_log"
  printf '%s\n' "$decision"
}
