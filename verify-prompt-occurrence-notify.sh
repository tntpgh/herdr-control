#!/usr/bin/env bash
# verify-prompt-occurrence-notify.sh — agent-hooks/omp-notify.sh's wiring into
# lib/prompt-occurrence.py (docs/plans/dot-herdr-recovery-slices.md §2):
# "Persist request before probing; failed parsing updates display status
# instead of discarding the observation." Proves a prompt_occ_screen row is
# written for EVERY outcome of the five-attempt probe loop (parseable,
# no_prompt, read_failed), never only the success case, and that a caller
# with no call_id/native_session (the `ask` path, or any hand-started
# session) still gets exactly today's behavior: nothing written.
#
# Stubs herdr as a real EXECUTABLE FILE on PATH, not an exported bash
# function. An earlier attempt at this exact test (see
# .handoffs/PROOF.md#review-dc6a55d-fix-2, "Dropped from this slice") used
# `export -f herdr` and lost the stub through nested bash: omp-notify.sh's
# own `_prompt_is_up`/`prompt_occurrence_display` call lib/prompt-parse.sh's
# `_pane_read_raw`, which runs in command substitutions and pipelines —
# subshells an exported FUNCTION does not reliably survive, verified live
# (`type -t herdr` flipped from `function` to not-found between the export
# and the call site in some reproductions). A real file on PATH has no such
# boundary: every subshell, pipeline and nested `bash` invocation resolves it
# identically, because PATH lookup is a kernel-level exec, not a shell
# feature.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# Prerequisite (not a test): the binding fixtures below (F2b) drive the REAL
# herdr-select.sh through its bound-bash path, which classifies the exact
# recorded command via lib/command-policy.sh's bashlex escalation gate
# (install.sh --apply provisions the interpreter at .venv-bashlex). Without
# it every non-trivial command escalates, which would report this suite's
# own setup as the thing under test rather than the binding logic.
if [ ! -x "$here/.venv-bashlex/bin/python3" ] ||
   [ "$(printf 'true' | "$here/.venv-bashlex/bin/python3" "$here/lib/bashlex_classify.py" 2>/dev/null)" != ALLOW ]; then
  echo "PREREQ MISSING: $here/.venv-bashlex (bash parser helper); run install.sh --apply — suite not run" >&2
  exit 2
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_SLACK_LEVEL=all
# herdr-control: approval friction fix (2026-10-16). lib/push-wake.sh's pid
# capture now retries (prompt_id_settled, lib/prompt-parse.sh) so a
# genuinely settling panel gets a second look before the write-time
# corroboration gives up. Every fixture in this suite is a STATIC screen
# (nothing changes between reads), so retrying can only add wall time, never
# change an outcome -- pinned to 0 (single read, today's exact behavior)
# everywhere except the dedicated settle-retry regression cases below, which
# set it back explicitly.
export HERDR_PROMPT_SETTLE_WAIT_S=0
# herdr-control #308: the retry loop for an occurrence already proven alive
# (bound, or genuinely queued behind a still-open sibling) now waits out a
# SEPARATE, longer `_queue_budget` instead of the short fast-poll `_budget`
# (agent-hooks/omp-notify.sh). Pinned low here so every pre-existing timing
# assertion in this suite keeps its old, fast behavior; the dedicated #308
# regression cases below override it back up, exactly like
# HERDR_NOTIFY_UNREADABLE_DEADLINE_S above.
export HERDR_NOTIFY_QUEUE_DEADLINE_S=3
WORKER_SCREEN="$WORK/worker.txt"
COND_SCREEN="$WORK/cond.txt"
: > "$COND_SCREEN"
FAIL_MARKER="$WORK/fail-read"
export WORKER_SCREEN COND_SCREEN FAIL_MARKER

WPANE="w1:p1"
export WPANE

# ---- the stub: one executable FILE, not a function ------------------------
STUBBIN="$WORK/bin"
export STUBBIN
mkdir -p "$STUBBIN"
cat > "$STUBBIN/herdr" <<'EOS'
#!/usr/bin/env bash
# Minimal stand-in for the real `herdr` CLI. "pane read" covers everything
# this file's own omp-notify.sh probes need. The F2/F3/F2b binding
# fixtures additionally drive the REAL herdr-select.sh (not just the
# notify hook), which needs process-info/list/send-keys too -- same shape
# as verify-approval-payload.sh's exported-function stub, ported to a PATH
# file for the reason explained at the top of this script. FAIL_MARKER
# present means "simulate a transport failure" (pane gone / herdr socket
# down) — prints nothing and exits nonzero, which is exactly how
# prompt_occurrence_display distinguishes read_failed from a
# successful-but-empty read.
case "$1 $2" in
  "pane read")
    if [ -n "${FAIL_MARKER:-}" ] && [ -f "$FAIL_MARKER" ]; then
      exit 7
    fi
    # SWITCH_ON_CLAIM: once the hook has taken its attention claim (the
    # step right before push_wake), serve the replacement screen — a
    # deterministic "screen changed between the final guard and
    # push_wake's own read".
    if [ -n "${SWITCH_ON_CLAIM:-}" ] && [ "$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
         "SELECT count(*) FROM events WHERE type='attention_tracking';" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
      cat "$SWITCH_ON_CLAIM"; exit 0
    fi
    cat "${WORKER_SCREEN:?}"
    exit 0
    ;;
  "pane process-info")
    pid=999999
    [ "${4:-}" != "${HERDR_FIXTURE_CALLER_PANE:-}" ] || pid="$PPID"
    printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"claude","cmdline":"claude"}]}}}\n' "$pid"
    exit 0
    ;;
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"},{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"}]}}\n' \
      "${SELPANE:-}" "${SELBIRTH:-}" "${SELCOND:-}" "${SELCBIRTH:-}"
    exit 0
    ;;
  "pane send-keys")
    printf '%s\n' "${4:-}" >> "${SEL_KEYS:-/dev/null}"
    exit 0
    ;;
esac
exit 0
EOS
chmod +x "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"
command -v herdr | grep -qx "$STUBBIN/herdr" \
  && ok "stub herdr resolves from PATH, not a shell function" \
  || bad "PATH stub not found first: $(command -v herdr)"
# herdr-select.sh's own PATH hardening (line ~105: it PREPENDS
# /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ahead of whatever PATH it
# inherits) would let a REAL `herdr` binary on this host shadow our file
# stub for every herdr-select.sh call the F2/F3/F2b fixtures below make --
# an exported bash FUNCTION is resolved before PATH is ever consulted, so
# it is immune to that prepend. This body is INLINE (never delegates to
# the file above by forking a subprocess): herdr-select.sh's own
# caller_pane_from_ancestry identifies the caller by $PPID, which must be
# the PID of whatever invoked herdr-select.sh itself -- a forked
# subprocess stub would answer with the wrong (one-hop-further) pid and
# break that identity match. Same subcommand set as the file stub above,
# kept in sync by hand; wherever this script's own nested-subshell probes
# lose the exported function (the documented reason this file uses a file
# stub at all for ITS OWN omp-notify.sh calls), the file on PATH is still
# there as a fallback.
herdr() {
  case "$1 $2" in
    "pane read")
      if [ -n "${FAIL_MARKER:-}" ] && [ -f "$FAIL_MARKER" ]; then return 7; fi
      if [ -n "${SWITCH_ON_CLAIM:-}" ] && [ "$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
           "SELECT count(*) FROM events WHERE type='attention_tracking';" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        cat "$SWITCH_ON_CLAIM"; return 0
      fi
      cat "${WORKER_SCREEN:?}"
      return 0
      ;;
    "pane process-info")
      local pid=999999
      [ "${4:-}" != "${HERDR_FIXTURE_CALLER_PANE:-}" ] || pid="$PPID"
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"claude","cmdline":"claude"}]}}}\n' "$pid"
      return 0
      ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"},{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"}]}}\n' \
        "${SELPANE:-}" "${SELBIRTH:-}" "${SELCOND:-}" "${SELCBIRTH:-}"
      return 0
      ;;
    "pane send-keys")
      printf '%s\n' "${4:-}" >> "${SEL_KEYS:-/dev/null}"
      return 0
      ;;
  esac
  return 0
}
export -f herdr
# herdr-select.sh's caller_pane_from_ancestry walks process ancestry via
# `ps -o ppid= -p <pid>`; stub it so the walk terminates after one hop
# (parent "1") instead of reading this harness's own real process tree --
# same convention verify-approval-payload.sh uses.
ps() { printf '1\n'; }
export -f ps

