#!/usr/bin/env bash
# lib/agent-profiles.sh — the ONLY file that knows about specific agent CLIs.
#
# Every other script asks a question here ("what process names count as an
# agent", "what command launches <agent> at <job-class>'s model") instead of
# hardcoding a CLI's flags inline. Add a new agent by adding a case here —
# not by editing spawn-task.sh / lib/pane-guard.sh / smart-name.sh, which
# used to each carry their own partial copy of this list and drifted.
#
# Sourced by: lib/pane-guard.sh (process allowlist), spawn-task.sh (model
# routing + launch command). Provides two pure functions and one variable —
# nothing here touches herdr or the filesystem.

# Process names herdr may see as a pane's foreground process for a
# recognized coding agent. HERDR_AGENT_PROCS (lib/pane-guard.sh) overrides
# this WHOLESALE when set — this list only supplies the default.
HERDR_AGENT_PROC_NAMES="claude codex omc omp herdr-reviewr aider opencode goose"

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
    claude:plan|claude:architect|claude:review|claude:design)   echo opus ;;
    claude:implement|claude:debug|claude:code)                  echo sonnet ;;
    claude:explore|claude:quick|claude:mechanical|claude:docs)  echo haiku ;;
    claude:*)                                                   echo sonnet ;;
    codex:plan|codex:architect|codex:review|codex:design)       echo "$HERDR_CODEX_DEEP" ;;
    codex:implement|codex:debug|codex:code)                     echo "$HERDR_CODEX_STD" ;;
    codex:explore|codex:quick|codex:mechanical|codex:docs)      echo "$HERDR_CODEX_FAST" ;;
    codex:*)                                                    echo "$HERDR_CODEX_STD" ;;
    # omp's reasoning dial is --thinking (off/minimal/low/medium/high/xhigh/max).
    # Verified 2026-07-31 (`omp --help`, live `omp -p` call): `--model <alias>`
    # fuzzy-matches opus/sonnet/haiku the same as Claude Code.
    omp:plan|omp:architect|omp:review|omp:design)               echo "opus:high" ;;
    omp:implement|omp:debug|omp:code)                           echo "sonnet:medium" ;;
    omp:explore|omp:quick|omp:mechanical|omp:docs)              echo "haiku:low" ;;
    omp:*)                                                      echo "sonnet:medium" ;;
  esac
}

# cli_for_agent <agent> <model-spec> -> launch command on stdout, exit 0.
# Exit 1 (no stdout) if <agent> isn't a known agent — caller falls back to
# treating the original argv as a literal command.
cli_for_agent() {
  local a="$1" spec="$2" m e
  case "$a" in
    claude)
      printf 'claude --model %s --permission-mode acceptEdits' "$spec" ;;
    codex)
      m="${spec%%:*}"; e="${spec##*:}"
      printf 'codex -m %s -c model_reasoning_effort=%s' "$m" "$e" ;;
    omp)
      m="${spec%%:*}"; e="${spec##*:}"
      # --approval-mode write: auto-approve read+write (file edits), still
      # prompt on exec (bash) — the closest omp equivalent to Claude Code's
      # --permission-mode acceptEdits above. Verified 2026-07-31 against a
      # live pane: omp's approval prompt is an Approve/Deny arrow-key+Enter
      # menu, not Claude's numbered list, and herdr-select.sh does not yet
      # know how to ANSWER that shape (see docs/control-plane-design.md) —
      # send-to-agent.sh recognizes and refuses it (lib/pane-guard.sh does
      # not need to; that gate is process-name only), but nothing here can
      # press "Approve" for you yet. A worker that hits a bash approval
      # under --approval-mode write will sit blocked with no automated way
      # to answer it. --approval-mode yolo avoids that blocking at the cost
      # of no exec gate at all — pick per your risk tolerance.
      printf 'omp --model %s --thinking %s --approval-mode write' "$m" "$e" ;;
    *)
      return 1 ;;
  esac
}
