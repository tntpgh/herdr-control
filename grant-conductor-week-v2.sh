#!/usr/bin/env bash
# grant-conductor-week-v2.sh renew --reason "<text>"
# grant-conductor-week-v2.sh status | revoke
# grant-conductor-week-v2.sh build-form --reason "<text>" --out <path.html>
# grant-conductor-week-v2.sh issue --confirm-form <form-id>
#
# docs/design/weekly-conductor-authorization.md (h) -- the accepted
# protocol: owner-dispatch-issue.py's own formserve build/answer/issue
# machinery, re-targeted at the conductor-weekly-authorization grant shape
# (lib/conductor_week_approval.py: PROTOCOL, KEYS, render_form,
# validate_approval, read_decision -- a direct structural mirror of
# owner-dispatch-issue.py's own functions, never owner-dispatch-issue.py's
# own owner_dispatch_auth/owner_dispatch_issuance tables, whose columns are
# shaped for a DIFFERENT protocol with no conductor-week analog).
#
# `build-form` is OFFLINE: writes ONE deterministic HTML page with the
# exact candidate grant embedded, nothing written to task_authorizations.
# T then runs `formserve.py <that file>` HIMSELF to actually serve and
# answer it -- this script never serves a page or opens a browser pane;
# formserve.py already does that, correctly, and is not reimplemented
# here. `issue` reads back ONLY an answered, byte-identical record and
# inserts the real grant via lib/task-authorization.py's own
# accept_conductor_week.
#
# The older JSON preview/approve prototype was removed. This formserve-backed
# path is the only weekly grant protocol.
# This script is the accepted path.
#
# `build-form` requires caller_pane_from_ancestry rc=2 -- genuinely outside
# herdr's reach, the SAME proof designate-main.sh --force already requires
# -- never run from inside a Main pane, never relayed by an agent on T's
# behalf. `issue` may run unattended: authority already flows entirely
# from T's own form answer.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"

_outside_herdr_or_die() {
  local rc=0
  caller_pane_from_ancestry >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || {
    echo "grant-conductor-week-v2: refused -- this process traces to a herdr-managed pane (or that could not be verified); $1 is only for a shell outside herdr's reach entirely, run by T directly (docs/design/weekly-conductor-authorization.md (h))" >&2
    exit 1
  }
}

_py() {
  local py; py="$(_registry_python)" || { echo "grant-conductor-week-v2: no usable python3" >&2; exit 1; }
  "$py" "$here/lib/conductor_week_approval.py" "$@"
}

_revoked_file() {
  printf '%s\n' "${HERDR_CONDUCTOR_WEEK_REVOKED_FILE:-$HOME/.local/state/herdr/conductor-weekly-authorization.revoked}"
}

_clear_revocation() {
  local f
  f="$(_revoked_file)"
  [ ! -e "$f" ] || rm -f "$f"
}

_find_form_id() {
  local form_path="$1" created_after_ms="$2" py
  py="$(_registry_python)" || return 1
  "$py" - "$form_path" "$created_after_ms" "${HERDR_STATE_ROOT:-$HOME/.local/state/herdr}/forms" <<'PYEOF'
import json
import sys
from pathlib import Path

form_path = str(Path(sys.argv[1]).resolve())
created_after_ms = int(sys.argv[2])
forms = Path(sys.argv[3])
matches = []
for path in forms.glob("*.json"):
    try:
        row = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        continue
    candidate = row.get("form_path")
    if (candidate and str(Path(candidate).resolve()) == form_path
            and int(row.get("created_at", 0)) >= created_after_ms):
        matches.append((int(row["created_at"]), row["id"]))
if matches:
    print(max(matches)[1])
PYEOF
}

