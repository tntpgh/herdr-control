#!/usr/bin/env bash
# stage3-execute.sh — run a Stage 3 ("FIX") pass of the Engineering
# Evolution Loop (thurber-os docs/engineering-evolution-loop-charter.md §3
# Stage 3, §4 safety boundaries; gate G-ELOOP-E2).
#
# Reads the latest Stage-2 proposal doc (same discovery logic
# stage2-diagnose.sh uses, via lib/engineering-stage2.sh), parses its
# structured ```stage3-findings fenced block, and for every finding that
# clears three gates in order --
#   1. allowlist   (schema_nullability_mismatch | dead_code | missing_error_observability)
#   2. denylist    (ZipForms writes, entity-graph merge/dedup,
#                   kb.action_queue send path, thurber-ai dispatch/tier/
#                   policy/send code — hardcoded file/content patterns,
#                   lib/engineering-stage3.sh)
#   3. rate limit  (7-day per-signature cooldown, 30/hr global cap — the
#                   same numbers as tourguide's self_heal.mjs)
# -- spawns a bounded, fully-specified spawn-task.sh worker on its own
# worktree branch, whose job ends at an opened PR (never merged here, never
# merged by the worker itself).
#
# FAILS CLOSED against a doc that predates the structured-output contract:
# no ```stage3-findings block (or one that doesn't parse) means "do
# nothing, log why" — never falls back to guessing from prose.
#
# NOT wired into any automatic schedule on purpose (first build; see
# thurber-os docs/tracking/2026-08-20-stage3-build.md). Invoke by hand:
#   ./stage3-execute.sh --dry-run     # show every decision + what would fire
#   ./stage3-execute.sh               # actually spawn workers for `fired` items
#   ./stage3-execute.sh --doc <path>  # use a specific proposal doc instead of
#                                      # the latest one auto-discovered
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/engineering-stage2.sh"
. "$HERE/lib/engineering-stage3.sh"

THURBER_OS="${STAGE3_THURBER_OS_REPO:-$HOME/Code/thurber-os}"
STATE_DIR="${STAGE3_STATE_DIR:-$HERE/.local-state/engineering-stage3}"
AUDIT_LOG="$STATE_DIR/audit.jsonl"

dry_run=0
doc_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) dry_run=1; shift ;;
    --doc) doc_override="${2:?--doc requires a path}"; shift 2 ;;
    -h|--help)
      printf 'usage: stage3-execute.sh [--dry-run] [--doc <path>]\n'
      exit 0 ;;
    *) printf 'usage: stage3-execute.sh [--dry-run] [--doc <path>]\n' >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { printf 'stage3-execute: jq is required\n' >&2; exit 2; }

doc="$doc_override"
if [ -z "$doc" ]; then
  doc=$(stage2_find_latest_doc "$THURBER_OS") || {
    printf 'stage3-execute: no Stage-2 proposal doc found under %s -- nothing to do\n' "$THURBER_OS/docs/tracking" >&2
    exit 0
  }
fi
[ -f "$doc" ] || { printf 'stage3-execute: doc not found: %s\n' "$doc" >&2; exit 2; }

mkdir -p "$STATE_DIR"
now=$(stage3_now)
mode_label=LIVE; [ "$dry_run" -eq 1 ] && mode_label=DRY_RUN

findings=$(stage3_extract_findings "$doc") || {
  printf 'stage3-execute: %s has no valid ```stage3-findings``` block (missing or malformed) -- failing closed, doing nothing\n' "$doc" >&2
  stage3_audit_entry skipped-malformed-doc "" "" null "" "" \
    "doc lacks a structured stage3-findings section, or it failed to parse as a valid array" "$doc" \
    >>"$AUDIT_LOG"
  exit 0
}

count=$(printf '%s' "$findings" | jq 'length')
printf 'stage3-execute: doc=%s  findings=%s  mode=%s\n' "$doc" "$count" "$mode_label"

if [ "$count" -eq 0 ]; then
  printf 'stage3-execute: structured block present but empty -- Stage-2 found nothing Stage-3-eligible this pass\n'
  exit 0
fi

fired=0 dry_fired=0 skipped_allow=0 skipped_deny=0 skipped_rate=0 skipped_other=0

while IFS= read -r item; do
  repo=$(jq -r '.repo' <<<"$item")
  file=$(jq -r '.file' <<<"$item")
  class=$(jq -r '.class' <<<"$item")
  decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$doc" "$item" "$now" "$dry_run")
  printf '%-24s %-16s %-40s %s\n' "$decision" "$repo" "$file" "$class"
  if [ "$dry_run" -eq 1 ] && [ "$decision" = dry-run-would-fire ]; then
    printf '  -- would run: spawn-task.sh %s <branch> debug, then deliver this brief:\n' "$(stage3_repo_dir_for "$repo" 2>/dev/null || printf '<repo>')"
    line_hint=$(jq -r '.line_hint // empty' <<<"$item")
    fix_summary=$(jq -r '.fix_summary // .one_line_fix_summary // ""' <<<"$item")
    stage3_build_prompt "$repo" "$file" "$line_hint" "$class" "$fix_summary" | sed 's/^/     /'
  fi
  case "$decision" in
    fired) fired=$((fired + 1)) ;;
    dry-run-would-fire) dry_fired=$((dry_fired + 1)) ;;
    skipped-not-allowlisted) skipped_allow=$((skipped_allow + 1)) ;;
    skipped-denylist) skipped_deny=$((skipped_deny + 1)) ;;
    skipped-rate-limited) skipped_rate=$((skipped_rate + 1)) ;;
    *) skipped_other=$((skipped_other + 1)) ;;
  esac
done < <(printf '%s' "$findings" | jq -c '.[]')

printf 'stage3-execute: fired=%s dry-run-would-fire=%s skipped-not-allowlisted=%s skipped-denylist=%s skipped-rate-limited=%s skipped-other=%s\n' \
  "$fired" "$dry_fired" "$skipped_allow" "$skipped_deny" "$skipped_rate" "$skipped_other"
printf 'stage3-execute: audit trail: %s\n' "$AUDIT_LOG"
