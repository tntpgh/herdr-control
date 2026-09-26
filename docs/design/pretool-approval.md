# Pre-tool approval: the hook decides on the exact input

Status: **shadow** (2026-09-26). The hook computes and records a verdict for every
registered-worker tool call; nothing is enforced by it, and the approval menu,
`herdr-select.sh` and peer answering are unchanged. Cutover is Terrence's
decision after shadow data (§8).

## 1. Goal and metric

**Goal.** A spawned task finishes end to end — brief → PR → merged/deployed, or a
clean handoff — with **zero human prompts**, except genuinely human-reserved
actions, and those reach a human through **one** escalation channel (§4).

**Metric** (`scripts/shadow-compare.sh --autonomy [--days N]`, registry read-only):

- `share_completed_zero_human`: of tasks created in the window that reached
  `completed`, the share with no human input.
- `human_prompts_per_task`, `conductor_prompts_per_task`, `auto_approvals_per_task`.
- Human input on a task = approvals rows with `authority=human` + `approval_escalated`
  with `verdict=reserved` (human-only by definition) + `attention_form_served` +
  `wake_fail_alerted`. Rows are attributed by `task_id`, or by the task's pane during
  its lifetime (the peer path records an empty `task_id`, backlog v). A reserved prompt
  refused on several retries counts each time, so this errs high.

**Baseline, 2026-09-19 → 2026-09-26** (79 tasks, 52 completed):

| metric | value |
|---|---|
| completed with zero human input | 18 of 52 = **34.6%** (22.8% of all 79 tasks) |
| human prompts per task | **5.06** |
| conductor prompts per task | 1.13 |
| auto (peer/grant) approvals per task | 42.14 |

Answering 42 menus per task automatically is the work the scrape/correlation layer
does, and it is where nearly every one of today's bugs lived.

## 2. Why: the bugs are in the correlation layer, not the policy

