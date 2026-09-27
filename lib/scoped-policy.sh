#!/usr/bin/env bash
# lib/scoped-policy.sh — the ONE peer decision, with the task's context.
#
# lib/command-policy.sh judges a command string with no context at all. That is
# the right floor, and it stays the floor: nothing here can clear a `deny`, a
# human-reserved action (conductor_reserved_reason), or an operator rule —
# including the ownership grant, whose command is judged by both with only the
# commit MESSAGE value removed. What this file adds is the task's own,
# already-approved context:
#
#   1. the ownership grant (#3b, _cp_grant_action) — moved here so
#      herdr-select.sh and the alert gate run the identical sequence;
#   2. the task's capability manifest (lib/task-manifest.sh), approved ONCE at
#      spawn and read from the registry row, never from the worker's worktree:
#      its `git` value is a CEILING checked first, and an `escalate` verdict for
#      a shape the manifest covers (_cp_scope_action) clears;
#   3. code by reference: `bash|sh|python3 <file>` is judged by the file's WHOLE
#      content, and a reviewing authority's approval of that content is bound
#      to its sha256 (lib/run-registry.sh file_approvals) — the same content
#      re-runs without a new review; different content escalates again.
#
# Provides:
#   approval_command_text <panel-text> <recorded-cmd>
#       -> the text to judge: the recorded untruncated command when it is
#          whitespace-collapsed equal to the panel's Command:/run: region
#          (_sp_command_region), else the panel. exit 2 when a non-empty
#          recorded command is not equal to that region — including when the
#          panel carries no such label at all (two different realities — the
#          caller refuses, never arbitrates).
#   peer_decide <cmd-text> <task-json>
#       -> 0 when peer authority may press Approve, 1 when it may not; sets
#          PD_VERDICT (allow|escalate|reserved|deny), PD_REASON, PD_AUTHORITY
#          (peer|grant|scope) and, for code by reference, PD_CODE_KIND/PATH/SHA.
#   code_ref_inspect <cmd-text> <worktree> [trunk]
#       -> _cp_code_ref's exit status (0 file, 1 not code-ref, 3 unreadable);
#          on 0 sets PD_CODE_KIND/PATH/SHA and PD_CODE_CONTENT_REASON, all taken
#          from ONE snapshot copy so the hash and the judged bytes are the same.
#          A tracked script byte-identical to the verified trunk tip whose own
#          content is not clean takes the trunk path (_sp_trunk_suite): SHA
#          binds the file AND the worktree's change-set; reason `trunk-clean:`
#          (no change-set: only reviewed trunk code runs) or `trunk:` (one
#          conductor review per change-set). TRUNK defaults to the registry
#          row for WORKTREE.
#
# Not a containment boundary (docs/approval-policy.md rule 7): the file can
# still change between this check and the interpreter opening it, by a process
# other than the blocked worker; and a same-user process can write the registry.
# What it buys is that a reviewed script cannot silently become a different
# script on its next run, and that the approver judges a whole file it can read
# instead of a clipped panel.
[ -n "${_HERDR_SCOPED_POLICY_SH:-}" ] && return 0
_HERDR_SCOPED_POLICY_SH=1
_sp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_sp_dir/command-policy.sh"
. "$_sp_dir/run-registry.sh"

