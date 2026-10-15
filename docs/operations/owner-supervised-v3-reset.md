# Owner-supervised same-pane v3 reset

Status: operational option for explicit owner approval. This is not an authority
change and does not deploy code. It uses the installed recovery helper, OMP's
normal exit, the existing Main role row, and the reviewed v3 launcher.

## Why this path

OMP 18.10.4 exposes `app.exit` on Ctrl+D. Normal disposal saves session state and
emits a `custom/session_exit` record with `kind=normal`, `reason=dispose`. The
installed helper verifies exact PID/process birth, pane terminal birth, session,
cwd, process image, current `agent_status`, visible prompt/activity exclusions,
transcript prefix, post-exit shell, and the exit record before allowing resume.
OMP 18.10.4's footer does not prove that its editor draft is empty. Empty-draft
evidence comes only from the owner's immediate visual confirmation.

OMP `/restart` has historical same-session evidence, but it does not prove that
the replacement process came through the fixed v3 launcher. Do not use `/restart`
for this runtime migration.

## Readable targets and order

1. `w7T:p2` — Issue-277 worker
2. `w7S:p2` — FUB / ForwardFlow research
3. `w72:p1` — Main conductor, blocked pending role-protocol reconciliation

## One bundled owner decision

The owner must explicitly authorize this exact three-row sequence and personally
confirm, immediately before each row, that the visible composer is empty and the
session is not streaming, editing, or at a tool/approval prompt. If any draft is
visible or the state is ambiguous, stop that row without clearing, submitting,
copying, exiting, or touching later rows.

This operational procedure currently covers rows 1 and 2 only. Earlier reviews
conflict on whether Main must hand its role to a temporary conductor or may keep
the pane-and-terminal-bound role through a same-pane shell gap. Do not execute
row 3 until that conflict is reconciled against enforcement code and installed
protocol. This document grants neither an authority bypass nor a Main restart.

## Procedure per row

1. Freshly read pane list, process-info and agent state. Bind exact pane, terminal
   birth, session path, cwd, PID/process birth, full process image and ancestry.
2. Create a new private evidence directory. Run `session-in-place.py capture`,
   bundle checksum verification and disposable `restore-check`.
3. Generate the helper's exact SHA-bound resume command for:
   `/Users/thurbs/.local/opt/omp-herdr-bound/releases/2026-10-14-issue277-v3/omp`
   with its reviewed launcher SHA and the exact captured session.
4. Re-read identity and idle state. The owner visually confirms the empty composer.
   From that trusted owner transcript, create a private structured confirmation
   containing the exact `before.json` SHA-256, pane, terminal birth, PID/process
   birth, confirmation epoch, and transcript-evidence SHA-256. Pass both private
   paths as `graceful-exit --owner-confirmation ... --owner-evidence ...`; the
   helper hashes the evidence file itself. The confirmation expires after five
   minutes, the capture after ten, and any mismatch refuses before the no-retry
   marker or key.
5. From the owner's trusted shell, invoke the installed helper's one-shot
   `graceful-exit` for the captured PID/pane/terminal. It creates its durable
   no-retry marker before sending one Ctrl+D. Never retry or remove the marker.
6. Require `graceful-exit.json`: old PID/birth absent, same pane/terminal/cwd,
   shell prompt, transcript prefix intact, and fresh normal/dispose exit record.
7. Run exactly the generated command once with supported `herdr pane run`. Never
   type or reconstruct it manually and never launch without `--resume`.
8. Run `verify-after`, generate fresh host-visible HEALTHY evidence and `accept`.
   Require same worktree/session, v3 mapped payload/runtime/native, all 11
   extensions, unchanged durable artifacts, and no unexpected duplicate turn.
9. Only after acceptance continue to the next row.

## Main procedure unresolved

Reconciliation verdict: the installed migration protocol mandates a live
non-worker conductor handoff. The security code itself binds Main to pane plus
terminal birth rather than OMP PID, so same-pane replacement would not revoke
the role, but Main is operationally unreachable while the pane is a shell. Active
registered workers are ineligible handoff targets. Preserve Main and stop after
row 2 unless either (a) an eligible live non-worker conductor exists and the
installed handoff completes, or (b) the owner explicitly approves a separately
reviewed procedural exception naming the trusted external owner shell as recovery
controller during the gap. Neither gate is satisfied by this document.

## Exact risks and stop rules

- Draft loss: `draft.txt` absence and the OMP footer are not evidence of an empty
  composer. Only the owner's immediate visual confirmation, bound to the fresh
  capture and identities by the structured confirmation, establishes emptiness.
  The helper independently requires current `agent_status=idle` and no visible
  prompt/activity. Any stale, nonempty, changed or ambiguous state stops.
- In-flight duplication: an active tool call or queued submission can be abandoned
  or replayed after resume. Require no streaming, tool prompt, pending owner
  delivery or background mutation. Never launch the resume command twice.
- Key race: Herdr's public key API lacks expected-PID CAS. The helper narrows the
  read/key interval but cannot eliminate it. Identity ambiguity stops with no
  retry.
- Command substitution: a wrong launcher/session can fork history or lose
  guardrails. Use only the helper-emitted command and verify its launcher hash.
- Main authority: conflicting reviews make the procedure unapproved. No helper,
  key, handoff, redesignation or resume action is allowed for row 3 under this
  document.
- Failure after exit: do not improvise. Keep the pane at its shell, preserve the
  bundle and marker, and use the verified recovery bundle under a new reviewed
  recovery decision.

## Minimum owner actions

1. Existing approval of the named serial procedure; this document currently
   implements only rows 1 and 2.
2. Two immediate visual confirmations: “composer empty and idle” for the named
   tab, one at a time.
3. Execute/observe the installed helper and exact generated resume command from a
   trusted owner shell. No direct pane text beyond the helper's one Ctrl+D and
   `herdr pane run` exact command. Main is excluded pending reconciliation.
