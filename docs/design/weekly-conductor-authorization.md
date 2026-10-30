# Weekly conductor authorization

Status: design candidate only. Offline planning. This document proposes no
code change, writes no TTL/security config, touches no database, and
activates nothing. It exists so the shape of a bounded, human-signed weekly
grant of conductor authority can be reviewed and approved before any of it
is built, the same posture `docs/design/resident-launch-grant.md` and
`docs/design/conductor-hold-precedence.md` already use for a change to who
may act unattended.

**Revision 2** (this version): responds to independent review
`REVIEW-WEEKLY-AUTH-962585c.md` (p35, 2026-10-30 12:24Z), which REJECTED
the first commit (`962585c`) on five material divergences from T's stated
intent plus one concrete mechanical gap. Fixed here, each inline at its
own section: (1)/(C) every lease a grant-authorized call creates AND the
redemption token it mints are now clamped to the grant's own `expires_at`
(§(f) item 5); (A) expiry is reframed from "falls back to the daily form"
to a visible PAUSE resolved only by one explicit weekly mint, with the
daily-form framing removed from this design's intended path (§(a), §(e),
§(f)); (B) Main's cross-task delegation privilege is now bounded by the
SAME scope and expiry as everything else the grant authorizes, with an
explicit numeric cap, not left permanently unbounded (§(c)); (E) pane
closure in §(i) is no longer unconditional — evidence is resolved before
either the state transition or the pane close, both held together; (F)
§(h)'s mint command now must print its own explicit start/end and flag a
weekend-spanning window on every successful mint, not only the no-op
refresh case. §(b)'s identity reasoning and §(a)'s 120h-vs-work-week
duration tradeoff were both reviewed and found sound — unchanged here.

## Problem this closes

T, 2026-10-30 12:03Z, DESIGN-only request, verbatim: *"we shouldn't have to
renew a lease every day; the main conductor should pick up identity and
manage others; it should last 1 work week, then I turn the key for the
following."*

