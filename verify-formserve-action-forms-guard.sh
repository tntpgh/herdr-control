#!/usr/bin/env bash
# verify-formserve-action-forms-guard.sh — formserve's action-forms guard
# (formserve.py: ACTION_FORMS_DIR / is_herdr_actions_own_serve) must let
# herdr-action.sh's OWN, real serve of its OWN file through, and still
# refuse a hand-placed copy next to it.
#
# Independent review of fix/formserve-title-consistency (REVIEW-FORMSERVE-
# 605f9da.md, G1/G2): the first version of the guard refused EVERY
# herdr-action.sh action form, including legitimate ones, because it ignored
# --request-id; it also derived its directory from HERDR_STATE_ROOT while
# herdr-action.sh uses HERDR_RUN_STATE_DIR (lib/run-registry.sh's
# run_state_root()), two variables several suites already set to DIFFERENT
# scratch dirs. This suite sets them to different dirs on purpose, so either
# defect would show up as case 1 failing.
#
# Drives the REAL herdr-action.sh CLI ("tick") against the REAL formserve.py
# (neither HERDR_ACTION_FORMSERVE nor HERDR_ACTION_PYTHON overridden), via
# lib/run-registry.sh's real trusted-receipt authorization path (the same
# fixture verify-task-authorization-gates.sh uses) so cmd_tick's own
# task_authorization_check passes without stubbing herdr/ps ancestry.
#
# Entirely sandboxed: HERDR_RUN_STATE_DIR and HERDR_STATE_ROOT both point at
# a scratch dir; never the live ~/.local/state/herdr. The spawned formserve
# process is killed by the exact pid its own registry row records -- never a
# pattern-matched pkill.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The real tree herdr-action.sh/formserve.py fall back to whenever
# HERDR_RUN_STATE_DIR/HERDR_STATE_ROOT are unset. MUST come from the
# caller, captured before anything sandboxes HOME: review REVIEW-FORMFIX-
# R2-510269d.md (G2/L1) caught this suite computing it from "${HOME}" at a
# point where the launcher had ALREADY exported a sandboxed HOME, so it
# snapshotted the sandbox instead of the real tree. Fail closed rather than
# fall back to deriving it ourselves again: unset, or anything whose REAL
# path (symlinks and relative components resolved) is the sandbox root or
# any descendant of it, refuses.
#
# REVIEW-FORMFIX-R3-a336a25.md (5): a prior version of this check compared
# the raw string against only $HOME and $TMPDIR -- 2 of the sandbox's 5
# subdirectories (home/, state/, runs/, tmp/, bin/), unresolved. The
# launcher now exports HERDR_GUARD_SANDBOX_ROOT (its own realpath'd $S) and
# this suite does its own realpath-based PREFIX comparison against it,
# covering every descendant in one check, independent of what the launcher
# already validated.
if [ -z "${HERDR_GUARD_LIVE_ROOT:-}" ]; then
  echo "FAIL setup: HERDR_GUARD_LIVE_ROOT is not set -- run via run-formserve-action-forms-guard-isolated.sh, which captures the real ~/.local/state/herdr before sandboxing HOME" >&2
  exit 1
fi
if [ -z "${HERDR_GUARD_SANDBOX_ROOT:-}" ]; then
  echo "FAIL setup: HERDR_GUARD_SANDBOX_ROOT is not set -- run via run-formserve-action-forms-guard-isolated.sh" >&2
  exit 1