Today: omp paints a menu → herdr scrapes the pane → the scrape is matched to the
omp hook's record by a `prompt_id` hashed from panel text → `lib/command-policy.sh`
judges the text → `herdr-select.sh` presses a key. Found live on 2026-09-26
(`.handoffs/notepad.md`): mid-token wrap mismatches stranding prompts (ix);
parallel tool calls recording command B under A's prompt_id, so Approve was
pressed on `gh api -X PUT …/merge` while the row said `ls` (event 38070, PR #162);
one prompt_id on 190 events across 40 tasks (`lib/prompt-parse.sh` `prompt_id`);
duplicate wakes (vii); edge peer-answer racing the hook's `input_required` write (x).

omp's `tool_call` hook already receives the **exact** tool input before execution,
fires before the approval decision (the #3b input cache depends on that order), and
can return `{block: true, reason}`; a throwing handler fails closed
(`omp://hooks.md`). `lib/pretool-registration.sh` and #159's write-scope guard
already block this way. The hook can judge the bytes that will run, with no
screen, hash, or keypress in between.

## 3. Tool policy table

Sources: `omp --help` tool list (v18.3.2), `omp://tools/*.md`, and the tools
workers actually called (164 worker sessions under `~/.omp/agent/sessions/*herdr-worktrees*`:
read 5504, bash 5312, edit 2229, grep 1787, write 903, todo 755, hub 327, glob 245,
**eval 244**, wait 100, task 38, web_search 24, learn 9, xd_notepad_* 2, ask 1;
`write xd://…` devices: notepad_append 42, lsp 18, notepad_read 18, pr_ready 3,
browser 3, recall 1, report_issue 1).

Policies: **verdict** = `lib/scoped-policy.sh peer_decide` (manifest ceiling → #3b
grant → `classify_command` → human-reserved list → manifest scope → code by
reference; the same function `herdr-select.sh` and `lib/alert-gate.sh` call).
**#159** = containment already enforced by `workerWriteScopeBlock` (PR #159).
**overlay** = switched off for workers by a spawn-time omp `--config` overlay at
cutover (`tools.approval.<tool>: deny`), with the hook as the backstop.

| Tool (name as omp emits it) | Policy | Hook-time verdict |
|---|---|---|
| `bash` / `shell` | verdict | peer_decide on `input.command`, exactly the text the menu path judges |
| `edit`, `write` (file path), `ast_edit`, `multiedit`, `notebook*`, `lsp` (mutating actions), `apply_patch` | #159 | allow unless #159 blocked (then `block`, logged as the verdict) |
| `write xd://notepad_append` / `notepad_priority`, `xd_notepad_*` tools | #159 (notepad file) | same |
| `read`, `grep`, `glob`, `find`, `ast_grep` | allow + credential check | allow; `reserved` when the path matches the reserved list's **credential** class (`conductor_reserved_reason "cat -- <path>"`, only its `credential-value` answer is used — its policy-filename rules are about editing and would reserve reading, backlog iii); `ssh://` → block |
| `read` of `http(s)://`, `web_search` | allow | allow (a GET; same as today — `net_read` is not manifest-enforced for these, see §7) |
| internal URLs (`skill://`, `rule://`, `artifact://`, `agent://`, `history://`, `pr://`, `issue://`, `local://`, `mcp://`) | allow | allow |
| `todo`, `wait`, `ask`, `checkpoint`, `rewind`, `hub`, `resolve`, `security_scan`, `new_context`, `context_notes`, job observers | allow | allow |
| `learn`, `retain`, `recall`, `reflect`, `report_issue` | allow | allow (omp memory, not a host action) — see open question 4 |
| read-only devices: `fleet_status`, `pr_ready`, `handoff_debt`, `single_copy_scan`, `worktree_debt`, `suite_wired`, `decisions_open`, `project_status`, `notepad_read`, `notepad_stats` | allow | allow |
| `secret_present` | reserved | human-only: workers hold no credentials |
| `memory_edit` | block | forgetting/invalidating shared memory is the conductor's |
| **`eval`** (py/js), `python` | overlay + block | block — see below |
| `browser`, `computer`, `debug` (DAP), `xd://browser`, `xd://debug` | overlay + block | block: drive processes/sessions with no text to judge |
| `generate_image`, `tts` | overlay + block | block: new spending is human-only |
| `manage_skill`, `ida` | overlay + block | block |
| `github` | split by `op` | `repo_view`/`file_read`/`search_*`/`run_watch` allow; `pr_create`/`pr_push`/`pr_checkout` block with "use bash `git`/`gh`" so the #3b grant judges the exact command (tool is off by default) |
| `task`, `agent`, delegation-shaped names | existing registration guard | block (unchanged; `lib/pretool-registration.sh`) |
| `mcp__*` | existing registration guard | read-only observer names allow; everything else is already blocked |
| unknown tool / unknown `xd://` device | escalate | a conductor reviews it (fail closed) |

**eval: disable for workers.** eval executes arbitrary Python/JS with no shell text
to classify; omp's own doc says a `bash.patterns` deny "does not apply to the same
command run through eval"; eval-prelude calls (`browser.open`, `tool.*`,
`computer.*`) are host-bridge calls that emit **no** `tool_call`, so the hook could
not see what an approved cell does. The replacement already exists and is stronger:
write the code to a file under the worktree and run it with `bash`/`python3` —
code by reference judges the file's whole content and binds any conductor approval
to its sha256 (D2). Cost: 244 worker eval calls in history must become files. This
is firstmate's shape (`.omp/fm-worker-overlay.yml`), applied only to the tools the
hook cannot judge.

## 4. The one escalation channel (no menu)

Enforcing-mode behaviour (design; not built this turn):

1. **Worker side.** The hook returns `{block: true, reason}` for `escalate` /
   `reserved`. Before returning it appends, with `claim_once`, an
   **`action_requested`** event keyed `actreq_<task>_<sha256(tool,input)[:16]>`:
   `{request_id, tool, command (exact), command_sha256, input_sha256, cwd, verdict,
   reason, route: conductor|human, code_path, code_sha256, pane, pane_birth}`.
   The deterministic id makes a retried identical call the same request (the
   denied-3×-then-redirect loop, backlog viii). The reason tells the worker:
   *"not run — <reason>. Requested as <id> for your conductor (or: human-only).
   Do not retry it or work around it; continue other work or end your turn; the
   answer arrives as a message in this pane."* `deny` and `block` get a reason
   and no request (nobody may approve them).
2. **Surfacing** (existing surfaces only): `lib/reconcile.sh` PASS 3 adds
   `action_requested` to its whitelist (owning conductor, cursor-acked);
   `lib/push-wake.sh` wakes the conductor pane exactly as `input_required` does
   today; `route=human` goes to the existing alert path (`lib/alert-gate.sh` →
   Slack / formserve decisions portal); the hub lists open requests (no
   `action_decided` yet).
3. **Deciding.** One script, `herdr-action.sh <request_id> approve|decline
   --authority conductor|human --review-category … --review-reason …`, applying
   today's `herdr-select.sh` authority rules unchanged: conductor authority needs
   the owning registered pane and cannot approve `reserved`; human authority is
   attributable. Approve writes a one-shot **grant** bound to
   `(task, tool, input_sha256)` — or, for code by reference, the existing
   `file_approval_record(task, realpath, sha256)` — plus an `action_decided` event
   (also recorded in `approvals`, `authority` as today). Decline writes
   `action_decided` with the reason.
4. **Worker learns.** `send-to-agent.sh` types `[HERDR-ACTION] <id> approved —
   re-issue the identical call` or `… declined: <reason>` into the worker pane
   (typed delivery with submit verification; the worker is idle, no menu). The
   re-issued call's hook finds the unused grant for that exact `input_sha256`,
   consumes it, and allows. A different byte changes the hash, so a grant cannot
   be stretched to another command — the property the scrape path lacked.

There is no second control plane: registry events, the approvals table,
push-wake, reconcile, alert-gate/formserve and send-to-agent already exist.

## 5. Identity (fail closed)

- A session is a worker only if spawn-task.sh stamped `HERDR_TASK_ID` and
  `HERDR_RUN_ID`. The hook reads them and `HERDR_PANE_ID` **once, at module load**
  (as #159 does), so a later in-process `process.env` edit cannot un-register it.
  No `HERDR_TASK_ID` → the shadow code returns before doing anything (Main and
  Terrence's own sessions: zero cost, zero events).
- `lib/pretool-shadow.sh` then requires: `HERDR_RUN_ID` and `HERDR_PANE_ID` set; the
  registry readable; a row for `(run, task)`; state `starting|running|blocked`;
  row `pane_id == HERDR_PANE_ID`; the live `herdr pane list` generation equal to the
  row's `pane_birth` (a missing reading is a failure here, unlike push-wake, because
  an enforcing hook cannot ask a human). Any failure → verdict `block`,
  policy `identity`. identity.json is never read.
- Handlers never throw: the shadow call is inside try/catch, spawns detached with
  error listeners, and cannot change the guards' return value. In enforcing mode a
  crash in the lib is a block (omp fails closed on a throwing handler; the hook maps
  a non-zero/garbled lib result to `block`).

## 6. Grants at hook time

- **#3b ownership grant** and **manifest** (ceiling + scope): unchanged — they are
  inside `peer_decide`, read from the registry row.
- **Code by reference**: `peer_decide` already returns `allow` for a file whose
  `(task, realpath, sha256)` is in `file_approvals`. Today that row is written when
  a conductor presses Approve on the menu; at cutover it is written by
  `herdr-action.sh approve` on the request (§4) — an out-of-band conductor grant
  bound to the sha. Changed bytes → a new request.
- **Improvement available only at hook time** (not in shadow, to keep parity): the
  hook knows the bash tool's exact `cwd`, so `bash tmp/x.sh` with `cwd=<worktree>`
  can be judged by reference instead of escalating as unresolvable (the D6 /
  2026-09-26 trap).

## 7. Threat model delta vs today

Weaker:
- **No human or conductor sees each command.** Today a person can glance at any
  menu; after cutover an `allow` runs unseen. Allowed calls are the ones peer
  automation already presses Approve on (42/task), so the practical loss is the
  rare menu a human happened to watch.
- The hook runs inside the worker's omp process. A worker that can edit the
  extension file or the registry defeats it — the same limit as today's
  `herdr-select.sh --authority` (approval-policy.md rule 7). Workers must not hold
  the herdr socket, 1Password, or host credentials.
- Anything omp runs without a `tool_call` (eval prelude bridges, subagent
  internals) is invisible — hence eval/browser/task disabled for workers.
- `read http(s)://` and `web_search` stay unscoped GETs (exfil by query string),
  as today.

Stronger:
- The verdict is on the **exact bytes that execute**, not a wrapped/clipped scrape;
  the parallel-call mis-attribution (38070), prompt_id collisions, wrap
  mismatches and peer/hook races disappear rather than being patched.
- Every tool call is judged, including write-tier tools the menu never showed
  (`read ~/.ssh/*`, `secret_present`, paid APIs) and eval, which the menu judged
  as panel text.
- Grants bind to `input_sha256`, not to "the prompt currently on screen".

## 8. Shadow → canary → default, and rollback

Built now (this PR):
- `lib/pretool-shadow.sh`: the verdict, identity checks, redaction; `--record`
  appends `pretool_verdict` `{schema, mode:"shadow", tool, call_id, verdict, policy,
  reason, authority, command (redacted, ≤2000 chars; withheld when the policy
  says it carries a credential), command_sha256, input_sha256, cwd, pane,
  code_path, code_sha256, elapsed_ms}` with event id `ptv_<task>_<sha(call_id)>`.
  Raw tool input and file contents are never stored.
- `agent-hooks/omp-herdr-control.ts`: `onToolCall` computes the guards' result as
  before, calls `recordShadowVerdict(event, ctx, result)` (detached, stdin payload,
  module-load identity) and returns `result` unchanged.
- `hub.py` leaves `pretool_verdict` out of its recent-events feed (one row per tool
  call would bury everything else); `lib/reconcile.sh` already ignores unknown types.
- `scripts/shadow-compare.sh` joins verdicts with approvals / approval_escalated
  (by command sha or collapsed text, never prompt_id) and lists every
  disagreement; `--autonomy` is the §1 metric.
- The menu, scrape, `herdr-select.sh`, edge peer-answer and alert gate are
  untouched — both paths stay available (Terrence, 2026-09-26).

Exit criteria for shadow: a week of worker traffic with zero `SHADOW_LOOSER` rows
that a reviewer cannot explain, `elapsed_ms` p95 recorded, and every
`SHADOW_TIGHTER` row either accepted or turned into a policy fix in
`lib/command-policy.sh` (one policy).

Canary: one spawned task with an explicit `spawn-task.sh --pretool-enforce` flag
(stored on the registry row, so a relaunch keeps it): omp launched with
`--auto-approve --config <worker overlay>` (`tools.approval.eval|python|browser|
computer|debug|generate_image|tts|manage_skill: deny`) and the hook in enforcing
mode for that task only (the hook reads the flag from the **registry row**, never
the environment). Default: flip the spawn default after the canary's task closes
end to end; the flag remains to opt a task back into the menu path.

Rollback: spawn without the flag (new tasks use the menu again); a running
enforcing task is relaunched without it. The menu path is not deleted until the
default has held for a period Terrence chooses.

Retired at cutover, **for enforcing workers only** (kept for menu-path tasks,
Claude/codex panes and `ask` prompts until the default holds):
- `agent-hooks/omp-herdr-control.ts`: `inputByCallId`/`cacheBashInput`/
  `rawBashCommand` (the untruncated-command channel for the menu).
- `agent-hooks/omp-notify.sh` approval branch → `input_required` for tool menus.
- `lib/prompt-parse.sh`: `prompt_id`, `prompt_menu_*`, `prompt_command_text`,
  `prompt_command_torn` as approval inputs.
- `lib/scoped-policy.sh` `approval_command_text` (corroboration) and the
  registry-corroboration block in `herdr-select.sh`.
- `peer-answer.sh` / `agent-edge.sh` peer answering and `sweep-approvals.sh` for
  those panes; `lib/alert-gate.sh` grace holds keyed on prompt_id; the
  approval-prompt half of `attention-tick.sh`.

Stays: `lib/command-policy.sh`, `lib/scoped-policy.sh` `peer_decide` /
`code_ref_inspect`, `lib/task-manifest.sh`, `lib/run-registry.sh` (approvals and
file_approvals), `lib/push-wake.sh`, `lib/pane-guard.sh`, `send-to-agent.sh`,
`herdr-select.sh` for `ask` questions and non-hook agents,
`lib/pretool-registration.sh`, #159's write scope.

## 9. Measured

- Hook handler cost (the only latency added to a tool call in shadow): bash/eval
  calls 3–12 ms including the detached spawn (verify-pretool-shadow.sh); non-worker
  sessions return before any work.
- Lib cost (what an enforcing, synchronous hook would add): recorded per call as
  `elapsed_ms` (hook fire → verdict, includes bash start, registry read, `herdr pane
  list`, peer_decide). Offline, 42 bash calls over 14 canary commands (3 runs each)
  with five verify suites running concurrently: p50 590 ms, p95 636 ms, max 707 ms.
  Idle, a simple `peer_decide` is ~340 ms. Under the 1 s p95 budget, but an
  enforcing hook should keep one long-lived evaluator rather than a bash per call.
- A shadow event can be lost if omp exits within milliseconds of the call (the
  detached child reads its payload from a pipe). Shadow data only; not a gate.

## 10. Open questions for Terrence

1. Cutover itself: auto-approve + enforcing hook for a canary task, after how much
   shadow data?
2. eval off for workers (files + code by reference instead): acceptable friction?
3. `read`/`web_search` over HTTP stay unscoped as today — scope them to the
   manifest's `net_read`, or leave it?
4. `learn` writes lessons future sessions load (including Main's). Allow, or
   route lesson text to the conductor?
5. Human-route requests: Slack only, or also a formserve decision (durable,
   expiry ≠ decline)?
