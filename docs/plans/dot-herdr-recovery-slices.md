# Dot-to-Herdr recovery: bounded next slices

Date: 2026-10-10 UTC. This is a scope proposal, not activation permission.

The parent reports external independent approval of inactive M1 at `2f7c6fd359afe1227225235761fff4e98beec367`, including independent reruns of the 423-check gate, 185 enforcement checks, 35 Worker cases, TypeScript, secret scan and a negative control. That reviewer also identified an inherited identity classification defect. Its requested repair is local code `8947af45e089adda533ef1ae034fbb4112954377`, followed by `15e0bc17954d688acaa3b66a1656c7549380e2c6` for an independently identified malformed-ID edge. Subsequent reviews rejected raw-byte normalization (`15e0bc1`) and permissive numeric/UTF-8 parsing (`0be4844`). Current candidate `4e41e83b66ee9309c3dae56ed7f17707ecb6dd91` uses strict decoding and exact integer PID validation before shell capture, isolated imports and checked process-map lookup failures. Fresh independent exact-code security and test reviews are CLEAR, zero unresolved HIGH/CRITICAL and no remaining finding; parent external review is pending.

The latest priority is **identity repair, the observed menu/watchdog blocker, minimal durable receipt-to-ack recovery, then a permitted isolated canary**. Full M2 action lifecycle hardening and global nonremote admission are conditional follow-ons, not automatic prerequisites for the existing trusted-host isolated workflow. No new remote approval endpoint, scope or credential is needed. Nothing here repairs missing historical authorization for the live jobs.

## 1. Identity repair: implemented, awaiting exact-code review

`caller_pane_from_ancestry` built its map with a nested `jq` command whose failure was lost. Invalid JSON, `{}` and missing foreground process data could yield `rc=2`, meaning a proven outside-Herdr caller. `designate-main.sh --force` reserves eligibility for precisely that result. Unavailable identity must be `rc=1`, even if another row/pane already matched.

The shared function now validates raw transport bytes as one complete pane inventory and one complete process response per pane before Bash captures any output. The standard-library parser strictly decodes UTF-8 and one JSON document, rejects duplicate keys/nonstandard numeric constants, and preserves exact numeric types; scoped `pipefail` preserves producer errors after otherwise valid output. Pane IDs must be nonempty ASCII protocol identifiers with absolute anchors, excluding control and glob characters; foreground rows require integer-token PIDs in the signed 32-bit process-identifier range. Decimal/exponent encodings, booleans and numeric rounding cannot establish identity. Missing/wrong-type fields, parser failure and failed reads propagate as unknown. A complete, valid no-match still returns 2; a matching complete inventory returns 0. The script consuming that distinction is unchanged.

The final exact-candidate CI passed 497 checks (exit 0); the current isolated identity suite has 77 checks: malformed/missing response and required fields, invalid PID types, partial valid-plus-invalid rows, another pane unavailable, malformed pane lists, unavailable/truncated ancestry, valid matching and outside cases, and the actual force-refusal boundary with fixture transports. No force succeeds and no live designation is made. The first 36-case corpus produced 12 passes / 24 failures against `2f7c6fd`. Fresh review then found trailing newline/NUL normalization and glob expansion; six new matching/no-match tests all fail against `8947af4` and pass after the encoding fix. The subsequent raw-byte review blocked `15e0bc1`: shell capture could strip NUL before JSON validation. Fourteen additional checks cover raw transport bytes, producer errors and actual force-consumer refusal; the complete 56-case suite on `15e0bc1` produced 47 passes / 9 failures and on `0be4844` passed all 56. Fresh reviewers then blocked that candidate: jq can normalize invalid UTF-8, accept invalid numeric syntax and round nonintegral PIDs. Fifteen additional checks cover those cases, PID range/type and duplicate keys. The 71-case suite produced 58 passes / 13 failures on `0be4844`, and 71 passes / 0 failures on `1836510`. A further security review blocked `1836510` with two HIGH findings: unisolated Python imports could load a worker-directory module, and a failed `awk` lookup could become an outside result. `d7090fc` isolates Python with `-I -S` and checks lookup failure; five new cases fail on the previous candidate and all 76 pass after repair. Security found no remaining HIGH/CRITICAL in `d7090fc`, but noted a possible LOW large-map refusal. A streamed fixture proved a real `printf: Broken pipe` (76 passes / 1 failure on old code), and `4e41e83` consumes the complete map before returning the first match. All 77 focused checks pass independently in both final review lanes; both are CLEAR with no remaining finding. No rejected candidate is presented as clear. The two older host-dependent fixtures now use a valid nonmatching numeric PID where they previously supplied zero or omitted it; their real process-ancestry dependency is not weakened.

