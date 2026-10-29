# Stuck write/edit saves (GBP wB4:p4, Intel wB2:p7) — operational fix

Status: **design + small local hardening, not an activation**. This document
explains why a large write/edit panel (a big heredoc save, or any call whose
content is large enough to push its panel out of the visible capture) can
end up with **no truthful resolution path at all** — not Approve, not Deny
— and separates what is genuinely small and local to fix from what is not.

Nothing here reactivates `#267`'s own prototype
(`_cp_write_content_verdict`, still zero callers — see
`docs/design/write-panel-ceiling-267.md`), wires anything into
`classify_command`/`peer_decide`/`conductor_reserved_reason`/
`herdr-select.sh`, or touches the live GBP/Intel panes.

## Root cause: everything downstream of a write/edit panel's resolution
## depends on the PAINTED SCREEN, which is lossy exactly where it matters most

Two independently confirmed failure modes
(`docs/design/write-panel-ceiling-267.md`, "Deny-not-pressable" and
"Deferred-occurrence tool mismatch" sections;
`verify-write-panel-267-repro.sh`, 7/7, reproduces both against the real,
unmodified code) turn out to be the same root cause wearing two faces: both
`herdr-select.sh`'s mechanism resolution and its deferred-occurrence
cross-check read **whatever is currently painted on screen**, and a write/
edit panel is precisely the shape most likely to defeat that:

