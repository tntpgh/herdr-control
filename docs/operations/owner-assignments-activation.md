# Durable owner assignments — activation (Plan 018 PR B)

PR A (#408) shipped schema v6 and the audited `owner-assignment.py` operations, inert. PR B routes every
live owner consumer by authority mode and adds the one deployment entrypoint,
`owner-assignment-activate.py`.

## Semantics

- A durable assignment is authoritative until an audited `assign_revoke` or an atomic `assign_replace`.
  Wall clock, reap, renew, release, unregister, crash or restart never end it. `acquire`, `claim_*`,
  `assign_initial` and `resume` cannot take over or resurrect one.
- Consumers that read the live holder now pass `modes=ol.AUTHORITY_MODES` deliberately:
  dispatch (`lib/owner_dispatch.py`), delivery gate (`lib/owner_lease_delivery.py`), publisher and
  `ra-sender.py` bound-holder checks, `submit-owner-result.py`, `accept-owner-result.py`,
  bind-live and standing grant issuance (`owner-dispatch-issue.py`), `factory-status.py`.
  `holder_tuple()` still defaults to timed-only; claim paths that just wrote a timed lease keep it.
- Delivery: the lease-remaining margin (`lease_too_short`) applies only to `authority_mode='timed'`; an
  assignment has NULL `expires_at` and is never dereferenced. Fence order, generation fencing and
  one-time-grant consumption order are unchanged (a revoked label holds before any grant is consumed).
- Bind-live grant issuance: the "grant must not outlive the lease" cap applies to timed leases only; an
  assignment's grant keeps its own bounded window (<= 24h).
- `factory-status` reports `authority_mode`, and an ended assignment as `state: ended` with an
  `assignment_ended:genN:<reason>` blocker (never `lease_expired`).
- `owner-lease-resume.py` refuses an assignment predecessor (`refused:predecessor_is_assignment`).
- Kill switches are unchanged: `owner_state.enabled=0` fails every assignment write and every delivery
  admit closed.

## Activation (`owner-assignment-activate.py`)

`assign_convert()` converts a currently authoritative timed lease to an assignment **in place** — same
lease row, same generation, same holder — so open requests and generation-bound standing grants keep
their binding. It needs an exact `(generation, pane, birth, session)` match and an unexpired lease; it
never converts an expired lease and never changes the holder.

```bash
# 1. dry-run (default, read-only): prints schema plan + one plan:convert line per label
python3 owner-assignment-activate.py --db "$HERDR_OWNER_LEASE_DB" \
    --decision-ref <id> --reason "<why>"

# 2. apply (stop owner consumers first; both flags are required while the schema is behind)
HERDR_OWNER_ASSIGNMENT_WRITER=1 HERDR_OWNER_LEASE_WRITER=1 \
python3 owner-assignment-activate.py --db "$HERDR_OWNER_LEASE_DB" \
    --decision-ref <id> --reason "<why>" --apply
```

- A label converts only when the owner registry's current `(pane, birth, session digest)` equals the
  lease holder exactly. Any mismatch or unresolved label refuses the **whole run** (exit 2) before any
  backup or write. Nothing is ever inferred. `--label L` (repeatable) restricts the set.
- `--apply` order: verify → sqlite-API backup (`<db>.pre-assignment-activate-v<N>-<ts>.sqlite3`, 0600,
  sha256 printed, rollback line printed) → schema migration → per label: fresh registry re-check +
  `assign_convert` (own audited transaction, `converted` event).
- Idempotent: once every label is an assignment the run prints `nothing_to_do`, takes no backup and
  writes nothing. Existing assignments are never rewritten, even with different evidence.
- Exit codes: 0 ok; 2 refused (drift, kill switch, convert refusal); 4 config (flags, DB open, schema
  < v3); 3 error after the backup (rollback line printed).

## Verification

```bash
python3 verify-owner-assignment-activation.py      # activation CLI + lifecycle + every consumer
python3 verify-owner-assignment.py verify-owner-dispatch.py verify-owner-lease-delivery.py   # run each
python3 remote-mcp/verify-ra-sender.py remote-mcp/verify-publisher.py                        # run each
```

After applying live: `python3 owner-assignment.py --db "$HERDR_OWNER_LEASE_DB" show --label <L>` must print
`mode=assignment gen=<same as before> expires_at=None`; `factory-status.py` must show
`authority_mode: assignment` and no `lease_expired` blocker for the label.

## Rollback

```bash
HERDR_OWNER_ASSIGNMENT_WRITER=1 python3 owner-assignment-activate.py --db "$HERDR_OWNER_LEASE_DB" \
    --rollback <backup> [--expect-sha256 <sha>]           # dry-run: names backup schema + sha256
HERDR_OWNER_ASSIGNMENT_WRITER=1 python3 owner-assignment-activate.py --db "$HERDR_OWNER_LEASE_DB" \
    --rollback <backup> --apply
```

`--apply` first snapshots the current store to `<db>.pre-rollback-<ts>.sqlite3`, then restores the backup
through sqlite's backup API and checks integrity. A rollback discards every row written after the backup
(requests, events), so stop owner consumers first. To end a single assignment without a full rollback,
use `owner-assignment.py revoke` (audited, fences every path at once).

## Changelog

- 2026-11-04 — PR B: consumers routed by authority mode; `ol.assign_convert()`, `ol.live_mode()`;
  `owner-assignment-activate.py`; `verify-owner-assignment-activation.py`; `factory-status` assignment
  states; `owner-lease-resume.py` assignment refusal; CI runs the new suites.
