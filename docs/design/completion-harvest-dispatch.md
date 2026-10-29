# Completion → harvest → next-eligible-dispatch

## Problem this closes

At 13:38 every worker was idle with a finished output, but no next step was
dispatched until the conductor noticed on its own. `hub.py`'s stall watchdog
(`docs: feat/stall-watchdog`, `STALL_SIGNAL_ARTIFACTS`, signal `artifact`)
already detects exactly this shape — a task in an idle state (`stalled`,
`ready_review`) with a ready artifact (`tmp/commit-msg.txt`, `tmp/REVIEW.md`,
`.handoffs/PROOF.md`) — and wakes the conductor's pane via
`stall-watchdog.sh cmd_wake` -> `send-to-agent.sh`. The wake itself works
(`verify-stall-watchdog.sh` already proves delivery, dedup, ack, escalation).

What is missing is everything AFTER the wake lands: nothing records that the
completion was durably seen (so there is no answer to "did we already know
about this artifact" independent of whether the wake's own dedup happened to
fire), and nothing tells the conductor WHAT to dispatch next — the wake is a
bare notification, not an actionable handoff. A human has to reconstruct
"what was this lane going to do next" from scratch every time, which is
exactly the kind of manual step that goes unnoticed under load.

## Diagnosis: where the runtime actually stands today

- `hub.py:4356-4382` (`stall_watchdog_candidates`, signal 2 "artifact"): pure
  function, already correctly detects "idle + ready artifact". Not touched
  by this change — re-deriving idle/done independently in bash would
  duplicate `derive()`/`_completion_at()`'s already-hardened (9+ review
  rounds) merge logic and risk diverging from it. Out of scope, deliberately.
