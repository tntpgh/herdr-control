# Conductor/worker control plane — design + roadmap

Provenance: a `/consensus` review run 2026-07-27 (`gpt-5.6-sol` and `gemini`
critiquing a proposal, both attached in full below) against real failures hit
driving a multi-repo build the same day. This document is the roadmap that
review produced. **It is a design document, not a changelog** — see "Built
this round" for what actually exists in code, and "Designed, not built" for
everything else. Do not treat a line item here as implemented unless it is
listed under Built.

## The observed problem

One conductor session drives workers in other repos, each in its own herdr
pane. In a single session this broke four ways:

1. A worker blocked on a permission prompt and sat idle; the conductor only
   noticed on a manual poll, repeatedly, after the human already had.
2. `herdr agent wait --until done` returns empty — the agent-status
   integration is unreliable (documented in the herdr-ops skill).
3. The conductor's delivery guard (`send-to-agent.sh`'s
   `looks_like_permission_prompt`) refused a legitimate message to a busy
   worker, mistaking on-screen content for a permission prompt. The only
   channel to a worker can be closed by a false positive — including, per the
   review, the wake message this document adds.
4. `sort-tabs.sh --all --mark` marked panes across every workspace as
   "working", including bare shells with no agent running.

(4) was fixed directly — see the sibling PR on `orch-hardening` (defects 1–7:
sort-tabs agent gating, preview.sh CLI-signature/proof/daemon-health fixes,
`.omc/handoffs` scaffolding, `wake-on-evidence.sh`). This document covers the
rest: a real push channel for (1)/(3) and the identity/durability foundation
underneath it.

## Built this round

Scoped deliberately narrow: the identity/registry **shape**, Edge 1 (push
wake) working end-to-end for a single worker, and the two defensive
correction items that make that edge not obviously wrong. Not a fleet-scale
control plane — see "Designed, not built" for the rest.

| Piece | File | What it does |
|---|---|---|
| Central run registry | `lib/run-registry.sh` | `register_task`, `set_task_state`, `append_event`, `read_task` against `~/.local/state/herdr/runs/<run_id>/` — NOT inside any worktree |
| Task identity at spawn | `spawn-task.sh` | Generates `run_id`/`task_id`/`worker_id`/`conductor_id`, records the worker pane's `terminal_id` as a birth fingerprint, registers the task, stamps all five identities (plus `HERDR_TASK_LABEL`) into the worker's own shell env, transitions `starting`→`running` |
| Push wake (Edge 1) | `agent-hooks/claude-notify.sh` | On an alert-worthy Notification event, if the worker was stamped with a conductor pane, sends a `[HERDR-PEER-SIGNAL]`-prefixed message naming the worker/pane/task and a `prompt_id`, via `send-to-agent.sh` — gated on `pane_is_agent` first (send-to-agent.sh does not enforce that itself), transitions the task to `blocked`, appends an `input_required` event to the central registry |
| TOCTOU-safe answering (Edge 3 hardening) | `lib/prompt-parse.sh` (`prompt_id`), `herdr-select.sh` (`--expect-prompt-id`) | A stable hash of the current question+options; `herdr-select.sh` optionally revalidates it immediately before pressing anything and refuses if the prompt has changed since the id was captured. Backward compatible — omit the flag and behavior is unchanged. |
| Wake persistence (SessionStart reconciliation) | `agent-hooks/session-reconcile.sh`, `lib/run-registry.sh` (`all_task_files`, `read_checkpoint`/`write_checkpoint`) | Runs on every conductor `SessionStart`: (a) reconciliation sweep — any task still `starting`/`running`/`blocked` whose registered pane no longer exists, or whose live `terminal_id` no longer matches the `pane_birth` fingerprint recorded at spawn, is transitioned to `lost`; (b) reports every task now in a terminal state (`completed`/`failed`/`blocked`/`lost`/`cancelled`) that a per-conductor checkpoint hasn't already shown, then updates that checkpoint. The checkpoint lives under the registry dir (`~/.local/state/herdr/runs/checkpoints/<conductor_id>.json`), never in a repo. Wired via `install.sh` as a synchronous (`async:false`) `SessionStart` hook — the only one that must NOT be async, since its `hookSpecificOutput.additionalContext` needs to land before the session's first turn. |