_sp_collapse_ws() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# _sp_command_region <panel> -> the text after the omp "Command:"/"run:"
# label, or empty when the panel carries no such label.
#
# prompt_menu_command (lib/prompt-parse.sh _prompt_menu_parse, mode=command)
# always emits "Allow tool: <tool> " followed by the body rows space-joined,
# one of which is the literal "Command: <cmd>" (or "run: <cmd>", omp's other
# shape — verify-omp-hooks.sh's own omp_menu_screen fixture uses it) row.
# Between the header and that row, omp (18.3.2) may also render, in this
# fixed order, "Origin: MCP server tool " (only for mcp__ tools) and
# "Reason: <varies>" (whenever omp's own policy flags the command, e.g.
# `rg -n shutdown lib/`, `rm -rf /abs/path`) — both stripped below, each
# optional and each at most once, before the Command:/run: case runs. The
# Claude/Codex numbered fallback (prompt_command_text's OTHER branch, the
# whole visible window) carries neither: those hooks never pass a recorded
# command at all (claude-notify.sh calls push_wake with no third argument),
# so a label-less panel has nothing structurally sound to anchor a recorded
# command against.
_sp_command_region() {
  local panel="$1" rest
  case "$panel" in
    "Allow tool: "*) rest="${panel#Allow tool: }"; rest="${rest#* }" ;;
    *) rest="$panel" ;;
  esac
  case "$rest" in "Origin: MCP server tool "*) rest="${rest#Origin: MCP server tool }" ;; esac
  case "$rest" in "Reason: Critical pattern detected Command:"*) rest="${rest#Reason: Critical pattern detected }" ;; esac
  case "$rest" in
    "Command:"*) printf '%s' "${rest#Command:}"; return 0 ;;
    "run:"*)     printf '%s' "${rest#run:}"; return 0 ;;
  esac
  printf ''
}

# approval_command_text <panel> <recorded>
#
# PR #158 independent review, HIGH: the previous rule treated `recorded` as
# corroborated whenever its collapsed text occurred ANYWHERE in the collapsed
# panel — a plain substring match. Reproduced live: panel shows
# `gh api -X PUT repos/o/r/pulls/7/merge`, a hook race records `ls` for the
# SAME prompt_id (change 5's own failure mode before its fix, or any other
# mis-keyed row) — "ls" IS a substring of "...pulls..." — and the wrongly
# "corroborated" `ls` verdict got PRESSED as Approve on the unjudged merge.
#
# Anchored now: a non-empty `recorded` corroborates ONLY when its
# whitespace-collapsed text EQUALS the whitespace-collapsed COMMAND REGION
# (_sp_command_region — everything after Command:/run:, header stripped),
# never a substring of the whole panel. A panel with no recognizable label
# refuses a non-empty recorded command outright (return 2) rather than
# falling back to a substring test against unstructured text — see
# _sp_command_region's own comment for why that is safe (only omp ever pairs
# a panel with a recorded command, and every omp panel carries one of these
# labels). A wrapped command reflows correctly: prompt_menu_command already
# space-joins wrapped rows before this ever runs, so the region for a
# multi-row command is the SAME reconstructed string either way.
approval_command_text() {               # panel recorded
  local panel="$1" recorded="$2" region pc rc
  if [ -z "$recorded" ]; then printf '%s' "$panel"; return 0; fi
  region="$(_sp_command_region "$panel")"
  if [ -z "$region" ]; then
    if [ -n "${panel//[[:space:]]/}" ]; then return 2; fi
    printf '%s' "$panel"; return 0
  fi
  pc="$(_sp_collapse_ws "$region")"; rc="$(_sp_collapse_ws "$recorded")"
  if [ "$pc" = "$rc" ]; then
    printf '%s' "$recorded"; return 0
  fi
  return 2
}

