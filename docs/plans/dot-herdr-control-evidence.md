# Evidence for the dot → Herdr plan

Baseline: `4f071ad0454bb5fcb1d835872bd6705064207c3f`. Date: 2026-10-10 UTC.
This is planning evidence, not implementation verification or canary acceptance.

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

Subsequent parent reviewer finding is also incorporated: assigning Main as supervisor can be logged as apparent manifest approval even without a Main decision; simple ownership fast paths do not check original approval provenance. The proposed first slice now includes separation of requester/source/supervisor, pre-execution task-bound provenance and identical unknown-provenance holds on simple/compound commands. Merely adding handover guidance is insufficient. No exact-plan acceptance has yet been received.

## Interruption accounting

No live canary ran. Workflow owner-relay count: **not measured**. Historical owner interruption count: **unknown**. No zero-relay success claim is made.

Worktree creation and local git metadata writes use the execution environment's auto-review mechanism because the common git directory is outside this task's writable root. No human response was required in this thread. No owner approval, message to KB/Main, canary launch, merge, deploy, persistent access change or live grant was issued. A progress/clarification message to the source task through the local task API failed with `thread not found`; it did not deliver. Final task output is the supported parent handoff.

## Pending

Exact-plan review; an approved implementation slice; a permitted fixture environment; exact-head adversarial code review; and an explicitly permitted live canary route. No implementation has started.