`lib/owner_lease.py` is explicitly **INERT** today ("Nothing calls this...
reviewable source with offline proofs ahead of any activation decision",
`lib/owner_lease.py:6-9`) and every writer in it — `register_owner`,
`reregister_owner`, and this session's new
`lib/owner_lease_recover.recover_lifecycle()` — hard-caps `lifecycle_end_at`
at `ol.MAX_TTL_S` (86 400s = 24h, `lib/owner_lease.py:78`) past `now` on
every single call, by design (R13-BOUNDS.md's own stated intent: "never a
default/unbounded renewal path"). If whichever label(s) the conductor/Main
role's own standing registration depends on are recovered through
`owner-lease-recover.py` once that system activates, that 24h ceiling means
a human has to answer a fresh `--confirm-form` decision **once a day,
every day**, forever — exactly the burden T is naming. Lowering or removing
`MAX_TTL_S` itself is not the fix: that cap is a *global* safety bound
shared by every owner-lease label in the system (project ownership,
dispatch queues, anything else registered there), and weakening it to serve
one role would weaken it everywhere. This document proposes a **second,
narrower, longer-lived authorization that sits beside the lease, never
inside it** — the lease's own 24h math never changes.

## Existing mechanisms this reuses, not reinvents

Four pieces already exist, shipped and reviewed, that this proposal
composes rather than duplicates:

1. **Main identity, continuously re-proven, restart-safe** —
   `designate-main.sh` + the registry's own `roles` table (`lib/run-
   registry.sh:2377`, `read_role`/`register_role_cas`/`unregister_role_cas`),
   label `"main"`, storing exactly `(pane_id, pane_birth)`. Every
   conductor-authority check in this codebase (`herdr-select.sh`'s
   reviewed-conductor gate, `lib/push-wake.sh`'s revalidation,
   `conductor-handover.sh`'s "is the caller Main" check) already reads this
   same row and resolves the CALLER from `caller_pane_from_ancestry`
   (`lib/pane-guard.sh:297`) — the first ancestor pid herdr itself reports
   as a pane's current foreground process, never `$HERDR_PANE_ID`/env
   (spoofable, security review PR #252 F2). `designate-main.sh` already
   handles exactly the restart case this document's (b) asks about: "no
   live Main exists (dead, or birth no longer matches) → any non-worker
   agent pane may self-designate; the caller IS the current live Main →
   idempotent; `--handoff-to` run by the live Main → explicit succession."
   Liveness is a tri-state (`_is_live`, `designate-main.sh:148-168`): live /
   confirmed gone / **indeterminate**, and every call site fails closed on
   indeterminate — "couldn't tell" is never read as "gone" (that gap was
   R2-F12 in security review PR #252 and is already fixed).
2. **Managing/delegating existing workers** — `conductor-handover.sh` +
   `lib/run-registry.sh:set_task_conductor` (`lib/run-registry.sh:1114`): a
   per-task compare-and-swap of `conductor_pane_id`/`conductor_pane_birth`,
   gated on the caller being either that task's own current live conductor
   or the designated Main (`conductor-handover.sh:28-38`). This is already
   the exact power item (c) asks about ("manage and delegate existing
   workers") — nothing new needs building for the *mechanism*, only for
   *how long a human's "yes" to using it lasts without being asked again*.
3. **A grant shape that is minted once by a live, proven pane and redeemed
   later by an unattended/different caller, hard-capped, revocable, audited
   — already shipped**: `lib/task-authorization.py`'s
   `resident_escalation_grant` source (`lib/task-authorization.py:303-423`,
   `accept_resident`/`read_resident_for_repo`/`accept_resident_spawn`,
   implementing `docs/design/resident-launch-grant.md`). Same
   `task_authorizations` table (`lib/task-authorization.py:103-135`,
   columns include `command_id` PK, `source`, `claims`, `effective_scope`,
   `source_repo`, `issued_at`, `expires_at` INTEGER-ms, `status` CHECK IN
   `('accepted','bound','launch_claimed','launched')`), new `source` value,
   no new table — this document proposes the same move again:
   `source='conductor_weekly_authorization'`.
4. **One-file, zero-code-to-take-effect revocation** —
   `~/.local/state/herdr/merge-delegation.revoked` /
   `~/.local/state/herdr/resident-escalation.revoked` (`docs/design/
   resident-launch-grant.md:413-421`). Reused verbatim for (d) below.

This proposal is therefore glue, not a new primitive: a time-boxed
permission slip that says *"while this exists, unexpired, unrevoked, and
the registry's own `roles.main` row shows a live Main — honor that Main's
use of its own pre-existing powers (§2–3 above) without asking a human
again for each individual use."* It does not change what Main can do; it
changes how often a human has to say yes to Main currently being allowed to
do it.

## Exact scope — what this authorizes, and what it never does

- **Authorizes**: (i) an automated daily call of `owner-lease-recover.py
  --apply` for the specific, closed label set the grant names at mint time
  (the label(s) the conductor/Main identity's own standing registration
  depends on — never a wildcard, never "every label"), each individual call
  still subject to `recover_lifecycle()`'s own unchanged self-extension
  ban and TOCTOU-safe CAS, PLUS a new clamp this grant itself requires:
  the lease bound it sets and the single-use redemption token it mints are
  BOTH capped at `min(now + ol.MAX_TTL_S, grant.expires_at)` — never
  outliving the grant that authorized them (§(f) item 5, fixing
  independent review finding 1/C); this grant only ever substitutes for
  the **human confirmation** leg of that function's authorization, never
  the CAS, never the 24h ceiling itself, never the self-extension check;
  (ii) Main's CROSS-TASK use of `conductor-handover.sh` — the part of
  that script beyond a conductor giving away its own task — while a valid
  weekly grant is active: scoped to the SAME closed label/repo set as
  (i), capped at a hard, non-adjustable rate constant, and refused
  outright the instant the grant expires, is revoked, or never existed
  (§(c) spells out the exact cap, fixing independent review finding B/3 —
  an earlier draft of this document left this power permanently
  unbounded).
- **Never authorizes**: minting itself (human-only, every time, §(h));
  raising `recover_lifecycle`'s 24h cap, the grant's own clamp, or
  `owner_lease.MAX_TTL_S`; adding a label to the grant's scope after mint
  (widening scope = a new mint, a new human consent, never an edit of a
  live grant — tested explicitly, §(g) item 4); a cross-task handover
  beyond the grant's own closed scope or its numeric rate cap, even while
  the grant is otherwise valid (§(c)); spawning a *new* task/worker (that
  is `spawn-task.sh`'s own, separately-gated authority, untouched);
  crossing to a different Main pane without that pane independently
  clearing `designate-main.sh`'s own, unmodified succession rules.

## (a) Two distinct durations — never merged into one

| | **Heartbeat / liveness lease** | **Weekly conductor authorization (new)** |
|---|---|---|
| What it proves | "this exact lease row is renewed and not yet expired" | "a human said yes to Main operating without a fresh daily ask, until this date" |
| Storage | `owner_leases` (unchanged) | `task_authorizations`, new `source` |
| Typical TTL | ~1h, renewed every ~15min (`owner_lease_renew.RENEW_TTL_S`/`RENEW_MARGIN_S`) | ≤5 work days, one mint, no auto-renew |
| Who/what renews it | the tick itself, unattended, continuously (`renew_due`) | **only T, outside herdr, every time** (§(h)) |
| What its expiry means | the lease is simply gone — the NORMAL, frequent, harmless case `renew_due`/`acquire` already handle every day | the grant is gone — the daily automated `owner-lease-recover.py --apply` call AND Main's cross-task delegation under the grant both STOP immediately; the label PAUSES (the same stuck state an unanswered recovery already has today) until T runs the ONE weekly mint command again (§(h)). This design never surfaces, relies on, or frames a human answering a fresh `--confirm-form` as the intended path back to authorization for the conductor-identity label — pausing is the correct, expected steady state, not an emergency fallback (fixes independent review finding A) |

These must stay two separate objects, never one merged "renew the lease for
a week" change, for the reason resident-launch-grant.md already established
for an analogous pair (its grant vs. a spawned task's own short TTL,
`docs/design/resident-launch-grant.md:394-409`): the short lease is the
thing that proves something is *alive right now*, cheaply, automatically,
many times a day — weakening its own TTL to "a week" would mean a dead
holder's stale lease could go undetected for up to that long. The weekly
object never claims liveness; it claims **authorization to act without
re-asking**, a materially different and narrower promise, and the thing it
authorizes (the daily recovery call) still has to independently prove the
underlying row is real and CAS-correct every single time it runs, exactly
as if a human had typed `--confirm-form` fresh that morning.

**Duration definition — a choice this document surfaces rather than
defaults past T, same as resident-launch-grant.md's Option A/B table**:

| | **Fixed 120h duration (recommended)** | **Calendar work-week (Mon–Fri)** |
|---|---|---|
| Expiry rule | `expires_at = issued_at + 5×24h`, flat, no calendar awareness | `expires_at` = end of the Friday the grant was minted in, or the next Friday if minted on a weekend |
| Minted Monday 09:00 | Expires Saturday 09:00 | Expires Friday ~24:00 (shorter) |
| Minted Friday 16:00 | Expires Wednesday 16:00 (spans the weekend, ends mid-week) | Expires the FOLLOWING Friday (up to 12 days — violates "≤5 work days") |
| Implementation | one subtraction, no timezone/calendar logic, matches every other TTL in this codebase (all plain epoch-ms arithmetic) | needs a timezone-aware calendar rule (whose timezone? DST?) — new code class nothing else here has |
| Risk | "work week" framing is approximate when minted mid-week | exactly matches "I turn the key for the following week" framing, but can silently exceed 5 real work days if minted near a weekend, which is the one thing (a) explicitly caps |

**Recommendation: fixed 120h.** It is the only option that cannot, by
construction, ever exceed the explicit "≤5 work days" cap regardless of
which day it is minted on, and it costs zero new calendar logic in a
codebase where every other expiry (`task_authorizations.expires_at`,
`owner_leases.expires_at`, `owner_projects.lifecycle_end_at`) is already
flat epoch arithmetic. T mints a fresh one whenever he actually sits down
to "turn the key," which need not be a fixed weekday — 120h from that
moment is "about a work week" without ever becoming more.

## (b) Identity recovery across pane/hub restart — no spoofing

This is **not new code** — it is `designate-main.sh`'s existing, already-
reviewed succession rule, deliberately left untouched and reused as-is,
because inventing a second "who is the real Main" check beside it would be
exactly the kind of second mechanism REVIEW-GRANT-9ac2fc4 warned against
(a parallel path is a place for the two to disagree).

At redemption time (the daily automated call, and any `conductor-
handover.sh` use), the ONLY identity question ever asked is the one
`herdr-select.sh`/`push-wake.sh` already ask today: *does `roles.main`
currently name a LIVE `(pane_id, pane_birth)`, and does the caller's own
`caller_pane_from_ancestry` resolve to exactly that pane?* The grant never
stores or compares against a frozen `(pane, birth)` snapshot from mint
time — if it did, a pane or hub restart (a new `pane_birth`, by design —
`lib/pane-guard.sh`'s whole point is that birth changes on restart so a
revived process can never inherit a dead one's identity) would silently
break the grant the moment the thing it exists to help with (surviving a
restart) actually happens. Instead the grant answers one question only:
*"is a currently-live, registry-proven Main — whoever that now is, via
`designate-main.sh`'s own unmodified succession rules — still within the
window a human authorized?"* Proving *who* that live Main is remains
entirely `designate-main.sh`'s job, continuously, for free, exactly as
today.

**What this means concretely for "the main conductor should pick up
identity"**: after a hub restart or a pane recycle, a NEW pane runs
`designate-main.sh` and becomes Main through its EXISTING rule ("no live
Main exists → any non-worker agent pane may self-designate" —
`designate-main.sh:58-61`) — nothing about that step changes. The weekly
grant, minted BEFORE the restart and still unexpired, is then immediately
usable by the NEW Main pane on its very next redemption attempt, because
the grant's own lookup re-reads `roles.main` fresh every time (no caching,
same discipline `_esc_check_launch_authority` already uses for the
revocation sentinel, `docs/design/resident-launch-grant.md:425`) — it never
needed to "recognize" the new pane specifically; it only ever asks whether
*some* live, registry-legitimate Main exists right now.

**No spoofing**: a caller cannot forge this by exporting an env var
(`caller_pane_from_ancestry` never reads one), cannot forge it by running
`designate-main.sh` from outside herdr entirely (that path is `--force`,
which itself requires `caller_pane_from_ancestry` rc=2 — genuinely outside
herdr's reach — and is reserved for T, same proof this document's own
mint step reuses, §(h)), and cannot forge it by presenting a stale
`roles.main` row across a restart (the liveness tri-state fails closed on
`indeterminate`, so a herdr read failure during the restart window refuses
rather than guesses).

## (c) Managing and delegating existing workers — bounded by this grant's scope and expiry (fixes independent review finding B/3)

`conductor-handover.sh` has two distinct powers today, and only one of
them is what this grant exists to time-box:

- **Self-handover (unaffected, out of scope)**: any conductor may give
  away its OWN task (`conductor-handover.sh:28-38`). Pre-existing,
  unconditional, unrelated to Main-ness — this grant neither widens nor
  narrows it; it needs no authorization today and gets none from this
  document.
- **Cross-task handover (bounded by this grant)**: ONLY Main may give away
  a task it does not itself hold (`set_task_conductor`'s CAS is keyed on
  an existing, non-terminal task row — there is no "create a task and
  immediately own it" path through this script). This is the genuinely
  novel power item (c) names, and an earlier draft of this document left
  it permanently unbounded ("Main does NOT lose the ability to run
  conductor-handover.sh" after expiry) — independent review
  (`REVIEW-WEEKLY-AUTH-962585c.md` finding B/3) confirmed this diverges
  from T's literal ask ("manage others... for 1 work week"). Fixed here:
  while a valid weekly grant is active, Main's cross-task use of
  `conductor-handover.sh` is
  - **scoped**: to the SAME closed label/repo set the grant names at mint
    (§"Exact scope") — never "any task" unconditionally; delegating a
    task outside that set still independently requires that target to
    hold a live `proj:` claim for the task's repo
    (`lib/run-registry.sh:1092-1101`, P2 project-scoped handover) AND is
    refused by the new scope check regardless;
  - **capped**: at a hard, non-caller-adjustable rate constant proposed as
    `CONDUCTOR_HANDOVER_CAP = 10` handovers per grant period — the same
    fixed-constant-never-env-overridable posture `ORCH_CHILD_CAP` already
    uses (`lib/task-authorization.py:33`: "deliberately not env-
    overridable... changing it is a reviewed code change"); a call past
    the cap is refused, named, exactly like every other check in this
    document;
  - **expired exactly with the grant**: the instant the grant expires, is
    revoked, or never existed, a CROSS-TASK handover attempt is REFUSED
    outright — not merely "the daily recovery call stops" as the rejected
    first draft stated. Without a valid grant, Main retains only the
    baseline self-handover power every conductor already has; it cannot
    reach a different task's row until a fresh weekly mint (§(h)) exists.

This makes "manage and delegate existing workers" bounded by the exact
same scope and expiry as everything else this grant authorizes — not a
separately-unbounded, pre-existing power the grant merely wraps in an
audit log, which is what the rejected first draft actually described.

## (d) Revocation and audit trail

Reuses the exact sentinel-file shape §(resident-launch-grant.md:411-441)
already established, under its own distinct filename so the two features
can never be confused or cross-revoked by accident:

- `touch ~/.local/state/herdr/conductor-weekly-authorization.revoked` — one
  file, no code required to take effect, checked fresh (no caching) before
  every grant lookup in both consuming call sites (§(f)'s daily recovery
  tick and §(c)'s now-bounded cross-task `conductor-handover.sh` check).
- **Mint audit**: an `events` row in the same transaction as the
  `task_authorizations` INSERT (mirrors `accept_resident`'s own
  `_insert`/`event()` pattern) — `minting_pane`, `minting_pane_birth`
  (= the human's own ancestry-resolved identity at mint time, §(h)),
  `reason` (required, non-empty, same requirement
  `conductor-handover.sh:107` already enforces for its own `--reason`),
  `expires_at`, `command_id`.
- **Cross-task delegation audit**: every grant-scoped cross-task
  `conductor-handover.sh` call records its own position against
  `CONDUCTOR_HANDOVER_CAP` in its existing `conductor_handover` event
  detail (§(c)) — auditable per-grant usage, not merely per-call.
- **Redemption audit**: every automated daily recovery call under the
  grant writes the SAME `owner_events('lifecycle_recovered', ...)` row
  `recover_lifecycle()` already writes for a human-confirmed recovery
  (`lib/owner_lease_recover.py`, this session) — no new event kind needed;
  the call's `confirmation_ref` (currently a formserve answer id) becomes,
  for a grant-authorized call, the grant's own redemption token id instead
  (never the bare grant `command_id` — see the REVIEW-GRANT-9ac2fc4 lesson
  cited in §(f)), so the audit trail stays uniform and still names exactly
  which authorization stood behind each individual recovery.
- **Revocation audit**: `touch` itself carries no actor — a companion
  revoke command (not a bare hand-`touch`) must also write one `events` row
  naming who revoked and when, same gap resident-launch-grant.md's own
  §7 already flags for its sentinel and the same fix applies here.
- **Expiry audit**: none needed at the moment of expiry — the row simply
  stops matching the lookup predicate (`status='accepted' AND
  expires_at>now()`), same as every other `task_authorizations` consumer.
  A future hub-dashboard surfacing "no weekly conductor authorization is
  currently active" (mirroring `xd://decisions_open`'s existing style) is
  optional, not required for v1.

## (e) Hard stop — PAUSE, never a silent reversion to the daily form

- **No grant → the automated path PAUSES; it never silently reverts to a
  daily human form.** The consuming code's lookup (`read_conductor_week()`,
  modeled on `read_resident_for_repo`, `lib/task-authorization.py:
  373-388`) returns `{}` for "no row," "expired," AND "revoked" alike —
  all three collapse to the identical fallthrough: the daily automated
  `owner-lease-recover.py --apply` call AND Main's cross-task delegation
  under the grant (§(c)) both simply STOP. This design does not surface,
  rely on, or describe a human answering a fresh `--confirm-form` as the
  intended next step for the conductor-identity label (fixes independent
  review finding A — the rejected first draft framed that reversion as
  "never a security failure, just a return to the status quo," which
  read as an intended, desirable fallback rather than a pause). There is
  no degraded middle state and no silent retry-forever: the label goes
  stuck/blocked, the identical honest resting state an unanswered
  recovery already has today with no grant mechanism built at all. The
  ONLY way forward is exactly ONE explicit weekly mint (§(h)) — this
  design removes the daily-renewal BURDEN; it does not reintroduce daily
  renewal as a fallback path.
