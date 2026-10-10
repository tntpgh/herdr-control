# Dot → Herdr: preserve task authority without turning messages into approvals

Status: bounded inactive M1 implemented at `37a3dff28d4402eb5b509e7f59c72c43f0c6cbf6` after independent plan GO at `212033cdc389283d8edd40c68af96b5229e424d8`. Final security and architecture reviews are CLEAR for this bounded inactive code; full release/canary acceptance remains open. This document does not authorize activation or a live approval.
Date: 2026-10-10 UTC. Baseline: `4f071ad0454bb5fcb1d835872bd6705064207c3f` (deployed PR272).
Branch: `fix/dot-control-authorization`. Worktree: `/Users/thurbs/Documents/Codex/2026-10-09/task/herdr-control`.

## 1. Reuse audit: what exists before anything new

| Requirement | Existing primitive to retain | Actual gap |
|---|---|---|
| Authorize an implementation task | OAuth `herdr:task.implement`, `remote-mcp/worker/src/mcp.ts`, `state.ts:805–838`; local allowlist | Actor/client and accepted scope remain in the Worker; leased Mac command lacks their provenance |
| Store task scope | `lib/task-manifest.sh`; registry `tasks.manifest`; `manifest_approved` event at `lib/run-registry.sh:715–732` | Manifest is a capability ceiling, not the complete work contract; receiving conductor is not shown its source or limitations |
| Transfer conductor | `conductor-handover.sh`, `set_task_conductor` at `lib/run-registry.sh:760–795` | CAS preserves manifest, but notifications carry only prose reason; hook requests need deliberate re-surfacing and durable acknowledgement |
| Recognize own-branch operations | `_cp_simple_words`, `_cp_grant_action` at `lib/command-policy.sh:534–637`; `peer_decide` at `lib/scoped-policy.sh:477` | Deliberately narrow grammar rejects compound commands and quoted `cd`; no explanation distinguishes this from missing authorization |
| Review a routine exception | `docs/approval-policy.md:24–43`; `herdr-action.sh:213–260`; `herdr-select.sh` conductor review | Main must review complete command and target using preserved task context; an inbox assertion cannot supply it |
| Bind an exact action | `pretool_action_sha`, `lib/action-request.sh:35–45`; code hash added in `lib/pretool-shadow.sh:962–984` | Action rows have no explicit expiry, worker birth snapshot or conductor generation |
| Deduplicate decisions/refusals | deterministic pending IDs, atomic consume and retained declines in `lib/action-request.sh:66–139` | Crash between execution and recorded result needs an explicit ambiguous state, not an automatic retry |
| Audit acknowledgement | `approvals` decided/attempted/confirmed fields; events; remote command leases/acks | Delivery receipt, authorization consumption and completed work are different facts and must remain separately observable |
| Carry authenticated control data | Existing `commands` queue and `/ingest/sync`; HMAC ingest authentication | Extend typed records and receipts; do not add a socket, inbox parser, daemon or arbitrary remote shell |
| Reject forged/stale identity | protected `roles.main`, `caller_pane_from_ancestry`, pane birth, conductor eligibility, CAS | Reuse them at decision time and consume time; a new env var or caller-supplied actor is not proof |

Genuinely new: a bounded authorization-context/receipt schema, structured handover evidence and request generation/expiry fields. A remote permission to approve actions is **not** required to fix this incident and is excluded from the first implementation. M1 is the preferred initial patch; M2/M3 are separately reviewable hardening/design work, not permission to build an unnecessarily large replacement control plane.

## 2. Requirements and current evidence

The owner wants a dedicated engineering job, a detailed plan run through the requested ultrathink lane, independent adversarial review, and minimum relays. Implement only reviewed, inactive changes in this worktree, with local commits. No merge, deploy, persistent access expansion, security-setting change or new approval capability activation without action-time user approval. Use subscription authentication only. Do not modify the two KnowledgeBase workers or Main.

Verified locally:

* PR272 reads Main's protected role pane and birth for **future** remote spawns (`remote-mcp/tasks.py:271–309`); it does not retrofit older rows.
* `set_task_conductor` updates conductor identity and timestamp, with CAS and a transactionally appended event. It does **not** replace `tasks.manifest`.
* The remote implementation brief explicitly requires commit/push to the assigned branch (`remote-mcp/tasks.py:369–378`); its manifest uses the allowlist's `git: push-own-branch`.
* `_cp_simple_words` accepts one simple command and one exact unquoted own-worktree `cd … &&` prefix. Remaining operators cause a miss. This helper is shared with other grant paths; widening it would have broader consequences.
* Owner inbox delivery marks its body untrusted and never an approval (`remote-mcp/publisher.py:735`). This boundary is working as designed.

