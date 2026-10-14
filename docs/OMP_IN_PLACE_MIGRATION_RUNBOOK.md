# OMP in-place migration runbook

Scope: serially restart the three named OMP sessions in their existing worktrees. This is not a disaster-recovery archive, worktree replacement, cleanup, or cross-host move. Never use `restart.sh --panes` for this procedure.

## Reviewed release identity

- Safeguard code commit: `ebb9eda40fd9679c4a62f80c5ec803e75ea27e64`.
- Reviewed four-file aggregate: `728c327b5a1135902c4a58de01ee42bf4c5363de2dfb6b22864404498f8a3dfd`.
- OMP 18.10.4 binary SHA-256: `7459333760ef0e265d5d40445ea459da3d18a10ef3ec4958302e1977b52c8a2b`.
- PR 280 merge: `84c78b8a16d0e629c4b8e4d393ebecdaf5f440d0`.
- Patched OMP candidate SHA-256: `0cd576cdf40af8c7a0b8f1b2d6e878fa089caa38d992ac6428ebdba9df51c1df`.

## Sessions and recovery modes

| Order | Pane | Terminal | Current PID | Session | Recovery mode | Existing verified bundle |
|---|---|---|---:|---|---|---|
| 1 | `w7T:p2` | `term_65dbcb632abf6d1` | 413 | `01a13674-4ac7-702c-8445-793f75fd2e62` | exact 18.10.4 | `pid-413-exact-v2` |
| 2 | `w7S:p2` | `term_65dbbe3123286cf` | 4004 | `01a1363e-3da7-70ef-a7d4-bc8a77a345ac` | explicit 18.10.3 → 18.10.4 | `pid-4004-version-change-v2` |
| 3 | `w72:p1` | `term_65d348046218f2` | 25513 | `01a11648-26bf-72fc-b01b-d4eb970d9c37` | explicit 18.9.2 → 18.10.4 | `pid-25513-version-change-v2` |

The old 18.10.3 and 18.9.2 filesystem paths no longer exist. They are not valid rollback targets. Their rollback is the retained, verified 18.10.4 compatibility bundle plus the unchanged original worktree and transcript.

## In-place integrity evidence

Before touching a PID, create a private mode-0700 evidence directory outside the repository. Record only:

1. PID birth, argv, cwd, pane, terminal, and session transcript SHA-256.
2. Worktree HEAD, porcelain-v2 status, submodule state, tracked diff digest, untracked-file aggregate digest, and ignored-state aggregate digest.
3. For ignored state, hash relative paths, regular-file contents, and symlink targets into a single aggregate. Do not copy ignored files and do not print their names or contents.
4. Hook, config, overlay, authority-library tree, OMP binary, and native-module SHA-256 values.
5. Names—not values—of required `HERDR_*`, `PI_*`, `OMP_*`, and credential-provider variables.

Credential values remain supplied by the existing authorized provider or inherited approved environment. Never write them to evidence or recovery bundles.

Immediately before restart, run bundle checksum verification and disposable restore validation. A mismatch, PID identity change, transcript change, worktree mutation, missing environment name, or failed host-visible health check stops the procedure.

## Serial restart procedure

For each row, in order:

1. Confirm the prior row is either untouched or fully accepted.
2. Capture the in-place integrity evidence above.
3. Verify the matching retained bundle with `session-recovery.sh verify` and `restore-check`.
4. Confirm host-visible Herdr health is `HEALTH HEALTHY` and save fresh evidence bound to that bundle, verifier, and deployed revision.
5. Stop only the named OMP PID. Do not close other panes or restart Herdr services.
6. Resume the archived transcript in the same cwd, same pane/terminal mapping, with the specified exact/fallback 18.10.4 runtime, archived hook/config/overlay/authority inputs, and existing credential provider.
7. Confirm transcript/session identity, cwd, hook/config/authority hashes, pane registration, and host-visible Herdr health.
8. Recompute worktree and ignored-state aggregates. Existing ignored files must remain in place; only documented normal runtime updates may differ.
9. Record fresh bundle-bound acceptance. Retain every recovery bundle until all three sessions pass.

If any row fails, stop. Preserve the failed session's worktree and evidence, resume from its retained 18.10.4 bundle if possible, and leave the other original PIDs untouched.

## Control-plane release and rollback

The safeguard release and PR 280 routing recovery are separate from session recovery. Deploy only the exact approved commit/package. Verify launchd, HTTP surfaces, served/deployed/plugin revision agreement, and subscription health from a host-visible context.

If the control-plane smoke check confirms an outage, roll the deployed Herdr app/plugin back to `85ff0af0ecc8ac7fd88813f6e231321c5ba4e2d9`. An `UNOBSERVABLE` result is not an outage and must not trigger rollback.

