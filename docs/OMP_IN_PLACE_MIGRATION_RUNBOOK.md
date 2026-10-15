# OMP in-place migration runbook

Scope: serially restart the three named OMP sessions in their existing worktrees. This is not a disaster-recovery archive, worktree replacement, cleanup, or cross-host move. Never use `restart.sh --panes` for this procedure.

## Reviewed release identity

- Safeguard code commit: `ebb9eda40fd9679c4a62f80c5ec803e75ea27e64`.
- Reviewed four-file aggregate: `728c327b5a1135902c4a58de01ee42bf4c5363de2dfb6b22864404498f8a3dfd`.
- OMP 18.10.4 binary SHA-256: `7459333760ef0e265d5d40445ea459da3d18a10ef3ec4958302e1977b52c8a2b`.
- PR 280 merge: `84c78b8a16d0e629c4b8e4d393ebecdaf5f440d0`.
- Patched OMP candidate SHA-256: `0cd576cdf40af8c7a0b8f1b2d6e878fa089caa38d992ac6428ebdba9df51c1df`.

## Sessions and recovery modes

| Order | Pane | Terminal | Historical bundle PID | Session | Recovery mode | Existing verified bundle |
|---|---|---|---:|---|---|---|
| 1 | `w7T:p2` | `term_65dbcb632abf6d1` | 413 | `01a13674-4ac7-702c-8445-793f75fd2e62` | exact 18.10.4 | `pid-413-exact-v2` |
| 2 | `w7S:p2` | `term_65dbbe3123286cf` | 4004 | `01a1363e-3da7-70ef-a7d4-bc8a77a345ac` | explicit 18.10.3 → 18.10.4 | `pid-4004-version-change-v2` |
| 3 | `w72:p1` | `term_65d348046218f2` | 25513 | `01a11648-26bf-72fc-b01b-d4eb970d9c37` | explicit 18.9.2 → 18.10.4 | `pid-25513-version-change-v2` |

The PID column identifies the historical bundle, not a live process. In
particular, bundle PID 413 was previously replaced (PID 79243 was observed
afterward), and no recorded PID may be assumed current. Immediately before
each capture, discover the live foreground PID with `herdr pane process-info`
and require the helper to bind it to the pane, terminal, cwd, and session.

The old 18.10.3 and 18.9.2 filesystem paths no longer exist. They are not valid rollback targets. Their rollback is the retained, verified 18.10.4 compatibility bundle plus the unchanged original worktree and transcript.

## In-place integrity evidence

Use `session-in-place.py` for the evidence steps. It deliberately never stops a
process or writes to a pane: `capture` records the private baseline,
`resume-command` prints a launcher-SHA-bound command for the verified external
conductor, `verify-after` binds the replacement PID and unchanged in-place
state, and `accept` writes a new `ACCEPTED.<pid>.json`. The historical bundle's
`LIVE_ACCEPTED_AT` is never replaced. Run `--help` on each subcommand for the
required explicit paths and identities.

### Main self-migration handoff

Main must never stop or replace itself. Before migrating the pane holding the
`main` role, Main uses the existing `designate-main.sh --handoff-to <pane>` path
to transfer the role to a live, non-worker temporary conductor. That conductor
records the current role/birth and performs the same sequence used for every
pane: capture the baseline; obtain the helper's exact SHA-bound resume command;
run `session-in-place.py graceful-exit` with the captured PID, pane and terminal.
That operation immediately rebinds the pane terminal birth/session/cwd and idle
PID foreground ancestry and complete captured process image (argv/resume arguments
and mapped runtime/native module), records transcript size/hash/mtime, and sends exactly
one logical `ctrl+d` through `herdr agent send-keys <pane> ctrl+d`. OMP 18.10.4 binds Ctrl+D to its
graceful shutdown path (draft save, session disposal and shutdown hooks); Ctrl+C
is clear/interrupt and is not an exit mechanism. The helper waits boundedly for
the exact PID/birth to disappear, then requires the same pane birth/cwd, no
OMP/agent foreground process, an observed shell prompt, an intact transcript
prefix, durable post-exit transcript metadata, and a fresh `session_exit` record
whose `kind=normal` and `reason=dispose`. It scans only the newly
appended transcript bytes and visible post-exit pane region for in-memory
credential values or the literal key token, reporting only pass/fail. Only after
`graceful-exit.json` exists may the conductor start the exact command with
`herdr pane run`; then run verify-after → a newly generated host-visible health
The idle check combines `herdr agent get` state, read-only `pane process-info`,
and the detection view's exact empty OMP composer; streaming, prompting, editor
text, or an unrecognized view fails closed. It does not rely on an undocumented
`process_info.pane_id` field.
check → accept. Direct `kill`, shell text injection, and an unverified fallback
command are not supported migration paths. The conductor confirms the
replacement pane is live and accepted. Only then does it hand the role
back with `designate-main.sh --handoff-to <original-main-pane>` and verify
`designate-main.sh --show` reports the replacement pane's current terminal
birth. A failure before acceptance leaves control with the temporary conductor;
it restores the verified recovery bundle or stops without touching other
sessions. A failure after acceptance but before return leaves the replacement
session running and control with the temporary conductor for explicit recovery.

Herdr's public key API has no expected-PID compare-and-swap. A residual race
therefore remains between the final read-only PID/ancestry check and delivery of
`ctrl+d`. The helper narrows but cannot eliminate that interval. Any changed or
lost pane, PID/birth ambiguity, missing shell, missing normal/dispose exit record,
or timeout fails closed; never retry the key and never proceed to `pane run`.
Before the key, the helper atomically creates a durable `graceful-exit.attempt`
marker. It intentionally remains after success or failure so concurrent or
retried invocations cannot deliver a second key; removal requires a separately
reviewed recovery decision.

Before touching a PID, create a private mode-0700 evidence directory outside the repository. Record only:

1. PID birth, argv SHA-256 plus sanitized allowlisted resume arguments, cwd,
   pane, terminal, and session transcript SHA-256. Never store raw argv.
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
4. Optionally confirm host-visible Herdr health as a preflight check. This is
   not acceptance evidence and cannot be reused after replacement.
5. Stop only the freshly discovered and helper-bound OMP PID with the helper's
   single guarded `CTRL_D` operation. On any mismatch or timeout, do not send a
   second key, text, signal, kill, resume command, or any other pane action.
6. Resume the archived transcript in the same cwd, same pane/terminal mapping, with the specified exact/fallback 18.10.4 runtime, archived hook/config/overlay/authority inputs, and existing credential provider.
7. Run `verify-after`, then generate a new host-visible `HEALTHY` record bound
   to the bundle, verifier, and deployed revision. It must postdate
   `after.json`; preflight health cannot satisfy acceptance.
8. Recompute worktree and ignored-state aggregates. Existing ignored files must remain in place; only documented normal runtime updates may differ.
9. Record fresh bundle-bound acceptance. Retain every recovery bundle until all three sessions pass.

If any row fails, stop. Preserve the failed session's worktree and evidence, resume from its retained 18.10.4 bundle if possible, and leave the other original PIDs untouched.

## Control-plane release and rollback

The safeguard release and PR 280 routing recovery are separate from session recovery. Deploy only the exact approved commit/package. Verify launchd, HTTP surfaces, served/deployed/plugin revision agreement, and subscription health from a host-visible context.

If the control-plane smoke check confirms an outage, roll the deployed Herdr app/plugin back to `85ff0af0ecc8ac7fd88813f6e231321c5ba4e2d9`. An `UNOBSERVABLE` result is not an outage and must not trigger rollback.

