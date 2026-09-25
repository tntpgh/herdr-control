# Scoped approval: prior art

Research written 2026-09-24 for `feat/task-scoped-approval` (brief: `.handoffs/SPEC.md` step 0).
Question: how do other systems decide what an agent may do without asking, and what should
herdr-control take from them? herdr-control's setup is one operator (Terrence), Main as the
conductor, one worker per herdr tab, and a human-only reserved list that stays untouched.

Every claim below cites a URL or a local path plus a commit. Anything not checked is marked
**[unverified]** or **[INFERENCE]**. Docs fetched on 2026-09-24. Claude Code and Codex docs
change fast, so re-read them before quoting version-specific behaviour.

**Terms used in every section**
- *Declared up front*: what the operator writes before the run (config, rules, a manifest).
- *By construction*: enforced by the OS, a sandbox, a proxy, or a tool that can't do more.
- *By classifier*: a pattern match or a model judges the text of each action.
- *Long code*: how multi-line scripts, evals, and subagent spawns get reviewed.

## Key findings

1. **buildrig could not be identified** (see §2). No local copy, no memory, no public repo or
   package under that name. The only mention on this machine is Terrence's own 2026-09-24
   message asking for this work.
2. **firstmate doesn't approve individual worker calls.** It launches workers with
   approvals off (Claude bypass, Codex `--dangerously-bypass-approvals-and-sandbox`, omp
   `--auto-approve`). Safety comes from three other places: a throwaway worktree per task,
   a merge authority set once at spawn, and merges through guarded scripts (§1).
3. **Deny always beats allow.** Claude Code, Codex, Devin CLI and omp all check deny before
   allow, and no grant can carve an exception out of a deny. That matches "a manifest can
   never grant a reserved action".
4. **No surveyed sandbox separates read HTTP from write HTTP.** Claude Code's and Codex's
   network proxies allow or block by *hostname*. GET-only vs POST is always a text-level
   (classifier) decision, so `net_read: [host]` on a `curl` is a classifier call unless a
   GET-only tool is used instead.
5. **Grants that live somewhere the agent can write are not trusted as-is.** Claude Code
   applies a project's allow rules only after a trust dialog that lists them, and ignores
   `defaultMode: auto` and credential `mask` entries in project files. Codex makes `.codex/`,
   `.agents/` and `.git/` read-only inside writable roots. firstmate refuses `--yolo` as a
   brief input.
6. **Sandboxed systems don't review long code; they contain it.** Systems that review text
   all have a size limit: Claude Code always prompts above 10,000 characters, OpenHands can't
   see content past 30k characters, and herdr refuses clipped panels. None of the agent CLIs
   surveyed ties an approval to a script's content hash. direnv does (§8).
7. **Model-based reviewers are "reviewer swaps, not permission grants"**, with circuit
   breakers: Codex Auto-review stops at 3 denials in a row or 10 in the last 50; Claude Code
   auto mode at 3 in a row or 20 in total. A model rating its own risk is not a control:
   OpenHands closed that issue "not planned".

## 1. firstmate

**Local record.** `~/Code/thurber-os` commit `fc0f7e1` (branch `plan/015-jev-firstmate`,
2026-09-17) rejected firstmate as a dependency:
- It would replace ≈960 lines of our routing, and would have to respect ≈14,600 lines of our
  governance it knows nothing about: the gate-registry signature guard, `ci.sh` validators,
  formserve "expiry ≠ decline", the secret hooks, the tighten-only posture floor, and the
  human-reserved action classes.
- It has 1,460 open issues, 72 commits a week, and a self-update path. Its own verification
  scored 20/25 rule matches, 18/25 profile matches, and one confidently wrong dispatch.

Sources: `plans/015-jev-and-firstmate.md` §6 and `docs/tracking/2026-09-17-plan-015-jev-deferred.md`
"firstmate — rejected". Five patterns were "borrowed as design, no code": (1) the model sees
only the classification and every gate stays in code; (2) four outcomes,
`clear|ambiguous|escalate|error`, and every non-clear goes back to the authorized path;
(3) approval-required rules beat confidence; (4) opt in on key presence, with no network call
when the key is absent; (5) never put a secret on argv.

That review was about *dispatch*. It did not look at how firstmate handles approvals. The
public repo was read for that: `github.com/kunchenguid/firstmate` at `b42d4fa` (2026-09-24).

- **Declared up front.** Per task, `fm-spawn.sh` *requires* `--mode <no-mistakes|direct-PR|local-only>`
  and `--yolo <on|off>`, "this task's delivery contract" (`bin/fm-spawn.sh:4-10`).
  - `yolo` governs merge authority only (`AGENTS.md:366-367`).
  - It is refused as a brief input: "The worker never owns merge decisions, so yolo is a
    spawn-time and firstmate-side input only" (`bin/fm-brief.sh:88-89,216`).
  - A relaunch reuses the recorded posture and can't override it (`bin/fm-spawn.sh:798-800`).
  - `config/claude-permission-mode` picks `bypass` (default) or `auto` for every Claude
    worker. Any other value refuses the spawn: "Firstmate never falls back to a permission
    posture the captain did not choose" (`docs/configuration.md:398-402`).