# A no-op Slack notifier and no conductor pane — push_wake's own
# missing-conductor guard (lib/push-wake.sh) makes the rest of the alert
# path a no-op without needing a second stubbed pane.
NOOP="$WORK/noop-notify.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"
chmod +x "$NOOP"

RUN_ID="runN"; TASK_ID="taskN"

run_notify() {                          # <extra jq fields...>
  local extra="$1"
  printf '{"tool":"bash","message":"omp needs your permission","cwd":"/tmp/repo"%s}' "$extra" \
    | ( export HERDR_PANE_ID="$WPANE" HERDR_RUN_ID="$RUN_ID" HERDR_TASK_ID="$TASK_ID" \
               HERDR_NOTIFY="$NOOP" HERDR_CONDUCTOR_PANE_ID=""
        bash "$here/agent-hooks/omp-notify.sh" >"$WORK/n.out" 2>"$WORK/n.err" )
}

screen_rows() {                         # -> count of prompt_occ_screen rows
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT count(*) FROM events WHERE type='prompt_occ_screen';" 2>/dev/null || printf 0
}

screen_display() {                      # -> the display field of the one row
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT payload FROM events WHERE type='prompt_occ_screen' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null \
    | jq -r '.display // ""' 2>/dev/null
}

omp_menu() {                            # <command> -> a complete omp approval panel
  # Same shape verify-omp-hooks.sh's own omp_menu_screen proves parseable:
  # header, blank, highlighted Approve row (ANSI 24-bit background), Deny,
  # blank, navigation footer. The ansi-highlight is what the strict parser
  # (lib/prompt-parse.sh's _prompt_menu_parse) needs to resolve a complete
  # panel rather than a merely menu-shaped one.
  printf ' Allow tool: bash\n'
  printf '   run: %s\n' "$1"
  printf '\n'
  printf '\033[48;2;40;40;40m  Approve\033[0m\n'
  printf '   Deny\n'
  printf '\n'
  printf ' up/down navigate  enter select  esc cancel\n'
}

# -- pending_parseable: a real omp menu is on screen -------------------------
rm -f "$FAIL_MARKER"
omp_menu "printf smoke" > "$WORKER_SCREEN"
( . "$here/lib/run-registry.sh"; register_task "$RUN_ID" "$TASK_ID" w1 cond1 "" "" "$WPANE" "" /repo /wt "review:notify-probe" ) >/dev/null 2>&1
# Production order: onApprovalRequested records seen before this hook runs.
python3 "$here/lib/prompt-occurrence.py" seen --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-1 --call-id call-1 \
  --tool bash --source test >/dev/null 2>&1
run_notify ',"call_id":"call-1","native_session":"sess-1"'
[ "$(screen_rows)" = 1 ] && ok "a parseable menu persists exactly one prompt_occ_screen row" \
  || bad "expected 1 screen row, got $(screen_rows): $(cat "$WORK/n.err")"
[ "$(screen_display)" = pending_parseable ] \
  && ok "parseable menu records display=pending_parseable" \
  || bad "expected pending_parseable, got $(screen_display)"

# -- no_prompt: the read succeeds but nothing prompt-shaped is on screen ----
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
printf 'ordinary agent output, nothing to see here\n' > "$WORKER_SCREEN"
run_notify ',"call_id":"call-2","native_session":"sess-2"'
[ "$(screen_rows)" = 1 ] && ok "a failed (not-found) probe still persists a screen row instead of discarding it" \
  || bad "expected 1 screen row on a failed probe, got $(screen_rows)"
[ "$(screen_display)" = no_prompt ] \
  && ok "an idle pane with nothing prompt-shaped records display=no_prompt" \
  || bad "expected no_prompt, got $(screen_display)"

# -- read_failed: the transport itself fails --------------------------------
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
: > "$FAIL_MARKER"
run_notify ',"call_id":"call-3","native_session":"sess-3"'
rm -f "$FAIL_MARKER"
[ "$(screen_display)" = read_failed ] \
  && ok "a transport failure is distinguished from an empty read: display=read_failed" \
  || bad "expected read_failed, got $(screen_display)"

# -- no call_id/native_session (the `ask` path today): zero rows, no change -
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
omp_menu "printf smoke" > "$WORKER_SCREEN"
run_notify ''
[ "$(screen_rows)" = 0 ] \
  && ok "no call_id/native_session (ask path) skips persistence, unchanged behavior" \
  || bad "expected 0 screen rows with no occurrence identity, got $(screen_rows)"

