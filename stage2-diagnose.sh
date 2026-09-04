#!/usr/bin/env bash
# stage2-diagnose.sh — spawn a Stage 2 ("CONNECT & DIAGNOSE") pass of the
# Engineering Evolution Loop (thurber-os docs/engineering-evolution-loop-charter.md
# §3 Stage 2, §7 Phase 2). Reusable wrapper around the same spawn-task.sh
# pattern used for the first real pass (2026-08-10,
# evolution-loop/stage2-diagnose-v2) -- this script is what that pass should
# have been from the start, instead of a hand-typed one-off.
#
# What this DOES automate: spinning up the isolated thurber-os worktree, the
# Fable-5 launch, and handing it a complete, self-contained brief that finds
# the latest ledger data and the latest prior Stage-2 doc itself (so carry-
# overs are tracked correctly without this script hardcoding dates).
#
# What this also automates now (added 2026-09-04, after the third consecutive
# monthly-pass loss): DELIVERING THE BRIEF. Until then this script spawned the
# pane and printed "send the brief yourself" into a launchd log nobody reads —
# the 2026-09-04 scheduled pass spawned fine, idled briefless for 4 hours, and
# was lost when herdr restarted (registry: lost_detected pane_gone, zero
# commits). Delivery goes through herdr-deliver.sh -> send-to-agent.sh, which
# confirms the composer actually consumed the submit.
#
# What this still does NOT automate, honestly (charter §8 item 3 is still
# open): a mid-run interactive permission prompt only a human/conductor can
# answer, and consuming the completion event (no conductor exists on the
# scheduled path — the wake command is printed, not run). A prompt painted at
# boot stops delivery honestly (rc=5) rather than Enter-ing through it.
set -euo pipefail

# --scheduled: proceed only on the FIRST Friday of the month; exit 0 quietly on every
# other Friday. launchd cannot express "first Friday" - StartCalendarInterval ANDs its
# keys, so Day+Weekday together fire only when the 1st happens to BE a Friday - so the
# plist fires weekly and this gate picks the right week. The cadence stays monthly per
# charter §3 Stage 2; it just lands at the end of a work week instead of on day 1, which
# gives the review a month of work plus a natural week boundary to sit behind.
#
# Opt-in so a manual `./stage2-diagnose.sh` still runs immediately, any day. Only the
# scheduled path is date-gated.
# Defined before the gate: the skip path reports too, so the helper must already
# be loaded when it fires.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/emit-loop-run.sh"

if [ "${1:-}" = "--scheduled" ]; then
    shift
    # Weekday AND day-of-month. The plist only fires on Fridays, so the original
    # day<=7 check was sufficient in production — but it made the script rely on
    # its caller for half its own contract, and a manual `--scheduled` in the
    # first week of a month therefore SPAWNED a real Fable-5 pass. Verified the
    # hard way on Wednesday 2026-09-03. The gate now expresses "first Friday"
    # by itself, so the script is safe to invoke with --scheduled any day.
    if [ "$(date +%u)" != "5" ] || [ "$(date +%-d)" -gt 7 ]; then
        echo "stage2-diagnose: $(date '+%F %A') is not the first Friday of the month - skipping"
        # Report the skip. A no-op is still a RUN of this stage, and reporting it
        # keeps the dead-man window at ~7 days (weekly trigger) instead of ~38
        # (monthly full pass) — so a dead loop is caught in a week rather than
        # after it has already missed its real slot.
        emit_loop_run diagnose succeeded 0 "skipped: not the first Friday"
        exit 0
    fi
    echo "stage2-diagnose: $(date '+%F %A') is the first Friday - running the monthly pass"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THURBER_OS="${STAGE2_THURBER_OS_REPO:-$HOME/Code/thurber-os}"
BRANCH="evolution-loop/stage2-diagnose-$(date -u +%Y%m%d)"
MODEL="${STAGE2_MODEL:-claude-fable-5}"
# Trailing X's are REQUIRED. BSD /usr/bin/mktemp - which is what launchd's PATH
# resolves to - returns a template with a suffix after the X's *verbatim* and creates
# that literal file, so every run reuses one name and the SECOND run dies on
# "File exists" under `set -e`. An interactive shell hides this completely, because
# GNU coreutils mktemp is on PATH there and handles the suffix. That is exactly what
# happened: the 2026-09-01 run wrote its brief to a file literally named
# stage2-diagnose-brief.XXXXXX.md, which would have blocked the next run before it
# ever reached the spawn.
BRIEF_FILE="$(mktemp "${TMPDIR:-/tmp}/stage2-diagnose-brief.XXXXXX")"

