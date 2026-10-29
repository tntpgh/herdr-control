# Resident escalation launch grant

Status: design candidate only. Offline planning. This document proposes no
code change, activates nothing, and grants no authority. It exists so the
decision to build it (and the decision to turn it on) can be made with the
full shape in front of Terrence at once, instead of inferred piecemeal.

## Problem this closes

R8 (`8376ffb`) added `_esc_check_launch_authority` (`lib/escalation.sh:537-
556`), called once by `esc_escalate` immediately after lock acquisition and
strictly before `_esc_quiesce_old_writer` (`lib/escalation.sh:1056-1059`). It
reuses `spawn-task.sh`'s own real gate — `caller_pane_from_ancestry` +
`pane_is_conductor_eligible` (`lib/pane-guard.sh:297-324`,
`lib/pane-guard.sh:161-173`) — read-only,
never reimplemented. In production this check fails every time, by
construction: the real caller chain is `hub.py`'s `stall-watchdog` daemon
thread (`daemon=True`, started unconditionally at hub startup, `hub.py:5824`)
running `_stall_watchdog_loop` (`hub.py:4712-4719`) which calls
`_stall_watchdog_tick()` (`hub.py:4676-4709`), which forks `bash
stall-watchdog.sh wake ...` as a **plain subprocess** (`hub.py:4700-4702`) —
not a process running inside any herdr pane. `stall-watchdog.sh`'s
`_sw_escalation_tick` then calls `esc_escalate` directly
(`stall-watchdog.sh:268-287`, the call at `285-286`). A background daemon's
subprocess chain cannot acquire herdr-pane ancestry by waiting or retrying;
this is a structural certainty, independently confirmed by both R7's review
(`REVIEW-ESC-R7.md:198-348`, "Confirmed the real production caller has no
pane ancestry") and this round's own reading of the same files.

R8's behavior on refusal is correct and is **not changed by this proposal**:
the old writer stays untouched, the task is marked `blocked` (reason
`no_launch_authority`, discoverable via the existing `journal_table`/
`journal_key` event fields), never quiesced, never retried. Today, that is
the *permanent* outcome for the resident caller — there is no path to
production success at all. This document proposes the "if production success
is required" half the R7 review named as out of scope and explicitly deferred
("a new persistent-access decision, not something I can clear myself"):

> it needs its own legitimate, persisted authorization — the same shape
> `spawn-task.sh` already has for a remote-MCP publisher
> (`authorization_command_id` + `read_task_authorization`,
> `spawn-task.sh:415-419`), established and reviewed as its own
> security-relevant change, never inferred or self-asserted by the watchdog.

## Existing mechanism this reuses, not reinvents

`spawn-task.sh` already has exactly two ways a spawn's authority can be
proven, both backed by the single `task_authorizations` table
(`lib/task-authorization.py:103-154`, columns include `command_id` PK,
`source`, `claims`, `effective_scope`, `source_repo`, `issued_at`,
`expires_at` INTEGER, `deadline_at` TEXT default `''`, `status` CHECK IN
`('accepted','bound','launch_claimed','launched')`):

1. **Live ancestry** (`spawn-task.sh:924-935`): when no
   `--authorization-command-id` is given and the job is `managed` (default,
   `spawn-task.sh:189`), the caller's *own, current* process ancestry must
   resolve via `caller_pane_from_ancestry` + implicit eligibility, and
   `spawn-task.sh` self-mints a `local_conductor`-sourced bookkeeping row
   after the fact (`lib/task-authorization.py:273-300`, `accept_local`). This
   is the path the resident caller can never pass — there is no live pane.
2. **Pre-minted bearer receipt** (`spawn-task.sh:411-445`): when
   `--authorization-command-id <id>` is given, `spawn-task.sh` calls
   `read_task_authorization` (`lib/run-registry.sh:949-951`) and validates the
   row *in place of* live ancestry — `.status == "accepted"`, `.source ==
   "oauth_task_delegation"`, `.repo == $repo`, `.effective_scope.job_class ==
   $job` (`spawn-task.sh:417-421`), plus a credential-posture check
   (`spawn-task.sh:423-432`) and a once-only worktree-mutation claim
   (`spawn-task.sh:435`). This is the shape the review named: a receipt
   **minted earlier, by a separately-verified actor, presented later by an
   unrelated process**.

This proposal is path 2, with a **new, narrower `source` value** —
`resident_escalation_grant` — not a third storage mechanism. No new table.
The grant is minted by a real, live, conductor-eligible pane (so minting
itself goes through the *existing* `caller_pane_from_ancestry` +
`pane_is_conductor_eligible` gate, unmodified) and consumed later by the
watchdog chain, which never has to prove its own ancestry because it is
presenting a receipt instead — exactly how the OAuth remote path already
works for a publisher that is never a herdr pane either.

## 1. Exact action

- **Caller**: `_esc_check_launch_authority` (`lib/escalation.sh:544-556`),
  called from `esc_escalate` (`lib/escalation.sh:1056`), reached only through
  `stall-watchdog.sh`'s `_sw_escalation_tick` (`stall-watchdog.sh:268-287`),
  reached only from `hub.py`'s `_stall_watchdog_loop` thread (`hub.py:4712`,
  started at `hub.py:5824`). No other caller of `esc_escalate` exists in this
  repo today (`no-progress-escalate.sh`'s own `cmd_tick` is the offline test
  CLI, invoked by a human/test harness, which already has real ancestry when
  run from a pane and is unaffected).
