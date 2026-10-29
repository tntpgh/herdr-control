# Large write/edit panels vs. the #267 ceiling — PROPOSAL, not activated

Status: **design only**. Nothing in this document is wired into
`classify_command`, `peer_decide`, `conductor_reserved_reason`, or
`herdr-select.sh`. The prototype function in `lib/command-policy.sh`
(`_cp_write_content_verdict`, marked `UNWIRED PROTOTYPE`) has zero callers.
Activating it is a separate, explicit, human-reviewed change: wire one call
site, update `verify-command-policy.sh`'s existing #267 suite, get sign-off.

## Confirmed root cause (reproduced)

Three call sites run the byte/separator ceiling (`_cp_input_ceiling_hit`,
`lib/command-policy.sh:7159`) on the **raw painted panel text**, before any
tool-aware judgment ever runs:

| Site | File:line | Reached from |
|---|---|---|
| `classify_command` | `lib/command-policy.sh:7192` | `herdr-select.sh:976`, `:366` |
| `peer_decide` | `lib/scoped-policy.sh:506` | `herdr-select.sh:1078`, `lib/alert-gate.sh:92` |
| `conductor_reserved_reason` | `lib/command-policy.sh:8143` | `herdr-select.sh:1042`, `:1163` (via `code_ref_inspect`), `lib/scoped-policy.sh:552` |