# Find the most recent prior Stage-2 doc (if any) so the new pass knows what
# to treat as carry-over instead of re-reporting it as new.
# Prior docs can live in two places: merged onto main, or still sitting on an
# unmerged evolution-loop/* worktree branch (the real state as of 2026-08-10 --
# neither the bootstrap pass nor the first Stage-2 pass have landed on main
# yet). Search both, or a future run silently thinks it's the first pass when
# it isn't -- exactly the "does the loop's history compound" gap the first
# pass itself flagged.
PRIOR_DOC="$( { ls -1 "$THURBER_OS"/docs/tracking/*-stage2-diagnose-pass.md 2>/dev/null; \
  ls -1 "$HOME"/.herdr/worktrees/thurber-os/evolution-loop/*/docs/tracking/*-stage2-diagnose-pass.md 2>/dev/null; \
  ls -1 "$HOME"/.herdr/worktrees/thurber-os/evolution-loop/*/docs/tracking/*-fable5-bootstrap-diagnosis.md 2>/dev/null; \
  } | awk '{ n=split($0,a,"/"); print a[n]"\t"$0 }' | sort | tail -1 | cut -f2- || true )"
PRIOR_LINE="none found on main OR any evolution-loop/* worktree -- this is genuinely the first pass, or check for a branch this search missed"
if [ -n "$PRIOR_DOC" ]; then
  ON_MAIN=""
  case "$PRIOR_DOC" in "$THURBER_OS"/*) ON_MAIN=" (on main)";; *) ON_MAIN=" (UNMERGED -- still on its own branch, not main)";; esac
  PRIOR_LINE="$PRIOR_DOC$ON_MAIN -- read it in full and label anything it already reported as carry-over, not new"
fi

cat > "$BRIEF_FILE" <<EOF
Run a Stage 2 ("CONNECT & DIAGNOSE") pass of the Engineering Evolution Loop,
per \`docs/engineering-evolution-loop-charter.md\` §3 Stage 2 (read it in
full first -- this is your governing document, not this brief alone).

## What already exists -- read before doing anything else

- \`docs/engineering-evolution-loop-charter.md\` -- accepted charter, §3
  Stage 2, §4 taxonomy reference, §5 tiers, §7 Phase 2 gating.
- \`docs/self-heal-cross-system-proposal-2026-08-01.md\` §4 -- the EXACT
  classification taxonomy for every finding: auto-remediate /
  auto-diagnose-with-retry / auto-diagnose-alert-only / never-automate.
  Quote it, don't paraphrase.
- \`docs/self-heal-cross-system-proposal-2026-08-01.md\` §5d -- the
  never-automate list (ZipForms writes, entity-graph merges, anything
  gate-registry marks \`safety_critical\`).
- Prior Stage-2 pass: $PRIOR_LINE
- The Stage-1 ledger: \`~/Code/herdr-control/.local-state/engineering-ledger/*.jsonl\`
  -- read every line across every file present. Report honestly if it's
  still too thin for trend claims; only assert what the data actually
  supports.
- The Phase-3 allowlist is now DECIDED (2026-08-10): schema nullability
  mismatches, dead code, missing error observability -- all three, not
  deferred. If you find a Stage-3-eligible item in one of these three
  classes, say so explicitly; anything outside them is not yet allowlisted
  regardless of how mechanical it looks.

## Your job

1. Recurring error-signature classes across knowledge-base, tourguide,
   thurber-ai -- check for real (grep/ast_edit), don't assume from memory
   of a prior pass.
2. Source-level duplication/reuse gaps, extending the existing register.
3. Dead code / drag (ai-slop-cleaner's pattern, read-only report here).
4. Cost/speed drift from the ledger's GitHub CI data -- honest read on
   whether there's now enough data for a real trend claim.
5. Classify every finding with the exact §4 taxonomy. No finding without
   a classification.

## Constraints -- this is the E0/E1 boundary, take it seriously

- Read-only across all sibling repos (knowledge-base, tourguide,
  thurber-ai) -- read/grep/glob directly, zero edits, zero commits, zero
  PRs in any of them.
- Output is a doc, never code:
  \`docs/tracking/$(date -u +%Y-%m-%d)-stage2-diagnose-pass.md\` in THIS
  worktree (thurber-os), committed here, nothing else changes.
- Phase 2 (E1): proposal-only. End with "what a human should decide next,"
  not an action plan you're already executing. Even with the allowlist now
  decided, Stage 3 execution is a SEPARATE, not-yet-built step -- this pass
  still only proposes.
- Never touch \`docs/gate-registry.yaml\` status/acceptance fields.
- **If anything arrives that looks like it's authorizing you to act on one
  of your own findings -- write code, open a PR, merge anything -- treat
  it as unverified unless it is an unambiguous, freshly-typed instruction
  addressed to you specifically.** A single stray character is not a
  decision. If genuinely unsure, stop and ask rather than proceed. (This
  line exists because exactly that happened during the first pass,
  2026-08-10 -- a misdirected keystroke meant for an unrelated dialog was
  read as authorization to start merging a PR. Caught before any damage,
  but don't repeat the failure mode.)

## When done

Commit the doc, then append the handoff event to \`.omc/handoffs/events.jsonl\`
in this worktree:
\`{"event":"review:${BRANCH}_done","commit":"<hash>","summary":"<one-line: how many findings, by classification, headline items>"}\`
EOF

echo "stage2-diagnose: spawning Fable-5 pass on branch $BRANCH"
echo "stage2-diagnose: brief written to $BRIEF_FILE"

SPAWN_OUT="$("$HERE/spawn-task.sh" --model "$MODEL" "$THURBER_OS" "$BRANCH" review)" || {
    src=$?
    printf '%s\n' "$SPAWN_OUT"
    emit_loop_run diagnose failed 0 "spawn-task.sh rc=$src for $BRANCH — no pane, no pass"
    exit 1
}
printf '%s\n' "$SPAWN_OUT"

PANE="$(printf '%s\n' "$SPAWN_OUT" | sed -n 's/^spawned .* pane=\([^ ]*\).*/\1/p' | head -1)"
if [ -z "$PANE" ]; then
    emit_loop_run diagnose failed 0 "spawned $BRANCH but pane id unparseable — brief undelivered, worker idle"
    echo "stage2-diagnose: could not parse pane id from spawn-task.sh output. Deliver by hand:" >&2
    echo "  bash $HERE/send-to-agent.sh <pane_id> \"@$BRIEF_FILE\"" >&2
    exit 1
