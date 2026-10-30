#!/usr/bin/env bash
# run-formserve-action-forms-guard-isolated.sh — the ONE command to run
# verify-formserve-action-forms-guard.sh in isolation.
#
# That suite drives the REAL herdr-action.sh CLI ("tick") against the REAL
# formserve.py through lib/run-registry.sh's trusted-receipt authorization
# path (action_request_create, register_task, accept_local_task_
# authorization) — genuine control-plane registry writes, so an agent in
# this repo's sandbox cannot run it (lib/hook-approval-rules.tsv: registry
# writes are human-only). This script is for a human to run by hand:
#
#   bash run-formserve-action-forms-guard-isolated.sh
#
# Every piece of isolation lives in THIS reviewed, committed script — never
# a tmp/ wrapper, which nobody but its author ever reads. Fail-closed: every
# setup step is checked (`set -euo pipefail` plus explicit `|| exit 1`
# guards), so a setup failure (mktemp, mkdir, stub write) aborts BEFORE the
# real suite ever runs, rather than silently running against whatever
# HOME/HERDR_STATE_ROOT/HERDR_RUN_STATE_DIR happen to already be set to.
#
# Isolation: HOME, HERDR_STATE_ROOT, HERDR_RUN_STATE_DIR and TMPDIR all
# point inside one mktemp -d; never the live ~/.local/state/herdr.
# HERDR_ACTION_NOTIFY and HERDR_ACTION_SEND are stubbed to local recorder
# scripts, because the suite's route=human action request makes it past
# claim_once's slack-notify gate on its very first herdr-action.sh tick —
# without a stub, that is a REAL Slack post (herdr-action.sh:534-536).
#
# REVIEW-FORMFIX-R2-510269d.md: the suite's own live-dir check must snapshot
# the REAL root, not whatever HOME happens to be once this launcher has
# already exported its sandboxed one. HERDR_GUARD_LIVE_ROOT is therefore
# captured from the REAL $HOME below, BEFORE the `export HOME=...` line, and
# handed to the suite explicitly; the suite fails closed if it is unset or
# resolves inside the sandbox ($S). $S itself is never deleted (no cleanup
# trap) so the sandboxed registry/forms a human would want to inspect after
# a run survive it; its path is printed at the end.
#
# REVIEW-FORMFIX-R3-a336a25.md: (1) the real-$HOME capture had no validation
# -- an empty/relative/missing $HOME silently produced a bogus live root.
# (6) a bare `bash …; rc=$?` under `set -e` meant any suite failure (rc!=0)
# aborted this script immediately, so the retained-$S path from r3 never
# printed on the one case (a failure) where a human would most want it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$here/verify-formserve-action-forms-guard.sh" ] || { echo "isolated-run: missing verify-formserve-action-forms-guard.sh next to this script" >&2; exit 1; }

if [ -z "${HOME:-}" ]; then
  echo "isolated-run: \$HOME is empty -- refusing to run" >&2
  exit 1
fi
case "$HOME" in
  /*) ;;
  *) echo "isolated-run: \$HOME ($HOME) is not an absolute path -- refusing to run" >&2; exit 1 ;;
esac
[ -d "$HOME" ] || { echo "isolated-run: \$HOME ($HOME) does not exist or is not a directory -- refusing to run" >&2; exit 1; }

HERDR_GUARD_LIVE_ROOT="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$HOME/.local/state/herdr")" \
  || { echo "isolated-run: could not resolve the real path of \$HOME/.local/state/herdr" >&2; exit 1; }
case "$HERDR_GUARD_LIVE_ROOT" in
  /*) ;;
  *) echo "isolated-run: resolved live root ($HERDR_GUARD_LIVE_ROOT) is not absolute -- refusing to run" >&2; exit 1 ;;
esac

S="$(mktemp -d)" || { echo "isolated-run: mktemp -d failed" >&2; exit 1; }
S="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$S")" \
  || { echo "isolated-run: could not resolve the real path of the sandbox dir" >&2; exit 1; }

mkdir -p "$S/home" "$S/state" "$S/runs" "$S/tmp" "$S/bin" || { echo "isolated-run: mkdir -p scratch dirs failed" >&2; exit 1; }

cat > "$S/bin/notify-stub.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${HERDR_TEST_NOTIFIED:-/dev/null}"
EOF
cat > "$S/bin/send-stub.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${HERDR_TEST_SENT:-/dev/null}"
EOF
chmod +x "$S/bin/notify-stub.sh" "$S/bin/send-stub.sh" || { echo "isolated-run: could not write/chmod stub scripts" >&2; exit 1; }

export HOME="$S/home" HERDR_STATE_ROOT="$S/state" HERDR_RUN_STATE_DIR="$S/runs" TMPDIR="$S/tmp"
export HERDR_GUARD_LIVE_ROOT="$HERDR_GUARD_LIVE_ROOT" HERDR_GUARD_SANDBOX_ROOT="$S"
export HERDR_ACTION_NOTIFY="$S/bin/notify-stub.sh" HERDR_ACTION_SEND="$S/bin/send-stub.sh"
export HERDR_TEST_NOTIFIED="$S/notified.log" HERDR_TEST_SENT="$S/sent.log"
: > "$HERDR_TEST_NOTIFIED"
: > "$HERDR_TEST_SENT"

rc=0
bash "$here/verify-formserve-action-forms-guard.sh" || rc=$?

echo
echo "== isolated-run: stubbed side channels (informational -- a notify call"
echo "   here is EXPECTED, the request's one human-route Slack post; real"
echo "   herdr-notify.sh/send never ran) =="
echo "notify-stub.sh calls:"
cat "$HERDR_TEST_NOTIFIED"
echo "send-stub.sh calls:"
cat "$HERDR_TEST_SENT"

echo
echo "== isolated-run: sandbox retained (no cleanup trap), for inspection =="
echo "$S"

exit "$rc"
