# Evidence for the dot → Herdr plan

Baseline: `4f071ad0454bb5fcb1d835872bd6705064207c3f`. Date: 2026-10-10 UTC.
This records planning and inactive implementation verification. It is not live canary acceptance.

## Repository and isolation

Created the explicitly requested worktree with:

```text
git -C /Users/thurbs/Code/herdr-control worktree add -b fix/dot-control-authorization /Users/thurbs/Documents/Codex/2026-10-09/task/herdr-control 4f071ad0454bb5fcb1d835872bd6705064207c3f
Preparing worktree (new branch 'fix/dot-control-authorization')
HEAD is now at 4f071ad fix(remote-mcp): route conductorless tasks to Main (#272)
```

The shared checkout remains on `main` at `2109e1c`; no checkout, reset, edit, worker approval, cancellation or deployment was performed there. The creation wrote only the new worktree/branch and its necessary shared git metadata. No git hooks were disabled.

Read-only connector snapshot at 00:33:12 UTC reported deployed hub `4f071ad`, two active KnowledgeBase jobs (`remote/3b223c69` and `remote/ed92fc20`), and current allowlisted repositories `knowledge-base`, `thurber-os`, `tourguide`, `tntpgh-dev`. `herdr-control` is not allowlisted. No attempt was made to change that list or spawn a proxy job.

## Exact local checks and limitations

| Command | Observed result | Interpretation |
|---|---|---|
| `bash tmp/dot-control/reproduce.sh` | Exit 0 for diagnostic runner; simple add/commit ownership rc=0; compound and quoted-cd ownership rc=1 | The script does not assert success or execute any command string. Ownership result reproduces the grammar miss. Full peer results are inconclusive because missing worktree parser dependency/log-path restrictions affected generic classification |
| `bash verify-conductor-handover.sh` | Exit 1, `passed=33 failed=25` | Raw CAS checks pass; CLI fixture calls return 3 and later assertions cascade. Exact root cause not yet established. Do not claim baseline suite is green or change production identity policy to make the test pass |
| `python3 remote-mcp/verify-tasks.py` | Exit 1, `Ran 62 tests in 3.215s`, `FAILED (errors=1)` | `CapabilityProbe.setUpClass` could not bind its localhost HTTP fixture: `PermissionError: [Errno 1] Operation not permitted`. Environment-limited baseline, not a code regression |
| `omp --help` | Exit 0, OMP v18.8.7, supports `--thinking … max` | CLI capability only. No model invocation, subscription-auth proof or paid API request |

Raw logs (stored with `.txt` extensions) and the diagnostic source are in [evidence/dot-control](evidence/dot-control). The archived script retains its original path calculation and is reproducible from `tmp/dot-control/reproduce.sh`, not from the archive directory. The first diagnostic also attempted default policy audit paths outside this task's writable sandbox, which failed with `Operation not permitted`; these are retained verbatim. No denied action was retried through another spelling, wrapper or identity. The ownership parser itself is a pure text check; its rc is separable from the later full-policy failure. The compound probe is a synthetic command shape, not the exact production bytes.

Do not use these failed/degraded baselines as an excuse to loosen policy. Before implementation verification, establish a permitted test environment with the repository's installed parser dependency and isolated cache/registry/log paths. Any fixture listener or process-ancestry access requiring additional execution permission must use the approval mechanism, never HERDR_ENV spoofing.

## Independent evidence and review gate

Two separate read-only repository audits confirmed: manifest survives handover; `_cp_simple_words` intentionally rejects compounds/quoted `cd`; remote actor provenance is not delivered locally; existing branch-work review and typed command queue can be reused; inbox text is never approval. Their findings informed the plan and therefore do not count as independent approval of that plan.

Parent reports an independent Astra ultra architecture review completed, with exact-plan/code acceptance pending. Its findings are incorporated: manifest is not an immutable complete user ceiling; trusted-host pane identity is not containment; grants lack expiry/generation; command hash does not bind git index/HEAD/hooks/config; crash windows are ambiguous; delivery/push proof does not establish tests/review.

Latest parent observation: Main refuses the recap commit/push because its original manifest approval was `conductor_unknown` with no pane identity. The refusal is preserved. This task did not inspect the live approval prompt or issue an approval. The two defects are grammar recognition and missing verified original provenance; neither is a lost database manifest.