- `stall-watchdog.sh:cmd_wake` (bash, a fresh subprocess per `(task,
  signal)` pair hub.py hands it — not a long-running thread): composes and
  sends the wake text at two call sites (first sighting, line ~389; retry
  within the owner's window, line ~353). This is the right, LOW-risk
  integration point — testable offline with the same fake-command-seam
  style every other feature in this repo uses, isolated from hub.py's
  internals entirely.
- No "lane" or successor-queue concept exists anywhere in this codebase
  today (confirmed: no match for `lane`, `successor_queue`,
  `next_eligible`, `pending_dispatch` in `hub.py`, `stall-watchdog.sh`,
  `lib/run-registry.sh`). This is genuinely new.
- `events` is this repo's one durable, append-only fact store, already used
  for exactly this generation-counter / dedup shape repeatedly (resident
  grant, resident redemption, `_stall_boot_epoch`, `stall_request_floor`
  — "one per new max, latest wins"). Reused here, not reinvented: no new
  table, no migration.

## Design

Three new fact types, all plain `events` rows, all via `lib/run-registry.sh`
(matching `stall-watchdog.sh`'s own bash-only, no-second-daemon style — no
new Python module needed, every operation here is an idempotent insert or a
"most recent row wins" read, both of which `append_event`/`claim_once`
already provide):

1. **Completion receipt** — `type=completion_receipt`, `event_id =
   completion_receipt_<task_id>_<sha256 of the artifact's content>`.
   `claim_once`-backed: calling it twice for the SAME (task, content) is a
   no-op (the dedup the conductor asked for, "by task plus artifact sha" —
   content, not mtime, so a file rewritten with the SAME bytes after a
   restart never double-fires). A genuinely NEW artifact (different
   content) is a different event_id and receipts again, same "a
   fingerprint that changes re-arms" shape `cmd_wake`'s own dedup already
   uses for the wake itself.
2. **Successor queue (per lane)** — `type=successor_queued`, a FRESH row
   every call (`append_event`, not `claim_once`): the conductor can replan.
   `payload={lane, next, queued_by, queued_at}`. Read by `ORDER BY sequence
   DESC LIMIT 1` for that lane — `events.sequence` is already an
   AUTOINCREMENT PK, so "latest wins" needs no generation counter in the
   payload (unlike `stall_request_floor`, which predates relying on
   `sequence` directly). `next` is a free-form string the conductor writes
   at queue time (e.g. "spawn implement on herdr-control
   feat/foo") — this script never parses it as a command; it exists to make
   the wake actionable, not to issue a spawn.
3. **Lane hold** — `type=lane_hold`, a FRESH row every call,
   `payload={lane, state: held|released, reason}`. Read the same
   "latest row for this lane wins" way. A lane with a `held` row more
   recent than any `released` row is held; a HELD lane's successor is
   never surfaced in a wake (but its own completion receipt still records
   — the hold blocks surfacing the NEXT step, not recording what already
   finished). Because every row is scoped to one lane key, holding lane A
   touches no row belonging to lane B — independent lanes are independent
   event streams, never a shared flag.
4. **Lane assignment** — `type=lane_assignment`, `event_id =
   lane_assignment_<task_id>`, `claim_once`-backed (first assignment wins,
   immutable — a task does not change lanes mid-flight). A task with no
   assigned lane has, by construction, no queued successor; nothing here
   invents a lane for an unassigned task.

### Wake integration (the only code-flow change, confined to `cmd_wake`)

Before composing `$msg` at EITHER existing wake call site, if `$signal` is
`artifact` or `handoff` (the two completion-shaped signals — `denied`,
`unprocessed`, `conductor_prompt` are not "a worker finished" and are left
alone):

1. If an artifact path was given and the file exists in the task's
   worktree, hash it and call `record_completion_receipt`.
2. Look up the task's lane (`read_lane_for_task`); if assigned and not
   held, look up its queued successor (`read_successor_for_lane`).
3. If a successor was found, append it to the SAME wake message text as an
   extra line: `Pre-planned next: <next>`. Nothing new is sent, delivered,
   or dispatched — the existing `_sw_send_and_record` call is reused
   unchanged, carrying a longer string. No new authority is exercised: the
   conductor still reads the wake and decides to spawn it, exactly as
   today for a wake with no pre-plan.

### What this does NOT do (authority boundary)

- **Never calls `spawn-task.sh` or any launch path.** The successor is a
  STRING the conductor reads, never code this script executes. Auto-
  dispatching a successor would need the same kind of structural
  authorization the resident-launch-grant feature required (REVIEW-
  GRANT-9ac2fc4) — out of scope here, not inferred, and NOT something this
  change's existing authority covers ("no grants, no new access").
- **Never assigns a lane automatically.** `assign_lane`/`queue_successor`/
  `hold_lane`/`release_lane` are a new, narrow, human/conductor-invoked CLI
  surface (`lib/run-registry.sh` functions, callable directly or via a thin
  wrapper script the same shape as `grant-resident-escalation.sh`) — not
  wired into `spawn-task.sh` itself. A task with nothing pre-planned for it
  gets exactly today's bare wake, unchanged.
- **Never touches `hub.py`.** Detection stays exactly as it is; this only
  changes what `stall-watchdog.sh` says once hub.py has already decided to
  wake.

## Rollback

The new branch in `cmd_wake` is additive before the existing `local msg=...`
line: no lane assigned, no receipt recorded, or no successor queued all
degrade to byte-for-byte today's message. Deleting the new
`lib/run-registry.sh` functions and the two `cmd_wake` call sites restores
exact prior behavior; no schema migration to reverse (plain `events` rows).

## Tests required

1. **Missed event**: a completion artifact appears, `cmd_wake` records the
   receipt and wakes; a SECOND, unrelated wake call for the same task/signal
   with the SAME artifact content must not re-record a receipt (dedup) but
   must still wake per the wake's own existing dedup/escalation rules —
   proves the receipt layer never interferes with the pre-existing wake
   ladder.
2. **Restart mid-transition**: receipts and successor rows are plain
   `events` rows, so a process restart mid-sequence loses nothing — a fresh
   `cmd_wake` invocation after a simulated restart (fresh shell, same
   registry file) reads back the SAME latest successor/hold state a
   continuous process would have seen.
3. **Duplicate events (dedup)**: `record_completion_receipt` called twice
   for the identical (task, artifact content) is a no-op the second time
   (claim_once semantics); called with DIFFERENT content for the same task
   is a new receipt (re-arms, matching `cmd_wake`'s own fingerprint
   semantics).
4. **Held lane isolation**: lane A held, lane B not — a completion on a
   task in lane B still surfaces lane B's queued successor; a completion on
   a task in lane A surfaces no successor (but its receipt still records).
   Releasing lane A restores its successor visibility on the next wake,
   with no effect on lane B at any point.