# -- a panel that paints UNREADABLE and only later parses (w7S:p7 23:31Z) ----
# The five fast probes miss it; the bounded extension must keep looking and
# then record the hook's own input_required (tool from the hook event, never
# the screen) so herdr-select can corroborate the tool.
keyhint_panel() {                       # live OMP 18.10.4 key-hint approval panel
  printf '╭─ Allow tool: bash\n│ Command: printf smoke\n├────────────────\n│ 󰘴 󰌑/󰘴 Q approve · 󱊷 deny\n╰────────────────\n'
}
unreadable_menu() {                     # gate matches, strict parse fails (row after footer)
  keyhint_panel; printf 'partially painted output\n'
}
tooled_rows() {
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT count(*) FROM events WHERE type='input_required' AND json_extract(payload,'\$.tool')='bash';" 2>/dev/null || printf 0
}
seen() {                                # <call> <session>: production order — onApprovalRequested records seen first
  python3 "$here/lib/prompt-occurrence.py" seen --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session "$2" --call-id "$1" \
    --tool bash --source test >/dev/null 2>&1
}
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
# input_required is only appended for a registered task (as every real
# spawn-task.sh worker is); register one so push_wake's write is observable.
( . "$here/lib/run-registry.sh"; register_task "$RUN_ID" "$TASK_ID" w1 cond1 "" "" "$WPANE" "" /repo /wt "review:notify-probe" ) >/dev/null 2>&1
seen call-5 sess-5
unreadable_menu > "$WORKER_SCREEN"
( sleep 2.5; keyhint_panel > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN" ) &
run_notify ',"call_id":"call-5","native_session":"sess-5"'
wait
[ "$(screen_display)" = pending_parseable ] \
  && ok "late-parsing panel is recorded pending_parseable after the bounded wait" \
  || bad "late-parsing panel display=$(screen_display)"
[ "$(tooled_rows)" -ge 1 ] \
  && ok "late-parsing panel gets the hook-written input_required carrying tool=bash" \
  || bad "no tooled input_required for late-parsing panel: $(cat "$WORK/n.err")"

# -- a later tool call's own seen does not disturb an earlier, still-open
# occurrence's wait: the earlier call keeps waiting for (and correctly
# binds to) its own panel instead of giving up the instant a later seen
# exists — the "A" side of the fix/notify-binding-concurrent trace: A's
# own hook exited at once with superseded=1 merely because A "was not the
# task's latest seen", even though A's panel was the one genuinely on
# screen. Only an explicit resolution (declined/withdrawn/completed, the
# next case below) supersedes a still-open occurrence now — a newer SEEN
# alone no longer does.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-8 sess-8
unreadable_menu > "$WORKER_SCREEN"
( sleep 1.8; seen call-9 sess-8; sleep 0.7; keyhint_panel > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN" ) &
run_notify ',"call_id":"call-8","native_session":"sess-8"'
wait
[ "$(tooled_rows)" -ge 1 ] && [ "$(screen_rows)" = 1 ] \
  && ok "a still-open earlier occurrence keeps waiting through a later seen and still binds to its own panel" \
  || bad "earlier-occurrence-survives-later-seen: tooled=$(tooled_rows) screen=$(screen_rows)"

# -- resolved during the wait (declined): cancel, no push ------------------
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-10 sess-10
unreadable_menu > "$WORKER_SCREEN"
( sleep 1.8; python3 "$here/lib/prompt-occurrence.py" declined --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-10 --call-id call-10 >/dev/null 2>&1 ) &
start=$(date +%s)
run_notify ',"call_id":"call-10","native_session":"sess-10"'
elapsed=$(( $(date +%s) - start )); wait
[ "$(tooled_rows)" = 0 ] && [ "$elapsed" -le 5 ] \
  && ok "a declined occurrence cancels the wait (${elapsed}s) and pushes nothing" \
  || bad "declined: tooled=$(tooled_rows) elapsed=${elapsed}s"

# -- stays unreadable: ONE total budget (fast probes included), env clamped -
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-6 sess-6
unreadable_menu > "$WORKER_SCREEN"
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=3 run_notify ',"call_id":"call-6","native_session":"sess-6"'
elapsed=$(( $(date +%s) - start ))
[ "$(tooled_rows)" = 0 ] && [ "$elapsed" -le 5 ] \
  && ok "a never-parseable panel stops within the total budget (${elapsed}s) and writes no input_required" \
  || bad "unreadable panel: tooled=$(tooled_rows) elapsed=${elapsed}s"
[ ! -e "$HERDR_RUN_STATE_DIR/diagnostics" ] \
  && ok "no terminal content is captured to disk" \
  || bad "diagnostics dir exists: $(ls "$HERDR_RUN_STATE_DIR/diagnostics")"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-14 sess-14
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=999 run_notify ',"call_id":"call-14","native_session":"sess-14"'
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 13 ] && ok "an oversized deadline override is clamped to 10s total (${elapsed}s)" \
  || bad "deadline override not clamped: ${elapsed}s"

# -- races on the FAST path: a LATER call sees an already-up, ambiguous
# panel at once but it is not yet its turn — an EARLIER, still-open
# call-12 was seen first — so it must wait, bounded, for its own panel
# rather than binding to the one already showing (the "B" side of the
# same trace). A short deadline override keeps the assertion fast.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-12 sess-11; seen call-11 sess-11      # call-12 is earliest/still open
keyhint_panel > "$WORKER_SCREEN"
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=3 run_notify ',"call_id":"call-11","native_session":"sess-11"'
elapsed=$(( $(date +%s) - start ))
[ "$(tooled_rows)" = 0 ] && [ "$(screen_rows)" = 1 ] && [ "$elapsed" -ge 2 ] \
  && ok "fast-path parse while a still-open earlier call is queued ahead waits (${elapsed}s), binding nothing" \
  || bad "fast-path not-yet-turn: tooled=$(tooled_rows) screen=$(screen_rows) elapsed=${elapsed}s"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-13 sess-13
python3 "$here/lib/prompt-occurrence.py" declined --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-13 --call-id call-13 >/dev/null 2>&1
run_notify ',"call_id":"call-13","native_session":"sess-13"'
[ "$(tooled_rows)" = 0 ] \
  && ok "fast-path parse after the occurrence was declined pushes nothing" \
  || bad "fast-path declined: tooled=$(tooled_rows)"

# -- missing seen fails CLOSED: no binding evidence, no provenance write ----
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
keyhint_panel > "$WORKER_SCREEN"                # no seen recorded at all (unknown + empty latest)
run_notify ',"call_id":"call-15","native_session":"sess-15"'
[ "$(tooled_rows)" = 0 ] && [ "$(screen_rows)" = 0 ] \
  && ok "unknown occurrence with no seen anywhere writes no tool provenance" \
  || bad "unknown+empty latest: tooled=$(tooled_rows) screen=$(screen_rows)"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-17 sess-16                            # only the NEW call's seen exists
run_notify ',"call_id":"call-16","native_session":"sess-16"'   # delayed old hook, its seen missing
[ "$(tooled_rows)" = 0 ] && [ "$(screen_rows)" = 0 ] \
  && ok "delayed old hook with missing seen cannot attach its tool to the new panel" \
  || bad "old hook/new panel: tooled=$(tooled_rows) screen=$(screen_rows)"

# -- notifier blocks; meanwhile old resolves, new seen, new panel ----------
# The authoritative record is written before any notification under the
# bound prompt id; nothing during/after the notifier may give the NEW prompt
# the old hook's tool.
keyhint_cmd_panel() {                   # <command>
  printf '╭─ Allow tool: bash\n│ Command: %s\n├────────────────\n│ 󰘴 󰌑/󰘴 Q approve · 󱊷 deny\n╰────────────────\n' "$1"
}
pid_rows() {                            # <prompt_id> -> tooled input_required rows for it
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT count(*) FROM events WHERE type='input_required' AND json_extract(payload,'\$.tool')='bash' AND json_extract(payload,'\$.prompt_id')='$1';"
}
screen_pid() { ( . "$here/lib/pane-guard.sh"; . "$here/lib/prompt-parse.sh"; prompt_id "$WPANE" ); }
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
keyhint_cmd_panel "rm -rf /tmp/new-prompt" > "$WORK/new.txt"
keyhint_cmd_panel "rm -rf /tmp/new-prompt" > "$WORKER_SCREEN"; NEW_PID="$(screen_pid)"
keyhint_cmd_panel "rm -rf /tmp/old-prompt" > "$WORKER_SCREEN"; OLD_PID="$(screen_pid)"
seen call-20 sess-20
RACE_NOTIFY="$WORK/race-notify.sh"
cat > "$RACE_NOTIFY" <<EOS
#!/usr/bin/env bash
echo called >> "$WORK/race-called"
python3 "$here/lib/prompt-occurrence.py" declined --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-20 --call-id call-20 >/dev/null 2>&1
python3 "$here/lib/prompt-occurrence.py" seen --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-20 --call-id call-21 --tool bash --source test >/dev/null 2>&1
cp "$WORK/new.txt" "$WORKER_SCREEN"
sleep 1
EOS
chmod +x "$RACE_NOTIFY"
rm -f "$WORK/race-called"
printf '{"tool":"bash","message":"m","cwd":"/tmp/repo","command":"rm -rf /tmp/old-prompt","call_id":"call-20","native_session":"sess-20"}' \
  | ( export HERDR_PANE_ID="$WPANE" HERDR_RUN_ID="$RUN_ID" HERDR_TASK_ID="$TASK_ID" \
             HERDR_NOTIFY="$RACE_NOTIFY" HERDR_CONDUCTOR_PANE_ID="" HERDR_SLACK_LEVEL=all HERDR_ALERT_GRACE_S=0
      bash "$here/agent-hooks/omp-notify.sh" >"$WORK/n.out" 2>"$WORK/n.err" )
sleep 1.5
[ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && [ -f "$WORK/race-called" ] \
  && [ "$(pid_rows "$NEW_PID")" = 0 ] && [ "$(pid_rows "$OLD_PID")" = 1 ] \
  && ok "notifier-blocked race: old prompt keeps its row, new prompt gets no old tool row" \
  || bad "notifier race: called=$([ -f "$WORK/race-called" ] && echo y || echo n) new=$(pid_rows "$NEW_PID") old=$(pid_rows "$OLD_PID")"

# -- push_wake refuses when the screen is no longer the expected prompt -----
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
cp "$WORK/new.txt" "$WORKER_SCREEN"
( export HERDR_PANE_ID="$WPANE" HERDR_RUN_ID="$RUN_ID" HERDR_TASK_ID="$TASK_ID" HERDR_CONDUCTOR_PANE_ID=""
  . "$here/lib/pane-guard.sh"; . "$here/lib/prompt-parse.sh"; . "$here/lib/run-registry.sh"; . "$here/lib/push-wake.sh"
  HERDR_EXPECT_PROMPT_ID="$OLD_PID" push_wake "m" "repo" "" bash record-only ) >/dev/null 2>&1
[ "$(pid_rows "$NEW_PID")" = 0 ] && [ "$(pid_rows "$OLD_PID")" = 0 ] \
  && ok "push_wake with a stale expected prompt id writes nothing" \
  || bad "push_wake expect-id: new=$(pid_rows "$NEW_PID") old=$(pid_rows "$OLD_PID")"

# -- mid-paint frame reads as NO prompt, then the panel parses (live 00:45Z) -
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-7 sess-7
printf 'ordinary agent output\n' > "$WORKER_SCREEN"
( sleep 2.5; unreadable_menu > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN"
  sleep 1; printf 'repaint\n' > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN"
  sleep 1; keyhint_panel > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN" ) &
run_notify ',"call_id":"call-7","native_session":"sess-7"'
wait
[ "$(tooled_rows)" -ge 1 ] \
  && ok "a panel that flips no-prompt/unreadable before parsing still gets its tooled row" \
  || bad "flipping panel: tooled=$(tooled_rows)"

# -- a bound request whose panel never paints: bounded, writes nothing ------
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-22 sess-22
printf 'ordinary agent output\n' > "$WORKER_SCREEN"
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=3 run_notify ',"call_id":"call-22","native_session":"sess-22"'
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 5 ] && [ "$(tooled_rows)" = 0 ] \
  && ok "never-painted panel stops at the budget (${elapsed}s) with no tooled row" \
  || bad "never-painted: ${elapsed}s tooled=$(tooled_rows)"
tr_row="$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT payload FROM events WHERE type='notify_probe_outcome' ORDER BY sequence DESC LIMIT 1;")"
[ "$(printf '%s' "$tr_row" | jq -r '.outcome+"|"+.entry_binding+"|"+.tool_call_id')" = "no_provenance|bound|call-22" ] \
  && ! printf '%s' "$tr_row" | grep -q 'ordinary agent output' \
  && ok "a firing that ends without provenance leaves an id-only outcome trace" \
  || bad "outcome trace: $tr_row"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-23 sess-23
keyhint_panel > "$WORKER_SCREEN"
run_notify ',"call_id":"call-23","native_session":"sess-23"'
outc() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT json_extract(payload,'\$.outcome') FROM events WHERE type='notify_probe_outcome' ORDER BY sequence;"; }
[ "$(outc)" = push_attempted_tool_row_present ] \
  && ok "a provenance write is traced as attempted with the tool row observed" \
  || bad "push trace: $(outc)"
run_notify ',"call_id":"call-23","native_session":"sess-23"'
[ "$(outc | wc -l | tr -d ' ')" = 2 ] \
  && ok "a repeat firing for the same call keeps its own trace row" \
  || bad "repeat firing traces: $(outc | tr '\n' ,)"

# -- expected-id mismatch at push time: refused, traced truthfully -----------
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-24 sess-24
keyhint_cmd_panel "rm -rf /tmp/old-prompt" > "$WORKER_SCREEN"
SWITCH_ON_CLAIM="$WORK/new.txt" run_notify ',"call_id":"call-24","native_session":"sess-24"'
[ "$(pid_rows "$NEW_PID")" = 0 ] && [ "$(pid_rows "$OLD_PID")" = 0 ] && [ "$(outc)" = push_attempted_no_tool_row ] \
  && ok "screen switching before push_wake's read: nothing written, trace says no tool row" \
  || bad "expect-id mismatch: new=$(pid_rows "$NEW_PID") old=$(pid_rows "$OLD_PID") trace=$(outc)"

# -- fix/notify-binding-scope regression: a never-resolved occurrence from a
# DIFFERENT session (a crash, killed pane, or a harness restart losing the
# in-memory callId map before tool_execution_end ever fires) must not
# starve a later call in a different session forever. Before the
# (pane,birth,session)-scoped fold filter, "earliest requested across the
# whole task" picked the stale sess-30 occurrence permanently and every
# later call's hook saw _occ_not_yet=1 forever (review BLOCK, Finding 1).
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-30 sess-30                            # stale: seen, never resolved
seen call-31 sess-31
keyhint_panel > "$WORKER_SCREEN"
run_notify ',"call_id":"call-31","native_session":"sess-31"'
[ "$(tooled_rows)" -ge 1 ] \
  && ok "a stale never-resolved occurrence in another session does not block a later session's own call" \
  || bad "cross-session stale occurrence blocked binding: tooled=$(tooled_rows) $(cat "$WORK/n.err")"

# -- same-session: an earlier, still-open (genuinely live) requested call
# keeps deferring a later call in that SAME session — unchanged. No
# resolution has proven the earlier one dead, so it must still win.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-32 sess-32; seen call-33 sess-32       # call-32 earliest/still open
keyhint_panel > "$WORKER_SCREEN"
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=3 run_notify ',"call_id":"call-33","native_session":"sess-32"'
elapsed=$(( $(date +%s) - start ))
[ "$(tooled_rows)" = 0 ] && [ "$elapsed" -ge 2 ] \
  && ok "same-session earlier live requested call still defers the later call (${elapsed}s), unchanged" \
  || bad "same-session live defer: tooled=$(tooled_rows) elapsed=${elapsed}s"
# Positive control: once call-32 (the blocker) resolves, call-33 — the
# SAME call this harness just reported blocked — binds. Proves the zero
# above is a real defer, not a harness that always writes nothing.
python3 "$here/lib/prompt-occurrence.py" completed --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-32 --call-id call-32 >/dev/null 2>&1
keyhint_panel > "$WORKER_SCREEN"
run_notify ',"call_id":"call-33","native_session":"sess-32"'
[ "$(tooled_rows)" -ge 1 ] \
  && ok "positive control: once the blocker resolves, the same deferred call-33 binds" \
  || bad "positive control failed: call-33 never bound after call-32 resolved, tooled=$(tooled_rows)"

# -- same-session: a never-resolved occurrence is DEAD once a LATER
# occurrence in the same (pane,birth,session) has resolved — omp paints
# panels oldest-first, so a later one could not have been reached, let
# alone resolved, while the earlier one was still genuinely pending.
# Ordering proves it dead; it must not block a still-later call forever.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-34 sess-34                             # stale: seen, never resolved
seen call-35 sess-34
python3 "$here/lib/prompt-occurrence.py" withdrawn --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-34 --call-id call-35 >/dev/null 2>&1
seen call-36 sess-34
keyhint_panel > "$WORKER_SCREEN"
run_notify ',"call_id":"call-36","native_session":"sess-34"'
[ "$(tooled_rows)" -ge 1 ] \
  && ok "same-session dead occurrence (a later one already withdrawn) does not block" \
  || bad "same-session dead occurrence blocked binding: tooled=$(tooled_rows) $(cat "$WORK/n.err")"

# -- herdr-control #308: a BOUND occurrence whose panel paints AFTER the
# short fast-poll budget is exhausted still gets found, via the longer
# `_queue_budget` ceiling introduced for this fix -- not the single shared
# budget the retry loop (agent-hooks/omp-notify.sh ~388-405) used to run
# on. Before the fix, a short `_budget` left the retry loop with no time
# left once the panel genuinely painted, and no_provenance fired with
# found=0 despite the occurrence being `bound` the entire time (the
# single-call live trace, task_20261017T032453Z_54010_30881, 2026-10-17:
# `seen` at 03:30:32, panel painted ~6s later, no_provenance at elapsed=10
# with last_binding=entry_binding=bound).
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-40 sess-40
: > "$WORKER_SCREEN"
( sleep 2; keyhint_panel > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN" ) &
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=1 HERDR_NOTIFY_QUEUE_DEADLINE_S=5 \
  run_notify ',"call_id":"call-40","native_session":"sess-40"'
elapsed=$(( $(date +%s) - start )); wait
[ "$(tooled_rows)" -ge 1 ] && [ "$elapsed" -ge 1 ] \
  && ok "bound occurrence painting after the short fast budget still binds via the longer queue budget (#308, ${elapsed}s)" \
  || bad "late-paint bound occurrence missed: tooled=$(tooled_rows) elapsed=${elapsed}s $(cat "$WORK/n.err")"

# -- herdr-control #308: a call genuinely QUEUED behind a still-open
# sibling (_occ_not_yet) whose sibling resolves AFTER the short fast
# budget, but before the longer queue budget, now binds within the SAME
# hook firing instead of giving up and leaving only the attention
# controller's tool-less row (the parallel live trace, two calls 40ms
# apart, task_20261017T032459Z_59522_10571, 2026-10-17: the second hook
# gave up at its 10s budget while the first prompt was still open,
# approved 4s later, and the second call's own panel never got read at
# all -- the exact failure #191 depends on never happening: herdr-select
# refuses an Approve whose prompt carries no hook-recorded tool).
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-41 sess-41; seen call-42 sess-41        # call-41 earliest/still open
keyhint_panel > "$WORKER_SCREEN"
( sleep 2
  python3 "$here/lib/prompt-occurrence.py" completed --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-41 --call-id call-41 >/dev/null 2>&1
  keyhint_panel > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN" ) &
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=1 HERDR_NOTIFY_QUEUE_DEADLINE_S=5 \
  run_notify ',"call_id":"call-42","native_session":"sess-41"'
elapsed=$(( $(date +%s) - start )); wait
[ "$(tooled_rows)" -ge 1 ] && [ "$elapsed" -ge 1 ] \
  && ok "a queued call whose sibling resolves after the short budget still binds within the same firing (#308, ${elapsed}s)" \
  || bad "queued-sibling-resolves-late missed: tooled=$(tooled_rows) elapsed=${elapsed}s $(cat "$WORK/n.err")"

# ---- fix/deferred-notify: deferred (exclusiveResolver) bound approvals must
# alert, bound to the exact request -------------------------------------------
# OMP's deferred resolver paints NO panel at all (.handoffs/SPEC.md Cause):
# the screen probe above found nothing for this mode forever, so these cases
# exercise the SEPARATE deferred branch directly rather than ever touching
# $WORKER_SCREEN.
printf '\n== deferred (exclusiveResolver) notify: alert fires with no painted panel ==\n'
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
: > "$WORKER_SCREEN"   # nothing ever painted for any case below

seed_deferred() {   # <call_id> <session> <approval_request_id> <core_digest>
  jq -nc '{input:{path:"x"}, core_arguments_json:({path:"x"}|tojson)}' \
    | python3 "$here/lib/prompt-occurrence.py" seen --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
      --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session "$2" --call-id "$1" \
      --tool write --source tool_approval_requested --input-json - \
      --approval-request-id "$3" --core-arguments-digest "$4" \
      --binding-protocol omp.tool-approval-binding.v1 --bound-envelope >/dev/null 2>&1
}
deferred_json() {   # <call_id> <session> <approval_request_id> <core_digest> -> run_notify extra-fields JSON
  printf ',"deferred":true,"call_id":"%s","native_session":"%s","approval_request_id":"%s","core_arguments_digest":"%s","binding_protocol":"omp.tool-approval-binding.v1"' \
    "$1" "$2" "$3" "$4"
}
input_required_row() {   # -> last input_required payload json
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT payload FROM events WHERE type='input_required' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null
}
ir_count() {
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT count(*) FROM events WHERE type='input_required';" 2>/dev/null || printf 0
}

# -- POSITIVE: valid deferred identity, no panel at all -> alert fires,
# bound to the occurrence's own exact request id/digest.
seed_deferred call-d1 sess-d1 req-d1 digest-d1
run_notify "$(deferred_json call-d1 sess-d1 req-d1 digest-d1)"
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
msg="$(printf '%s' "$row" | jq -r '.message // ""')"
[ "$(ir_count)" = 1 ] && ok "deferred: an alert fires with no panel painted (the Cause bug: notify used to exit silently)" \
  || bad "deferred positive: input_required rows=$(ir_count)"
case "$pid" in
  deferred:*) ok "deferred: the bound prompt identity comes from the occurrence, never a screen scrape" ;;
  *) bad "deferred positive: prompt_id not occurrence-derived: $pid" ;;
esac
printf '%s' "$msg" | grep -q 'req-d1' \
  && ok "deferred: the alert names the exact approval_request_id a conductor can act on" \
  || bad "deferred positive message missing identity: $msg"
printf '%s' "$msg" | grep -q 'digest-d1' \
  && ok "deferred: the alert names the exact core_arguments_digest" \
  || bad "deferred positive message missing digest: $msg"

# -- NEGATIVE: mismatched request id (never what recordOccurrence durably
# wrote for this call) -> fails closed on binding, still alerts.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seed_deferred call-d2 sess-d2 req-d2-real digest-d2
run_notify "$(deferred_json call-d2 sess-d2 req-d2-WRONG digest-d2)"
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
msg="$(printf '%s' "$row" | jq -r '.message // ""')"
case "$pid" in
  deferred-unbound:*) ok "deferred: a mismatched request id still alerts, unbound (never silent)" ;;
  *) bad "deferred mismatched-request: rows=$(ir_count) pid=$pid" ;;
