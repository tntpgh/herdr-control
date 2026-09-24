---
description: Prerequisites, config.sh knobs, and running install.sh to wire the Claude/omp hooks for herdr-control activation.
globs: ["install.sh", "config.sh", "agent-hooks/**"]
---
# Activation & Install

## Step 1 — prerequisites

```bash
command -v herdr jq python3 curl tmux sqlite3
herdr status
```

All must exist and `herdr status` must show a running server. `sqlite3` backs
the run registry (`lib/run-registry.sh`) that `spawn-task.sh` and
`herdr-select.sh` depend on — it ships with macOS by default, so this check
rarely fails there, but confirm it explicitly rather than discovering it
mid-run. If herdr is not installed or not running, stop: nothing else can
work.

## Step 2 — configure

```bash
$EDITOR config.sh
```

`config.sh` is the only file with machine defaults (which agent to launch, PATH
for a minimal environment, sort preferences, Codex model tier names). Everything
else is generic. Leave the defaults unless the human asks otherwise.

Two defaults worth knowing about, not changing: `HERDR_POSTURE_FLOOR` (the
loosest approval posture any worker may be spawned at — default `write`;
`lib/posture.sh`) and `HERDR_POLICY_EXTRA_RULES` (site rules for the
command-policy classifier — `lib/command-policy.sh`). Both can only make
things *stricter* than their default, never looser, so there is no failure
mode from leaving them alone.

## Step 3 — wire the hooks

```bash
./install.sh            # dry run — shows what it would change, writes nothing
./install.sh --apply
```

Expected on a fresh machine: three `+` lines (Notification, PostToolUse, Stop).
Expected on a machine already wired: three `=` lines and "nothing to do" — it
matches on aliases, so an existing hook under a different filename is detected
rather than duplicated. **Duplicate hooks double every alert**, so if you see a
`+` for a job that is already wired, investigate before applying.

Verify:

```bash
python3 -c "import json;d=json.load(open('$HOME/.claude/settings.json'));print(list(d['hooks']))"
```

The JSON must still parse. If it does not, restore the `.bak-herdr-*` backup
`install.sh` wrote.

## omp extension (skip if you don't use omp)

The same `./install.sh --apply` above also symlinks `agent-hooks/omp-herdr-control.ts`
into `~/.omp/agent/extensions/herdr-control.ts` (or `$PI_CODING_AGENT_DIR/extensions`
when set) — no separate command to run. It gives an omp session the same four jobs
the Claude hooks above give a Claude session (push-wake, session reconciliation,
mid-session reconciliation, alert retraction), through omp's own extension events
instead of `settings.json`.

Verify the symlink exists and resolves into THIS checkout:

```bash
readlink -f ~/.omp/agent/extensions/herdr-control.ts
```

The output must be `$here/agent-hooks/omp-herdr-control.ts` — `$here` being the
path this checkout lives at (`install.sh`'s own output names it too: `= omp
extension already wired -> ...` on a re-run, or `+ omp extension ... -> ...` on a
fresh install). `! omp extension refusing to overwrite non-symlink file` means a
real file already occupies that path and install.sh left it alone — investigate
before removing anything by hand.

A push wake still only reaches a worker `spawn-task.sh` launched: it needs
`HERDR_PANE_ID` stamped into the worker's environment, and a hand-started omp
session has none, so it stays reconciliation-only — the same limitation a
hand-started Claude session already has.

If the operator does not use omp, skip this entirely: nothing else in this
runbook depends on it, and it does not affect the Claude hook wiring above.