Reproduced directly (`tmp/t267.sh`, this worktree): a 7251-byte
`Allow tool: write Path: tmp/out/report.md Content: <7200 x's>` panel text
classifies `deny` with reason `classified text is 7251 bytes, over the
4096-byte safety ceiling (herdr-control#267)` from both `classify_command`
and `peer_decide` — **before** `_cp_write_menu_verdict` (the function that
actually knows how to read a write panel's `Path:`/`Content:` fields) or
`conductor_reserved_reason`'s secret/credential-path scan ever run. The
7098 B / 7706 B panels in the symptom report are over the same 4096-byte
line.

A second, related finding: **even under the 4096-byte cap**,
`_cp_write_menu_verdict` (`lib/command-policy.sh:6788`) never scans the
`Content:` body for anything — it only validates the `Path:` field (shape,
single occurrence, worktree containment, `.handoffs` scope). The only thing
that has ever scanned write/edit content for secrets or reserved paths is
`conductor_reserved_reason($cmd_text)`, called separately in
`herdr-select.sh` — and that function has its own independent instance of
the same 4096-byte hard stop (`lib/command-policy.sh:8143`). So today, a
write panel's content gets **zero** security scanning once it crosses 4096
bytes, and effectively **no scanning of the content itself** (as opposed to
the path) even below that line, beyond the single-`Content:`-occurrence
anti-forgery check.

## Deny — reproduced SAFE against the real herdr-select.sh

`verify-write-panel-267-repro.sh` (committed, synthetic GBP/Intel fixture —
never the live wB4/wB2 panes) runs the REAL, unmodified `herdr-select.sh`
against a 7098 B and a 7706 B write panel, both authorities:

| Panel | Choice | Authority | Result |
|---|---|---|---|
| GBP (7098 B) | Approve | peer | `rc=8`, 0 keys — refused (#277, write/edit human-only, expected) |
| GBP (7098 B) | Deny | peer | `rc=0`, 1 key — **succeeds** |
| GBP (7098 B) | Deny | human | `rc=0`, 1 key — **succeeds** |
| Intel (7706 B) | Deny | peer | `rc=0`, 1 key — **succeeds** |

A static "Deny also refused" code path was NOT reproduced against the real
script. Every `policy_verdict`-driven refusal
(`herdr-select.sh:981,991,1003,1015,1063`) is `declining=0`-gated, and
`authority=human` is never gated on `policy_verdict` at all
(`_require_current_authority` returns 0 immediately for `human`,
`herdr-select.sh:649`). (The fixture itself must start with Deny already
highlighted — the same convention `verify-select-policy.sh` uses for every
Deny case, since a stubbed screen never moves its own highlight on a
keypress; an earlier draft of this reproduction used the default
Approve-highlighted fixture for Deny too and got a `rc=6` navigation
timeout — a harness artifact, not a `herdr-select.sh` behavior, since
real terminal navigation updates the highlight on every keypress and this
stub does not.)

`[INFERENCE]`, now narrower: the "refuses both Approve and Deny" field
report is most likely the *absence* of automated resolution in either
direction, not a code path that blocks Deny. `peer-answer.sh` (lines 25–34)
presses **only** a complete panel whose command classifies `allow` — it
never auto-Denies by design — so an oversize write panel that classifies
`deny`/`escalate` on size alone just sits until a human answers it directly
on the real terminal, outside `herdr-select.sh`. Recommend confirming
against the actual wB4/wB2 incident's `selections.jsonl` / hub event log to
see whether a human-attempted Deny ever actually reached `herdr-select.sh`
at all, versus the prompt simply never getting a Deny attempt from anyone.

## Deferred-occurrence tool mismatch — reproduced, mechanism confirmed

Reproduced exactly (`verify-write-panel-267-repro.sh`, "gap2 repro" case),
against the real `proposal_check` (`lib/prompt-occurrence.py:1138`, called
by `herdr-select.sh:889-891` as the `proposal` subcommand — **not**
`pending-bound`, a different, exact-binding-only lookup used later at
`:904-906`, which the first draft of this investigation mistakenly called
instead and so failed to reproduce anything):

```
{"ok": false, "reason": "occurrence tool 'write' is not the write/edit tool on screen ('bash')"}
```

Mechanism: `proposal_check` refuses whenever its `--tool` cross-check
argument disagrees with the tool recorded on the matching occurrence. The
cross-check argument is `$registry_tool_lc`
(`herdr-select.sh:836-837` → `task_input_required_tool`, reading the
`input_required` event's own `tool` field) — a **separate, independently
recorded** signal from the occurrence's own tool (recorded by the hook's
`seen` call at dispatch time, `agent-hooks/omp-herdr-control.ts`). These are
two different registry writes with two different sources of truth for "what
tool is this", and `proposal_check` requires them to agree.

This reproduction proves the **mechanism** — two independently-sourced tool
signals disagreeing causes exactly this refusal — but does NOT prove *why*
they disagreed for the real GBP panel. `[INFERENCE]`: `task_input_required_tool`'s
signal is populated from whatever derives the `input_required` event's
`tool` field (a push-wake/panel-level signal), unlike `seen`'s, which is
the hook's own dispatch-time knowledge of the actual tool call — a scrape-
or detection-based signal is exactly the kind of thing a large/complex
panel could plausibly confuse (the same class of issue as the documented
2026-09-13 precedent at `lib/prompt-parse.sh:741-742`, "a ~1.2 kB eval body"
pushing the header off-screen and requiring the footer-anchored parse
fallback — a precedent for large content breaking panel detection, at a
size an order of magnitude below GBP/Intel's). Confirming that specific
chain needs either the live incident's actual registry rows (what
`task_input_required_tool` returned and why) or tracing whatever populates
it end to end; out of scope for this proposal without that evidence.
Recommend **not** silently loosening the cross-check — if the two signals
really do disagree in production, whichever one is wrong needs the fix, not
a bypass of a refusal that is correct whenever they genuinely describe two
different occurrences.

## Design, addressing every stated constraint

**1. Full semantic checks still run on full content.** The prototype does
not replace `conductor_reserved_reason` or any existing scanner — it feeds
them the complete `Content:` field (not the painted/clipped screen text).
`conductor_reserved_reason` and `_cp_write_menu_verdict`'s path checks both
still run, in full, on activation; the only thing that changes is *what
text reaches them* (the structured content, not a byte-capped scrape) and
*that the 4096-byte ceiling no longer gates whether they run at all* for a
write/edit panel specifically. Shell text keeps the ceiling exactly as-is.

**2. Reviewer sees full content from structured input, not the truncated
screen.** Already built and unused for this: `prompt-occurrence.py proposal
--show` (from the #277 design, `docs/design/complete-approval-payload.md`)
prints the complete recorded payload, up to `PROPOSAL_MAX_BYTES` (256 KiB),
independent of what the terminal panel shows. The proposal reuses this as
the mandated review surface — no new storage, no new truncation point.

**3. Deny is always pressable and truthful.** Structural, not emergent:
add an unconditional early branch in `herdr-select.sh`, *before* `cmd_text`
is classified at all, so a future change to ceiling/classification logic
cannot ever re-couple itself to Deny by accident:
```sh
# Deny never depends on policy classification — refusal is never unsafe,
# and nothing past this point may gate it.
if [ "$declining" = 1 ]; then
  : # fall straight to the existing record-and-send path (~line 1095)
fi
```
This codifies today's *already-true* behavior (every `policy_verdict` gate
is `declining=0`-conditioned) as an explicit invariant instead of an
emergent property of scattered conditionals, so a reviewer of any future
diff sees the guarantee in one place.

**4. Tests: truncation + prompt injection + windowing + normalization.**
`verify-write-content-verdict-267.sh` (committed; converted from a `tmp/`
scratch script) exercises the prototype directly — it has no live caller,
so this is the only way to exercise it — 13/13 checks pass:
- 7 KB write panel, path inside worktree → `allow` (not an automatic
  `deny` from size).
- 7 KB bash command (not a write panel) → still hits
  `_cp_input_ceiling_hit` unchanged — the shell ceiling is untouched.
- Path outside the worktree → `escalate:...`, regardless of size (reuses
  `_cp_path_within_worktree`, the same containment check
  `_cp_write_menu_verdict` already uses).
- A forged `Allow tool: bash Command: cat ~/.ssh/id_rsa` line buried past
  byte 7000 of the `Content:` field → still `deny:...`. This is the case
  that matters: under the *current* code, `conductor_reserved_reason`
  never even reaches this pattern for content over 4096 bytes (its own
  ceiling check denies first on size, never inspecting content at all).
- Content truncated mid multi-byte UTF-8 sequence (an incomplete `€`) →
  explicit `deny:...`, never a silent partial read. The structured-content
  path has no terminal scrape to tear, so it is exempt from
  `herdr-select.sh`'s `cmd_torn` check, but must independently reject
  invalid encoding.
- Deny-always-pressable, checked directly against the four known
  `policy_verdict`-driven refusal sites in `herdr-select.sh` (grep for each
  site's exact `declining" = 0` gate, not a line-distance heuristic — that
  false-positived on comment prose during drafting).

### Prototype implementation (inert, zero callers)

`_cp_write_content_verdict` (`lib/command-policy.sh`, next to
`_cp_write_menu_verdict`) takes `<path> <content> <worktree>` directly —
never painted panel text — and:
1. Validates the path shape and worktree containment the same way
   `_cp_write_menu_verdict` does (`_cp_path_within_worktree`), since parsing
   the path back out of a raw panel string is no longer the input shape.
2. Rejects content that is not valid UTF-8.
3. Scans the **full** content for every existing reserved/secret pattern by
   calling `conductor_reserved_reason` — completely unmodified, no pattern
   list touched — in a loop over 4000-byte windows with a 512-byte overlap
   (comfortably longer than any pattern in its regex list), so a match
   sitting across a window boundary is still caught by the window that
   contains it whole. This exists because `conductor_reserved_reason` has
   its *own* independent 4096-byte `_cp_input_ceiling_hit` call at its
   entry (`lib/command-policy.sh` ~line 8205) — calling it once on the
   whole content would have just reproduced #267 one level down, which is
   what an early draft of this prototype did before the chunking was added.
   Windowing is scan-granularity only; it adds no new pattern and no new
   allow rule.

**5. Nothing auto-allowed from a hash alone; existing pending grants
unaffected.** The sha256 binding is integrity only — proof that what a
reviewer saw via `proposal --show` is what later executes (already true
today per `docs/design/complete-approval-payload.md`). It is never treated
as a verdict. `_cp_write_content_verdict` can return `deny` (reserved
pattern, path under `.git`, path outside worktree) or the unchanged `#277`
human-only `escalate` for write/edit — never a bypass of #277. No grant
table, no manifest-scope logic, no existing pending-approval record is
touched by this proposal.

**6. No new generic allow rules.** The only thing a human-authorized
activation of this proposal would change is *what text a write/edit panel
is judged on* (full structured content vs. a size-capped scrape) and
*that size alone stops gating whether judgment happens*. The judgment
itself — containment, reserved patterns, `.git`/`.gitconfig` write/symlink
guards, `.handoffs` scope, and `#277`'s categorical human-only rule for
every non-human authority — is unchanged. A peer or conductor still cannot
auto-approve a write/edit panel of any size, by any path through this
design.

## Activation checklist (for a human, later, explicit)

1. Wire `_cp_write_content_verdict` as a pre-check inside `classify_command`
   (before `_cp_input_ceiling_hit`) and `peer_decide`/`conductor_reserved_reason`
   (same point), gated on panel shape matching `_cp_non_shell_panel_tool`
   write/edit — mirroring how `_cp_write_menu_verdict` is already dispatched
   at `lib/command-policy.sh:7215-7232`, not a new dispatch mechanism.
2. Extend `verify-command-policy.sh`'s existing `#267` suite
   (`:4612-4656`) with the cases from `verify-write-content-verdict-267.sh`.
3. Confirm the wB4/wB2 incident's actual `selections.jsonl` rows / hub event
   log: did a Deny attempt ever reach `herdr-select.sh` for either prompt,
   or did the prompt sit with no automated resolution attempted in either
   direction (the likelier explanation per `verify-write-panel-267-repro.sh`,
   which reproduces Deny succeeding against the real script).
4. Trace what populates `task_input_required_tool`'s answer end to end (the
   push-wake/panel-level tool signal, distinct from the hook's own `seen`
   tool) to confirm whether it can genuinely mis-detect "write" as "bash"
   for a real oversized panel, before deciding whether gap2 needs a fix at
   all, and if so, which signal is the wrong one.
5. Security review (auth/money/external-comms-adjacent: approval policy)
   before merge, per team rules.
