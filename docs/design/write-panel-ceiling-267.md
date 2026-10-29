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

## Deny-not-pressable — CONFIRMED, one root cause for both halves of the report

Live evidence (conductor, GBP wB4:p4, ~03:45Z): `herdr-select wB4:p4 2
--expect-prompt-id ...` was refused for what looked like two reasons —
(a) "classified text was 7310 bytes, over the 4096 ceiling"; (b) it
resolved "option 2" to a **Steering queue row**
("Conductor: your oversized write was refused...") instead of the panel's
Deny. Both are the **same bug**, reproduced end to end against the real
`herdr-select.sh` and `lib/prompt-parse.sh`
(`verify-write-panel-267-repro.sh`, "Deny-not-pressable repro"):

1. omp paints a `Steering · N` queued-message block **above** the write
   panel. When the panel's content is tall enough (wrapped across many
   rows) that the captured/visible window ends **before** the Approve/Deny
   footer, `prompt_menu_options`'s `_menu_gate` — which requires both
   `navigate` and `select` from the footer text — fails, because the
   footer simply never entered the window.
2. `_current_offer` (`herdr-select.sh:420-436`) is "MENU FIRST" specifically
   to avoid a steering block hijacking option resolution (a 2026-09-05
   precedent, same file, same comment) — but that protection only holds
   while `prompt_menu_options` actually returns something. When it returns
   empty, `_current_offer` falls through to `prompt_options`, the
   **numbered**-prompt parser — which DOES match the Steering block's own
   `N. Conductor: ...` rows (they are within `_prompt_window`'s last-25-
   non-blank-line scan).
3. `label` for `choice=2` now resolves to the steering row's text
   ("Conductor: please retry once under the 4096-byte panel limit"), not
   "Deny". `herdr-select.sh:477`'s case statement
   (`Deny|deny|No|no|...) declining=1 ;;`) does not match that text, so
   `declining` **stays 0**.
4. Downstream, `classify_command` denies on the >4096-byte ceiling (#267's
   original bug) or escalates on garbled panel text (either verdict is
   non-`allow`), and because `declining=0`, the conductor/peer non-human-
   authority gates (`herdr-select.sh:1015`, `:1063`) apply that verdict as
   if the human were trying to **Approve**, not Deny. Exact reproduced
   output, byte-for-byte matching the live report:
   ```
   herdr-select: REFUSED (deny) — a human must answer this one.
   herdr-select: classified text is 5092 bytes, over the 4096-byte safety
   ceiling (herdr-control#267) — split the command or run a script file by
   reference
   herdr-select: option 2 (Conductor: please retry once under the
   4096-byte panel limit) in wB4:p4 was NOT pressed.
   ```

**This falsifies this document's earlier §3 claim** ("Deny is always
pressable... codifies today's already-true behavior"). That claim is true
only for the `declining=1`-gated refusal sites themselves — every one of
them really is `declining=0`-gated, exactly as stated. The bug is one layer
**upstream**: `declining` can be silently left at `0` for an actual Deny
keypress, because mechanism resolution (`lib/prompt-parse.sh`) mis-detects
which menu is on screen. `_cp_write_content_verdict` (this proposal's
prototype) cannot fix this — it is never reached; the failure is entirely
in prompt/option resolution, before `classify_command` is even the
relevant layer. **This needs its own, separate proposal** against
`lib/prompt-parse.sh`'s `_current_offer`/`prompt_options` fallback, not
`lib/command-policy.sh`. Candidate direction (not implemented, not
reviewed): when `prompt_menu_options` returns empty but the captured window
contains an `Allow tool:` header with no matching footer, that is
*evidence of a truncated omp panel*, not *evidence of no omp panel at
all* — `_current_offer` should fail closed (escalate/refuse to navigate)
rather than silently falling through to the numbered-prompt parser, which
can match unrelated numbered content (steering, or ordinary numbered agent
prose) with no indication anything was mis-resolved. This mirrors the
fail-closed principle `_prompt_menu_parse` already applies to its own two
passes (`lib/prompt-parse.sh:748-752`: "the risk it removes is a real menu
that cannot be answered at all").

`verify-select-policy.sh`'s existing `boxed_panel` convention (bordered,
padded, same shape as a real omp panel) is what let this reproduce
precisely — the fixture needs the SAME bordered/padded overhead a real
panel paints, since omp's write panel preview caps at ~2000 UTF-16 units
of raw content (`docs/design/complete-approval-payload.md`), so most of
the >4KB scraped-text size the live incident saw must be structural
(border/padding/one-row-per-wrapped-line), not raw content bytes.

## Deferred-occurrence tool mismatch — CONFIRMED, two reproductions

