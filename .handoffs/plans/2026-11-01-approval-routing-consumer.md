# Approval routing bug — design delta (God-Mode factory authorization)

Source: `~/.handoffs-conductor/PLAN-GOD-MODE-FACTORY-20261101.md` and
`APPROVAL-ROUTING-BUG-20261101.md`. Task binding: this worktree/branch
(`fix/approval-routing-consumer`, `~/Code/.worktrees/approval-routing-fix`),
implemented directly by the herdr-control registered owner/conductor — no
duplicate worker spawned. Read-only trace first, then this design, then
implementation within this same document's scope only.

## 1. Read-only trace: formserve answer → conductor → grant issue

1. `formserve.py`/`hub.py:record_answer` claims a form `answered` exactly
   once (`claim_and_update`, exclusive lock + rename — loser gets 409). This
   part is correct and already exactly-once.
2. `hub.py:notify_owner(row)` (line 1629) is the ONLY thing that runs after
   a successful claim. It builds a plain-text message —
   `"Form answers from the hub (<title>):\n<json answers>"` — and pushes it
   into `row["deliver_to"]`'s composer via `herdr-deliver.sh`. **That is the
   entire pipeline.** There is no second step.
3. `owner-dispatch-issue.py issue-standing` is the only code that turns an
   answered standing-grant form into an actual grant row
   (`insert_standing_grant`, `owner_dispatch_auth`/`owner_dispatch_issuance`
   tables). It is a **one-shot CLI**, gated behind three env flags
   (`HERDR_OWNER_DISPATCH_ISSUE`, `HERDR_OWNER_LEASE_WRITER`,
   `HERDR_OWNER_LEASE_DELIVERY`, all must be `"1"`), documented as
   "OFF BY DEFAULT, INERT... pilot." Nothing in the codebase calls it except
   its own CLI entry point and the verify/test suites — confirmed by
   `grep -rl issue-standing` returning only `owner-dispatch-issue.py`,
   `verify-factory-on.py`, `verify-owner-dispatch.py`.
4. `build-standing-form` (which produces the form Terrence actually
   answers) also has no caller anywhere in the tree — it too is only
   invoked by hand, with no wrapper recording which queue-dir/queue-name it
   used for later consumption.
5. **Root cause, precisely:** the delivered message in step 2 is the raw
   `answers` JSON (just `{"decision": "approve", ...}` from the form's own
   fields) — not an actionable command, and nothing downstream ever reads
   it and calls `issue-standing`. A human (or the conductor agent) was
   expected to notice the delivered text, reconstruct the exact
   `issue-standing --form-id ... --queue-dir ... --queue-name ...`
   invocation themselves, and run it. On 2026-11-01 that reconstruction
   never happened for any of the three fresh forms — all three answers sat
   delivered-but-unconsumed, `queue_sha_mismatch` persisted because the row
   was never created, not because any safety check actually refused a real
   attempt.
6. This is **not a security bypass bug** — every check `issue-standing`
   performs (queue digest, canonical item equality, live-generation
   re-check, `approval_already_used`, auth-store v2 migration gate) is
   correct and already exercised by the verify suites. The gap is purely
   "answered → nobody ever calls the already-correct consumer."

## 2. Fix: a new, narrowly-scoped, default-OFF consumer tick

**Not** adding grant-issuance capability to `hub.py` itself. `hub.py` is an
always-on web request handler; giving it (even transiently, even via a
scoped subprocess call from inside a request) the standing env-flag
privilege widens its live attack surface for every future hub change, and
couples a request-handling code path to a privileged write. Every existing
auth-adjacent feature in this repo (standing queue-supervisor dispatch,
owner-lease-recover, the weekly-turn-key design currently in review) uses
the SAME shape instead: a separate, narrowly-scoped script, ticked
periodically under launchd, gated by its own default-OFF master switch,
identical to `attention_controller`/`stall_watchdog`'s existing
supervision pattern. This fix follows that same shape, not a new one.

### New subcommand: `owner-dispatch-issue.py consume-pending`

```
owner-dispatch-issue.py consume-pending --queue-root DIR [--forms-dir DIR]
```

