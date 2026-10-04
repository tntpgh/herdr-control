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
# job-class tiers: plan|architect|design|deep-review (deep) ·
#                  review|implement|debug|code|docs (standard — review runs
#                  the standard model at HIGH effort: omp sonnet:high, same
#                  sonnet alias as implement for claude/omc, $HERDR_CODEX_STD
#                  for codex) ·
#                  explore|quick|mechanical (fast)
# Terrence's decision 2026-10-04 (form 20261004T181727-8798,
# models=risk_based_default): Opus/`deep-review` only for work touching
# auth, secrets, money, deploys/CI/build, data deletion or migrations, or
# concurrency/races, and for plan/architect/design. Routine review uses
# `review` (standard model, high effort) — a flat Opus-for-every-review
# default burned budget on work that didn't need it.
# `docs` moved fast -> standard 2026-09-05: restructuring a governance doc
# (which rules have incidents behind them) came up Haiku and had to be
# killed and respawned. Docs work is judgment work; only explore/quick/
# mechanical are genuinely fast-tier.
#
# Claude and omp both fuzzy-match plain aliases (opus/sonnet/haiku) to a
# current canonical model, so they share the same tier names. Codex has no
# such alias scheme, so its model names are set in config.sh instead.
# Credential posture BY JOB CLASS — the safe choice made once, not remembered
# at every spawn (security review 2026-09-19, SPAWN-OPENV-006).
#
# The risk that justifies withholding attaches to the KIND of work, not to the
# individual call: `review` reads diffs and third-party code, `explore` reads
# whatever is out there. Both process material we did not write, which is the
# one case where a prompt-injected instruction could reach a process holding a
# vault credential. `implement`/`debug`/`plan` work on our own tree against our
# own databases and genuinely need secrets — that is why the default is ON at
# all (an opt-in flag was measured to be the wrong default: nearly every task
# here reads a secret, so a forgotten flag parks an overnight run).
#
# Precedence in the spawners, strictest wins:
#   HERDR_SECRETS_WITHHELD=1 (inherited)  >  --no-secrets  >  this table
#   >  unmanaged-literal-command default  >  --secrets  >  managed default ON
# So --secrets can lift a job-class default (a reviewer that must query the DB)
# but never an inherited withholding.
# Matching is SUBSTRING and fail-closed (SPAWN-OPENV-010). Exact tokens looked
# tidy and covered almost nothing a human types: `pr-review`, `code-review`,
# `review-111`, `audit`, `triage`, `scrape`, `research` all fell through to
# GRANT and printed "[managed default]", which reads like a decision rather
# than a miss. An unrecognised class is withheld: a job nobody classified is
# exactly the one nobody thought about.
KNOWN_JOB_CLASSES="plan architect review deep-review design implement debug code docs explore research quick mechanical"
secrets_default_for_job() {  # <job-class> -> "withhold" | ""
	case "$1" in
		*review*|*explore*|*audit*|*scrape*|*research*|*triage*) printf 'withhold\n'; return ;;
	esac
	case " $KNOWN_JOB_CLASSES " in
		*" $1 "*) printf '\n' ;;
		*)        printf 'withhold\n' ;;   # unrecognised: fail closed
	esac
}

