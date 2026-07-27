#!/usr/bin/env bash
# ============================================================================
#  preview.sh — show a page in the Herdr Browser pane, arbitrating screen space.
#
#  The problem this solves: the browser pane and the reviewr sidebar both want a
#  right split. On the wide external monitor there is room for both. On the
#  laptop screen alone there is not, and you end up with two useless slivers.
#
#  So: opening the browser on a narrow setup CLOSES the reviewr sidebar first.
#  On a wide setup both stay open. Nothing is closed that did not need to be.
#
#  Usage:
#    preview.sh open [url]     open the browser pane (closing reviewr if narrow)
#    preview.sh url <url>      navigate — opens the pane first if it is closed
#    preview.sh close          close the browser pane
#    preview.sh toggle [url]   close if open, else open
#    preview.sh status         print what is open and which display profile is active
#
#  Display profile:
#    "wide"   = an external display is attached  -> browser and reviewr coexist
#    "narrow" = built-in display only            -> browser evicts reviewr
#
#  Pin it to one specific monitor by name (substring, case-insensitive):
#    HERDR_PREVIEW_WIDE_DISPLAY="DELL"
#  Left unset, ANY attached external display counts as wide. That default is
#  deliberate: a name can only be matched when the monitor is plugged in, and
#  guessing a string we have never seen would fail closed to "narrow" every time
#  the real monitor IS attached — the exact wrong direction.
#
#  Force a profile (testing, or a setup we detect wrongly):
#    HERDR_PREVIEW_PROFILE=wide|narrow
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/config.sh" ] && . "$HERE/config.sh"

BROWSER_PLUGIN="official.browser"
BROWSER_PANE="browser"
REVIEWR_PLUGIN="persiyanov.reviewr"

die() { printf 'preview: %s\n' "$*" >&2; exit 1; }
note() { printf 'preview: %s\n' "$*" >&2; }

command -v herdr >/dev/null 2>&1 || die "herdr not on PATH"

# ── display profile ─────────────────────────────────────────────────────────
# Fail-open to "wide" on any detection error. A wrong "narrow" silently closes a
# sidebar you were using; a wrong "wide" just leaves the layout as you had it.
# The cheaper mistake is the one that touches nothing.
display_profile() {
  if [ -n "${HERDR_PREVIEW_PROFILE:-}" ]; then
    printf '%s' "$HERDR_PREVIEW_PROFILE"; return
  fi
  local want="${HERDR_PREVIEW_WIDE_DISPLAY:-}"
  case "$(uname -s)" in
    Darwin) ;;
    *) printf 'wide'; return ;;          # only macOS detection is implemented
  esac
  command -v system_profiler >/dev/null 2>&1 || { printf 'wide'; return; }

  system_profiler -json SPDisplaysDataType 2>/dev/null | python3 -c '
import json, sys, os
want = (os.environ.get("HERDR_PREVIEW_WIDE_DISPLAY") or "").strip().lower()
try:
    data = json.load(sys.stdin)
except Exception:
    print("wide"); sys.exit(0)          # unparseable -> touch nothing
for gpu in data.get("SPDisplaysDataType", []):
    for d in gpu.get("spdisplays_ndrvs", []) or []:
        if d.get("spdisplays_online") != "spdisplays_yes":
            continue
        name = (d.get("_name") or "")
        internal = d.get("spdisplays_connection_type") == "spdisplays_internal"
        if want:
            if want in name.lower():
                print("wide"); sys.exit(0)
        elif not internal:
            print("wide"); sys.exit(0)
print("narrow")
' 2>/dev/null || printf 'wide'
}