Critical reviewer finding supplied by the parent: `register_task` attributes `manifest_approved` to the assigned conductor (`lib/run-registry.sh:727`). PR272 can therefore assign Main as supervisor and produce apparent Main approval without an actual Main decision. These must become distinct facts: authenticated requester, authorization source/delegation and assigned supervisor. `peer_decide` currently uses task manifest/branch without checking original approval provenance. Consequently a simple spelling may clear where the compound is held; merely recommending split commands would leave an authorization bypass. The initial repair must make unknown provenance hold consistently on every command shape before treating guidance as sufficient.

Parent-supplied diagnostic, not independently executed against the live workers: both workers are now assigned Main `w72:p1` with matching birth; finance runs; recap has 147/147 tests and exactly two staged additions. Its original manifest still records `git: push-own-branch`. A compound quoted `git add && git status && git commit` missed the ownership recognizer. No approval was issued by the diagnostic task. Exact live command bytes and action hash have not been fetched in this engineering job.

Latest parent update supersedes the earlier interpretation: Main recognizes that manifest but rejects its provenance because the initial `manifest_approved` actor was `conductor_unknown`, without a pane identity. Main requires direct local user confirmation for commit/push. This is a second defect, distinct from the grammar miss. Neither the original work objective, the preserved manifest nor later handover can repair missing grant provenance retroactively. Preserve the refusal; do not approve or reissue the real command, synthesize a known approver, or claim its existing grant was authenticated. The parent handles any explicit legacy recovery decision.

Do not describe this as erased stored scope. The incident combines a grammar miss with unverified initial grant provenance and incomplete handover context. Existing reviewed-conductor `branch-work` is suitable when source authority is verified; it cannot override Main's current explicit provenance refusal. This plan issues no live approval.

### Success requirements

1. Receiving conductors recover the original verified work contract, capability ceiling and any later verified narrowing without owner relay.
2. A routine classifier miss is distinguishable from an out-of-scope request. Only the current live conductor can review the former; deny/reserved/operator restrictions remain binding.
3. Typed control records are authenticated independently of ordinary inbox text. Work objectives, reason strings, tool output and worker files never mint authority.
4. Bind task/run, action hash, authenticated requester, decision actor, worker identity, conductor generation, validity window and replay key. Revalidate local policy at execution time.
5. Persist refusals and unresolved states; no repeated requests for the same unchanged blocked action. Changed commands need fresh review and must not inherit approval.
6. Recover after restart, concurrent processing and lost acknowledgement without duplicate mutation or invented success.
7. An actual permitted synthetic job must complete inspection → editing → tests → local commit → independent review with zero owner relays within scope. Fixture results alone cannot satisfy this requirement.

## 3. Current end-to-end flow and failure seams

1. MCP verifies OAuth and derives caller identity. `startTask` checks scope, switches, repository and caps, saves requester identity remotely and queues `{repo, mode, objective}`.
2. The Mac publisher calls authenticated `/ingest/sync`, receives a leased typed command, locally checks the allowlist and generates the brief/manifest. Requester provenance is not carried through to the local authorization record.
3. `spawn-task.sh` creates its own worktree/branch and registers manifest, worker pane/birth and conductor pane/birth. PR272 supplies Main's role as a validated fallback. Research uses hook approval; implementation currently uses menu approval (`tasks.py:426–446`).
4. Policy checks task context. An exact own-branch command can use the existing ownership grant; a compound grammar miss falls through to generic classification. That miss must not be presented as proof the original task lacks commit authority.
5. Conductor review is an existing local path with operational categories. It checks the complete command/target, active task and current conductor identity. Human-reserved operations use a pinned answered form. Inbox messages only supply data.
6. Handover CAS changes the conductor and emits an event. The notice gives a reason but no verified authorization summary. A human may also genuinely narrow a handover: preserve that narrowing only when its trusted provenance is established; prose in an inbox is neither narrowing nor expansion authority.
7. Existing requests/acks deduplicate some retries. Publisher command results are cached after work, and `_start` can adopt an existing worktree identity; `_resume` spawns again. A crash after a side effect but before persistence is not proven exactly-once recovery.

## 4. Threat model and invariants