model_for_agent() {
  local a="$1" j="$2"
  case "$a:$j" in
    claude:deep-review)                                          printf 'opus\n' ;;
    claude:plan|claude:architect|claude:design)                  printf 'opus\n' ;;
    claude:review|claude:implement|claude:debug|claude:code|claude:docs) printf 'sonnet\n' ;;
    claude:explore|claude:quick|claude:mechanical)               printf 'haiku\n' ;;
    claude:*)                                                   printf 'sonnet\n' ;;
    # omc launches the real claude binary (cli_for_agent below), so it uses
    # claude's model aliases. These rows were MISSING until 2026-09-04:
    # model_for_agent returned empty for omc, and spawn-task.sh then built
    # `claude --model ` — a broken launch that looked routed but wasn't.
    omc:deep-review)                                             printf 'opus\n' ;;
    omc:plan|omc:architect|omc:design)                           printf 'opus\n' ;;
    omc:review|omc:implement|omc:debug|omc:code|omc:docs)        printf 'sonnet\n' ;;
    omc:explore|omc:quick|omc:mechanical)                        printf 'haiku\n' ;;
    omc:*)                                                       printf 'sonnet\n' ;;
    codex:deep-review)                                            printf '%s\n' "$HERDR_CODEX_DEEP" ;;
    codex:plan|codex:architect|codex:design)                      printf '%s\n' "$HERDR_CODEX_DEEP" ;;
    codex:review|codex:implement|codex:debug|codex:code|codex:docs) printf '%s\n' "$HERDR_CODEX_STD" ;;
    codex:explore|codex:quick|codex:mechanical)                   printf '%s\n' "$HERDR_CODEX_FAST" ;;
    codex:*)                                                      printf '%s\n' "$HERDR_CODEX_STD" ;;
    # omp's reasoning dial is --thinking (off/minimal/low/medium/high/xhigh/max).
    # Verified 2026-07-31 (`omp --help`, live `omp -p` call): `--model <alias>`
    # fuzzy-matches opus/sonnet/haiku the same as Claude Code.
    omp:deep-review)                                              printf 'opus:high\n' ;;
    omp:plan|omp:architect|omp:design)                            printf 'opus:high\n' ;;
    omp:review)                                                   printf 'sonnet:high\n' ;;
    omp:implement|omp:debug|omp:code|omp:docs)                  printf 'sonnet:medium\n' ;;
    omp:explore|omp:quick|omp:mechanical)                       printf 'haiku:low\n' ;;
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

# ---- tool set by job class ---------------------------------------------------
# omp's default (--tools omitted) loads EVERY built-in tool's schema into the
# first request. Measured live (2026-09-27/28, /tmp scratch, `omp -p --mode
# json --no-session --thinking off "hi"`, summing usage.input+cacheRead+
# cacheWrite so prompt-cache hits still count): all built-ins ~22.6k tokens;
# read,bash,edit,write,grep,glob,todo,eval,wait only (no task/yield) ~19.7k;
# read,bash,grep,glob,todo,web_search only ~17.6k. `manage_skill`, `learn`,
# `write`, and every xd:// device tool (fleet_status, project_status, …) are
# EXTENSION tools, not filtered by --tools at all — confirmed live with
# `--no-tools`, which still left them callable. So `--tools` only ever trims
# omp's OWN built-ins; an extension tool a job needs is never at risk of
# being named wrong or dropped.
#
# `hub` (248 calls in worker sessions, 2026-09-14..27) is omp's own
# agent-messaging tool (ops list/inbox/wait), not a herdr-control one. It is
# NOT in `omp --tools`'s valid list (`--tools=hub` -> "Unknown tool"), and a
# live probe on 2026-09-28 found it absent from freshly spawned workers both
# WITH a class tool set and with `--tools all` — so this table neither grants
# nor removes it. Never add `hub` to a list below: naming a tool omp has not
# registered makes the launch fail.
#
# Every class that changes files (routers send rename/typo/format briefs to
# `mechanical`; docs is "judgment work", above) keeps `edit`. Only `explore`
# is trimmed to the read set. `ask` stays in both: it is herdr's structured
# question channel (omp-herdr-control.ts alerts on it, herdr-select answers
# it) — without it a worker that needs a decision prints text and goes idle
# with no prompt_id. It costs ~0.7k tokens (interactive haiku probe, 13,358
# -> 14,086). `ask` is valid in `--tools` only interactively; `omp -p`
# rejects it, and workers are never launched with -p.
#
#   implement|debug|code|docs|mechanical|quick
#                                  -> read,bash,edit,write,grep,glob,todo,eval,wait,ask
#   explore                        -> read,bash,grep,glob,todo,web_search,ask
#   plan|architect|review|design|deep-review,
#   and any unrecognised class     -> "" (all tools — unrestricted)
#
# plan/architect/review/design/deep-review stay unrestricted rather than losing write/
# edit: nothing in this codebase enforces that a `review` job never writes
# (it still has to leave notes in PROOF.md, and a reviewer occasionally
# proposes a diff), so a blanket "reviewers never edit" tool cut would be a
# guess dressed up as a measurement. An unrecognised class fails the SAME
# direction as secrets_default_for_job's fail-closed default LOOKS like it
# should, but isn't: unlike a credential grant, a missing/wrong tool merely
# breaks the job (a `read`-only worker asked to fix a bug just fails loudly
# on its first `edit` call) rather than exposing anything, so the safe
# default here is the FULL set, not the empty one.
tools_for_job() {  # <job-class> -> comma-separated --tools value, or "" for unrestricted
  case "$1" in
    implement|debug|code|docs|mechanical|quick) printf 'read,bash,edit,write,grep,glob,todo,eval,wait,ask\n' ;;
    # research/explore keep no `edit` (no diff-style patching of tracked
    # files) but DO get `write` back (N8, round-2 security review): their
    # one legitimate deliverable is .handoffs/ANSWER.md, and with no write
    # tool at all the only way to produce it was a bash heredoc, which an
    # unattended remote spawn has nobody watching to approve. Safe because
    # spawn-task.sh tags a research/explore task's manifest with
    # `handoffs_write: ANSWER.md`, and _cp_write_menu_verdict
    # (lib/command-policy.sh) narrows ANY task carrying that key to
    # exactly that one .handoffs file -- never a broad in-worktree write
    # the way implement/debug/etc above get. `git: none` (the allowlist's
    # default ceiling for these job classes) still stops a pushed branch.
    explore|research)                           printf 'read,bash,write,grep,glob,todo,web_search,ask\n' ;;
    *)                             printf '\n' ;;   # plan/architect/review/design/deep-review + unrecognised: unrestricted
  esac
}

