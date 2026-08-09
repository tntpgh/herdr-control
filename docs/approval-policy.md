# Approval policy — the trust-boundary contract

This is the single place that names the invariants any script touching
approval, delivery, or auto-answering must satisfy. It doesn't introduce new
behavior — every rule below is already enforced by existing code, cited by
file — it exists so a new script (or an outside reviewer) has one page to
check against instead of reconstructing the boundary from
`docs/control-plane-design.md`'s design history across several "review
correction" entries.

If you're adding a new automated-answering path, a new spawn surface, or a
new remote-control channel, it MUST satisfy every rule here or explain in
its own header comment why a rule doesn't apply.

## 1. Only "allow" may be answered without a human

`lib/command-policy.sh`'s `classify_command` is the sole gate between "an
agent auto-presses a key for another agent" and "a human must look at this."
It classifies the raw shell text behind a prompt into `allow` / `escalate` /
`deny`. Peer automation (`herdr-select.sh --authority peer`) may act ONLY on
`allow`; anything else is refused, unconditionally, with no key pressed
(exit 8). `--authority human` still records the verdict — a person may
approve a destructive command — but the decision is attributable, not
silent. (Design history: `docs/control-plane-design.md` correction 8.)

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
a real CLI flag for claude/omp; codex is deliberately left unmapped, because
a plausible-looking guessed flag would either break the spawn or falsely
imply enforcement that isn't happening. `posture_is_enforced_for(agent)` is
how a caller checks this instead of assuming a guarantee. A new
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

---

Cross-reference: `docs/control-plane-design.md` has the design history and
rationale behind each correction cited above. This file is the current
state of the contract; that one is why it looks like this.