_renew() {
  _outside_herdr_or_die "renew"
  local reason="" html out err created_ms pid form_id="" hub_url rc=0 i
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      --reason=*) reason="${1#--reason=}"; shift ;;
      *) echo "grant-conductor-week-v2: renew: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -n "$reason" ] || { echo "grant-conductor-week-v2: renew requires --reason" >&2; return 2; }
  html="$(mktemp "${TMPDIR:-/tmp}/herdr-factory-week-key.XXXXXX.html")" || return 1
  out="${html%.html}.out"
  err="${html%.html}.err"
  created_ms="$(( $(date +%s) * 1000 ))"
  _CONDUCTOR_WEEK_MINTING_PANE="" _CONDUCTOR_WEEK_MINTING_PANE_BIRTH="" \
    _py build-form --reason "$reason" --out "$html" || return $?

  "$(_registry_python)" "$here/formserve.py" "$html" --timeout 86400 --no-open >"$out" 2>"$err" &
  pid=$!
  for i in $(seq 1 40); do
    form_id="$(_find_form_id "$html" "$created_ms")"
    [ -n "$form_id" ] && break
    sleep 0.25
  done
  if [ -z "$form_id" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$err" >&2
    echo "grant-conductor-week-v2: form did not register" >&2
    return 1
  fi
  hub_url="http://127.0.0.1:8600/decisions/$form_id"
  if ! curl -fsS "$hub_url" | grep -q '<h1>'; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "grant-conductor-week-v2: registered form did not render at $hub_url" >&2
    return 1
  fi
  open -a "Google Chrome" "http://127.0.0.1:8600/decisions" >/dev/null 2>&1 || true
  printf 'weekly key approval: %s\n' "$hub_url"
  wait "$pid" || rc=$?
  cat "$out"
  [ "$rc" = 0 ] || { cat "$err" >&2; return "$rc"; }
  _py issue --confirm-form "$form_id" || return $?
  _clear_revocation
  printf 'renewed:7-days:%s\n' "$form_id"
}

_status() {
  local row revoked=false
  row="$(read_conductor_weekly_authorization 2>/dev/null || true)"
  conductor_week_revoked && revoked=true
  if [ -z "$row" ] || [ "$row" = "{}" ]; then
    printf '{"active":false,"revoked":%s}\n' "$revoked"
    return
  fi
  printf '%s\n' "$row" | jq -c --argjson revoked "$revoked" \
    '{active:(.status=="accepted" and ($revoked|not)),revoked:$revoked,command_id,issued_at,expires_at,labels:.effective_scope.labels,handover_cap:.effective_scope.handover_cap}'
}

_revoke() {
  local f
  f="$(_revoked_file)"
  umask 077
  mkdir -p "$(dirname "$f")" || return 1
  printf 'revoked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$f"
  printf 'revoked:%s\n' "$f"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  build-form)
    _outside_herdr_or_die "build-form"
    minting_pane="$(caller_pane_from_ancestry 2>/dev/null || true)"
    minting_pane_birth=""
    [ -n "$minting_pane" ] && minting_pane_birth="$(pane_birth_now "$minting_pane" 2>/dev/null || true)"
    _CONDUCTOR_WEEK_MINTING_PANE="$minting_pane" \
    _CONDUCTOR_WEEK_MINTING_PANE_BIRTH="$minting_pane_birth" \
      _py build-form "$@"
    ;;
  issue)
    # Unattended-eligible (§(h) step 3): authority flows entirely from the
    # human's own form answer, never from this caller's own identity -- no
    # ancestry check here. A fresh successful issue also clears an older
    # emergency revocation sentinel.
    _py issue "$@" && _clear_revocation
    ;;
  renew)
    _renew "$@"
    ;;
  status)
    [ "$#" = 0 ] || { echo "grant-conductor-week-v2: status takes no arguments" >&2; exit 2; }
    _status
    ;;
  revoke)
    [ "$#" = 0 ] || { echo "grant-conductor-week-v2: revoke takes no arguments" >&2; exit 2; }
    _revoke
    ;;
  *)
    echo "usage: grant-conductor-week-v2.sh renew --reason \"<text>\" | status | revoke | build-form --reason \"<text>\" --out <path.html> | issue --confirm-form <form-id>" >&2
    exit 1
    ;;
esac
