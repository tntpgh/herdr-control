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
# Launch strings are typed into a shell; compare what the shell would SEE
# (eval'd argv), so %q escapes that the shell strips (`\,`) do not read as
# a difference. A payload that fails to parse compares unequal.
argv_of(){ ( eval "set -- $1" 2>/dev/null && printf '%s\n' "$@" ) ; }
check(){ if [ "$(argv_of "$2")" = "$(argv_of "$3")" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

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
# posture_is_enforced_for reports on the LAUNCHED binary, not the flavor's
# own flag table: claude/codex/omp all launch the omp binary (cli_for_agent),
# which DOES get --approval-mode, so all report enforced. The old "codex not
# enforced" pin described the pre-2026-08-16 world where codex meant the
# codex binary; it was a false negative ever since.
posture_is_enforced_for codex && ok "codex (omp-launched) reports posture enforced" || bad "codex launches omp with --approval-mode — must report enforced"
posture_is_enforced_for claude && ok "claude (omp-launched) reports posture enforced" || bad "claude should report enforced"
posture_is_enforced_for omp   && ok "omp reports posture enforced"            || bad "omp should report enforced"
posture_is_enforced_for omc   && ok "omc (claude-launched) reports posture enforced" || bad "omc should report enforced"
posture_is_enforced_for mytool && bad "unknown agent (literal command) must report NOT enforced" || ok "unknown agent reports posture not enforced"

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
check "omc with a standalone effort passes it as claude's own --effort, not inside --model" \
  "$(HERDR_POSTURE_FLOOR=write cli_for_agent omc sonnet:high)" \
  "claude --model sonnet --effort high --permission-mode acceptEdits"
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
  for a in claude codex omp omc; do
    [ -n "$(model_for_agent "$a" "$j")" ] || bad "model_for_agent $a $j returned empty"
  done
done
ok "every agent x job-class yields a model"
check "claude plan -> opus"         "$(model_for_agent claude plan)"      "opus"
check "claude implement -> sonnet"  "$(model_for_agent claude implement)" "sonnet"
check "claude docs -> haiku"        "$(model_for_agent claude docs)"      "haiku"
check "omp plan -> opus:high"       "$(model_for_agent omp plan)"         "opus:high"
check "omp unknown job -> default"  "$(model_for_agent omp weird)"        "sonnet:medium"
check "omc plan -> opus (rows were missing; launch built 'claude --model ')" \
                                    "$(model_for_agent omc plan)"         "opus"
check "omc implement -> sonnet"     "$(model_for_agent omc implement)"    "sonnet"
check "omc docs -> haiku"           "$(model_for_agent omc docs)"         "haiku"

# ============================================================================
# Managed-launch regressions (2026-09-04): argv boundaries, bypass-flag
# refusal, canonical operator ancestor rules, stricter child floor.
# ============================================================================
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Physical path: on macOS mktemp answers under the /var/folders SYMLINK while
# git's --path-format=absolute resolves it, and the ancestor-derivation
# checks below compare paths byte-for-byte.
WORK=$(cd "$WORK" && pwd -P)

printf '== argv boundaries: metacharacters in a model spec stay ONE literal argument ==\n'
# cli_for_agent output is TYPED into a live shell; a model name from config
# or --model is untrusted shell source. Round-trip the emitted line through
# eval against a capturing stub: the payload must arrive as one argv element
# and its embedded command must NOT execute.
payload="sonnet;touch $WORK/pwned"
cli=$(HERDR_POSTURE_FLOOR=write cli_for_agent omp "$payload")
omp() { printf '%s\n' "$@" > "$WORK/argv.txt"; }
eval "$cli"
unset -f omp
[ ! -e "$WORK/pwned" ] && ok "embedded command did not execute" || bad "quoting broke: payload executed in the launch shell"
check "payload arrived as one literal --model value" "$(sed -n '2p' "$WORK/argv.txt")" "$payload"
check "posture flag still follows the quoted model" "$(sed -n '3p' "$WORK/argv.txt")" "--approval-mode"

printf '== managed extra flags: posture/rules/system-context overrides are refused ==\n'
for f in --approval-mode --permission-mode --auto-approve --yolo \
         --dangerously-skip-permissions --allow-dangerously-skip-permissions \
         --allowedTools --allowed-tools=Bash --bare --safe-mode \
         --no-rules --no-extensions --no-skills \
         --system-prompt --append-system-prompt --append-system-prompt=/x \
         --system-prompt-file --append-system-prompt-file=/x \
         --settings --setting-sources --add-dir \
         --config --config=/x --profile --cwd --cwd=/x \
         --hook -e --extension --plugin-dir --mcp-config --strict-mcp-config --agents; do
  managed_flag_rejected "$f" && ok "rejects $f" || bad "must reject $f"
done
for f in --resume --continue -p; do
  managed_flag_rejected "$f" && bad "must allow useful flag $f" || ok "allows $f"
done

printf '== canonical rules: derived from the ORIGINAL project ancestor, with provenance ==\n'
fleet="$WORK/fleet"; mkdir -p "$fleet/proj"
printf 'CANON-MARKER operator ancestor rules\n' > "$fleet/AGENTS.md"
HERDR_CANONICAL_RULES=""
HERDR_STATE_DIR="$WORK/state"
if canonical_rules_resolve omp "$fleet/proj"; then
  check "source derived from the project ancestor" "$CANONICAL_RULES_SRC" "$fleet/AGENTS.md"
  case "$CANONICAL_RULES_ARGS" in
    "--append-system-prompt "*) ok "emits --append-system-prompt" ;;
    *) bad "args wrong: $CANONICAL_RULES_ARGS" ;;
  esac
  composed="${CANONICAL_RULES_ARGS#--append-system-prompt }"
  # %q of a plain path quotes to itself; eval-strip is unnecessary here.
  if [ -f "$composed" ] && grep -q 'CANON-MARKER' "$composed" && grep -q "source: $fleet/AGENTS.md" "$composed"; then
    ok "composed cache carries the content AND a provenance header naming the source"
  else
    bad "composed cache missing content or provenance: $composed"
  fi