Reproduced exactly (`verify-write-panel-267-repro.sh`, "gap2 repro"), against
the real `proposal_check` (`lib/prompt-occurrence.py:1138`, called by
`herdr-select.sh:889-891` as the `proposal` subcommand — **not**
`pending-bound`, a different, exact-binding-only lookup used later at
`:904-906`, which the first draft of this investigation mistakenly called
instead and so failed to reproduce anything):

```
{"ok": false, "reason": "occurrence tool 'write' is not the write/edit tool on screen ('bash')"}
```

**Mechanism, now confirmed end to end** (live incident, dashboard pane
w9T:p4Q, ~03:48Z — a deferred write occurrence `508d50d8`, tool=write,
`proc://preview-http/kill`, no panel ever painted for it; the screen still
showed the previous bash command's box; "gap2 repro v2" reproduces this
exact shape, not a hand-passed `--tool`): `proposal_check` refuses whenever
its `--tool` cross-check argument disagrees with the tool recorded on the
matching occurrence. The cross-check argument is `$registry_tool_lc`
(`herdr-select.sh:836-837` → `task_input_required_tool`, reading the
`input_required` event recorded for the **current on-screen prompt_id** —
here, the stale bash panel's). A deferred write occurrence registers its
own `seen` tool at dispatch time, but its `screen` correlation (the probe
that runs after dispatch) records **whatever is actually on screen at that
moment** — here, the still-rendered bash panel, since the write never
painted its own. So the write occurrence's own `screen_prompt_id` equals
the stale bash panel's prompt_id, and when something later asks "what tool
is pending for this prompt_id", `task_input_required_tool` correctly
answers for the **panel that is actually there** ("bash"), which
legitimately disagrees with the deferred write's own recorded tool
("write"). This is not two signals racing or disagreeing about the SAME
call — it is one signal (the painted panel) correctly describing a
DIFFERENT, earlier call than the one a reviewer is asking about. **Any**
tool call that paints no panel of its own inherits whatever panel was
already on screen when something probes the cross-check — not specific to
write panels, large content, or #267's size ceiling at all.

Recommend **not** silently loosening the cross-check (it is correctly
catching a real mismatch in this exact case): whoever resolves a deferred,
no-panel-painted write occurrence needs to stop asking "what does the
CURRENT screen say", and instead check whether the occurrence has a
`screen_prompt_id` at all / whether a NEW panel for it has since appeared
— a proposal for `herdr-select.sh`'s `pending-bound`/`proposal` call sites
around `:884-906`, not for this one (`lib/command-policy.sh`).

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
This codifies today's *already-true* behavior for the refusal sites
themselves (every `policy_verdict` gate really is `declining=0`-
conditioned, confirmed by grep) as an explicit invariant instead of an
emergent property of scattered conditionals. **It does not fix
Deny-not-pressable** — see "Deny-not-pressable" above: `declining` itself
can be wrongly left at `0` for a genuine Deny keypress, one layer upstream
in `lib/prompt-parse.sh`'s mechanism resolution, before any of these gates
run. That needs its own separate proposal.

**4. Tests: truncation + prompt injection + windowing + normalization.**
`verify-write-content-verdict-267.sh` (committed; converted from a `tmp/`
scratch script) exercises the prototype directly — it has no live caller,
so this is the only way to exercise it — 16/16 checks pass:
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
- A reserved pattern straddling each window boundary (4000 B and 7488 B)
  still denies, plus a same-shaped negative control that allows — proves
  the windowed `conductor_reserved_reason` scan has no blind spot at a
  seam, and that windowing did not introduce a false positive either.
- A case-insensitive credential-path variant past 4096 B still denies
  (`~/.SSH/ID_RSA`) — the reserved-pattern scan stays case-insensitive at
  any content size, matching `conductor_reserved_reason`'s own behavior.
- A regression marker: `classify_command`/`peer_decide`, UNCHANGED by this
  commit, still deny the same 7 KB write panel on size alone today — this
  flips only once activation (checklist below) wires the prototype in.

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
3. **Separate proposal, before or alongside this one**: fix
   Deny-not-pressable in `lib/prompt-parse.sh`'s `_current_offer` (see
   "Deny-not-pressable" above) — `declining` must never stay `0` for an
   actual Deny keypress because a Steering block got matched instead of
   the omp menu. This is the live incident's actual root cause and is
   independent of `lib/command-policy.sh`; this proposal's prototype does
   not touch it.
4. **Separate proposal**: fix the deferred-occurrence tool cross-check
   (`herdr-select.sh:884-906`) to stop comparing a no-panel-painted
   occurrence against whatever panel happens to be on screen (see
   "Deferred-occurrence tool mismatch" above) — resolve by the
   occurrence's own `screen_prompt_id` presence/absence, not by
   `task_input_required_tool` on the CURRENT prompt.
5. Security review (auth/money/external-comms-adjacent: approval policy)
   before merge, per team rules.
