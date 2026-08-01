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
# Sourced by: lib/pane-guard.sh (process allowlist), spawn-task.sh (model
# routing + launch command), herdr-select.sh (which answering strategy a
# prompt needs). Pure — nothing here touches herdr or the filesystem.
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

posture_is_enforced_for() {             # <agent> -> exit 0 if a flag exists for it
  [ -n "$(posture_flag_for_agent "$1" "$(resolved_posture)")" ]
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
cli_for_agent() {
  local a="$1" spec="$2" want="${3:-}" m e posture flag
  posture="$(resolved_posture "$want")"
  flag="$(posture_flag_for_agent "$a" "$posture")"
  case "$a" in
    claude|omc)
      printf 'claude --model %s%s\n' "$spec" "${flag:+ $flag}" ;;
    codex)
      m="${spec%%:*}"; e="${spec##*:}"
      printf 'codex -m %s -c model_reasoning_effort=%s%s\n' "$m" "$e" "${flag:+ $flag}" ;;
    omp)
      m="${spec%%:*}"; e="${spec##*:}"
      # At the `write` floor omp auto-approves read+write and still prompts on
      # exec — the closest equivalent to Claude's acceptEdits. That prompt IS
      # answerable now (herdr-select.sh's menu strategy, capability
      # `menu-prompt`), so `write` no longer means "will sit blocked forever on
      # its first bash call" the way it did when the menu shape had no
      # answering path.
      printf 'omp --model %s --thinking %s%s\n' "$m" "$e" "${flag:+ $flag}" ;;
    *)
      return 1 ;;
  esac
}