- **No grant admits an unproven caller.** The lookup is read-only and
  content-based (does a valid row exist), never "trust whoever is asking" —
  the SAME `roles.main` liveness check from §(b) runs on every single
  redemption, not just the first one after mint. A Main that goes dark
  mid-week (pane dies, no successor self-designates) makes the grant
  **unusable**, not merely idle — there is no live Main for the lookup's
  identity leg to match against, so redemption refuses even though the
  grant row itself is still technically unexpired. This is deliberate: the
  grant authorizes a LIVE Main, never a frozen moment-in-time identity.
- **No re-mint without the human step.** Nothing in this design — not the
  daily automated recovery, not `conductor-handover.sh`, not any future
  tick — can extend, renew, or re-issue the grant. Only §(h)'s exact
  command, run by T, every time, produces a new row. Expiry is therefore a
  true hard stop: the system cannot talk itself back into authorization.

## (f) How this supersedes `owner-lease-recover.py`'s daily forms — for the conductor-identity label only

`owner-lease-recover.py` (`owner-lease-recover.py`, this session) today
requires `--confirm-form <formserve id>` in BOTH dry-run and `--apply`,
bound to an exact `(label, new_lifecycle_end_at, caller_pane_id,
caller_pane_birth)` tuple (`owner-lease-recover.py:read_confirmation`) —
that id must be freshly answered by a human, once per call, because the
24h cap means a new call is needed roughly once a day for any label stuck
past its bound. For every OTHER owner-lease label, that path is untouched
and remains the CLI's only mechanism. For the conductor-identity label
specifically, this document proposes a SECOND, alternate confirmation
path — `--conductor-grant <redemption-token-id>` beside the existing
`--confirm-form <form-id>` — reached only by a new, unattended daily tick
(not interactively by T), that:

1. Checks the revocation sentinel first (§(d)), then looks up the current
   `conductor_weekly_authorization` row (§(e) — absent/expired/revoked all
   fall through identically to "no grant," at which point the tick simply
   does not run `--apply` today and the label PAUSES — it does not wait
   for or request a human form; resuming requires a fresh weekly mint,
   §(h)).
2. Re-verifies the live-Main identity check (§(b)) — refuses if no live,
   registry-proven Main currently exists, even with a technically-valid
   grant row.
3. Checks the label being recovered is IN the grant's own closed label
   list from mint time (§"Exact scope") — a grant minted for label
   `conductor` can never be presented for any other label, including a
   NEWLY-registered one that did not exist at mint time; widening this set
   is always a brand-new mint (§(g) item 4 tests this explicitly).
4. Only then mints a **brand-new, single-use, short-TTL redemption token**
   (mirrors `accept_resident_spawn`'s own `grant_command_id` link,
   `lib/task-authorization.py:391-422`) and passes THAT token's id as
   `--conductor-grant`, never the bare weekly grant's own `command_id`.
   This is not optional polish — it is the exact, previously-real defect
   REVIEW-GRANT-9ac2fc4 found and fixed for the resident-escalation grant
   (`docs/design/resident-launch-grant.md:304-313`): a bare grant id,
   once it appears in any ordinary audit record (and it will — every
   `owner_events` row names its `confirmation_ref`), becomes a reusable
   bearer credential for the grant's entire remaining week if ever passed
   straight through instead of being redeemed into a single-use token
   first. `owner-lease-recover.py`'s own `read_confirmation`-equivalent
   check for this path must validate the token's `source` is exactly
   `conductor_weekly_redemption` and reject a bare
   `conductor_weekly_authorization` id outright, the same way `--confirm-
   form`'s check rejects a form that is not `status=="answered"`. **This
   redemption token — the "child grant" of the standing weekly
   authorization — is itself clamped**: its own `expires_at` is
   `min(issued_at + <short redemption TTL>, grant.expires_at)`, so a
   token minted near the end of the week cannot outlive the grant that
   authorized it, even before step 5's own clamp is reached.
