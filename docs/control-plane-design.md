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
| Wake persistence (SessionStart reconciliation) | `agent-hooks/session-reconcile.sh`, `lib/reconcile.sh`, `lib/run-registry.sh` (`all_task_files`, `read_checkpoint`/`write_checkpoint`) | Runs on every conductor `SessionStart`: (a) reconciliation sweep — any task still `starting`/`running`/`blocked` whose registered pane no longer exists, or whose live `terminal_id` no longer matches the `pane_birth` fingerprint recorded at spawn, is transitioned to `lost`; (b) reports every task now in a terminal state (`completed`/`failed`/`blocked`/`lost`/`cancelled`) that a per-conductor checkpoint hasn't already shown, then updates that checkpoint. The checkpoint lives under the registry dir (`~/.local/state/herdr/runs/checkpoints/<conductor_id>.json`), never in a repo. Wired via `install.sh` as a synchronous (`async:false`) `SessionStart` hook — the only one that must NOT be async, since its `hookSpecificOutput.additionalContext` needs to land before the session's first turn. |
| Wake persistence, mid-session (interval reconciliation) | `agent-hooks/interval-reconcile.sh`, `lib/run-registry.sh` (`checkpoint_age_s`) | The same sweep+report as above, wired as `PostToolUse` instead of `SessionStart`, so a long-lived session gets reconciliation without restarting. Throttled to once per `HERDR_RECONCILE_INTERVAL_S` (default 300s) via the checkpoint file's own mtime — most tool calls cost one `stat`. Activity-gated, not a real timer: see "designed, not built" item 1. |
| Pane-birth revalidation at delivery time | `lib/pane-guard.sh` (`pane_birth_now`, `require_pane_birth_match`), `lib/run-registry.sh` (`task_for_pane`), `herdr-select.sh`, `agent-hooks/claude-notify.sh`, `spawn-task.sh` (`conductor_pane_birth`) | Closes the TOCTOU gap the review called the most dangerous unhit failure: pane ids are RECYCLED, so a wake or an answer aimed at a bare pane id can land in an unrelated later process. `herdr-select.sh` looks up the registered task for its target pane (`task_for_pane`) and refuses (`exit 7`) if the pane's live `terminal_id` no longer matches what was registered. `claude-notify.sh` does the mirror check on the CONDUCTOR side, using a new `conductor_pane_birth` fingerprint `spawn-task.sh` now captures at registration time (the worker's own `pane_birth` was already tracked; the conductor's pane was not). Both are mandatory whenever the pane IS registered — a pane spawned outside the registry (`spawn-agent.sh`) has nothing to check, so it is unaffected, the same backward-compatible principle as `--expect-prompt-id`. |

All eight were tested live against real herdr panes (not just `bash -n`):
`sort-tabs.sh` against a scratch workspace with a genuine agent-recognized
pane and a bare shell; the full spawn→register→push-wake→blocked-state→event
chain against a scratch conductor pane and a real worktree spawn (cleaned up
after); `--expect-prompt-id` against both a matching and a deliberately wrong
id; the agent-pane gate against a bare shell conductor pane (confirmed: no
text delivered, nothing executed); `session-reconcile.sh` against a
hand-registered fake task marked `completed` (reported exactly once, silent on
a second run) and a fake task marked `running` against a `pane_id`/`pane_birth`
pair absent from a live `herdr pane list` (transitioned to `lost` and reported
exactly once); `interval-reconcile.sh`'s throttle (immediate re-run silent,
`HERDR_RECONCILE_INTERVAL_S=0` still silent when nothing new via
`--quiet-if-empty`); pane-birth revalidation against a real scratch pane
running a throwaway `node` script printing a fake numbered prompt — a
registration with the pane's actual live fingerprint let `herdr-select.sh`
press a real key (confirmed via the pane's own transcript), a registration
with a deliberately wrong fingerprint made it refuse (`exit 7`) with the pane
transcript byte-for-byte unchanged afterward; the same match/refuse pair
proven for `claude-notify.sh`'s conductor-side check (delivered text on
match, silently refused + logged a `push_wake_refused` event on mismatch,
pane transcript unchanged) — see this PR's description for the exact commands
run. Installing the hooks for real (`install.sh --apply --repoint`) also
incidentally proved Claude Code's settings hot-reload: OTHER already-running
sessions on the same machine picked up `interval-reconcile.sh` and started
calling it within one tool call of the settings write, no restart observed
to be necessary.

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

