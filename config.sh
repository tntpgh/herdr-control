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

# ---- agent-hooks/interval-reconcile.sh (mid-session wake persistence) ------
# Seconds between full reconciliation sweeps within one live session (the
# throttle is activity-gated — it only checks on a tool call, see the file's
# own header). Lower = more responsive lost-detection/reporting mid-session,
# at the cost of a `herdr pane list` call that often:
: "${HERDR_RECONCILE_INTERVAL_S:=300}"

# ---- session-reconcile.sh retention (terminal task-file pruning) -----------
# Task files in a terminal state (completed/failed/cancelled/lost) older
# than this many days are removed on every SessionStart sweep
# (lib/run-registry.sh's prune_completed_tasks). Nothing else prunes the
# registry, so this is the only thing keeping run_state_root from growing
# forever on a long-lived host.
: "${HERDR_TASK_RETENTION_DAYS:=14}"

# ---- spawn-task.sh model routing (job-class -> model) ----------------------
# Claude tiers use the standard aliases (opus/sonnet/haiku) and need no config.
# Codex model names are yours — edit to match your Codex setup.
# Format: "<model>:<reasoning-effort>".
: "${HERDR_CODEX_DEEP:=gpt-5.6-sol:high}"     # plan / architect / review / design
: "${HERDR_CODEX_STD:=gpt-5.5:medium}"        # implement / debug / code
: "${HERDR_CODEX_FAST:=gpt-5.4-mini:low}"     # explore / quick / mechanical / docs

# ---- shared state (smart-name.sh ownership/debounce, attention.sh stalls) ---
# Where the tools remember what they've done. Removable at any time; the tools
# rebuild it. Kept out of the repo and out of ~/.config/herdr on purpose.
: "${HERDR_STATE_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"

# ---- smart-name.sh (tabs that say what the work is) ------------------------
# 1 = call a model for ambiguous work; 0 = deterministic names only (no key,
# no cost, no network). Known processes (Run Tests / Dev Server / View Logs /
# Remote Shell) are named without a model either way.
: "${SMART_NAME_AI:=1}"
# Which summariser CLI to call: auto (claude if present, else omp — preserves
# pre-existing behaviour on an install that already had claude configured,
# even after omp is added to PATH later), or force one explicitly.
: "${SMART_NAME_BACKEND:=auto}"
# The model that proposes labels. Naming is a trivial task — keep it cheap.
: "${SMART_NAME_MODEL:=haiku}"
# Hard ceiling on a single model call, seconds. Timed-out calls just abstain.
: "${SMART_NAME_TIMEOUT:=25}"
# Don't re-name a tab we already named more recently than this (seconds) unless
# --force or the evidence changed. Tames churn on a busy pane.
: "${SMART_NAME_COOLDOWN:=45}"
# Max serialized evidence sent to the model. Bounded + sanitized before it goes.
: "${SMART_NAME_EVIDENCE_CHARS:=4500}"

# ---- attention.sh (honest waiting-reason signal engine + focus view) -------
# An agent whose screen hasn't changed in this many seconds, with no permission
# prompt up, is reported "stalled" rather than "working". Needs two runs to
# fire (the first records a baseline).
: "${HERDR_STALL_SECS:=90}"

# ============================================================================
#  End of your config — generic below.
# ============================================================================
export HERDR_DEFAULT_AGENT HERDR_SOURCE HERDR_SOCK HERDR_SORT_DONE_FIRST HERDR_SORT_NO_GH
export HERDR_CODEX_DEEP HERDR_CODEX_STD HERDR_CODEX_FAST
export HERDR_RECONCILE_INTERVAL_S HERDR_TASK_RETENTION_DAYS
export HERDR_STATE_DIR SMART_NAME_AI SMART_NAME_BACKEND SMART_NAME_MODEL SMART_NAME_TIMEOUT
export SMART_NAME_COOLDOWN SMART_NAME_EVIDENCE_CHARS HERDR_STALL_SECS
export PATH="$HERDR_EXTRA_PATH:/usr/bin:/bin:${PATH:-}"
