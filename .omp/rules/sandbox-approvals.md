---
description: Sandbox pane resolution, the write-path verification check, and honest observed-vs-inferred reporting for herdr-select.sh / peer-answer.sh.
globs: ["herdr-select.sh", "peer-answer.sh", "guard-raw-prompt-answer.sh", "settings.example.json"]
---
# Sandbox, Approvals & Verification

## Step 6 — sandbox, if your agent runs sandboxed

Pane resolution needs the herdr socket and the **tmux** socket. Without tmux,
the hooks cannot work out which pane asked, so answers have nowhere
to go — and it fails *silently*. See the `_sandbox_note` in
`settings.example.json`.

## Step 7 — verify

**Write path.** From a pane with no prompt on screen, try to answer it with
`herdr-select.sh`. Because no prompt is on screen, the correct result is a
refusal:

> ⚠️ herdr-select: refusing to press a key into a pane that did not ask a question.

That is a **pass**, not a failure: it proves pane resolution and the guard
work, without touching a live agent.

## Step 8 — report honestly

Tell the human which of these you actually observed versus inferred. In
particular, a wake for a **live numbered prompt** can only be verified
when a real prompt occurs — if you have not seen one, say so rather than
implying the flow is fully proven.

Same standard for omp and for peer-authority answering: verifying the extension
symlink resolves is not the same as watching a real `omp` approval menu get
answered, and verifying `herdr-select.sh --authority peer` refuses a
not-yet-prompting pane (Step 7's write-path check) is not the same as watching
it correctly REFUSE a live prompt whose command classifies as `escalate` or
`deny`. Report exactly which of these you watched happen versus which you are
inferring from reading the code.