## Built in round 2 (2026-08-01)

Round 1 above built the SHAPE and is left as written — it is the record of that
round, not a live description of the code. Round 2 closed corrections 2, 4, 5
and 6 and made omp a first-class agent. Where the two disagree, this section
wins.

**Superseded rows in the round-1 table:** the registry is no longer
`~/.local/state/herdr/runs/<run_id>/` JSON files plus a per-run `events.jsonl` —
it is one SQLite database at `~/.local/state/herdr/runs/registry.sqlite3`.
`all_task_files()` is gone (it emitted file paths); `all_tasks_json()` replaces
it with one JSON object per line. Legacy task files, events and checkpoints are
imported once, non-destructively, on first use — dropping a running worker's
registration would silently disable recycled-pane refusal for it, which is a
safety regression that produces no error.

| Piece | File | What it does |
|---|---|---|
| SQLite registry (correction 4) | `lib/run-registry.sh` | Real monotonic `sequence` (AUTOINCREMENT, replacing `grep -c` count-then-append, which collided silently under concurrent writers); `UNIQUE(event_id)` so an at-least-once retry dedups instead of double-logging; a state change and its event in ONE transaction (the prior fix could only SUPPRESS the event when the state write failed); `task_id` as PRIMARY KEY so an id collision fails loudly instead of overwriting a live registration; enforced state transitions (`completed -> running` is refused); `events_since`/`advance_event_cursor` as a cursor over the EVENT STREAM, which the file layout could not express at all |
| Approval lifecycle (correction 6) | `lib/run-registry.sh` (`approval_decided`/`approval_attempted`/`approval_confirmed`), `lib/push-wake.sh`, `herdr-select.sh` | Three distinct records, so "decided and typed nothing" can no longer read the same as "the agent received it". Wakes likewise record `wake_attempted` then `wake_result` carrying `send-to-agent.sh`'s real outcome (`submitted`/`unsubmitted`/`refused`/`transport_error`) — that exit status existed all along and was discarded by a fire-and-forget `\|\| true` |
| Adapter capabilities (correction 5) | `lib/agent-profiles.sh` (`agent_capabilities`, `answer_strategy_for_agent`) | "Bare digit, never Enter" was hardcoded protocol knowledge and was already wrong for omp, whose menu wants arrow keys and Enter. Now declared per agent (`numbered-prompt`, `menu-prompt`, `summariser`, `push-hook`); an agent declaring nothing is refused an automated answer rather than guessed at |
| Operational vs authorization (correction 8) | `lib/command-policy.sh`, `herdr-select.sh` (`--authority`, exit 8) | A conductor AGENT calling `herdr-select.sh` previously looked exactly like a person. Under `--authority peer` the prompt's command is normalized (heredoc/quote/ANSI-C/`$()` to depth 8) and classified; anything not `allow` is refused with no key pressed. Under `human` the verdict is still recorded — a person may approve a destructive command, but it is attributable |
| Posture floor | `lib/posture.sh`, `config.sh` (`HERDR_POSTURE_FLOOR`) | `yolo`<`write`<`strict`, composed by taking the MORE restrictive of floor and request, so a spawn can tighten and never loosen. Unknown names fail closed to `strict`. codex is deliberately unmapped and gets no flag — inventing one would either break the spawn or falsely imply enforcement |
| omp push hooks | `agent-hooks/omp-herdr-control.ts`, `omp-notify.sh`, `omp-reconcile.sh`, `install.sh` | omp workers PUSH when blocked instead of waiting to be noticed by a poll. Installed globally as a symlink into omp's user-level auto-discovery root, so parity with `~/.claude/settings.json` rather than a per-repo `.omp/` |

Verified by five suites at the repo root, 166 checks total:
`verify-run-registry.sh` (42 — including 20 concurrent writers proving unique
sequences, and a SQL-injection attempt through a task label), `verify-posture.sh`
(49), `verify-command-policy.sh` (25), `verify-select-policy.sh` (29 — runs the
REAL `herdr-select.sh` against a stubbed herdr and asserts that on every refusal
NO KEY IS PRESSED), `verify-omp-hooks.sh` (21).

### Still open after round 2

- **Correction 3, half of it.** `.omc/handoffs/events.jsonl` is still repo-local
  and still separate from the registry. A worker's completion evidence and its
  lifecycle state remain in two places.