# ---- launch command ---------------------------------------------------------
# cli_for_agent <agent> <model-spec> [posture-request] [job-class] [tools-override]
# -> launch command, exit 0. Exit 1 (no stdout) if <agent> isn't a known
# agent — caller falls back to treating the original argv as a literal
# command.
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

# R3-1 follow-up: the job-based posture override must be the SAME decision
# everywhere a posture gets computed, not just inside cli_for_agent's own
# launch flag -- spawn-task.sh separately computes its own `eff_posture`
# (stamped into the worker's environment as HERDR_POSTURE_FLOOR, which
# governs any GRANDCHILD this worker itself spawns) via resolved_posture
# directly, with no knowledge of job class. Two independent computations of
# "what posture does this spawn get" drift by construction -- a
# research/explore worker's own launch got --approval-mode always-ask, but
# its stamped floor stayed `write`, so a grandchild it spun up could inherit
# a LOOSER floor than its own parent, defeating tighten-only inheritance.
# One function, called from both places.
#
# The force is skipped for `approval=hook` (remote-research-answer-approval,
# 2026-10-02): the whole reason research/explore are forced to `strict` is
# so their write calls hit an omp MENU, which is the only thing that made
# _cp_write_menu_verdict's handoffs_write narrowing (lib/command-policy.sh,
# N8) run at all. A hook-approval task never paints a menu (--auto-approve)
# and instead has EVERY call -- write included -- judged synchronously by
# lib/pretool-shadow.sh's pretool_enforce, whose `write` case now applies
# the identical handoffs_write narrowing to the exact structured path (see
# _ps_plain_write_verdict) -- never a scraped, possibly-clipped panel. So
# for a hook task's OWN launch, `write` is the correct posture: forcing
# `strict` would only block spawn-task.sh's own `--approval hook requires
# the write posture floor` check for no safety gain. menu-mode
# research/explore keeps the original force unchanged.
#
# `purpose` (F9, security review PR #220): a GRANDCHILD this worker spawns
# does not inherit the hook's per-call write judge -- only the worker's own
# session does. `purpose=stamp` (spawn-task.sh's HERDR_POSTURE_FLOOR, which
# every child spawn composes against and can only tighten past) must stay
# `strict` for research/explore in EITHER approval mode; `purpose=launch`
# (the default; what cli_for_agent uses to build --approval-mode) keeps the
# hook-mode `write` carve-out so the hook's own auto-approve swap still
# works. The two no longer have to agree.
posture_want_for_job() {  # <want> <job> [approval] [purpose=launch|stamp] -> effective want request
  local want="$1" job="${2:-}" approval="${3:-menu}" purpose="${4:-launch}"
  case "$job" in
    research|explore)
      if [ "$purpose" = stamp ]; then
        printf 'strict\n'
      elif [ "$approval" = hook ]; then
        printf '%s\n' "$want"
      else
        printf 'strict\n'
      fi ;;
    *) printf '%s\n' "$want" ;;
  esac
}

