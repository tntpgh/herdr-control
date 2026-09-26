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

# spawn-task.sh's own unfilled template placeholder line is never a real
# item (review #146 finding 2: it paged Main on the first tick after deploy
# for two already-shipped projects whose workers never touched SPEC.md).
write_spec("# SPEC\n\n## Acceptance\n- [ ] (one checkbox per acceptance criterion)\n")
items, next_step = hub.spec_checklist(wt)
results["placeholder_filtered"] = items == [] and next_step is None

# A wrapped acceptance item (an indented continuation line) is joined to the
# previous item's text, not truncated (review #146 finding 9 — measured live:
# herdr-control's own next_step came out truncated at the wrap point).
write_spec(
    "# SPEC\n\n## Acceptance\n"
    "- [ ] PR against main with every CI check consumed on the final SHA (opened,\n"
    "      not yet merged -- Main merges).\n"
)
items, next_step = hub.spec_checklist(wt)
results["wrapped_line_joined"] = next_step == "PR against main with every CI check consumed on the final SHA (opened, not yet merged -- Main merges)."

# ---- project_needs_wake() (pure function; task_states is whatever the
# CALLER passes — see the full-join test below for proof the caller now
# passes the REGISTRY's stored state, not the page's derived one) ----
# No live worker + a next step + nothing waiting on Terrence -> wake.
results["wake_when_stalled_with_next_step"] = hub.project_needs_wake(
    task_states=["lost"], next_step="first thing", open_forms=0) is True

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
    task_states=["lost"], next_step="first thing", open_forms=1) is False

# A closed latest task (shipped/canceled/no-follow-on/handed_off_to:*) means
# a human-reviewed gate already decided the outcome; an unticked SPEC.md box
# is not grounds to re-open it (review #146 finding 2).
for reason in ("shipped", "canceled", "no-follow-on", "handed_off_to:qa-team"):
    results[f"no_wake_when_closed_{reason.split(':')[0]}"] = hub.project_needs_wake(
        task_states=["lost"], next_step="first thing", open_forms=0, closure_reason=reason) is False

# A lost/failed task with NO closure reason recorded still needs a wake --
# closure is a gate, not a requirement to have one at all.
results["wake_when_lost_no_closure_reason"] = hub.project_needs_wake(
    task_states=["lost"], next_step="first thing", open_forms=0, closure_reason=None) is True

# Worker gone (task reconciled to lost) but its PR is open in review -> the
# work is in Terrence's queue, not abandoned; never page Main to carry it.
results["no_wake_when_pr_open_in_review"] = hub.project_needs_wake(
    task_states=["lost"], next_step="first thing", open_forms=0, closure_reason=None,
    open_prs=1) is False

# ---- full join: projects_data() against realistic herdr_data()-shaped
# fixtures (review #146 finding 8: prior coverage only exercised the pure
# helpers with a hand-picked task_states=["stalled"], which encoded the bug
# rather than catching it). Every external dependency is monkeypatched so
# this never touches the real registry, gh, or a live pane.


class _FakeCache:
    def __init__(self, value):
        self.value = value

    def get(self):
        return self.value


def _spec_with_unfinished_item(text_of_item):
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, ".handoffs"), exist_ok=True)
    with open(os.path.join(d, ".handoffs", "SPEC.md"), "w") as f:
        f.write(f"# SPEC\n\n## Acceptance\n- [ ] {text_of_item}\n")
    return d


def _spec_with_placeholder_only():
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, ".handoffs"), exist_ok=True)
    with open(os.path.join(d, ".handoffs", "SPEC.md"), "w") as f:
        f.write("# SPEC\n\n## Acceptance\n- [ ] (one checkbox per acceptance criterion)\n")
    return d


# tourguide-like: latest task CLOSED shipped, worker never touched SPEC.md
# (template placeholder left behind) -> must never wake.
wt_tourguide = _spec_with_placeholder_only()
task_tourguide = {
    "task_id": "t-tourguide", "state": "completed", "stored_state": "completed",
    "pane_id": "", "label": "implement:x", "branch": "feat/x", "worktree": wt_tourguide,
    "repo": "/repo/tourguide", "project": "", "updated_at": "2026-09-01T00:00:00Z",
    "closure_reason": "shipped",
}

# watchdog-worker-like: worker FINISHED and is awaiting Terrence's PR review
# (derived "ready_review"), but the REGISTRY never explicitly closed it —
# stored_state stays "running". A real unfinished checklist item is present.
# Must never wake: the worker is live/awaiting review, not abandoned.
wt_watchdog = _spec_with_unfinished_item("open the PR")
task_watchdog = {
    "task_id": "t-watchdog", "state": "ready_review", "stored_state": "running",
    "pane_id": "", "label": "implement:y", "branch": "feat/y", "worktree": wt_watchdog,
    "repo": "/repo/watchdog-worker", "project": "", "updated_at": "2026-09-01T00:00:00Z",
    "closure_reason": None,
}

# genuinely-abandoned: the registry marked it LOST (a real terminal state, no
# live pane), no closure reason was ever recorded, and real work remains.
# THIS is the case the whole feature exists for -> must wake.
wt_abandoned = _spec_with_unfinished_item("finish the migration")
task_abandoned = {
    "task_id": "t-abandoned", "state": "lost", "stored_state": "lost",
    "pane_id": "", "label": "implement:z", "branch": "feat/z", "worktree": wt_abandoned,
    "repo": "/repo/scratch-project", "project": "", "updated_at": "2026-09-01T00:00:00Z",
    "closure_reason": None,
}

hub.CACHES["herdr"] = _FakeCache({"tasks": [task_tourguide, task_watchdog, task_abandoned]})
hub.CACHES["forms"] = _FakeCache({"open": []})
hub._claims_by_worktree = lambda: {}
hub._open_prs_for_repo = lambda repo: {}
hub._pane_probe = lambda pane_id: {}

joined = hub.projects_data()
by_project = {p["project"]: p for p in joined["projects"]}

results["join_tourguide_no_wake"] = by_project.get("tourguide", {}).get("needs_wake") is False
results["join_watchdog_no_wake"] = by_project.get("watchdog-worker", {}).get("needs_wake") is False
results["join_abandoned_wakes"] = by_project.get("scratch-project", {}).get("needs_wake") is True
results["join_tourguide_next_step_none"] = by_project.get("tourguide", {}).get("next_step") is None

print(json.dumps(results))
PYEOF
  if ! py_out="$(python3 "$PYFILE" "$here")"; then
    # A crash here used to report failed=0 with every check below silently
    # skipped (seen live: a TypeError on a new kwarg read as green).
    bad "hub.py check block crashed — every spec_checklist/project_needs_wake/join case is unverified"
    py_out='{}'
  fi
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