- **Correction 1's timer.** Interval reconciliation is still activity-gated: an
  idle session with no tool calls gets none until its next tool call. A true
  wall-clock timer needs a daemon.
- **Backpressure.** No debounce, priority, fairness or coalescing. omp's alert
  path is bounded only because it stays silent unless a prompt actually painted;
  N simultaneously-blocked workers still produce N injections.
- **Classification sees only the VISIBLE pane.** A command scrolled out of view
  cannot be judged, which is part of why peer authority is opt-in rather than
  the default.
- **omp menu answering** has been exercised only against the 2-option
  `Allow tool: bash` shape; the N-row path is written generically but unproven.

## The review's numbered corrections — status

The review's numbered corrections, as a roadmap. Round 1 (2026-07-27) built the
shape; round 2 (2026-08-01) closed 2, 4, 5 and 6 — see the section above, which
wins where the per-correction notes below still read as unbuilt.

### 1 — Push does not replace polling; it's push + reconciliation (partially built)

> "push for responsiveness + periodic reconciliation for correctness" — push
> alone cannot detect a crashed worker, a dead hook, a wedged worker that
> never emits an input-needed event, a tmux restart, or laptop sleep.

Built: `agent-hooks/session-reconcile.sh` runs the reconciliation sweep
described here — inspects every registered task's pane against the live
`herdr pane list`, transitions anything whose pane is gone or recycled to
`lost`, and rebuilds what the conductor gets told after a restart via the
per-conductor checkpoint. `agent-hooks/interval-reconcile.sh` extends this
to run DURING a live session too (throttled `PostToolUse`, default every
300s), so a conductor that stays open for hours no longer waits for a
restart to learn a worker went `lost` or completed. **Not built**: the
interval sweep is activity-gated (it only checks on a tool call), not a
real independent timer — a session sitting fully idle (no tool calls) gets
no reconciliation until its next tool call or the next `SessionStart`. No
leases, no expiry independent of activity. A true wall-clock timer would
need a background daemon, which is out of scope for a Claude Code hook.
`wait-for-blocked.sh`-style polling is not a stopgap to delete once push
works. Needed: a reconciliation sweep — inspect registered panes, expire
leases, detect missed events, rebuild conductor state after a restart — on
some interval, independent of whether push fired. Not built.

### 2 — Identity and lifecycle (CRITICAL — partially built)

> Pane ids are recycled. A delayed wake or answer can hit an unrelated future
> process. Needs run_id/task_id/worker_id/pane_id **plus a pane birth
> fingerprint**, a conductor id, and an explicit lifecycle
> (created→starting→running→blocked→running→completed, with
> failed/cancelled/lost as distinct terminal states). "Idle", "blocked",
> "complete", and "pane exists" must never be conflated.

Built: the five-way identity tuple, the birth fingerprint (`terminal_id`),
`starting`/`running`/`blocked` transitions via `set_task_state`, a real `lost`
terminal state (`agent-hooks/session-reconcile.sh` / `interval-reconcile.sh`
revalidate every non-terminal task's `pane_id`/`pane_birth` against a live
`herdr pane list`), and — the part this correction actually emphasizes —
fingerprint revalidation IMMEDIATELY BEFORE LIVE DELIVERY, not just during
reconciliation. `herdr-select.sh` now refuses (`exit 7`) to press a key if the
target pane's live `terminal_id` no longer matches the `pane_birth` its
registered task recorded (`lib/pane-guard.sh`'s `require_pane_birth_match`,
via `lib/run-registry.sh`'s `task_for_pane` reverse lookup). `claude-notify.sh`
does the mirror check before a push wake, using a new `conductor_pane_birth`
field `spawn-task.sh` now captures for the CONDUCTOR's own pane (previously
only the worker's pane had a fingerprint — the delivery direction this
correction is actually about had nothing to check). Both are proven both
ways: matching fingerprint delivers exactly as before, mismatched fingerprint
refuses with the target pane provably untouched (see "Built this round").
**Built in round 2**: the transition-rule table is now enforced in
`set_task_state` — `completed`/`failed`/`cancelled`/`lost` are real terminal
states and nothing leaves them, so a stale hook firing after the sweep already
buried a task cannot resurrect it. An illegal transition is refused with a
diagnostic rather than written. `blocked` is deliberately NOT terminal even
though it is reported like one: a worker waiting on a prompt resolves back to
`running` routinely. **Still not built**: a `created` pre-registration state,
which nothing has needed.

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

