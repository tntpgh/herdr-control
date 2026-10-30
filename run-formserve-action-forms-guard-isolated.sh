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
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$here/verify-formserve-action-forms-guard.sh" ] || { echo "isolated-run: missing verify-formserve-action-forms-guard.sh next to this script" >&2; exit 1; }

S="$(mktemp -d)" || { echo "isolated-run: mktemp -d failed" >&2; exit 1; }
cleanup() { rm -rf "$S"; }
trap cleanup EXIT

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
export HERDR_ACTION_NOTIFY="$S/bin/notify-stub.sh" HERDR_ACTION_SEND="$S/bin/send-stub.sh"
export HERDR_TEST_NOTIFIED="$S/notified.log" HERDR_TEST_SENT="$S/sent.log"
: > "$HERDR_TEST_NOTIFIED"
: > "$HERDR_TEST_SENT"

bash "$here/verify-formserve-action-forms-guard.sh"
rc=$?

echo
echo "== isolated-run: stubbed side channels (informational -- a notify call"
echo "   here is EXPECTED, the request's one human-route Slack post; real"
echo "   herdr-notify.sh/send never ran) =="
echo "notify-stub.sh calls:"
cat "$HERDR_TEST_NOTIFIED"
echo "send-stub.sh calls:"
cat "$HERDR_TEST_SENT"

exit "$rc"
