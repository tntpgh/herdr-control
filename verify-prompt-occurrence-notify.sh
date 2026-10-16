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

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_SLACK_LEVEL=all
WORKER_SCREEN="$WORK/worker.txt"
COND_SCREEN="$WORK/cond.txt"
: > "$COND_SCREEN"
FAIL_MARKER="$WORK/fail-read"
export WORKER_SCREEN COND_SCREEN FAIL_MARKER

WPANE="w1:p1"
export WPANE

# ---- the stub: one executable FILE, not a function ------------------------
STUBBIN="$WORK/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/herdr" <<'EOS'
#!/usr/bin/env bash
# Minimal stand-in for the real `herdr` CLI, covering only the subcommands
# lib/prompt-parse.sh issues: pane read (the only one this test's path
# calls). FAIL_MARKER present means "simulate a transport failure" (pane
# gone / herdr socket down) — prints nothing and exits nonzero, which is
# exactly how prompt_occurrence_display distinguishes read_failed from a
# successful-but-empty read.
if [ "$1 $2" = "pane read" ]; then
  if [ -n "${FAIL_MARKER:-}" ] && [ -f "$FAIL_MARKER" ]; then
    exit 7
  fi
  cat "${WORKER_SCREEN:?}"
  exit 0
fi
exit 0
EOS
chmod +x "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"
command -v herdr | grep -qx "$STUBBIN/herdr" \
  && ok "stub herdr resolves from PATH, not a shell function" \
  || bad "PATH stub not found first: $(command -v herdr)"

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

# -- superseded during the wait: a later tool call recorded its own seen ----
# The panel that becomes parseable is the REPLACEMENT's; this hook must not
# attach its tool/command to it, nor record a screen row for it.
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-8 sess-8
unreadable_menu > "$WORKER_SCREEN"
( sleep 1.8; seen call-9 sess-8; sleep 0.7; keyhint_panel > "$WORKER_SCREEN.tmp" && mv "$WORKER_SCREEN.tmp" "$WORKER_SCREEN" ) &
run_notify ',"call_id":"call-8","native_session":"sess-8"'
wait
[ "$(tooled_rows)" = 0 ] && [ "$(screen_rows)" = 0 ] \
  && ok "superseded occurrence writes neither input_required nor a screen row for the replacement prompt" \
  || bad "superseded: tooled=$(tooled_rows) screen=$(screen_rows)"

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

# -- races on the FAST path: parseable at once, but no longer ours ----------
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events;"
seen call-11 sess-11; seen call-12 sess-11      # replacement already recorded
keyhint_panel > "$WORKER_SCREEN"
run_notify ',"call_id":"call-11","native_session":"sess-11"'
[ "$(tooled_rows)" = 0 ] && [ "$(screen_rows)" = 0 ] \
  && ok "fast-path parse of a replacement prompt pushes nothing for the old occurrence" \
  || bad "fast-path replacement: tooled=$(tooled_rows) screen=$(screen_rows)"
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

printf -- '-----\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