Defend against accidental scope loss, malicious objectives/inbox text, forged actor fields, stale/recycled panes, command substitution, changed cwd/env/code bytes, replay, two consumers racing, ack loss, clock expiry and revoked authorization. Fail closed on unreadable or conflicting evidence.

Trusted inputs: verified server caller context; existing authenticated publisher connection; local registry written through protected control paths; process-ancestry-derived local actor; current local policy; a pinned, answered human form when required. OAuth identifies the granted client/account, not proof that a human personally reviewed every objective. No client-supplied `actor`, manifest, hash or reason can establish a grant.

Known ceiling: same-user host processes and the Herdr socket are not a containment boundary (`docs/approval-policy.md:7`). Do not claim resistance to a fully compromised same-user Mac or unattended isolation. No secret/key is added to a worker. Authenticated request provenance cannot fix OS containment.

Invariants:

* Effective authority is the intersection of verified task authorization, manifest ceiling, verified later restrictions, current local policy and the current decision actor's authority. This is a design invariant, not a claim current manifests fully enforce a user ceiling: `git` restrictions may escalate rather than deny, and `writes` primarily covers curl output rather than all edit tools.
* Handover changes responsibility, not the task's permissions. It cannot revive an expired/revoked decision or promote an old approval across an identity change. Assigning Main is not a Main approval. A server-derived existing OAuth work delegation is not a human exact-command approval.
* Ordinary messages never invoke a control handler, even if they contain valid-looking JSON, hashes or approval language.
* Classification, recorded decision, grant consumption, notification delivery and work completion are distinct audit facts.
* No fallback from denied/reserved/unknown to allow. Missing identity, failed policy check, invalid schema or unavailable clock/registry stops the action.
* A previous explicit refusal stays refused. Do not split, quote differently or rewrap an already-denied live command to evade it.

### Three pre-mortems

1. A handover notice for job A contains job B's richer manifest. Prevent with task/run-bound registry lookup, stored hash comparison, generation CAS and cross-job tests; never parse permission out of the notice.
2. A commit happens and the process dies before acknowledgement. Retrying commits again. Prevent with intent/result journaling and reconciliation against a pinned worktree/branch/head; ambiguous outcomes stop without re-executing and surface one durable recovery item.
3. A compatibility fallback silently drops expiry or actor on an older publisher. Require explicit protocol version/capability agreement, deny unknown/new records and keep new handling disabled until both sides are reviewed and explicitly activated.

## 5. Alternatives and decision

| Option | Benefit | Cost / rejection |
|---|---|---|
| A. Repair continuity and explain the grammar miss; retain existing conductor review | Smallest fix, uses current permissions and exact-action policy | Some compound actions still need machine conductor review; zero human relay must be measured |
| B. Add a narrow compound-git recognizer | May remove a routine machine review | Security-sensitive shell grammar expansion. Do not widen shared `_cp_simple_words`; optional later AST recognizer only after separate review and evidence of need |
| C. Add remote approval via owner inbox or task scope | Superficially reduces relays | Rejected: converts untrusted data/start entitlement to new approval authority |
| D. New independent control service | Potential future isolation boundary | Rejected for this incident: duplicates existing transport, requires credentials/operations/security grants |

Choose A first. Preserve B as a measured follow-up, not a prerequisite. Typed context and review requests reuse the existing queue; no remote approve endpoint ships in the initial change. A request to review an action cannot decide it. If later evidence proves a new remote human-approval capability is necessary, design a distinct consent scope, target restrictions, authenticated human-intent proof and action-time activation proposal; current start/message scopes do not authorize it.

For future tasks whose original authority has been verified, the generated brief may recommend separate simple git operations as the documented accepted grammar. This guidance must come after provenance enforcement so simple/compound spelling cannot evade a hold. It is not permission to reissue a refused command. Existing blocked commands go through their existing review route.

## 6. Proposed contract (review before implementation)

### Task authorization context

Add versioned typed provenance to the existing start/resume command payload and persist its accepted local receipt alongside the existing task record. Fields: remote command ID/op, remote task ID and parent if resumed, verified requester actor/client, accepted task entitlement/version, repo and mode, objective digest, local allowlist/manifest digest, issued/expiry times and canonical payload digest. Use the server's caller data, not the objective. Treat objective bytes as untrusted work data; hashing does not authorize their contents. This binds the existing authenticated OAuth delegation to the specific command-to-task mapping, repository, objective and effective scope. Keep `requester`, `authorization_source` and `assigned_supervisor` separate in storage, audit and display. A hash shared by identical manifests on two tasks does not make their authorizations interchangeable.

