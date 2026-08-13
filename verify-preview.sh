#!/usr/bin/env bash
# verify-preview.sh — proof of the 2026-08-10 preview.sh startup-race bug
# (docs/2026-08-10-herdr-browser-render-bug.md) and its fix.
#
# `preview.sh url` opened a pane, then ran the browser plugin CLI's `open`
# with NO view id — a real ambiguity once more than one view exists (the
# CLI-created unbound view from the race, plus the real pane-backed view the
# viewer registers ~60ms later). preview.sh discarded that ambiguity error,
# then accepted the pane-backed view's URL as "success" even when it was
# still about:blank, because its only check was "nonempty", not "matches
# what we asked for".
#
# This drives the REAL preview.sh against stub `herdr`/`bun` EXECUTABLES on
# PATH (not exported bash functions — those do not reliably cross into a
# `bash preview.sh` subprocess in every shell environment, which silently
# turned an earlier draft of this file into a false-positive suite: both the
# bug-reproduction and the regression scenario were failing for the SAME
# wrong reason, "herdr plugin not installed", not the reason each assertion
# claimed). Real PATH-resolved executables have no such gap.
#
# The doc's proposed-patch section requires a regression suite that proves,
# as DISTINCT cases:
#   1. pane open may return before the matching view appears (the wait/poll
#      loop actually waits, it is not a no-op single check);
#   2. navigation is issued with the matching view_id, never an implicit
#      view, for every CLI call (open AND text);
#   3. a nonzero CLI navigation result makes preview.sh fail;
#   4. a landed URL different from the CLI's own final URL makes it fail
#      (the exact about:blank false-success case); and
#   5. a redirect whose final CLI URL matches the pane view succeeds (no
#      false-positive failure on a legitimate redirect).
# Cases 1, 2 and 4 are provable regressions: they FAIL against the pre-fix
# preview.sh (verified by running this same suite against
# `git show <pre-fix-sha>:preview.sh` — see the doc and commit history).
#
#   bash verify-preview.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PANE_ID="w1:pB"
STATE="$WORK/state.json"           # the fake daemon's view table
mkdir -p "$WORK/bin" "$WORK/plugin-root/src"

# ---- herdr stub (real executable on PATH) ---------------------------------
cat >"$WORK/bin/herdr" <<'HERDR_EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w1","focused":true}]}}\n'
    ;;
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"%s","label":"Browser","workspace_id":"w1"}]}}\n' "$PANE_ID"
    ;;
  "plugin list")
    printf '{"result":{"plugins":[{"plugin_root":"%s"}]}}\n' "$PLUGIN_ROOT"
    ;;
  "plugin pane") exit 0 ;;
  "plugin action") exit 0 ;;
  *) exit 0 ;;
esac
HERDR_EOF
chmod +x "$WORK/bin/herdr"