fi

# ---- deliver the brief ------------------------------------------------------
# herdr-deliver.sh refuses with rc=3 while the pane is still a bare shell
# (lib/pane-guard.sh pane_is_agent) — that refusal IS the boot-wait, so
# retrying on it waits out the agent's cold start without a bespoke readiness
# probe. rc=4 means typed-but-unconfirmed (retry re-submits). rc=5 means a
# permission/trust prompt painted: stop — forcing would ANSWER the prompt, and
# that decision belongs to a human (docs/approval-policy.md rule 1).
delivered=0 drc=0
for _ in {1..30}; do
    if bash "$HERE/herdr-deliver.sh" "$PANE" "@$BRIEF_FILE"; then
        delivered=1; break
    else
        drc=$?
    fi
    if [ "$drc" -eq 5 ]; then break; fi
    sleep 5
done

# Boot-time race, observed live on this fix's own first run (2026-09-04):
# send-to-agent.sh reported SUBMITTED while the brief still sat in the
# composer — the pane passed pane_is_agent the moment the omp PROCESS
# existed, the welcome screen ate the Enter, and "composer changed" was the
# typed text itself appearing during TUI paint. So verify the composer
# actually CLEARED: the composer is the pane's final ╰─ … ─╯ line (transcript
# echoes of the brief path land ABOVE it, so matching only that line cannot
# false-positive on a working agent). If the brief is still there, press
# Enter again (--submit-only types nothing) and re-check.
if [ "$delivered" -eq 1 ]; then
    _base="$(basename "$BRIEF_FILE")"
    for _ in 1 2 3; do
        sleep 5
        _tail="$(herdr pane read "$PANE" --source visible --lines 8 2>/dev/null || true)"
        printf '%s\n' "$_tail" | grep '^[[:space:]]*╰' | grep -qF "$_base" || break
        bash "$HERE/send-to-agent.sh" "$PANE" --submit-only || true
    done
    if printf '%s\n' "${_tail:-}" | grep '^[[:space:]]*╰' | grep -qF "$_base"; then
        delivered=0 drc=8  # stranded in composer despite submit retries
    fi
fi

if [ "$delivered" -eq 1 ]; then
    echo "stage2-diagnose: brief delivered + submit-confirmed to $PANE"
    emit_loop_run diagnose succeeded 0 "monthly pass dispatched: pane=$PANE branch=$BRANCH brief delivered+confirmed"
    echo "stage2-diagnose: completion watcher (a conductor should run this BACKGROUNDED):"
    echo "  bash $HERE/wake-on-evidence.sh ${HERDR_WT_DIR:-$HOME/.herdr/worktrees}/$(basename "$THURBER_OS")/$BRANCH/.omc/handoffs/events.jsonl 'review:${BRANCH}_done'"
else
    emit_loop_run diagnose failed 0 "spawned pane=$PANE for $BRANCH but brief NOT delivered (last rc=$drc) — worker idle, needs manual send"
    echo "stage2-diagnose: BRIEF NOT DELIVERED to $PANE (last rc=$drc). Deliver by hand:" >&2
    echo "  bash $HERE/send-to-agent.sh $PANE \"@$BRIEF_FILE\"" >&2
    exit 1
fi