The Mac validates schema, size, operation and current local allowlist before spawn. It computes its own manifest hash and records any mismatch/refusal. Persist the verified receipt before worker execution, then bind the actual local task/run/worktree/branch/worker birth transactionally before releasing the worker to act; if that binding cannot be established, refuse launch instead of running first and recording provenance later. The existing launch path must be traced for this timing gate during exact-plan review. The task context's original acceptance receipt remains historical evidence after the delivery lease expires; any later action grant has its own fresh expiry. This avoids expiring a running task merely because its spawn message lease ended.

Do not backfill authenticated requester identity from `.handoffs/SPEC.md`, `identity.json`, an inbox or a guessed parent. Existing verified manifest events remain useful local evidence; missing provenance is reported explicitly. Legacy context cannot acquire additional capabilities through migration.

One shared task-authorization check must gate ownership/scope grants in `peer_decide`, reviewed menu conductor approval in `herdr-select.sh`, hook conductor decisions in `herdr-action.sh`, and approved hook grant consumption in `lib/action-request.sh`/`lib/pretool-shadow.sh`. Missing or conflicting provenance is a non-overridable automated hold, not an ordinary `escalate` that a conductor may clear. Check even a previously approved request immediately before consumption. Keep decline and existing explicit human recovery available, but create no recovery grant in this job. Unknown origin stays unknown through handover and through a different command spelling. A local trusted human recovery decision may explicitly create a new bounded grant for a legacy task; it must be a new auditable decision, never a rewritten historical approver.

Minimum protocol admission is part of M1. The server must withhold receipt-dependent start/resume commands unless the authenticated publisher advertises the required protocol version; adding fields to a legacy `start` is insufficient because old `_start` ignores unknown fields. New receivers reject missing/unsupported receipt versions for this path. Persist unique command→remote-task→local-task binding, returning the same result on identical retries and refusing conflicting payloads. Adoption/recovery must use this protected binding, not worker-writable `identity.json`. Both mismatched-version directions must produce zero spawns. These controls cannot be postponed until after provenance issuance.

### Handover and acknowledgement

Expose a read-only authorization summary derived from the registry: task/run, repo/worktree/branch, manifest and hash, source receipt quality, active restrictions, original expected output, pending request IDs/hashes, and current conductor pane/birth. Reference it from the handover notification instead of treating notification prose as authority. Explicitly label `conductor_unknown`, missing birth, hash mismatch and absent source receipt as unverified; never display a green authorization state merely because manifest JSON exists.

Extend the existing transaction to advance a conductor epoch and append a structured handover receipt with unchanged authorization digest. The receiver rereads the summary and acknowledges the exact epoch/digest. A lost notice is retried/deduplicated from the event; no second handover is needed. No acknowledgement itself grants anything. Complete authorization data must remain inspectable if the notification is truncated. Existing hook requests use permanent `actsurf_<request-id>` claims (`herdr-action.sh:319`) while handover re-wakes only `input_required` menu events (`conductor-handover.sh:214`); key review-notification receipts to the conductor generation so an already-surfaced pending hook request reaches the new conductor once without creating new permission.

Invalidate unconsumed old-conductor one-shot approvals on handover; preserve declines. Pending requests can be reviewed by the new conductor under the same task ceiling. File approval lifetime must be explicit: retain only if existing grant semantics are demonstrably task-bound and current content/policy are revalidated; otherwise require a fresh review. Do not silently carry an old actor's authority.

### Exact action/control request

Reuse `action_requests`; extend rather than create a parallel approval store. A decisionable request binds:

`schema_version, request_id, task_id, run_id, action_sha256, tool, effective_cwd, code_sha256_if_any, authorization_digest, requester_actor/client, worker_pane/birth, conductor_pane/birth/epoch, issued_at, expires_at, idempotency_key, payload_digest`.

Reuse `pretool_action_sha` for execution-relevant tool input, including command/cwd/env. Confirm normalization with both clients; do not redefine hashing in two languages without shared golden vectors. Validate caller identity independently: use the existing ancestry primitive for a local actor, and separately record the verified remote client for provenance. The current environment-based actor check in `_ha_conductor_ok` needs security review against the ancestry path already used by handover; do not claim that an env string authenticates a pane.