## 2. Menu observations: proposed exact scope, not implemented

### Reuse and failure

Reuse native OMP approval events, existing SQLite events, prompt parsing, the attention ladder, committed handover events and existing bounded conductor review. Do not add action authority or a parallel approval channel.

`agent-hooks/omp-herdr-control.ts:925` drops session/call identity when notifying and deletes cached input on the first request. `agent-hooks/omp-notify.sh:95` can return after five failed screen probes without a durable occurrence. `attention-tick.sh:337` skips unreadable/answered observations together. The hub's denied watchdog at `hub.py:4313` excludes blocked tasks. Existing watchdog acknowledgements and unrelated owner activity retire notification obligations; those are not evidence that an action completed.

### Proposed production boundary

| File | Bounded change |
|---|---|
| `agent-hooks/omp-herdr-control.ts` | Carry native session/call identity and complete input; keep repeated-call input; persist before detached screen work; emit correlated lifecycle facts. |
| `agent-hooks/omp-notify.sh` | Persist request before probing; failed parsing updates display status instead of discarding the observation. |
| New `lib/prompt-occurrence.py` | Deterministic event writer/fold over the existing events store, shared by shell and hub; no grant or permission endpoint. |
| `lib/prompt-parse.sh` | Adapter distinguishing read failure, readable-but-unparseable and current parser results, with parsing rules unchanged. |
| `attention-tick.sh`, `lib/attention-key.sh` | Project unresolved occurrence state/age; key delivery by occurrence and committed conductor generation; retain legacy behavior for legacy callers. |
| `lib/push-wake.sh`, `herdr-select.sh` | Separate observation from screen-corroborated selection; use shared correlation and preserve every source, policy, prompt and conductor check. Unknown/mismatch sends zero keys. |
| `hub.py`, `lib/run-registry.sh` | Inventory/attention adapters, unresolved-event retention and projection across blocked/stalled states; suppress duplicate legacy handling for occurrences that own attention. |

Do not broaden `stall-watchdog.sh`'s unrelated acknowledgement semantics; native menu occurrences use the existing attention ladder. This is a proposed cohesive slice, not permission to change all consumers before scope review.

### Data and lifecycle contract

Immutable occurrence identity is `(run, task, pane, registered pane birth, native session, toolCallId)`. Store tool, complete input, canonical input digest, source, first-seen sequence/time and corroborated screen binding. Input digest is an immutable constraint, not the occurrence identity. Missing input followed by verified enrichment remains one occurrence; changed tool/input under the same call is a mismatch. Identical commands with different call IDs stay distinct.

Keep display (`pending_parseable`, `pending_unreadable`, `read_failed`, `correlation_mismatch`, `unknown`), authorization (current policy result/hold) and lifecycle separate. Requested may become approved-awaiting-completion; only a matching completion, decline or withdrawal resolves it. Approval, execution start, disappearance, task status, idle Main, review, wake delivery and answered inbox do not establish completion. Failed matching completion resolves the action as failed, without declaring task success.

Attach a screen prompt ID only using existing full tool/command corroboration. Missing hook identity, multiple plausible calls, clipping and forged or unknown panels retain unknown state and send zero keys. Observation text is never approval.

Deduplicate event IDs and retain unresolved evidence across restart. A late request cannot reopen a resolved occurrence. Delivery identity includes the current assignment and committed handover event generation, so A-to-B-to-A is distinguishable. Handover retains scope and age; it creates a delivery obligation, not authority. Unknown send outcome is not exactly-once delivery.

### Implementation prerequisite and proof