**Built in round 2** — this correction is closed, by taking the review's own
suggestion ("a small SQLite db"). `lib/run-registry.sh` is now one database at
`~/.local/state/herdr/runs/registry.sqlite3` in WAL mode, and each named gap maps
to a primitive rather than to careful shell:

- *sequence numbers were count-then-append* → `INTEGER PRIMARY KEY AUTOINCREMENT`,
  a real monotonic counter that never reuses a value. Proven with 20 concurrent
  writers: 20 rows, 20 distinct sequences.
- *duplicate events on retry* → `UNIQUE(event_id)` plus an optional caller-supplied
  id, so an at-least-once producer retries into a no-op. `lib/push-wake.sh` uses
  this: a repeated wake for the same task and prompt writes the same rows once.
- *atomic append* → a transaction. The state change and its event now land
  together; the previous design could only SUPPRESS the event when the state
  write failed, which is compensation, not atomicity.
- *consumer cursor loss* → `events_since` / `advance_event_cursor`, a cursor over
  the event stream. Advancing is separate from reading on purpose: a consumer
  that read events and then crashed must be able to see them again.
- *concurrent writers* → `.timeout` (the CLI dot-command; `PRAGMA busy_timeout=N`
  returns a row and would corrupt every query's output).

The checkpoint over task state is kept alongside it — it answers "what changed
since I last looked", which is a different and still-useful question from "which
events have I never seen".

### 5 — Prompt answering has a TOCTOU race (partially built)

> Validating option 2 is visible then typing 2 is check-then-use. Between
> inspection and delivery the prompt can vanish, options can change, the pane
> can restart, another message can alter the composer, or the pane id can now
> mean something else. Needs a `prompt_id` from stable captured content,
> revalidated immediately before injection. Also: "never send Enter" is a
> TUI implementation detail, not a protocol invariant — encode it as an
> adapter capability.

Built: `prompt_id()` and `herdr-select.sh --expect-prompt-id` (content-level:
is this still the same QUESTION), tested against both a match and a
deliberate mismatch — plus, this round, `require_pane_birth_match`
(identity-level: does this pane id still mean the same PROCESS), covering
the correction's other named case — "the pane id can now mean something
else" — which `prompt_id` alone does not: a recycled pane running a
different agent could show a superficially similar-looking prompt and still
pass a content check. Unlike `--expect-prompt-id`, the pane-birth check is
unconditional wherever the pane is registered, not opt-in, since there is no
safe default that skips it.

**Built in round 2**: the adapter abstraction exists as declared per-agent
capabilities in `lib/agent-profiles.sh` (`agent_capabilities`,
`answer_strategy_for_agent`) rather than as a class per TUI. `numbered-prompt`
means "press the bare digit, never Enter"; `menu-prompt` means "arrow to the row,
confirming the highlight after every keystroke, then Enter". `herdr-select.sh`
dispatches on that instead of carrying the convention as protocol knowledge —
which it had already outgrown, since omp's menu wants the exact opposite of
Claude's digit. An agent that declares neither is refused an automated answer
rather than guessed at.

### 6 — Delivery semantics are unspecified

> Exactly-once is unrealistic; use at-least-once with idempotent consumers. A
> wake needs an ACK from the conductor. An answer needs three separate
> records: decision recorded / delivery attempted / delivery
> confirmed-or-timed-out. Recording a choice before pressing must not imply
> it was delivered.

**Built in round 2.** `lib/push-wake.sh` (new, shared by the Claude and omp
notify hooks so the two entry points cannot drift) writes `wake_attempted`
BEFORE the send and `wake_result` after it, carrying `send-to-agent.sh`'s real
outcome — `submitted` / `unsubmitted` / `refused` / `transport_error`. Those exit
codes existed all along and were thrown away by a fire-and-forget `|| true`, so
"the conductor was woken" and "we typed at a pane and never looked" recorded
identically. Both events use stable ids derived from the task and prompt, so an
at-least-once retry dedups rather than double-logging.

`herdr-select.sh` likewise now writes three separate records —
`approval_decided` / `approval_attempted` / `approval_confirmed` — so a run that
dies at a failed `send-keys` leaves `decided_at` and `attempted_at` set with
`confirmed_at` NULL, which is exactly the state that used to be
indistinguishable from success.

**Still not built**: an ACK *from* the conductor (that it read the wake, not
merely that the text submitted), and retry. The outcome is recorded; nothing
acts on a `refused` result yet.

## Also flagged, not yet triaged into the numbered list

From Gemini's review, corroborating rather than duplicating the above:

- **Signal storms** — a busy repo with many simultaneous blocked prompts could
  flood the conductor; needs debounce per worker or a queue summary instead
  of N immediate pane injections. Round 2 bounded one side of this by
  accident of design rather than by solving it: `omp-notify.sh` fires on every
  `tool_call` but stays silent unless a prompt actually painted, so
  auto-approved calls cost nothing. N genuinely-blocked workers still produce N
  injections.
- **Wake cycles** — worker A waits on worker B waits on worker A; should
  alert the human rather than attempt to resolve automatically.
- **Task summary on every wake** — partially addressed (`HERDR_TASK_LABEL` is
  included), but a conductor juggling ten workers still can't reconstruct
  full context from a one-line label alone.

## Multi-agent portability (2026-07-31, updated 2026-08-01)

This whole design assumed one CLI (Claude Code, secondarily Codex). Widening it
to any recognized agent — `lib/agent-profiles.sh` — is mostly mechanical
(process-name allowlist, model-routing table, launch flags), verified live
against `omp` (Oh My Pi): `pane_is_agent`, `spawn-task.sh`'s model routing, and
`smart-name.sh`'s `omp -p` summariser path all confirmed end-to-end against a
real herdr pane.

**The two pieces this section previously listed as open are now closed.**

*Answering omp's prompt.* `herdr-select.sh` drives the `Allow tool: <name>` /
`Approve` / `Deny` menu: it walks the highlight with Down/Up and confirms the
move after every keystroke by reading the row's ANSI 24-bit background-colour
escape (plain-text scraping cannot see the highlight at all, which is why this
needed `--format ansi`), then presses Enter. Bounded at 20 presses so a
pathological or wrapping menu cannot spin. Which mechanism an agent needs is now
declared, not sniffed — capability `menu-prompt` vs `numbered-prompt` in
`lib/agent-profiles.sh` — which is also the adapter abstraction correction 5
asked for. The "record the choice before pressing" invariant maps onto menu
navigation unchanged: the decision is recorded once, before the first keystroke.

*Pushing when blocked.* omp workers were reconciliation-only because
`install.sh` wired Claude hooks and nothing else. `agent-hooks/omp-herdr-control.ts`
is an omp extension module, installed as a symlink into omp's **user-level**
auto-discovery root (`~/.omp/agent/extensions/`, honouring `PI_CODING_AGENT_DIR`)
— cwd-independent, so it is genuine parity with a global
`~/.claude/settings.json` rather than a per-repo `.omp/`. Operator kill switch:
`disabledExtensions: [extension-module:herdr-control]`.

The event mapping is not one-to-one, and the difference matters. Claude has a
`Notification` event meaning "I am asking the human something", so its hook is
told. omp's nearest surface is `tool_call`, which fires before EVERY tool call.
Alerting straight off that would be a self-inflicted signal storm, so
`omp-notify.sh` polls the worker's own pane and exits silently unless a prompt
actually painted. That also makes it approval-mode-agnostic for free: under
`--approval-mode yolo` nothing prompts, so nothing alerts, with no need to mirror
which mode omp was launched at.

| Claude hook | omp event | job |
|---|---|---|
| `Notification` | `tool_call` | verify a prompt painted, then alert + push wake |
| `SessionStart` (`additionalContext`) | `before_agent_start` | reconciliation report, returned as an injected message |
| `PostToolUse` | `tool_result` | throttled interval reconcile + alert retraction |
| `Stop` | `agent_end` | retraction backstop |

One hard safety note on that shim: omp's tool dispatch is **fail-closed** — a
handler that throws BLOCKS the tool call. So every handler is exhaustively
wrapped and returns `undefined` on all paths. A monitoring shim that can wedge
the agent it monitors is strictly worse than no shim.

**Remaining omp gaps.** The menu path has been exercised only against the
2-option `Allow tool: bash` shape; the N-row code is written generically but
unproven. `send-to-agent.sh`'s `_PROMPT_OMP` false-positive risk against a
genuine Claude prompt was never empirically closed (distinct exact phrases, so
structurally low risk). And a manually-started omp session has no
`HERDR_PANE_ID`, so it cannot verify a prompt and stays reconciliation-only —
the same deal a hand-started Claude session gets for its push wake.

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