A command hash does not bind git's index, HEAD, hooks or effective config. For a commit-specific approval, capture a reviewed execution-context digest (canonical worktree/git dir, branch and HEAD, index tree, relevant hook bytes and execution-affecting git config) and check it at consumption; changes force fresh review. Do not disable hooks to make the snapshot deterministic. M1 keeps the existing trusted-host review semantics and must state this limitation; any stronger security guarantee in M2 requires demonstrated context binding and an honest residual check-to-use race analysis.

Check action hash and current full command at decision time, then again immediately before atomic consume. Re-read active task, worker birth, conductor epoch, authorization digest, expiry, current deny/operator/reserved rules and code content hash. Any mismatch records a reason and refuses. A decision must not consume an approval for a different action or use a claim from ordinary inbox text.

Idempotency rules: same authenticated caller + key + identical canonical payload returns the original receipt without executing twice. Same key with different payload fails. A repeated refusal returns the same refusal, not a new form. Expired, stale or consumed approvals never run again. New reviewed decisions require explicit new generations; changing the command does not clear a prior denial for free.

### Recovery and auditable outcomes

Journal `received → validated → decided/refused → execution_claimed → consumed → result_recorded`; keep notification attempt/confirmed as a separate track. Use existing SQLite transactions and unique IDs. Do not claim transactionality across SQLite and git/PTY effects. A crash after claim but before a durable execution result produces `outcome_unknown`; reconcile task identity and pinned git head/worktree before any retry. If proof is insufficient, create one durable recovery item and stop.

Publisher restart resumes leases/acks from durable receipts. Duplicate command IDs return stored outcomes. Reconcile original and resumed task separately: resume gets a new task ID and an explicitly authorized subset; it never inherits consumed approvals. Herdr restart may issue new terminal IDs; use the existing corroborated agent-session reconciliation path, advance the epoch, and invalidate old action bindings. Never update a birth solely because a pane ID matches.

## 7. Authorized engineering milestones and gates

| Milestone | Exact work and likely files | Gate / deliverable |
|---|---|---|
| M0: ground and review | This plan; baseline evidence; relevant `.agents/skills`, repository rules and audits | Commit plan first; exact SHA to parent. Requested ultrathink lane and independent security verdict must be real, recorded and independent |
| M1: minimum provenance/continuity repair | `remote-mcp/worker/src/state.ts`/`types.ts`, `remote-mcp/publisher.py`/`tasks.py`, `spawn-task.sh`, `lib/run-registry.sh`, `lib/scoped-policy.sh`, `conductor-handover.sh`, `herdr-select.sh`, `herdr-action.sh`, `lib/action-request.sh`/`lib/pretool-shadow.sh` and existing verifier files | Separate requester/source/supervisor; strict protocol admission and unique receipt binding; atomic registration/receipt before every launch mode; shared hold on peer, menu conductor, hook decision and consume; preserve handover manifest; no new endpoint or classifier widening |
| M2: strengthen existing action lifecycle | `lib/action-request.sh`, `lib/run-registry.sh`, `herdr-action.sh`, `lib/pretool-shadow.sh`; existing request/handover tests | Hash/identity/expiry/epoch CAS, retained refusal and loss-recovery tests; no new remote approval power |
| M3: remaining transport/lifecycle hardening | Existing remote command queue and its TS/Python tests; reuse M1 source receipt | Broader side-effect/ack-loss reconciliation beyond M1's mandatory version admission and duplicate/conflict receipt binding; no parallel transport or new approval capability |
| M4: exact-head adversarial review | Separate reviewer reads final diff and executes negative corpus on fixture-only state | Zero unresolved HIGH/CRITICAL; findings and remediation pinned to final local commit |
| M5: permitted canary | Disposable synthetic repo/worktree, own registered test panes/conductor, explicitly bounded inspect/edit/test/local-commit/review scope | Action-time approval for any activation/production change; actual interruption report. No KB/Main takeover, no deployment during engineering |

Implementation begins only after M0 review. M1 does not require a new persistent grant. M2/M3 may be built and tested inactive under this task, but review cannot authorize their deployment. If a reviewer determines a milestone necessarily expands authority, stop that dependency and ask the parent with the exact capability and evidence; continue unaffected work.

Bound the first implementation to M1: preserve/authenticate existing delegation, correct attribution, hold unverified origins consistently, present authoritative handover context, and prove those paths with fixtures. Defer compound grammar, full action epochs/expiry/context digests and new acknowledgement machinery to separate reviewed slices. M1 alone must not claim the full acceptance matrix or completed live zero-relay repair. Registration already precedes `herdr pane run` (`spawn-task.sh:799`, `:911`); a receipt-backed menu launch must fail closed on registration failure, matching the existing hook launch safeguard.

