# AGENTS.md — activating herdr-control

Instructions for an agent (Claude Code, Codex, …) asked to set this up. Written
to be followed top to bottom. Verify each step before moving on; several
failures here are **silent**, and the whole point of this tooling is alerts you
can trust.

Human-facing docs: `README.md` (what it is), `SKILL.md` (what it does and why it
refuses things).

---

## Rules for this setup

1. **Never overwrite `~/.claude/settings.json`.** It is personal and often holds
   secrets and unrelated config. Use `./install.sh --apply`, which merges only
   its own entries and backs up first. If you must hand-edit, merge — do not
   replace.
2. **Never commit a credential.** Tokens belong outside the repo (gitignored,
   mode 600), referencing a secret manager rather than containing literals.
   `settings.example.json` is the only file that may show config shape, and it
   contains placeholders only.
3. **Stop and ask the human** for anything needing a browser or a credential:
   generating tokens, signing in to a secret manager. You cannot do these, and
   guessing wastes a round trip.
4. **Do not enable the send path until the read path works.** Confirm prompts
   are detected before confirming answers land.

---

## Rules for working in this repo

This repo's own command policy (`lib/command-policy.sh`, via `herdr-select.sh`)
judges every bash command you run here, so a denial is a verdict, not noise.

- **A denied command stays denied.** Do not re-issue it, reword it, or re-wrap it
  in `eval`/`python` to get past the classifier — that is circumventing a
  control. Report the denial and its reason instead of retrying.
- **Reserved filenames are human-only.** When what got refused is argv naming a
  policy file, inspect that file with your read/grep tools rather than trying
  more bash variants; to *run* a verification script whose own name is reserved,
  call it from a short throwaway wrapper under `tmp/`.
- **Read back multi-line edits.** Re-read the changed region before moving on —
  duplicated `fi`/`return` lines and continuations orphaned onto the wrong line
  are the recurring failure here.

---

## Details live in `.omp/rules/`

The step-by-step activation runbook, sandbox/verification
mechanics, and the troubleshooting table moved to path-scoped rules — each fires
only when you touch the files it's about, instead of loading on every turn here:

- `.omp/rules/activation-install.md` — prerequisites, `config.sh`, `install.sh`,
  the omp extension symlink.
- `.omp/rules/sandbox-approvals.md` — sandboxed pane resolution, the
  write-path verification check, honest observed-vs-inferred reporting.
- `.omp/rules/tab-naming-attention.md` — `smart-name.sh`, `attention.sh`, the
  herdr config snippet.
- `.omp/rules/troubleshooting.md` — symptom → cause table.
</content>
<parameter name="i">Write trimmed guardrail-only AGENTS.md