esac
printf '%s' "$msg" | grep -q 'req-d2-real' \
  && bad "deferred mismatched-request LEAKED the real request id into an unbound alert: $msg" \
  || ok "deferred: an unbound alert names no approval (fails closed, no false identity)"

# -- NEGATIVE: mismatched core_arguments_digest -> same fail-closed-but-alert.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seed_deferred call-d3 sess-d3 req-d3 digest-d3-real
run_notify "$(deferred_json call-d3 sess-d3 req-d3 digest-d3-WRONG)"
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
case "$pid" in
  deferred-unbound:*) ok "deferred: a mismatched core_arguments_digest still alerts, unbound" ;;
  *) bad "deferred mismatched-digest: rows=$(ir_count) pid=$pid" ;;
esac

# -- NEGATIVE: stale (already authorized/resolved) occurrence -> fails
# closed, still alerts -- the approval is no longer pending to name.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seed_deferred call-d4 sess-d4 req-d4 digest-d4
python3 "$here/lib/prompt-occurrence.py" authorized --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-d4 --call-id call-d4 \
  --decided-by test --choice Approve >/dev/null 2>&1
run_notify "$(deferred_json call-d4 sess-d4 req-d4 digest-d4)"
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
case "$pid" in
  deferred-unbound:*) ok "deferred: an already-authorized (stale) occurrence still alerts, unbound" ;;
  *) bad "deferred stale: rows=$(ir_count) pid=$pid" ;;