No new API calls to paid model providers. Parent reports an independent Astra ultra architecture pass completed and supplied its findings; this engineering job did not invoke another model CLI. The parent subsequently supplied exact-plan GO at `212033cdc389283d8edd40c68af96b5229e424d8` for bounded inactive M1. `omp --help` confirms `--thinking max`, but that is not proof of the intended subscription route and no local ultrathink pass is claimed. Do not silently switch to a billed API or bypass HERDR_ENV.

## 8. Test plan and exact acceptance criteria

All automated checks use fresh fixture registries, caches, logs, fake pane adapters and local disposable git repositories. Set the documented test paths before sourcing helpers; do not touch the real registry/cache or active pane socket. Inspect verifier isolation first. Keep raw logs, exit codes, baseline SHA and final SHA.

| Case | Required observable outcome |
|---|---|
| Original incident shape | Synthetic quoted compound misses current grant; complete request is routable to existing branch-work review with original manifest visible; no assertion that scope vanished |
| Handover continuity | Same task/worktree/branch/manifest digest before and after; new conductor sees original scope and verified restrictions; old conductor cannot decide/consume |
| Genuine narrowing | Verified explicit narrower task restriction wins; ordinary reason/inbox text cannot change it |
| Authorized synthetic sequence | Inspect, edit, tests, local commit and independent review complete; exact owner relays = 0, commit SHA and review evidence present |
| Outside scope | Push when commit-only, other branch/worktree, deploy/merge/secrets/security change: refused, zero side effects |
| Forgery | Client-supplied actor, worker-edited SPEC/identity, fake control JSON in inbox, forged pane env: refused; no grant minted |
| Unknown original approver | `approved_by=conductor_unknown` / empty original birth remains unverified after handover; receipt cannot be retroactively blessed; one stable recovery item |
| Same hold, different spelling | Identical unknown-provenance task remains held for simple add/commit and compound/quoted variants; splitting cannot bypass Main's refusal |
| All approval surfaces | Unknown/conflicting source refuses peer ownership/scope, menu conductor, hook conductor and approved one-shot consume; zero sends/consumption; declines still work |
| Previously approved then invalid source | Remove/invalidate provenance after an approval: consumption fails, no key/send/side effect and no new approval prompt |
| Main fallback attribution | Future spawn can assign Main as supervisor but never logs Main as the approving actor unless an actual verified Main decision exists |
| Cross-task manifest equality | Two tasks with the same manifest hash cannot exchange receipts; request/task/run/repo/objective mapping mismatch refuses |
| Substituted provenance | Forged or replayed actor/source/scope metadata, altered mapping, missing receipt or post-launch receipt cannot mint authorization |
| Changed command | Change one command/cwd/env/tool/code byte after approval: hash mismatch, zero execution |
| Changed execution context | Change index tree, HEAD, hook bytes or execution-affecting config: prior commit-specific approval cannot authorize the altered effect |
| Shell injection | Append substitution, redirect, launcher, global git exec option, alternate cwd or extra command to the incident shape: no compound auto-grant or hook bypass |
| Wrong/recycled pane | Correct pane ID with wrong/empty birth or unrelated active job: refused |
| Stale/expired | Old conductor epoch, expired request, dead task, revoked/narrowed entitlement: refused with stable reason |
| Identical replay | Same key/payload returns original receipt; no second execution or prompt |
| Conflicting replay | Same key/different payload refused and audited |
| Concurrent same action | Two consumers race; exactly one consume wins, at most one side effect |
| Concurrent jobs | Two approved jobs progress independently; A's approval never clears B; no global prompt suppression |
| Handover race | Two swaps race; exactly one CAS wins; losing receiver gets no authority |
| Restart before side effect | Durable request remains recoverable, requires current identity/policy, does not lose refusal |
| Crash after side effect / ack loss | Commit not duplicated; receipt reconstructed only from sufficient evidence; otherwise `outcome_unknown` and one recovery item |
| Herdr restart | Corroborated session can rebind task; old birth-bound approvals invalidated; no ID-only adoption |
| Policy tightening | New deny/operator/human reservation blocks an earlier grant at consume time |
| Repeated refusal | Re-run unchanged denied request 10 times: same refusal, 0 new owner prompts, 0 execution |
| Audit failure | Required durable receipt cannot be committed: no action proceeds |
| Mixed versions / malformed schema | Unknown operation/version/extra privilege/invalid digest or time refuses; existing read/inbox paths unchanged |
| Receipt protocol admission | New issuer with old receiver withholds receipt-dependent work; new receiver with absent/unknown receipt version refuses; spawn counter is zero in both cases |
| Missing dependencies | Missing parser/interpreter, failed identity lookup or unavailable audit store fails closed with explicit evidence; never count a degraded test as a policy pass |
| False completion evidence | Delivered notification or pushed SHA alone does not satisfy tests/review; require actual test results and independently recorded review against the candidate commit |
| Real workers | No test sends, approvals, cancellations, state changes or file edits against KB panes/Main; verify via test transport logs and read-only fleet snapshot |

