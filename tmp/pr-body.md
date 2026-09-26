## Evidence (live registry, 2026-09-26, task_20260926T170628Z_167_1682, pane w2F:p4)

```
37805 input_required 17:42:06Z prompt_id 195be899… command: git commit -m "docs(policy): grant header comment matches -u/--set-upstream push shape"
37806 wake_held      17:42:06Z prompt_id 195be899… reason "allow-class and unreserved; a peer may answer it"
37808 approval_escalated 17:42:06Z run_id='' task_id='' {"verdict":"reserved","reason":"merge, governance, push, or control weakening remains human-only","pane":"w2F:p4"}
```

`herdr-select.sh` looked up the registry row before `push_wake` had written it, judged the raw scraped panel instead (whose commit message contains the word "push"), and refused a grant-allowable commit as reserved — while the alert gate independently HELD the conductor's wake for the same prompt ("a peer may take it"). Gate says peer, peer says human; nobody is woken until the 90s grace timer or a human notices.

## Changes

1. **herdr-select.sh waits briefly for the registry row (peer, approve only).** When `authority=peer`, `declining=0`, the pane is a registered task, and no `input_required` row exists yet for the current prompt, poll for the row's *existence* (never for a non-empty command — a command-less prompt legitimately records `command:""`) for up to `HERDR_SELECT_RECORD_WAIT_S` seconds (default 4, clamped 0..15). New helper `wait_for_input_required_row` in `lib/scoped-policy.sh`.
2. **The peer refusal event carries the task's own identity.** `approval_escalated` now records `own_run`/`own_task` (not the empty `HERDR_RUN_ID`/`HERDR_TASK_ID` on this edge path) plus `prompt_id`.
3. **A held wake is released the moment a peer refuses the same prompt.** New `release_wake_hold` (`lib/push-wake.sh`) claims the SAME idempotency key `grace_realert` uses (`grace_realert_${run}_${task}_${pid}` via `claim_once`), records `wake_hold_released`, and delivers the conductor wake immediately (detached) through the identical forced-wake command `grace_realert`'s own 90s re-check would fire — factored into shared helper `_pw_forced_wake_argv` so the two paths can never drift.
4. **The reverse order: a hold is never taken after a peer refusal.** `push_wake` now checks for an existing `approval_escalated` row on this exact `(task, prompt_id)` before holding; if one exists, it delivers immediately instead.
5. **The hook records a command only for the prompt that actually shows it.** `push_wake` corroborates the recorded command against the live panel (`approval_command_text`) before writing it into `input_required`; on a mismatch the row gets `command:""`, `command_uncorroborated:true`, and a `command_hint` (first 200 chars), and an empty command is passed to `human_must_answer` for that call.

## What did not change

- `lib/command-policy.sh`, `lib/run-registry.sh`, `lib/reconcile.sh` untouched.
- Approve stays fail-closed: a registry command disagreeing with the panel still refuses.
- `push_wake`'s per-attempt recording is unchanged.
- `agent-edge.sh`'s `HERDR_EDGE_PEER_ANSWER` opt-in default is unchanged.

## Tests (new cases, extending existing suites, written before the fix)

- `verify-select-policy.sh`: the race (delayed row → `grant`, not raw-panel `reserved`), a command-less row never waits, no row ever appears → bounded fallback, `approval_escalated` carries `own_run`/`own_task`/`prompt_id`, held-then-refused → `wake_hold_released` + forced `wake_attempted` + `grace_realert_*` claim taken. Plus two PR #155 carry-over gaps: the mid-token-wrap Approve-refusal case now also asserts the "does not match what is on screen" stderr text, and the peer Deny-on-mismatch case now asserts the approvals row's `command` is the panel scrape, not empty.
- `verify-alert-gate.sh`: an early release's claim stops the late 90s grace timer from delivering a second wake.
- `verify-omp-hooks.sh`: an `approval_escalated` row for the exact prompt stops `push_wake` from holding and it delivers immediately instead; a corroborated recorded command passes through unchanged; an uncorroborated one (panel shows A, hook fires with B) is dropped with `command_uncorroborated:true` + `command_hint`, and delivery is gated on the corroborated (absent) text.

## Suite results

_Placeholder — the conductor runs these in this worktree, both failing-before (unfixed code, new tests) and passing-after, and pastes the lines here:_

- `verify-select-policy.sh`:
- `verify-alert-gate.sh`:
- `verify-omp-hooks.sh`:
- `verify-peer-answer.sh`:
- `verify-attention-tick.sh`:
- `verify-scoped-approval.sh`:
