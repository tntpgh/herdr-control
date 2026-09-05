#!/usr/bin/env bash
# lib/agent-profiles.sh — the ONLY file that knows about specific agent CLIs.
#
# Every other script asks a question here ("what process names count as an
# agent", "what command launches <agent> at <job-class>'s model", "can this
# agent's prompts be answered, and how") instead of hardcoding a CLI's flags or
# prompt shape inline. Add a new agent by adding cases here — not by editing
# spawn-task.sh / lib/pane-guard.sh / smart-name.sh / herdr-select.sh, which
# used to each carry their own partial copy of this knowledge and drifted.
#
# Sourced by: lib/pane-guard.sh (process allowlist), spawn-task.sh and
# spawn-agent.sh (model routing + launch command + managed-flag policy +
# canonical rules), herdr-select.sh (which answering strategy a prompt
# needs). Pure — nothing here touches herdr or the filesystem — EXCEPT the
# canonical-rules helpers at the bottom (they read the operator's ancestor
# rules file and write a composed cache; only the spawners call them).
_ap_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_ap_dir/posture.sh"

# Process names herdr may see as a pane's foreground process for a
# recognized coding agent. HERDR_AGENT_PROCS (lib/pane-guard.sh) overrides
# this WHOLESALE when set — this list only supplies the default.
HERDR_AGENT_PROC_NAMES="claude codex omc omp herdr-reviewr aider opencode goose"

# ---- capabilities -----------------------------------------------------------
# What a given agent's TUI can actually do, declared per agent instead of
# assumed globally.
#
# Review correction 5 named the reason this exists: '"never send Enter" is a TUI
# implementation detail, not a durable invariant — different TUIs or versions
# may require different submission behavior. Encode this in an adapter
# capability, not the protocol.' Until now "press the bare digit, never Enter"
# was protocol knowledge hardcoded in herdr-select.sh, and it was already wrong
# for one shipped agent: omp answers an Approve/Deny highlight menu with arrow
# keys and Enter, the exact opposite convention. Adding a second agent meant
# adding a second special case to a safety-critical script.
#
# Tokens, and who consumes each:
#   numbered-prompt  herdr-select.sh — a numbered list, answered by pressing
#                    that digit and NEVER Enter (Enter accepts whatever option
#                    happens to be highlighted, which is not necessarily the
#                    one asked for).
#   menu-prompt      herdr-select.sh — a highlight menu with no numbers,
#                    answered by arrow-navigating to the wanted row (confirmed
#                    after every keystroke via its ANSI background-colour
#                    escape) and then Enter.
#   summariser       smart-name.sh — can run as a bare one-shot summariser
#                    (`-p`) stripped of tools/MCP/project context.
#   push-hook        install.sh — has a hook/extension system herdr-control can
#                    wire, so a blocked worker PUSHES an alert instead of
#                    waiting to be noticed by a reconciliation poll.
#
# An agent with NO declared capability is not a bug and not a refusal to run
# it — it spawns and is watched exactly as before. It only means the automated
# answering path declines to guess at its prompt shape, which is the
# fail-closed direction: pressing a key into a TUI whose convention you do not
# know is how you accept the wrong option.
agent_capabilities() {                  # <agent> -> space-separated tokens
  case "$1" in
    # omc is oh-my-claudecode, which launches Claude Code underneath, so it
    # inherits Claude's prompt shape and hook surface exactly.
    claude|omc) printf 'numbered-prompt summariser push-hook\n' ;;
    codex)      printf 'numbered-prompt summariser\n' ;;
    # omp's menu shape and its extension-based push hook are both verified live
    # (2026-07-31 / 2026-08-01); see agent-hooks/omp-herdr-control.ts.
    omp)        printf 'menu-prompt summariser push-hook\n' ;;
    *)          printf '\n' ;;
  esac
}

agent_has_capability() {                # <agent> <token> -> exit 0 if declared
  local tok
  for tok in $(agent_capabilities "$1"); do
    [ "$tok" = "$2" ] && return 0
  done
  return 1
}

# Which answering strategy a pane's agent needs. herdr-select.sh dispatches on
# this rather than sniffing the screen twice and guessing.
#   digit | menu | none
answer_strategy_for_agent() {           # <agent> -> strategy
  if agent_has_capability "$1" numbered-prompt; then printf 'digit\n'
  elif agent_has_capability "$1" menu-prompt;   then printf 'menu\n'
  else printf 'none\n'
  fi
}

# ---- model routing ----------------------------------------------------------
# model_for_agent <agent> <job-class> -> "<model>" or "<model>:<thinking-or-effort>"
#
# job-class tiers: plan|architect|review|design (deep) ·
#                  implement|debug|code (standard) ·
#                  explore|quick|mechanical|docs (fast)
#
# Claude and omp both fuzzy-match plain aliases (opus/sonnet/haiku) to a
# current canonical model, so they share the same tier names. Codex has no
# such alias scheme, so its model names are set in config.sh instead.
model_for_agent() {
  local a="$1" j="$2"
  case "$a:$j" in
    claude:plan|claude:architect|claude:review|claude:design)   printf 'opus\n' ;;
    claude:implement|claude:debug|claude:code)                  printf 'sonnet\n' ;;
    claude:explore|claude:quick|claude:mechanical|claude:docs)   printf 'haiku\n' ;;
    claude:*)                                                   printf 'sonnet\n' ;;
    # omc launches the real claude binary (cli_for_agent below), so it uses
    # claude's model aliases. These rows were MISSING until 2026-09-04:
    # model_for_agent returned empty for omc, and spawn-task.sh then built
    # `claude --model ` — a broken launch that looked routed but wasn't.
    omc:plan|omc:architect|omc:review|omc:design)               printf 'opus\n' ;;
    omc:implement|omc:debug|omc:code)                           printf 'sonnet\n' ;;
    omc:explore|omc:quick|omc:mechanical|omc:docs)              printf 'haiku\n' ;;
    omc:*)                                                      printf 'sonnet\n' ;;
    codex:plan|codex:architect|codex:review|codex:design)        printf '%s\n' "$HERDR_CODEX_DEEP" ;;
    codex:implement|codex:debug|codex:code)                      printf '%s\n' "$HERDR_CODEX_STD" ;;
    codex:explore|codex:quick|codex:mechanical|codex:docs)       printf '%s\n' "$HERDR_CODEX_FAST" ;;
    codex:*)                                                     printf '%s\n' "$HERDR_CODEX_STD" ;;
    # omp's reasoning dial is --thinking (off/minimal/low/medium/high/xhigh/max).
    # Verified 2026-07-31 (`omp --help`, live `omp -p` call): `--model <alias>`
    # fuzzy-matches opus/sonnet/haiku the same as Claude Code.
    omp:plan|omp:architect|omp:review|omp:design)               printf 'opus:high\n' ;;
    omp:implement|omp:debug|omp:code)                           printf 'sonnet:medium\n' ;;
    omp:explore|omp:quick|omp:mechanical|omp:docs)              printf 'haiku:low\n' ;;
    omp:*)                                                      printf 'sonnet:medium\n' ;;
  esac
}

# ---- posture -> each agent's own flag ---------------------------------------
# lib/posture.sh owns the ladder and the compose-only-tightens rule; this owns
# the translation into one CLI's vocabulary, because that is an agent fact.
#
# Flag values are verified against each CLI's own --help, not guessed:
#   claude --permission-mode  acceptEdits | auto | bypassPermissions | manual | dontAsk | plan
#   omp    --approval-mode    always-ask | write | yolo
#
# codex is deliberately UNMAPPED and returns nothing. Its approval surface is
# not a single documented enum the way the other two are, and emitting a
# plausible-looking flag that does not exist would break the spawn outright,
# while emitting one that exists but means something subtly different would be
# worse — it would look like the posture was enforced when it was not. An
# unmapped agent runs at its own default; posture_is_enforced_for below is how
# a caller can find that out and say so, rather than quietly implying a
# guarantee.
posture_flag_for_agent() {              # <agent> <posture> -> flag string, may be empty
  local a="$1" p="$2"
  case "$a:$p" in
    claude:yolo|omc:yolo)     printf -- '--permission-mode bypassPermissions\n' ;;
    claude:write|omc:write)   printf -- '--permission-mode acceptEdits\n' ;;
    claude:strict|omc:strict) printf -- '--permission-mode manual\n' ;;
    omp:yolo)                 printf -- '--approval-mode yolo\n' ;;
    omp:write)                printf -- '--approval-mode write\n' ;;
    omp:strict)               printf -- '--approval-mode always-ask\n' ;;
    *)                        printf '' ;;
  esac
}

# Whether the posture actually reaches the process that gets launched. This
# checks the LAUNCHED binary's vocabulary, not the requested flavor's:
# `codex` has no flag of its own in the table above, but cli_for_agent has
# launched the omp harness for both claude and codex flavors since
# 2026-08-16, and omp's --approval-mode IS emitted for those spawns — so
# reporting "not enforced" for codex was the exact false-negative mirror of
# the false-positive the unmapped table entry guards against.
posture_is_enforced_for() {             # <agent> -> exit 0 if the launched CLI gets a real flag
  local launcher
  case "$1" in
    claude|codex|omp) launcher=omp ;;   # all three launch the omp binary (cli_for_agent)
    omc)              launcher=omc ;;   # its own harness: the real claude binary
    *)                return 1 ;;       # unrecognized agent: literal command, nothing enforced
  esac
  [ -n "$(posture_flag_for_agent "$launcher" "$(resolved_posture)")" ]
}

# ---- omp cross-family model routing ------------------------------------------
# `claude`/`codex` as a spawn-task.sh agent argument mean "use this model
# family at this job-class's tier" — they no longer name a CLI BINARY to
# launch. Both route through the omp harness (below), so every spawned
# worker shares one approval surface, one push-hook wiring
# (agent-hooks/omp-herdr-control.ts), and one answering convention
# (herdr-select.sh already detects numbered-vs-menu live off the rendered
# screen, so it needs no per-agent branch here) — and the operator can
# Ctrl+P swap the live pane between the Claude and Codex model families
# instead of being locked into whichever flavor was requested at spawn
# time. `omc` is deliberately NOT routed here: it IS its own harness
# (Claude Code + OMC's own hook/skill system), not a bare CLI to wrap.
#
# The tier mapping below is a lookup, not new logic: model_for_agent's
# claude/codex tiers are already 1:1 by construction (opus/HERDR_CODEX_DEEP
# = deep, sonnet/HERDR_CODEX_STD = standard, haiku/HERDR_CODEX_FAST = fast),
# and every model id here was verified live against omp's own model cache
# (`openai-codex` provider, `~/.omp/agent/models.db`) 2026-08-16 — a bare
# `omp --model openai-codex/gpt-5.4-mini -p "..."` round-tripped for real.
omp_cross_family_model() {   # <from-agent> <bare-model-name> -> "<omp-model> <thinking-or-empty>"
  local from="$1" name="$2"
  case "$from" in
    claude)
      case "$name" in
        opus)  printf 'openai-codex/%s %s\n' "${HERDR_CODEX_DEEP%%:*}" "${HERDR_CODEX_DEEP##*:}" ;;
        haiku) printf 'openai-codex/%s %s\n' "${HERDR_CODEX_FAST%%:*}" "${HERDR_CODEX_FAST##*:}" ;;
        *)     printf 'openai-codex/%s %s\n' "${HERDR_CODEX_STD%%:*}"  "${HERDR_CODEX_STD##*:}" ;;
      esac ;;
    codex)
      if   [ "$name" = "${HERDR_CODEX_DEEP%%:*}" ]; then printf 'opus high\n'
      elif [ "$name" = "${HERDR_CODEX_FAST%%:*}" ]; then printf 'haiku low\n'
      else printf 'sonnet medium\n'
      fi ;;
  esac
}

# ---- launch command ---------------------------------------------------------
# cli_for_agent <agent> <model-spec> [posture-request] -> launch command, exit 0.
# Exit 1 (no stdout) if <agent> isn't a known agent — caller falls back to
# treating the original argv as a literal command.
#
# The posture argument is a REQUEST, not a setting: it goes through
# resolved_posture, which composes it against HERDR_POSTURE_FLOOR and returns
# whichever is more restrictive. So a caller can tighten one spawn and can
# never loosen below the machine floor, and omitting the argument simply
# spawns at the floor.
#
# Every value-bearing token is %q-quoted at emission (_ap_emit), because the
# output of this function is TYPED into a live shell (herdr pane run) by the
# spawners. Model specs come from config.sh and from --model overrides on the
# spawner's own command line — untrusted shell source either way. A model
# name like `x;$(...)` used to be interpolated bare into that typed line and
# would have executed in the fresh worker pane; now it arrives as one literal
# argv element. Clean values (all the real model names) quote to themselves,
# so the emitted command is byte-identical to before for every normal spawn.
_ap_emit() {                            # <argv...> -> one shell-safe launch line
  local out="" x
  for x in "$@"; do out+="${out:+ }$(printf '%q' "$x")"; done
  printf '%s\n' "$out"
}

cli_for_agent() {
  local a="$1" spec="$2" want="${3:-}" m e posture flag
  local has_effort alt alt_model models
  local -a argv
  posture="$(resolved_posture "$want")"
  case "$a" in
    claude|codex)
      # Always the omp posture vocabulary — omp is the ONLY binary actually
      # launched for either flavor now (see the block comment above).
      flag="$(posture_flag_for_agent omp "$posture")"
      m="${spec%%:*}"
      has_effort=1; [ "$m" = "$spec" ] && has_effort=0
      alt="$(omp_cross_family_model "$a" "$m")"
      alt_model="${alt%% *}"
      [ "$a" = codex ] && m="openai-codex/$m"
      models="${m},${alt_model}"
      argv=(omp --model "$m")
      if [ "$has_effort" = 1 ]; then
        e="${spec##*:}"
        argv+=(--thinking "$e")
      fi
      argv+=(--models "$models")
      ;;
    omc)
      flag="$(posture_flag_for_agent omc "$posture")"
      argv=(claude --model "$spec")
      ;;
    omp)
      # Same colonless-spec hazard as the claude/codex branch above —
      # `--thinking <model-name>` would be an equally invalid omp flag value.
      # Omit rather than guess.
      m="${spec%%:*}"
      # At the `write` floor omp auto-approves read+write and still prompts on
      # exec — the closest equivalent to Claude's acceptEdits. That prompt IS
      # answerable now (herdr-select.sh's menu strategy, capability
      # `menu-prompt`), so `write` no longer means "will sit blocked forever on
      # its first bash call" the way it did when the menu shape had no
      # answering path.
      flag="$(posture_flag_for_agent "$a" "$posture")"
      argv=(omp --model "$m")
      if [ "$m" != "$spec" ]; then
        e="${spec##*:}"
        argv+=(--thinking "$e")
      fi
      ;;
    *)
      return 1 ;;
  esac
  # $flag word-splits on purpose: its values come only from
  # posture_flag_for_agent's own fixed table ("--approval-mode write" is two
  # argv elements), never from caller input.
  # shellcheck disable=SC2206
  [ -n "$flag" ] && argv+=($flag)
  _ap_emit "${argv[@]}"
}

# ---- managed extra flags: what may NOT ride along ---------------------------
# A managed launch's whole point is that posture, rules, and system context
# are decided by the floor-composed spawn path, not by whatever extra argv
# happened to follow the agent name. These flags would override exactly that
# — approval mode, rule/extension loading, or the system-prompt channel the
# canonical-rules append uses — so a spawner REFUSES the spawn when one
# appears, loudly, instead of silently launching something that looks
# floor-governed and isn't. Covers both launched vocabularies (omp and
# claude, since omc launches the real claude binary). Everything else
# (e.g. --resume, --continue) passes through, %q-quoted by the spawner.
# Tighten a spawn with --posture; run a bypassing invocation as an explicitly
# UNMANAGED literal command if you really mean it.
managed_flag_rejected() {               # <arg> -> exit 0 if forbidden on a managed launch
  case "$1" in
    --approval-mode|--approval-mode=*|\
    --permission-mode|--permission-mode=*|\
    --auto-approve|--auto-approve=*|--yolo|\
    --dangerously-skip-permissions|--dangerously-bypass-approvals-and-sandbox|\
    --no-rules|--no-extensions|--no-skills|\
    --system-prompt|--system-prompt=*|\
    --append-system-prompt|--append-system-prompt=*|\
    --settings|--settings=*|--setting-sources|--setting-sources=*|\
    --add-dir|--add-dir=*)
      return 0 ;;
  esac
  return 1
}

