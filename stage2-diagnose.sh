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
# What this does NOT automate, honestly (charter §8 item 3 is still open):
# the spawned session can still hit an interactive permission prompt (a
# network-egress command, an unusual file category) that only a human /
# conductor session can answer -- exactly what happened during the first
# real pass. Firing this from launchd with nobody watching means it may
# just sit at such a prompt until someone checks the pane. That is a real
# limitation, not silently papered over: §8 item 3 (persistent conductor vs
# scheduled job) is the actual fix, and remains Terrence's call.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/engineering-stage2.sh"
THURBER_OS="${STAGE2_THURBER_OS_REPO:-$HOME/Code/thurber-os}"
BRANCH="evolution-loop/stage2-diagnose-$(date -u +%Y%m%d)"
MODEL="${STAGE2_MODEL:-claude-fable-5}"
BRIEF_FILE="$(mktemp "${TMPDIR:-/tmp}/stage2-diagnose-brief.XXXXXX.md")"

# Find the most recent prior Stage-2 doc (if any) so the new pass knows what
# to treat as carry-over instead of re-reporting it as new. lib/engineering-
# stage2.sh's stage2_find_latest_doc is the SAME search stage3-execute.sh
# uses to find the doc it consumes -- one implementation, not two that can
# drift apart.
PRIOR_LINE="none found on main OR any evolution-loop/* worktree -- this is genuinely the first pass, or check for a branch this search missed"
if PRIOR_DOC="$(stage2_find_latest_doc "$THURBER_OS")"; then
  PRIOR_LINE="$PRIOR_DOC ($(stage2_doc_location_label "$THURBER_OS" "$PRIOR_DOC")) -- read it in full and label anything it already reported as carry-over, not new"
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
6. For every finding classified \`auto-remediate\` or
   \`auto-diagnose-with-fix\` AND allowlisted per the Phase-3 allowlist
   above, ALSO add a structured entry to the Stage-3 output block below --
   see "Structured Stage-3 output" section. This is new as of the
   G-ELOOP-E2 build (2026-08-20): earlier passes' free-text-only docs are
   exactly what taught Stage-3 it needs this, since a prose-only doc gives
   an automated consumer nothing safe to parse.

## Structured Stage-3 output -- REQUIRED, even if empty

Stage-3 (\`stage3-execute.sh\`) parses this doc mechanically and fails
closed (does nothing, logs why) if this fenced block is missing or
malformed -- so get the shape exactly right, and include it even when you
found zero Stage-3-eligible items (an empty array, not a missing block, is
how Stage-3 tells "ran, found nothing" apart from "doc predates this
contract").

At the very end of the doc, after everything else, add exactly one fenced
block tagged \`stage3-findings\` containing a JSON array. One object per
eligible finding (auto-remediate or auto-diagnose-with-fix AND allowlisted):

\`\`\`stage3-findings
[
  {"repo": "knowledge-base", "file": "connectors/imessage.py", "line_hint": 388, "class": "missing_error_observability", "fix_summary": "one sentence: what's wrong and the fix"}
]
\`\`\`

Field rules -- Stage-3 validates these mechanically, so:
- \`repo\`: exactly one of \`knowledge-base\`, \`tourguide\`, \`thurber-ai\`
  (the literal directory name, not a display name).
- \`file\`: path relative to that repo's root.
- \`line_hint\`: your best-guess line number (integer), or \`null\` if you
  don't have one -- Stage-3 treats it as a hint to re-verify, not ground
  truth.
- \`class\`: exactly one of the three allowlist slugs --
  \`schema_nullability_mismatch\`, \`dead_code\`, \`missing_error_observability\`.
  Do not invent new class names here; anything else is dropped by Stage-3
  as not-allowlisted regardless of how you classified it in prose above.
- \`fix_summary\`: one sentence, plain text, no secrets/PII (same discipline
  as everything else in this doc).

Never include a finding here that touches ZipForms writes, entity-graph
merge/dedup, \`kb.action_queue\`'s outbound-send path, or thurber-ai's
dispatch/tier/policy/send code -- Stage-3 denylists those file paths
mechanically too, but don't rely on that backstop; those are never-automate
per §5d regardless of class.

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

Commit the doc (the structured \`stage3-findings\` block included), then
append the handoff event to \`.omc/handoffs/events.jsonl\` in this worktree:
\`{"event":"review:${BRANCH}_done","commit":"<hash>","summary":"<one-line: how many findings, by classification, headline items>"}\`
EOF

echo "stage2-diagnose: spawning Fable-5 pass on branch $BRANCH"
echo "stage2-diagnose: brief written to $BRIEF_FILE"

"$HERE/spawn-task.sh" --model "$MODEL" "$THURBER_OS" "$BRANCH" review

echo "stage2-diagnose: spawned (background, not blocking). Send the brief to"
echo "the new pane with send-to-agent.sh once it's up, e.g.:"
echo "  bash $HERE/send-to-agent.sh <pane_id> \"@$BRIEF_FILE\""
