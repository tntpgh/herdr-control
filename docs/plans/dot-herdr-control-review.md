# Independent review record: dot → Herdr M1

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

Both findings were repaired in the follow-up candidate. Exact-head independent re-review is pending; the initial candidate remains rejected.

The receiver now returns a nonterminal `held` acknowledgement for an exact unfinished or unavailable receipt, with any complete protected local mapping. The Worker retains that mapping without claiming launch success. Both acknowledgement orders converge, cancellation/revocation/expiry preserve known stop targets, unknown expired holds remain durable, and late accepted evidence can only restore cancellation reachability. Source expiry, receipt and lease are not renewed. A real Python producer fixture drives the Worker regression (22 offline tests).

Cancel cache fingerprints now bind only command ID, operation, remote task ID and payload. Attempts may change; payload may not. Missing resume mode also refuses consistently. A separately observed concurrent cold-registry initialization race was repaired with a connection timeout installed before the first WAL PRAGMA, with an eight-process regression (21 registry tests).

Existing regression suites use explicit accepted/bound/launched test receipts, not replacement production validators. Environment-limited and deployed-baseline failures remain separately reported in the evidence file.