esac

# -- NEGATIVE: replayed/foreign request id -- a DIFFERENT call's identity
# claimed for this one -> never credited, fails closed.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seed_deferred call-d5a sess-d5 req-d5-orig digest-d5-orig
seed_deferred call-d5b sess-d5 req-d5-own digest-d5-own
run_notify "$(deferred_json call-d5b sess-d5 req-d5-orig digest-d5-orig)"
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
case "$pid" in
  deferred-unbound:*) ok "deferred: a replayed/foreign request id is never credited to a different call" ;;
  *) bad "deferred replay wrongly bound: $pid" ;;
esac

# -- NEGATIVE: missing approval_request_id/binding_protocol -> this script's
# own deferred=true demotion (never TS's fault) never fabricates an alert
# straight from the (missing) identity, AND the firing still falls back to
# the ORDINARY screen-based path rather than going silent outright: with
# nothing painted it stays quiet (same as an ordinary call), but with a
# real menu painted it alerts exactly like a non-deferred call would.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
run_notify ',"deferred":true,"call_id":"call-d6","native_session":"sess-d6"'
[ "$(ir_count)" = 0 ] \
  && ok "deferred: missing approval_request_id/binding_protocol never fabricates an alert" \
  || bad "deferred missing-identity unexpectedly alerted: $(ir_count) rows"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
omp_menu "ls -la" > "$WORKER_SCREEN"
seen call-d6b sess-d6b
run_notify ',"deferred":true,"call_id":"call-d6b","native_session":"sess-d6b"'
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
case "$pid" in
  deferred:*|deferred-unbound:*) bad "demoted deferred firing still prompt_id=$pid, not the ordinary screen path" ;;
  "") bad "demoted deferred firing with a real menu painted raised no alert at all" ;;
  *) ok "deferred: missing identity demotes to the ORDINARY screen-based path, not silence (alerts off the real panel)" ;;
esac
: > "$WORKER_SCREEN"