Regression suites: `verify-conductor-handover.sh`, `verify-owner-approval.sh`, `verify-scoped-approval.sh`, `verify-select-policy.sh`, `verify-run-registry.sh`, `verify-pretool-shadow.sh`, `verify-pretool-enforce.sh`; Python `remote-mcp/verify-tasks.py`, `verify-publisher.py`, `verify-owner-inbox.py`; Worker task and owner-inbox tests. Run focused suites per touched module, then the required policy regressions. Baseline unrelated failures must be distinguished from changes. Do not rename/wrap a rejected verification command to evade a control.

Every security test states the mutation that makes it fail (remove birth check, omit action hash, return allow for unknown schema, execute twice after lost ack). Use fake transport counters to prove zero side effects, not only an expected error message. Add tests to an existing gate that actually runs.

### Interruption accounting

Record separately: `owner_input_requests`, `owner_relays`, `owner_approval_prompts`, `conductor_reviews`, `policy_refusals`, `repeat_prompts`, `recovery_items`, `test_transport_sends`. Count from a defined start/end cursor and exact task IDs, with complete audit coverage. One initial bounded canary authorization is a setup decision; report it separately, never hide it in “zero.” Machine conductor reviews may be nonzero; owner relays within approved scope must be zero. Historical interruption counts are unknown and cannot be inferred from two stalled workers.

Current measurement: no live canary attempted, no owner approval issued, zero sends to KB/Main by this engineering job. These facts do not prove zero-relay workflow completion.

## 9. Migration, compatibility and rollback

Use additive versioned schema changes, transactionally stamp only after success, and test against populated v10 fixture databases. New columns on legacy rows default to missing/unverified, never authorized. Preserve manifests, refusals and historical events. Do not eagerly mutate the two current jobs. Any future legacy-task reconciliation must independently verify original local manifest and server task receipt; unresolved provenance requires one explicit recovery decision.

Separate delivery lease expiry from task scope lifetime; separate scope revocation from conductor handover. Protocol negotiation rejects new control records at old receivers rather than silently dropping bindings. Ship no active endpoint/tool registration, install mutation, launchd restart or changed global default during this job. Hook-mode implementation launch remains a separate reviewed activation decision; do not flip it to reduce test prompts.

Rollback before activation: retain the worktree/commits, remove no user data, and revert the isolated commits if requested. After any later approved activation: disable new handling through its explicitly reviewed switch, withdraw/invalidate unconsumed new grants and return to established local conductor review. Do not automatically drop audit tables, downgrade a database in place or replay old grants. Restore a database only through the existing verified backup/restore procedure under explicit operator approval. Reverting code must not let older code accept new unexpired grants without the new checks.

## 10. Open review decisions and completion boundaries

* Parent reports Astra ultra architecture review completed and independent exact-plan GO at `212033cdc389283d8edd40c68af96b5229e424d8` for inactive M1. Exact code `37a3dff28d4402eb5b509e7f59c72c43f0c6cbf6` subsequently received security and architecture CLEAR for bounded inactive M1; activation remains a separate gate.
* Independent reviewer should challenge M2's exact lifecycle and migration before implementation, especially file-grant lifetime, actor authentication and the consume/side-effect crash gap.
* Decide whether M1 alone meets the real canary without broader grammar recognition. Prefer the existing reviewed conductor route; a generic compound shell parser is outside the first fix.
* Canary activation scope remains unapproved. Current remote allowlist excludes `herdr-control`; do not alter it or use `knowledge-base` as a proxy. Ask the parent for an explicitly permitted isolated canary route when the reviewed candidate is ready.
* Legacy unknown grants need direct trusted recovery authorization. Main's current explicit refusal is authoritative for this workflow; the engineering patch must not silently bless the two current tasks or replay their blocked commands.
* This plan is not an approval for current real worker commands, a persistent security grant, a deploy or a completed implementation. Release acceptance remains open until exact-head review and actual permitted canary evidence exist.