Read-only inspection established the pinned OMP 18.8.7 contract in `/opt/homebrew/Cellar/omp/18.8.7/bin/omp`, SHA-256 `cf0227bdefca0c486bd2aed1771de3ab98930266883eb69d341caf5665caee14`; the executable was never invoked. Bundled `wrapper.ts` at byte 154546753 emits `tool_approval_resolved` with `sessionId`, `toolName`, `toolCallId`, `approved`, and optional `reason`, using the same captured session as the request. The checked-in handler ignores this payload (`omp-herdr-control.ts:1308`); its existing test only supplies `{approved:true}` (`verify-omp-hooks.sh:940`).

Approval resolution precedes `tool.execute`, so approval is not completion. False also covers unavailable UI or abort; preserve its reason instead of labelling every false a human denial. Bundled `lifecycle-mirror.ts` at byte 150990597 and `agent-loop.ts` at byte 143960156 provide `tool_execution_end` with call ID, tool, result and `isError`, but **no session ID**. The runner context supplies a session manager (byte 157988330). Implementation must correlate that context to the recorded request and prove delayed events/session changes cannot resolve another call. Aborted/unexecuted calls may emit error completion. Missing or conflicting correlation stays unknown; never resolve the latest pending occurrence by inference.

Extend existing hook, attention, selector, hub and watchdog fixtures plus a pure occurrence-fold suite. Cover input-cache eviction/duplicate events, late enrichment, changed input under reused IDs, concurrent identical commands, session/birth reuse, out-of-order completion, crash after approval, unrelated acknowledgements, wrapped/clipped/Unicode/forged screens, unknown highlights/options, read failure, blocked/stalled transitions, overdue events, restart and A-to-B-to-A handover. Negative paths send zero keys and bounded notifications. The existing positive authorized compound-menu fixture must still succeed.

## 3. Receipt-to-ack recovery: proposed exact scope, not implemented

### Reuse and failure

The protected receipt can reach `launched` before the publisher saves `pending_command_acks` (`publisher.py:1751`). A crash in that gap loses the local acknowledgement cache. Redelivery checks live source validity first (`publisher.py:1488`), and retired/revoked commands may never be leased again. The Worker then lacks the target needed for cancellation. Its existing late-ack path already repairs that mapping for cancellation only.

Reuse historical receipt verification, the protected registry, existing machine-authenticated `/ingest/sync` and its `command_acks`. Do not weaken source expiry, admission, switches or authorization. Recovery must be independent of redelivery and incapable of spawning.

| File | Bounded change |
|---|---|
| `lib/task-authorization.py` | Durable transport revision/confirmation on protected receipts; lifecycle transactions advance revision; bounded pending enumeration and exact-revision confirmation. |
| `lib/run-registry.sh`, `remote-mcp/registry-bridge.sh` | Additive migration/narrow adapters and retention of task evidence needed by unconfirmed revisions. |
| `remote-mcp/tasks.py` | Ack-only projection from verified historical receipt plus binding. No admission, reservation, brief, spawn or capability-probe call. |
| `remote-mcp/publisher.py` | Enumerate pending revisions before sync, independently of JSON cache and leases; send acknowledgements and CAS-confirm the exact sent revision only on explicit correlated results. |
| `remote-mcp/worker/src/state.ts` | Bounded `command_ack_results` on existing sync response; preserve current late-ack/cancellation behavior. `types.ts` only if response typing belongs there. |

`authorization.py`, `spawn-task.sh`, policy and source issuance are outside this slice. HTTP 200 is insufficient confirmation: current sync also returns success for ignored/conflicting evidence.

### Contract and proof

Use `verify_receipt()` and `_binding(require_active=False)` for historical evidence. Accepted receipt projects held without inventing a mapping; bound/launch-claimed projects held with protected mapping; launched projects accepted with protected mapping. Confirmation means that evidence was recorded, not that work completed or authority renewed.

Correlate Worker results to command ID and exact submitted acknowledgement digest. Distinguish recorded/already-recorded from unknown, conflict and unsupported. Accepted duplicate requires the retained binding to match. An older held response cannot confirm a newer launched revision. Corrupt/missing evidence stays unresolved with one durable recovery record; identity files or inbox assertions are not substitutes.

Historical evidence may be delivered after source expiry, OAuth revocation or new-launch switches turning off. The Worker must retain late targets only for cancellation, with no running-state resurrection, new receipt, expiry extension or resume bypass. Unknown/pruned commands produce explicit unresolved results; current 30-day retention is a practical boundary, not permission to fabricate forgotten authority.