- **By construction.** Almost nothing at the tool-call level. Workers run with approvals off:
  Claude `--dangerously-skip-permissions` or `--permission-mode auto` (`bin/fm-spawn.sh:300-310,529-537`);
  Codex `--dangerously-bypass-approvals-and-sandbox` (`:1962-1964`); omp forced
  `--auto-approve` plus a tracked `--config` overlay `.omp/fm-worker-overlay.yml` (`:182-192`);
  Devin `--permission-mode dangerous --respect-workspace-trust false` (`:175-180`).
  The real boundary is elsewhere:
  - A disposable isolated worktree per task (`AGENTS.md:472`).
  - Merges only through `bin/fm-pr-merge.sh`, which refuses unproven or red merges (`AGENTS.md:368-372`).
  - An opt-in `config/launch-env-allowlist` (`env -i` plus named variables). The file
    itself calls this "an exec environment boundary, not a sandbox" (`bin/fm-spawn.sh:275-298`).
- **By classifier.** PreToolUse "seatbelts" guard only the *primary* (firstmate's own
  session), not workers. The watcher-arm and `cd` guards use a shell tokenizer that "never
  executes, sources, evaluates, or expands" the command. Their threat model is "agent
  mistakes". They fail open on transport errors and closed on semantic matches
  (`docs/arm-pretool-check.md`, `docs/cd-guard.md`). Captain gates stay unconditional:
  "Destructive, irreversible, and security-sensitive merges still escalate" even with yolo on
  (`AGENTS.md:369`), and away and quiet modes "never expand approval authority" (`AGENTS.md:489`).
- **Long code.** Not reviewed per call. Review happens at the PR: the `no-mistakes` pipeline,
  or `direct-PR` plus the merge authority (`AGENTS.md:360-367`). The primary is blocked from
  using a harness's own subagent tool, because untracked work switched off supervision
  (73 minutes unnoticed, 2026-07-22) (`docs/subagent-guard.md`).
- **What to steal.**
  - Authority belongs to the spawn record, written by the conductor-side script, and the
    worker can't author it. The equivalent for us: the manifest's *effective* copy lives
    somewhere the worker can't edit (§ "Findings that constrain the design", item 3).
  - An invalid posture refuses the spawn instead of falling back. Posture is fixed for the
    life of the task across relaunches. Keep the four-outcome vocabulary.
  - **Don't steal** approvals-off workers. Nothing would ever reach `herdr-select.sh`, so the
    human-only list would stop being enforced at the moment of action.

## 2. buildrig — not found

What was searched (2026-09-24), all with no match:
- **Local files.** `grep -i 'build-?rig'` over `~/Code` (gitignore respected): 0 matches.
  Over `~/.omp`, `~/.claude`, `~/.herdr`, `~/Code/thurber-os` (gitignore off): only this
  task's own session logs and briefs.
- **Memory.** Mnemopi `recall("buildrig")` returned nothing relevant.
- **Origin.** The only real mention is Terrence's message to Main: "being mindful of other
  tools like buildrig and firstmate" (`~/.omp/agent/sessions/-Code-thurber-os/2026-09-24T22-59-29-583Z_*.jsonl`, entry 277).
- **Public.** GitHub repository search for `buildrig`/`build-rig`, filtered to exact
  `^build-?rig$` names: 0 repos. `registry.npmjs.org/buildrig` → 404;
  `pypi.org/pypi/buildrig/json` → 404. `buildrig.com` and `buildrig.dev` are registered
  (Cloudflare nameservers) but have no A records, and neither does `www.`; `buildrig.ai` and
  `buildrig.io` don't resolve.
