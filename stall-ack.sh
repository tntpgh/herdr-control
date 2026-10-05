#!/usr/bin/env bash
# stall-ack.sh — "I have acted on this one." Stops a stall-watchdog wake from
# repeating or escalating for a task.
#
#   stall-ack.sh <task_id>              # ack every open stall-watchdog signal
#   stall-ack.sh <task_id> <signal>     # ack just one signal: handoff | artifact | denied | unprocessed | conductor_prompt
#
# AN ACK IS NOT A CLAIM THE WORK IS DONE — same philosophy as ack.sh's own
# "a human looked" marker, applied to a stall wake instead of a ready_review
# row. A signal whose fingerprint later CHANGES (the artifact is rewritten,
# a fresh denial lands) re-arms on its own regardless of any earlier ack —
# acking today's handoff does not silence tomorrow's.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

task_id="${1:?usage: stall-ack.sh <task_id> [signal]}"
signal="${2:-all}"

bash "$here/stall-watchdog.sh" ack "$task_id" "$signal"
printf 'stall-ack: acked %s for task %s\n' "$signal" "$task_id"
