#!/usr/bin/env bash
# lib/posture.sh — the approval posture ladder.
#
# Before this, "how much is this worker allowed to do unattended" was a raw CLI
# flag chosen per spawn: `--permission-mode acceptEdits` here, `--approval-mode
# yolo` there, each spelled in the vocabulary of one agent and each decided in
# isolation. Two problems with that. It is not comparable across agents (is
# codex's default stricter than omp's `write`? nothing could answer), and it has
# no floor — any single call site could hand out the loosest setting, and
# nothing anywhere said "not on this machine".
#
# So postures are RANKED and composition only ever TIGHTENS:
#
#   yolo    (0)  no approval gate at all
#   write   (1)  auto-approve file edits, still prompt before executing        <- default floor
#   strict  (2)  prompt before everything
#
# compose_posture returns the MORE restrictive of the floor and the request, so
# a caller asking for something looser than the machine's floor gets the floor.
# A caller can always tighten for one spawn; it can never loosen. (Borrowed from
# qm's security postures, which compose an org floor with a scope request the
# same way and let a narrower scope only tighten.)
#
# Unknown posture names fail CLOSED to `strict` rather than being ignored: a
# typo in a posture name must not silently widen what an agent may do.
#
# Sourced by lib/agent-profiles.sh (which maps a posture to each agent's own
# flag) and spawn-task.sh. Pure — nothing here touches herdr or the filesystem.
set -uo pipefail

# The floor for this machine. config.sh sets the default; override per run.
: "${HERDR_POSTURE_FLOOR:=write}"

posture_rank() {                        # <posture> -> 0|1|2, empty if unknown
  case "$1" in
    yolo)   printf '0\n' ;;
    write)  printf '1\n' ;;
    strict) printf '2\n' ;;
    *)      printf '' ;;
  esac
}

# compose_posture <floor> <requested> -> the more restrictive of the two.
#
# Either side being unknown collapses to `strict`. That is the fail-closed
# direction: an unrecognized floor (operator typo in config.sh) or an
# unrecognized request must not fall back to "whatever the agent defaults to",
# because for some agents that default is the loosest setting available.
compose_posture() {
  local floor="${1:-}" req="${2:-}" fr rr
  fr="$(posture_rank "$floor")"
  rr="$(posture_rank "$req")"

  # No request at all is normal (most spawns don't ask) — the floor governs.
  if [ -z "$req" ]; then
    [ -n "$fr" ] && { printf '%s\n' "$floor"; return 0; }
    printf 'posture: unknown floor %s — falling back to strict\n' "${floor:-<empty>}" >&2
    printf 'strict\n'; return 0
  fi

  if [ -z "$fr" ] || [ -z "$rr" ]; then
    printf 'posture: unknown posture (floor=%s requested=%s) — falling back to strict\n' \
      "${floor:-<empty>}" "${req:-<empty>}" >&2
    printf 'strict\n'; return 0
  fi

  if [ "$rr" -ge "$fr" ]; then printf '%s\n' "$req"; else printf '%s\n' "$floor"; fi
}

# The posture actually in force for a spawn: the machine floor composed with an
# optional per-spawn request.
resolved_posture() {                    # [requested] -> posture
  compose_posture "${HERDR_POSTURE_FLOOR:-write}" "${1:-}"
}