# _sp_clamp_wait_seconds <raw> -> a sane HERDR_SELECT_RECORD_WAIT_S: default
# 4, clamped to 0..15. A non-numeric value (unset, empty, garbage) falls back
# to the default rather than erroring or silently coercing to 0, which would
# look identical to "no wait configured" — _ag_grace_seconds (lib/alert-gate.sh)
# is the same pattern for the same reason.
_sp_clamp_wait_seconds() {
  local raw="${1:-}"
  if ! [[ "$raw" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '4\n'; return 0
  fi
  awk -v v="$raw" 'BEGIN{ if (v < 0) v = 0; if (v > 15) v = 15; printf "%s\n", v }'
}

# wait_for_input_required_row <run_id> <task_id> <prompt_id>
#
# fix/peer-waits-for-record change 1: an input_required row exists the
# INSTANT the hook (agent-hooks/omp-notify.sh -> lib/push-wake.sh push_wake)
# writes it, but herdr-select.sh can be called before that write lands — a
# peer answering as fast as the alert path fires, or the omp hook itself
# racing tool_approval_requested. Live registry, 2026-09-26: event 37805
# input_required and 37806 wake_held landed the SAME second — a
# herdr-select.sh lookup racing between the two found nothing, judged the
# SCRAPED panel instead of the untruncated registry command, and a
# grant-allowable commit (message containing "push") was refused as reserved.
#
# Polls for the ROW'S EXISTENCE, never for a non-empty command: a
# command-less prompt legitimately records command:"" (lib/push-wake.sh
# change 5), and waiting on non-empty would block every one of those for the
# full window instead of the ~0s it actually needs. Bounded by
# HERDR_SELECT_RECORD_WAIT_S (default 4, clamped 0..15, ~0.25s steps); no row
# ever appearing (a hand-started session, an older omp build, a non-bash
# prompt) falls through unchanged, after the wait, to the scraped-panel
# behaviour that predates this function.
#
# HERDR_SELECT_WAIT_TRACE is a TEST SEAM, unset in every real deployment: when
# it names a file, append one line per poll ("poll <n>") and a final "found"
# or "timeout" line. PR #158 review round 2: elapsed-ms assertions raced the
# machine's own speed (a run that should have waited returned in under the
# threshold simply because this host was fast that second). A test can now
# synchronize on the FILE's content — e.g. wait for "poll 1" to appear before
# seeding the row a delayed test depends on — instead of guessing a sleep
# long enough to outrun any machine.
wait_for_input_required_row() {
  local run_id="$1" task_id="$2" prompt_id="$3"
  [ -n "$prompt_id" ] || return 0
  registry_init || return 0
  local wait_s elapsed=0 step=0.25 n poll_n=0
  wait_s="$(_sp_clamp_wait_seconds "${HERDR_SELECT_RECORD_WAIT_S:-}")"
  while :; do
    poll_n=$((poll_n + 1))
    [ -n "${HERDR_SELECT_WAIT_TRACE:-}" ] && printf 'poll %s\n' "$poll_n" >> "$HERDR_SELECT_WAIT_TRACE"
    n="$(_sql "SELECT count(*) FROM events
          WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
            AND type='input_required'
            AND json_extract(payload,'\$.prompt_id')=$(_sq "$prompt_id");" 2>/dev/null)"
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      [ -n "${HERDR_SELECT_WAIT_TRACE:-}" ] && printf 'found\n' >> "$HERDR_SELECT_WAIT_TRACE"
      return 0
    fi
    if ! awk -v e="$elapsed" -v w="$wait_s" 'BEGIN{exit !(e < w)}'; then
      [ -n "${HERDR_SELECT_WAIT_TRACE:-}" ] && printf 'timeout\n' >> "$HERDR_SELECT_WAIT_TRACE"
      return 1
    fi
    sleep "$step"
    elapsed="$(awk -v e="$elapsed" -v s="$step" 'BEGIN{printf "%.4f", e+s}')"
  done
}

# _sp_trunk_suite <wt> <path> <snapshot> [trunk]
#   -> 0 and prints `clean <trunk-sha12>` or `diff <trunk-sha12> <change-set sha256>`
#      when PATH is tracked in WT and SNAPSHOT is byte-identical to that path at
#      the trunk tip as the REMOTE reports it (never the worker-writable
#      refs/remotes/origin/*); 1 otherwise (fall back to the file's own content).
#
# F5: the repo's own suites (verify-*.sh) carry reserved strings as test
# FIXTURES, so their content is `reserved:` and every worker test run needed a
# human. A suite identical to trunk was reviewed and merged — but it sources
# and runs the worktree's lib/*.sh, which the worker may have edited, so the
# file's own sha is not enough (that would reopen red test H4, "nested"). The
# change-set digest binds the whole worktree state: `git diff --binary <tip>`
# (committed, staged and unstaged tracked changes) plus every untracked,
# non-ignored file's path and sha256. An empty change-set means only reviewed
# trunk code can run. A changed .gitignore could hide a new file from the
# digest, so it disqualifies the trunk path.
# ceiling: files ignored by the trunk's own .gitignore rules, and a worker that
# rewrites the `origin` URL itself, are outside what this sees.
_sp_trunk_suite() {                     # wt path snap [trunk]
  local wt="$1" path="$2" snap="$3" trunk="${4:-}" realwt rel tip tmo blob changed untracked digest
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  if [ -z "$trunk" ] && command -v _sql >/dev/null 2>&1; then
    trunk="$(_sql "SELECT trunk FROM tasks WHERE worktree=$(_sq "$wt") ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null)"
  fi
  [[ "$trunk" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  realwt="$(cd "$wt" 2>/dev/null && pwd -P)" || return 1
  case "$path" in "$realwt"/*) rel="${path#"$realwt"/}" ;; *) return 1 ;; esac
  git -C "$realwt" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 1
  tmo="$(command -v timeout || command -v gtimeout)" || return 1
  tip="$("$tmo" 8 git -C "$realwt" ls-remote --exit-code origin "refs/heads/$trunk" 2>/dev/null | cut -f1)"
  [[ "$tip" =~ ^[0-9a-f]{40}$ ]] || return 1
  git -C "$realwt" cat-file -e "$tip^{commit}" 2>/dev/null || return 1
  blob="$(git -C "$realwt" rev-parse --verify -q "$tip:$rel" 2>/dev/null)" || return 1
  [ "$blob" = "$(git -C "$realwt" hash-object --no-filters -- "$snap" 2>/dev/null)" ] || return 1
  changed="$(git -C "$realwt" diff --name-only "$tip" 2>/dev/null)" || return 1
  case $'\n'"$changed" in *$'\n'.gitignore*|*/.gitignore*) return 1 ;; esac
  untracked="$(cd "$realwt" && git ls-files -o --exclude-per-directory=.gitignore -z 2>/dev/null | sort -z |
    xargs -0 -I{} sh -c 'printf "%s %s\n" "$(shasum -a 256 < "$1" | cut -d" " -f1)" "$1"' _ {} 2>/dev/null)"
  case $'\n'"$untracked" in *' .gitignore'*|*'/.gitignore'*) return 1 ;; esac
  if [ -z "$changed" ] && [ -z "$untracked" ]; then
    printf 'clean %s\n' "${tip:0:12}"; return 0
  fi
  digest="$( { git -C "$realwt" diff --binary "$tip" 2>/dev/null; printf '\n--untracked--\n%s\n' "$untracked"; } | shasum -a 256 | cut -d' ' -f1)"
  printf 'diff %s %s\n' "${tip:0:12}" "$digest"
}