# ---- bun stub (real executable on PATH; stands in for the plugin CLI) -----
# Reads/writes $STATE, a tiny JSON view table, so a scenario can express
# exactly what the plugin daemon's views look like at each step. Honors
# HERDR_BROWSER_VIEW_ID the same way the real daemon does: an unaddressed
# `open`/`text` with more than one view open is refused; an addressed call
# acts on that view only.
#
# Extra knobs the acceptance-contract scenarios below toggle via env:
#   VIEWS_CALL_COUNT_FILE  - if set, every `views` call increments a counter
#                            here (proves the wait loop actually polls).
#   BUN_VIEWS_DELAY_UNTIL  - if set, `views` hides the view whose pane_id is
#                            BUN_VIEWS_DELAY_PANE_ID from its OWN output
#                            until the call counter reaches this value —
#                            simulating a pane-backed view that has not
#                            heartbeated into the daemon yet. The real
#                            $STATE file is untouched; only what `views`
#                            reports is delayed.
#   BUN_OPEN_FORCE_FAIL    - if "1", `open` fails immediately (exit 1),
#                            never touching $STATE. Simulates a real CLI
#                            navigation error.
#   BUN_OPEN_REPORT_URL    - if set, `open`'s JSON response reports this as
#                            the final ("url") field instead of the literal
#                            requested arg — the CLI's own post-redirect URL.
#   BUN_OPEN_LANDED_URL    - if set, this is what actually gets written into
#                            the target view's url in $STATE, independent of
#                            what is reported — lets a scenario make the
#                            CLI's claim and the pane's real state diverge.
cat >"$WORK/bin/bun" <<'BUN_EOF'
#!/usr/bin/env bash
[ "$1" = "run" ] && [ "$2" = "src/cli.ts" ] || exit 0
shift 2
cmd="$1"; shift || true
n_views=$(python3 -c '
import json,sys
try: print(len(json.load(open(sys.argv[1])).get("views") or []))
except Exception: print(0)
' "$STATE" 2>/dev/null)
case "$cmd" in
  views)
    count=0
    if [ -n "${VIEWS_CALL_COUNT_FILE:-}" ]; then
      count=$(( $(cat "$VIEWS_CALL_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$count" >"$VIEWS_CALL_COUNT_FILE"
    fi
    if [ -n "${BUN_VIEWS_DELAY_UNTIL:-}" ] && [ "$count" -lt "$BUN_VIEWS_DELAY_UNTIL" ]; then
      python3 -c '
import json, os, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    d = {"views": []}
hide = os.environ.get("BUN_VIEWS_DELAY_PANE_ID", "")
d["views"] = [v for v in (d.get("views") or []) if v.get("pane_id") != hide]
json.dump(d, sys.stdout)
' "$STATE"
    else
      cat "$STATE" 2>/dev/null || printf '{"views":[]}\n'
    fi
    ;;
  open)
    url="$1"
    printf 'url=%s view_id=%s\n' "$url" "${HERDR_BROWSER_VIEW_ID:-<none>}" >>"$OPEN_CALLS"
    if [ -z "${HERDR_BROWSER_VIEW_ID:-}" ] && [ "${n_views:-0}" -gt 1 ]; then
      echo "multiple browser views are open; set HERDR_BROWSER_VIEW_ID" >&2
      exit 1
    fi
    if [ "${BUN_OPEN_FORCE_FAIL:-0}" = "1" ]; then
      echo "navigation failed (forced by test)" >&2
      exit 1
    fi
    report_url="${BUN_OPEN_REPORT_URL:-$url}"
    landed_url="${BUN_OPEN_LANDED_URL:-$report_url}"
    python3 -c '
import json, sys, os
state_path, view_id, landed_url, report_url = sys.argv[1], os.environ.get("HERDR_BROWSER_VIEW_ID",""), sys.argv[2], sys.argv[3]
try:
    d = json.load(open(state_path))
except Exception:
    d = {"views": []}
views = d.get("views") or []
target = None
if view_id:
    target = next((v for v in views if v.get("view_id") == view_id), None)
elif len(views) == 1:
    target = views[0]
if target is None:
    print(json.dumps({"ok": False, "error": "no matching view"}))
    sys.exit(1)
target["url"] = landed_url
json.dump(d, open(state_path, "w"))
print(json.dumps({"ok": True, "url": report_url}))
' "$STATE" "$landed_url" "$report_url"
    ;;
  text)
    printf 'view_id=%s\n' "${HERDR_BROWSER_VIEW_ID:-<none>}" >>"$OPEN_CALLS.text"
    if [ -z "${HERDR_BROWSER_VIEW_ID:-}" ] && [ "${n_views:-0}" -gt 1 ]; then
      echo "multiple browser views are open; set HERDR_BROWSER_VIEW_ID" >&2
      exit 1
    fi
    printf '{"text":"some page body"}\n'
    ;;
  *) exit 0 ;;
esac
BUN_EOF
chmod +x "$WORK/bin/bun"

export PANE_ID STATE PLUGIN_ROOT="$WORK/plugin-root" OPEN_CALLS="$WORK/open-calls.log"
export PATH="$WORK/bin:$PATH"
# config.sh (sourced by preview.sh) unconditionally does
# `export PATH="$HERDR_EXTRA_PATH:/usr/bin:/bin:$PATH"` -- that PREPEND
# outranks anything we put in $PATH ourselves, silently routing every
# herdr/bun call at the real system binaries instead of these stubs (the
# exact false-positive/false-failure gap an earlier draft of this suite hit
# on every scenario touching do_url). Override the variable config.sh reads
# instead of fighting its later PATH rewrite.
export HERDR_EXTRA_PATH="$WORK/bin"
# Isolate browser_daemon_state_file from the REAL herdr state on this
# machine (browser_state_dir derives from $XDG_STATE_HOME/$HOME, not from
# the mocked plugin_root) -- otherwise this suite reads/depends on whatever
# real daemon happens to be running right now. Seed a "live" daemon.json
# pointing at this test's own PID (definitely alive for the suite's
# duration) so do_open takes the ordinary focus path, not the
# dead-daemon reopen path.
export XDG_STATE_HOME="$WORK/state-home"
mkdir -p "$XDG_STATE_HOME/herdr/plugins/official.browser"
printf '{"pid":%d}' "$$" >"$XDG_STATE_HOME/herdr/plugins/official.browser/daemon.json"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