- Refuses (exit 4) unless the same three flags `issue-standing` itself
  requires are set — this subcommand calls `issue_standing_main` **in
  process** (same Python module, same function), so it inherits exactly
  the privilege `issue-standing` already has, nothing new.
- Kill switch: reuses `queue-supervisor.py`'s own
  `kill_switch_engaged()` (`~/.local/state/herdr/owner-dispatch.revoked`,
  imported, not reimplemented) — unreadable or present stops the whole
  pass before any store is opened, exactly the existing rule. Also checks
  `merge-delegation.revoked` the same way (same fail-closed-on-unreadable
  semantics) before any management-adjacent action, per the plan's
  explicit requirement.
- Scans the pinned forms dir (`~/.local/state/herdr/forms/*.json`, the
  SAME trust root `read_decision`/`issue_standing_main` already use) for
  records whose embedded `rec.protocol == STANDING_PROTOCOL`, `status ==
  "answered"`, `answers.decision == "approve"` and `cancelled` is not
  true.
- For each candidate: `--queue-dir` = `--queue-root`, `--queue-name` =
  `f"{rec['owner_label']}.queue.json"` — the EXACT convention
  `lib/queue_supervisor.py` already uses (`<root>/<label>.queue.json`),
  reused rather than invented, so the same root config value already used
  for `HERDR_QUEUE_SUPERVISOR_ROOT` works here unchanged.
- Calls `issue_standing_main(["--form-id", id, "--queue-dir", root,
  "--queue-name", f"{label}.queue.json"], resolve=resolve, now=now)`
  in-process. Idempotency needs no new state: a form already consumed
  returns `refused:approval_already_used` from `issue_standing_main`
  itself (existing check, line 916-918) — running the tick twice, or
  across a restart, is a safe no-op for anything already issued.
- Every attempt (issued / refused:<reason> / issue_uncertain) is appended
  to `~/.local/state/herdr/owner-dispatch/consume.jsonl` (one line per
  attempt, form_id + outcome + timestamp) — an audit trail distinct from
  the DB rows, so "did the tick ever see this form" is answerable even for
  a refused attempt that left no DB row.
- Exit code: 0 only if every candidate this pass ended `issued` or
  `refused:approval_already_used` (already-done, not a failure); nonzero
  if anything ended in a genuine refusal or `issue_uncertain` — so a
  periodic caller can alert without masking a real problem as "ran fine."

### Periodic tick: `owner-dispatch-consume-tick.sh`

Same shape as `stall-watchdog.sh`/`attention.sh` — a thin shell wrapper
setting the required env (queue root, lease/auth DB paths, the three
`HERDR_OWNER_*` flags) and calling `consume-pending` once, meant to be
installed as a LaunchAgent on the SAME cadence as the existing tickers.
**Gated by a NEW master switch, `HERDR_OWNER_DISPATCH_CONSUMER=1`, default
OFF** — matching every prior standing/auth feature in this repo (#353,
#354, #356, #357 all shipped default OFF; activation is always a later,
separate, Terrence-approved step). This PR does **not** flip it on, does
**not** add it to `install.sh`'s LaunchAgent list, and does **not** run it
against the three real pending 2026-11-01 forms — per the plan's own
"Preserve current approvals... do not replay the already-issued approvals
until the consumer fix is reviewed." Once reviewed, activation is a
one-line env flip plus an `install.sh --apply` the same way every other
switch here goes live, outside this PR's own scope.

## 3. Explicit owner override for recovery — zero schema/record-shape change

A "recovery" is never a bypass of `issue-standing`'s own checks — it is a
**fresh, explicitly-approved standing form built against the CURRENT
queue/generation** (an ordinary `build-standing-form` run, completely
unmodified), consumed through the exact same `issue_standing_main` path as
a first-time grant, with the SAME `validate_standing_approval`/
`render_standing_form` and the SAME `STANDING_KEYS` Terrence has always
approved. `STANDING_KEYS` is guarded by `verify-owner-dispatch.py`'s own
"FROZEN COMPAT (ffa64cc)" test (byte-identical schema/validator behavior
against a frozen snapshot module) — this design deliberately never touches
it, the approved record, or its render, so that guard stays green
unmodified.

