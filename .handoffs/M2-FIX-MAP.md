# M2-FIX-MAP

T's 22:07Z run (`verify-weekly-conductor-authorization-m2.sh`
run-20261030T220728Z-8bdJF7): 7 passed, 5 failed (A, B2, C, C2, FATAL).
Static checks only (`bash -n`, `python3 -m py_compile`) — no suite run,
T runs it. Hard rule honored: TTL/cap/expiry/proof requirements are
UNCHANGED; only fixtures changed, except (A) which is a genuine
production defect.

## A — PRODUCTION DEFECT
**File**: `owner-lease-recover.py`
**Where**: lines 107-130 (pre-edit numbering) — a second, accidental
copy of the file's own header (`from __future__ import annotations`
through `forms_dir()`), pasted in on top of the real one at 54-85.
Missing `import subprocess`/`registry_db()`/`_task_authorization()`
compared to the real copy — looks like an old pre-conductor-grant-feature
header re-pasted by mistake, not new session work.
**Change**: `CUT` the duplicate block (107-130) entirely. No other line
touched. `python3 -m py_compile owner-lease-recover.py` → clean.
Explains the companion "owner_projects row unchanged" failure too — the
script could not parse at all, so nothing ran.

## B2 — OUTDATED FIXTURE (r2 p35-adopted after r1 REJECT; r3 strengthened)
**File**: `verify-weekly-conductor-authorization-m2.sh`, case B2
**Root cause**: `read_conductor_week` (`task-authorization.py:581-583`)
returns the most recent row among UNEXPIRED grants only — case B's own
grant (120h, fresh) is still valid when B2 runs, cap-exhaustion being a
separate per-task check `read_conductor_week` doesn't filter on — so
B2's own expired grant was never a candidate; B's still-valid one got
found and refused at the cap check instead.
**r1 (REJECTED, criterion a)**: bracketed B2 with the global revoke
sentinel — made revoked+cap-exhausted+expired simultaneously true, so
the refusal could not be attributed to expiry alone.
**r2 (adopted, p35-proposed)**: dropped the sentinel bracket; directly
neutralizes case B's own leftover row via fixture SQL (`_sql` helper) —
`UPDATE task_authorizations SET expires_at=<now_ms-1> WHERE
command_id=<cB_grant> AND source='conductor_weekly_authorization'`
(table/columns confirmed against `task-authorization.py:572-578,588-591`)
— before the handover attempt. No production code or sentinel touched;
only expired rows are DB-present when B2 runs, so `expires_at>?` is the
sole gate. Assertion text unchanged.
**r3 (this round, additive)**: captures `cB2_grant` (previously
discarded) and asserts, pre-attempt: (1) the sentinel file is absent —
refusal can't be revocation; (2)
`conductor_week_handover_count("$cB2_grant") < $CONDUCTOR_HANDOVER_CAP`
— refusal can't be the cap. Only expiry is left, proven by direct
runtime assertion, not just fixture construction.

## P1-P4 — NEW CASES (this round, additive; close p35's named gap)
**File**: same, inserted between case C2 and case D
**Gap named**: p35's r1 verdict (b) — `_valid_proof_ref`
(`lib/run-registry.sh:1426`, called `:1663,1690`) had ZERO test call
sites in either suite; pre-fix C/C2's own `--proof="x"` never exercised
a valid proof either — predates this session's fixes.
- **P1**: `shipped`, no `--proof` → refused, task stays `running`.
- **P2**: `shipped --proof="x"` → refused at the same format gate, task
  stays `running`.
- **P3**: `shipped --proof=".handoffs/PROOF.md#ok"` against a real
  minimal git worktree (`git init -b main` + one commit — attached, not
  detached, so the review-PR hygiene path never engages) with a
  genuinely non-empty `PROOF.md` → accepted, reaches `completed`. Same
  fixture shape as `verify-close-done-workers.sh`'s own working
  "PROOF.md actually holds something" case — no network, no `gh`.
- **P4**: `no-follow-on`, no proof, its own case → accepted, reaches
  `closed_unverified` (never `completed`).