seed_views() { printf '%s' "$1" >"$STATE"; }
run_preview() { ( cd "$here" && bash preview.sh url "$1" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }

printf '== sanity: the stubs are actually resolved on PATH inside a preview.sh subprocess ==\n'
( cd "$here" && bash -c 'herdr workspace list' ) >"$WORK/sanity.txt" 2>&1
grep -q '"focused":true' "$WORK/sanity.txt" && ok "herdr stub resolves inside a subprocess" \
  || bad "stub not resolved — cannot trust anything below: $(cat "$WORK/sanity.txt")"

printf '== a stray unbound ghost view (the races aftermath) must not fool navigation — the REAL pane view lands the URL, honestly ==\n'
: >"$OPEN_CALLS"
seed_views '{"views":[
  {"view_id":"ghost-unbound","pane_id":null,"url":"http://decoy.example/"},
  {"view_id":"real-pane-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}
]}'
run_preview "http://target.example/"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 despite the stray ghost view" \
  || bad "exit $rc: $(cat "$WORK/err.txt")"
python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
real = next(v for v in d["views"] if v["view_id"] == "real-pane-view")
ghost = next(v for v in d["views"] if v["view_id"] == "ghost-unbound")
sys.exit(0 if real["url"] == "http://target.example/" and ghost["url"] == "http://decoy.example/" else 1)
' "$STATE" && ok "navigated the REAL pane view, and never touched the ghost" \
  || bad "wrong view navigated: $(cat "$STATE")"

printf '== targeting the real pane view directly (bypassing the race) reaches it, not the ghost ==\n'
: >"$OPEN_CALLS"
seed_views '{"views":[
  {"view_id":"ghost-unbound","pane_id":null,"url":"about:blank"},
  {"view_id":"real-pane-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}
]}'
( cd "$here" && HERDR_BROWSER_VIEW_ID=real-pane-view bun run src/cli.ts open "http://target.example/" \
    >"$WORK/direct-out.txt" 2>"$WORK/direct-err.txt" )
grep -q '"ok": true' "$WORK/direct-out.txt" && ok "targeted open against the real view succeeds" \
  || bad "targeted open failed: $(cat "$WORK/direct-err.txt")"
python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
v = next(v for v in d["views"] if v["view_id"] == "real-pane-view")
sys.exit(0 if v["url"] == "http://target.example/" else 1)
' "$STATE" && ok "the pane-backed view's url updated" || bad "pane-backed view url did not update"

printf '== single-view case (no race) still works exactly as before ==\n'
: >"$OPEN_CALLS"
seed_views '{"views":[{"view_id":"only-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}]}'
run_preview "http://target.example/single"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "exit 0, single unambiguous view navigates fine"
else
  grep -q "browser plugin not installed" "$WORK/err.txt" \
    && bad "exit $rc for the WRONG reason (stub not reached): $(cat "$WORK/err.txt")" \
    || bad "exit $rc (regression on the common case): $(cat "$WORK/err.txt")"
fi
grep -q "http://target.example/single" "$STATE" && ok "url landed on the pane's view" || bad "url did not land"

# ---- acceptance-contract cases (docs/2026-08-10-herdr-browser-render-bug.md) ----
# Each of the 5 points the doc requires before applying its patch, as its
# own distinct scenario/assertion — not folded into the scenarios above.