# -- NEGATIVE: two concurrently pending deferred occurrences -- each binds
# only its OWN exact identity; no "earliest" guess, no cross-binding.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seed_deferred call-d7a sess-d7 req-d7a digest-d7a
seed_deferred call-d7b sess-d7 req-d7b digest-d7b
run_notify "$(deferred_json call-d7b sess-d7 req-d7b digest-d7b)"
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
msg="$(printf '%s' "$row" | jq -r '.message // ""')"
case "$pid" in
  deferred:*) ok "deferred: concurrent occurrences -- call-d7b binds exactly its own identity" ;;
  *) bad "deferred concurrent: call-d7b did not bind: $pid" ;;
esac
printf '%s' "$msg" | grep -q 'req-d7a' \
  && bad "deferred concurrent: call-d7b's alert leaked call-d7a's request id (cross-binding)" \
  || ok "deferred: no cross-binding between two concurrently pending deferred requests"

# -- UNCHANGED: an ordinary (non-deferred) painted-menu approval still binds
# a real screen prompt_id, byte-for-byte today's path.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-d8 sess-d8
keyhint_panel > "$WORKER_SCREEN"
run_notify ',"call_id":"call-d8","native_session":"sess-d8"'
row="$(input_required_row)"; pid="$(printf '%s' "$row" | jq -r '.prompt_id // ""')"
case "$pid" in
  deferred*) bad "ordinary approval wrongly took the deferred path: $pid" ;;
  "") bad "ordinary approval: no prompt_id bound" ;;
  *) ok "ordinary (non-deferred) approval still binds a real screen prompt_id, unchanged" ;;
esac
: > "$WORKER_SCREEN"

# ---- integrated: the REAL hook → human-stale timer → notifier, two concurrent
# deferred requests in one turn (review r5 HIGH + its sibling-supersession and
# --choices-drop companions). Nothing painted; production Slack level.
printf '\n== deferred integrated: two concurrent requests, human-stale per exact id ==\n'
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
: > "$WORKER_SCREEN"
REC_NOTIFY="$WORK/rec-notify.sh"; REC_LOG="$WORK/rec-notify.log"; : > "$REC_LOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$REC_LOG" > "$REC_NOTIFY"
chmod +x "$REC_NOTIFY"
fire_deferred() {   # <call_id> <session> <req> <digest>
  printf '{"tool":"write","message":"omp needs your permission","cwd":"/tmp/repo"%s}' "$(deferred_json "$@")" \
    | ( export HERDR_PANE_ID="$WPANE" HERDR_RUN_ID="$RUN_ID" HERDR_TASK_ID="$TASK_ID" \
               HERDR_NOTIFY="$REC_NOTIFY" HERDR_CONDUCTOR_PANE_ID="" \
               HERDR_SLACK_LEVEL=errors HERDR_HUMAN_ALERT_S=4
        bash "$here/agent-hooks/omp-notify.sh" >/dev/null 2>&1 )
}
stale_posts() { grep -- '--class human-stale' "$REC_LOG" | grep -c -- "$1"; }
seed_deferred call-i1 sess-i sess-req-i1 digest-i1
seed_deferred call-i2 sess-i sess-req-i2 digest-i2
seed_deferred call-i3 sess-i sess-req-i3 digest-i3
fire_deferred call-i1 sess-i sess-req-i1 digest-i1
fire_deferred call-i2 sess-i sess-req-i2 digest-i2
fire_deferred call-i2 sess-i sess-req-i2 digest-i2   # duplicate hook firing, same request
fire_deferred call-i3 sess-i sess-req-i3 digest-i3
# Resolved before its timer: call-i3 is answered now, inside the 4s window.
python3 "$here/lib/prompt-occurrence.py" authorized --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-i --call-id call-i3 \
  --decided-by test --choice Approve >/dev/null 2>&1
sleep 7
[ "$(stale_posts sess-req-i1)" = 1 ] \
  && ok "integrated: request 1 gets its own human-stale post although request 2 fired after it" \
  || bad "integrated: request 1 human-stale posts=$(stale_posts sess-req-i1): $(cat "$REC_LOG")"
[ "$(stale_posts sess-req-i2)" = 1 ] \
  && ok "integrated: request 2 gets exactly one human-stale post despite a duplicate hook firing" \
  || bad "integrated: request 2 human-stale posts=$(stale_posts sess-req-i2)"
[ "$(stale_posts sess-req-i3)" = 0 ] \
  && ok "integrated: a request resolved before its timer stands down (no post)" \
  || bad "integrated: resolved request 3 still posted $(stale_posts sess-req-i3)"
grep -- '--class human-stale' "$REC_LOG" | grep -q -- '--choices' \
  && bad "integrated: a deferred human-stale post used --choices (droppable)" \
  || ok "integrated: deferred human-stale posts never use --choices"
grep -- '--class human-stale' "$REC_LOG" | grep -q -- 'herdr-select.sh' \
  && ok "integrated: the human-stale post carries the exact-id answer command" \
  || bad "integrated: human-stale post lacks the answer hint: $(cat "$REC_LOG")"
# The generated answer hint must use only flags its two commands accept
# (v13 canary: --approval-arguments-digest etc. were refused as unknown).
# Parsed against each command's own argument list; nothing is executed.
hs_post="$(grep -- '--class human-stale' "$REC_LOG" | grep -- 'sess-req-i1' | head -1)"
sel_part="${hs_post#*herdr-select.sh }"
prop_part="${hs_post#*prompt-occurrence.py proposal }"; prop_part="${prop_part%%  ·  then*}"
sel_known="$(grep -oE '^ +--[a-z-]+\)' "$here/herdr-select.sh" | tr -d ' )' | sort -u)"
prop_known="$(python3 "$here/lib/prompt-occurrence.py" proposal --help 2>/dev/null | grep -oE -- '--[a-z-]+' | sort -u)"
bad_flags=""
for f in $(printf '%s\n' "$sel_part" | grep -oE -- '--[a-z-]+' | sort -u); do
  printf '%s\n' "$sel_known" | grep -qx -- "$f" || bad_flags="$bad_flags herdr-select:$f"
done
for f in $(printf '%s\n' "$prop_part" | grep -oE -- '--[a-z-]+' | sort -u); do
  printf '%s\n' "$prop_known" | grep -qx -- "$f" || bad_flags="$bad_flags proposal:$f"
done
for req in --db --worktree; do printf '%s' "$prop_part" | grep -q -- "$req " || bad_flags="$bad_flags proposal-missing:$req"; done
printf '%s' "$sel_part" | grep -q -- '--expect-payload-sha ' || bad_flags="$bad_flags select-missing:--expect-payload-sha"
[ -n "$hs_post" ] && [ -z "$bad_flags" ] \
  && ok "integrated: the answer hint uses only flags herdr-select.sh and proposal accept" \
  || bad "integrated: answer hint flags not accepted:${bad_flags:- (no post)}"

# ---- herdr-control fix/binding-fixture: F1/F2/F3/F2b -- binding CONTROLS --
# proof3's trace (.handoffs/PLAN.md §2): A/B (two parallel calls) bound
# correctly; the break was C, whose panel OMP's key-hint overlay clipped to
# one row ending in "…", so the hook's command-text equality check never
# matched, no input_required row was written, and herdr-select refused with
# "hook recorded '<none>'". These fixtures pin: F1 the parallel case still
# binds (regression guard), F2 the clipped case fails CLOSED (0 rows, select
# refuses, 0 keys -- never a false approve), F3 two commands identical up to
# the clip cannot be told apart by a clipped panel either (the negative any
# future prefix-based fix must keep), and F2b the evidence for the pending
# (b) decision: HERDR_BOUND_BASH=1 resolves the SAME clipped command by
# exact identity, no screen read, no keypress.
printf '\n== binding fixtures: F1 parallel / F2 clipped fail-closed / F3 same-prefix negative / F2b bound-bash evidence ==\n'

