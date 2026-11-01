# Weekly turn key — design only

**Status:** design candidate; no code, database, TTL/security configuration, or
activation. Published from `.handoffs/plans/weekly-turn-key.md`
(worktree `feat/weekly-turn-key`, task `design:feat/weekly-turn-key`,
closed `completed` 2026-11-01) into a tracked location so it is reviewable.
Content below is that design, reconciled against `origin/main` as of
`3b38b1c` and against the approval that authorized writing it down for
implementation (§0).

**Decision in this design:** a key is a fixed **168-hour** authorization window from the
successful `issue` time printed and approved in advance. It is not a calendar-week rule.
That is the literal seven-day ceiling, independent of timezone, daylight saving, or the
time Terrence turns it. It has no automatic renewal and cannot mint itself.

## 0. Authorization for this document, and the one open prerequisite

Form `20261101T214337-8797` ("Seven-day factory lease cycle"), answered
`decision=approve_with_conductor`, `requirements=answer_renewal`:
authorizes writing/implementing the design (NOT activation), scopes it to
**five labels** — `thurber-os`, `tntpgh-dev`, `tourguide`, `knowledge-base`,
and the **registered conductor lease** — and requires renewal to happen
only on a fresh owner answer. That is exactly this document's §2.1 scope
list and §3's human-run flow; no scope change was needed to match it.