| What depends on the screen | File:line | Why it is lossy for a large write |
|---|---|---|
| `_current_offer`'s menu detection | `herdr-select.sh:420-436` → `prompt_menu_options` → `_menu_gate` (`lib/prompt-parse.sh:596-599`, needs literal `navigate`+`select` text) | A write panel's content is rendered one row per wrapped line; tall enough content pushes the Approve/Deny footer out of the captured/visible window (`_pane_read_raw`, `--lines $_PANE_WINDOW_LINES`, `lib/prompt-parse.sh:483,556-558` — bounded in practice by the real terminal's own row count, not by the 1000-line argument). `_menu_gate` then fails and `_current_offer` falls through to the numbered-prompt parser (`prompt_options`, `lib/prompt-parse.sh:163-166` → `_prompt_window`, `:47-65`, itself a bottom-anchored "last 25 non-blank lines" scan), which matches an omp `Steering · N` queued-message block above the panel instead. |
| `label`/`declining` resolution | `herdr-select.sh:454` (`label=` from whatever `$options` the mis-detected mechanism returned), `:476-478` (the `declining=1` case statement, which never matches steering text) | A steering row's text is never `Deny|deny|No|...`, so `declining` stays `0` for an actual Deny keypress — confirmed end to end, `verify-write-panel-267-repro.sh`'s "Deny-not-pressable repro": `rc=8`, 0 keys, `classify_command`'s #267 ceiling verdict applied as if Deny were Approve. |
| The deferred-occurrence tool cross-check | `herdr-select.sh:834-839` (`task_input_required_tool "$own_run" "$own_task" "$current_prompt_id"`, `lib/run-registry.sh:1968-1977`) feeding `herdr-select.sh:889-891` (`proposal` subcommand) → `proposal_check` (`lib/prompt-occurrence.py:1138`, refusal at `:1194-1195`) | `current_prompt_id` is computed from **whatever is on screen right now**. A write/edit call that never paints its own panel at all (confirmed live, dashboard w9T:p4Q — `proc://preview-http/kill`-shaped, no panel) has its `screen()` probe (`lib/prompt-occurrence.py` `seen`/`screen` two-step, same order production uses) record **whatever panel actually was on screen at probe time** — a stale, unrelated bash box from the prior tool call. The cross-check then correctly, truthfully reports that the occurrence's own tool (`write`) disagrees with the panel currently on screen (`bash`) — because it is telling the truth about two different calls, not failing to agree about the same one. |

### Why this makes a large/quiet write genuinely unresolvable today

Put together, a write/edit call whose content is large enough to either (a)
push its own panel's footer out of the capture, or (b) never render a
distinct panel at all, loses **both** resolution paths simultaneously:

- **Approve**: already categorically refused for every non-human authority
  by design (`herdr-control#277`, `herdr-select.sh:868-931`) — unaffected,
  not a bug.
- **Deny**: silently misrouted to a Steering row (case (a)) or blocked by a
  truthful-but-unhelpful cross-check refusal with no panel to press into
  at all (case (b)).

A human at the real terminal is not necessarily stuck (they can scroll, or
answer a steering prompt directly) — but every **automated** resolution
path (`herdr-select.sh`, `peer-answer.sh`, the peer/conductor lanes this
tooling exists to drive) is. The write just sits.

## Why the live mechanism-detection and cross-check code are NOT small/local fixes

`_current_offer`'s menu-vs-numbered fallback (`herdr-select.sh:420-436`,
`lib/prompt-parse.sh`'s `_prompt_menu`/`_prompt_window`) and
`proposal_check`'s identity cross-check (`lib/prompt-occurrence.py:1138`)
are both **shared infrastructure for every approval type**, not
write/edit-specific:

- `_current_offer` resolves the mechanism for bash, write, edit, and every
  other tool's approval panel. Changing when it falls through to the
  numbered parser, or making it fail closed on a "header present, footer
  absent" shape, changes behavior for every live pane watched by this
  tooling today — exactly the kind of blast radius this file's own R1-R6
  commit history (cited throughout `lib/prompt-parse.sh`) shows is never
  safe to change without the equivalent of a full security review and a
  sweep across all 14 live panes (the precedent at `lib/prompt-parse.sh:84`
  is literally that: "swept across all 14 live panes at N=0..6").
- `proposal_check`'s cross-check is the SAME mechanism `#277`'s exact
  binding proof depends on (`docs/design/complete-approval-payload.md`) —
  loosening it to tolerate a stale screen reopens exactly the identity-
  spoofing class that design closed.

Per the conductor's own framing ("if the fix is small and local") — it is
not. Both remain the two separate, explicit, human-reviewed follow-up
proposals already named in `docs/design/write-panel-ceiling-267.md`'s
activation checklist (items 5 and 6): fail `_current_offer` closed instead
of falling through to the numbered parser when a truncated omp header is
detected without its footer; and resolve a deferred, no-panel-painted
occurrence by its own `screen_prompt_id` presence/absence rather than by
cross-checking against whatever happens to be on screen right now. Neither
is implemented here.

## The minimal operational fix through the supported path — small, local, implemented here

The conductor's four stated requirements for the supported path are
`#267`'s own Requirements 1–4 (`write-panel-ceiling-267.md`, "Design,
addressing every stated constraint"). Three of the four are **already true
today**, entirely independent of the two unfixed live bugs above, because
`_cp_write_content_verdict` (`lib/command-policy.sh:6896-7013`) never reads
the painted screen at all — it takes the occurrence's STRUCTURED `path`/
`content` directly, the same full, untruncated payload the hook records at
dispatch time (`docs/design/complete-approval-payload.md`'s `seen`
`--input-json`, never clipped the way the painted panel is):

1. **Full content is shown to the reviewer.** `prompt-occurrence.py
   proposal --show` (`lib/prompt-occurrence.py`, cited at
   `write-panel-ceiling-267.md:95,178-183`) already prints the complete
   recorded payload up to `PROPOSAL_MAX_BYTES` (256 KiB), independent of
   what any terminal panel shows or how tall it is.
2. **Every semantic check runs on the full content.**
   `_cp_write_content_verdict`'s windowed `conductor_reserved_reason` scan
   (`:6985-7012`) already covers the complete content, window-boundary
   cases included (`verify-write-content-verdict-267.sh`'s straddling
   tests).
3. **No hash-only allow.** `_cp_write_content_verdict` has no hash/digest
   parameter at all — nothing resembling "trust the sha256, skip the
   review" exists in its signature or body.
4. **Deny stays pressable and truthful.** NOT fully true yet — see above;
   `_cp_write_content_verdict` itself cannot regress it further (it is a
   pure classifier: no registry writes, no event appends, no interaction
   with `herdr-select.sh`'s `declining` variable or keypress path at all —
   confirmed by a new structural test below), but it also cannot fix it.

What was genuinely missing — and is small, local, and fixed here, in the
same inert posture as the rest of `#267` (zero callers,
`verify-command-policy.sh` unaffected) — were two gaps in requirements 2–3
that a caller could otherwise exploit by accident or by malice while
claiming "the supported path was followed":

- **Empty/whitespace content silently allowed.** Before this change,
  `_cp_write_content_verdict ""` classified `allow` — there is nothing to
  review in an empty string, so "the content was judged" was never true
  for it. This is the structural shape of "approve by asserting a hash
  matches, without supplying real content for review" — closing it removes
  that shape entirely, not just a specific hash-shaped payload.
- **A painted-panel elision marker embedded in content was not detected.**
  The established codebase convention for "this text is a clipped view,
  not the real thing" is a literal `elided`/`truncated` substring check
  (`herdr-select.sh:1008-1012`, `lib/alert-gate.sh:89-90`) — applied today
  only to the SCRAPED panel text. `_cp_write_content_verdict` had no
  equivalent guard on its own `content` parameter, so a caller that
  accidentally (or deliberately) passed through an already-clipped
  `[…247ch elided…]`-shaped string instead of the real structured payload
  would have had it judged as if it were complete.

Both are fixed in `_cp_write_content_verdict` (`lib/command-policy.sh`):
empty/whitespace-only content now returns
`deny:empty content — nothing to review`; content containing an
elided/truncated marker now returns
`escalate:content carries an elision/truncation marker — this is not the
complete payload, refusing to judge a partial view`. Four new tests in
`verify-write-content-verdict-267.sh` cover: empty content denies; an
elided-marker-bearing content escalates (never allows); a hash-shaped
string used AS content is judged as ordinary text with no special
bypass (still denies/allows on its actual content, proving there is no
hash-recognition shortcut); and a structural confirmation that
`_cp_write_content_verdict` makes zero registry/event/`declining` writes
(grep-based, same convention as the existing four `declining=0` gate
checks).

## Status

- Still inert: `_cp_write_content_verdict` has zero callers; no change to
  `classify_command`, `peer_decide`, `conductor_reserved_reason`,
  `herdr-select.sh`, or `lib/prompt-parse.sh`/`lib/prompt-occurrence.py`.
- Deny-not-pressable and the deferred-occurrence stale-screen mismatch
  remain unfixed, as explained above — tracked as
  `write-panel-ceiling-267.md`'s activation checklist items 5 and 6.
- GBP (wB4:p4) and Intel (wB2:p7) are untouched; this change cannot affect
  their panes (zero callers, no network, no live state writes).