- **spawn-task.sh invocation**: unchanged —
  `bash "$_esc_dir/../spawn-task.sh" --no-focus "$repo" "$branch" "$job"
  "$agent"` (`lib/escalation.sh:591`, inside `_esc_spawn_successor`), with one
  new argument added when a grant is admissible:
  `--authorization-command-id <grant_command_id>`.
- **Job classes**: exactly the four `esc_tier_job` values
  (`lib/escalation.sh:189-196`) — `explore` (fast), `implement` (standard),
  `plan` (deep), `deep-review` (frontier). No other job class is ever passed
  by this caller; the grant's `effective_scope.job_class` is validated
  against this closed set, not a wildcard.
- **Models**: unchanged — whatever `esc_tier_model`/`esc_tier_agent`
  (`lib/escalation.sh:206-213`, `esc_tier_model` immediately below it) already
  resolve for the granted tier (fast =
  haiku, standard = sonnet, deep = opus, frontier = codex's
  `$HERDR_CODEX_DEEP`). The grant authorizes a **tier ceiling**, not a model
  string, so it tracks config changes the same way escalation already does.

## 2. Scope

- **Repo**: the grant's `source_repo` column names exactly one repo
  (absolute, normalized path — the same shape `accept_local` already
  enforces, `lib/task-authorization.py:276-277`). One grant per repo; no
  wildcard, no "all repos" grant ever.
- **Task**: a grant does **not** name a task_id — it cannot, since the task
  that will eventually need it does not exist yet at mint time (no-progress
  loops are detected after the fact). Scope is instead enforced structurally:
  `esc_escalate` only ever runs after `no_progress_detect` has already
  returned `loop: true` for a *specific* task (`stall-watchdog.sh:280-282`),
  and `_esc_spawn_next_tier`'s own journal/pinning logic
  (`lib/escalation.sh:830-...`) already refuses a second spawn for a task
  that already has one in flight or bound. The grant only ever reaches
  `spawn-task.sh` from inside that already-gated call path — it is not a
  general-purpose spawn credential and must never be accepted outside
  `_esc_spawn_successor`'s own invocation.
- **Max tier**: the grant's `effective_scope` carries a `max_tier` field (one
  of `fast|standard|deep|frontier`). `_esc_check_launch_authority` refuses
  if `to_tier` (the tier `esc_escalate` is currently trying to reach) ranks
  above the grant's `max_tier` in the existing ladder order — the old writer
  stays active and the task is marked `blocked`, same shape as a missing
  grant. **Default proposal: `standard` only** (haiku→sonnet). Reaching
  `deep`/`frontier` unattended is a materially bigger blast radius (opus/
  codex spend, longer unattended runtime) and should require either a
  separate, explicitly wider grant or stay human-only until there is
  operating experience with `standard`.

## 3. Identity and binding — no spoofed ancestry, no env bypass

The resident caller's own process ancestry is never checked, inferred, or
trusted — it has none, and nothing here teaches `caller_pane_from_ancestry`
or `pane_is_conductor_eligible` to accept one. Both functions stay exactly as
they are, reused read-only by the **mint** step instead:

1. Terrence (or a conductor acting on his explicit instruction) runs a new,
   narrow, human-invoked command — e.g.
   `grant-resident-escalation.sh <repo> <max_tier> <ttl>` — **from a real
   herdr pane**. The command's first action is calling
   `caller_pane_from_ancestry` + `pane_is_conductor_eligible` against *itself,
   right now* (identical call shape to `_esc_check_launch_authority`'s
   existing fallback, `lib/escalation.sh:554-555`) — if that fails, nothing
   is minted. This is the **only** place in the whole proposal where live
   ancestry is proven, and it happens once, interactively, at mint time —
   never deferred to the unattended caller.
2. On success it calls a new `accept_resident(db, command_id, minting_pane,
   minting_pane_birth, repo, max_tier, expires_at)` adapter (same file,
   `lib/task-authorization.py`, modeled on `accept_local` at lines 273-300
   but with `source="resident_escalation_grant"` and its own narrower
   manifest validator — `job_class` closed to the four escalation values,
   `secrets` hard-coded to `"default"`, never `"grant"`) and writes one row
   to the existing `task_authorizations` table. No new table, no new
   storage adapter class.