cli_for_agent() {
  local a="$1" spec="$2" want="${3:-}" job="${4:-}" tools_req="${5:-}" approval="${6:-menu}" m e posture flag
  local has_effort alt alt_model models tools
  local -a argv
  # R3-1 (round-3 security review): research/explore's whole write
  # restriction (handoffs_write, N8) is enforced by _cp_write_menu_verdict,
  # which only ever judges a MENU panel. At the default `write` posture omp
  # auto-approves every in-worktree write with no menu at all, so the
  # restriction never runs and these job classes get an unrestricted,
  # unprompted write tool. Force `strict` here -- the single point every
  # spawn (local or the remote-mcp publisher's own _spawn, which passes no
  # --posture at all) funnels through -- so a caller's lesser request can
  # never leave a write unjudged for these two classes. Skipped for
  # `approval=hook` -- see posture_want_for_job's own comment.
  want="$(posture_want_for_job "$want" "$job" "$approval")"
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
      # spawn-task.sh's standalone --effort rewrites the spec to model:effort;
      # claude takes that as its own --effort flag, never inside --model.
      argv=(claude --model "${spec%%:*}")
      [ "${spec%%:*}" != "$spec" ] && argv+=(--effort "${spec##*:}")
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
  # --tools trims omp's OWN built-ins (tools_for_job, above) — never emitted
  # for omc, which launches the real claude binary and has no such flag.
  # tools_req (the spawner's own --tools override) wins over the job-class
  # table: "all" forces unrestricted, anything else is used verbatim, "" (the
  # default) falls through to the table.
  if [ "${argv[0]}" = omp ]; then
    case "$tools_req" in
      all) tools="" ;;
      "")  tools="$(tools_for_job "$job")" ;;
      *)   tools="$tools_req" ;;
    esac
    [ -n "$tools" ] && argv+=(--tools "$tools")
  fi
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
    --allow-dangerously-skip-permissions|\
    --allowedTools|--allowedTools=*|--allowed-tools|--allowed-tools=*|\
    --no-rules|--no-extensions|--no-skills|--bare|--safe-mode|\
    --system-prompt|--system-prompt=*|--system-prompt-file|--system-prompt-file=*|\
    --append-system-prompt|--append-system-prompt=*|\
    --append-system-prompt-file|--append-system-prompt-file=*|\
    --settings|--settings=*|--setting-sources|--setting-sources=*|\
    --config|--config=*|--profile|--profile=*|--cwd|--cwd=*|\
    --hook|--hook=*|-e|--extension|--extension=*|--plugin-dir|--plugin-dir=*|--plugin-url|--plugin-url=*|\
    --mcp-config|--mcp-config=*|--strict-mcp-config|--agents|--agents=*|\
    --tools|--tools=*|--no-tools|\
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