## C, C2 — OUTDATED FIXTURE
**File**: `verify-weekly-conductor-authorization-m2.sh`, cases C/C2
(~lines 219/256 old numbering)
**Root cause**: `--proof="x"` under `--reason=shipped` was refused by
`_valid_proof_ref` (`lib/run-registry.sh:1426`) — "x" matches neither
`<merged PR URL> <merge sha>` nor a `*PROOF.md*` reference — BEFORE the
per-row loop (and checks 5/6, the actual thing C/C2 test) was ever
reached. A real GitHub PR URL would need a live `gh` network lookup
(`_gh_pr_lookup`, line 1485) this sandboxed suite cannot make.
**Change**: switch both cases to `--reason=no-follow-on` (drop
`--proof` entirely). `close-done-workers.sh`'s proof gate (line 137) is
scoped to exactly `shipped|abandoned|superseded` — `no-follow-on` needs
none — while checks 5/6 run "on EVERY candidate row... same as every
other check here" (`close-done-workers.sh:815-819`) regardless of
reason. Proves the identical HOLD behavior both cases always intended.
Assertions (`approval_unconsumed`, `could not be read`) unchanged.

## FATAL (case D) — OUTDATED FIXTURE
**File**: `verify-weekly-conductor-authorization-m2.sh`, case D
(~line 273 old numbering)
**Root cause**: `accept_conductor_weekly_authorization` refuses any
window where `expires - issued != CONDUCTOR_WEEK_TTL_MS`
(`task-authorization.py:540-542`) — a real grant can never have an
arbitrary window. The old fixture built `cD_issued = now_ms` paired
with `cD_near_clamp_ms = (real_now + 3600) * 1000` — a ~1h window,
refused outright by `mint_week`.
**Change**: backdate `cD_issued = now_ms - TTL_MS + 3600000` (same
pattern case G already uses below it), so
`cD_near_clamp_ms = cD_issued + TTL_MS` still lands ~1h from now while
the window itself stays exactly `TTL_MS`. `cD_real_now` (still read
later for the case's own 24h sanity bound) preserved, just reordered.
Assertion (`^apply:recovered:conductor:`, then the clamp-vs-24h compare)
unchanged.

## Final coverage map
| Case | Reason | Proof | Outcome | Target state |
|---|---|---|---|---|
| B2 | (handover, not closure) | n/a | grant expiry alone refused, isolated from cap+sentinel by explicit assert | n/a |
| P1 | shipped | none | refused at format gate | running (unchanged) |
| P2 | shipped | `"x"` (invalid shape) | refused at format gate | running (unchanged) |
| P3 | shipped | valid, offline PROOF.md | accepted | completed |
| P4 | no-follow-on | none (none required) | accepted | closed_unverified |
| C | no-follow-on | none | accepted, then HELD by check 5 (unconsumed approval) | running (held) |
| C2 | no-follow-on | none | accepted, then HELD by check 6 (fail-closed unreadable) | running (held) |
`_valid_proof_ref`'s two real call sites (`lib/run-registry.sh:1663,1690`)
are now exercised by P1 (empty), P2 (invalid shape, no-PR no-PROOF.md),
P3 (valid PROOF.md shape, no network); the `<PR URL> <sha>` branch
(`_gh_pr_lookup`) remains untested here, same as everywhere else in
both suites — it needs a live `gh`/network call neither suite can make
sandboxed, named as a standing limitation, not silently dropped.

## Static checks run (no suite executed)
```
bash -n verify-weekly-conductor-authorization-m2.sh   # M2_SYNTAX_OK
bash -n verify-weekly-conductor-authorization.sh      # M1_SYNTAX_OK (unmodified, re-checked)
python3 -m py_compile owner-lease-recover.py          # PY_COMPILE_OK
bash -n designate-main.sh                             # DESIGNATE_SYNTAX_OK (unmodified, re-checked)
bash -n close-done-workers.sh                         # CDW_SYNTAX_OK (unmodified, re-checked)
```

## File hashes (sha256) and time of this fix
`owner-lease-recover.py` unchanged since r1 (A's fix only; not
touched since) — hash/time as computed 2026-10-30T22:15:58Z.
`verify-weekly-conductor-authorization-m2.sh` updated again this round
(B2 r3 strengthening + new cases P1-P4) — new hash computed by the
conductor 2026-10-30T22:38Z, confirmed against this agent's own
independently-computed value before the conductor's was received.
```
f18cf31507e2f84ee0aeb18de11fdd43450cf1fb437a342786867f8176b8ec4d
  owner-lease-recover.py (2026-10-30T22:15:58Z, unchanged)
43e12712ae8db8ea3281e269b298f825f1cee2256042f411e08bce58a20e699e
  verify-weekly-conductor-authorization-m2.sh (2026-10-30T22:38:00Z, B2 r3 + P1-P4)
```

## Exact isolated test command for T (unchanged)
```
cd /Users/thurbs/.herdr/worktrees/herdr-control/feat/lease-lifecycle-recover && bash verify-weekly-conductor-authorization.sh && bash verify-weekly-conductor-authorization-m2.sh
```