# F1 needs no herdr-select.sh call (notify-hook binding only); it reuses the
# existing WPANE/RUN_ID/TASK_ID registration and `seen`/`keyhint_cmd_panel`/
# `pid_rows`/`screen_pid`/`outc` from above. F2/F3/F2b additionally drive the
# REAL herdr-select.sh, which needs its own registered task with a live
# conductor pane and a protected-source authorization chain
# (`task_authorization_check`) -- a plain `register_task` (as used above)
# has neither, so those three use a dedicated pane/run/task registered via
# `fixture_register_task` (tests/fixtures/task-authorization.sh), exactly
# the pattern verify-approval-payload.sh uses.
. "$here/lib/run-registry.sh"
. "$here/tests/fixtures/task-authorization.sh"
SELPANE="w7:p7"; SELBIRTH="term-bind-sel-1"; SELCOND="w9:p9"; SELCBIRTH="cond-bind-1"
export SELPANE SELBIRTH SELCOND SELCBIRTH
SEL_KEYS="$WORK/sel-keys.log"; : > "$SEL_KEYS"
export SEL_KEYS
SRUN="runS"; STASK="taskS"
mkdir -p "$WORK/wt-sel/.handoffs"
fixture_register_task "$SRUN" "$STASK" w1 c1 "$SELCOND" "$SELCBIRTH" "$SELPANE" "$SELBIRTH" \
  /repo "$WORK/wt-sel" "impl:binding-fixture" >/dev/null 2>&1 \
  || { echo "binding-fixture: SELPANE task registration failed"; fail=$((fail + 1)); }
set_task_state "$SRUN" "$STASK" blocked >/dev/null 2>&1

seen_sel() {                            # <call> <session> -- SELPANE's own seen
  python3 "$here/lib/prompt-occurrence.py" seen --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    --run "$SRUN" --task "$STASK" --pane "$SELPANE" --birth "$SELBIRTH" --session "$2" --call-id "$1" \
    --tool bash --source test >/dev/null 2>&1
}
screen_pid_sel() { ( . "$here/lib/pane-guard.sh"; . "$here/lib/prompt-parse.sh"; prompt_id "$SELPANE" ); }
run_notify_sel() {                      # <extra jq fields...> -- SELPANE's own firing
  local extra="$1"
  printf '{"tool":"bash","message":"omp needs your permission","cwd":"/tmp/repo"%s}' "$extra" \
    | ( export HERDR_PANE_ID="$SELPANE" HERDR_RUN_ID="$SRUN" HERDR_TASK_ID="$STASK" \
               HERDR_NOTIFY="$NOOP" HERDR_CONDUCTOR_PANE_ID=""
        bash "$here/agent-hooks/omp-notify.sh" >"$WORK/sn.out" 2>"$WORK/sn.err" )
}
reset_sel_keys()   { : > "$SEL_KEYS"; }
sel_keys_pressed() { wc -l < "$SEL_KEYS" | tr -d ' '; }
sel_sel() { ( HERDR_FIXTURE_CALLER_PANE="${HERDR_PANE_ID:-}" bash "$here/herdr-select.sh" "$SELPANE" "$@" \
  >"$WORK/sel-out.txt" 2>"$WORK/sel-err.txt" ); }
conductor_sel() {                       # <extra flags...> -- ordinary (non-bound) conductor Approve
  ( export HERDR_PANE_ID="$SELCOND"
    sel_sel 1 --authority conductor --review-category branch-work \
      --review-reason "Reviewed the complete recorded payload and its target." "$@" )
}
input_sha() {                           # <tool> <input-json> -> the sha a reviewer reads from `proposal --show`
  python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}
seed_deferred_bash() {   # <call_id> <session> <approval_request_id> <core_digest> <command>
  jq -nc --arg c "$5" '{input:{command:$c}, core_arguments_json:({command:$c}|tojson)}' \
    | python3 "$here/lib/prompt-occurrence.py" seen --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
      --run "$SRUN" --task "$STASK" --pane "$SELPANE" --birth "$SELBIRTH" --session "$2" --call-id "$1" \
      --tool bash --source tool_approval_requested --input-json - \
      --approval-request-id "$3" --core-arguments-digest "$4" \
      --binding-protocol omp.tool-approval-binding.v1 --bound-envelope >/dev/null 2>&1
}
conductor_bound_sel() {                 # <request> <digest> <call-id> <payload-sha> -- exact bound resolution
  ( export HERDR_PANE_ID="$SELCOND" HERDR_SELECT_ACTOR=bound-conductor
    sel_sel 1 --authority conductor --review-category branch-work \
      --review-reason "Reviewed the complete recorded payload and its target." \
      --approval-request-id "$1" --expect-arguments-digest "$2" \
      --expect-tool-call-id "$3" --expect-payload-sha "$4" )
}

# -- F1: parallel order still binds correctly (regression guard; proof3 A/B) -
printf '\n-- F1: parallel order (proof3 A/B) --\n'
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-f1a sess-f1p; seen call-f1b sess-f1p
keyhint_cmd_panel "pwd" > "$WORKER_SCREEN"; F1A_PID="$(screen_pid)"
run_notify ',"call_id":"call-f1a","native_session":"sess-f1p","command":"pwd"'
[ "$(pid_rows "$F1A_PID")" = 1 ] && [ "$(outc | tail -1)" = push_attempted_tool_row_present ] \
  && ok "F1: A's firing writes input_required{tool:bash,command:pwd} under A's own screen prompt id" \
  || bad "F1 A bind: pid_rows=$(pid_rows "$F1A_PID") outcome=$(outc | tail -1)"
start=$(date +%s)
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=3 \
  run_notify ',"call_id":"call-f1b","native_session":"sess-f1p","command":"git status --short --branch"'
elapsed=$(( $(date +%s) - start ))
f1_defer_binding="$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT json_extract(payload,'\$.entry_binding') FROM events WHERE type='notify_probe_outcome' ORDER BY sequence DESC LIMIT 1;")"
[ "$(pid_rows "$F1A_PID")" = 1 ] && [ "$elapsed" -ge 2 ] \
  && ok "F1: B, seen second while A's panel is still up, waits (_occ_not_yet) instead of superseding A (${elapsed}s)" \
  || bad "F1 B defer: pid_rows(A)=$(pid_rows "$F1A_PID") elapsed=${elapsed}s"
[ "$f1_defer_binding" = earliest ] \
  && ok "F1: B's own deferring probe records entry_binding=earliest while queued behind A" \
  || bad "F1 B defer entry_binding: $f1_defer_binding"
python3 "$here/lib/prompt-occurrence.py" authorized --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-f1p --call-id call-f1a \
  --decided-by test --choice Approve >/dev/null 2>&1
python3 "$here/lib/prompt-occurrence.py" completed --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-f1p --call-id call-f1a >/dev/null 2>&1
keyhint_cmd_panel "git status --short --branch" > "$WORKER_SCREEN"; F1B_PID="$(screen_pid)"
run_notify ',"call_id":"call-f1b","native_session":"sess-f1p","command":"git status --short --branch"'
[ "$(pid_rows "$F1B_PID")" = 1 ] \
  && ok "F1: once A resolves, B binds its OWN command under B's own screen prompt id" \
  || bad "F1 B bind: pid_rows(B)=$(pid_rows "$F1B_PID")"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-f1bp sess-f1q; seen call-f1ap sess-f1q    # order swapped: B' seen first this time
keyhint_cmd_panel "git status --short --branch" > "$WORKER_SCREEN"; F1BP_PID="$(screen_pid)"
run_notify ',"call_id":"call-f1bp","native_session":"sess-f1q","command":"git status --short --branch"'
python3 "$here/lib/prompt-occurrence.py" authorized --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-f1q --call-id call-f1bp \
  --decided-by test --choice Approve >/dev/null 2>&1
python3 "$here/lib/prompt-occurrence.py" completed --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  --run "$RUN_ID" --task "$TASK_ID" --pane "$WPANE" --birth "" --session sess-f1q --call-id call-f1bp >/dev/null 2>&1
keyhint_cmd_panel "pwd" > "$WORKER_SCREEN"; F1AP_PID="$(screen_pid)"
run_notify ',"call_id":"call-f1ap","native_session":"sess-f1q","command":"pwd"'
[ "$(pid_rows "$F1BP_PID")" = 1 ] && [ "$(pid_rows "$F1AP_PID")" = 1 ] && [ "$F1BP_PID" != "$F1AP_PID" ] \
  && ok "F1: order swapped (B seen first) -- each call still binds only under its OWN screen prompt id" \
  || bad "F1 swapped: pid_rows(B')=$(pid_rows "$F1BP_PID") pid_rows(A')=$(pid_rows "$F1AP_PID")"