## 11. Follow-on: unreadable menus and truthful progress

Parent supplied a further observation during M1: Main had been idle since 00:52:13 UTC with its inbox answered, while both workers had been blocked about ten minutes on routine closure/read-only commands. Automation refused wrapped or unreadable menus. Main's completed code reviews did not authorize further work: recap had 1 high/5 medium/2 low findings, finance 3 high/5 medium/3 low. These are reported observations; this engineering task did not inspect or answer the live menus.

Independent source diagnosis found four gaps. The OMP hook already receives `toolCallId`, but `notifyForPrompt` drops it. `omp-notify.sh` exits without recording an approval if its five screen checks fail. `attention-tick.sh` treats an unreadable prompt like an answered one, and the hub watchdog's denied-prompt rule considers `stalled` while a worker can remain `blocked`. A pure fixture aged 940 seconds returned no watchdog signal for `blocked`, but `denied` for `stalled`. The sweep also interpreted every selector exit 8 as clipping and recommended shorter commands. M1 removes that misleading advice and preserves the refusal; it does not reissue a held command.

The separately reviewed follow-on should preserve `(session, toolCallId, task, pane birth, tool, input hash)` as a durable observation even when the screen cannot be read. An observation is never an approval. Inventory, attention and selection should share explicit states: `pending_parseable`, `pending_unreadable`, `read_failed`, `correlation_mismatch`, `authorization_held`, `resolved`, and `unknown`. Unknown must not mean idle. Preserve exact current selector checks and retain the complete input for corroboration; do not guess highlighted options or relax parsing. Existing hook-mode exact requests may be used only for tasks already authorized and configured for that path.

Track unresolved occurrences across blocked/stalled states, restart and handover. Deduplicate notification by occurrence and conductor generation. Acknowledgement means receipt; resolution requires the matching completion, decline or withdrawal. An answered inbox, unrelated owner reply, review, delivered wake or idle Main is not evidence that the pending action resolved. Mark work runnable only after source authority, current policy and the exact action validate.

Acceptance for this follow-on: wrapped commands/footer/status rows, clipped headers/bodies, Unicode widths, unreadable highlights, forged panel text, unknown options, missing/delayed hook events, concurrent identical commands with distinct call IDs, recycled panes, changed commands, restart/ack loss and handover all retain one correct occurrence. Every unknown/mismatch path sends zero keys; repeated observations create no duplicate owner requests; unresolved work cannot be reported as “no prompts”, idle or completed. No new remote approval endpoint, worker posture switch or legacy grant repair is authorized by this diagnosis.

## 12. External code review: required M1 concurrency closure

The parent's exact-code review extends the inactive M1 acceptance gate with two concrete races:

* **Authority and action CAS:** validating provenance and then updating an action in separate transactions permits cancellation/source invalidation in between. The shared storage adapter must read current task/receipt and change only the exact request/action/run/task/tool/route tuple under one SQLite writer transaction. Approval and any resulting file grant belong to that same transaction. An invalidation committed first must produce no consumption and no allow result. A consumption committed first remains an auditable earlier authorization event; no database transaction can promise atomic rollback of an already-started external effect.
* **Resume lineage and worktree:** two distinct signed commands are not an idempotent replay; they may otherwise mutate the same retained branch concurrently. Worker admission will maintain a linear parent/child lineage in the existing task store, reject a second child of the same parent, and refuse using an unresolved child as a new parent. The local receiver and spawn path must reserve the exact worktree under the protected command receipt before ANSWER rollover, worktree creation/reuse or brief writes. A launch of unknown outcome never releases its reservation merely because its message expired or the remote row became terminal. Safe advancement requires authoritative prior-task closure plus verified original-pane absence/replacement; old or conflicting evidence remains held.

These are local correctness constraints, not new permissions. Tests must reproduce the original races before repair, exercise invalidation-first interleavings, distinct resume IDs and uncertain launch, and show successful authorized compound-menu delivery through the supported selector with isolated transport. The authorization, registry, negative ancestry and offline Worker suites must be referenced by an exercised CI gate; local fixture execution is not a hosted CI run or the permitted live canary.

Reservation scope: the initial implementation serializes authenticated remote intents and refuses already-registered active local occupants. A new nonremote/unmanaged spawn racing before its own registration does not participate in this same durable intent protocol. It must not be described as global worktree exclusivity; closing or operationally excluding that race is a preactivation gate. No live worker is used to test it in this task.
