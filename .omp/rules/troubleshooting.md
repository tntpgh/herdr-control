---
description: Symptom-to-cause table for herdr-control activation and hooks — consult when an alert, hook, or answer misbehaves.
globs: ["install.sh", "agent-hooks/**", "herdr-select.sh", "peer-answer.sh", "config.sh", "lib/alert-gate.sh", "lib/push-wake.sh"]
---
# Troubleshooting

| symptom | cause |
|---|---|
| `pane=none` | tmux socket unreachable, or the agent runs outside a herdr pane |
| prompt detected with no options | prompt not painted yet, or auto-approved before the hook read it |
| every alert arrives twice | two hooks wired for the same job — check `Notification` in settings.json |
| cannot write files under a `hooks/` directory | agent sandboxes commonly block writes to any path named `hooks/` (a writable `.git/hooks` is code execution on the next git command). This repo uses `agent-hooks/` for that reason — do not rename it back. If you hit this elsewhere, the write needs to happen outside the sandbox |
| omp session never alerts or pushes | check the extension symlink resolves (Step 3's omp subsection); a hand-started omp session (not via `spawn-task.sh`) has no `HERDR_PANE_ID` and is reconciliation-only by design |
| `herdr-select.sh` exits 8 | expected under `--authority peer` when the prompt's command classifies as `escalate`/`deny` — a human needs to answer it, not automation |
| `posture: unknown posture ... falling back to strict` on stderr | a typo in `HERDR_POSTURE_FLOOR` or a per-spawn posture request — fails closed on purpose, fix the name in `config.sh` |
| a prompt that is an ordinary command (`git status`, a test run, ...) never woke anyone | that is an ALLOW-class prompt (`lib/command-policy.sh` `classify_command`) — `lib/alert-gate.sh` `human_must_answer` HOLDS it for a peer. Check `classify_command "<the command>"` directly, or wait out the `grace_realert` conductor-wake re-check |
| hub crash-loops (KeepAlive respawns constantly) after a `brew upgrade python@3.1x` | the pinned interpreter path baked into the plist no longer exists — check `~/Library/Logs/com.herdr-control.hub.log` for an `exec`-failure line, then re-run `install.sh --apply --hub` to re-resolve and re-render; `.omp/rules/activation-install.md` "Hub interpreter pin" has the full mechanism |