#!/usr/bin/env bash
# Read-only classification probe: none of the command strings is executed.
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/lib/scoped-policy.sh"
task=$(jq -nc --arg wt "$here" '{task_id:"synthetic-dot-plan",worktree:$wt,branch:"fix/dot-control-authorization",trunk:"main",manifest:"{\"git\":\"commit-only\",\"net_read\":[],\"net_write\":\"none\",\"writes\":[]}"}')
probe() {
  local label="$1" cmd="$2" grant rc
  grant=$(_cp_grant_action "$cmd" "$here" fix/dot-control-authorization main); rc=$?
  printf '%s ownership_rc=%s grant=%s\n' "$label" "$rc" "${grant:-none}"
  peer_decide "$cmd" "$task"; rc=$?
  printf '%s peer_rc=%s verdict=%s authority=%s reason=%s\n' "$label" "$rc" "$PD_VERDICT" "$PD_AUTHORITY" "$PD_REASON"
}
probe add 'git add -- "example-one.md" "example-two.md"'
probe status 'git status --short'
probe commit 'git commit -m "Document scoped task"'
probe compound 'git add -- "example-one.md" "example-two.md" && git status --short && git commit -m "Document scoped task"'
probe quoted_cd "cd \"$here\" && git commit -m 'Document scoped task'"