5. `recover_lifecycle()` itself (`lib/owner_lease_recover.py`) is called
   with ONE bound change specific to this path:
   **`new_lifecycle_end_at = min(now + ol.MAX_TTL_S, grant.expires_at)`**
   — a lease this path creates or extends can never reach past the
   grant's own `expires_at`. This closes the exact gap independent review
   (`REVIEW-WEEKLY-AUTH-962585c.md`, finding 1/C) found: an unclamped call
   near hour 100 of a 120h grant would otherwise set a 24h-out bound
   reaching ~hour 124 — up to ~24h past the grant's own end, letting the
   label's standing registration outlive the authorization that produced
   it. Every OTHER check `recover_lifecycle()` already enforces — self-
   extension ban, the 24h ceiling as the other half of the `min()`,
   TOCTOU-safe CAS — stays unchanged regardless of which confirmation path
   supplied `confirmation_ref`; the grant only ever substitutes for the
   human clicking "approve" on a form, and now additionally supplies this
   one clamp. Every other check this session already built and verified
   (45/45, `verify-owner-lease-recover.py`) still runs, unchanged, every
   day.

**Net effect for T**: for every OTHER owner-lease label, nothing changes —
the daily `--confirm-form` path remains the CLI's only mechanism,
untouched. For the conductor-identity label specifically, once a valid
weekly grant exists, the daily `--confirm-form` decision disappears for up
to 120h, with the resulting lease and its redemption token both clamped
exactly to the grant's own window (item 5) — and on expiry or revocation,
the label PAUSES rather than silently reverting to a daily form: the only
way forward is the ONE weekly mint in §(h), never an assumption that a
human will resume answering individual daily prompts.

## (g) Exact test list (negatives required before any code lands)

Offline, same fake-command-seam / fixture style as
`verify-resident-launch-grant.sh` and `verify-owner-lease-recover.py`
(mktemp DB, no live registry, no real `herdr` call) — this is the gate
before implementation, not a retrofit:

