#!/usr/bin/env bash
# write-handoff.sh — append one session handoff to every notepad that needs it,
# then mark each as synced into the mnemopi bank.
#
#   write-handoff.sh <handoff.md> <notepad.md> [notepad.md ...]
#
# Why this exists: the handoff has to land in several notepads (a project's
# .omc/ AND .omx/ so either harness resumes, plus thurber-os for cross-repo
# state), and doing that by hand means a `cat >>` per file, per session, plus a
# manual duplicate check, plus the mark-synced call. That was repeated four
# times in a single session on 2026-09-02.
#
# The appending is the trivial part. The part worth automating is the DUPLICATE
# GUARD: notepads are append-only and long, a re-run silently doubles a section,
# and the duplicate is only visible later as two identical "## Completed"
# blocks that disagree about what is done. This keys on the handoff's first
# heading and refuses to write it twice, so re-running is safe.
#
# Marking synced reuses ~/.omp/agent/scripts/mnemopi-mark-notepad-synced.sh
# rather than reimplementing its cursor bookkeeping.
set -euo pipefail

MARK="$HOME/.omp/agent/scripts/mnemopi-mark-notepad-synced.sh"

usage() {
    echo "usage: write-handoff.sh <handoff.md> <notepad.md> [notepad.md ...]" >&2
    exit 2
}

HANDOFF="${1:-}"; [ -n "$HANDOFF" ] || usage
shift
[ "$#" -gt 0 ] || usage

[ -f "$HANDOFF" ] || { echo "write-handoff: no such file: $HANDOFF" >&2; exit 1; }
[ -s "$HANDOFF" ] || { echo "write-handoff: $HANDOFF is empty — refusing" >&2; exit 1; }

# Dedupe key: the first markdown heading. Without one there is nothing stable to
# match on, so refuse rather than append something that can never be detected as
# a duplicate later.
KEY="$(grep -m1 '^#\{1,2\} ' "$HANDOFF" || true)"
if [ -z "$KEY" ]; then
    echo "write-handoff: $HANDOFF has no '# ' or '## ' heading to key on — refusing" >&2
    exit 1
fi
echo "write-handoff: key = ${KEY}"

wrote=0 skipped=0 failed=0
for np in "$@"; do
    if [ ! -f "$np" ]; then
        echo "  MISSING  $np (not created — a notepad path you did not expect is a mistake, not a new file)" >&2
        failed=$((failed + 1)); continue
    fi
    if grep -qF "$KEY" "$np"; then
        echo "  skip     $np (already has this handoff)"
        skipped=$((skipped + 1)); continue
    fi
    cat "$HANDOFF" >> "$np"
    printf '  wrote    %s (now %s lines)\n' "$np" "$(wc -l < "$np" | tr -d ' ')"
    wrote=$((wrote + 1))
    if [ -x "$MARK" ]; then
        "$MARK" "$np" >/dev/null 2>&1 && echo "           marked synced" \
            || echo "           WARN could not mark synced" >&2
    fi
done

printf 'write-handoff: wrote=%d skipped=%d failed=%d\n' "$wrote" "$skipped" "$failed"
[ "$failed" -eq 0 ]
