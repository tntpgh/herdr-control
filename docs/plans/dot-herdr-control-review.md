# Independent review record: dot → Herdr M1

Follow-up priority and exact identity candidate: [identity evidence](dot-herdr-identity-evidence.md) and [bounded recovery scopes](dot-herdr-recovery-slices.md). These supersede older broad prerequisite wording: full M2/global nonremote admission are conditional follow-ons; the immediate path is identity repair, menu/watchdog recovery, minimal durable receipt-to-ack recovery and an explicitly permitted isolated canary. The M1 history below remains an immutable account of its earlier reviews.

Latest result: **security CLEAR + architecture CLEAR** for bounded inactive M1 at `37a3dff28d4402eb5b509e7f59c72c43f0c6cbf6`; zero unresolved high-confidence HIGH/CRITICAL findings. Full activation/release acceptance remains open. Earlier rejected candidates are retained below.

Plan approval: parent-supplied independent GO at `212033cdc389283d8edd40c68af96b5229e424d8`, bounded inactive M1 only. Architecture advice previously came from the parent's Astra ultra review. This record does not approve deployment, a live action or full release acceptance.

## Initial candidate: 71eafafdd765e53f275c2534f3ca21d28001dab3

Two fresh review lanes inspected the exact committed code independently. They did not author the implementation or edit files.

**Security/spec: REQUEST CHANGES.** One HIGH, one MEDIUM. Personally inspected 23 files: 18 production files, four verifiers and the plan, plus a delegated narrow transport audit. Ran the exported candidate's registry authorization (19 passed), approval gates (36 passed) and negative ancestry (3 passed); its delegated authorization suite passed 62. No live worker or network action.

**Architecture: BLOCK.** Independently reproduced the HIGH using production Worker methods with in-memory SQLite and network disabled. Other M1 boundaries were coherent: source versus supervisor, existing queue/key reuse, protocol rejection/withholding and delivery expiry versus running-task lifetime.

### HIGH: unfinished duplicate poisoned definitive launch acknowledgement

`remote-mcp/tasks.py:652` returned `outcome: refused` for a matching but unfinished receipt. The original consumer could still launch. If the duplicate acknowledgement arrived first, `remote-mcp/worker/src/state.ts:1339–1341` marked the command done; lines 1384–1386 marked the remote task failed without its local identity. The later accepted acknowledgement was ignored. Cancellation and revocation could no longer reach the running worker. The local deadline remained a backstop but did not make this interface correct.

Observed offline:

```json
{"state":{"state":"failed","local_task_id":"","local_run_id":""},"command":{"status":"done","outcome":"refused"},"cancels":0}
{"cancel_request":{"ok":false,"reason":"already_terminal (failed)"}}
```

Required repair: a matching unfinished receipt must remain nonterminal, retain any known verified local identity and permit definitive acknowledgement/reconciliation or cancellation. Feed both acknowledgement orders through Worker in a regression; count one launch. Do not reexecute an ambiguous action.

### MEDIUM: mutable lease count broke cancel replay

`remote-mcp/publisher.py:1501` fingerprinted the complete wire command, including `attempts`, which changes on legitimate redelivery. The isolated reproduction returned accepted on attempt 1, then refused on attempt 2, with one processor call.

Required repair: hash immutable command ID, operation, remote task ID and payload. A changed lease-attempt count must reuse the acknowledgement; changed payload must refuse.

## Boundaries retained by both reviewers

Action-grant expiry, conductor epochs, HEAD/index binding and complete user-ceiling enforcement remain M2/M3. Full Cloudflare integration, timer/positive live ancestry and the real canary remain unproven. Both-components rollback needs a tested quiescence procedure before activation; old code can ignore additive receipt fields. Fixture success is not zero-owner-relay release acceptance.

## Follow-up

Both findings were repaired in the follow-up candidate, then re-reviewed as recorded below. The initial candidate remains rejected.

The receiver now returns a nonterminal `held` acknowledgement for an exact unfinished or unavailable receipt, with any complete protected local mapping. The Worker retains that mapping without claiming launch success. Both acknowledgement orders converge, cancellation/revocation/expiry preserve known stop targets, unknown expired holds remain durable, and late accepted evidence can only restore cancellation reachability. Source expiry, receipt and lease are not renewed. A real Python producer fixture drives the Worker regression (22 offline tests).

Cancel cache fingerprints now bind only command ID, operation, remote task ID and payload. Attempts may change; payload may not. Missing resume mode also refuses consistently. A separately observed concurrent cold-registry initialization race was repaired with a connection timeout installed before the first WAL PRAGMA, with an eight-process regression (21 registry tests).