Prove crash after every receipt phase, especially launched-before-publisher-save; fresh publisher restart after expiry/revocation with no redelivery; exact target cancellation and one original spawn; lost sync response after Worker application; old-held/new-launched confirmation race; forged cache, absent/corrupt/mismatched receipts, unknown/pruned command, bounded backlog, migration and retention. Use real temporary registry persistence and production Worker methods with fixture transports. Removing enumeration or confirming the wrong revision must make the tests fail. Keep the extended suites in existing CI gates.

### Migration and rollback of the proposed slices

Menu observations append versioned events to the existing store; no observation is converted into a grant. Projection must tolerate older events as unknown and preserve their unresolved age. Rollout of hook, parser/selector and attention consumers is an explicit activation unit. A downgrade must retain the event journal and surface unsupported unresolved observations for bounded review; it must not mark them answered or erase evidence.

Receipt transport metadata is additive under the existing registry writer lock and verified backup/migration protocol. The Worker response extension is backward compatible: an older response lacking correlated acknowledgement results leaves the receipt unconfirmed for retry; a new Worker accepts old acknowledgement requests without assuming local durable confirmation. Keep bounded backlog and pending-evidence retention explicit. Rollback disables the new projection/sender using reviewed code while retaining receipt revisions and remote stop mappings. Never clear a cancellation target or fabricate a confirmation to make a downgrade appear complete.

Neither migration is run against live state in this engineering phase. Each activation proposal must pin schema/component versions, compatibility order, backup, exact permitted target, stop conditions and rollback commands. Independent tests must show old/new mixed versions fail closed and do not relaunch a job.

## 4. Isolated canary: operational and authorization boundary

One uniquely named disposable canonical repository/worktree/branch, outside existing jobs and routine launch/archive targets, can avoid the global nonremote-admission race. Use one authorized launcher throughout admission, mutation, execution and verified pane shutdown; explicitly exclude other local/manual launch/archive paths from that target. A snapshot alone does not exclude future races. Every component must use the intended isolated registry, with no conflicting task/reservation/pane; unknown observations abort. This is cooperative trusted-host isolation, not same-UID containment.

The parent must identify the supported canary route and exact bounded inspect/edit/test/local-commit/review scope. Current remote allowlisting excludes `herdr-control`; do not change it silently or use KnowledgeBase as a proxy. Any necessary activation/deployment must be separately proposed with exact code/component versions, target environment, migration/backup, commands, stop conditions and rollback, for action-time approval. No such action is taken by this plan.

Acceptance still requires the actual permitted sequence, exact task/commit/review evidence, and measured zero owner relays within its approved scope, with concurrent jobs/handover/crash/ack-loss and negative requests exercised. Engineering fixture counts are not a substitute. Legacy unknown-provenance tasks require a genuine new bounded authorization through a supported trusted mechanism; never backfill historical approval or clear Main's refusal implicitly.

## 5. Conditional follow-ons, deliberately not started

Full M2 expiry/epochs/HEAD-index/hooks binding and complete user-ceiling enforcement remain separately reviewable hardening. Global all-launch exclusivity is not required solely to run the isolated trusted-host canary above.

If remote-versus-new-nonremote coordination is later needed, the smallest code design is a neutral local launch-intent row under the same SQLite writer lock, reciprocal remote/local checks before mutation, atomic registration binding and retained unknown outcomes. It must not become an authorization receipt. Shared local blockers can preserve existing local/local respawn behavior; global mutual exclusion would require a broader lifecycle contract. `spawn-agent` sessions and arbitrary same-UID writes are not covered by that narrow design.

## 6. Review and artifact handling

Return the separate identity commit promptly to the parent's same independent reviewer. Obtain scope selection before implementing the broader menu/ack changes above. All work stays inactive, with local commits only; no push, merge, deployment, persistent access expansion or live approval.

The consolidated Library report remains the reviewed `2f7c6fd` snapshot until the new review completes. Preserve `library_file_id=libfile_5327f8eaa4dc8191b09c9c853b428b5c` when refreshing it; replace that existing file rather than creating a duplicate. Its older broad activation-gate wording will be narrowed to this priority at that reviewed refresh.