1. **Spoofed pane (explicit ask)**: a caller whose `$HERDR_PANE_ID`/
   `$HERDR_TASK_ID` env claims to be the live Main, but whose
   `caller_pane_from_ancestry` resolves to a DIFFERENT pane (or none) —
   refused; the grant lookup's identity check must use ancestry only,
   never env, proven by a fixture where env and ancestry disagree.
2. **Expired week (explicit ask)**: a grant with `expires_at` in the past
   — refused, falls through to "no grant" behavior byte-for-byte, same
   shape as resident-launch-grant.md's own item 2; boundary case
   (`expires_at == now` must refuse, one second before must still pass).
3. **Revoked (explicit ask)**: the sentinel file present — refused even
   against an otherwise fully valid, unexpired, correctly-scoped grant,
   and checked BEFORE the grant lookup (ordering test, mirrors resident-
   launch-grant.md item 6); created mid-week, takes effect on the very
   next tick with no restart (item 7's shape).
4. **Scope widening (explicit ask)**: a grant minted for label `conductor`
   presented for a DIFFERENT label (including one that did not exist at
   mint time) — refused; a second, separate test proves a grant can never
   be mutated in place to add a label (no UPDATE path exists for
   `effective_scope` on an `accepted` row — only a brand-new mint can).
5. A grant exists, unexpired, unrevoked, correctly scoped — but
   `roles.main` currently shows NO live pane (dead, or `_is_live` returns
   indeterminate) — refused (§(b)/(e)); must NOT fall back to "trust the
   grant's own minting_pane snapshot."
6. A grant exists and is valid, but the CURRENT live Main is a
   DIFFERENT pane than the one that minted it (legitimate succession via
   `designate-main.sh` mid-week) — **admitted**, proving (b)'s restart
   story actually works, not just that it fails safe.
7. The bare weekly grant `command_id` presented directly as
   `--conductor-grant` (bypassing the redemption-token mint) — refused
   (wrong `source`), directly proving the REVIEW-GRANT-9ac2fc4 lesson is
   re-applied here, not just described (mirrors resident-launch-grant.md
   item 5, the test that was missing from that feature's own first cut).
8. A redemption token claimed once succeeds and recovers the correct
   grant id; a second claim of the SAME token is refused (single-use,
   mirrors resident-launch-grant.md item 8).
9. `--force`-equivalent mint identity check: a mint attempt from a process
   whose ancestry traces to ANY herdr pane at all (worker, conductor, or
   Main itself) is refused — only `caller_pane_from_ancestry` rc=2
   (genuinely outside herdr) may mint, proving Main can never self-renew
   its own authorization (§(h)'s core safety property).
10. The full existing `verify-owner-lease-recover.py` suite (45
    assertions as of this session) stays green with the new
    `--conductor-grant` branch present but no grant ever minted in any
    fixture — the new path must be provably inert until a human has run
    the mint command, same proof shape resident-launch-grant.md item 9
    requires.
11. A mutation probe reverting the new branch to "always fall through to
    `--confirm-form`-only" must make the valid-grant positive-path test
    fail — proving the branch is load-bearing, not dead code (mirrors
    resident-launch-grant.md item 10).
12. A positive end-to-end fixture — valid grant, live Main, correct label,
    redemption token mints and claims, `recover_lifecycle()` succeeds,
    audit event carries the redemption token id — required before
    activation but, like resident-launch-grant.md's own closing note, does
    not by itself satisfy items 1–11; all of the negatives above gate
    activation independently.
13. **Lease clamp at grant near-expiry (fixes finding 1/C)**: a grant-
    authorized recovery call at hour 100 of a 120h grant sets
    `lifecycle_end_at` to exactly the grant's `expires_at` (hour 120), NOT
    hour 124 — proving the `min(now+24h, grant.expires_at)` clamp from
    §(f) item 5. A call well before the window's end (hour 10) is
    unaffected — it still gets the full 24h, proving the clamp only bites
    near expiry, never shortens an ordinary call.
14. **Redemption token (child grant) clamp**: a redemption token minted at
    hour 119 of a 120h grant has its own `expires_at` capped at hour 120,
    never its normal short redemption TTL past that point (§(f) item 4).
15. **Delegation cap and expiry (fixes finding B/3)**: a cross-task
    `conductor-handover.sh` call beyond `CONDUCTOR_HANDOVER_CAP` within
    one grant period is refused even though the grant itself is otherwise
    valid; a cross-task call naming a label/repo OUTSIDE the grant's own
    scope is refused; a cross-task call attempted after the grant has
    expired is refused outright — not merely "the daily recovery call
    stops" (§(c)); a SELF-handover (any conductor giving away its own
    task) succeeds identically with no grant at all, proving that power
    stayed untouched.
16. **Mint prints its own start and end (fixes finding F)**: a fresh mint's
    terminal output states both `issued_at` and `expires_at` as absolute
    timestamps; a mint whose `[issued_at, expires_at)` window includes a
    Saturday or Sunday prints an explicit weekend-spanning flag; a mint
    whose window does not must NOT print that flag (no false positive).

## (h) The one action-time activation consent T would sign

Exactly one new command, run by T, every time, from OUTSIDE herdr entirely
— the identical proof `designate-main.sh --force` already requires
(`caller_pane_from_ancestry` returns rc=2: the ancestry walk completed and
found NO herdr pane anywhere in this process's chain, `designate-main.sh:
77-90`) — never from inside a Main pane, never relayed by an agent on his
behalf, never inferred from a prior week's grant or from this document
existing:

```
grant-conductor-week.sh --reason "<text>"
```

- **No `--pane` argument** — the grant binds to whichever pane
  `roles.main` names live AT THE MOMENT of each redemption (§(b)), never a
  pane T names by hand at mint time; naming one would reintroduce exactly
  the frozen-snapshot restart problem (b) exists to avoid.
- **No `--days`/`--ttl` argument** — fixed at 120h (§(a)'s recommended
  option), a hard constant in the command itself, not a caller-supplied
  value, same posture `grant-resident-escalation.sh`'s own hard tier/TTL
  caps take (`docs/design/resident-launch-grant.md:407-409`: "No grant may
  ever request a longer window; the mint command itself refuses a `ttl`
  argument above the cap").
- **`--reason` is the one required field** — non-empty, audited verbatim
  (§(d)), the same bar `conductor-handover.sh --reason` already sets.
- **The label scope is the one other thing fixed in the command itself**
  (not caller-supplied either) — a closed, reviewed list of the exact
  label(s) the conductor/Main identity's own standing registration
  depends on, hard-coded in `grant-conductor-week.sh`, changeable only by
  editing and re-reviewing that script, never by an argument at mint time.
  This is what makes "scope widening" (§(g) item 4) a code change and
  review, not a runtime choice available to whoever runs the mint command.
- **Every mint prints its own start and end, explicitly — not only the
  no-op-refresh case (fixes independent review finding F).** On a FRESH
  mint, the command's own terminal output states both `issued_at` and
  `expires_at` as absolute timestamps, never just "120h" — and prints a
  visible flag line whenever `[issued_at, expires_at)` includes a Saturday
  or Sunday (e.g. `NOTE: this window includes a weekend — effective
  working days may be fewer than 5`), so the window is never silently
  read as "until Friday" or silently assumed to be exactly five business
  days. §(a)'s Duration table is honest about weekend-spanning in the
  document's own prose; this makes the RUNTIME TOOL say the same thing to
  T at the exact moment he turns the key, not only in a design doc he
  read once.

Running it when a grant is already active and unexpired is a no-op refresh
— it ALSO prints both `issued_at` and `expires_at` (same requirement,
same format, no special case), writes nothing new — not a silent
extension of the existing window; "turning the key" always produces a
grant whose `expires_at` is 120h from the moment the command actually
ran, same "retry keeps the original validity window, never extends it"
rule `accept_resident`/`accept_local` already enforce
(`lib/task-authorization.py:281,354`) — reread as: a SECOND run before the
first expires replaces nothing silently; its own new `command_id` mints a
genuinely separate row rather than lying about `issued_at`.

## (i) A closed session must never fabricate a completed task

Added 2026-10-30, after a real incident: `close-done-workers.sh --apply`
set `state=completed` on 15 tasks that still held an **approved-but-
unconsumed action request** (10 on pane `p55` alone) and 12 tasks that
still held a **seen-only prompt occurrence** — a prompt the pane displayed
but that was never driven to resolution. This belongs in the weekly-
conductor-authorization document specifically because the daily automated
recovery tick in §(f) and any future no-progress-escalation successor
logic are exactly the kind of mechanism that could read a fabricated
`completed` as a green light to inherit a grant or spawn a successor —
this section makes that invariant explicit and names the actual defect
that would otherwise feed it bad input.

### Root cause

`close-done-workers.sh`'s closability gate (`close-done-workers.sh:30-48`,
the four checks: pane idle, worktree gone-or-clean, no unpushed commits)
is entirely about **git/pane hygiene**. It never reads `approvals`
(`lib/run-registry.sh:302-319` — `decided_at`/`attempted_at`/
`confirmed_at`/`outcome`, the three-timestamp model security review
correction 6 already requires precisely so "decided but never delivered"
is a queryable fact) and never reads `prompt-occurrence.py`'s per-task
occurrence records (`first_seen_at`/`unresolved_reason`/
`resolution_reason`, `lib/prompt-occurrence.py:941-964`). A task whose
worktree is clean and whose pane is idle passes every existing check even
when a human/conductor approved an action the worker never re-issued
(`decided_at` set, `outcome` still NULL), or a prompt was painted and
never resolved (`unresolved_reason` set, `resolution_reason` still NULL).
`close-done-workers.sh:770` then calls `set_task_state(... "completed"
...)` on exactly that row — git-clean is not evidence the WORK finished,
only that nothing is sitting uncommitted.

### The fix this document proposes (still design-only, still no code)

**Decouple two facts `close-done-workers.sh` currently fuses into one
action.** Today, "close the pane" and "mark the task completed" happen in
the same `apply=1` branch, back to back (`close-done-workers.sh:764-782`).
They become two independently-true records:

1. **Closing a session/pane must never imply completion.** Before EITHER
   the `completed` transition or the pane close itself, the gate gains a
   fifth and sixth check, same shape as the existing four (report-and-
   hold, never silently skip, and now symmetric with them in what they
   gate — see item 3): no `approvals` row for this `task_id` has
   `decided_at IS NOT NULL AND outcome IS NULL` (an approved action never
   consumed), and no `prompt-occurrence` row for this task has
   `unresolved_reason IS NOT NULL AND resolution_reason IS NULL` (a prompt
   only ever seen). Either one HOLDS BOTH the `completed` transition AND
   the pane close (item 3), named with the exact `approval_id`/occurrence
   key, exactly how the existing four checks already name their own hold
   reason — never a silent skip.
2. **The real hold/approval-consumption/uncertain-outcome state survives.**
   A task held by check 5 or 6 does not become `completed` **and its pane
   does not close either** — the SAME honest failure mode the file's own
   `refused` branch (`close-done-workers.sh:770-780`) already treats as
   unacceptable ("leave its state... untouched... instead of a lie")
   applies here too: it moves to the registry's existing `blocked` state
   (already a valid, non-terminal value — no new enum needed) with a
   reason naming which evidence is outstanding
   (`approval_unconsumed:<approval_id>` /
   `prompt_unresolved:<occurrence_key>`), and the pane stays open — exactly
   like a row held by any of checks 1–4 today — so a human can still
   re-query it. There is no third, in-between state where the pane is
   gone but the evidence question is still open.
3. **Evidence is captured and resolved BEFORE the pane is ever allowed to
   close — closure is never unconditional (fixes independent review
   finding 6/E).** Checks 5 and 6 are fully symmetric with the file's
   existing four (`close-done-workers.sh:30-48`): failing EITHER holds
   BOTH the state transition AND the pane close together, exactly like
   checks 1-4 already do — there is no "close the pane anyway, just
   don't say completed" path. An earlier draft of this document made pane
   closure unconditional even while gating only the `completed` label,
   which meant the pane — and with it, any further ability to re-query
   live state — could still disappear out from under an unresolved
   approval or prompt; that is the exact defect independent review
   (`REVIEW-WEEKLY-AUTH-962585c.md`, finding 6/E) found. Only once checks
   1–6 ALL pass does `close-done-workers.sh` append a NEW `events` row,
   `type='session_closed'` (`task_id`, `run_id`, `pane_id`, `pane_birth`,
   `closed_by`, `closed_at`, `reason` = the batch's `closure_reason`), in
   the SAME transaction as the `completed` state write, and only then
   does the pane actually close. The record stays conceptually SEPARATE
   from work completion — it answers "when did this session end," the
   state write answers "was the work verified done" — but both facts are
   now produced together, atomically, only once evidence is clean, which
   closes the gap independent review found without reopening the
   "phantom `running` row against a gone pane" failure mode this
   document's checks 1-4 already exist to prevent (a HELD row's pane
   stays open and reachable, never orphaned, per item 2).
4. **No grant inheritance, no automatic successor, on a fabricated
   completion.** Stated as a hard invariant for every consumer, present
   and future: `state='completed'` is the ONLY admissible completion
   signal for (A) this document's own §(f) daily redemption tick (it
   already never reads task state at all — confirmed here as deliberate,
   not incidental), (B) any no-progress-escalation successor-spawn logic,
   and (C) any future "hand the next task to whoever finished the last
   one" convention. A `session_closed` event — now written only once a
   closure actually completes (checks 1-6 all passed, item 3) — must
   still never be read as evidence of completion by anything; it proves
   only that a pane stopped existing, not that the work behind it was
   verified done.

### Negative tests required before any of this lands (design-only gate)

1. **A closed stalled task** — pane idle, worktree clean, no unpushed
   commits, and no outstanding `approvals`/prompt-occurrence evidence
   (passes all 6 checks) — closes and reaches `completed` exactly as
   today's batch-reason semantics intend (e.g. `--reason=no-follow-on`
   requires no per-task proof); this test exists to prove checks 5/6 add
   a gate without regressing the existing, accepted "nothing more to do"
   closure path.
2. **An approved-but-unconsumed request** — an `approvals` row with
   `decided_at` set and `outcome IS NULL` for the task under test — the
   close attempt HOLDS on check 5: the task state stays `blocked` (named
   with the exact `approval_id`), the pane stays OPEN (not closed), and no
   `session_closed` event is appended at all — none of the three happens
   independently of the others (dry-run must change nothing, same as
   every other check in this file).
3. **Pane-only evidence loss** — the pane itself is gone (no live occupant
   to re-query) and the ONLY remaining evidence is the registry's own
   `approvals`/`prompt-occurrence` rows; if those rows themselves cannot be
   read (query failure, corrupt row, anything short of a clean "no
   outstanding evidence" answer), the gate HOLDS the state transition —
   never defaults to "could not check, assume fine, mark completed."
   Mirrors the existing `panes_ok` fail-closed pattern at `close-done-
   workers.sh:181-189` (F2, security review round 2) applied to the new
   evidence sources instead of pane-list shape. Since the pane itself is
   already gone in this scenario, the test asserts the TASK STATE is never
   silently marked `completed` on unreadable evidence — the "hold the
   pane too" half of item 3 only applies when there is still a pane left
   to hold.

## Review boundary

This document, the new `grant-conductor-week.sh` command, the new
`accept_conductor_week`/`read_conductor_week`/`claim_conductor_redemption`
adapters in `lib/task-authorization.py`, `owner-lease-recover.py`'s new
`--conductor-grant` branch (including its lease/redemption-token clamp,
§(f) items 4-5), `conductor-handover.sh`'s new cross-task grant/scope/cap
check (§(c)), and §(i)'s two new `close-done-workers.sh` evidence checks
plus the gated `session_closed` event are a security-relevant change to
who may act as Main without a fresh human decision, and to what a closed
task registry row is allowed to claim happened — security-reviewer, zero
unresolved high/critical findings, before any of it lands,
not activation: no grant exists until `grant-conductor-week.sh` is run,
and the first grant requires T first-hand, outside herdr, every single
time — not a conductor acting on a prior general approval, not inferred
from this document existing, not inferred from the code having merged.
This document does not request that approval; it exists so that when it is
requested, the exact shape being approved is already written down.