code_ref_inspect() {                    # cmd wt [trunk]
  PD_CODE_KIND="" PD_CODE_PATH="" PD_CODE_SHA="" PD_CODE_CONTENT_REASON=""
  local out rc snap
  out="$(_cp_code_ref "$1" "$2")"; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  local order=0
  case "$out" in *$'\t'order) order=1; out="${out%$'\t'order}" ;; esac
  PD_CODE_KIND="${out%%$'\t'*}"; PD_CODE_PATH="${out#*$'\t'}"
  snap="$(mktemp "${TMPDIR:-/tmp}/herdr-coderef.XXXXXX")" || return 3
  if ! cat "$PD_CODE_PATH" > "$snap" 2>/dev/null; then rm -f "$snap"; return 3; fi
  PD_CODE_SHA="$(shasum -a 256 < "$snap" | cut -d' ' -f1)"
  PD_CODE_CONTENT_REASON="$(_cp_code_content_reason "$PD_CODE_KIND" "$snap" "$(dirname "$PD_CODE_PATH")")"
  # Something else in the command could rewrite or feed what this run
  # executes (_cp_coderef_others_unsafe): the file stays bound, but it is
  # reviewed every time and an earlier approval never replays. Reserved
  # content keeps its stronger reason.
  if [ "$order" = 1 ]; then
    case "$PD_CODE_CONTENT_REASON" in
      reserved:*) ;;
      *) PD_CODE_CONTENT_REASON="nested: the command also runs something that could change $PD_CODE_PATH before or while it runs — review the whole command${PD_CODE_CONTENT_REASON:+; $PD_CODE_CONTENT_REASON}" ;;
    esac
  elif [ -n "$PD_CODE_CONTENT_REASON" ]; then
    # F5: a merged suite whose own content trips the checks (fixtures). Never
    # when the order gate fired: something else in the command runs too.
    local ts
    if ts="$(_sp_trunk_suite "$2" "$PD_CODE_PATH" "$snap" "${3:-}")"; then
      set -- $ts
      if [ "$1" = clean ]; then
        PD_CODE_CONTENT_REASON="trunk-clean: identical to trunk @$2 and the worktree has no changes against it — only reviewed trunk code runs"
        PD_CODE_SHA="$(printf '%s\nclean %s\n' "$PD_CODE_SHA" "$2" | shasum -a 256 | cut -d' ' -f1)"
      else
        PD_CODE_CONTENT_REASON="trunk: identical to trunk @$2 but it runs over worktree change-set ${3:0:12} — a conductor may review \`git diff $2\` plus untracked files and approve once for this state"
        PD_CODE_SHA="$(printf '%s\n%s\n' "$PD_CODE_SHA" "$3" | shasum -a 256 | cut -d' ' -f1)"
      fi
    fi
  fi
  rm -f "$snap"
  return 0
}