# ---- canonical operator ancestor rules --------------------------------------
# Task worktrees live under ~/.herdr/worktrees — physically OUTSIDE the
# project's ancestor tree — so an omp worker's normal upward rule discovery
# finds the worktree's own tracked AGENTS.md but can never reach the
# operator's ancestor rules (this fleet: ~/Code/AGENTS.md sitting above every
# project). These helpers restore that one file, explicitly, via omp's
# --append-system-prompt: the source is DERIVED from the original project
# root's ancestors (never hardcoded), composed into a cache file with a
# provenance header naming where it came from, and appended WITHOUT touching
# normal project rule discovery, copying anything into the worktree, or
# executing anything from the repo.
#
# These are the one exception to this file's "pure" rule (they read the rules
# source and write the composed cache); only the spawners call them.

canonical_rules_source() {   # <project-root> -> source path (empty = none); exit 2 = configured but unusable
  local src="${HERDR_CANONICAL_RULES:-}" dir
  if [ -n "$src" ]; then
    # Explicit operator path — inherited across descendants via the spawn
    # stamp. Configured-but-unreadable FAILS the managed launch (caller
    # aborts on exit 2): silently launching without the operator's rules is
    # the dishonest direction.
    if [ -f "$src" ] && [ -r "$src" ]; then printf '%s\n' "$src"; return 0; fi
    echo "canonical-rules: HERDR_CANONICAL_RULES is set but missing/unreadable: $src" >&2
    return 2
  fi
  dir=$(cd "$1" 2>/dev/null && pwd) || {
    echo "canonical-rules: project root unreadable: $1" >&2
    return 2
  }
  # Walk the ORIGINAL project root's ancestors (never the root itself — its
  # own AGENTS.md loads through normal discovery), stopping at $HOME. The
  # spawners pass repo_root's answer, so a nested spawn from inside a task
  # worktree derives from the real project tree, not the worktree mirror.
  while :; do
    case "$dir" in "$HOME"|/|"") break ;; esac
    dir=$(dirname "$dir")
    if [ -e "$dir/AGENTS.md" ]; then
      if [ -f "$dir/AGENTS.md" ] && [ -r "$dir/AGENTS.md" ]; then
        printf '%s\n' "$dir/AGENTS.md"; return 0
      fi
      echo "canonical-rules: ancestor rules exist but are unreadable: $dir/AGENTS.md" >&2
      return 2
    fi
  done
  return 0                              # nothing configured or found: launch normally
}

canonical_rules_compose() {  # <source> -> composed cache file path; exit 1 on failure
  local src="$1" dir out
  dir="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}/canonical-rules"
  mkdir -p "$dir" || return 1
  out="$dir/$(printf '%s' "$src" | tr '/ ' '__').md"
  {
    printf -- '<!-- herdr-control managed launch: canonical operator ancestor rules.\n'
    printf -- '     Source: %s\n' "$src"
    printf -- '     Appended because task worktrees live outside the project ancestor\n'
    printf -- '     tree, so upward rule discovery cannot reach this file. The\n'
    printf -- "     worktree's own project rules still load through normal discovery. -->\n\n"
    cat "$src"
  } > "$out.tmp.$$" || { rm -f "$out.tmp.$$"; return 1; }
  mv -f "$out.tmp.$$" "$out" || return 1
  printf '%s\n' "$out"
}

# canonical_rules_resolve <agent> <project-root>
# Sets CANONICAL_RULES_SRC (source path, "" when none) and
# CANONICAL_RULES_ARGS ("--append-system-prompt <%q path>", "" when none).
# Exit 2 = a configured/derived source exists but is unusable — the caller
# MUST refuse the managed launch rather than launch without it.
# Only omp-backed launches take the flag; omc (the real claude binary, its
# own harness with its own rule discovery) is left alone.
canonical_rules_resolve() {
  CANONICAL_RULES_SRC="" CANONICAL_RULES_ARGS=""
  case "$1" in claude|codex|omp) ;; *) return 0 ;; esac
  local src composed
  src=$(canonical_rules_source "$2") || return 2
  [ -n "$src" ] || return 0
  composed=$(canonical_rules_compose "$src") || {
    echo "canonical-rules: could not compose cache from $src" >&2
    return 2
  }
  CANONICAL_RULES_SRC="$src"
  CANONICAL_RULES_ARGS="--append-system-prompt $(printf '%q' "$composed")"
}
