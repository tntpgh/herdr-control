# Weekly factory key

Status: implemented by `grant-conductor-week-v2.sh`, pending merge and deployment.

The weekly factory key lets the live Main conductor recover registered owner
lanes and hand existing work to Main without asking Terrence for the same
routine authority every day. It is authorization, not liveness: owner leases
remain short and must still be renewed or recovered through their normal
state machine.

## Exact scope

Every grant contains this fixed, reviewed label set:

- `conductor`
- `thurber-os`
- `tntpgh-dev`
- `tourguide`
- `knowledge-base`
- `herdr-control`

The set is part of the human-approved digest. It cannot be widened through an
environment variable, command-line option, or update to an accepted row. A
new lane requires a code change, review, and a fresh human-approved grant.

The key does **not** authorize deny-class tool decisions, secret access,
destructive actions, external writes, pushes or merges, deployments, or
governance signatures. Those retain their existing gates.

## (a) Duration

`CONDUCTOR_WEEK_TTL_MS` is exactly seven days (`168h`) from the previewed
`issued_at`. There is no caller-selected TTL and no automatic renewal. The
preview displays the absolute start/end, weekend-spanning flag, exact labels,
and handover cap before Terrence answers.

## (b) Identity across sessions

A weekly grant never identifies Main by a stale pane snapshot. Each unattended
tick reads the current `roles.main` row and verifies the pane plus birth
fingerprint is live. Missing, recycled, or indeterminate Main identity fails
closed. The actor label is always `conductor`.

## (c) Existing-worker handover

A transfer whose recipient is live Main requires an active, unrevoked weekly
grant and consumes one of `CONDUCTOR_HANDOVER_CAP = 10` audit rows. The grant
is rechecked for every task, so expiry or revocation during a batch stops the
next transfer. Transfers between non-Main conductors keep their existing
rules.

## (f) Owner-lane recovery

`conductor-week-daily-tick.sh`:

1. admits the exact `--recover-label` against the weekly grant;
2. re-verifies live Main;
3. mints a fresh five-minute, single-use redemption token bound to that label;
4. clamps the token to the grant's own `expires_at`;
5. calls `owner-lease-recover.py --conductor-grant`.

The authorization layer re-reads and integrity-checks the exact parent grant
before minting. It refuses an inactive parent, an unlisted label, or a clamp
that differs from the parent expiry. `owner-lease-recover.py` independently
clamps the recovered lifecycle to `min(now + 24h, grant.expires_at)` and keeps
all project, owner, caller-identity, disabled-state, and compare-and-swap
checks.

Expiry or revocation pauses the lane. There is no fallback that silently
creates broader authority.

## (g) Required proofs

`verify-weekly-conductor-authorization.sh` covers grant mint/expiry/revocation,
fixed scope, receipt integrity, single-use redemption, cap enforcement,
preview/answer/issue binding, replay refusal, and the operator
status/revoke/renew path.

`verify-weekly-conductor-authorization-m2.sh` covers the real daily tick,
live-Main failure, actor and target scope, recovery clamp, handover cap and
mid-batch expiry/revocation, plus cleanup proof/hold behavior.

Auth changes require two independent adversarial reviews and a real isolated
end-to-end smoke before merge.

## (h) Turning the key

From a shell outside Herdr:

```bash
./grant-conductor-week-v2.sh renew --reason "Run the factory this week"
```

`renew` builds the deterministic approval page, serves it through the canonical
`formserve.py`, verifies the hub-rendered page, opens the local decisions
inbox, waits for the answer, issues only the exact answered digest, and clears
an older revocation sentinel only after successful issue.

Other operations:

```bash
./grant-conductor-week-v2.sh status
./grant-conductor-week-v2.sh revoke
./grant-conductor-week-v2.sh issue --confirm-form <form-id>
```

`issue` is replay-safe: the same answered form cannot mint twice. The last
command resumes a valid answer if the serving shell exited after submission.

## (i) Checkpoint and close

Pane cleanup remains evidence-driven. `completed` requires
`shipped|abandoned|superseded` plus its existing proof. `no-follow-on` closes
as `closed_unverified`, never as completed. Unconsumed approvals, unresolved
prompts, working processes, dirty or unpushed work, and unreadable evidence all
hold the pane. The weekly key never weakens these checks.