canonical_rules_source() {   # <project-root> -> ':'-joined sources farthest-first (empty = none); exit 2 = configured but unusable
  local src="${HERDR_CANONICAL_RULES:-}" dir found="" one
  if [ -n "$src" ]; then
    # Explicit operator path(s) — inherited across descendants via the spawn
    # stamp. Any configured-but-unreadable entry FAILS the managed launch
    # (caller aborts on exit 2): silently launching without the operator's
    # rules is the dishonest direction.
    local IFS=':'
    for one in $src; do
      [ -n "$one" ] || continue
      [ -f "$one" ] && [ -r "$one" ] || {
        echo "canonical-rules: HERDR_CANONICAL_RULES entry missing/unreadable: $one" >&2
        return 2
      }
    done
    printf '%s\n' "$src"; return 0
  fi
  dir=$(cd "$1" 2>/dev/null && pwd) || {
    echo "canonical-rules: project root unreadable: $1" >&2
    return 2
  }
  # Walk the ORIGINAL project root's ancestors (never the root itself — its
  # own AGENTS.md loads through normal discovery), stopping at $HOME. omp's
  # own discovery loads EVERY ancestor file, so collect them all, farthest
  # first, rather than stopping at the nearest. The spawners pass repo_root's
  # answer, so a nested spawn from inside a task worktree derives from the
  # real project tree, not the worktree mirror.
  while :; do
    case "$dir" in "$HOME"|/|"") break ;; esac
    dir=$(dirname "$dir")
    [ -e "$dir/AGENTS.md" ] || continue
    if [ -f "$dir/AGENTS.md" ] && [ -r "$dir/AGENTS.md" ]; then
      found="$dir/AGENTS.md${found:+:$found}"
    else
      echo "canonical-rules: ancestor rules exist but are unreadable: $dir/AGENTS.md" >&2
      return 2
    fi
  done
  printf '%s\n' "$found"
}

canonical_rules_compose() {  # <':'-joined sources> -> composed cache file path; exit 1 on failure
  local srcs="$1" dir out one
  dir="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}/canonical-rules"
  mkdir -p "$dir" || return 1
  out="$dir/$(printf '%s' "$srcs" | tr '/ :' '__+').md"
  (
    printf -- '<!-- herdr-control managed launch: canonical operator ancestor rules.\n'
    printf -- '     Sources (outermost first): %s\n' "$srcs"
    printf -- '     Appended because task worktrees live outside the project ancestor\n'
    printf -- '     tree, so upward rule discovery cannot reach these files. The\n'
    printf -- "     worktree's own project rules still load through normal discovery. -->\n"
    IFS=':'
    for one in $srcs; do
      [ -n "$one" ] || continue
      printf -- '\n<!-- source: %s -->\n' "$one"
      cat "$one" || exit 1
    done
    # herdr-control's own worker rules (how approvals work for a spawned
    # worker: code by reference, briefs by reference, the capability
    # manifest). Tracked in this repo, so they ship with the policy they
    # describe instead of living in an operator file that can drift from it.
    if [ -r "$_ap_dir/worker-rules.md" ]; then
      printf -- '\n'
      cat "$_ap_dir/worker-rules.md" || exit 1
    fi
  ) > "$out.tmp.$$" || { rm -f "$out.tmp.$$"; return 1; }
  mv -f "$out.tmp.$$" "$out" || return 1
  printf '%s\n' "$out"
}

# canonical_rules_resolve <agent> <project-root> [launch-cwd]
# Sets CANONICAL_RULES_SRC (':'-joined source paths, "" when none) and
# CANONICAL_RULES_ARGS ("--append-system-prompt <%q path>", "" when none).
# Exit 2 = a configured/derived source exists but is unusable — the caller
# MUST refuse the managed launch rather than launch without it.
# Only omp-backed launches take the flag; omc (the real claude binary, its
# own harness with its own rule discovery) is left alone. When the launch
# cwd sits INSIDE a source's directory tree, normal discovery already loads
# that file — it is dropped from the append rather than loaded twice.
canonical_rules_resolve() {
  CANONICAL_RULES_SRC="" CANONICAL_RULES_ARGS=""
  case "$1" in claude|codex|omp) ;; *) return 0 ;; esac
  local src composed cwd="${3:-}" one keep=""
  src=$(canonical_rules_source "$2") || return 2
  [ -n "$src" ] || return 0
  if [ -n "$cwd" ]; then
    cwd=$(cd "$cwd" 2>/dev/null && pwd) || cwd=""
  fi
  local IFS=':'
  for one in $src; do
    [ -n "$one" ] || continue
    case "${cwd:+$cwd/}" in "$(dirname "$one")/"*) continue ;; esac
    keep="${keep:+$keep:}$one"
  done
  [ -n "$keep" ] || return 0
  composed=$(canonical_rules_compose "$keep") || {
    echo "canonical-rules: could not compose cache from $keep" >&2
    return 2
  }
  CANONICAL_RULES_SRC="$keep"
  CANONICAL_RULES_ARGS="--append-system-prompt $(printf '%q' "$composed")"
}
