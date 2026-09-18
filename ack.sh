#!/usr/bin/env bash
# ack.sh — "I have seen this one." Clears a finished task from Needs-attention
# without claiming it is resolved.
#
#   bash ack.sh                      # list what is waiting to be acked
#   bash ack.sh <task-id|label>...   # ack those
#   bash ack.sh --all                # ack every ready_review task
#   bash ack.sh --undo <task-id|label>...
#
# WHY. Before this there were two states for finished work: `ready_review`
# (pages forever) and `completed` (invisible). A review whose verdict is posted
# and a branch whose PR is open both need a decision that is not the worker's
# to make, so five tasks on this machine sat in Needs-attention for a day with
# nothing wrong — which is how an attention surface stops being read.
#
# AN ACK IS NOT A CLAIM THAT THE WORK IS DONE. It records that a human looked,
# which is the only thing the hub can honestly know. The marker stored is the
# task's EVIDENCE TIME, so if the worker reports again afterwards — a second
# round, a follow-up — the task comes back. Acking round one does not silence
# round two.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
[ -r "$here/config.sh" ] && . "$here/config.sh" >/dev/null 2>&1

PORT="${HERDR_HUB_PORT:-8600}"
ACK_FILE="${HERDR_ACK_FILE:-$HOME/.local/state/herdr/runs/acked.json}"

MODE=list; UNDO=0; ALL=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --all)  MODE=ack; ALL=1 ;;
    --undo) MODE=ack; UNDO=1 ;;
    --list) MODE=list ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *)  MODE=ack; ARGS+=("$a") ;;
  esac
done

# The hub is the one that knows which tasks are in which state, and it already
# derives evidence times. Asking it beats re-deriving them here and drifting.
snapshot() {
  curl -s --max-time 5 "http://127.0.0.1:${PORT}/herdr?json=1" 2>/dev/null
}

json="$(snapshot)"
[ -n "$json" ] || { echo "hub is not answering on :$PORT — start it (./restart.sh)" >&2; exit 2; }

ACK_FILE="$ACK_FILE" MODE="$MODE" UNDO="$UNDO" ALL="$ALL" \
python3 - "$json" "${ARGS[@]+"${ARGS[@]}"}" <<'PY'
import json, os, sys, pathlib, tempfile

snap = json.loads(sys.argv[1] or "{}")
wanted = sys.argv[2:]
ack_path = pathlib.Path(os.environ["ACK_FILE"])
mode, undo, do_all = os.environ["MODE"], os.environ["UNDO"] == "1", os.environ["ALL"] == "1"

try:
    acks = json.loads(ack_path.read_text())
    acks = acks if isinstance(acks, dict) else {}
except (OSError, ValueError):
    acks = {}

# Elements are checked, not assumed: a well-formed-JSON response of the wrong
# shape used to print a Python traceback from an operator tool, which is the
# shape that gets read as "the hub is broken".
tasks = [t for t in (snap.get("tasks") or []) if isinstance(t, dict)]
ready = [t for t in tasks if t.get("state") == "ready_review"]

def matches(t, key):
    return key in (t.get("task_id"), t.get("label")) or key == (t.get("label") or "").split(":")[-1]

if mode == "list":
    if not ready:
        print("Nothing is waiting to be acked.")
        # Still worth saying what IS in attention, so this is never a dead end.
        other = [t for t in tasks if t.get("state") in ("blocked", "stalled")]
        for t in other:
            print(f"  {t.get('state'):12} {t.get('label')}  (not a review — it needs a look, not an ack)")
        raise SystemExit(0)
    print("Ready for review — acking one records that you looked, not that it is done:\n")
    for t in ready:
        print(f"  {t.get('label')}")
        print(f"    task: {t.get('task_id')}")
        print(f"    pane: {t.get('pane_id')}   worktree: {t.get('worktree') or '-'}")
    print(f"\nack them: bash ack.sh --all   |   one: bash ack.sh <label>")
    raise SystemExit(0)

# TARGETS COME FROM THE ROWS THIS TOOL IS ABOUT. Drawing them from every task
# and guarding only on "evidence_at is a number" let `ack.sh pr520` write
# markers for blocked, stalled and running rows that happened to share a branch
# suffix — and those markers lie in wait: the moment such a pane goes idle with
# its evidence time unchanged, the ack fires and the row leaves every surface,
# including this tool's own listing, so `--undo` cannot even name it.
# `--undo` still searches every task, because removing a marker can only ever
# make something MORE visible.
pool = tasks if undo else ready
targets = ready if do_all else [t for t in pool for k in wanted if matches(t, k)]
if not targets:
    print(f"nothing matched: {' '.join(wanted) or '(no arguments)'}", file=sys.stderr)
    raise SystemExit(2)

changed = 0
for t in targets:
    tid = t.get("task_id")
    if not tid:
        continue
    if undo:
        if acks.pop(tid, None) is not None:
            changed += 1
            print(f"unacked: {t.get('label')}")
        continue
    # The marker is the EVIDENCE TIME the hub derived, not now(): acking must
    # not swallow a report that lands while you are typing the command.
    ev = t.get("evidence_at")
    if t.get("state") != "ready_review":
        # Belt to the `pool` braces above: a marker may only ever be written
        # for the state an ack means something about.
        print(f"refusing {t.get('label')}: state is {t.get('state')}, not ready_review", file=sys.stderr)
        continue
    if not isinstance(ev, (int, float)):
        # No evidence time to bind to. Writing `now` here would silence a report
        # that lands a second later.
        print(f"refusing {t.get('label')}: no evidence time (state {t.get('state')})", file=sys.stderr)
        continue
    acks[tid] = ev
    changed += 1
    print(f"acked: {t.get('label')}")

if changed:
    ack_path.parent.mkdir(parents=True, exist_ok=True)
    # Atomic: the hub reads this file on every page render.
    fd, tmp = tempfile.mkstemp(dir=ack_path.parent, prefix=".acked.")
    with os.fdopen(fd, "w") as fh:
        json.dump(acks, fh, indent=1, sort_keys=True)
    os.replace(tmp, ack_path)
    print(f"\n{changed} change(s) in {ack_path}")
else:
    print("nothing changed")
PY