# ── pane state ──────────────────────────────────────────────────────────────
# A plugin pane counts as open only when it is in the SAME workspace we are
# acting on. `herdr pane list` spans every workspace, and screen space does not:
# a reviewr sidebar in the knowledge-base workspace is not competing with a
# browser pane in thurber-os, because the two are never on screen together.
# Scanning globally made this evict a sidebar the user could not even see.
current_workspace() {
  herdr workspace list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for w in (d.get("result") or {}).get("workspaces") or []:
    if w.get("focused"):
        print(w.get("workspace_id") or ""); sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

pane_is_open() {                        # $1 = pane label
  local ws; ws="$(current_workspace)" || return 1
  herdr pane list 2>/dev/null | python3 -c '
import json, sys
label, ws = sys.argv[1].lower(), sys.argv[2]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
panes = (d.get("result") or {}).get("panes") or []
sys.exit(0 if any((p.get("label") or "").lower() == label
                  and p.get("workspace_id") == ws for p in panes) else 1)
' "$1" "$ws" 2>/dev/null
}

browser_open() { pane_is_open "Browser"; }
reviewr_open() { pane_is_open "reviewr"; }

browser_root() {
  herdr plugin list --plugin "$BROWSER_PLUGIN" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d["result"]["plugins"][0])["plugin_root"])
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# ── actions ─────────────────────────────────────────────────────────────────
do_open() {
  local profile; profile="$(display_profile)"
  if [ "$profile" = "narrow" ] && reviewr_open; then
    note "narrow display — closing the reviewr sidebar to make room"
    herdr plugin action invoke close --plugin "$REVIEWR_PLUGIN" >/dev/null 2>&1 \
      || note "could not close reviewr (continuing)"
  fi
  if browser_open; then
    herdr plugin pane focus --plugin "$BROWSER_PLUGIN" --entrypoint "$BROWSER_PANE" >/dev/null 2>&1
  else
    herdr plugin pane open --plugin "$BROWSER_PLUGIN" --entrypoint "$BROWSER_PANE" \
      --placement split --direction right --focus >/dev/null 2>&1 \
      || die "could not open the browser pane"
  fi
}

# Is the pane's browser view registered with the daemon? `views` lists only views
# backed by a VISIBLE plugin pane, so a pane that herdr has never actually drawn
# (its workspace not on screen on any client) registers nothing.
#
# This matters because `cli.ts open` still succeeds in that state — it drives the
# daemon's own page instead, reports ok/navigated, and the pane keeps showing
# about:blank. A command that reports success while changing nothing on screen is
# worse than one that fails, so check first and say so.
view_count() {
  local root; root="$(browser_root)" || { printf '0'; return; }
  bun run "$root/src/cli.ts" views 2>/dev/null | python3 -c '
import json, sys
try:
    print(len((json.load(sys.stdin).get("views") or [])))
except Exception:
    print(0)
' 2>/dev/null || printf '0'
}

do_url() {
  local url="${1:-}"
  [ -n "$url" ] || die "url: needs a URL"
  do_open
  local root; root="$(browser_root)" || die "browser plugin not installed"
  command -v bun >/dev/null 2>&1 || die "bun not on PATH (the browser CLI needs it)"

  if [ "$(view_count)" = "0" ]; then
    note "WARNING: the browser pane has no registered view, so this navigation"
    note "         will NOT appear in the pane — it drives the daemon's own page."
    note "         herdr registers a view only for a pane it has actually drawn:"
    note "         bring the workspace on screen once, then re-run."
  fi
  bun run "$root/src/cli.ts" open "$url" 2>&1 | tail -6
}

do_close() {
  browser_open || { note "browser pane is not open"; return 0; }
  herdr plugin pane close --plugin "$BROWSER_PLUGIN" --entrypoint "$BROWSER_PANE" >/dev/null 2>&1 \
    || die "could not close the browser pane"
  note "browser pane closed"
}

case "${1:-}" in
  open)   shift; do_open; [ $# -gt 0 ] && do_url "$1"; ;;
  url)    shift; do_url "${1:-}" ;;
  close)  do_close ;;
  toggle) shift
          if browser_open; then do_close; else do_open; [ $# -gt 0 ] && do_url "$1"; fi ;;
  status)
          printf 'display profile : %s\n' "$(display_profile)"
          printf 'browser pane    : %s\n' "$(browser_open && echo open || echo closed)"
          printf 'reviewr sidebar : %s\n' "$(reviewr_open && echo open || echo closed)"
          printf 'wide-display pin: %s\n' "${HERDR_PREVIEW_WIDE_DISPLAY:-<any external>}"
          ;;
  ''|-h|--help|help)
          sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)      die "unknown command '${1}' (try: open, url, close, toggle, status)" ;;
esac
