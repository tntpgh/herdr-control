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

## Hook adoption: getting a PR's hook bytes live

The Claude hook commands in `settings.json` and the omp extension symlink
both point at a CHECKOUT PATH, not a commit — `install.sh`'s `$here`, i.e.
wherever it was run from. A PR branch's hook bytes (e.g. PR #273) go live
only if something resolves to them:

1. **The installed symlink/hook commands point at whichever checkout
   `install.sh --apply --repoint` was last run from** (`install.sh:27-31,
   336-353` — repoint is a deliberate opt-in; a plain re-run never moves an
   existing wiring). If that was the long-lived `~/Code/herdr-control`
   checkout on `main`, PR bytes that only exist on a branch/worktree are not
   live anywhere, merged or not — the bash hooks (`claude-notify.sh`,
   `claude-pretooluse-cache.sh`, `herdr-resolve.sh`,
   `interval-reconcile.sh`, `session-reconcile.sh`) read straight off disk
   at call time, so whichever checkout the command path resolves into is
   what runs, even without a daemon restart.
2. **To adopt a PR for real: merge it to `main`, update the checkout the
   symlink/hooks point at** (`git -C ~/Code/herdr-control pull`, or
   `install.sh --apply --repoint` from the checkout that should now own it),
   **then reload:**
   - Claude Code hooks: no reload needed — each event execs the hook path
     fresh, so updated bytes on disk take effect on the very next event.
   - omp extension (`~/.omp/agent/extensions/herdr-control.ts` ->
     `agent-hooks/omp-herdr-control.ts`): omp's loader hot-reloads on a
     change to the FILE the symlink currently resolves to
     (`agent-hooks/omp-herdr-control.ts:93-97`, confirmed in that file's own
     comment). Whether a symlink *retarget* (new realpath, not just new
     bytes at the same path) is picked up without restarting the omp
     session is **not verified here** — `[INFERENCE]` only, not exercised
     live. Treat "symlink now points at the new checkout" as requiring a
     fresh omp session until someone confirms otherwise.
3. **This worktree is not an adoption path.** A task worktree
   (`~/.herdr/worktrees/herdr-control/<branch>`) is disposable — running
   `--repoint` from one wires a checkout that gets deleted, silently
   breaking every hook and the omp extension the next time cleanup runs.
   Adoption always targets a durable checkout (`~/Code/herdr-control` on
   `main`, or an explicit APM deploy path), never a worktree.