else
  bad "resolve failed for a readable derived ancestor source"
fi
printf '== every ancestor AGENTS.md is restored, outermost first (matches omp discovery) ==\n'
mkdir -p "$fleet/org/proj2"
printf 'ORG-MARKER org rules\n' > "$fleet/org/AGENTS.md"
if canonical_rules_resolve omp "$fleet/org/proj2"; then
  check "both ancestors collected, farthest first" "$CANONICAL_RULES_SRC" "$fleet/AGENTS.md:$fleet/org/AGENTS.md"
  composed="${CANONICAL_RULES_ARGS#--append-system-prompt }"
  grep -q 'CANON-MARKER' "$composed" && grep -q 'ORG-MARKER' "$composed" \
    && ok "composed cache carries both files" || bad "an ancestor was dropped: $composed"
else
  bad "resolve failed with two readable ancestors"
fi
canonical_rules_resolve omp "$fleet/org/proj2" "$fleet/org/proj2" && [ -z "$CANONICAL_RULES_ARGS" ] \
  && ok "in-tree launch cwd: nothing appended (normal discovery already loads them)" \
  || bad "in-tree launch double-loads ancestor rules: $CANONICAL_RULES_SRC"
canonical_rules_resolve omp "$fleet/org/proj2" "$WORK/elsewhere" \
  && [ "$CANONICAL_RULES_SRC" = "$fleet/AGENTS.md:$fleet/org/AGENTS.md" ] \
  && ok "out-of-tree launch cwd (a worktree): all ancestors appended" \
  || bad "out-of-tree cwd lost ancestors: $CANONICAL_RULES_SRC"
chmod 000 "$fleet/org/AGENTS.md"
if canonical_rules_resolve omp "$fleet/org/proj2" 2>/dev/null; then
  bad "an unreadable ancestor must fail resolution, not be skipped"
else
  ok "unreadable ancestor fails resolution (rc!=0)"
fi
chmod 644 "$fleet/org/AGENTS.md"

canonical_rules_resolve mytool "$fleet/proj" && [ -z "$CANONICAL_RULES_ARGS" ] \
  && ok "unrecognized agent: no rules flag (literal commands are unmanaged)" \
  || bad "unrecognized agent should resolve empty, rc 0"