- **Name collisions (not buildrig):** [regenrek/agentrig](https://github.com/regenrek/agentrig),
  a plugin packager for Claude, Codex and Cursor; and [agentkitai/agentrig](https://github.com/agentkitai/agentrig),
  a 1-star harness created 2026-08-29. A search engine labelled the second "BuildRig
  (agentrig)", but its README never says "buildrig".

Verdict: **unidentified**. Nothing is inferred about it. Terrence would need to supply a link.

## 3. Claude Code

Sources: [permissions](https://code.claude.com/docs/en/permissions), [permission modes](https://code.claude.com/docs/en/permission-modes), [sandboxing](https://code.claude.com/docs/en/sandboxing).

- **Declared up front.** `permissions.allow|ask|deny` in `settings.json`, with rules such as
  `Bash(npm run *)`, `WebFetch(domain:example.com)`, `Read(...)`/`Edit(...)` with gitignore
  paths, and `Agent(Name)`. Also `defaultMode`, `additionalDirectories`,
  `sandbox.filesystem.allowWrite`, `sandbox.network.allowedDomains`, and managed settings that
  nothing overrides.
  - Order is deny → ask → allow. "An allow rule can't carve an exception out of a deny rule."
  - Project `permissions.allow` rules apply only after the workspace-trust dialog "lists the
    rules and directories the folder would grant".
  - "Yes, and don't ask again" saves a rule to `.claude/settings.local.json`, which applies
    across the whole repo, worktrees included. That makes it per-repo and permanent, not
    per-task.
- **By construction.** An OS sandbox (Seatbelt on macOS, bubblewrap on Linux) for filesystem
  writes, plus network through a proxy. The proxy "enforces the allowlist based on the
  requested hostname and … does not terminate or inspect TLS". It covers only Bash, PowerShell
  and Monitor commands and their children. With `autoAllowBashIfSandboxed` (default on), "the
  sandbox boundary substitutes for that whole-tool prompt". Protected config paths can't be
  exempted. The escape hatch, a `dangerouslyDisableSandbox` retry, can be turned off with
  `allowUnsandboxedCommands: false`.
- **By classifier.**
  - **Bash rules.** Matched after splitting `&&`, `;`, `|` and stripping wrappers such as
    `timeout` and `nohup`. The docs say plainly these rules are not a security boundary:
    `/usr/bin/curl` and `sh -c 'curl …'` slip past `Bash(curl *)`, and a rule like
    `Bash(curl http://github.com/ *)` "is fragile".
  - **Auto mode.** A separate model reviews anything that isn't read-only.
    - It blocks by default "Launching an autonomous agent loop … `--dangerously-skip-permissions`".
    - It allows by default "Read-only HTTP requests" and "Pushing to any branch … including
      the default branch". That second default conflicts with our human-only list.
    - Boundaries stated in conversation "can be lost if context compaction removes the
      message … For a hard guarantee, add a deny rule."
    - A conversational approval must "name the action and its specifics" and covers one
      action. Fallback: 3 blocks in a row or 20 in total pause auto mode.
  - **Hooks.** A PreToolUse hook sees the full tool input and can deny, ask or allow. It
    cannot override deny or ask rules.
- **Long code.** Commands longer than 10,000 characters always prompt. Entering auto mode
  drops broad allows: `Bash(*)`, "wildcarded interpreters like `Bash(python*)`",
  package-manager `run`, and `Agent` allow rules. Read/Edit deny rules don't cover "a Python
  or Node script that opens files itself"; the sandbox is the answer for that. Subagents are
  checked at three points: the task description at spawn, every action while running, and the
  final report before the parent reads it. The classifier sees tool calls but not tool results.
- **What to steal.**
  1. The trust-dialog pattern: a grant that arrives inside the worked-on tree takes effect
     only after a human (or Main) sees the listed grants.
  2. Keys that widen capability count only from operator-controlled sources.
  3. Never allow a whole interpreter (`python3 *`). Ask for the specific file instead.
  4. The three-point subagent review.
  5. Scope is data, not prose. Prose gets lost in compaction.

  **Don't copy** the auto-mode default that allows pushes to the default branch.

## 4. OpenAI Codex CLI

Sources: [approvals & security](https://learn.chatgpt.com/docs/agent-approvals-security) (redirected from `developers.openai.com/codex/...`), [permissions](https://learn.chatgpt.com/docs/permissions), [rules](https://learn.chatgpt.com/docs/agent-configuration/rules), [auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review), [subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).

- **Declared up front.**
  - `sandbox_mode = read-only | workspace-write | danger-full-access`, and
    `approval_policy = on-request | never | { granular = … }`. `untrusted` is retired and
    replaced by a project `trust_level = "untrusted"`.
  - `[sandbox_workspace_write] network_access`, and `features.network_proxy` with a
    per-domain allow/deny list.
  - Beta **permission profiles**: `[permissions.<name>]` holds filesystem and network rules,
    can `extends = ":workspace"`, and is selected with `default_permissions`.
  - **Rules** (`.rules`, Starlark): `prefix_rule(pattern, decision = allow|prompt|forbidden, justification, match, not_match)`.
    `match` and `not_match` are "inline unit tests" checked at load. The most restrictive
    decision wins: forbidden > prompt > allow.
- **By construction.** Seatbelt (`sandbox-exec -p`) on macOS; bwrap plus seccomp on Linux.
  Network is off by default. If a policy can't be enforced, Codex "refuses to run the command
  instead of silently running it unsandboxed". `.git`, `.agents` and `.codex` are read-only
  inside writable roots. The proxy blocks local and private addresses, and domain rules are
  hostname-based. "Network access and network filtering are separate settings." The proxy
  does *not* filter web search, MCP, the browser or connectors.
- **By classifier.** Prefix rules match on argv. A `bash -lc` script is split only if it is a
  linear chain of plain words; with redirects, substitutions, variables, globs or control flow
  it is judged "as a single invocation". **Auto-review** (`approvals_reviewer = "auto_review"`)
  sends only actions that already need approval to a reviewer agent:
  - "Auto-review is a reviewer swap, not a permission grant."
  - It fails closed. A denial tells the agent not to "pursue the same outcome via workaround".
  - Its circuit breaker trips at 3 denials in a row or 10 of the last 50. `/approve` retries
    one exact denied action once.
- **Long code.** Not reviewed. It runs inside the sandbox unless it crosses the boundary.
  Subagents inherit the sandbox and the parent's live overrides. Approvals from inactive
  threads show a source label. In non-interactive runs the action fails back to the parent.
- **What to steal.**
  1. A **named profile that extends a base**. That fits a manifest per job class
     (`geo-audit` extends read-only plus `net_read`).
  2. Keep "may reach the network" and "which hosts" as separate knobs.
  3. `match`/`not_match` examples inside the manifest, checked at spawn. That is a red-test
     fixture for free.
  4. Auto-review's contract for Main: Main reviews escalations but gains no power to grant
     beyond the manifest. It needs a denial circuit breaker. Main denied four times in 15
     minutes on the geo-audit run (SPEC.md).

## 5. OpenHands

Sources: [SDK security guide](https://docs.openhands.dev/sdk/guides/security), [sandboxes](https://docs.openhands.dev/openhands/usage/sandboxes/overview), [issue #4157](https://github.com/OpenHands/software-agent-sdk/issues/4157).

- **Declared up front.** A confirmation policy object: `AlwaysConfirm()`, `NeverConfirm()`,
  or `ConfirmRisky(threshold)`. A security analyzer, which does not change confirmation by
  itself ("you must configure both"). A sandbox provider: Docker (default), Process ("unsafe
  … no container isolation"), or Remote.
- **By construction.** Only the Docker or remote sandbox. The analyzer layer calls itself
  "not … a sandbox replacement".
- **By classifier.**
  - `LLMSecurityAnalyzer`: the agent rates its own `security_risk`. Issue #4157 says a model
    "can classify any action … as LOW" and it auto-executes. The issue was closed
    `not_planned` on 2026-09-04.
  - Deterministic `PatternSecurityAnalyzer` and `PolicyRailSecurityAnalyzer` (fetch-to-exec,
    raw disk, catastrophic delete, "per-segment"). `EnsembleSecurityAnalyzer` takes the
    maximum severity, and UNKNOWN is confirmed by default.
  - Documented limits: no hard deny ("SDK analyzers return `SecurityRisk`, not block/allow"),
    `execute_tool()` bypasses the analyzer, and "Content past 30k chars is invisible".
- **Long code.** Scanned as action text up to the 30k cap. No file-level or hash-bound
  review is documented. **[unverified]** whether any exists.
- **What to steal.** Take the worst verdict across checks (worst-case wins), and treat
  UNKNOWN as confirm. Our reserved list and `escalate`-by-default already do both.
  **Don't steal** self-rated risk.

## 6. Devin CLI ("Devin-style capability grants")

Source: [Devin CLI permissions](https://docs.devin.ai/cli/reference/permissions). Devin's
hosted product (cloud VM sessions) was **not** examined.

- **Declared up front.** Modes: Normal, Accept Edits, Smart, Bypass, and Autonomous. Scoped
  grants: `Read(glob)`, `Write(glob)`, `Exec(prefix)`, and `Fetch(URL pattern | domain:host)`,
  plus tool names and `mcp__…`. Deny "always wins". A specific allow can carve out of a
  broader *ask* only at the same configuration level. Organization Team Settings deny and ask
  rules survive every mode.
- **By construction.** Autonomous mode is "only available when the OS-level sandbox is
  active". Shell commands and fetches auto-approve "because the sandbox enforces what they can
  read, write, and reach". `edit`/`write` tools still prompt because they run outside the
  sandbox. Granting `Write(...)` mid-session "dynamically expand[s] the sandbox".
- **By classifier.** Smart mode lets a fast model judge anything that isn't a workspace edit.
  It *never* auto-approves package installs, mutating `git`, `rm`, `sudo`, destructive cloud
  CLI calls, or anything touching dotenv files, key material, git config, or the agent's own
  config.
- **Long code.** Not documented beyond `Exec(prefix)`. **[unverified]**
- **What to steal.** Grant vocabulary split by effect (`Read`, `Write`, `Exec`, `Fetch`), which
  maps onto `writes` / `net_read` / `net_write` / `git`. A grant should widen the
  *enforcement* boundary, not just silence a prompt. The Smart-mode never list is the same
  idea as our reserved list: fixed classes that no mode unlocks.

## 7. omp `--approval-mode` (checked locally)

Checked on this machine: `omp --help` (v18.3.0) lists
`--approval-mode=<value>  Override tools.approvalMode for this session (always-ask|write|yolo)`
and `--auto-approve`; `omp config get tools.approvalMode` → `yolo`; `omp config list` shows
`tools.approval = {}`. Semantics come from the bundled docs `omp://approval-mode.md`,
`omp://settings.md` and `omp://hooks.md`.

- **Declared up front.**
  - Every tool has a tier: `read`, `write` or `exec`. Unknown tools default to `exec`; MCP
    tools are `write`.
  - Modes: `always-ask` auto-approves `read`; `write` auto-approves read and write; `yolo`
    auto-approves everything. `tools.approval.<tool>: allow|deny|prompt` overrides the mode.
  - `bash.patterns` is an ordered, first-match list: `deny` is absolute, `prompt` forces a
    prompt, and `allow` approves at the `write` tier.
  - A per-run `--config` overlay beats project config, which beats global config.
- **By construction.** None. "`bash.patterns` is an approval policy, not containment. An
  allowed program still has the bash process's filesystem, network, and subprocess access."
- **By classifier.** Tool policies, including bash critical-pattern overrides (`rm -rf /`,
  fork bombs, remote-fetch-then-execute); in `yolo`, a bare critical override is ignored.
  `bash.allowCompoundCommands` (off by default) judges only flat, literal `&&` chains.
  `tool_call` hooks can `{block: true}`, and a hook that throws fails closed. **[unverified]**
  whether `tool_call` fires before or after the approval prompt.
- **Long code.**
  - `eval` is `exec` tier. "A `bash.patterns` `deny` rule does not apply to the same command
    run through `eval`"; closing that needs an explicit `tools.approval.eval`.
  - Subagents "run headless with `tools.approvalMode: yolo` … The parent `task` approval is
    the authorization boundary." `tools.approval.<tool>` stays authoritative inside them, and
    a `prompt` there rejects the call.
  - The approval prompt shows "command, path, code, … or subagent assignment". The standard
    formatter truncates `computer.run` JavaScript to 2,000 characters.
- **How herdr-control uses it** (worktree at `ed5700a`).
  - Workers launch at the `write` floor (`lib/posture.sh:14-16`, `lib/agent-profiles.sh:171-190`),
    so every `bash`, `eval` and `task` call prompts.
  - `herdr-select.sh:353-356` refuses a panel containing "elided" or "truncated".
  - Commit `2482186` already forwards the untruncated *bash* command from the omp hook. It
    also added an exact per-task grant (`_cp_grant_action`: own-branch add, commit, push, and
    PR create), stored in the run registry at `~/.local/state/herdr/runs/registry.sqlite3`
    (`lib/run-registry.sh:50-54`).
- **What to steal.**
  1. Send `eval` code and `task` assignments through the hook in full, the same way bash
     already is. That fixes the clipping for those tools at the source.
  2. Approving a `task` spawn approves the subagent's *whole run* in yolo. The manifest has
     to bound it, and so must any `tools.approval` deny.
  3. If a per-task omp `--config` overlay is ever used (firstmate does this), it can only
     *add* prompts or denies. It can't replace `command-policy.sh` as the decision owner, per
     SPEC.md "don't build a second policy engine" **[INFERENCE]**.

## 8. Adjacent prior art: hash-bound approval (direnv)

Not an agent tool, but the closest thing found to "code by reference, bound to a hash".
- `direnv allow` records permission for an `.envrc`. The allow key is
  `sha256(absolute_path + "\n" + file_contents)` (`fileHash`, `internal/cmd/rc.go` at
  [`b00e451`](https://github.com/direnv/direnv/blob/b00e451f547f39be7ab836d969054114a465a0f9/internal/cmd/rc.go)).
  So any edit, or the same content at a different path, is blocked again until re-allowed.
  `deny` is keyed on the path hash alone.
- Stated rationale: "any git repo that you pull … would be able to wipe your hard drive"
  ([man page](https://github.com/direnv/direnv/blob/master/man/direnv.1.md)).
- agentkitai/agentrig (§2) likewise pins MCP definitions. Its README says: "changed
  definitions require separate consent … hashes detect changes, not authenticity."
- **What to steal.** Put the path in the hash. Keep the approval record outside the tree the
  agent can edit. Note what a hash doesn't cover: it binds content, not what the script will
  *fetch or source* at run time. A file that runs `curl … | sh` or imports a sibling module is
  only partly covered by its own hash **[INFERENCE]**.

## Comparison

| System | Declared up front | By construction | By classifier | Long code / evals / spawns | Steal? |
|---|---|---|---|---|---|
| firstmate | Per-task `--mode`, `--yolo` (merge authority) at spawn; Claude permission posture file | Worktree per task, merges via guarded scripts; workers run approvals-off | Primary-only PreToolUse seatbelts (tokenizer, mistakes-only threat model) | Not reviewed per call; PR pipeline plus merge authority | Spawn-recorded authority the worker can't author; invalid posture refuses spawn. Not approvals-off |
| buildrig | — | — | — | — | Unidentified |
| Claude Code | allow/ask/deny rules, modes, sandbox paths and domains; project grants need trust | Seatbelt/bwrap for Bash; hostname proxy | Bash rules (docs say not a boundary); auto-mode model; hooks | >10k chars prompts; interpreter allows dropped in auto; subagents checked 3× | Trust dialog for in-tree grants; no interpreter wildcards; 3-point spawn review |
| Codex CLI | sandbox_mode, approval_policy, permission profiles, `.rules` with tests | Seatbelt/bwrap+seccomp, network off, refuses when unenforceable | argv prefix rules; Auto-review agent on escalations only | Contained, not reviewed; subagents inherit sandbox | Named profile extending a base; match/not_match fixtures; reviewer-swap contract plus breaker |
| OpenHands | Confirmation policy plus analyzer; sandbox provider | Docker/remote sandbox only | Self-rated LLM risk; regex/rail ensemble, max-severity | Text up to 30k chars; no file review found | Worst-case-wins, UNKNOWN→confirm. Not self-rating |
| Devin CLI | Modes; Read/Write/Exec/Fetch scoped rules; org rules | Autonomous = OS sandbox; Write grant expands it | Smart-mode fast model with fixed never list | Undocumented | Effect-typed grants; a grant widens enforcement |
| omp | Tier per tool; mode; `tools.approval`; `bash.patterns`; `--config` overlay | None ("not containment") | Tool policies, critical patterns, hooks (fail-closed) | `eval` bypasses `bash.patterns`; subagents yolo under parent `task` approval | Send eval/task text in full through the hook; bound task spawns |
| direnv | `allow` per file | Refuses to load unallowed files | — | sha256(path+contents) | Hash-bound approval |

## Findings that constrain the design

1. **Precedence.** Everyone checks deny first. For us: reserved list, then manifest allow,
   then today's text rules. A manifest can't lift a reserve (§3, §4, §6, §7).
2. **`net_read` vs `net_write` can't be separated by construction** with anything surveyed,
   because both proxies work on hostnames (§3, §4). It stays a `command-policy.sh` text
   judgment on `curl`/`wget` flags. A separate GET-only fetch-to-file tool could make it
   structural **[INFERENCE]**.
3. **Where the effective grant lives.** `.handoffs/identity.json` sits inside the worker's
   worktree, so the worker can write it (`spawn-task.sh:467-470` documents workers reading
   it). The run registry is outside the worktree. Every surveyed system either ignores
   capability-widening config from agent-writable locations or needs a trust step for it
   (§1, §3, §4).
4. **Long code.** Hash-binding (direnv) plus full-text forwarding (omp hooks) covers files
   and bash. It doesn't cover `eval` or `task` until their full input is forwarded (§7).
5. **Reviewer loops.** When Main acts as reviewer, Codex's and Claude's circuit breakers and
   the "no workaround after denial" instruction are the documented guard against the
   deny-and-redirect loop seen on 2026-09-24 (§3, §4).

## Unknowns

- buildrig: unidentified (§2). Devin's hosted product: not examined.
- firstmate's `no-mistakes` pipeline internals were not read; only its role in `AGENTS.md`.
- ~~Whether omp's `tool_call` hook runs before or after the approval prompt~~ — resolved by
  the integrating engineer against the v18.3.0 binary (`strings`, the tool wrapper): `tool_call`
  fires first, with `{toolName, toolCallId, input}`; `tool_approval_requested` follows with
  `{sessionId, toolName, toolCallId, reason?, approvalMode}` and **no input** (see Design §D5).
- Whether a per-run omp `--config` `tools.approval` reaches `task` subagents: the docs say
  user `tools.approval` stays authoritative there. Not tested.
- The doc versions are whatever was served on 2026-09-24. No Claude Code or Codex binary was
  run.

## Sources

- herdr-control worktree at `ed5700a`: `.handoffs/SPEC.md`; `herdr-select.sh:353-356`; `lib/posture.sh:14-16`; `lib/agent-profiles.sh:171-190`; `lib/command-policy.sh:1980`; `lib/run-registry.sh:50-54`; `spawn-task.sh:467-470`; commit `2482186` (per-task grant, untruncated bash command).
- `~/Code/thurber-os` at `fc0f7e1`: `plans/015-jev-and-firstmate.md`; `docs/tracking/2026-09-17-plan-015-jev-deferred.md`.
- Terrence's request: `~/.omp/agent/sessions/-Code-thurber-os/2026-09-24T22-59-29-583Z_01a0d5a5-36af-747b-a2b4-141c48c1d8de.jsonl`, entry 277.
- firstmate at `b42d4fa8a752fad9a5f0235783b02534bce29219`: https://github.com/kunchenguid/firstmate — `AGENTS.md`, `bin/fm-spawn.sh`, `bin/fm-brief.sh`, `bin/fm-promote.sh`, `bin/fm-dispatch-resolve.sh`, `docs/configuration.md`, `docs/arm-pretool-check.md`, `docs/cd-guard.md`, `docs/subagent-guard.md`, `docs/herdr-backend.md`.
- buildrig searches: GitHub repository search API; https://registry.npmjs.org/buildrig; https://pypi.org/pypi/buildrig/json; DNS for buildrig.{com,ai,dev,io}; https://github.com/regenrek/agentrig; https://github.com/agentkitai/agentrig.
- Claude Code: https://code.claude.com/docs/en/permissions; https://code.claude.com/docs/en/permission-modes; https://code.claude.com/docs/en/sandboxing.
- Codex: https://learn.chatgpt.com/docs/agent-approvals-security; https://learn.chatgpt.com/docs/permissions; https://learn.chatgpt.com/docs/agent-configuration/rules; https://learn.chatgpt.com/docs/sandboxing/auto-review; https://learn.chatgpt.com/docs/agent-configuration/subagents.
- OpenHands: https://docs.openhands.dev/sdk/guides/security; https://docs.openhands.dev/openhands/usage/sandboxes/overview; https://github.com/OpenHands/software-agent-sdk/issues/4157.
- Devin: https://docs.devin.ai/cli/reference/permissions.
- omp v18.3.0: `omp --help`; `omp config get tools.approvalMode`; `omp config list`; bundled `omp://approval-mode.md`, `omp://settings.md`, `omp://hooks.md`.
- direnv: https://github.com/direnv/direnv/blob/b00e451f547f39be7ab836d969054114a465a0f9/internal/cmd/rc.go; https://github.com/direnv/direnv/blob/master/man/direnv.1.md.

## Design for herdr-control

Built on `feat/task-scoped-approval`. Everything below is reuse of the existing engine
(`lib/command-policy.sh`, `lib/run-registry.sh`, `herdr-select.sh --authority`), not a second
one: one new shared entry point (`lib/scoped-policy.sh` `peer_decide`) that `herdr-select.sh`
and `lib/alert-gate.sh` both call, so the gate deciding who is woken and the path that presses
keys cannot disagree.

### D1. Capability manifest, approved once at spawn

Declared in the brief as a fenced block:

````
```herdr-manifest
net_read: [teamthurber.com, www.teamthurber.com]
writes: [tmp/**, GEO-AUDIT-REPORT-*.md]
net_write: none
git: commit-only
```
````

- **Parsed and validated at spawn** (`lib/task-manifest.sh`), fail-closed: unknown key, a
  wildcard/IP/port host, an absolute/`~`/`..` glob, a glob naming `.git`, `.handoffs` or
  `.env*`, two blocks, or any `net_write` other than `none` refuses the spawn — before any
  herdr/registry side effect.
- **Stored in the registry, not the worktree** (finding 3): `tasks.manifest` (schema v5),
  plus a `manifest_approved` event carrying the canonical JSON, its sha256, and the spawning
  conductor. `identity.json` gets an informational copy; the policy never reads it. A
  worker editing it widens nothing (tested).
- **Who approves, and when: the conductor that runs `spawn-task.sh`, once.** Writing the
  brief and spawning is the decision; `spawn-task.sh` prints the manifest and its sha. This
  is within authority Terrence already delegated: the manifest can only name what the
  reviewed-operational conductor could approve call by call (`local-read`/`branch-work` —
  a GET to a named host into worktree paths, a git ceiling), so it pre-reviews the
  conductor's own authority and never extends it. A manifest that needs more (any
  `net_write`) cannot be written; that stays a per-call human decision.
- **Precedence** (finding 1; Claude Code deny→ask→allow, Codex, Devin): manifest git
  **ceiling** → ownership grant (#3b) → `classify_command` → **human-reserved list**
  (nothing below can override it) → manifest **scope**, consulted only for an `escalate`
  verdict, never `deny`/reserved → code by reference. Outside the manifest, every verdict is
  exactly today's.
- **What the scope clears today: one measured shape.** A single simple `curl -q` GET (strict
  no-eval tokenizer shared with the #3b grant; `-q`/`--disable` first so no curlrc is read)
  where every URL's host is exactly in `net_read`, no userinfo, no `Host:` header, only
  allowlisted flags (no `-d/-F/-T/--json/--data*`, no `-X` other than GET/HEAD, no
  `-K/-u/-b/-c/-x/-O/-J/-L`), no option value starting with `@`, no `-w %output{}`, no
  `$`/`~` anywhere and no unquoted `{ } * ? [ ]` (brace/glob expansion happens after the
  parse), and every `-o`/`-D` target inside `writes` — not `.git`/`.handoffs`/`.env*`, not a
  symlink or hard link, parent resolving inside the worktree. Deliberately narrow; widen
  with evidence.
- **`git`** is a ceiling, not a grant: `commit-only` refuses a peer-pressed push/PR-create
  even though #3b would allow it; `none` also refuses add/commit. The conductor, who wrote
  the manifest, can still approve those per call.

### D2. Code by reference, bound to a hash

- `bash|sh|zsh|dash|python3[.N] [-u -B -e -x -v] <file> [args]` (one simple command) is
  judged by the file's **whole content**, from one snapshot copy so the hash and the judged
  bytes are identical. Shell content: `classify_command` + reserved list. Python content:
  reserved list + a positive capability list (process, network, deletion, env/home,
  dynamic code) — running shell rules over Python is a category error.
- Clean content clears for a peer. Otherwise it escalates; the conductor reads the **file**
  (not a clipped panel) and approves with `--authority conductor`; `herdr-select.sh`
  records `(task, realpath, sha256)` in `file_approvals`. The same bytes then re-run
  without review (the extract.py edit-rerun loop in the geo audit); a **changed file for a
  path that needed review escalates again, even if the new content would self-classify
  clean**. A conductor can never approve a file whose content is human-reserved. A script
  that can't be read for review escalates. This is direnv's `(path, sha256)` allow (§8) and
  `quick-action.sh --trust`'s existing rule (approval-policy.md §6) applied to worker code.
- Tightening, stated plainly: before this, `bash <file>` classified `allow` with no look
  inside (approval-policy.md §8 limit 1). Now, for a task-registered pane, the content is
  what gets judged.
- The ">~10 lines goes in a file" rule is in `lib/worker-rules.md`, appended by
  `canonical_rules_compose` to every managed launch's canonical rules — tracked with the
  policy it describes, not in an operator file.

### D3. Design only — not built

- **Fetch-to-file tool** (finding 2). `herdr-fetch <url> <worktree-path>`: GET only, no
  config file (`curl -q`), no redirects off-host (`--proto-redir` + host re-check), writes
  only to a manifest `writes` path, prints status + byte count + sha256 and never the body.
  It makes `net_read` structural rather than a flag parse, and keeps pages out of context.
  Approved by name (`herdr-fetch` is one reviewed executable), so its calls clear on the
  manifest with no curl parsing at all. Build it the day a second job template needs web
  input; until then D1's curl shape covers the measured case.
- **Main-run phase-0 inputs per job template.** Some inputs are the same for every run of a
  job: geo-audit needs the UA matrix fetch and the crawl list before any analysis. Main
  runs a template's phase 0 itself (it already did, ad hoc: `tmp/geo/ua-matrix.txt`, the
  crawl) and hands the worker files, so the worker's manifest can be `net_read: []` —
  nothing to approve at all. Shape: `templates/<job>/phase0.sh` producing `tmp/<job>/`,
  run by Main before `spawn-task.sh`, referenced in the brief.
- **Approval mode matched to job class** (§7). Today every worker launches at the `write`
  floor. Proposed: `explore|docs|review` with an empty manifest → stay `write` (every exec
  prompts, nearly all clear on the classifier); `implement|debug` with a manifest → `write`
  plus the manifest; nothing goes to `yolo`, because `yolo` removes the prompt this whole
  design hangs off, and omp `task` subagents already run `yolo` (§7) — which is why a
  `task` spawn's brief must be by reference and reviewed like a script.

### D4. False-positive classes measured while building this (the replay)

1. **`curl -D`/`-f` read as a POST/form upload.** The send-flag match was case-insensitive;
   curl's `-D` is `--dump-header`, `-f` is `--fail`. A plain GET came back "remote mutation —
   human-only". Fixed at the root: short flags case-sensitive, one shared list for
   `classify_command` and `conductor_reserved_reason`.
2. **The reserved list scans quoted DATA arguments as commands.** A probe script's argv
   (`'git push origin feat/x'` as a string to classify) was reserved; so was **a test-suite
   filename in argv** (`verify-command-policy.sh` contains `command-policy.sh`, which the
   reserved list reads as editing the policy). Neither peer nor conductor may approve those.
   Not changed here — the reserved list is deliberately a word match and loosening it is a
   control-weakening decision for Terrence — but the worker rule "test inputs are data, keep
   them out of argv" routes around it, and code by reference judges the file, not argv.
3. **Clipped panels** for long evals and `task` spawns: remedied by reference (D2, worker
   rules), not by parsing the clip.

### D5. Root causes fixed in this repo

- **The untruncated-command channel never worked.** omp's `tool_approval_requested` has no
  `input` (verified in the v18.3.0 binary), so #3b's `rawBashCommand` always got
  `undefined`: every geo-audit `input_required` event had `command: ""`, `herdr-select.sh`
  judged the scraped panel, and the ownership grant could not match in production.
  `agent-hooks/omp-herdr-control.ts` now caches bash input from `tool_call` by
  `toolCallId` (bounded Map, never throws, never blocks) and reads it on the approval event.
- **False peer signal with no menu up.** `omp-notify.sh` accepted the numbered prompt shape
  for approval events; a Write preview of a numbered markdown list matched it, and the gate
  then classified screen text. omp approvals are never numbered (`agent-profiles.sh`:
  `menu-prompt` only), so approval events now require `prompt_menu_visible`; `ask` keeps
  both shapes.

### D6. Limits (approval-policy.md rule 7 — not containment)

- The file can change between the hash check and the interpreter opening it, by a process
  other than the blocked worker; a same-user process can write the registry.
- Relative `-o`/`-D` targets and code-by-reference files require an explicit
  `cd <worktree> &&` prefix (or an absolute path under the worktree). This makes
  the judged path equal to the path the worker's persistent shell opens. The
  scope rejects `.git`/`.handoffs`/`.env*` after resolving parent symlinks too.
- Redirects are not allowed in the scope (`-L` absent), so a GET stays on `net_read`.
- The Python tripwire is a regex over NFKC-normalized source with comments and the module
  docstring removed; dynamic access (string-built attribute names, `getattr`, `sys.modules`)
  is flagged, but a determined obfuscation can still pass. Its job is to route a script to a
  reviewer, not to contain one.
- Code by reference covers exactly `cd <worktree> && interp <file>` or an absolute file
  under the worktree; a compound or piped form falls back to the old command-line-only
  judgment (it never widens anything).

### D7. Review record (2026-09-24)

Initial red test (`tmp/red-test-report.md`, `red-tester` agent) proved the four required
negatives with zero keys and the positives, then found H1–H5. Initial security review
(`security-reviewer`) found SCOPE-01..06, GRANT-01, CODEREF-01 and CEIL-01, including
one critical and two high findings. The fixes are now in this branch and pinned by
`verify-select-policy.sh`, `verify-scoped-approval.sh` and `verify-command-policy.sh`:
unquoted/URL globbing and `#N` output expansion are refused; curlrc is disabled with
first-argument `-q`; relative scope/code paths require `cd <worktree> &&`; hard links
and resolved `.git`/`.handoffs`/`.env*` paths are refused; the grant checks operator
rules and reserved free arguments; the spawn resolves the complete brief path; Python
uses CPython encoding detection, NFKC and an AST alias tripwire; nested execution/imports
escalate; `git: none` is a read-only allowlist; registry/alert/parser policy files are
reserved. The initial red-tester's second pass could not run because its model hit a
usage limit; the final code-level recheck was requested separately. The persistent-shell
cwd assumption is removed from the scope/code-ref contract by requiring an explicit
worktree binding.
