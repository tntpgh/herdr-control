#!/usr/bin/env bash
# verify-posture.sh — prove the posture ladder only ever tightens, that the
# per-agent capability table drives the answering strategy, and that
# cli_for_agent emits only flags the real CLIs actually accept.
#
#   bash verify-posture.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/config.sh"
. "$here/lib/agent-profiles.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

printf '== rank ordering ==\n'
check "yolo   rank" "$(posture_rank yolo)"   "0"
check "write  rank" "$(posture_rank write)"  "1"
check "strict rank" "$(posture_rank strict)" "2"
check "unknown rank is empty" "$(posture_rank banana)" ""

printf '== compose only ever TIGHTENS ==\n'
check "floor write + request yolo   -> write (request refused)"  "$(compose_posture write yolo)"   "write"
check "floor write + request strict -> strict (tightening ok)"   "$(compose_posture write strict)" "strict"
check "floor write + no request     -> write"                    "$(compose_posture write '')"     "write"
check "floor strict + request yolo  -> strict"                   "$(compose_posture strict yolo)"  "strict"
check "floor strict + request write -> strict"                   "$(compose_posture strict write)" "strict"
check "floor yolo   + request write -> write"                    "$(compose_posture yolo write)"   "write"
check "floor yolo   + no request    -> yolo"                     "$(compose_posture yolo '')"      "yolo"

printf '== unknown posture fails CLOSED to strict ==\n'
check "unknown request  -> strict" "$(compose_posture write banana 2>/dev/null)" "strict"
check "unknown floor    -> strict" "$(compose_posture banana write 2>/dev/null)" "strict"
check "unknown floor, no request -> strict" "$(compose_posture banana '' 2>/dev/null)" "strict"
if compose_posture write banana 2>&1 >/dev/null | grep -q 'unknown posture'; then
  ok "unknown posture warns on stderr (not silent)"
else
  bad "unknown posture was silent"
fi

printf '== resolved_posture honours the machine floor ==\n'
check "default floor is write" "$(HERDR_POSTURE_FLOOR=write resolved_posture)" "write"
check "floor strict cannot be loosened by a request" \
  "$(HERDR_POSTURE_FLOOR=strict resolved_posture yolo)" "strict"

printf '== capabilities ==\n'
check "claude answers numbered prompts" "$(answer_strategy_for_agent claude)" "digit"
check "codex  answers numbered prompts" "$(answer_strategy_for_agent codex)"  "digit"
check "omp    answers a menu"           "$(answer_strategy_for_agent omp)"    "menu"
check "omc inherits claude's shape"     "$(answer_strategy_for_agent omc)"    "digit"
check "unknown agent -> no strategy"    "$(answer_strategy_for_agent aider)"  "none"
agent_has_capability omp menu-prompt      && ok "omp declares menu-prompt"   || bad "omp missing menu-prompt"
agent_has_capability omp push-hook        && ok "omp declares push-hook"     || bad "omp missing push-hook"
agent_has_capability claude push-hook     && ok "claude declares push-hook"  || bad "claude missing push-hook"
agent_has_capability codex push-hook      && bad "codex must NOT claim push-hook" || ok "codex does not claim push-hook"
agent_has_capability omp numbered-prompt  && bad "omp must NOT claim numbered-prompt" || ok "omp does not claim numbered-prompt"

printf '== posture -> real, verified CLI flags ==\n'
# Values checked against each CLI's own --help:
#   claude --permission-mode  acceptEdits|auto|bypassPermissions|manual|dontAsk|plan
#   omp    --approval-mode    always-ask|write|yolo
check "claude write"  "$(posture_flag_for_agent claude write)"  "--permission-mode acceptEdits"
check "claude strict" "$(posture_flag_for_agent claude strict)" "--permission-mode manual"
check "claude yolo"   "$(posture_flag_for_agent claude yolo)"   "--permission-mode bypassPermissions"
check "omp write"     "$(posture_flag_for_agent omp write)"     "--approval-mode write"
check "omp strict"    "$(posture_flag_for_agent omp strict)"    "--approval-mode always-ask"
check "omp yolo"      "$(posture_flag_for_agent omp yolo)"      "--approval-mode yolo"
check "codex unmapped (must not invent a flag)" "$(posture_flag_for_agent codex write)" ""
posture_is_enforced_for codex && bad "codex must report posture NOT enforced" || ok "codex reports posture not enforced"
posture_is_enforced_for omp   && ok "omp reports posture enforced"            || bad "omp should report enforced"