Existing regression suites use explicit accepted/bound/launched test receipts, not replacement production validators. Environment-limited and deployed-baseline failures remain separately reported in the evidence file.

## Second candidate: fb35974ff368ae3eed847b6a75139c08a4405971

Two new independent lanes both reproduced a remaining HIGH and returned a blocking finding: a revoked, previously unbound held launch can later report a local mapping, but the stop request was queued while its remote state remained terminal `cancelled`. A transient cancellation failure then skips the retry path (`state.ts:1500`) because that path excludes terminal states. The stop target is recorded but no outstanding stop or stuck event remains.

Observed with the actual Python acknowledgement producer and production Worker methods: `state=cancelled`, `local_task_id=task_fixture`, start `done/late_accepted`, cancel `done/failed`, no `cancel_retry_queued` or `cancel_stuck`, next sync `commands=[]`.

Required repair: a late-discovered possibly running target must retain unresolved cancellation state independently from the retired launch authority. Failed or lost stop delivery needs bounded retries or one durable unresolved-stop record; it must never revive launch permission. The author repair and subsequent independent reviews are recorded below.

The same two lanes independently reproduced a MEDIUM migration race: the registry suite returned 20 passed / 1 failed, and a standalone cold-initialization rerun failed. Multiple v11 migrators shared a second-resolution backup destination and checked version outside a migration-wide writer lock; one read `integrity=<none>, version=10, expected=10`. A unique verified backup plus serialized version recheck/migration is required.

Architecture WATCH for later activation: after crash-before-ack persistence, a restart beyond source expiry/revocation cannot regenerate the acknowledgement from a durable outbox. The repaired handler can contain late acknowledgements that arrive; it does not guarantee producing every lost one. Keep receipt-outbox/reconciliation and its permitted crash canary as an explicit M3/preactivation gate.

Repair design for the second review: `ensureCancel` reopens only stop tracking to `cancelling` when a late mapping reveals a possible live target. Failed and expired/lost cancellations share the existing retry ceiling and produce one `cancel_stuck` record on exhaustion. Source receipts, launch expiry and authority remain retired. Migration now rechecks version under one SQLite writer lock, creates a unique verified online backup, and commits schema plus version together. Stress testing also exposed a separate transient lock at initial WAL setup; bounded typed busy handling passed the final stress tests before the next exact-head candidate: eight simultaneous initializers × ten cold starts and × ten populated v10 migrations. Full registry authorization 23/23 and existing registry 134/134 passed. Worker offline 26/26 and reviewer reproducer 27/27 passed; TypeScript passed. These repairs were included in the subsequent exact-head reviews below.

## External parent review at fb35974 plus evolving repairs

The parent independently reported two additional HIGH findings, keeping the candidate unaccepted:

1. `lib/action-request.sh:74` checked source authority separately from the status/kind-only consumption UPDATE; cancellation or source invalidation could win between those operations. Approval decisions had the same gap. Required repair: validate current task/receipt and perform the exact action CAS in one SQLite transaction, including file-grant persistence; deterministic invalidation-first tests must show zero consumption and execution. Multiple consumers proving only one winner do not cover invalidation.
2. `state.ts:955` admitted distinct resumes for the same terminal parent, while `spawn-task.sh:863` had a best-effort claim after shared worktree preparation. Required repair: exclusive lineage/worktree reservation before shared mutations, with distinct command IDs and an uncertain first launch.

The parent additionally requires the new suites to run through CI and a successful authorized compound-menu delivery fixture. The durable receipt outbox remains an activation blocker. These bounded inactive repairs are authorized; no activation or broader grant was approved.

The authorized repair is implemented: approval/consumption and file-grant persistence now share the current-source/request validation transaction. The old committed implementation fails four deterministic invalidation interleavings; the repaired shell path and 14 storage tests pass. The supported selector's compound-menu fixture records one Enter and confirmed approval. Remote admission uses a durable one-child lineage; local command-bound canonical reservations precede all shared-worktree writes and survive unknown launch outcomes. Worker before-fix regression failed, then 34 offline tests passed; local reservation 25 and integration 103 passed. The exact eight-suite CI command passed 423 checks locally, with hosted runner execution still unproven. The subsequent exact-head reviews are recorded below.

## Frozen candidate: 34d705ed6bd8d1b14649b01873c0c07f30d3b693

Two fresh lanes were created with no inherited conversation. Neither authored the implementation or advised its repairs. Review baseline is `4f071ad0454bb5fcb1d835872bd6705064207c3f`.

### Security/spec: CLEAR for bounded inactive M1

Unresolved high-confidence HIGH/CRITICAL findings: **0**. No code repair requested. This verdict does not authorize merge, push, activation or a live canary.

