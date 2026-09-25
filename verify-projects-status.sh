#!/usr/bin/env bash
# verify-projects-status.sh — proof for thurber-os docs/project-contract-plan.md
# §2 (/api/projects) and §3a's project-level "carry to completion" wake:
#
#   * schema v4 -> v5 adds tasks.project, register_task's 14th arg populates
#     it, and every existing 13-arg caller still registers with project=''.
#   * hub.py's spec_checklist() parses SPEC.md's `- [ ]`/`- [x]` acceptance
#     items and reports the first unticked one as the next step (or None when
#     every item is ticked, or when the file has no checklist at all).
#   * hub.py's project_needs_wake() — "no live worker, a next step, and
#     nothing waiting on Terrence" — fires on a stalled/dead project with
#     unfinished acceptance and stays quiet once a live worker appears or the
#     acceptance completes.
#
# Registry probes use a throwaway HERDR_RUN_STATE_DIR (mktemp -d) so this
# never touches the real fleet registry. bash tests/*.py invocations are
# subprocess-only, no network, no herdr call — safe to run standalone:
#   bash verify-projects-status.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ── 1: schema v5 / register_task project column ─────────────────────────────
WORK="$(mktemp -d)"
export HERDR_RUN_STATE_DIR="$WORK"
. lib/run-registry.sh

if registry_init; then ok "registry_init (fresh db, schema v5)"; else bad "registry_init failed"; fi

if register_task run1 task1 worker1 cond1 "" "" pane1 birth1 /repo/knowledge-base /wt/x label1 branchX trunkY fub-content; then
  ok "register_task with project (14 args)"
else
  bad "register_task with project failed"
fi

got_project="$(read_task run1 task1 | jq -r '.project')"
[ "$got_project" = "fub-content" ] && ok "read_task reports project=fub-content" \
  || bad "read_task project mismatch: got '$got_project'"

# A pre-existing 13-arg caller (every script written before this change)
# keeps registering with an empty project — never a hard requirement.
if register_task run1 task2 worker2 cond1 "" "" pane2 birth2 /repo/other /wt/y label2 branchZ trunkY; then
  ok "register_task without project (13 args, back-compat)"
else
  bad "register_task without project (13 args) failed"
fi
got_project2="$(read_task run1 task2 | jq -r '.project')"
[ "$got_project2" = "" ] && ok "read_task reports empty project for a 13-arg registration" \
  || bad "expected empty project, got '$got_project2'"

schema_ver="$(_sql "SELECT value FROM schema_meta WHERE key='schema_version';")"
[ "$schema_ver" = "5" ] && ok "schema_meta reports version 5" || bad "schema_version is '$schema_ver', expected 5"

# ── 2: hub.py spec_checklist() / project_needs_wake() ───────────────────────
# Written to a real temp .py file rather than a heredoc inside $(...): this
# repo's bash is macOS's stock 3.2.57, which mis-parses a quoted heredoc
# delimiter when the body contains an apostrophe and the opening line also
# quotes a variable inside a command substitution — measured live tracking
# down this exact test. A temp file sidesteps the whole class of bash-3.2
# heredoc/quoting interactions instead of avoiding apostrophes forever.
if command -v python3 >/dev/null 2>&1; then
  PYFILE="$WORK/check_projects.py"
  cat > "$PYFILE" <<'PYEOF'
import sys, json, importlib.util, tempfile, os

here = sys.argv[1]
spec = importlib.util.spec_from_file_location("hub", os.path.join(here, "hub.py"))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)

wt = tempfile.mkdtemp()
os.makedirs(os.path.join(wt, ".handoffs"), exist_ok=True)


def write_spec(text):
    with open(os.path.join(wt, ".handoffs", "SPEC.md"), "w") as f:
        f.write(text)


results = {}

# All items unticked -> next step is the first one.
write_spec("# SPEC\n\n## Goal\nx\n\n## Acceptance\n- [ ] first thing\n- [ ] second thing\n\n## Proof contract\nx\n")
items, next_step = hub.spec_checklist(wt)
results["first_unticked"] = next_step == "first thing" and len(items) == 2

# First ticked -> next step is the second.
write_spec("# SPEC\n\n## Acceptance\n- [x] first thing\n- [ ] second thing\n")
items, next_step = hub.spec_checklist(wt)
results["second_unticked"] = next_step == "second thing"

# All ticked -> no next step (None).
write_spec("# SPEC\n\n## Acceptance\n- [x] first thing\n- [x] second thing\n")
items, next_step = hub.spec_checklist(wt)
results["all_done"] = next_step is None and len(items) == 2

# No checklist at all (a free-text --brief SPEC.md) -> no items, no next
# step, not a crash (real example: knowledge-base fub-content-layer SPEC.md).
write_spec("# Brief: something\n\n## Goal\nprose only, no checkboxes\n")
items, next_step = hub.spec_checklist(wt)
results["no_checklist"] = items == [] and next_step is None

# ---- project_needs_wake() ----
# No live worker + a next step + nothing waiting on Terrence -> wake.
results["wake_when_stalled_with_next_step"] = hub.project_needs_wake(
    task_states=["stalled"], next_step="first thing", open_forms=0) is True

# A running/blocked worker present -> never wake, even with a next step.
results["no_wake_when_running"] = hub.project_needs_wake(
    task_states=["running"], next_step="first thing", open_forms=0) is False
results["no_wake_when_blocked"] = hub.project_needs_wake(
    task_states=["blocked"], next_step="first thing", open_forms=0) is False

# Nothing left to do -> never wake even with no live worker.
results["no_wake_when_done"] = hub.project_needs_wake(
    task_states=["completed"], next_step=None, open_forms=0) is False

# An open decision already covers it -> the human already knows; don't page.
results["no_wake_when_decision_open"] = hub.project_needs_wake(
    task_states=["stalled"], next_step="first thing", open_forms=1) is False

print(json.dumps(results))
PYEOF
  py_out="$(python3 "$PYFILE" "$here")"
  echo "$py_out" | python3 -c "
import json, sys
r = json.loads(sys.stdin.read().strip().splitlines()[-1])
for k, v in r.items():
    print((\"ok\" if v else \"FAIL\") + \"\t\" + k)
" | while IFS=$'\t' read -r st name; do
    if [ "$st" = ok ]; then printf '  ok    %s\n' "$name"; else printf '  FAIL  %s\n' "$name"; fi
  done
  extra_pass=$(echo "$py_out" | python3 -c "import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(sum(1 for v in r.values() if v))")
  extra_fail=$(echo "$py_out" | python3 -c "import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(sum(1 for v in r.values() if not v))")
  pass=$((pass + extra_pass)); fail=$((fail + extra_fail))
else
  bad "python3 not found — cannot exercise hub.py's spec_checklist/project_needs_wake"
fi

echo
echo "===== VERIFY ====="
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
