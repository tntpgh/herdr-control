# Weekly project envelope (`owner-dispatch-approval-weekly/1`)

One human approval lets a project's queue lane run for up to 7 days without a
fresh approval per day or per queue edit. DEFAULT OFF. `owner-dispatch-approval-standing/1`
is unchanged and still the right tool when you want a *pinned* job list.

## What the approval binds

A **policy**, not a queue sha:

| field | meaning |
|---|---|
| `templates[]` | allowed job shapes: `name`, `request_prefix` (>= 8 chars, exact, case-sensitive, a *prefix* of the request text), `manifest_allow` (names the item's manifest must be a subset of), `max_request_bytes` |
| `max_per_day` | items per rolling 24 h |
| `max_per_week` | items per envelope lifetime (the window is <= 7 d, so this is the weekly cap) |
| `per_item_cap_cents` | an item declaring more is refused |
| `total_cap_cents` | sum of declared costs over the envelope |
| `envelope_window_s` | 60 s .. 604800 s (7 d), counted from the human's answer |

plus the holder floor (pane, birth, session digest, lease generation) of the
live owner and the lane's label/project. Nothing claims a lease.

## Lifecycle

```
build-weekly-form  ->  formserve (human answers)  ->  consume-pending | issue-weekly  ->  queue items  ->  tick
```

1. `owner-dispatch-issue.py build-weekly-form --label L --project P --templates-dir D --templates-name t.json --lease-db DB --auth-id ENV_ID --max-per-day N --max-per-week N --per-item-cap-cents N --total-cap-cents N [--window-s 604800] --out page.html`
   `t.json` is a JSON list of templates. Writes the deterministic page only (O_EXCL); serves nothing.
   The page states that the queue is **not** pinned and shows every prefix as an exact JSON string.
2. Serve the page with formserve on the local hub (`http://127.0.0.1:8600/decisions`).
3. The answered form is turned into one `owner_dispatch_envelope` row plus the immutable issuance record by
   `issue-weekly --form-id ID` or, periodically, `consume-pending` (it now handles standing *and* weekly forms;
   same `HERDR_OWNER_DISPATCH_CONSUMER=1` + three issue flags + both kill switches).
4. Queue items name the envelope in their existing `auth_id` field and carry `cost_cents`. Append them whenever;
   no new approval.
5. `HERDR_QUEUE_SUPERVISOR_ENVELOPE=1` (mutually exclusive with `..._STANDING`; both on = `refused:standing_and_envelope_both_on`)
   makes the supervisor use `EnvelopeDispatch`. The flag is carried across `install.sh --hub` re-renders.

The auth store must be at schema v3 first (`oda.migrate`; a separate, separately-approved step). `issue-weekly` refuses an
unmigrated store (`refused:auth_store_not_migrated`) before any write. v3 only **adds** a table + triggers.

## What happens at dispatch

`oda.consume_envelope` runs in one `BEGIN IMMEDIATE` and mints the same pre-consumed single-use **child** row
`consume_standing` mints (`parent` = the envelope, bound to the item's rid, the sha256 of the exact request bytes sent,
the live holder and the cost). The Dispatcher, lease fence, DeliveryGate, journal, `intent.json`, `unsent()/unresolved()`
and receipts are untouched. Every cap is *derived from the child rows* (count/sum), never from a counter, so it cannot
drift from the audit trail.

| refusal | lane effect |
|---|---|
| `policy_template`, `policy_manifest`, `policy_size`, `policy_cost_missing`, `policy_item_cap` (off-policy item) | **refused and frozen** (`held_consumed`), escalated once, never sent. Needs operator `resume` after the item is removed/fixed |
| `envelope_missing`, `envelope_mismatch`, `envelope_holder_changed`, `envelope_policy_invalid` | refused and frozen (fail closed) |
| `envelope_expired`, `envelope_revoked`, `envelope_day_cap`, `envelope_week_cap`, `envelope_budget` | item stays **pending** (retry-safe hold, one escalation); nothing written. Day cap clears itself after 24 h |
| `approval_pending` | see race fix below |

## Kill switch

`owner-dispatch-issue.py revoke-envelope --auth-id ENV_ID --operator NAME --reason TEXT`

1. creates `~/.local/state/herdr/owner-dispatch/envelope-revoked/ENV_ID.revoked` (O_EXCL, 0600) *first* — dispatch reads it
   inside the consume transaction, so the stop is immediate and independent of the DB;
2. appends audit lines to `~/.local/state/herdr/owner-dispatch/revoke.jsonl` (who, why, when, marker, DB result);
3. flips the row `granted -> denied` and writes an append-only `owner_dispatch_operator` row (needs
   `HERDR_OWNER_DISPATCH_AUTH_DB`; exit 1 if only the marker landed — dispatch **is** stopped, re-run when the store is reachable).

Deleting the marker does not resume: the DB denial is sticky (the row trigger allows only `granted -> denied`).
The factory-wide `owner-dispatch.revoked` still stops the whole supervisor. An auth id that is not a safe name reads as revoked.
Resuming = a new envelope.

## Race fix (also covers standing/1)

If the hub ticked before the grant existed, `standing_missing` froze the first item as `held_consumed` forever. Now
`defer_if_approval_pending` (queue-supervisor.py, `lib/approval_pending.py`): a `*_missing` refusal while a form for the same
label + grant id is **open** (unexpired) or **answered-approve and still inside its own window** returns the retry-safe
`approval_pending`, the item stays pending, and runs as soon as the grant is issued. No matching form -> unchanged
(`held_consumed`). A declined, expired, or other-label/other-id form never defers. `pending()` can only delay, never authorise.
Worst case for a stale approved-but-never-issued form: the item waits out that form's window (<= 7 d for weekly, 24 h for standing).

## Status

`factory-status.py` (text and `--json`) shows, per lane with the envelope flag on: envelope id, status, `expires_at`,
`day used/max`, `week used/max`, `spent/total`, remaining day/week/cents, and blockers
(`envelope_revoked`, `envelope_expired`, `envelope_day_cap`, `envelope_week_cap`, `envelope_budget`,
`next_item_policy_*`).

## Threat model: what a compromised party can do

| actor | standing/1 | weekly envelope |
|---|---|---|
| **queue writer** (can edit `<label>.queue.json`) | any edit breaks the queue sha: nothing runs until a new approval. Can only run the approved items | **can run any text starting with an approved prefix**, to the approved manifest names, up to the caps, for up to 7 days. Cannot run anything outside a prefix, exceed item/day/week caps, or outlive expiry |
| **compromised worker** (owner pane) | can only act on requests it was sent; can write results | same. Cannot widen the policy (rows are immutable; policy sha256 re-checked each dispatch), cannot mint children (no writer in the worker path), cannot un-revoke |
| **forms-dir writer** (same UID) | can forge an answered form -> a grant (same-UID trust boundary, unchanged) | same, but a forged weekly form buys 7 d of policy-bounded authority instead of 24 h of a pinned list. `approval_pending` lets a forged form delay (not run) an item |
| **cost liar** (queue writer) | spend cap is on declared `cost_cents` | same: **spend caps are only as honest as the declared cost**. The item-count caps are hard regardless of cost |

The envelope trades *pinned content* for *bounded policy*. Choose prefixes narrow enough that "anything starting with this"
is acceptable. Prefer a per-day cap of what you would be comfortable reviewing the next morning.

## Verification

`python3 verify-weekly-envelope.py` (expiry, daily/weekly/spend caps, off-policy, kill switch + audit, append-while-live,
race fix, issuer pipeline, factory-status). `tmp/red-mutations.py` is not shipped; its result is in `.handoffs/PROOF.md`.

## Review follow-ups (PR #411 security review)

- The signed page now says, next to both spend-cap rows and in the body, that the caps bind only the `cost_cents` the queue
  writer declares; only the item-count caps are hard.
- `revoke-envelope` still flips the DB row to `denied` and writes the operator row and audit line when the marker cannot be
  written (unwritable state dir); it then exits 1 (`marker=error:<type>`). Dispatch is stopped by the DB denial.
- `auth_id` / approval id uniqueness is checked across `owner_dispatch_auth` and `owner_dispatch_envelope` by every issuer
  (single, standing, weekly, in-transaction), so a standing grant can never reuse an envelope's id and spend its caps.