The reviewer confirmed transaction-time current source/task validation plus the exact request CAS in `lib/task-authorization.py:436` and `:468`, including file-grant persistence. It confirmed durable one-child resume lineage at `remote-mcp/worker/src/state.ts:1001`, and canonical worktree reservation plus a once-only mutation claim at `lib/task-reservation.py:78`, `:159` and `spawn-task.sh:507` before shared changes. Uncertain launches retain ownership.

Independent passes: authorization/admission 64/64, reservations 25/25 and production Worker offline 34/34. Its fresh narrow reviewer independently passed atomic actions 14/14 and approval gates 56/56. Removing transaction-time source validation in memory made both source-invalidation negatives fail, confirming that the tests detect the repaired defect.

The reviewer explicitly judged the disclosed limitations compatible with bounded inactive M1, but retained them as release/activation gates: no durable lost-acknowledgement outbox; newly concurrent nonremote/unmanaged intents lack shared reservation admission; existing task-bound approvals survive handover until M2 adds epochs/expiry/context binding; no registry-to-PTY atomicity claim; hosted CI, full Cloudflare/OAuth runtime and the real zero-relay canary remain unproven. It performed no live worker, network, security-setting or deployment action.

### Architecture: WATCH, one MEDIUM

Unresolved high-confidence HIGH/CRITICAL findings: **0**. One MEDIUM remains in this exact candidate, so the reviewer does not approve it while recommending a repair. After an unmapped held launch times out, a late acknowledgement can reopen stop tracking; a local `cancelled` snapshot then changes its state to generic `cancelled`. The snapshot remap at `remote-mcp/worker/src/state.ts:1891–1894` checks only `timeout_detected`, although this sequence records `timed_out`. The cancel-ack path at `:1534–1536` already checks both. Required repair: use that same event lookup for snapshots and regress the full sequence. This loses timeout classification, not launch-authority retirement or cancellation reachability.

Independent passes: registry authorization/migration 24/24, action transactions 14/14, reservations 25/25, production Worker offline 34/34, registry integration 103 assertions and approval gates 56/56. No code was edited by review. Bounded inactive M1 architecture otherwise remains supported; the disclosed activation limits remain open.

## Final code candidate: 37a3dff28d4402eb5b509e7f59c72c43f0c6cbf6

The one MEDIUM timeout-reporting finding was repaired with one SQL lookup change and a production offline regression. No broader lifecycle work or authority expansion was added. Red control: 34 passed / 1 failed before; 35/35 after; TypeScript exits 0. The earlier architecture reviewer who advised this repair did not approve it.

**Security/spec: CLEAR for bounded inactive M1.** The independent security reviewer had given no repair advice and independently re-reviewed the complete two-file delta against its earlier full review. Exact SHA: `37a3dff28d4402eb5b509e7f59c72c43f0c6cbf6`. Unresolved high-confidence HIGH/CRITICAL findings: **0**; no new finding or repair advice. It confirmed the lookup matches the cancellation-acknowledgement path and read the red/green logs; it did not rerun the suites. Its earlier independent tests and mutation-control results remain recorded in tool outputs. The raw typecheck log was empty, so it explicitly relied on the author's reported successful exit.

**Architecture: CLEAR for bounded inactive M1.** A fresh reviewer with no inherited conversation, no authorship and no prior repair advice inspected exact `37a3dff28d4402eb5b509e7f59c72c43f0c6cbf6` against deployed baseline `4f071ad`. Unresolved high-confidence HIGH/CRITICAL findings: **0**; no remaining concrete finding. It independently ran the production Worker offline suite, 35/35 passed. Removing only the added `timed_out` event lookup in memory produced 34 passes / 1 failure, confirming sensitivity to the repaired defect without editing source.

It confirmed retained stop targets, bounded cancellation retries and durable stuck records without renewed launch authority; one-child remote resume lineage; canonical local reservations and once-only mutation claims before shared writes. Its fresh delegated atomic audit found no HIGH/CRITICAL and confirmed source/task validation, exact-action consumption/approval and file grants share the SQLite writer transaction.

**Review conclusion:** both lanes are CLEAR on the exact final code, with zero unresolved HIGH/CRITICAL and no remaining concrete finding in bounded inactive M1. This is not permission to merge, deploy or activate. Required later gates remain: durable lost-acknowledgement outbox/reconciliation; newly concurrent nonremote/unmanaged intent admission; deferred M2 epochs/expiry/HEAD-index/full ceiling enforcement; menu/watchdog work; hosted CI, full Cloudflare/OAuth runtime and an explicitly authorized real canary. No reviewer used live Herdr/KB/Main, network, security changes or model CLI calls.
