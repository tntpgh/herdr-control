# ============================================================================
#  YOUR CONFIG — the only file with machine/personal specifics.
#  Every other file is generic. Edit the values here; leave the rest alone.
#  Each is overridable per-invocation as an environment variable too.
# ============================================================================

# The agent command `spawn-agent.sh` runs when you don't pass one explicitly.
# e.g. claude · codex · "aider" · a wrapper of your own.
: "${HERDR_DEFAULT_AGENT:=claude}"

# Extra dirs prepended to PATH so git/gh/jq/python3 (and your agent) resolve even
# when herdr runs a script with a minimal environment (e.g. from a keybinding).
#   Apple-Silicon Homebrew: /opt/homebrew/bin   Intel/Linux Homebrew: /usr/local/bin
: "${HERDR_EXTRA_PATH:=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}"

# Label these tools report themselves as in herdr's pane/agent metadata.
: "${HERDR_SOURCE:=herdr-control}"

# Path to the herdr control socket (rarely needs changing).
: "${HERDR_SOCK:=$HOME/.config/herdr/herdr.sock}"

# ---- sort-tabs.sh behaviour (also settable per run) ------------------------
# Finished tabs on top instead of attention-first:
: "${HERDR_SORT_DONE_FIRST:=0}"
# Skip gh entirely (git-only ranks; you lose reviewed/merged/waiting):
: "${HERDR_SORT_NO_GH:=0}"

# ---- spawn-task.sh model routing (job-class -> model) ----------------------
# Claude tiers use the standard aliases (opus/sonnet/haiku) and need no config.
# Codex model names are yours — edit to match your Codex setup.
# Format: "<model>:<reasoning-effort>".
: "${HERDR_CODEX_DEEP:=gpt-5.6-sol:high}"     # plan / architect / review / design
: "${HERDR_CODEX_STD:=gpt-5.5:medium}"        # implement / debug / code
: "${HERDR_CODEX_FAST:=gpt-5.4-mini:low}"     # explore / quick / mechanical / docs

# ============================================================================
#  End of your config — generic below.
# ============================================================================
export HERDR_DEFAULT_AGENT HERDR_SOURCE HERDR_SOCK HERDR_SORT_DONE_FIRST HERDR_SORT_NO_GH
export HERDR_CODEX_DEEP HERDR_CODEX_STD HERDR_CODEX_FAST
export PATH="$HERDR_EXTRA_PATH:/usr/bin:/bin:${PATH:-}"