printf '== omp cross-family model lookup (Ctrl+P swap target) ==\n'
check "claude opus -> codex deep tier"     "$(omp_cross_family_model claude opus)"   "openai-codex/gpt-5.6-sol high"
check "claude sonnet -> codex std tier"    "$(omp_cross_family_model claude sonnet)" "openai-codex/gpt-5.5 medium"
check "claude haiku -> codex fast tier"    "$(omp_cross_family_model claude haiku)"  "openai-codex/gpt-5.4-mini low"
check "codex deep tier -> claude opus"     "$(omp_cross_family_model codex gpt-5.6-sol)"   "opus high"
check "codex std tier -> claude sonnet"    "$(omp_cross_family_model codex gpt-5.5)"       "sonnet medium"
check "codex fast tier -> claude haiku"    "$(omp_cross_family_model codex gpt-5.4-mini)"  "haiku low"

printf '== cli_for_agent composes the floor, and cannot be loosened ==\n'
printf -- '-- claude/codex both launch under omp now (one approval surface, one\n'
printf -- '   push-hook, Ctrl+P swaps --models between the two families) --\n'
check "claude at the write floor launches omp, not the claude binary" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent claude sonnet)" \
  "omp --model sonnet --models sonnet,openai-codex/gpt-5.5 --approval-mode write"
check "codex at the write floor launches omp, not the codex binary" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent codex gpt-5.5:medium)" \
  "omp --model openai-codex/gpt-5.5 --thinking medium --models openai-codex/gpt-5.5,sonnet --approval-mode write"
check "omp at the write floor" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent omp sonnet:medium)" \
  "omp --model sonnet --thinking medium --approval-mode write"
check "a yolo REQUEST is refused at a write floor" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent omp sonnet:medium yolo)" \
  "omp --model sonnet --thinking medium --approval-mode write"
check "a strict request IS honoured (tightening)" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent omp sonnet:medium strict)" \
  "omp --model sonnet --thinking medium --approval-mode always-ask"
check "a strict FLOOR overrides everything, even routed through omp" \
  "$(HERDR_POSTURE_FLOOR=strict cli_for_agent claude sonnet yolo)" \
  "omp --model sonnet --models sonnet,openai-codex/gpt-5.5 --approval-mode always-ask"
check "omc still launches the real claude binary (it IS its own harness)" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent omc sonnet)" \
  "claude --model sonnet --permission-mode acceptEdits"
printf '== 2026-08-08 bug: a spec with NO ":effort" must OMIT the flag, never pass the model name as the effort value ==\n'
# Reported live: spawn-task.sh --model X with no --effort produced
# `codex -m X -c model_reasoning_effort=X` — codex hard-errors on every call
# (invalid_enum_value), silently, with no crash and no obvious signal. Same
# hazard now applies to omp's --thinking, guarded the same way.
check "codex with no effort in the spec omits --thinking entirely" \
  "$(cli_for_agent codex gpt-5.6-sol)" \
  "omp --model openai-codex/gpt-5.6-sol --models openai-codex/gpt-5.6-sol,opus --approval-mode write"
check "omp with no effort in the spec omits --thinking entirely" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent omp sonnet)" \
  "omp --model sonnet --approval-mode write"
check "codex with an effort still works (no regression)" \
  "$(cli_for_agent codex gpt-5.6-sol:high)" \
  "omp --model openai-codex/gpt-5.6-sol --thinking high --models openai-codex/gpt-5.6-sol,opus --approval-mode write"
if cli_for_agent definitely-not-an-agent x >/dev/null 2>&1; then
  bad "unknown agent should exit 1"
else
  ok "unknown agent exits 1 (caller falls back to a literal command)"
fi

printf '== model routing unchanged for every job class ==\n'
for j in plan architect review design implement debug code explore quick mechanical docs weird; do
  for a in claude codex omp; do
    [ -n "$(model_for_agent "$a" "$j")" ] || bad "model_for_agent $a $j returned empty"
  done
done
ok "every agent x job-class yields a model"
check "claude plan -> opus"         "$(model_for_agent claude plan)"      "opus"
check "claude implement -> sonnet"  "$(model_for_agent claude implement)" "sonnet"
check "claude docs -> haiku"        "$(model_for_agent claude docs)"      "haiku"
check "omp plan -> opus:high"       "$(model_for_agent omp plan)"         "opus:high"
check "omp unknown job -> default"  "$(model_for_agent omp weird)"        "sonnet:medium"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
