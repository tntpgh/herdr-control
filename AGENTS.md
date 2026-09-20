# AGENTS.md — activating herdr-control

Instructions for an agent (Claude Code, Codex, …) asked to set this up. Written
to be followed top to bottom. Verify each step before moving on; several
failures here are **silent**, and the whole point of this tooling is alerts you
can trust.

Human-facing docs: `README.md` (what it is), `SKILL.md` (what it does and why it
refuses things), `slack-bridge/SETUP.md` (the Slack app).

---

## Rules for this setup

1. **Never overwrite `~/.claude/settings.json`.** It is personal and often holds
   secrets and unrelated config. Use `./install.sh --apply`, which merges only
   its own entries and backs up first. If you must hand-edit, merge — do not
   replace.
2. **Never commit a credential.** Tokens belong in `~/.config/herdr-bridge.env`
   (gitignored, mode 600), which should *reference* a secret manager rather than
   contain literals. `settings.example.json` and `herdr-bridge.env.example` are
   the only files that may show config shape, and they contain placeholders only.
3. **Stop and ask the human** for anything needing a browser or a credential:
   creating the Slack app, generating tokens, enabling Interactivity. You cannot
   do these, and guessing wastes a round trip.
4. **Do not enable the send path until the read path works.** Confirm alerts
   arrive before confirming replies land.

---

## Details live in `.omp/rules/`

The step-by-step activation runbook, the Slack bridge setup, sandbox/verification
mechanics, and the troubleshooting table moved to path-scoped rules — each fires
only when you touch the files it's about, instead of loading on every turn here:

- `.omp/rules/activation-install.md` — prerequisites, `config.sh`, `install.sh`,
  the omp extension symlink.
- `.omp/rules/slack-bridge.md` — creating the Slack app, `herdr-bridge.env`,
  starting `run-bridge.sh`.
- `.omp/rules/sandbox-approvals.md` — sandboxed pane resolution, the
  read-path/write-path verification order, honest observed-vs-inferred reporting.
- `.omp/rules/tab-naming-attention.md` — `smart-name.sh`, `attention.sh`, the
  herdr config snippet.
- `.omp/rules/troubleshooting.md` — symptom → cause table.
</content>
<parameter name="i">Write trimmed guardrail-only AGENTS.md