# -- F2: clipped panel fails CLOSED (proof3 C; live sample occ_0f3d6752) ----
printf '\n-- F2: clipped panel fails closed (proof3 C) --\n'
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
PROOF3_CMD="printf '{\"event\":\"x_done\",\"status\":\"completed\",\"reason\":\"no-follow-on\"}\n' >> /Users/thurbs/.herdr/worktrees/tourguide/review/offline-mcp-proof3/.handoffs/events.jsonl"
CLIPPED_F2="$(printf '%s' "$PROOF3_CMD" | cut -c1-124)…"
seen_sel call-f2 sess-f2
keyhint_cmd_panel "$CLIPPED_F2" > "$WORKER_SCREEN"; F2_PID="$(screen_pid_sel)"
( sleep 1.5; python3 "$here/lib/prompt-occurrence.py" declined --db "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    --run "$SRUN" --task "$STASK" --pane "$SELPANE" --birth "$SELBIRTH" --session sess-f2 --call-id call-f2 >/dev/null 2>&1 ) &
F2_CMD_JSON="$(jq -nc --arg c "$PROOF3_CMD" '$c')"
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=1 HERDR_NOTIFY_QUEUE_DEADLINE_S=5 \
  run_notify_sel ",\"call_id\":\"call-f2\",\"native_session\":\"sess-f2\",\"command\":$F2_CMD_JSON"
wait
[ "$(pid_rows "$F2_PID")" = 0 ] \
  && ok "F2: a clipped panel gets 0 input_required rows for the screen prompt id" \
  || bad "F2 clip rows: pid_rows=$(pid_rows "$F2_PID")"
f2_trace="$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT payload FROM events WHERE type='notify_probe_outcome' ORDER BY sequence DESC LIMIT 1;")"
[ "$(printf '%s' "$f2_trace" | jq -r '.outcome+"|"+.entry_binding+"|"+.tool_call_id')" = "no_provenance|bound|call-f2" ] \
  && ok "F2: outcome is no_provenance with entry_binding=bound once the occurrence is recorded declined" \
  || bad "F2 outcome trace: $f2_trace"
reset_sel_keys; conductor_sel --expect-prompt-id "$F2_PID"; rc=$?
[ "$rc" -eq 8 ] && [ "$(sel_keys_pressed)" = 0 ] \
  && ok "F2: herdr-select.sh <pane> 1 --authority conductor exits 8 and presses 0 keys" \
  || bad "F2 select refusal: rc=$rc keys=$(sel_keys_pressed); $(cat "$WORK/sel-err.txt")"
grep -qF "hook recorded '<none>'" "$WORK/sel-err.txt" \
  && ok "F2: the refusal names the exact cause -- no hook-recorded tool for this prompt" \
  || bad "F2 refusal reason: $(cat "$WORK/sel-err.txt")"

# -- F3: same-prefix siblings -- a clipped panel cannot disambiguate them ---
printf '\n-- F3: same-prefix siblings (negative) --\n'
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
F3_COMMON="$(python3 -c "print('git -C /Users/thurbs/.herdr/worktrees/herdr-control/fix/pad'.ljust(124,'p'))")"
F3_LOG="${F3_COMMON} log --oneline -E --grep='#(252|253|264)\b'"
F3_PUSH="${F3_COMMON} push origin fix/pad"
[ "$(printf '%s' "$F3_LOG" | cut -c1-124)" = "$(printf '%s' "$F3_PUSH" | cut -c1-124)" ] \
  && ok "F3 setup: the two fixture commands genuinely share the first 124 chars" \
  || bad "F3 setup: fixture commands do not share a 124-char prefix"
CLIPPED_F3="$(printf '%s' "$F3_LOG" | cut -c1-124)…"
seen_sel call-f3log sess-f3log
seen_sel call-f3push sess-f3push
keyhint_cmd_panel "$CLIPPED_F3" > "$WORKER_SCREEN"; F3_PID="$(screen_pid_sel)"
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=1 HERDR_NOTIFY_QUEUE_DEADLINE_S=2 \
  run_notify_sel ",\"call_id\":\"call-f3log\",\"native_session\":\"sess-f3log\",\"command\":$(jq -nc --arg c "$F3_LOG" '$c')"
HERDR_NOTIFY_UNREADABLE_DEADLINE_S=1 HERDR_NOTIFY_QUEUE_DEADLINE_S=2 \
  run_notify_sel ",\"call_id\":\"call-f3push\",\"native_session\":\"sess-f3push\",\"command\":$(jq -nc --arg c "$F3_PUSH" '$c')"
[ "$(pid_rows "$F3_PID")" = 0 ] \
  && ok "F3: neither sibling's command is ever written under the shared, ambiguous clipped screen pid" \
  || bad "F3: pid_rows=$(pid_rows "$F3_PID")"
reset_sel_keys; conductor_sel --expect-prompt-id "$F3_PID"; rc=$?
[ "$rc" -eq 8 ] && [ "$(sel_keys_pressed)" = 0 ] \
  && ok "F3: a conductor Approve on the ambiguous clipped panel presses 0 keys and refuses" \
  || bad "F3 select refusal: rc=$rc keys=$(sel_keys_pressed); $(cat "$WORK/sel-err.txt")"

# -- F2b: evidence for decision (b) -- bound bash, flag on ------------------
printf '\n-- F2b: HERDR_BOUND_BASH=1 resolves F2'"'"'s exact request, no screen, no key --\n'
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
: > "$WORKER_SCREEN"   # deferred path paints nothing
export HERDR_BOUND_BASH=1
F2B_JSON="$(jq -nc --arg c "$PROOF3_CMD" '{command:$c}' | jq -cS .)"
F2B_DIGEST="sha256:$(printf '%s' "$F2B_JSON" | shasum -a 256 | awk '{print $1}')"
F2B_SHA="$(input_sha bash "$F2B_JSON")"
seed_deferred_bash call-f2b sess-f2b req-f2b "$F2B_DIGEST" "$PROOF3_CMD"
run_notify_sel "$(deferred_json call-f2b sess-f2b req-f2b "$F2B_DIGEST"),\"command\":$(jq -nc --arg c "$PROOF3_CMD" '$c')"
f2b_row="$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT payload FROM events WHERE type='input_required' ORDER BY sequence DESC LIMIT 1;")"
[ "$(printf '%s' "$f2b_row" | jq -r '.tool')" = bash ] && [ "$(printf '%s' "$f2b_row" | jq -r '.command')" = "$PROOF3_CMD" ] \
  && ok "F2b: the deferred alert for the bound bash request carries tool=bash and the FULL (uncut) command" \
  || bad "F2b input_required: $f2b_row"
reset_sel_keys
conductor_bound_sel req-f2b "$F2B_DIGEST" call-f2b "$F2B_SHA"; rc=$?
authorized_f2b="$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT count(*) FROM events WHERE type='prompt_occ_authorized';" 2>/dev/null)"
[ "$rc" -eq 0 ] && [ "$(sel_keys_pressed)" = 0 ] && [ "${authorized_f2b:-0}" -ge 1 ] \
  && ok "F2b: with HERDR_BOUND_BASH=1, the exact request resolves -- 0 keys, no screen read" \
  || bad "F2b bound resolve: rc=$rc keys=$(sel_keys_pressed) authorized=$authorized_f2b; $(cat "$WORK/sel-err.txt")"
unset HERDR_BOUND_BASH
reset_sel_keys
conductor_bound_sel req-f2b "$F2B_DIGEST" call-f2b "$F2B_SHA"; rc=$?
[ "$rc" -eq 8 ] && [ "$(sel_keys_pressed)" = 0 ] \
  && ok "F2b: flag unset again -- bound bash resolution is refused once more (limited to write/edit); F2's refusal stands" \
  || bad "F2b flag-off regression: rc=$rc keys=$(sel_keys_pressed)"


printf -- '-----\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