canonical_rules_resolve omc "$fleet/proj" && [ -z "$CANONICAL_RULES_ARGS" ] \
  && ok "omc: left to its own harness's rule discovery (no flag)" \
  || bad "omc should resolve empty, rc 0"
HERDR_CANONICAL_RULES="$WORK/does-not-exist.md"
if canonical_rules_resolve omp "$fleet/proj" 2>/dev/null; then
  bad "configured-but-missing source must FAIL (no silent launch without operator rules)"
else
  ok "configured-but-missing source fails resolution (rc!=0)"
fi
HERDR_CANONICAL_RULES=""

printf '== spawn-task.sh end-to-end (dry-run against a stubbed herdr) ==\n'
herdr() { return 1; }
export -f herdr
git -C "$fleet/proj" init -q
spawn_env=(HERDR_CANONICAL_RULES= "HERDR_STATE_DIR=$WORK/state" "HERDR_WT_DIR=$WORK/wt" \
           "HERDR_RUN_STATE_DIR=$WORK/registry" HERDR_POSTURE_FLOOR=write HERDR_PANE_ID=)
out=$(env "${spawn_env[@]}" bash "$here/spawn-task.sh" --dry-run --posture strict "$fleet/proj" t1 implement omp 2>&1)
printf '%s\n' "$out" | grep -q 'posture   : strict' && ok "stricter request honoured and stamped as the child floor" || bad "posture line wrong: $out"
printf '%s\n' "$out" | grep -q -- '--approval-mode always-ask' && ok "launch carries the strict flag" || bad "strict flag missing from launch"
printf '%s\n' "$out" | grep -q -- '--append-system-prompt' && ok "canonical rules appended to the managed launch" || bad "rules flag missing from launch"
printf '%s\n' "$out" | grep -q "rules     : $fleet/AGENTS.md" && ok "rules line names the derived ancestor source" || bad "rules provenance line missing"
printf '%s\n' "$out" | grep -q -- '--no-rules' && bad "project context must never be disabled" || ok "no rule/extension-disabling flags in the launch"
out=$(env "${spawn_env[@]}" bash "$here/spawn-task.sh" --dry-run --posture yolo "$fleet/proj" t1 implement omp 2>&1)
printf '%s\n' "$out" | grep -q 'posture   : write' && ok "a yolo request cannot loosen the write floor" || bad "floor loosened: $out"
out=$(env "${spawn_env[@]}" bash "$here/spawn-task.sh" --dry-run --effort high "$fleet/proj" t1 implement omp 2>&1)
printf '%s\n' "$out" | grep -q -- '--thinking high' && ok "standalone --effort applies to the job-class model" || bad "standalone --effort dropped: $out"
out=$(env "${spawn_env[@]}" bash "$here/spawn-task.sh" --dry-run "$fleet/proj" t1 implement omc 2>&1)
printf '%s\n' "$out" | grep -q -- 'claude --model sonnet' && ok "omc launch gets a real model (map rows restored)" || bad "omc launch broken: $out"
if out=$(env "${spawn_env[@]}" bash "$here/spawn-task.sh" --dry-run "$fleet/proj" t2 implement claude --no-rules 2>&1); then
  bad "bypass flag on a managed launch must refuse the spawn"
else
  printf '%s\n' "$out" | grep -q 'refusing managed extra flag' && ok "bypass flag refused loudly" || bad "refusal not explained: $out"
fi
out=$(env "${spawn_env[@]}" bash "$here/spawn-task.sh" --dry-run "$fleet/proj" t3 quick ./my-tool --flag 2>&1)
printf '%s\n' "$out" | grep -q 'UNMANAGED' && ok "literal command visibly reported as UNMANAGED" || bad "unmanaged launch not reported: $out"
if out=$(env "${spawn_env[@]}" "HERDR_CANONICAL_RULES=$WORK/does-not-exist.md" \
      bash "$here/spawn-task.sh" --dry-run "$fleet/proj" t4 implement omp 2>&1); then
  bad "configured-but-missing rules source must fail the managed spawn"
else
  printf '%s\n' "$out" | grep -q 'refusing managed launch' && ok "unusable rules source refuses the managed spawn" || bad "refusal not explained: $out"
fi
unset -f herdr


printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
