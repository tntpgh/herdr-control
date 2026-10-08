# Pre-tool approval: the hook decides on the exact input

Status (2026-09-27): **shadow for every worker; enforcement merged but OFF by
default** (PR #170, after Terrence accepted the §12 same-user residual). The
hook records a verdict for every registered-worker tool call.
Enforcement exists only behind `spawn-task.sh --approval hook` (§11), which no
default or existing spawn uses; the approval menu, `herdr-select.sh` and peer
answering are unchanged for every other task. Terrence answered the cutover
questions on 2026-09-27 (§10); the first canary waits for the q1 gate
(`scripts/shadow-compare.sh --gate`) and is scheduled by Main.

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
| `hub` | split by `op` | `wait`/`inbox`/`list`/`jobs`/`logs`/`cancel`/`stop`/`send` allow; `start`/`restart` launch a program, so `application` + `args` are judged by peer_decide like a bash command (a service `env` escalates); any other op escalates |
| `write proc://<job>` | verdict | the text written to a job's stdin is judged as a command |
| `write` to any other URL scheme | escalate | except `agent://`, `local://`, `file://` (#159 containment) and `xd://` (device table); schemes are matched case-insensitively (`Xd://` is `xd://`) |
| `todo`, `wait`, `ask`, `checkpoint`, `rewind`, `resolve`, `security_scan`, `new_context`, `context_notes`, job observers | allow | allow |
| `learn` | conductor (q4) | escalate → an action request routed to the conductor; the lesson is saved only after review |
| `retain`, `recall`, `reflect`, `report_issue` | allow | allow (omp memory, not a host action) |
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

Enforcing-mode behaviour (built 2026-09-27, behind `--approval hook`; §11 has the
as-built differences):

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
3. **Deciding.** One script, `herdr-action.sh approve|decline|supersede <request_id>
   --authority conductor|human --review-category … --review-reason …`, applying
   today's `herdr-select.sh` authority rules unchanged: conductor authority needs
   the owning registered pane and cannot approve `reserved`; human authority is
   attributable. Approve writes a one-shot **grant** bound to
   `(task, tool, input_sha256)` — or, for code by reference, the existing
   `file_approval_record(task, realpath, sha256)` — plus an `action_decided` event
   (also recorded in `approvals`, `authority` as today). Decline writes
   `action_decided` with the reason. Supersede cancels one exact request without
   granting execution; it requires decline-capable authority, the request's
   `action_sha256`, and a nonblank reason. A later identical call creates a fresh
   pending request, unlike decline's persistent refusal.
4. **Worker learns.** `send-to-agent.sh` types `[HERDR-ACTION] <id> approved —
   re-issue the identical call`, `… declined: <reason>`, or `… SUPERSEDED:
   <reason>` into the worker pane (typed delivery with submit verification;
   the worker is idle, no menu). Only an approval grants execution. The
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
  stores a `pretool_verdict` row `{schema, mode:"shadow", tool, call_id, verdict,
  policy, reason, authority, command (redacted, ≤2000 chars; withheld when the
  policy says it carries a credential), command_sha256, input_sha256, cwd, pane,
  code_path, code_sha256, elapsed_ms}` keyed `ptv_<task>_<sha(call_id)>`. Raw tool
  input and file contents are never stored. Redaction covers token shapes,
  Authorization headers, `curl -u user:pass`, `mysql -p…`, `sshpass -p`,
  `--password/--token/--api-key` values, `*KEY/TOKEN/SECRET/PASSWORD*=` in any case,
  URL userinfo and private-key blocks.
- **Storage: a separate file**, `pretool-shadow.sqlite3`, beside the registry
  (table `pretool_verdicts`). The shadow reads the control-plane registry
  read-only and never runs `registry_init`, so a burst of parallel tool calls
  cannot hold the registry lock against push-wake, the alert gate or
  herdr-select, and never enters `events_since`'s 500-row window or the hub's
  event feed. (Review of PR #164 measured 7 of 62 rows dropped and live writers
  at risk when the rows went into `registry.sqlite3`; with the separate file a
  64-call burst plus a concurrent live writer recorded 64/64 and 20/20.) At
  cutover, `action_requested`/`action_decided` DO belong in the registry: they
  are low-volume and are what reconcile and push-wake consume.
- `agent-hooks/omp-herdr-control.ts`: `onToolCall` computes the guards' result as
  before, calls `recordShadowVerdict(event, ctx, result)` (detached, stdin payload,
  module-load identity) and returns `result` unchanged.
- `scripts/shadow-compare.sh` joins verdicts with approvals / approval_escalated
  (by command sha or collapsed text, never prompt_id) and lists every
  disagreement; `--autonomy` is the §1 metric. Every join is bound to the call:
  bash by command sha or collapsed text (omp's `Allow tool: bash ; Command:`
  prefix stripped), other tools by the tool the panel names. `approval_escalated`
  records the captured `command` since 2026-09-28; an older event without one
  joins nothing (pane + time alone produced most of the 41.7% first-gate
  disagreement). The `via` column says which join produced each row.
- The menu, scrape, `herdr-select.sh`, edge peer-answer and alert gate are
  untouched — both paths stay available (Terrence, 2026-09-26) — except that
  `approval_escalated` now records the command (2026-09-28), and `--gate` check
  (e) FAILs while any command-less escalation is still inside its window.

Exit criteria for shadow: a week of worker traffic with zero `SHADOW_LOOSER` rows
that a reviewer cannot explain, `elapsed_ms` p95 recorded, and every
`SHADOW_TIGHTER` row either accepted or turned into a policy fix in
`lib/command-policy.sh` (one policy).

Canary: one spawned task with an explicit `spawn-task.sh --approval hook` flag
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
  with five verify suites running concurrently: p50 590 ms, p95 636 ms, max 707 ms;
  the same set with the machine otherwise quiet: p50 410 ms, p95 445 ms, max 474 ms. Under the 1 s p95 budget, but an
  enforcing hook should keep one long-lived evaluator rather than a bash per call.
- A shadow event can be lost if omp exits within milliseconds of the call (the
  detached child reads its payload from a pipe). Shadow data only; not a gate.

## 10. Terrence's decisions (2026-09-27)

Answered on the hub form `20260927T001841-8741` (`answered_via: hub`); every
recommended default was taken, no notes.

1. **Canary gate:** start the 3-job canary only after **5 days** of shadow data
   AND **≥ 1,000 shadow rows across ≥ 5 tasks**, with **≤ 2 % disagreement**, and
   **every `SHADOW_LOOSER` row explained by hand**. Checked by
   `scripts/shadow-compare.sh --gate` (explanations: `<seq>\t<why>` lines in
   `~/.local/state/herdr/runs/shadow-explained.tsv`). Default after the canary
   only if: zero reserved actions ran without a yes; ≤ 1 human question per job
   (vs 5.06 baseline); no worker retries a blocked step more than once; every
   handoff answered through the one channel and picked back up automatically.
2. **eval / python / browser / debugger off for workers** (scripts run via bash
   under code by reference instead), accepting the cost of the 244 historical
   eval calls. Built as `agent-hooks/omp-worker-overlay.yml`, applied only with
   `--approval hook`.
3. **Web reads stay unscoped for now** (`read http(s)://`, `web_search`); revisit
   after the canary.
4. **`learn` goes to the conductor**: an action request; saved only if approved.
5. **Human-route requests: Slack plus a durable hub decision form**; expiry is
   never a decline.

## 11. As built: enforcement behind `--approval hook` (2026-09-27)

Nothing here runs for a task spawned without the flag.

- **Spawn** (`spawn-task.sh --approval menu|hook`, default `menu`): `hook` is
  validated before any side effect — managed omp launch only (claude/codex/omp
  flavors), effective posture `write` only (a stricter floor or yolo refuses
  rather than being re-interpreted), overlay present — and otherwise the spawn
  is refused. It replaces `--approval-mode write` with
  `--auto-approve --config agent-hooks/omp-worker-overlay.yml`, stamps
  `HERDR_APPROVAL=hook`, and passes `approval=hook` to `register_task`, which
  stores it on the row (schema v6 `tasks.approval`, default `menu`) and records
  an `approval_posture` event. Nothing updates the column afterwards, so a
  relaunch in that pane keeps it. A hook worker whose registration fails is never
  launched. A default spawn's `--dry-run` output is byte-identical to before.
- **Hook** (`agent-hooks/omp-herdr-control.ts`): enforcement is on only when the
  task's **registry row** says `approval=hook` (read once per session, cached once
  it answers). `HERDR_APPROVAL=hook` in the launch environment can only tighten:
  it turns enforcement on so that an unreadable registry or a disagreeing row
  refuses every call. The existing guards (fleet registration, #159 write scope)
  still run first. Then `lib/pretool-shadow.sh --enforce --record` runs
  synchronously (20 s timeout) on the exact input; any failure blocks. A
  registered worker whose omp was launched with `--auto-approve` (or its alias
  `--yolo`) — what `--approval hook` emits — is always enforced, whatever the
  row read says; the lib then refuses if the row does not say `hook`. A
  yolo-POSTURE menu spawn (`--approval-mode yolo`) is unchanged. The row is read
  with a single SELECT on the plain path (no `registry_init`; not `-readonly`,
  which cannot open a WAL database whose -wal/-shm files are absent), retried, so a lock race cannot flip a hook row to
  unenforced (seen once in testing before this change).
- **Verdict → answer**: allow runs; `deny`/`block` are refused with no request;
  `escalate`/`reserved`/`learn` look up `action_requests` for
  `(task, action_sha256)` — an approved one-shot grant is consumed (check-and-set
  UPDATE; exactly one of N parallel identical calls runs) and the call runs; a
  pending request blocks as "still waiting"; a declined one blocks with the
  reviewer's reason and is not re-requested; a superseded one cannot be consumed
  and re-escalates as a fresh pending request. Otherwise a new request is created
  (deterministic id, so parallel identical calls make one row) and the conductor
  is woken immediately. `action_sha256` covers the execution-relevant input only
  (bash: command, cwd, service env/name; other tools: the whole input minus the
  model's free-text `i`), so a rephrased intent still matches and one changed byte
  does not.
- **Deciding** (`herdr-action.sh approve|decline|supersede <id>`): conductor
  authority as in `herdr-select.sh` (caller pane = registered conductor pane
  with a live matching generation, active task; approval needs an operational
  category + reason and a conductor-route request). Decline and supersede may
  cancel human-route/reserved requests too, because neither runs the action.
  Supersede requires `--action-sha256 <request's action_sha256>` and a nonblank
  reason. Human authority requires an **answered, pinned hub form for exactly
  that request** (`--form <id>`) with the matching `action_sha256` for approve,
  decline, and supersede; cancellation additionally requires a nonblank reason.
  Approve records a one-shot grant, or for a code-by-reference script a
  `file_approvals` row bound to its reviewed sha256.
  Supersede records no grant of either kind. Decisions write an `approvals` row
  and `action_decided` (request id, action SHA, authority, reviewer, reason,
  form record and `form_outcome`; event timestamp), and notify the worker after
  a pane-generation check. A conductor decision also retires the open human
  form under the same record lock as withdrawal, resolving it by `form_path`
  if not yet pinned; already-answered or expired forms are preserved. A human
  answer losing the request-decision race is audited as `kept:answered:<decision>`.
- **Abandoned research action**: the existing form under `runs/action-forms/`
  offers “Cancel this request (worker moved on)” alongside approve and decline,
  with no default choice. Cancellation records `superseded`, not approved.
  Request age, an idle/done pane, a passing `ANSWER.md`, and form expiry never
  decide the request. `publisher.py` already selects only `status='pending'`;
  superseded and declined rows therefore clear `has_pending_request` on the
  next snapshot. Another pending request still blocks, even when the task has
  historical `input_required` events: the newest pending request supplies the
  blocker's tool, summary and since, overriding the historical menu ask. Pending
  membership is computed separately from presentation. The research
  orchestrator's answer validation and F1/F2 live-pane/closure gates remain
  unchanged. Terminal task withdrawal below
  is distinct from a worker pane merely reporting done.
- **Withdrawal** (`herdr-action.sh tick`, 2026-09-29): a pending request whose
  task is terminal (`completed|failed|cancelled|lost`) becomes `withdrawn`
  (authority `system`, event `action_withdrawn`) and its form record, if still
  `open`, is flipped to `withdrawn` under `lib/record_store.py`'s lock — an
  answered or expired record is never overwritten. Before this the tick skipped
  inactive tasks, so such requests stayed pending forever and their forms stayed
  listed on `/decisions` where an answer did nothing. A missing or unreadable
  task row is left pending, never guessed at.
- **Surfacing**: conductor route — `herdr-action.sh surface` wakes the conductor
  pane once (from the hook, detached; the hub's tick is the backstop).
  Human route — reserved requests, or conductor requests still pending after
  `HERDR_ACTION_STALE_S` (900 s) — the hub's tick (`hub.py` `_action_tick`, every
  15 s, one read-only query when nothing is pending) posts one Slack alert at
  class `human-action` (`lib/slack-level.sh`: an error class, posted at the
  default level) and serves a formserve decision; an answered form is applied as
  human authority. An answered legacy form without `action_sha256` is rejected:
  `action_form_rejected` records its request, form record and
  `reason: missing_action_sha256` once per form, and the CLI/tick emits a clear
  stderr line. The request stays pending; an explicit conductor decision is
  needed, not an automatic re-serve or grant from an unbound answer. An expired
  form is recorded as `action_form_expired` and re-served — never a decline.
  `lib/reconcile.sh` reports `action_requested` to the owning conductor at
  session start.
- **Review round 1 (2026-09-27, two independent reviewers) and what changed**:
  - *Self-approval*: a worker's allowed bash could UPDATE `action_requests`,
    forge a form record, or edit the gate files (`lib/pretool-shadow.sh`,
    `lib/action-request.sh`, `herdr-action.sh`, the hook, the overlay). Now
    `lib/hook-approval-rules.tsv` joins the ONE policy through its operator-rule
    channel (tighten-only; a match is human-only) for hook workers and shadow;
    enforce refuses when the rules file is missing. A grant is consumed only if
    its authority could have made it (human for a human-only request;
    conductor only for a conductor-route request). A human decision counts only
    from the formserve record pinned when the hub served that request's form.
  - *Script swap*: a grant now folds the sha256 of any script the command
    runs (code_ref_inspect; an explicit tool `cwd` resolves relative scripts);
    a rewritten script no longer matches. A script that cannot be resolved,
    or that runs other local files, is refused with no request.
  - *Hidden cwd/env*: the review text is `(in <cwd>) <command>` plus
    `[env] …`; a bash call that sets a service env escalates.
  - *`hub start`* ran any program unjudged — now judged as a command (above).
  - *Mixed-case schemes* (`Xd://secret_present`) and `file://` reads bypassed
    the table — schemes are lowercased; `file://` is decoded; a glob pattern is
    judged as a path (a grep pattern is not).
  - *Installed hook*: `--approval hook` refuses unless the extension omp will
    load resolves to this checkout's hook and carries
    `HERDR_HOOK_APPROVAL_PROTOCOL = 1`; the worker gets `HERDR_CONTROL_DIR`
    pinned to that checkout.
  - *Slack*: the post carries the request id, tool and verdict only; the
    command stays on the hub form (a webhook path is a secret no redactor
    knows).
  - A menu worker whose registry read fails reads once, then relies on the
    env signal only.
  - `hub send` stays allowed: in omp 18.3.2 it is in-process peer messaging
    (delivered to an agent id in the same omp process, never typed into a
    herdr pane), and the recipient's own tool calls are judged by this hook.
  - Residual, stated: `read http(s)://` and `web_search` stay unscoped (q3); a
    bash call's persistent-shell cwd is not what the grant binds when the call
    names no `cwd`; inline `GIT_CONFIG_*=…` / `export` shapes classify allow in
    both modes (reviewer note, pre-existing).
- **Differences from §4's sketch**: request state lives in an `action_requests`
  table (events alone cannot do an atomic one-shot consume); the Slack/form half
  runs in the hub, not the worker, because a `--no-secrets` worker has no Slack
  credential; conductor wakes use `send-to-agent.sh` directly rather than
  `lib/push-wake.sh`, whose prompt-id machinery this path exists to retire.

## 12. Same-uid residual: a worker can forge its own approval (DECIDED: A + B)

Review round 2 on `97ac9c8` (both reviewers, live-proven): the hook-approval
rules are text patterns, and an allowed bash call that builds its target at
run time (`$(printf %s <base64> | base64 -d)`, a glob like
`~/.local/state/h*/runs/r*.sqlite3`, a symlink, or a script whose content is
clean text) writes the registry or the pinned hub-form record. The next
re-issue of a human-only call then runs as if Terrence had approved it. Both
live reproductions were end to end: `gh pr merge … --admin` reserved → forged
record/row → the tick applied it as `approved/human` → re-issue ran.

This cannot be closed by more patterns or by path resolution: the worker, the
decider (`herdr-action.sh`), the hub and the registry all run as one uid, so
anything the hook can read the worker can write, and a clean-classified script
runs with no review at all. docs/approval-policy.md rule 7 already says the
approval layer is a trust boundary, not containment. The same class exists in
the menu path today — measured on origin/main with peer authority:
`herdr pane send-keys <own pane> Enter` → allow, and
`(sleep 20; bash "$(printf %s <b64 of herdr-select.sh> | base64 -d)" <own pane> 1 --authority human) &` → allow.
A worker can already press Approve on its own reserved menu with one allowed
command.

What hook mode changes is that no human glances at each call (§7), so the only
thing between a deliberately adversarial worker and a reserved action is the
worker's own honesty, in both modes. The decision needed before merge:

- (A) accept this as the rule-7 residual for hook mode, as it is already
  accepted for the menu path, and merge off-by-default; or
- (B) require hook-approval workers to run isolated under a different uid or
  container that cannot write `~/.local/state/herdr` or the herdr-control
  checkout (`isolated-worker.py` is the existing starting point), and merge
  only with that; or
- (C) keep the branch unmerged and hook approval off.

**Decision (Terrence, 2026-09-27, hub form `20260927T022930-8742`, answered via
the hub): (A) + (B).** Merge PR #170 with hook mode OFF by default, and record
the same-user gap as the rule-7 residual for BOTH the menu path and hook mode.
Open the isolation follow-up: run workers under a separate macOS user or a
container that cannot write `~/.local/state/herdr`, the checkouts, or
Terrence's gh/1Password credentials — required before hook mode becomes the
default and for any task that reads untrusted input (starting point:
`isolated-worker.py`). Tracked as
[#172](https://github.com/tntpgh/herdr-control/issues/172). His note: "there are things like devcontainers that
might work, but we'd have to be mindful of how our system works. Like the idea
of getting better at our security with this." The 5-day shadow gate (§10 q1)
still applies to any canary.

## 13. Long-lived owner/conductor identity (built OFF, 2026-10-07)

Status: **inert.** Code, store, CLI and tests exist; nothing sets the opt-in,
nothing calls the registration path, no default changed. Activation needs a
reviewed owner decision (below).

**Why.** §5/§11 cover only spawned tasks: identity is the registry row
`spawn-task.sh` stamped. An ordinary long-lived pane (Main, a conductor) has
no row, so nothing judges its exact input. Incident
`.handoffs/incidents/2026-10-07-mnemopi-cursor-bypass.md` (pane w72:p3): a
`bash` call was denied twice, then `eval` wrote
`~/.omp/agent/notepad-mnemopi-sync-cursors.json` — §3's `eval` row, from a
pane §3 does not cover.

**Identity: three facts, all required.** A row in
`$(run_state_root)/owner-identities.sqlite3` (`lib/owner-identity.sh`) binds an
owner label to:
- `pane_id` — the herdr pane;
- `pane_birth` — that pane's herdr `terminal_id` at registration, the same
  generation `_ps_identity` (`lib/pretool-shadow.sh:130`) and
  `_ha_conductor_ok` (`herdr-action.sh:112`) compare against
  `pane_birth_now` (`lib/pane-guard.sh:85`). A later process in a recycled
  pane id has a different birth;
- `session_id` — the running omp session's own id, read by the hook from
  `ctx.sessionManager.getSessionId()` (`omp://extensions.md`), never from env
  or the payload. `/new`, `/resume` or a relaunch is a different identity.

The existing `owners` table (`register-owner.sh`, `lib/run-registry.sh:1586`)
is NOT reused: it is a remote-MCP routing registry that any caller may
(re)write with `INSERT OR REPLACE` and that carries no session binding. A
separate file also means no registry migration: the store does not exist
until a human registers the first owner, and the enforcing check only reads it.

Rows are never deleted. Revoke flips `state` to `revoked`; re-registering a
label adds a new row; the check reads the label's newest row. Partial unique
indexes allow at most one ACTIVE row per label, per pane and per session, so
racing registrations of one pane land exactly once.

**Opt-in and env only tightens.** The hook (`agent-hooks/omp-herdr-control.ts`
`LOAD_OWNER_LABEL`, `onToolCall` at :939) engages owner mode only when the
session was launched with `HERDR_OWNER_APPROVAL=<label>`, read once at module
load. Like `HERDR_APPROVAL=hook` (§11), the label turns the check on and can
never admit a call: admission needs the record. A session without the label
takes exactly origin/main's path (proved below). A session with both a worker
task and an owner label is refused. The record cannot engage owner mode by
itself: a session the human launched without the label is that human's
choice of posture, and the label is what makes the session unable to shed it.

**Gate, then the existing classifier.** `lib/pretool-shadow.sh --enforce
--owner` runs `pretool_decide` unchanged except for its first step:
`_ps_identity` dispatches to `_ps_owner_identity` (:176). Every failure sets
`PS_POLICY=identity` through the same `_ps_id_fail` (:128), and
`pretool_owner_enforce` (:789) answers with the same sentence the worker
branch uses (`_ps_identity_refusal`, :773): *"…cannot prove this session is
the live registered owner '<label>', so nothing runs. Stop and tell
Terrence."* Refused, never allowed: no store, unreadable/corrupt store,
unknown label, malformed label, revoked (checked every call, no cache — a
revoke lands on the next call), wrong pane, recycled or vanished pane, session
mismatch, missing session id, worker+owner env. The refusal names the
session id and pane so the human can register it; it never shows the
registered session id.

After identity, the verdict is the §3 table and `peer_decide` with an empty
task JSON (the unregistered-pane case `peer_decide` already has,
`lib/scoped-policy.sh:529-533`). Two tightenings, owner-only, at the end of
`pretool_decide` (:694); both can only turn `allow` into `escalate`:
- `containment-159` allows (edit/write/notepad/local://) lean on the #159
  guard, which runs for spawned workers only → escalate (`owner-scope`).
- a command `peer_decide` allowed (bash, a job's stdin, `hub start`) must pass
  the read-only closed world. `classify_command` with no worktree allows
  `python3 -c "open(p,'w')…"`, `node -e writeFileSync`, `echo > p` and `cp`;
  for a worker the #184 write-target guard contains those, for an owner
  nothing would. The closed world is the existing F3 one, generalized rather than
  copied: `_ps_bash_closed_world_verdict` (:382, formerly
  `_ps_bash_handoffs_verdict`) with an empty `hw` means "no write scope" —
  every segment's command word on `_PS_HW_SAFE`, read-only git verbs only, no
  command substitution, and any write target escalates. Worker reasons are
  byte-identical. Exec-capable git options (`git grep -O`/
  `--open-files-in-pager`, clustered or abbreviated, `--ext-diff`,
  `--textconv`, `--output`, …; the PR #251 review's HIGH finding) are refused
  by #254's shared gate — `_cp_git_unsafe_tokens` and
  `_cp_exec_name_or_opaque_present` (lib/command-policy.sh), which
  `peer_decide` runs for every session and the closed world calls again —
  so owner mode carries no git option list of its own. One rule stays in the
  closed world, because no shared gate sees it: a find/rg/git argument
  holding an expansion (`$X`, `${X}`, `$'…'`, a backtick) escalates, since
  the shell resolves it after the check (`git grep $X`, X=`-O<cmd>`). A bare
  `$` regex anchor is not an expansion.

Answers: `allow` runs (omp's own approval layer still applies after it);
`escalate`/`reserved` are blocked as Terrence's call ("stop and ask him"),
with no action request and no registry write; `deny`/`block` (eval, python,
browser, debug, paid APIs) are blocked. Verdicts are audited in the owner
store's `owner_events` (with the session id), never in the shadow store's
worker rows.

**Registration is human-only.** `owner-approval.sh register <label> <pane>
<session>` / `revoke <label> --reason <why>` refuse (exit 9, audited as
`register_refused`/`revoke_refused`) unless: no `HERDR_TASK_ID`/`HERDR_RUN_ID`/
`HERDR_OWNER_APPROVAL`; the caller's pane is not the target and is not running
an agent (`pane_is_agent`); stdin is a terminal; no ancestor process is a
known agent (`lib/agent-profiles.sh` names, so an agent's bash with a pty is
still refused); and the label is typed back. Inside an enforced session the
policy refuses first: `lib/hook-approval-rules.tsv` adds the store, its
tables, `owner-approval.sh`, `owner-identity.sh` and
`HERDR_OWNER_APPROVAL`/`HERDR_OWNER_SESSION_ID` to the human-only list; the
write/edit tools are owner-scope; eval is blocked. Residual (§12, unchanged):
a same-uid process that double-forks away from its agent and fakes a
terminal can still write the store. Isolation (#172) is what closes it.

**Proof** (`verify-owner-approval.sh`, 124 checks): missing store, unknown and
malformed labels, recycled/vanished/wrong pane, session mismatch and missing
session, worker+owner env, revoke mid-session (and the revoked session stays
out after the label is re-bound), garbage/table-less/mode-000 store and a row
with no birth, a spoofed "approved" pane screen plus approval-shaped payload
fields and env (herdr is only ever asked `pane list`), seven owner-mode
self-registration/elevation commands plus write/edit/eval on the store, every
CLI guard, 14 bash write/exec shapes including the incident's interpreter
write, 30 parallel checks from two sessions on one pane (15/15 and 0/15), 12
racing registrations (exactly one lands), revoke racing 16 checks, and the
hook: ctx session id required (env never substitutes, a throwing session
manager refuses), `--auto-approve` with no store refuses everything, missing
lib refuses, and a session without the label returns origin/main's answers
exactly (non-worker and menu worker).

**Deliberately not built (decisions for activation):**
1. *Answering owner escalations.* Today they are blocked for Terrence to run
   himself. A grant path would reuse `action_requests` with the human route,
   keyed to the owner label instead of a task row; that touches the hub tick
   and `herdr-action.sh`, so it waits for the decision.
2. *An owner write scope.* None today: every file mutation and every
   non-read bash escalates. A per-owner allowlist of writable roots is the
   obvious extension.
3. *Subagents.* A child session has its own id, so its calls are refused.
   Binding children to the parent session is possible but widens the identity.
4. *Launch posture.* With the label and omp's menu, owner mode only removes
   calls. With `--auto-approve`, the hook is the only check. Which one is a
   posture decision.

**Activation step (NOT taken by this change).**
1. Terrence decides the four items above (hub form, `rule://conductor-decisions`).
2. Launch the owner's omp with `HERDR_OWNER_APPROVAL=<label>` (posture per
   item 4). Every call is refused until step 3, and the refusal shows
   `this session is <id> in pane <pane>`.
3. From a plain terminal (not an agent pane):
   `owner-approval.sh register <label> <pane> <session>`, then type the label.
4. Rollback: `owner-approval.sh revoke <label> --reason <why>` (the session
   is then refused, never unenforced), then relaunch without the label.