Subsequent parent reviewer finding is also incorporated: assigning Main as supervisor can be logged as apparent manifest approval even without a Main decision; simple ownership fast paths do not check original approval provenance. The proposed first slice now includes separation of requester/source/supervisor, pre-execution task-bound provenance and identical unknown-provenance holds on simple/compound commands. Merely adding handover guidance is insufficient. That planning-stage gate was subsequently satisfied at `212033c`, as recorded below.

Supplemental independent exact-plan review of `290c1f5` returned ITERATE with two HIGH findings: the provenance hold must also cover reviewed menu conductor, hook decision and approved one-shot consumption; minimum mixed-version admission cannot be deferred while issuing provenance-bearing legacy commands. Both corrections are now explicit in the plan. This review did not run tests or authorize implementation/activation; the parent subsequently supplied exact-plan GO at `212033c`.

## Follow-up baseline diagnosis (same unchanged production source)

`ps -o ppid= -p $$` returned exit 127 with `zsh:1: operation not permitted: ps`. `lib/pane-guard.sh:185` requires that process-ancestry read. The handover CLI's 25 failures follow its identity-check exit 3 and the resulting unchanged fixture state; raw registry CAS cases passed. No fallback identity or fake `ps` was introduced.

The remote task error is the fixture's `HTTPServer(("127.0.0.1", 0), Health)` bind at `remote-mcp/verify-tasks.py:317`; no live service is involved. It was not retried outside the sandbox or silently skipped.

The isolated worktree lacked its ignored `.venv-bashlex` interpreter, while the existing shared checkout already has it installed. A worktree-local symlink now reuses that dependency read-only. With `XDG_RUNTIME_DIR` pointed to a task-local test directory (no HOME/HERDR_ENV change), the same diagnostic returned cleanly:

```text
add peer_rc=0 verdict=allow authority=grant
status peer_rc=0 verdict=allow authority=peer
commit peer_rc=0 verdict=allow authority=grant
compound peer_rc=1 verdict=escalate authority=peer
quoted_cd peer_rc=1 verdict=escalate authority=peer
```

Both escalation reasons are `find/git combined with substitution, redirect or quoting: a conductor must review it`. Exact output: [reproduction-dependencies-restored.txt](evidence/dot-control/reproduction-dependencies-restored.txt). These command strings were classified only, never executed. This proves the grammar difference while preserving the unknown-provenance problem; it does not approve splitting a held real command. No production code had changed at that baseline point.

## Interruption accounting

No live canary ran. Workflow owner-relay count: **not measured**. Historical owner interruption count: **unknown**. No zero-relay success claim is made.

Worktree creation and local git metadata writes use the execution environment's auto-review mechanism because the common git directory is outside this task's writable root. No human response was required in this thread. No owner approval, message to KB/Main, canary launch, merge, deploy, persistent access change or live grant was issued. A progress/clarification message to the source task through the local task API failed with `thread not found`; it did not deliver. Final task output is the supported parent handoff.

## Reviewed scope and inactive candidate