fi
_guard_realpath() { python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"; }
live_real="$(_guard_realpath "$HERDR_GUARD_LIVE_ROOT")" \
  || { echo "FAIL setup: could not resolve realpath of HERDR_GUARD_LIVE_ROOT ($HERDR_GUARD_LIVE_ROOT)" >&2; exit 1; }
sandbox_real="$(_guard_realpath "$HERDR_GUARD_SANDBOX_ROOT")" \
  || { echo "FAIL setup: could not resolve realpath of HERDR_GUARD_SANDBOX_ROOT ($HERDR_GUARD_SANDBOX_ROOT)" >&2; exit 1; }
case "$live_real" in
  "$sandbox_real"|"$sandbox_real"/*)
    echo "FAIL setup: HERDR_GUARD_LIVE_ROOT realpath ($live_real) is the sandbox root or a descendant of it ($sandbox_real) -- refusing to run" >&2
    exit 1 ;;
esac
LIVE_HERDR_DIR="$live_real"
live_snapshot() {
  python3 -c "
import os, sys
d = sys.argv[1]
out = []
if os.path.isdir(d):
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            try:
                st = os.stat(p)
                out.append((os.path.relpath(p, d), st.st_size, int(st.st_mtime)))
            except OSError:
                pass
print(sorted(out))
" "$LIVE_HERDR_DIR"
}
live_before="$(live_snapshot)"
work="$(mktemp -d "${TMPDIR:-/tmp}/formserve-action-guard.XXXXXX")" || exit 1
export HERDR_RUN_STATE_DIR="$work/runs" HERDR_STATE_ROOT="$work/state"
wt="$work/worktree"; mkdir -p "$wt"
fails=0
ok() { printf '  ok   %s\n' "$1"; }
not_ok() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

. "$here/lib/run-registry.sh"
. "$here/lib/action-request.sh"

accept_local_task_authorization guard-trusted w9:p9 conductor-birth "$wt" '' >/dev/null \
  || { not_ok "setup: accept_local_task_authorization"; exit 1; }
register_task run1 task1 worker1 cond1 w9:p9 conductor-birth w2:p2 worker-birth \
  "$wt" "$wt" impl:task1 feat/x main '' '' hook guard-trusted >/dev/null \
  || { not_ok "setup: register_task"; exit 1; }
mark_authorization_launch guard-trusted task1 run1 launch_claimed >/dev/null \
  || { not_ok "setup: launch_claimed"; exit 1; }
mark_authorization_launch guard-trusted task1 run1 launched >/dev/null \
  || { not_ok "setup: launched"; exit 1; }
set_task_state run1 task1 running >/dev/null

# route=human set directly on creation skips cmd_tick's conductor-surface
# branch, so the very first tick drives _ha_human_route -> _ha_serve_form.
rid="$(action_request_create run1 task1 bash guard-sha 'echo guard test' escalate fixture human once '' '')"
[ -n "$rid" ] || { not_ok "setup: action_request_create"; exit 1; }

echo "== formserve action-forms guard: real herdr-action.sh serve path =="

bash "$here/herdr-action.sh" tick >/dev/null 2>&1

fid=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  fid="$(_sql "SELECT form_record FROM action_requests WHERE request_id=$(_sq "$rid");" 2>/dev/null)"
  [ -n "$fid" ] && break
  sleep 0.5
done
rec="$HERDR_STATE_ROOT/forms/$fid.json"
if [ -n "$fid" ] && [ -f "$rec" ] && [ "$(jq -r .status "$rec")" = open ]; then
  ok "herdr-action.sh's own serve of its own action-forms file is NOT refused (form $fid open)"
else
  not_ok "herdr-action's own serve was refused or never registered: request=$rid form_record=$fid"
fi
if [ -n "$fid" ] && [ -f "$rec" ] \
  && [ "$(jq -r .request_id "$rec")" = "$rid" ] \
  && [ "$(jq -r .title "$rec")" = "Human-only action requested: impl:task1" ]; then
  ok "served form's request_id/title match herdr-action's own call"
else
  not_ok "served form mismatch: $(jq -c '{request_id,title}' "$rec" 2>/dev/null)"
fi

# Kill the long-lived (--timeout 86400) real formserve this test spawned, by
# the EXACT pid its own registry row recorded -- never a name/pattern kill.
if [ -n "$fid" ] && [ -f "$rec" ]; then
  pid="$(jq -r .pid "$rec" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != null ] && kill "$pid" 2>/dev/null
fi

# A hand-placed copy next to the real file, in the SAME dir, is still
# refused: same bytes, but no matching --request-id/registry row.
action_forms_dir="$(run_state_root)/action-forms"
cp "$action_forms_dir/${rid}-1.html" "$action_forms_dir/${rid}-1-copy.html" 2>/dev/null
out=$(python3 "$here/formserve.py" "$action_forms_dir/${rid}-1-copy.html" --port 0 --no-open --timeout 1 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "herdr-action serves this form itself"; then
  ok "a hand copy of the same bytes, same dir, no bound request-id, is still refused"
else
  not_ok "hand copy was not refused: rc=$rc out=$(printf '%s' "$out" | head -2)"
fi

live_after="$(live_snapshot)"
if [ "$live_before" = "$live_after" ]; then
  ok "live $LIVE_HERDR_DIR unchanged"
else
  not_ok "live $LIVE_HERDR_DIR CHANGED: before=$live_before after=$live_after"
fi
echo "work dir retained (no cleanup trap), for inspection: $work"

if [ "$fails" -eq 0 ]; then
  echo "# all checks passed"
  exit 0
fi
echo "# $fails check(s) FAILED"
exit 1
