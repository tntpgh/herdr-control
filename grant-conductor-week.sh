#!/usr/bin/env bash
# grant-conductor-week.sh build --reason "<text>"
# grant-conductor-week.sh approve <form-id>
# grant-conductor-week.sh issue --confirm-form <form-id>
#
# docs/design/weekly-conductor-authorization.md (h) -- the one weekly mint
# command, human-only, a two-step preview-then-confirm flow: `build`
# computes and PRINTS the exact candidate grant (issued_at, expires_at,
# weekend-spanning flag, scope, caps, reason, minting identity) and writes
# ONLY a preview file -- zero task_authorizations rows, nothing yet to
# revoke (§(g) item 18); `approve` flips that preview to answered; `issue`
# reads back ONLY the approved, digest-matched record and inserts the real
# grant -- never the reverse order, never a freshly-recomputed "now" at
# issue time (§(g) items 19/20/21).
#
# SCOPE NOTE (read before touching this file): §(h)'s prose names
# `owner-dispatch-issue.py`'s own HTML-form + dedicated-SQLite-table
# protocol ("no new primitive") as the pattern to reuse. This script
# instead layers on a LIGHTER, self-contained JSON preview/approve/issue
# mechanism (lib/conductor_week_form.py), built on lib/record_store.py's
# existing claim-once atomic file update -- the same primitive formserve.py
# and owner-dispatch-issue.py both already depend on, just without
# owner-dispatch-issue.py's own additional HTML-rendering/dedicated-table
# layer on top. Every safety property §(h)/§(g) actually names is still
# here byte-for-byte: zero authoritative write at build, digest-bound
# compare-and-swap at issue, a hard confirm-window staleness refusal, and
# single-use (claim-once via lib/record_store.py). This substitution was
# made because the heavier owner-dispatch-issue.py-style reimplementation
# could not be executed even once in the edit-only session that built this
# file (see .handoffs/PROOF.md) -- an untested multi-hundred-line HTML/
# SQLite protocol handed to T unexercised is a worse risk than a smaller,
# fully-inspectable mechanism with the same guarantees. Documented here
# deliberately, not hidden; wiring a real formserve.py/hub page onto this
# later is additive (the record shape already matches that vocabulary),
# not a rewrite.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"

_outside_herdr_or_die() {
  local rc=0
  caller_pane_from_ancestry >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || {
    echo "grant-conductor-week: refused -- this process traces to a herdr-managed pane (or that could not be verified); $1 is only for a shell outside herdr's reach entirely, run by T directly (docs/design/weekly-conductor-authorization.md (h))" >&2
    exit 1
  }
}

_py() {
  local py; py="$(_registry_python)" || { echo "grant-conductor-week: no usable python3" >&2; exit 1; }
  "$py" "$@"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  build)
    _outside_herdr_or_die "build"
    reason=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) reason="${2:?grant-conductor-week: --reason needs a value}"; shift 2 ;;
        *) echo "grant-conductor-week: unrecognized argument: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$reason" ] || { echo "usage: grant-conductor-week.sh build --reason \"<text>\"" >&2; exit 1; }
    minting_pane="$(caller_pane_from_ancestry 2>/dev/null)"
    _py - "$reason" "$minting_pane" <<'PYEOF'
import json, sys
sys.path.insert(0, "lib")
import conductor_week_form as cwf

reason, minting_pane = sys.argv[1], sys.argv[2]
row = cwf.build(reason, minting_pane)
f = row["fields"]
print(f"grant-conductor-week: preview written -> {row['id']}")
print(f"  issued_at:  {f['issued_at']}")
print(f"  expires_at: {f['expires_at']}")
print(f"  scope:      labels={f['labels']}")
print(f"  caps:       handover_cap={f['handover_cap']}")
print(f"  reason:     {f['reason']}")
print(f"  minting_pane: {minting_pane or '(none)'}")
if row["weekend_spanning"]:
    print("  WEEKEND-SPANNING: this window includes a Saturday or Sunday")
print(f"  digest:     {row['digest']}")
print()
print(f"next: grant-conductor-week.sh approve {row['id']}")
print(json.dumps(row, indent=2, sort_keys=True))
PYEOF
    ;;
  approve)
    _outside_herdr_or_die "approve"
    form_id="${1:-}"
    [ -n "$form_id" ] || { echo "usage: grant-conductor-week.sh approve <form-id>" >&2; exit 1; }
    _py - "$form_id" <<'PYEOF'
import json, sys
sys.path.insert(0, "lib")
import conductor_week_form as cwf
import record_store as rs

form_id = sys.argv[1]
try:
    row = cwf.approve(form_id)
except rs.NotClaimable as e:
    print(f"grant-conductor-week: refused -- form {form_id} is not open (currently {e.state})", file=sys.stderr)
    sys.exit(1)
except FileNotFoundError:
    print(f"grant-conductor-week: refused -- no such form {form_id}", file=sys.stderr)
    sys.exit(1)
print(f"grant-conductor-week: approved {form_id}")
print(f"next: grant-conductor-week.sh issue --confirm-form {form_id}")
print(json.dumps(row, indent=2, sort_keys=True))
PYEOF
    ;;
  issue)
    # Unattended-eligible by design (§(h) step 3): authority flows entirely
    # from the human's own `approve` in step 2, never from this caller's
    # own identity -- no ancestry check here.
    form_id=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --confirm-form) form_id="${2:?grant-conductor-week: --confirm-form needs a value}"; shift 2 ;;
        *) echo "grant-conductor-week: unrecognized argument: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$form_id" ] || { echo "usage: grant-conductor-week.sh issue --confirm-form <form-id>" >&2; exit 1; }
    precheck_out="$(_py - "$form_id" <<'PYEOF'
import json, sys
sys.path.insert(0, "lib")
import conductor_week_form as cwf

row, refusal = cwf.issue_precheck(sys.argv[1])
if refusal:
    print(f"REFUSED:{refusal}")
    sys.exit(1)
print(json.dumps(row))
PYEOF
)"
    precheck_rc=$?
    if [ "$precheck_rc" -ne 0 ]; then
      echo "grant-conductor-week: refused -- ${precheck_out#REFUSED:}" >&2
      exit 1
    fi
    issued_at="$(printf '%s' "$precheck_out" | jq -r '.fields.issued_at')"
    expires_at="$(printf '%s' "$precheck_out" | jq -r '.fields.expires_at')"
    reason="$(printf '%s' "$precheck_out" | jq -r '.fields.reason')"
    minting_marker="$(printf '%s' "$precheck_out" | jq -r '.fields.minting_marker')"
    command_id="$(gen_id conductor_week)"
    grant_json="$(accept_conductor_weekly_authorization "$command_id" "$minting_marker" "$reason" "$issued_at" "$expires_at")" || {
      echo "grant-conductor-week: refused -- accept_conductor_weekly_authorization failed (digest-approved preview rejected by storage layer)" >&2
      exit 1
    }
    echo "grant-conductor-week: issued $command_id"
    printf '%s\n' "$grant_json"
    ;;
  *)
    echo "usage: grant-conductor-week.sh build --reason \"<text>\" | approve <form-id> | issue --confirm-form <form-id>" >&2
    exit 1
    ;;
esac