3. At spawn time, `_esc_check_launch_authority` gains one new branch, tried
   **before** falling through to today's ancestry check: look up the most
   recent `status='accepted'` row with `source='resident_escalation_grant'`
   and `source_repo = <repo>` (a read, same transaction shape `read()`
   already provides, `lib/task-authorization.py:156-157`). If one exists,
   unexpired, and its `max_tier` admits `to_tier`, pass its `command_id`
   through to `_esc_spawn_successor` as `--authorization-command-id`.
   `spawn-task.sh`'s own validation at line 420 gains the matching new
   admissible `.source` branch with its own predicate (job_class, repo,
   max_tier — never widened to the OAuth predicate's shape).
4. No environment variable ever carries a grant, a repo name, or a bypass
   flag. `HERDR_ESC_AUTHORITY_CMD` (the existing test seam) stays test-only
   and is never read in production; the grant lookup is a database read, not
   an env check, so there is nothing to export into a shared process
   environment that a different, unauthorized caller could inherit.

## 4. Expiry — a hard time window

Every grant row carries `expires_at` (the existing INTEGER epoch-ms column).
`_esc_check_launch_authority`'s lookup filters on `expires_at > now()` the
same way `launch()` already enforces `deadline_at` for the OAuth path
(`lib/task-authorization.py:522-524`, "task deadline expired before
launch") — an expired grant is invisible to the lookup, not specially
handled; the pre-flight check falls straight through to today's ancestry
check (which still fails for this caller) and the task is marked `blocked`
exactly as it is today. The existing local/OAuth grants use a 15-minute TTL
(`TTL_MS`, `lib/task-authorization.py:21`) because they authorize one
spawn, now. A resident grant has to survive across many unattended ticks
over hours, so it needs a longer but still *hard-capped* window — proposed
**24 hours**, re-mint required after. No grant may ever request a longer
window; the mint command itself refuses a `ttl` argument above the cap
(enforced in the command, not trusted from the caller).

## 5. Revocation — one file, effective at the next tick

This repo already has exactly this pattern for an equally blunt instrument:
`~/.local/state/herdr/merge-delegation.revoked` instantly revokes routine-
merge delegation for every session the moment any session touches it (per
`AGENTS.md`'s "Stop merging" rule). Reuse the same shape rather than invent
a second one:

- `touch ~/.local/state/herdr/resident-escalation.revoked` — one file, one
  command, requires no code to run to take effect (`touch` itself is the
  entire revocation).
- `_esc_check_launch_authority`'s new branch checks for this sentinel
  **before** it ever queries the grant row — present means refuse
  unconditionally, regardless of any otherwise-valid, unexpired,
  correctly-scoped grant. Checked fresh on every call (no caching), so it is
  live on the very next tick, not the next process restart — `esc_escalate`
  runs inside a short-lived `bash` subprocess per tick already
  (`stall-watchdog.sh:285-286`), so there is no long-lived state to flush.
- **Proof it fired**: on seeing the sentinel, the pre-flight check marks the
  task `blocked` via the existing `_esc_mark_blocked_uncertain`
  (`lib/escalation.sh:1058-1059`'s own call shape) with its own distinct
  reason, e.g. `resident_grant_revoked`, carrying the same
  `journal_table`/`journal_key` discoverability fields every other blocked
  reason already carries. A negative test (§9) touches the sentinel, runs a
  tick against an otherwise-valid grant, and asserts exactly that reason —
  the same observable proof pattern as every `_esc_mark_blocked_uncertain`
  path already in the suite, not a new kind of evidence.
- Per-repo, finer-grained revocation does not need a new mechanism at all:
  update that repo's row to `status != 'accepted'` or let it expire — the
  lookup predicate (`status='accepted' AND expires_at > now()`) already
  excludes it.

## 6. Rollback

The new branch in `_esc_check_launch_authority` is strictly additive and
tried *before* a fallthrough, never a replacement: no grant, an expired
grant, a wrong-repo grant, a tier-exceeding grant, or the revocation sentinel
all fall through to exactly the ancestry check R8 already ships — which
still fails for the resident caller and produces exactly today's shipped
behavior (old writer untouched, task `blocked` with reason
`no_launch_authority`). Full rollback of the feature is therefore: `touch`
the revocation sentinel (instant, no deploy) and/or stop running the mint
command (no new grants are ever created automatically — nothing mints
itself). There is no code path that needs reverting under load; the R8
behavior this builds on is never removed, only extended.

## 7. Audit fields

- **Mint**: an `events` row via the existing `event()` helper
  (`lib/task-authorization.py:303-305`, the same mechanism `register()`
  already uses for `manifest_recorded`) — `minting_pane`, `minting_pane_birth`,
  `repo`, `max_tier`, `expires_at`, `command_id`. Written by the mint command
  itself, inside the same transaction as the `task_authorizations` insert, so
  a grant can never exist without its own audit event.
- **Consumption**: no new field needed — `register_task` already stores
  `authorization_command_id` on the task row
  (`lib/run-registry.sh:889`, surfaced in every task's JSON), so every
  successor spawned under a resident grant is already traceable to the exact
  grant that authorized it, by the existing mechanism, for free.
- **Revocation**: the bare `touch` has no actor field by itself — the mint
  command's companion revoke command (not just raw `touch` by hand) should
  also write one `events` row (or a line to a small revocation log) naming
  who revoked and when, so "it fired" and "who fired it" are both
  answerable without trusting file mtimes alone.
- **Expiry**: no action needed at expiry time — the row simply stops
  matching the lookup predicate. A periodic sweep (future, optional, not
  required for v1) could surface "a resident grant expired N days ago and
  was never re-minted" on the hub dashboard, the same way
  `xd://decisions_open` already surfaces other waiting state.

## 8. What stays human-only

- Minting a new grant (requires live, real pane ancestry at mint time — this
  cannot be automated without recreating exactly the gap this document
  exists to close).
- Revoking a grant.
- Re-minting after expiry.
- Choosing which repo(s) are eligible at all — this proposal activates for
  **zero repos** by default; enabling the first one is a deliberate,
  separate decision, not a side effect of landing the code.
- Raising `max_tier` above `standard`, or raising the TTL cap above 24h —
  both require a code change to the mint command's own hard caps, reviewed
  like any other security-relevant change, never a runtime argument.

## 9. Negative tests required before activation

All offline, same fake-command-seam style as `verify-no-progress-
escalation.sh` (`HERDR_ESC_AUTHORITY_CMD` override, no real `herdr`/
`spawn-task.sh` invocation), run as part of that suite:

1. No grant exists for the repo → today's exact refuse-and-block behavior,
   byte-for-byte unchanged (regression, not new — proves default-off).
2. A grant exists but `expires_at` is in the past → refused, `blocked`,
   discoverable reason; never silently treated as valid.
3. A grant exists for a *different* repo → refused (scope mismatch).
4. A grant exists but its `max_tier` is below the tier `esc_escalate` is
   currently trying to reach → refused (tier-cap enforcement), including the
   boundary case (`to_tier == max_tier` must pass; one above must refuse).
5. A grant is valid, unexpired, correctly scoped — but the authority check is
   invoked directly, bypassing `esc_escalate`'s own no-progress gate — must
   still refuse or be structurally unreachable, proving the grant is not a
   general-purpose spawn bypass usable outside escalation's own call path.
6. The revocation sentinel is present → refused even against an otherwise
   fully valid grant, and the sentinel is checked *before* the grant lookup
   (ordering test: a valid grant plus the sentinel must never spawn).
7. The sentinel is created mid-run (after a tick that already succeeded
   under a valid grant) and takes effect on the *next* tick without a
   process restart — directly proves "effective at the next tick," not
   "effective after redeploy."
8. A grant that does authorize a spawn is consumed through the existing
   once-only `claim_task_worktree_mutation` claim (`spawn-task.sh:435`) —
   verify a grant cannot authorize two concurrent spawns (reuses the
   existing once-only semantics; this proposal adds no new consumption
   logic to re-prove, only a new way to reach the existing gate).
9. The full existing `verify-no-progress-escalation.sh` suite (120
   assertions as of R9) stays green with the new lookup branch present but
   no grant ever minted in any fixture — the new code path must be
   provably inert until a human has explicitly run the mint command.
10. A mutation probe (same isolated `git archive` + rewritten-test pattern
    as every round of this feature) proving the new branch is load-bearing:
    reverting it to "always fall through to ancestry" must make the
    valid-grant positive-path test fail.

A positive "grant actually authorizes a successful spawn end-to-end"
fixture test is also required once the mint/consume code exists, but it is
not a *negative* test and does not gate activation by itself — items 1-10
above do.

## Review boundary

This document, the mint command, the new `accept_resident` adapter, the new
`_esc_check_launch_authority` branch, and `spawn-task.sh`'s new admissible
`.source` branch are a security-relevant change to who may launch an agent
unattended in production and must go through `security-reviewer` with zero
unresolved high/critical findings before any code lands, exactly like the
`authorization_command_id` + `read_task_authorization` mechanism it reuses
did. Landing the code is still not activation: no grant exists until the
mint command is run, and **the first grant for the first repo requires
Terrence first-hand** — not a conductor acting on a prior general approval,
not inferred from this document existing, not inferred from the code having
merged. This document does not request that approval; it exists so that when
it is requested, the exact shape being approved is already written down.
