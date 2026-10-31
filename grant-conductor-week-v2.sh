#!/usr/bin/env bash
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
# FROZEN SIBLING: grant-conductor-week.sh + lib/conductor_week_form.py (a
# lighter, non-formserve JSON preview/approve mechanism built earlier in
# this session) are NOT this protocol. Frozen in place per conductor
# instruction -- do not edit, do not delete, do not wire anything to them.
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
    # ancestry check here.
    _py issue "$@"
    ;;
  *)
    echo "usage: grant-conductor-week-v2.sh build-form --reason \"<text>\" --out <path.html> | issue --confirm-form <form-id>" >&2
    exit 1
    ;;
esac