peer_decide() {                         # cmd task-json
  local cmd="$1" task="$2" wt branch trunk manifest task_id s ceil res rc state
  PD_VERDICT=escalate PD_REASON="" PD_AUTHORITY=peer
  PD_CODE_KIND="" PD_CODE_PATH="" PD_CODE_SHA=""
  wt="$(printf '%s' "$task" | jq -r '.worktree // empty' 2>/dev/null)"
  branch="$(printf '%s' "$task" | jq -r '.branch // empty' 2>/dev/null)"
  trunk="$(printf '%s' "$task" | jq -r '.trunk // empty' 2>/dev/null)"
  manifest="$(printf '%s' "$task" | jq -r '.manifest // empty' 2>/dev/null)"
  task_id="$(printf '%s' "$task" | jq -r '.task_id // empty' 2>/dev/null)"

  if [ -z "${cmd//[[:space:]]/}" ]; then
    PD_REASON="unreadable prompt — nothing to classify"; return 1
  fi

  # The manifest's declared ceiling binds even the ownership grant: a task
  # spawned `git: commit-only` does not get its push pressed by a peer.
  ceil="$(_cp_scope_ceiling "$cmd" "$manifest")"
  if [ -n "$ceil" ]; then PD_REASON="$ceil"; return 1; fi

  s="$(_cp_grant_action "$cmd" "$wt" "$branch" "$trunk" 2>/dev/null)"
  if [ -n "$s" ]; then
    # A grant never skips operator rules or the human-reserved list. The only
    # exception is the value of a git commit message, because #3b exists to
    # stop policy-file words inside that value from being misread as actions.
    _cp_best_v=0; _cp_best_r=""
    _cp_apply_operator_rules "$(scannable_command "$cmd")"
    if [ "$_cp_best_v" -gt 0 ]; then
      PD_VERDICT=reserved PD_REASON="$_cp_best_r"; return 1
    fi
    local grant_check="$cmd"
    case "$cmd" in "cd ${wt} && "*) grant_check="${cmd#cd "$wt" && }" ;; esac
    case "$s" in
      "git add"*|"git commit"*) grant_check="$(_cp_strip_commit_message "$cmd" "$wt")" ;;
    esac
    res="$(conductor_reserved_reason "$grant_check")"
    if [ -n "$res" ]; then PD_VERDICT=reserved PD_REASON="$res"; return 1; fi
    if [ "$(classify_command "$grant_check")" = deny ]; then
      PD_VERDICT=deny PD_REASON="$(classify_reason)"; return 1
    fi
    PD_VERDICT=allow PD_AUTHORITY=grant PD_REASON="ownership grant: $s"; return 0
  fi

  PD_VERDICT="$(classify_command "$cmd")"; PD_REASON="$(classify_reason)"
  res="$(conductor_reserved_reason "$cmd")"
  if [ -n "$res" ]; then PD_VERDICT=reserved PD_REASON="$res"; return 1; fi

  if [ "$PD_VERDICT" = escalate ]; then
    s="$(_cp_scope_action "$cmd" "$wt" "$manifest" 2>/dev/null)"
    if [ -n "$s" ]; then PD_VERDICT=allow PD_AUTHORITY=scope PD_REASON="$s"; fi
  fi
  [ "$PD_VERDICT" = allow ] || return 1

  # Code by reference needs a registered task: the worktree to resolve a
  # relative path against and the task id its approvals bind to. An
  # unregistered pane (a hand-started session peer-answer.sh sweeps) keeps
  # exactly the pre-existing judgment of the command line alone.
  [ -n "$wt" ] || return 0
  code_ref_inspect "$cmd" "$wt" "$trunk"; rc=$?
  case "$rc" in
    1) return 0 ;;
    0) ;;
    *) PD_VERDICT=escalate PD_REASON="runs a script file that cannot be resolved or read for review"; return 1 ;;
  esac
  local short="${PD_CODE_SHA:0:12}"
  # F5: a merged suite over a worktree with no changes against the verified
  # trunk tip runs only reviewed code — no approval needed.
  case "$PD_CODE_CONTENT_REASON" in
    trunk-clean:*) PD_REASON="${PD_REASON:+$PD_REASON; }$PD_CODE_PATH $PD_CODE_CONTENT_REASON"; return 0 ;;
  esac
  state=none
  [ -n "$task_id" ] && state="$(file_approval_state "$task_id" "$PD_CODE_PATH" "$PD_CODE_SHA")"
  case "$state" in
    approved)
      # A hash binds ONE file's bytes. A script that runs or imports other
      # local files would carry those files' later edits through a stale
      # approval, so it never re-runs on one — every run is a review.
      case "$PD_CODE_CONTENT_REASON" in
        reserved:*|nested:*)
          PD_VERDICT=reserved
          PD_REASON="$PD_CODE_CONTENT_REASON — an approved file cannot be replayed by a peer when its content is reserved or runs other files"
          return 1 ;;
      esac
      PD_REASON="${PD_REASON:+$PD_REASON; }$PD_CODE_PATH approved at sha256 $short"; return 0 ;;
    changed)
      PD_VERDICT=escalate
      case "$PD_CODE_CONTENT_REASON" in
        trunk:*) PD_REASON="$PD_CODE_CONTENT_REASON — the worktree changed since this suite was approved (now sha256 $short)" ;;
        *) PD_REASON="$PD_CODE_PATH changed since it was approved (now sha256 $short) — review the whole file again" ;;
      esac
      return 1 ;;
  esac
  if [ -z "$PD_CODE_CONTENT_REASON" ]; then
    PD_REASON="${PD_REASON:+$PD_REASON; }$PD_CODE_PATH content classifies clean (sha256 $short)"; return 0
  fi
  case "$PD_CODE_CONTENT_REASON" in
    reserved:*) PD_VERDICT=reserved ;;
    *) PD_VERDICT=escalate ;;
  esac
  PD_REASON="$PD_CODE_CONTENT_REASON — file $PD_CODE_PATH sha256 $short; a conductor may review the whole file and approve it (bound to this sha256)"
  return 1
}