All five were tested live against real herdr panes (not just `bash -n`):
`sort-tabs.sh` against a scratch workspace with a genuine agent-recognized
pane and a bare shell; the full spawn→register→push-wake→blocked-state→event
chain against a scratch conductor pane and a real worktree spawn (cleaned up
after); `--expect-prompt-id` against both a matching and a deliberately wrong
id; the agent-pane gate against a bare shell conductor pane (confirmed: no
text delivered, nothing executed); `session-reconcile.sh` against a
hand-registered fake task marked `completed` (reported exactly once, silent on
a second run) and a fake task marked `running` against a `pane_id`/`pane_birth`
pair absent from a live `herdr pane list` (transitioned to `lost` and reported
exactly once) — see this PR's description for the exact commands run.

### What was deliberately left alone

- `send-to-agent.sh`'s `looks_like_permission_prompt` regex — **not
  touched**. The review flagged it can false-positive (proposal problem #3:
  "mistaking its todo-list checkboxes for a permission prompt"; Gemini,
  independently: "the wake message itself can be blocked by the delivery
  guard"), but the exact trigger wasn't reproduced, and this regex has
  already been tightened once before to stop a different false-positive
  class (see the file's own history). Patching a safety-relevant heuristic
  on a guess risks reintroducing the bug it already fixed. What got built
  instead is the two things both reviews concretely asked for: a
  machine-readable `[HERDR-PEER-SIGNAL]` marker so a wake is never
  ambiguous with an instruction once delivered, and `--expect-prompt-id`
  revalidation for the answering side. If the false-positive recurs, capture
  the actual on-screen content that tripped it — the regex needs a real
  reproduction, not another guess.
- `.omc/handoffs/events.jsonl` (the worker→conductor completion channel from
  the sibling PR) is **unchanged** — still repo-local. The review's
  central-registry critique (correction 3) was applied to the NEW push-wake
  state (task lifecycle, `input_required` events), not retrofitted onto the
  existing completion-evidence channel. Unifying them is listed below.

## Designed, not built

The review's numbered corrections, as a roadmap. None of this exists in code.

### 1 — Push does not replace polling; it's push + reconciliation (partially built)

> "push for responsiveness + periodic reconciliation for correctness" — push
> alone cannot detect a crashed worker, a dead hook, a wedged worker that
> never emits an input-needed event, a tmux restart, or laptop sleep.

Built: `agent-hooks/session-reconcile.sh` runs the reconciliation sweep
described here — inspects every registered task's pane against the live
`herdr pane list`, transitions anything whose pane is gone or recycled to
`lost`, and rebuilds what the conductor gets told after a restart via the
per-conductor checkpoint. **Not built**: it only runs on `SessionStart`, not
"on some interval" — a conductor that stays open for hours without restarting
gets no reconciliation until it does. No leases, no expiry independent of a
session boundary. `wait-for-blocked.sh`-style interval polling inside a live
session remains undone.

### 2 — Identity and lifecycle (CRITICAL — partially built)

> Pane ids are recycled. A delayed wake or answer can hit an unrelated future
> process. Needs run_id/task_id/worker_id/pane_id **plus a pane birth
> fingerprint**, a conductor id, and an explicit lifecycle
> (created→starting→running→blocked→running→completed, with
> failed/cancelled/lost as distinct terminal states). "Idle", "blocked",
> "complete", and "pane exists" must never be conflated.

Built: the five-way identity tuple, the birth fingerprint (`terminal_id`),
`starting`/`running`/`blocked` transitions via `set_task_state`, and now a
real `lost` terminal state — `agent-hooks/session-reconcile.sh` revalidates
every non-terminal task's `pane_id`/`pane_birth` against a live `herdr pane
list` and transitions to `lost` on a mismatch or missing pane. **Not built**:
`completed`/`failed`/`cancelled` are used by convention (a worker or operator
sets them) but have no enforced transition-rule table (nothing stops
`completed` -> `running`, for instance), there is still no `created`
pre-registration state, and the fingerprint revalidation that now happens at
`SessionStart` does NOT happen before a push wake or an answer is delivered
mid-session — `claude-notify.sh` and `herdr-select.sh` still act on a pane id
without re-checking its birth first. The reuse scenario the correction warns
about is closed for the reconciliation path, not the live-delivery path.

### 3 — Control-plane state does not belong in the worker repo (built for the NEW state; not retrofitted)

> Repos should hold task artifacts, not the orchestration queue — a worktree
> cleanup deletes the control plane, and a conductor ends up watching ten
> repos instead of one authoritative inbox.

Built: `lib/run-registry.sh` puts task identity and lifecycle events under
`~/.local/state/herdr/runs/<run_id>/`, not in any worktree — and now the
consumer checkpoint that reads that state also lives there
(`~/.local/state/herdr/runs/checkpoints/<conductor_id>.json`), not in a repo,
so a worktree cleanup can't reset what a conductor has already been shown.
**Not built**: migrating or unifying the existing `.omc/handoffs/events.jsonl`
completion channel into the same store — a worker's completion evidence and
its lifecycle state currently live in two different places.

### 4 — JSONL is durable, not reliable

> Partial writes after interruption, duplicate events on retry, concurrent
> writers, consumer cursor loss after a conductor restart, truncation/
> rotation, events from different runs mixed together. Needs event ids,
> atomic append, consumer checkpoints, dedup, explicit run scoping — or a
> small SQLite db / one-file-per-event spool.

`lib/run-registry.sh`'s `append_event` has event ids and per-run scoping
(one `events.jsonl` per `run_id`, `event_id` = `<run_id>_<sequence>`) but
**explicitly not** the rest: writes are not atomic (no lock, no
temp-file+rename), sequence numbers are count-then-append (not a real
monotonic counter under concurrent writers). This is the known weakest part
of what got built; treat every number in the file above as "good enough for
one worker being watched synchronously," not as a queue a fleet can trust.

**Partially built**: a consumer checkpoint now exists
(`read_checkpoint`/`write_checkpoint`), but it is a checkpoint over **task
state** (`task_id` -> last-reported `state`+`updated_at`), not over the
**event stream** — a restarting conductor now knows which task-state
transitions it has already been shown, but nothing dedups or checkpoints
`events.jsonl` itself line-by-line. A task that changes state twice between
two reconciliation runs is reported once (its latest state), with the
intermediate transition never surfaced — correct for "tell me what changed,"
not sufficient for "replay every event exactly once."

### 5 — Prompt answering has a TOCTOU race (partially built)

> Validating option 2 is visible then typing 2 is check-then-use. Between
> inspection and delivery the prompt can vanish, options can change, the pane
> can restart, another message can alter the composer, or the pane id can now
> mean something else. Needs a `prompt_id` from stable captured content,
> revalidated immediately before injection. Also: "never send Enter" is a
> TUI implementation detail, not a protocol invariant — encode it as an
> adapter capability.

Built: `prompt_id()` and `herdr-select.sh --expect-prompt-id`, tested against
both a match and a deliberate mismatch. **Not built**: the adapter
abstraction (`ClaudeCodeAdapter.answer_prompt()` etc.) that would let a
different TUI or a version change declare its own safe submit behavior
instead of "bare digit, never Enter" being hardcoded protocol knowledge.

### 6 — Delivery semantics are unspecified

> Exactly-once is unrealistic; use at-least-once with idempotent consumers. A
> wake needs an ACK from the conductor. An answer needs three separate
> records: decision recorded / delivery attempted / delivery
> confirmed-or-timed-out. Recording a choice before pressing must not imply
> it was delivered.

Not built at all. The push wake in `claude-notify.sh` is fire-and-forget
(`|| true`) with no ACK, no retry, and no distinction between "delivery
attempted" and "delivery confirmed" — `send-to-agent.sh`'s own exit codes
(SUBMITTED/UNSUBMITTED/REFUSED) are available and currently discarded by the
wake call. `herdr-select.sh`'s existing "record before sending" pattern
satisfies "decision recorded" but conflates it with "delivery attempted" —
there is no separate "confirmed" record.

## Also flagged, not yet triaged into the numbered list

From Gemini's review, corroborating rather than duplicating the above:

- **Signal storms** — a busy repo with many simultaneous blocked prompts could
  flood the conductor; needs debounce per worker or a queue summary instead
  of N immediate pane injections.
- **Wake cycles** — worker A waits on worker B waits on worker A; should
  alert the human rather than attempt to resolve automatically.
- **Task summary on every wake** — partially addressed (`HERDR_TASK_LABEL` is
  included), but a conductor juggling ten workers still can't reconstruct
  full context from a one-line label alone.

## Full critiques (attached verbatim)

<details>
<summary>gpt-5.6-sol (codex) — round 2</summary>

## 1. What's strong

The proposal correctly identifies the architectural direction: push-based
signaling, durable state, and explicit ownership are substantially better
than scraping terminal output.

Particularly strong:

- Separating a peer signal from human authorization is the right safety
  invariant.
- Rejecting terminal text as completion evidence avoids echo and scrollback
  false positives.
- Making layout commands observational rather than authoritative fixes a
  real category error.
- Preserving Slack as an independent notification path gives useful
  redundancy.
- Recording answers is valuable for auditability.
- The proposal is grounded in observed failures rather than hypothetical
  scaling concerns.

The core diagnosis is right: the current system lacks a reliable control
channel and a durable task model.

## 2. What's weak or missing

The proposal still treats TUI text injection as more of the control plane
than it should. It creates durable completion events, but wakes and answers
remain tied to pane identity and terminal presentation. That is acceptable
only as a last-mile adapter.

The largest missing pieces are:

### No task identity or state machine

"Worker pane" is not a durable identity. Pane IDs can be reused after a pane
exits. A delayed event could wake or answer an unrelated future process.

Each task needs: `run_id`, `task_id`, `worker_id`, pane ID plus pane birth
fingerprint, conductor ID, monotonic event sequence or unique event ID,
explicit lifecycle state.

At minimum: `created → starting → running → blocked → running → completed`,
with `failed`/`cancelled` branches and `running → lost`.

"Idle," "blocked," "complete," and "pane exists" must not be conflated.

### JSONL is durable but not necessarily reliable

Unaddressed failure modes: partial writes after interruption, duplicate
events after retries, concurrent writers, cursor loss after conductor
restart, file truncation or rotation, worktree/repository cleanup removing
state, events from multiple historical runs mixed together, watching ten
repositories instead of one authoritative inbox.

A JSONL file can work initially, but only with an event ID, atomic append
assumptions, consumer checkpoints, deduplication, and explicit run scoping.
A small SQLite database or atomic one-file-per-event spool would be safer.

Control-plane state should not live inside the worker repository. Put it
under a central runtime directory such as
`~/.local/state/herdr/runs/<run_id>/`. Repositories should contain task
artifacts and handoff reports, not the orchestration queue itself.

### No delivery semantics

Best effort / at least once / exactly once / acknowledged / retried — the
proposal doesn't say. Exactly-once delivery is unrealistic; use at-least-once
events with idempotent consumers. A wake needs an acknowledgment from the
conductor. An answer needs separate records for decision recorded, delivery
attempted, delivery confirmed or timed out. Recording the choice before
pressing is good, but that record must not imply successful delivery.

### Prompt answering still has a race

Validating option 2 is visible then typing 2 is a
time-of-check/time-of-use race. Between inspection and delivery: the prompt
could disappear, the options could change, the pane could restart, another
message could alter the composer, the pane ID could now refer to something
else.

Every prompt needs a `prompt_id` derived from stable captured content, and
the answer operation must revalidate immediately before injection. Also,
"never Enter" is an implementation detail, not a durable invariant —
different TUIs or versions may require different submission behavior.
Encode this in an adapter capability, not the protocol.

### No recovery or liveness model

Completion events solve normal completion, not worker crash, hook crash,
conductor crash, tmux server restart, laptop sleep, repository deletion, a
worker wedged without producing an input-needed event, or a task completing
after the conductor exits. Needs heartbeats or leases and a `lost` state.
Polling should not be eliminated entirely: push handles latency;
reconciliation polling repairs missed events. The robust pattern is "push
for responsiveness + periodic reconciliation for correctness."

### Completion evidence is underspecified

A worker-authored `completed` line is a claim, not proof. It should include
expected deliverable paths, repository and worktree, base and resulting
commit SHA if applicable, dirty-worktree status, commands run, exit codes,
test summary, known gaps. The conductor then verifies the completion
contract independently — this directly protects against "verified locally
but not actually delivered."

### Missing backpressure and fairness

At ten workers, the main problem is not event volume — it's simultaneous
blocked prompts and conductor attention. Needs priority, prompt age,
per-task deadline, coalescing repeated wake events, bounded retry, fairness
between workers, escalation for authorization-sensitive prompts, a queue
summary rather than ten immediate pane injections. Rate limiting alone can
suppress the one wake that matters.

### Trust boundaries need stronger provenance

Any worker capable of writing the event file can impersonate another worker
unless events are bound to a run/task registration. At minimum verify:
registered task identity, expected repo/worktree, current pane fingerprint,
conductor relationship, event schema and allowed transitions. Less about
hostile code than preventing stale or accidental cross-run messages.

## 3. Specific recommended changes

1. Introduce a central run registry: `~/.local/state/herdr/runs/<run_id>/state.sqlite`
   (SQLite WAL mode if practical; otherwise atomic event files renamed into
   an inbox).
2. Assign stable identities at spawn: `run_id`, `task_id`, `worker_id`,
   `conductor_id`, `pane_id`, `pane_birth` (server-start:pid:start-time),
   `repo`, `worktree`.
3. Define a versioned event envelope: `schema`, `event_id`, `run_id`,
   `task_id`, `worker_id`, `sequence`, `type`, `occurred_at`, `payload`.
4. Use explicit terminal states: `completed`, `failed`, `cancelled`, `lost`.
   Do not make "idle" a terminal state.
5. Keep push notifications, but add reconciliation every few seconds:
   inspect registered panes, expire leases, consume missed events, detect
   invalid state transitions, rebuild the conductor dashboard after restart.
6. Treat TUI injection as a versioned adapter (`inspect_prompt()`,
   `deliver_peer_message()`, `answer_prompt()`) — the protocol should not
   promise "bare digit, never Enter"; the adapter determines safe behavior
   for the detected UI/version.
7. Require prompt-bound answers: `prompt_id = sha256(normalized prompt +
   options + task_id)`, `selected_option`, `selected_text`, `decided_by`,
   `authority`. Revalidate the prompt and pane fingerprint immediately
   before injection.
8. Separate operational questions from authorization questions. Peer
   automation may answer only allowlisted operational prompts; destructive,
   credential, production, or scope-changing prompts must escalate to the
   human.
9. Make completion a structured claim followed by conductor verification.
   Never equate the event with acceptance.
10. Make layout state derived: `displayed state = registered task state +
    live pane reconciliation`. Layout tools may rearrange or annotate panes,
    but may not create task-state assertions.

## 4. Verdict

This is not fundamentally a pile of patches, but it becomes one if pane
injection and repository JSONL files are treated as the control plane.
Promote durable task identity, lifecycle state, acknowledgments, and
reconciliation to the center. Keep tmux and Claude Code text injection as
carefully validated edge adapters. At ten workers, the likely first failure
is not throughput — it is stale identity, missed events, and prompt races.
The most dangerous unhit failure is a delayed answer being injected into a
reused pane and accepted by the wrong task.

</details>

<details>
<summary>Gemini — round 2</summary>

### 1. What's strong about this proposal

- **Durable Evidence Over Terminal Scraping**: moving away from `wait output
  --match` to a `.omc/handoffs/events.jsonl` file is the single most
  important architectural upgrade — replaces a fragile, timing-dependent TUI
  hack with a deterministic state machine.
- **The "Peer Signal" Invariant**: decoupling "Wake" from "Authorization" is
  critical — treating worker messages as data to verify rather than commands
  to execute prevents the conductor from becoming a puppet of its own
  sub-processes.
- **Validated Answering**: `herdr-select.sh` recording the choice before
  sending the digit provides an audit trail that doesn't currently exist in
  TUI-driven orchestration.

### 2. What's weak or missing

- **"Conductor Context" Poisoning**: injecting text into the conductor pane
  is still a pile of patches. If the conductor is mid-plan and a worker
  injects "Worker 4 blocked: 1/2/3", that text becomes part of the
  conductor's own thought process — "Context Drift" where the conductor
  forgets its original goal to address the interruption.
- **Race Conditions in Answering**: `herdr-select.sh` sends a bare digit; if
  the worker's UI shifts just as the digit is sent, it could trigger an
  unintended action. No Focus Verification.
- **The "Interrupt Storm"**: at 10 workers, if 4 hit permission prompts
  simultaneously, the conductor's input buffer floods. Without a priority
  queue or signal buffer, the conductor likely crashes or hallucinates.

### 3. Specific recommended changes

- **"Signal Inbox" for the conductor**: instead of text injection, workers
  write "Wake" events to a central `conductor/signals.jsonl`; the conductor
  polls at the *start* of its turn rather than having text shoved into its
  buffer mid-stream.
- **Prompt-verification for answering**: `herdr-select.sh` should take an
  optional `--verify "string"` flag — screen-scrape to confirm the expected
  prompt is actually visible before sending the digit.
- **Pane-ID ownership in layout commands**: refactor layout scripts to only
  affect panes matching a specific `CONDUCTOR_SESSION_ID`, preventing
  phantom-agent marking of bare shells.
- **Structured handoff schema**: define `events.jsonl` immediately with
  `timestamp`, `worker_id`, `type` (HEARTBEAT|BLOCKED|DONE|FAIL), `payload`.

### 4. Revised proposal sections

**Edge 1 — The Signal Inbox (out-of-band signaling)**: workers don't "talk"
to the conductor's terminal — they write to
`conductor/inbox/<conductor_id>.jsonl`. On `input-needed`, the worker appends
a `BLOCKED` event with the prompt text and options; the conductor-ops skill
checks this inbox at every "checkpoint," keeping the conductor's context
clean.

**Edge 3 — Verified selection**: `herdr-select.sh` becomes a safety tool —
capture the last 5 lines of the target worker pane, regex-match the
requested options are present, log the intention to `events.jsonl`, and send
the bare digit only if the match succeeds; if the prompt has changed, alert
the conductor: "Worker state desync: expected prompt not found."

**Failure mode at scale**: the failure mode nobody has hit yet is
**Livelock** — Worker A blocked on Worker B, Worker B blocked waiting for
the conductor to approve Worker A's previous step. A central `events.jsonl`
and Signal Inbox enable a Dependency Graph in the conductor to detect these
circular waits before the session freezes.

</details>

## Note on this document's own provenance

This document was written after the underlying `/consensus` run's raw output
files (under `/tmp/claude/consensus_orch_control_plane_20260727_201952/`)
were independently verified to exist, be freshly timestamped, and match the
same incidents already fixed in the sibling PR — before any of the code
above was written. `/tmp` is not durable storage; this file is the durable
copy.
