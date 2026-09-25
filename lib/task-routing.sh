#!/usr/bin/env bash
# task-routing.sh — the single, conservative role-to-job routing contract.
#
# This module only classifies work. It never authorizes commands, secrets,
# pushes, merges, governance, or external communications.
set -uo pipefail

TASK_ROUTING_ROLES="orchestrator planner implementer trivial escalate"

_task_routing_json() {
  jq -cn --arg provider "$1" --arg role "$2" --arg job_class "$3" \
    --arg confidence "$4" --arg reason "$5" \
    '{provider:$provider, role:$role, job_class:(if $job_class == "" then null else $job_class end), confidence:($confidence|tonumber), reason:$reason}'
}

# route_task_deterministic <brief> -> JSON on stdout.
# High-risk work is deliberately checked before convenience classifications.
route_task_deterministic() {
  local brief="${1:-}" lower
  lower=$(printf '%s' "$brief" | tr '[:upper:]' '[:lower:]')

  if [ -z "${brief//[[:space:]]/}" ]; then
    _task_routing_json deterministic escalate "" 1.0 "empty brief requires human triage"
    return 1
  fi

  if printf '%s\n' "$lower" | grep -Eq \
    '(^|[^[:alnum:]])(auth|authentication|credential(s)?|secret(s)?|token(s)?|password(s)?|oauth|permission(s)?|security|vulnerabilit(y|ies)|exploit|encryption)([^[:alnum:]]|$)|(^|[^[:alnum:]])(money|payment(s)?|billing|invoice(s)?|refund(s)?|charge(s)?|payout(s)?|financial)([^[:alnum:]]|$)|(^|[^[:alnum:]])(external[ -]?(comm|comms|communication|communications|email)|send[ -]?(email|slack|sms|message)|email|publish|post[ -]?public)([^[:alnum:]]|$)|(^|[^[:alnum:]])(production|prod|deploy|release|delete|destroy|destructive|drop|truncate|erase|wipe|migration)([^[:alnum:]]|$)'; then
    _task_routing_json deterministic escalate "" 1.0 "high-risk work requires human triage"
    return 1
  fi

  if printf '%s\n' "$lower" | grep -Eq '(^|[^[:alnum:]])(orchestrate|coordinate|supervise|dispatch|fan[ -]?out)([^[:alnum:]]|$)'; then
    _task_routing_json deterministic orchestrator plan 0.88 "coordination language maps to the planning tier"
    return 0
  fi
  if printf '%s\n' "$lower" | grep -Eq '(^|[^[:alnum:]])(plan|planner|design|architect|architecture|break[ -]?down|research[ -]?plan)([^[:alnum:]]|$)'; then
    _task_routing_json deterministic planner plan 0.9 "planning language maps to the planning tier"
    return 0
  fi
  if printf '%s\n' "$lower" | grep -Eq '(^|[^[:alnum:]])(trivial|mechanical|format|formatting|rename|typo|whitespace)([^[:alnum:]]|$)'; then
    _task_routing_json deterministic trivial mechanical 0.84 "bounded mechanical work maps to the fast tier"
    return 0
  fi

  _task_routing_json deterministic implementer implement 0.78 "default code work maps to the implementation tier"
}

route_role_job_class() {
  case "$1" in
    orchestrator|planner) printf 'plan\n' ;;
    implementer) printf 'implement\n' ;;
    trivial) printf 'mechanical\n' ;;
    escalate) return 1 ;;
    *) return 1 ;;
  esac
}