printf '== case 1: the pane-backed view registers asynchronously — the wait must actually POLL, not check once ==\n'
: >"$OPEN_CALLS"
: >"$WORK/views-call-count"
export VIEWS_CALL_COUNT_FILE="$WORK/views-call-count"
export BUN_VIEWS_DELAY_UNTIL=5
export BUN_VIEWS_DELAY_PANE_ID="$PANE_ID"
seed_views '{"views":[{"view_id":"late-pane-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}]}'
start_ts=$(python3 -c 'import time; print(time.time())')
run_preview "http://target.example/late"; rc=$?
elapsed=$(python3 -c 'import time,sys; print(time.time()-float(sys.argv[1]))' "$start_ts")
calls=$(cat "$WORK/views-call-count" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "exit 0 once the delayed view registered" \
  || bad "exit $rc waiting for a view that does register shortly after — the wait is not working: $(cat "$WORK/err.txt")"
[ "${calls:-0}" -ge 5 ] && ok "views was polled $calls times before the view appeared, not just checked once" \
  || bad "views was called only ${calls:-0} time(s) before giving up — the wait loop is a no-op, not a poll"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 0.15 else 1)' "$elapsed" \
  && ok "the wait spent real time polling (~${elapsed}s) instead of racing straight through" \
  || bad "returned almost instantly (${elapsed}s) for a view that was not there yet — suspicious for a poll loop"
unset VIEWS_CALL_COUNT_FILE BUN_VIEWS_DELAY_UNTIL BUN_VIEWS_DELAY_PANE_ID

printf '== case 2: navigation must target the matching view_id explicitly, for open AND text, never implicit ==\n'
: >"$OPEN_CALLS"; : >"$OPEN_CALLS.text"
seed_views '{"views":[
  {"view_id":"ghost-unbound","pane_id":null,"url":"http://decoy.example/"},
  {"view_id":"real-pane-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}
]}'
run_preview "http://target.example/explicit-view"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 with the correct view explicitly targeted" \
  || bad "exit $rc: $(cat "$WORK/err.txt")"
grep -qx "url=http://target.example/explicit-view view_id=real-pane-view" "$OPEN_CALLS" \
  && ok "open was called with --view-id=real-pane-view, not an implicit view" \
  || bad "open was not addressed to the real pane view: $(cat "$OPEN_CALLS" 2>/dev/null)"
grep -qx "view_id=real-pane-view" "$OPEN_CALLS.text" \
  && ok "text was also called with --view-id=real-pane-view, not an implicit view" \
  || bad "text was not addressed to the real pane view: $(cat "$OPEN_CALLS.text" 2>/dev/null)"

printf '== case 3: a nonzero CLI navigation result must make preview.sh fail ==\n'
: >"$OPEN_CALLS"
export BUN_OPEN_FORCE_FAIL=1
seed_views '{"views":[{"view_id":"only-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}]}'
run_preview "http://target.example/cli-error"; rc=$?
[ "$rc" -ne 0 ] && ok "exit $rc when the CLI navigation itself fails" \
  || bad "exit 0 despite the CLI navigation call failing — the error was swallowed"
unset BUN_OPEN_FORCE_FAIL

printf '== case 4: a landed URL different from the CLI final URL must fail (the exact about:blank false-success case) ==\n'
: >"$OPEN_CALLS"
export BUN_OPEN_LANDED_URL="about:blank"
seed_views '{"views":[{"view_id":"only-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}]}'
run_preview "http://target.example/never-lands"; rc=$?
[ "$rc" -ne 0 ] && ok "exit $rc when the CLI reports success but the pane view stayed at about:blank" \
  || bad "exit 0 while the pane was still on about:blank — the exact silent-success bug"
grep -q "loaded http://target.example/never-lands" "$WORK/err.txt" \
  && bad "printed 'loaded' as if it succeeded, despite the mismatch: $(cat "$WORK/err.txt")" \
  || ok "did not claim success for a URL that never actually landed"
unset BUN_OPEN_LANDED_URL

printf '== case 5: a redirect whose final CLI URL matches the pane view must succeed, not false-fail ==\n'
: >"$OPEN_CALLS"
export BUN_OPEN_REPORT_URL="http://final.example/landed-after-redirect"
export BUN_OPEN_LANDED_URL="http://final.example/landed-after-redirect"
seed_views '{"views":[{"view_id":"only-view","pane_id":"'"$PANE_ID"'","url":"about:blank"}]}'
run_preview "http://target.example/redirect-start"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 for a legitimate redirect (requested one URL, landed on another)" \
  || bad "exit $rc on a legitimate redirect — false-positive failure: $(cat "$WORK/err.txt")"
grep -q "http://final.example/landed-after-redirect" "$STATE" \
  && ok "the pane view shows the CLI's own post-redirect URL" \
  || bad "pane view does not show the redirected URL: $(cat "$STATE")"
unset BUN_OPEN_REPORT_URL BUN_OPEN_LANDED_URL

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
