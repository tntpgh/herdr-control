---
description: Sandbox pane resolution, the required read-path-then-write-path verification order, and honest observed-vs-inferred reporting for herdr-select.sh / peer-answer.sh.
globs: ["herdr-select.sh", "peer-answer.sh", "guard-raw-prompt-answer.sh", "slack-bridge/herdr-notify.sh", "settings.example.json"]
---
# Sandbox, Approvals & Verification

## Step 6 — sandbox, if your agent runs sandboxed

Pane resolution needs the herdr socket and the **tmux** socket. Without tmux,
alerts still send but cannot work out which pane asked, so replies have nowhere
to go — and it fails *silently*. See the `_sandbox_note` in
`settings.example.json`.

## Step 7 — verify, in this order

**Read path.** From a pane running an agent:

```bash
./slack-bridge/herdr-notify.sh --dry-run --choices "test alert"
```

`pane=<id>` must be the pane you ran it in. `pane=none` means resolution failed
— check the tmux socket (step 6). Then send one for real (drop `--dry-run`) and
confirm it arrives in Slack.

**Write path.** Reply to that alert in the thread with a number. Because no
prompt is on screen, the correct result is a refusal:

> ⚠️ herdr-select: refusing to press a key into a pane that did not ask a question.

That is a **pass**, not a failure: it proves routing, the allowlist, the
workspace check and the guard all work, without touching a live agent.

**Retraction.** After a real prompt is answered in the terminal, the alert
should disappear from Slack within a tool call or two.

## Step 8 — report honestly

Tell the human which of these you actually observed versus inferred. In
particular, an alert firing on a **live numbered prompt** can only be verified
when a real prompt occurs — if you have not seen one, say so rather than
implying the flow is fully proven.

Same standard for omp and for peer-authority answering: verifying the extension
symlink resolves is not the same as watching a real `omp` approval menu get
answered, and verifying `herdr-select.sh --authority peer` refuses a
not-yet-prompting pane (Step 7's write-path check) is not the same as watching
it correctly REFUSE a live prompt whose command classifies as `escalate` or
`deny`. Report exactly which of these you watched happen versus which you are
inferring from reading the code.
</content>
<parameter name="i">Write sandbox-approvals.md rule file