The parent supplied independent exact-plan **GO** at `212033cdc389283d8edd40c68af96b5229e424d8` for bounded inactive M1. Initial implementation candidate `71eafafdd765e53f275c2534f3ca21d28001dab3`, on `fix/dot-control-authorization`, received **REQUEST CHANGES / BLOCK** from two fresh independent review lanes. They found one HIGH (a concurrent duplicate's refusal could discard a later successful launch acknowledgement and lose remote cancellation) and one MEDIUM (cancel retry hashing included mutable lease attempts). Both were repaired before another exact-head review: unresolved matching receipts produce nonterminal `held` acknowledgements, while cancel retry hashes omit lease-attempt counters. No activation occurred.

M1 preserves server-derived task delegation in the existing command queue with a canonical HMAC receipt, validates it against the local allowlist, and binds it atomically to the actual task identity before launch. Local launches require verified process ancestry and a live eligible conductor. The assigned supervisor is never recorded as the source approver. Legacy tasks remain unverified; policy/parser/identity failures hold across ownership, menu, hook, decision and consumption paths. Receipt retries cannot launch twice; ambiguous launch intent is retained as `outcome_unknown`. Registration, launch intent and launch acknowledgement are separate durable facts.

The parent-reported unreadable-menu stall is recorded in plan section 11. Independent diagnosis found a dropped tool-call identifier and monitoring that can conflate unreadable with answered. Existing menu parser tests passed 64/64 and window tests 16/16; this does not reconstruct the live incident. M1 removes the sweep's incorrect exit-8-to-clipping inference and shorter-command advice. Structured menu observations and watchdog state repair remain a separately reviewed follow-on.

## Implementation verification

All records below use synthetic identities, scratch state and fixture transports. The source authentication tests use fixture keys, never live signing credentials. Shell execution/overwrite tests reserve the new control helper filenames; native file tools retain the existing worktree-containment policy. These are not OS containment guarantees. No model/service/API call or live Herdr worker was used.

| Command / evidence | Observed result | Boundary |
|---|---|---|
| `python3 verify-task-authorization.py` | 23 passed | Real SQLite and concurrent processes: receipt acceptance, duplicate binding/launch winners, concurrent independent jobs, handover, corruption, rollback and legacy migration |
| `bash verify-task-authorization-gates.sh` | 48 passed | Real policy/registry with explicit fixture panes/ancestry; no live approval |
| `python3 remote-mcp/verify-authorization.py` | 64 passed | HMAC/protocol/time/payload/scope checks; production Worker golden vector interoperability |
| `python3 remote-mcp/verify-tasks.py` | 76 passed | Lifecycle and failure/recovery behavior; local fixture transport |
| `python3 remote-mcp/verify-publisher.py` | 47 passed | Publisher formatting, bookkeeping and isolated response handling |
| `python3 remote-mcp/verify-tasks-e2e.py --registry-only` | 89 passing assertions | Real receipt verification/registry, fake worker launch; timers explicitly excluded |
| `node test/authorization-offline.cjs` in `remote-mcp/worker` | 26 passed | Real production state methods and SQLite; substitutes DurableObject base/storage, no Cloudflare/OAuth ingress |
| Worker TypeScript `tsc --noEmit` | Exit 0 | Static check using existing installed dependencies |
| `bash verify-scoped-approval.sh` | 260 passed | Existing policy cases use explicit protected-receipt fixtures |
| `bash verify-pretool-shadow.sh` | 70 passed | Existing policy shadow behavior with verified fixtures |
| `bash verify-pretool-enforce.sh` | 185 passed | Real hook interface; fixture transports/identity only |
| `bash verify-owner-approval.sh` | 118 passed, 3 failed, 3 skipped | Three quote/parser failures reproduced against deployed baseline; skips require host process/PTY access |
| `bash verify-select-policy.sh` | 387 passed, 22 failed | Deployed `4f071ad` baseline also 387/22; all 22 ordered failure lines match exactly after decoding |
| `bash verify-run-registry.sh` | 134 passed | Existing schema expectation updated to 11; no legacy grant backfill |
| `bash verify-sweep-approvals.sh` | 23 passed | No selector refusal is misreported as clipping or permission to retry |
| `bash verify-process-identity-failures.sh` | 3 passed | Unavailable, malformed and truncated ancestry return unknown, including a matching partial ancestor |

Raw results are in [evidence/dot-control](evidence/dot-control). Node uses the existing `/Users/thurbs/.local/share/mise/installs/node/22.23.2/bin/node`; the default shim could not resolve its configured version. No runtime was installed and no global setting changed. The parser and Worker dependencies are existing read-only worktree symlinks, excluded from git.

The legacy owner-approval and menu-select suites are not claimed green: their parser/quote/menu mismatches are retained in raw result files and baseline comparisons. No production parser or identity guard was weakened to remove them.

The standard Worker Vitest attempt executed **zero tests**: localhost binding and Wrangler log-path permissions failed before execution. The full timer integration attempt reached sandbox-denied `ps`; the registry-only run explicitly excludes timer verification and cannot establish it. Baseline handover CLI tests also remain host-limited by real process ancestry. No rejected test or action was retried with a false Herdr identity or a weaker production guard. In-process HTTP response fixtures replaced listener-only unit harnesses; the result is explicitly not socket integration.

The pre-commit repository hook initially rejected synthetic `example.test` email addresses. Fixtures were corrected to its supported reserved `example.com` domain and the signed golden vector regenerated. Hooks and policy configuration were not changed or disabled. The corrected initial commit passed the hook without a human prompt. The repaired candidate commit completed but the PII scan emitted an `awk` invalid-UTF-8 warning from a deliberately truncated-byte shadow-test diagnostic. That archived diagnostic now represents invalid bytes as literal `\\xc3`; its raw source remains in `/tmp/herdr-regression-shadow-recheck.log`. No hook/configuration was changed. A read-only scan of the complete `4f071ad..fb35974` range with the installed scanner, unchanged patterns and byte-safe `LC_ALL=C` returned exit 0 without warnings; see [candidate-secret-scan.txt](evidence/dot-control/candidate-secret-scan.txt). No push or network operation ran; the warning is not treated as successful full scanning.

## Measured interruptions and side effects

Engineering job: **0 owner input requests, 0 owner relays, 0 human approval prompts, 0 live canary runs, 0 sends to KB/Main**. These counts describe this engineering job, not end-to-end Herdr task acceptance.

In the new consumer fixture, three sequential and four concurrent enforcing-hook calls for an unverified task produced **0 action requests**. Two surface/tick retries produced **1 durable hold event and 0 notification/form sends**. Four concurrent consumers of one verified grant produced **1 consumption and 3 refusals**; a subsequent replay refused. Held scenarios produced **0 consumes, 0 keypresses and 0 notifications**. One separately identified positive approval emitted one fixture notification.

Real-registry integration observed exactly one fake launch for overlapping duplicate consumers; the loser reported nonterminal `held` with `outcome_unknown`. Actual Python-produced acknowledgements were passed through production Worker state methods in both arrival orders. Held replay generated one audit/event; mapped holds stayed cancellable; expired unmapped holds kept a durable unresolved record. Late acknowledgements retained targets only for cancellation, never restored launch authority. The subsequent stop-tracking regression covers late accepted/held mappings from failed, timed-out and cancelled rows, transient stop failure, lost/expired stop acknowledgement, five bounded retries, one durable stuck event, replay and final confirmed stop. The repaired reviewer probe observed `cancelling`, `late_accepted`, one pending retry after the first stop failed (27 passed including its additional case). Two distinct concurrent jobs retained different receipt/task bindings. A lost acknowledgement reused the protected record without another launch or deadline extension. Eight real processes simultaneously initializing one cold registry also passed after a reproduced race was fixed by installing the SQLite busy timeout before the first WAL PRAGMA. Independent repeats later exposed a backup/version-check race in that migration; the earlier passing cold-init run alone did not establish reliability. Fixing that race alone still produced 1/10 cold-init failures, and an amplified run reproduced 6/30 failures at the initial WAL transition. After the writer-lock migration and bounded typed WAL retry repairs, all 160 simultaneous initializer processes passed: eight processes × ten cold registries plus eight × ten populated v10 registries. Each populated migration retained one verified pre-v11 backup. Backup/schema-failure tests confirm fail-closed rollback and preservation of verified backups; the final authorization suite passed 23/23 and legacy registry suite 134/134. These are fixture measurements, not a live job or a proof that every crash window automatically recovers.

## Remaining acceptance gates

Fresh independent review of `fb35974ff368ae3eed847b6a75139c08a4405971` found a further HIGH: late mapping after revocation remained terminal, so a transient cancel failure lost the retry. Both lanes also reproduced a MEDIUM concurrent-migration backup race (20 passed / 1 failed), superseding the earlier 21-pass run as evidence of reliable concurrency. That candidate remains rejected. Both findings have now been repaired and a new exact-head review is pending: cancellation stays tracked, while SQLite serializes version recheck, unique verified backup, DDL and version stamping. WAL setup retries only typed transient BUSY/LOCKED errors within the existing bounded wait budget. The real canary (inspection → edit → tests → local commit → review, zero owner relays) has **not** run. No production source receipt was backfilled, no legacy refusal was cleared, and no merge, push, deploy, persistent access expansion, approval activation or security-setting change occurred. Later activation/canary authorization must be resolved by the parent through a permitted route; current remote allowlisting excludes `herdr-control`.

M2 action-grant expiry/generation/HEAD-index binding and full immutable work ceilings, plus the menu/watchdog follow-on, remain outside M1. A durable receipt outbox is also required before claiming recovery when a crash loses the acknowledgement and restart occurs after source expiry/revocation; late-ack handling alone cannot generate missing evidence. This candidate must not be described as satisfying full release acceptance.