### `issue-standing --recovery-of AUTH_ID --reason TEXT --actor NAME` (new, optional)

All three or none — a partial set is `refused:recovery_flags_partial`
before anything is checked. Pure CLI/audit annotation, never part of the
signed `rec`:

- `--recovery-of` must name an EXISTING row in `owner_dispatch_auth`
  (checked against the already-open store before any identity/claim
  logic runs) — refuses `recovery_target_unknown` otherwise, so this can
  never mint a first grant under cover of "recovery."
- Otherwise the issuance is 100% the existing `issue_standing_main` path,
  unmodified — same re-validation, same `approval_already_used` dedup
  (on the NEW auth_id the fresh form names), same kill-switch checks, same
  caps resolved fresh from the current queue.
- On successful issuance only (both the clean-commit path and the
  "verified present after an error" path — never on a refusal, since
  there is nothing to record recovering FROM a write that never
  happened), one line is appended to
  `~/.local/state/herdr/owner-dispatch/recovery.jsonl`: `actor`, `reason`,
  `approval_id` (the new form's id), `old_auth_id`/`new_auth_id`,
  `old_lease_generation`/`new_lease_generation`, `old_queue_sha256`/
  `new_queue_sha256`, `timestamp`.
- `consume-pending` never passes these three flags — recovery stays a
  separate, explicit, human-invoked action, never auto-attempted by the
  tick.
- Cannot widen scope: the fresh form Terrence approves is bound by the
  unmodified `build_standing_main`/`validate_standing_approval` path —
  item cap, spend cap and queue items are all re-derived from the CURRENT
  queue at build time, never copied forward from the stale grant.

## 4. Preserve current approvals, no replay

- The three 2026-11-01 forms stay exactly as answered — this PR's tick is
  default-OFF and is never pointed at them as part of this work.
- Nothing in this design reads or writes `owner_dispatch_auth`/
  `owner_dispatch_issuance` rows outside the existing, unmodified
  `insert_standing_grant`/`issue_standing_main` path.
- No manual DB insert, anywhere in this change.

## Acceptance → design mapping

| Acceptance criterion | Covered by |
|---|---|
| Approved form → exactly one grant, lane runnable | `consume-pending` calling `issue_standing_main` once per candidate; existing `insert_standing_grant` transaction |
| Duplicate answer → no second grant | `issue_standing_main`'s existing `approval_already_used` check (unchanged) |
| Queue hash mismatch → refused, no state change | `issue_standing_main`'s existing `queue_sha_mismatch` refusal (unchanged); `consume-pending` logs it, writes nothing |
| Lease generation mismatch → refused, no state change | `issue_standing_main`'s existing `lease_holder_mismatch` refusal (unchanged) |
| Expired approval → refused | `window()` check inside `issue_standing_main` (unchanged) |
| Owner override recovery → durable audit record and exactly one recovery action | `issue-standing --recovery-of/--reason/--actor`, `recovery.jsonl`, unmodified `issue_standing_main` for the actual issuance |
| Kill switch present/unreadable → refused | `consume-pending`/`issue-standing --recovery-of` both reuse `lib/kill_switch.engaged()` (extracted from `queue-supervisor.py`'s own `kill_switch_engaged()`) against `owner-dispatch.revoked` and `merge-delegation.revoked`, fail-closed on unreadable |
| Scope/lane/spend widening → refused | Recovery form re-derives caps from the CURRENT queue via unmodified `build_standing_main` validation; nothing copied from the stale grant |
| Existing denied noMedia import remains denied, never replayed | Out of this subsystem entirely (unrelated queue/lane); this design touches no denied-row state, confirmed by scope (standing-grant forms only) |

## Explicit non-goals, this PR

- No activation (`HERDR_OWNER_DISPATCH_CONSUMER` stays unset; not added to
  `install.sh`).
- No replay of the three real 2026-11-01 answered forms.
- No `owner_dispatch_auth` schema change / migration.
- No change to `hub.py`'s request-handling path.
- No merge, no deploy — stops at a reviewable PR per the plan's own gate
  (independent review by `w9T:p5G` after PR #396 closure).