**Blocking prerequisite found while preparing this document, not yet
resolved:** `feat/lease-lifecycle-recover` (local branch, tip `aac086b`,
never pushed past `6eecaef`) carries three **uncommitted, unreviewed**
commits beyond its own original `SPEC.md` scope (which was narrowly
"owner-lease lifecycle recovery, code + tests only" — that piece shipped
cleanly via PR #386 / `c9f2fdf`, already on `main`). The three commits past
that point (`6eecaef..aac086b`: "weekly M2 fix candidate for independent
review", "weekly M2 dependencies for C", "weekly M2: remaining
dependencies") implement a **conductor-week authorization mechanism** —
`lib/task-authorization.py` (`accept_conductor_week`, `read_conductor_week`,
`accept_conductor_redemption`, handover-cap tracking), `lib/run-registry.sh`
(`closed_unverified` state, conductor-week bash wrappers), a `to_is_main`
cap/scope check in `conductor-handover.sh`, and two new files
(`lib/conductor_week_form.py`, `grant-conductor-week.sh`) — that this
design's §1 explicitly calls "revision 3" and builds on as an *existing*,
reusable foundation. It is not on `main`, was never opened as a PR, and its
own `.handoffs/PROOF.md` documents an unresolved review exchange (a cited
static-review finding the reviewing session could not locate the source
document for) plus a same-session incident (an `_write` call overwrote the
append-only proof ledger; partially recovered from the omp session
transcript, not fully). The worktree's pane (`w9T:p40`) is idle/done, one
tracked file modified (`verify-weekly-conductor-authorization-m2.sh`,
+123/−24), held open by `close-done-workers.sh`'s own dirty-worktree check
— correctly not touched or closed by this session.

**This means revision 3's conductor-week mechanism — the thing §1–§3 below
describe as already built — currently exists only as uncommitted code in
that one worktree, unreviewed.** Implementing this design today would
either (a) silently depend on code nobody else can see or run, or (b)
require re-deriving the same mechanism a second time, which is exactly the
"second approval protocol" §1 says this document must not create.
**Before any implementation PR for this design, that worktree's three
commits need an explicit disposition — reviewed and merged as their own
PR, or deliberately superseded with a stated reason — decided by Terrence,
not inferred by whichever session happens to implement this next.** This
document stays correct either way (it describes the mechanism's shape, not
which commit SHA provides it) but implementation cannot safely start until
that's resolved.

One piece of this design's own reuse list already changed since it was
written: §2.2's `NULL`-bound initialization case now has a direct,
*already-merged-pending-review* implementation to reuse instead of a new
helper — `bind_missing_lifecycle()` (PR #398,
`lib/owner_lease_recover.py`, CAS on `(unregistered_at IS NULL,
lifecycle_end_at IS NULL)`, mints no token, `lifecycle_bound` audit event).
§2.2 is updated below to cite it directly in place of describing a new
helper shaped like `recover_lifecycle()`.

## 1. What exists today and why this is an extension

The existing revision-3 design in `docs/design/weekly-conductor-authorization.md`
(commit `42290c4`, on branch `feat/lease-lifecycle-recover` — not yet on `main`; see §0)
already supplies the right human-consent shape for the conductor:
`build` prints the exact candidate, `formserve` records the answer, and `issue` inserts
only the digest-matching record. It also correctly keeps a short liveness lease separate
from a longer human authorization, requires a live registry-proven Main at redemption,
uses a single-use child redemption token, clamps lease/token expiry to grant expiry, and
makes expiry a PAUSE rather than a fallback to daily forms. Its revision-3 test list and
`closed_unverified` rule remain requirements, not optional background.

This document extends that design in two gaps revision 3 did not close:

1. the key covers the **closed, named owner-label set** (`conductor`, `thurber-os`,
   `tntpgh-dev`, `tourguide`, `knowledge-base`) and repairs/advances each label's
   lifecycle bound without changing the short liveness lease;
2. the key can authorize the existing factory standing-grant adapter to renew/reissue
   the exact named standing lanes for the same seven-day window, while each individual
   standing grant remains subject to its existing 24-hour cap and generation fence.

It does not create a second approval protocol or a second lease/grant database.

The current incident mechanisms are concrete, not hypothetical:

- v5 added nullable `owner_projects.lifecycle_end_at` (`lib/owner_lease.py:258-276`),
  and `owner-register.py` defaults `--lifecycle-end` to `None`
  (`owner-register.py:99-105`); therefore `renew_due()` returns
  `no_lifecycle_bound` (`lib/owner_lease_renew.py:99-105`) and every affected lane can
  stop renewing. (Live 2026-11-01: `knowledge-base` hit exactly this; fixed for that one
  label via `bind_missing_lifecycle()`, PR #398 — see §2.2.)
- when the conductor's bound ends, its ordinary lease eventually expires; the registered
  label then fails closed in `DeliveryGate.admit()` as `owner_no_lease`
  (`lib/owner_lease_delivery.py:110-133`). The conductor label is literally
  `conductor` (`remote-mcp/publisher.py:1295`).
- a same-identity expired-lease resume preserves `(pane_id, pane_birth, session_digest)`
  but creates a new `lease_id` and generation (`owner-lease-resume.py:144-169`,
  `lib/owner_lease.py:519-548,704-727`). Existing standing rows store the old
  `lease_generation`; `consume_standing()` fences on it and only admits a narrowly
  checked `floor+1` restart (`lib/owner_dispatch_auth.py:262-321`). The generation
  change also stales old open `owner_requests` (`lib/owner_lease.py:542-548`), which
  is how in-flight work can become orphaned.

## 2. Data model: one parent key, existing child records

### 2.1 Weekly key record

The key is one parent authorization record in the existing `task_authorizations`
authorization store, using the existing source/claims/integrity fields with
`source='weekly_turn_key'`. It is **not** a task receipt: `task_id` and
`remote_task_id` remain empty, no worker is bound, and no task lifecycle transition is
allowed. The source-specific adapter must recognize this source and keep its status at
the existing parent `accepted` state; it must never fabricate `bound`, `launch_claimed`,
or `launched`. This reuses the existing immutable `claims` + `source_sha256` +
`expires_at` record instead of adding a weekly-key table or a parallel authorization
store. The current table and status contract are `lib/task-authorization.py:103-135`.

The canonical claims object, all included in the digest and form, is:

```json
{
  "version": 1,
  "source": "weekly_turn_key",
  "key_id": "...",
  "minted_by": {"external": true, "actor": "..."},
  "issued_at": 0,
  "expires_at": 0,
  "scope": {
    "owner_labels": ["conductor", "thurber-os", "tntpgh-dev", "tourguide", "knowledge-base"],
    "projects": {"conductor": "tntpgh/herdr-control"},
    "standing_lanes": [{"label": "...", "project": "...", "queue_sha256": "..."}]
  },
  "lease_floor": {"label": {"generation": 0, "holder": {"pane_id": "...", "pane_birth": "...", "session_digest": "..."}}},
  "caps": {
    "window_s": 604800,
    "per_lifecycle_write_s": 86400,
    "per_standing_window_s": 86400,
    "handover_count": 10
  },
  "preview_sha256": "..."
}
```

The exact current holder and generation are captured for every lane at preview and
revalidated at issue. The key's **live identity policy** is not a frozen pane: at each
use, the caller must resolve the registry's current `roles.main` identity through the
existing ancestry-based path. A pane/hub restart may therefore select a new legitimate
Main, but a caller-supplied `HERDR_PANE_ID` or stale pane snapshot never suffices.

`issued_at` and `expires_at` are 168 hours apart. `expires_at` is immutable. A second
key is a new parent row and a new human approval; an existing key is never extended or
edited in place.

### 2.2 Existing lease rows remain the liveness fence

`owner_projects.lifecycle_end_at` remains an absolute bound and
`owner_leases.expires_at` remains the short liveness lease. The key does not replace,
merge, or lengthen `owner_leases`; a dead pane still loses its live lease quickly.
Every tick still runs the ordinary identity and CAS checks in
`owner_lease_renew.renew_due()`.

The weekly lifecycle adapter is allowed only for the named labels in the key, and
**reuses the two existing narrowly-scoped recovery functions directly rather than a new
one** — both already share the CAS/audit-event shape this needs:

- if `lifecycle_end_at` is `NULL`: call `owner_lease_recover.bind_missing_lifecycle()`
  (PR #398) with `new_lifecycle_end_at = min(now + MAX_TTL_S, key.expires_at)`. Mints no
  token (unchanged from today); writes a `lifecycle_bound` event carrying the key's
  confirmation ref.
- if it is expired, or live but too close to the key end: call
  `owner_lease_recover.recover_lifecycle()` (merged, PR #386) with the same clamp.
  Mints a fresh `unregister_token` (unchanged existing behavior of that function); writes
  a `lifecycle_recovered` event carrying the key's confirmation ref.

Each individual `owner_projects` write is therefore at most the existing
`owner_lease.MAX_TTL_S = 86400` seconds ahead of `now`; repeated ticks can keep the
bound ahead until the key expires. The weekly adapter is a thin per-label dispatcher
over these two existing functions, passing the weekly key's own confirmation id as
`confirmation_ref` — it must never alter `project`, `max_open`, `unregistered_at`, or
the owner mapping (neither reused function does). A `NULL` bound is an explicit
weekly-key activation case; it is not silently treated as unbounded by ordinary renewal.

This directly closes both lease incidents: all five labels are included in the signed
scope and NULL bounds are initialized during activation; an expired conductor bound is
recovered before its short lease is allowed to run out. If any label cannot pass the
project, registration, identity, or CAS checks, activation pauses for the entire key
operation and reports the exact label; it does not proceed with a partial lane set.

### 2.3 Existing factory standing grants remain the child grants

A standing grant remains the existing `owner_dispatch_auth` parent row
(`kind='standing'`, `status='granted'`) with one pre-consumed child row per dispatched
item. Its existing fields remain authoritative: owner label/project, pane/birth/session,
`lease_generation`, queue digest, item cap, spend cap, and `expires_at`
(`lib/owner_dispatch_auth.py:94-112,160-170`; `owner-dispatch-issue.py:510-524`).
`consume_standing()` remains the only way to mint a child receipt and still performs the
queue digest, item/spend cap, duplicate request, and current-holder checks
(`lib/owner_dispatch_auth.py:254-353`).

The weekly key may renew/reissue only a standing parent already named in its signed
`standing_lanes` list, for the same project, exact queue digest, item cap, and spend
cap. Every resulting standing window is `min(86400, key.expires_at-now)`; the key does
**not** raise `MAX_STANDING_WINDOW_S` and cannot make a single standing row last seven
days. The one human answer authorizes up to seven days of these bounded daily windows;
it does not turn a daily 24-hour grant into a seven-day bearer grant.

A standing parent cannot be widened. New labels, projects, queue items, queue digests,
item caps, spend caps, or a new standing lane require a new build/answer/issue cycle.
The weekly parent key is only a coordinator authorization; it is not a replacement
standing row and is never accepted as `auth_id` by `consume_standing()`.

## 3. The form Terrence answers

The command is explicitly human-run, outside herdr, and never auto-turns itself:

```text
grant-weekly-turn-key build --reason "<text>"
# Terrence answers the formserve decision
# Then, only after the answer:
grant-weekly-turn-key issue --confirm-form <form-id>
```

This is revision 3's preview-digest-confirm flow, extended rather than duplicated.
`build` performs no authoritative DB write. It reads and displays:

- the exact fixed 168-hour `issued_at`/`expires_at` window and a UTC timestamp;
- every five-label owner scope, canonical project, current lifecycle bound (including
  `NULL`), current live lease holder and generation, and the exact initialization/
  renewal clamp;
- every standing lane, queue digest, item cap, spend cap, current generation, and the
  fact that each child window remains `<=86400` seconds;
- the allowed operations and the hard caps above;
- the Main identity policy, the same-identity resume rule, the two kill-switch paths,
  and the PAUSE behavior on expiry/revocation;
- the required reason and a canonical digest of all fields.

The form is the existing `formserve` answer surface. The answer must be `approve` and
must echo the digest of exactly the embedded record. `issue` re-reads the answered
form, requires fresh status and a bounded confirmation age, recomputes the digest from
the embedded values, and inserts the one parent `weekly_turn_key` row using the
previewed timestamps and scope. It never recomputes a later `now`, accepts a caller
scope, or writes a lease/grant row during `build`. The insert is compare-and-swap
single-use on the preview digest, as required by revision 3 and the existing
`owner-dispatch-issue.py` pattern (`owner-dispatch-issue.py:394-464,530-569`).

Before issue succeeds, it must re-read all five owner rows and all named standing rows.
A changed queue digest, project, holder, generation, missing row, revoked switch, or
partial lane set refuses the issue; no partial key is created. A currently active key
makes `build` a no-op preview, not an extension. Expiry is a hard PAUSE; there is no
silent daily-form fallback and no automated re-mint.

## 4. Scope ceiling — what the key may and may not raise

### It may

- initialize or advance `lifecycle_end_at` only for the five already-registered labels
  in the signed scope, with each write capped at `now + 86400` and never past the key;
- renew/reissue the already-named standing grant lanes with each individual
  `standing_window_s <=86400`, exact queue/project/caps, and no additions;
- perform the existing conductor management operation for already-registered workers
  only in the closed scope, with revision 3's fixed handover cap of 10 per key period;
- survive a legitimate same-identity Main resume using the receipt-handoff protocol in
  §6 below;
- record all uses against the existing lease, owner-event, standing-grant issuance,
  child-receipt, and task-authorization audit trails.

### It may not

- raise `owner_lease.MAX_TTL_S`, `MAX_STANDING_WINDOW_S`, or the per-write 24-hour
  ceiling; the key is not a seven-day lease or seven-day standing bearer token;
- create an owner mapping, register a new label, change a project, change `max_open`,
  clear `unregistered_at`, rotate an unregister token, or revive an unregistered label;
- add a lane, queue item, repository, manifest, item cap, spend cap, capability, or
  handover target after issue;
- spawn a new worker/task, mint a remote `task_authorizations` receipt, or approve a
  new capability scope;
- use a bare weekly key id as a dispatch credential. Each automated lifecycle use and
  standing reissue obtains a single-use redemption child bound to the exact operation,
  key id, current Main identity, lane, generation, and clamp; the consumer rejects the
  parent id as a bearer token;
- bypass the current live-Main, registry, session-digest, generation, queue-digest,
  self-extension, CAS, delivery, or receipt checks;
- re-mint or extend itself. Only Terrence's new outside-herdr build/answer/issue flow
  can create the next key.

The answer to "past today's 24-hour cap?" is therefore precise: **no individual
lifecycle or standing-grant write/window may pass the existing 24-hour cap; yes, one
human approval may authorize repeated bounded operations for at most 168 hours.**
That is a frequency reduction, not a capability increase.

## 5. Revocation and ordering

The existing kill switches win over an active key, unconditionally:

1. At the start of every weekly operation, before reading the key or opening either
   store, check `owner-dispatch.revoked` using the same pinned, fresh `lstat` behavior
   as `queue-supervisor.py:67-82`. An absent-only result means clear; any other error
   means engaged. This preserves the existing `queue-supervisor.py:181-199` ordering.
2. For any operation that manages/conducts workers, check
   `merge-delegation.revoked` at the same preflight point. The current repository uses
   that path as a design precedent but has no executable reader; implementation MUST
   add the check to the shared handover/weekly gate rather than assume the reference is
   enforcement. Unreadable is engaged.
3. Recheck both sentinels immediately before each authoritative commit/child mint and
   immediately before each dispatch/handover. A positive or unreadable check aborts
   without opening/committing the affected operation. The check is fresh per operation,
   never cached in a process and never represented by a key claim.
4. Keep the existing in-transaction row revocation: a denied `owner_dispatch_auth`
   parent returns `standing_denied`/`auth_denied` (`lib/owner_dispatch_auth.py:410-437`),
   and the weekly parent lookup must reject a revoked status. The filesystem switches
   are an earlier global stop, not a replacement for row status.

A filesystem sentinel cannot be atomically locked together with SQLite. The design
therefore makes the boundary explicit: a sentinel created after the final pre-commit
check may stop the next operation but cannot retroactively undo a commit. No subsequent
weekly action is permitted after that observation, and every consumer checks again.
This is the same stop-on-next-tick semantics already documented for
`owner-dispatch.revoked`; it is not described as an impossible atomic guarantee.

## 6. Same-identity resume and in-flight receipts

The key never accepts "same pane" as sufficient. A resume is continuity only when all
of these are true, checked in one owner-store transaction before the new generation is
committed:

- the current registry resolver returns the same `(pane_id, pane_birth,
  session_digest)` as the expired predecessor;
- the predecessor generation is exactly the key's recorded floor and the new generation
  is exactly `floor + 1`;
- the predecessor is released for `expired`, not replaced, revoked, or manually handed
  off; the new holder is the live registry-proven Main; and
- every affected label is in the key's closed scope and the weekly key is unexpired and
  unrevoked.

This is a continuity proof, not a relaxed identity match. A different pane, different
birth, different session digest, skipped generation, uncertain liveness, or an expired/
revoked key pauses.

The current generic `acquire()` behavior stales open old-generation requests. That is
not sufficient for a weekly-key resume because it can orphan in-flight receipts. The
weekly resume adapter therefore has a separate **receipt handoff transaction**, not a
second receipt system:

- first freeze admission for the old generation;
- enumerate every old-generation `owner_requests` row in `queued`, `held`, `blocked`,
  or `delivering` state and every related `owner_dispatch_auth` child by its existing
  `request_id`/`parent` link;
- rebind only safely recoverable queued/held/blocked requests to the exact successor
  generation, preserving the same request id, body, queue digest, parent grant, and
  audit history; append a `weekly_resume_rebound` event with old/new generation and
  key/redemption id;
- a `delivering` request is not replayed or silently relabeled. It remains held for
  explicit settlement/reconciliation; if its outcome cannot be proven, the transaction
  aborts before creating the successor lease;
- consumed child rows remain immutable historical receipts. They are never reused as
  new authority. A new child is minted only by `consume_standing()` after the successor
  holder/generation and queue digest checks pass;
- only after all rows are accounted for does the transaction create the successor lease,
  update the weekly key's per-label floor, and commit. Any enumeration or CAS failure
  aborts and leaves the predecessor state inspectable.

Thus a same-identity resume preserves the authorization without widening it, while an
impostor cannot inherit it from a pane id or environment variable. It also prevents the
incident's orphaning behavior: no in-flight request is silently discarded as `stale`,
and no consumed receipt becomes a reusable bearer token. If safe handoff is impossible,
PAUSE is the required result.

## 7. Required negative cases before implementation

These are design gates, not code claims:

1. all five labels have `lifecycle_end_at IS NULL`: build displays them; issue/activation
   initializes exactly those rows with the 24-hour/key-expiry clamp, and ordinary
   `renew_due()` still reports `no_lifecycle_bound` in a fixture where no key is active;
2. conductor bound expired: without a key, renewal stops and inbox admission is
   `owner_no_lease`; with a valid key, the conductor bound is recovered before the
   short lease expires, with no project/mapping change;
3. resume under a valid key with same full identity and no unsafe receipt: successor
   generation is admitted and the standing lane continues;
4. resume with different pane/birth/session, skipped generation, no live Main,
   revoked/expired key, or sentinel present: refused;
5. resume with a queued/held/blocked in-flight request: request survives with the same
   id and is rebound once; no duplicate child or dispatch is created;
6. resume with delivering/ambiguous receipt: successor is not created and the old row
   remains inspectable; no fabricated completion or replay;
7. standing grant with old generation and a different queue digest/cap/project: refused;
8. parent weekly key id passed directly to `consume_standing()` or lifecycle recovery:
   refused; only a single-use, operation-bound redemption child is accepted;
9. any new label/project/queue item/capability after issue: refused and no row changed;
10. `owner-dispatch.revoked` or `merge-delegation.revoked` present or unreadable:
    stop occurs before key/grant lookup, before store open where applicable, and again
    before commit/dispatch;
11. active key reaches 168 hours: all automated paths PAUSE; no daily form fallback,
    extension, or self-mint;
12. revision 3's existing spoofed-pane, expired, scope-widening, bare-parent,
    single-use-redemption, digest/CAS, and `closed_unverified` negative tests remain
    required unchanged;
13. **(new, §0)** the weekly lifecycle adapter calls `bind_missing_lifecycle()` for a
    `NULL` bound and `recover_lifecycle()` for an expired bound — never a third,
    parallel helper — verified by asserting both existing functions' own test suites
    (`verify-owner-lease-bind-lifecycle.py`, `verify-owner-lease-recover.py`) still pass
    unmodified after the adapter is added.

## 8. Security boundary and stop condition

This is design only. Before any code, an independent security review is REQUIRED, with
zero unresolved high/critical findings. The review must cover the source-specific
`task_authorizations` adapter, the two sentinel ordering/race boundaries, the NULL-bound
initialization path, the per-operation 24-hour clamps, the same-identity receipt handoff,
and all five-label all-or-nothing behavior. No implementation PR, TTL/security config
write, database write, or activation is authorized by this document.

**Additionally required before implementation (§0): disposition of
`feat/lease-lifecycle-recover`'s three uncommitted "weekly M2" commits**
(`6eecaef..aac086b`) — either reviewed and merged as the revision-3
foundation this design builds on, or deliberately superseded with a stated
reason, decided by Terrence. Implementation must not proceed against an
assumed-but-unmerged dependency.

**Activation remains gated behind a fresh, separate owner answer** (per the
authorizing form's `requirements=answer_renewal`) distinct from both this
document's approval and the per-use `build`/`issue` forms in §3 — i.e. even
once implemented, reviewed, and merged, the mechanism stays OFF (unwired,
no LaunchAgent, no default-on flag) until Terrence explicitly turns it on,
matching the `HERDR_OWNER_DISPATCH_CONSUMER`-style off-by-default posture
already used for `owner-dispatch-issue.py consume-pending` (PR #397).
