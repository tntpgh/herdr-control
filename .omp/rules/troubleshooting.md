---
description: Symptom-to-cause table for herdr-control activation and the Slack bridge — consult when an alert, hook, or reply misbehaves.
globs: ["install.sh", "agent-hooks/**", "slack-bridge/**", "herdr-select.sh", "peer-answer.sh", "config.sh", "lib/alert-gate.sh", "lib/push-wake.sh", "hub-connection-alert.sh"]
---
# Troubleshooting

| symptom | cause |
|---|---|
| alert names a pane but replies do nothing | Interactivity not enabled (buttons only); use a threaded number |
| `pane=none` | tmux socket unreachable, or the agent runs outside a herdr pane |
| alert has no options, only the message | prompt not painted yet, or auto-approved before the hook read it; the context block should still show what is on screen |
| every alert arrives twice | two hooks wired for the same job — check `Notification` in settings.json |
| `team=ANY (unbound)` at startup | `HERDR_BRIDGE_TEAM` unset; the workspace check is inert |
| refusal on every reply | expected when no prompt is showing; only a live prompt accepts a choice |
| cannot write files under a `hooks/` directory | agent sandboxes commonly block writes to any path named `hooks/` (a writable `.git/hooks` is code execution on the next git command). This repo uses `agent-hooks/` for that reason — do not rename it back. If you hit this elsewhere, the write needs to happen outside the sandbox |
| omp session never alerts or pushes | check the extension symlink resolves (Step 3's omp subsection); a hand-started omp session (not via `spawn-task.sh`) has no `HERDR_PANE_ID` and is reconciliation-only by design |
| `herdr-select.sh` exits 8 | expected under `--authority peer` when the prompt's command classifies as `escalate`/`deny` — a human needs to answer it, not automation |
| `posture: unknown posture ... falling back to strict` on stderr | a typo in `HERDR_POSTURE_FLOOR` or a per-spawn posture request — fails closed on purpose, fix the name in `config.sh` |
| an alert never showed up, and the prompt is an ordinary command (`git status`, a test run, ...) | that is an ALLOW-class prompt (`lib/command-policy.sh` `classify_command`) — `lib/alert-gate.sh` `human_must_answer` HOLDS it for a peer, it never reaches herdr-notify.sh at all. `HERDR_SLACK_VERBOSE=1` does NOT reveal this (nothing was ever attempted to suppress). Check `classify_command "<the command>"` directly, or wait out `HERDR_ALERT_GRACE_S` (default 90s) — an unanswered held prompt still alerts late |
| an alert never showed up, and the prompt IS escalate/reserved/deny-class (or a re-fired plain-context prompt) | the 2026-09-24 symptoms-only filter (SKILL.md "Symptoms only, not status") reached herdr-notify.sh and dropped it: a duplicate for an already-claimed (pane, key) within `HERDR_ALERT_DEDUP_TTL_S` (default 3600s), or a `--choices` alert with nothing left to show. Set `HERDR_SLACK_VERBOSE=1` on the hook's shell to restore always-post and confirm |
| conductor wake failed but nothing paged after 10 minutes | check `wake_fail_alerted` in the registry (`sqlite3 ~/.local/state/herdr/runs/registry.sqlite3 "SELECT * FROM events WHERE type='wake_fail_alerted'"`) — it only fires if the task is STILL `blocked` and the prompt is STILL on screen when `HERDR_WAKE_FAIL_ALERT_S` (default 600) elapses; answered any other way, it stays silent by design |