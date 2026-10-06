#!/usr/bin/env bash
# verify-worktree-archival.sh — real-negative test suite for close-done-
# workers.sh's detached-HEAD close path and archive-worktrees.sh
# (2026-10-05-worktree-archival-and-detached-close proposal; review r1 of
# PR #236, whose probes P1-P8 are Section P below, review r2, whose probes
# are Section R, and review r3, whose probes S3 and S5 are Section S).
#
# Real git throughout: a real bare "origin" repo, real `git worktree add`,
# real `git ls-remote`/`rev-list`/`bundle`, real sha256 manifests, real
# lsof. Only two EXTERNAL services are stubbed, both exported bash functions
# the scripts under test call as their own subprocess — `herdr` (never the
# real pane daemon) and `gh` (never a real GitHub call) — same pattern as
# verify-close-done-workers.sh. Section R adds a pass-through `shasum` on
# PATH whose only job is to run a hook mid-archive; Section S adds more such
# hooks and runs the REAL spawn-task.sh (herdr stubbed) against the archiver.
# Every repo, worktree, registry, archive root and code root lives under one
# mktemp dir; nothing here touches ~/Code.
#
#   bash verify-worktree-archival.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
_manifest_has() {               # <manifest> <sha256> <relpath>
  awk -F'\t' -v s="$2" -v r="$3" '$1==s && $3==r {f=1} END{exit !f}' "$1"
}

# Canonical (pwd -P) so every path this suite prints matches what git
# reports; symlinked spellings are created on purpose where a test needs one.
TMP=$(cd "$(mktemp -d)" && pwd -P)
export HERDR_RUN_STATE_DIR="$TMP/runs"
export HERDR_ARCHIVE_ROOT="$TMP/archive"
# archive-worktrees.sh only ever archives beneath ~/.herdr/worktrees or
# $HERDR_CODE_ROOT/.worktrees, and with no repo argument scans
# $HERDR_CODE_ROOT — both stay inside the scratch dir.
export HERDR_CODE_ROOT="$TMP/code"
export HERDR_APP_DIR="$TMP/no-such-app"
export HERDR_ARCHIVE_MIN_FREE_KB=0
WTROOT="$HERDR_CODE_ROOT/.worktrees"
mkdir -p "$WTROOT"

CALLS=$(mktemp)
export CALLS
export PANES_JSON='{"result":{"panes":[{"pane_id":"pD","agent_status":"idle","terminal_id":"birthD-live","cwd":"/"}]}}'
# PANES_FILE, when set, wins over PANES_JSON: a hook firing mid-run (Section
# R) rewrites the file to "spawn" a pane between the check and the remove.
herdr() {
  printf '%s\n' "$1 $2" >> "$CALLS"
  case "$1 $2" in
    "pane list")  if [ -n "${PANES_FILE:-}" ]; then cat "$PANES_FILE"; else printf '%s\n' "$PANES_JSON"; fi ;;
    "pane close") : ;;
    *) printf '{}\n' ;;
  esac
}
export -f herdr

# gh stub, matching real gh's shapes: `gh pr view <n> -R <slug> --json ...
# -q <jq>` applies -q to ONE object and fails when the PR does not exist;
# `gh pr list -R <slug> --head <branch> --state all --json ... -q <jq>`
# applies -q to an ARRAY of every matching PR — empty, exit 0, when there is
# none. GH_PRS is "<slug>#<n> <branch> <STATE> <merge-oid|->", one PR per
# line. GH_DOWN=1 makes every call fail the way an API outage does.
export GH_DOWN=0
export GH_PRS="org/repo#42 pr-42 MERGED a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
org/repo#43 pr-43 OPEN -
org/repo#44 pr-44 CLOSED -
rtree/demo#1 feat-merged MERGED b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
rtree/demo#2 feat-open OPEN -
rtree/demo#3 feat-closed CLOSED -
rtree/demo#4 feat-pullonly MERGED c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
rtree/demo#5 feat-dirty MERGED d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
rtree/demo#9 feat-stale MERGED e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5
rtree/demo#10 feat-disk MERGED f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6
probe/p1#11 p1-open OPEN -
probe/p2#21 p2-sub MERGED 2121212121212121212121212121212121212121
probe/p2#22 p2-link MERGED 2222222222222222222222222222222222222222
probe/p3#31 p3-reused MERGED 3131313131313131313131313131313131313131
probe/p3#32 p3-reused OPEN -
probe/p4#41 p4-live MERGED 4141414141414141414141414141414141414141
probe/alpha#51 review/shared CLOSED -
probe/beta#52 review/shared CLOSED -
probe/p6#61 p6-parent MERGED 6161616161616161616161616161616161616161
probe/p8#81 p8-merged MERGED 8181818181818181818181818181818181818181"
gh() {
  [ "$GH_DOWN" = 1 ] && { echo "gh: HTTP 503 (stub: API down)" >&2; return 1; }
  local cmd="$1 $2" slug="" q="" head="" n="" prev="" a key br st oid num arr='[]'
  for a in "$@"; do
    case "$prev" in
      -R) slug="$a" ;;
      -q) q="$a" ;;
      --head) head="$a" ;;
    esac
    prev="$a"
  done
  [ "$cmd" = "pr view" ] && n="$3"
  while read -r key br st oid; do
    [ -n "$key" ] || continue
    case "$key" in "$slug#"*) ;; *) continue ;; esac
    num="${key#*#}"
    if [ -n "$n" ]; then
      [ "$num" = "$n" ] || continue
    else
      [ "$br" = "$head" ] || continue
    fi
    arr=$(jq -c --arg s "$st" --arg u "https://github.com/$slug/pull/$num" --arg o "$oid" \
      '. + [{state:$s, url:$u, mergeCommit:(if $o=="-" then null else {oid:$o} end)}]' <<<"$arr")
  done <<<"$GH_PRS"
  if [ "$cmd" = "pr view" ]; then
    [ "$(jq length <<<"$arr")" -gt 0 ] || { echo "GraphQL: Could not resolve to a PullRequest" >&2; return 1; }
    jq -r ".[0] | $q" <<<"$arr"
  else
    jq -r "$q" <<<"$arr"
  fi
}
export -f gh

# shellcheck source=lib/run-registry.sh
. "$here/lib/run-registry.sh"

G() { git -c user.email=t@t -c user.name=t "$@"; }
mkrepo() {                      # <dir> <slug>: primary checkout + bare origin
  git init -q --bare "$1.origin.git"
  git init -q -b main "$1"
  G -C "$1" commit -q --allow-empty -m init
  printf 'tmp/\n.handoffs/\nnode_modules/\n.venv/\n' > "$1/.gitignore"
  G -C "$1" add .gitignore && G -C "$1" commit -q -m gitignore
  G -C "$1" remote add origin "$1.origin.git"
  G -C "$1" push -q origin main
  G -C "$1" config herdr.origin-slug "$2"
}
mkwt() {                        # <repo> <branch> <wt> [push=1]: one new commit
  G -C "$1" worktree add -q -b "$2" "$3" main
  G -C "$3" commit -q --allow-empty -m "$2 work"
  if [ "${4:-1}" = 1 ]; then
    G -C "$3" push -q origin "$2"
    G -C "$1" fetch -q origin
  fi
}
# Run from an unrelated scratch repo, like an operator's shell — the same
# for this code and any older revision run against this suite. The non-repo
# cwd case (launchd, cron, $HOME) has its own test in Section B.
CWD_REPO="$TMP/cwd-repo"; git init -q "$CWD_REPO"
AW() { (cd "$CWD_REPO" && bash "$here/archive-worktrees.sh" "$@" 2>&1); }
row() { printf '%s\n' "$1" | grep -F "$2 "; }      # <output> <wt>: that worktree's line
present() {                     # <label> <wt>
  [ -d "$2" ] && ok "$1: worktree still present" || bad "$1: worktree was REMOVED"
}

#######################################################################
# Section A: close-done-workers.sh's detached-HEAD close path
#######################################################################
printf '== Section A: close-done-workers.sh detached-HEAD close path ==\n'

A_TMP="$TMP/A"; mkdir -p "$A_TMP"
A_ORIGIN="$A_TMP/origin.git"
git init -q --bare "$A_ORIGIN"
A_WORK="$A_TMP/work"
git init -q -b main "$A_WORK"
G -C "$A_WORK" commit -q --allow-empty -m init
printf 'tmp/\n.handoffs/\n' > "$A_WORK/.gitignore"
git -C "$A_WORK" add .gitignore
G -C "$A_WORK" commit -q -m gitignore
git -C "$A_WORK" remote add origin "$A_ORIGIN"
git -C "$A_WORK" push -q origin main

for n in 42 43 44; do
  git -C "$A_WORK" switch -q -c "pr-$n" main
  G -C "$A_WORK" commit -q --allow-empty -m "pr $n work"
  git -C "$A_WORK" push -q origin "pr-$n:refs/pull/$n/head"
done
git -C "$A_WORK" switch -q main

A_SHA42=$(git -C "$A_WORK" rev-parse pr-42)
A_SHA43=$(git -C "$A_WORK" rev-parse pr-43)
A_SHA44=$(git -C "$A_WORK" rev-parse pr-44)

A_WT="$A_TMP/worktrees"; mkdir -p "$A_WT"
wtA="$A_WT/wtA"; git -C "$A_WORK" worktree add -q --detach "$wtA" "$A_SHA42"
wtB="$A_WT/wtB"; git -C "$A_WORK" worktree add -q --detach "$wtB" "$A_SHA42"
wtC="$A_WT/wtC"; git -C "$A_WORK" worktree add -q --detach "$wtC" "$A_SHA42"
wtD="$A_WT/wtD"; git -C "$A_WORK" worktree add -q --detach "$wtD" "$A_SHA43"
wtE="$A_WT/wtE"; git -C "$A_WORK" worktree add -q --detach "$wtE" "$A_SHA44"
wtF="$A_WT/wtF"; git -C "$A_WORK" worktree add -q --detach "$wtF" "$A_SHA42"

# negative 1: HEAD one commit ahead of refs/pull/42/head
G -C "$wtA" commit -q --allow-empty -m "extra local commit"
register_task runA1 taskA1 w c cp cb pD birthD-live "$A_WORK" "$wtA" "detached-A1" || bad "register taskA1"
set_task_state runA1 taskA1 running || bad "taskA1 -> running"
set_task_review_pr runA1 taskA1 org/repo 42 || bad "set_task_review_pr A1"
out=$(bash "$here/close-done-workers.sh" --task=taskA1 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'does not match refs/pull/42/head' \
  && ok "negative 1: HEAD one commit ahead of the ref HOLDs" || bad "negative 1 output: $out"
check "negative 1: task state untouched (dry run)" "$(read_task runA1 taskA1 | jq -r .state)" "running"

# negative 2: a dirty tree
printf 'uncommitted\n' > "$wtB/dirty.txt"
register_task runA2 taskA2 w c cp cb pD birthD-live "$A_WORK" "$wtB" "detached-A2" || bad "register taskA2"
set_task_state runA2 taskA2 running || bad "taskA2 -> running"
set_task_review_pr runA2 taskA2 org/repo 42 || bad "set_task_review_pr A2"
out=$(bash "$here/close-done-workers.sh" --task=taskA2 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'uncommitted/untracked' \
  && ok "negative 2: a dirty tree HOLDs" || bad "negative 2 output: $out"

# negative 2b (L4): an untracked file hidden by status.showUntrackedFiles=no
# still HOLDs — the check is git plumbing, not `git status`.
git -C "$wtB" config status.showUntrackedFiles no
out=$(bash "$here/close-done-workers.sh" --task=taskA2 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'uncommitted/untracked' \
  && ok "negative 2b: untracked file HOLDs even with status.showUntrackedFiles=no" || bad "negative 2b output: $out"
git -C "$wtB" config --unset status.showUntrackedFiles

# negative 3: an ignored .handoffs file with no archive (dry run never archives)
mkdir -p "$wtC/.handoffs"
printf 'reviewer notes\n' > "$wtC/.handoffs/notes.md"
register_task runA3 taskA3 w c cp cb pD birthD-live "$A_WORK" "$wtC" "detached-A3" || bad "register taskA3"
set_task_state runA3 taskA3 running || bad "taskA3 -> running"
set_task_review_pr runA3 taskA3 org/repo 42 || bad "set_task_review_pr A3"
out=$(bash "$here/close-done-workers.sh" --task=taskA3 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'not yet archived' \
  && ok "negative 3: ignored .handoffs file with no archive HOLDs" || bad "negative 3 output: $out"
[ -d "$HERDR_ARCHIVE_ROOT" ] && bad "negative 3: dry run must never create the archive root" \
  || ok "negative 3: dry run created nothing under HERDR_ARCHIVE_ROOT"

# negative 4: an OPEN PR
register_task runA4 taskA4 w c cp cb pD birthD-live "$A_WORK" "$wtD" "detached-A4" || bad "register taskA4"
set_task_state runA4 taskA4 running || bad "taskA4 -> running"
set_task_review_pr runA4 taskA4 org/repo 43 || bad "set_task_review_pr A4"
out=$(bash "$here/close-done-workers.sh" --task=taskA4 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'OPEN' \
  && ok "negative 4: an OPEN PR HOLDs" || bad "negative 4 output: $out"

# negative 4b (L4): --apply against an OPEN PR with an ignored artifact
# HOLDs WITHOUT archiving anything — GitHub is asked before the copy.
mkdir -p "$wtD/.handoffs"
printf 'notes on an open PR\n' > "$wtD/.handoffs/notes.md"
out=$(bash "$here/close-done-workers.sh" --apply --reason=shipped --task=taskA4 \
  --proof="https://github.com/org/repo/pull/42 a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'OPEN' \
  && ok "negative 4b: --apply against an OPEN PR HOLDs" || bad "negative 4b output: $out"
[ -z "$(find "$HERDR_ARCHIVE_ROOT" -maxdepth 2 -type d -name 'detached-pr-43-*' 2>/dev/null)" ] \
  && ok "negative 4b: no archive dir was left behind for the OPEN PR" \
  || bad "negative 4b: an archive dir was created for an OPEN PR"
check "negative 4b: task untouched" "$(read_task runA4 taskA4 | jq -r .state)" "running"

# negative 5: a CLOSED-unmerged PR without an explicit disposition
register_task runA5 taskA5 w c cp cb pD birthD-live "$A_WORK" "$wtE" "detached-A5" || bad "register taskA5"
set_task_state runA5 taskA5 running || bad "taskA5 -> running"
set_task_review_pr runA5 taskA5 org/repo 44 || bad "set_task_review_pr A5"
: > "$CALLS"
out=$(bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --task=taskA5 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'needs --reason=abandoned or superseded' \
  && ok "negative 5: CLOSED-unmerged PR without explicit disposition HOLDs" || bad "negative 5 output: $out"
check "negative 5: task untouched" "$(read_task runA5 taskA5 | jq -r .state)" "running"
grep -q '^pane close$' "$CALLS" && bad "negative 5: pane was closed despite the HOLD" \
  || ok "negative 5: no pane close for the HOLD"

# negative 6 (L3): --reason=abandoned on a BRANCH worktree (not a detached
# reviewer) HOLDs, even though the branch is clean and fully pushed.
wtL3="$A_WT/wtL3"
G -C "$A_WORK" worktree add -q -b l3-branch "$wtL3" main
G -C "$wtL3" push -q -u origin l3-branch
register_task runL3 taskL3 w c cp cb pD birthD-live "$A_WORK" "$wtL3" "branch-L3" || bad "register taskL3"
set_task_state runL3 taskL3 running || bad "taskL3 -> running"
out=$(bash "$here/close-done-workers.sh" --apply --reason=abandoned --task=taskL3 \
  --proof="https://github.com/org/repo/pull/42 a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && printf '%s' "$out" | grep -qi 'only for a detached-HEAD reviewer' \
  && ok "negative 6: --reason=abandoned on a branch worktree HOLDs" || bad "negative 6 output: $out"
check "negative 6: task untouched" "$(read_task runL3 taskL3 | jq -r .state)" "running"

# positive: MERGED, clean, recoverable, one ignored artifact -> apply
# archives+verifies it and closes
mkdir -p "$wtF/.handoffs"
printf 'reviewer notes for the merged PR\n' > "$wtF/.handoffs/notes.md"
exp_notes_sha=$(shasum -a 256 "$wtF/.handoffs/notes.md" | cut -d' ' -f1)
register_task runA6 taskA6 w c cp cb pD birthD-live "$A_WORK" "$wtF" "detached-A6" || bad "register taskA6"
set_task_state runA6 taskA6 running || bad "taskA6 -> running"
set_task_review_pr runA6 taskA6 org/repo 42 || bad "set_task_review_pr A6"
: > "$CALLS"
out=$(bash "$here/close-done-workers.sh" --apply --reason=shipped --task=taskA6 \
  --proof="https://github.com/org/repo/pull/42 a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "positive: apply exits 0" || bad "positive exit $rc: $out"
check "positive: task completed" "$(read_task runA6 taskA6 | jq -r .state)" "completed"
_ev() { sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.$1') FROM events WHERE task_id='taskA6' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';"; }
check "positive: reason recorded is shipped" "$(_ev reason)" "shipped"
check "positive (L4): detached-close tuple persisted in the event (state)" "$(_ev detail.detached_close.state)" "MERGED"
check "positive (L4): detached-close tuple persisted in the event (head)" "$(_ev detail.detached_close.head)" "$A_SHA42"
grep -q '^pane close$' "$CALLS" && ok "positive: pane close was called" || bad "positive: no pane close: $(cat "$CALLS")"
manifest_path=$(printf '%s\n' "$out" | sed -n 's/.*archive=\([^ ]*\).*/\1/p' | head -1)
if [ -n "$manifest_path" ] && [ -f "$manifest_path" ]; then
  ok "positive: archive manifest exists at $manifest_path"
  _manifest_has "$manifest_path" "$exp_notes_sha" ".handoffs/notes.md" \
    && ok "positive: manifest records the ignored file's correct sha256" \
    || bad "positive: manifest missing/wrong sha256: $(cat "$manifest_path")"
  copy_path="$(dirname "$manifest_path")/files/.handoffs/notes.md"
  [ -f "$copy_path" ] && [ "$(shasum -a 256 "$copy_path" | cut -d' ' -f1)" = "$exp_notes_sha" ] \
    && ok "positive: archived copy's own sha256 matches" \
    || bad "positive: archived copy missing or wrong: $copy_path"
else
  bad "positive: no archive manifest path found in output: $out"
fi

#######################################################################
# Section B: archive-worktrees.sh
#######################################################################
printf '\n== Section B: archive-worktrees.sh ==\n'

B_TMP="$TMP/B"; mkdir -p "$B_TMP"
B_PRIMARY="$B_TMP/demo"
mkrepo "$B_PRIMARY" rtree/demo
B_ORIGIN="$B_PRIMARY.origin.git"

# 1. feat-merged: clean, pushed, MERGED PR; ignored notes + regenerable dirs.
wtMerged="$WTROOT/demo-feat-merged"; mkwt "$B_PRIMARY" feat-merged "$wtMerged"
mkdir -p "$wtMerged/tmp" "$wtMerged/node_modules/pkg" "$wtMerged/.venv/lib"
printf 'merged notes\n' > "$wtMerged/tmp/notes.md"
printf 'module.exports = 1\n' > "$wtMerged/node_modules/pkg/index.js"
printf 'x = 1\n' > "$wtMerged/.venv/lib/x.py"
exp_merged_notes_sha=$(shasum -a 256 "$wtMerged/tmp/notes.md" | cut -d' ' -f1)

# 2. feat-livepane: MERGED-looking but a non-terminal registry row owns it.
wtLivepane="$WTROOT/demo-feat-livepane"; mkwt "$B_PRIMARY" feat-livepane "$wtLivepane"
register_task runB2 taskB2 w c cp cb pLive birthLive "$B_PRIMARY" "$wtLivepane" "live-pane-owner" || bad "register taskB2"
set_task_state runB2 taskB2 running || bad "taskB2 -> running"

# 3. feat-unreachable: a local-only commit, never pushed, no PR.
wtUnreachable="$WTROOT/demo-feat-unreachable"; mkwt "$B_PRIMARY" feat-unreachable "$wtUnreachable" 0

# 4. feat-pullonly: pushed ONLY as refs/pull/4/head, never as a branch.
wtPullonly="$WTROOT/demo-feat-pullonly"; mkwt "$B_PRIMARY" feat-pullonly "$wtPullonly" 0
G -C "$wtPullonly" push -q origin HEAD:refs/pull/4/head

# 5. feat-open: pushed, OPEN PR.
wtOpen="$WTROOT/demo-feat-open"; mkwt "$B_PRIMARY" feat-open "$wtOpen"

# 6. feat-closed: pushed, CLOSED-unmerged PR.
wtClosed="$WTROOT/demo-feat-closed"; mkwt "$B_PRIMARY" feat-closed "$wtClosed"

# 7. feat-dirty: pushed, MERGED PR, plus tracked/untracked/ignored content.
wtDirty="$WTROOT/demo-feat-dirty"
G -C "$B_PRIMARY" worktree add -q -b feat-dirty "$wtDirty" main
printf 'original\n' > "$wtDirty/tracked.txt"
G -C "$wtDirty" add tracked.txt && G -C "$wtDirty" commit -q -m "add tracked.txt"
G -C "$wtDirty" push -q origin feat-dirty
printf 'original\nmore\n' > "$wtDirty/tracked.txt"
printf 'untracked content\n' > "$wtDirty/untracked.txt"
mkdir -p "$wtDirty/tmp/sub"
printf 'ignored content\n' > "$wtDirty/tmp/sub/ignored.txt"
exp_tracked_sha=$(shasum -a 256 "$wtDirty/tracked.txt" | cut -d' ' -f1)
exp_untracked_sha=$(shasum -a 256 "$wtDirty/untracked.txt" | cut -d' ' -f1)
exp_ignored_sha=$(shasum -a 256 "$wtDirty/tmp/sub/ignored.txt" | cut -d' ' -f1)

# 8. feat-nopr (H6): pushed, clean, NO PR at all — never inferred removable.
wtNopr="$WTROOT/demo-feat-nopr"; mkwt "$B_PRIMARY" feat-nopr "$wtNopr"

# 9. feat-stale (M1): pushed + fetched, then deleted on origin; the local
#    remote-tracking ref still claims it — a stale cache, not the remote.
wtStale="$WTROOT/demo-feat-stale"; mkwt "$B_PRIMARY" feat-stale "$wtStale"
git --git-dir="$B_ORIGIN" update-ref -d refs/heads/feat-stale
git -C "$B_PRIMARY" show-ref -q --verify refs/remotes/origin/feat-stale \
  && ok "B setup: feat-stale's remote-tracking ref survives (the stale cache)" \
  || bad "B setup: feat-stale remote-tracking ref missing — M1 fixture invalid"

# 10. feat-disk (M2): MERGED, clean — removable only with room on disk.
wtDisk="$WTROOT/demo-feat-disk"; mkwt "$B_PRIMARY" feat-disk "$wtDisk"

primary_still_main() {
  [ "$(git -C "$B_PRIMARY" symbolic-ref -q --short HEAD 2>/dev/null)" = main ]
}

printf '== archive-worktrees.sh dry run: previews every scenario, mutates nothing ==\n'
out=$(AW "$B_PRIMARY")
row "$out" "$wtLivepane" | grep -q HOLD && row "$out" "$wtLivepane" | grep -qi 'running/blocked' \
  && ok "B: feat-livepane HOLDs, naming the live task" || bad "B dry-run feat-livepane: $out"
row "$out" "$wtUnreachable" | grep -q HOLD && row "$out" "$wtUnreachable" | grep -qi 'no ref origin has' \
  && ok "B: feat-unreachable HOLDs (no ref on origin)" || bad "B dry-run feat-unreachable: $out"
row "$out" "$wtOpen" | grep -q HOLD && row "$out" "$wtOpen" | grep -qi OPEN \
  && ok "B: feat-open HOLDs (OPEN PR)" || bad "B dry-run feat-open: $out"
row "$out" "$wtClosed" | grep -q HOLD && row "$out" "$wtClosed" | grep -qi 'disposition=abandoned|superseded' \
  && ok "B: feat-closed HOLDs (CLOSED, no --disposition)" || bad "B dry-run feat-closed: $out"
row "$out" "$wtMerged" | grep -q '^  archive' \
  && ok "B: feat-merged previews archivable" || bad "B dry-run feat-merged: $out"
row "$out" "$wtMerged" | grep -q 'disposition=merged (1 file(s), 2 regenerable dir(s) excluded' \
  && ok "B (M2): feat-merged preview copies 1 file and excludes node_modules/.venv" || bad "B dry-run feat-merged counts: $out"
row "$out" "$wtPullonly" | grep -q '^  archive' \
  && ok "B: feat-pullonly reachable via origin's refs/pull/4/head, previews archivable" \
  || bad "B dry-run feat-pullonly: $out"
row "$out" "$wtDirty" | grep -q HOLD && row "$out" "$wtDirty" | grep -qi 'dirty: uncommitted work' \
  && ok "B: feat-dirty HOLDs in preview (dirty tracked/untracked work)" || bad "B dry-run feat-dirty: $out"
row "$out" "$wtNopr" | grep -q HOLD && row "$out" "$wtNopr" | grep -qi 'no PR on feat-nopr' \
  && ok "B (H6): a branch with no PR HOLDs — no inferred 'reachable' disposition" || bad "B dry-run feat-nopr: $out"
row "$out" "$wtStale" | grep -q HOLD && row "$out" "$wtStale" | grep -qi 'no ref origin has' \
  && ok "B (M1): a branch deleted on origin HOLDs despite a stale remote-tracking ref" || bad "B dry-run feat-stale: $out"
printf '%s\n' "$out" | grep -qF "$B_PRIMARY " \
  && bad "B dry-run: the PRIMARY checkout was printed as a row" \
  || ok "B dry-run: the primary checkout was never printed as a row"
[ -d "$HERDR_ARCHIVE_ROOT/demo" ] && bad "B dry-run: created an archive dir" \
  || ok "B dry-run: created nothing under the archive root"

printf '== H4: a scope without exactly one repo argument refuses before acting ==\n'
out=$(AW --apply --branch=feat-open --disposition=abandoned); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'exactly one repo argument' \
  && ok "B (H4): --branch with no repo argument refuses" || bad "B H4 no-repo: rc=$rc $out"
out=$(AW --apply --worktree="$wtOpen" --disposition=abandoned); rc=$?
[ "$rc" -ne 0 ] && ok "B (H4): --worktree with no repo argument refuses" || bad "B H4 --worktree no-repo: rc=$rc $out"
out=$(AW --apply --branch=no-such-branch --disposition=abandoned "$B_PRIMARY"); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'matches 0 linked worktrees' \
  && ok "B (H4): a scope matching no worktree refuses" || bad "B H4 zero-match: rc=$rc $out"
present "B (H4): feat-open after the refused scoped runs" "$wtOpen"

printf '== M2: insufficient free disk HOLDs; H6: a disposition contradicting GitHub HOLDs ==\n'
out=$(HERDR_ARCHIVE_MIN_FREE_KB=999999999999 AW --apply --branch=feat-disk "$B_PRIMARY")
row "$out" "$wtDisk" | grep -q HOLD && row "$out" "$wtDisk" | grep -qi 'insufficient disk' \
  && ok "B (M2): not enough free disk HOLDs" || bad "B disk: $out"
present "B (M2): feat-disk with no disk room" "$wtDisk"
out=$(AW --apply --branch=feat-disk --disposition=abandoned "$B_PRIMARY")
row "$out" "$wtDisk" | grep -q HOLD && row "$out" "$wtDisk" | grep -qi 'contradicts' \
  && ok "B (H6): --disposition=abandoned on a MERGED branch HOLDs" || bad "B contradiction: $out"
present "B (H6): feat-disk after a contradicting disposition" "$wtDisk"

printf '== the bundle is verified against the source repo, not the caller cwd ==\n'
mkdir -p "$TMP/nonrepo"
out=$(cd "$TMP/nonrepo" && bash "$here/archive-worktrees.sh" --apply --branch=feat-disk "$B_PRIMARY" 2>&1)
[ ! -d "$wtDisk" ] && ok "B: archive+remove works from a non-repo cwd" || bad "B non-repo cwd: $out"

printf '== archive-worktrees.sh --apply (batch, unscoped) ==\n'
out=$(AW --apply "$B_PRIMARY")
[ ! -d "$wtMerged" ] && ok "B apply: feat-merged removed" || bad "B apply: feat-merged still present: $out"
[ ! -d "$wtPullonly" ] && ok "B apply: feat-pullonly removed" || bad "B apply: feat-pullonly still present: $out"
row "$out" "$wtDirty" | grep -q HOLD && row "$out" "$wtDirty" | grep -qi 'dirty: uncommitted work' \
  && ok "B apply: a dirty worktree HOLDs in a batch apply" || bad "B apply: feat-dirty not held: $out"
present "B apply: feat-dirty" "$wtDirty"
[ "$(shasum -a 256 "$wtDirty/tracked.txt" 2>/dev/null | cut -d' ' -f1)" = "$exp_tracked_sha" ] \
  && ok "B apply: feat-dirty's tracked.txt is byte-for-byte untouched" || bad "B apply: feat-dirty's tracked.txt was modified"
[ -f "$wtDirty/untracked.txt" ] && ok "B apply: feat-dirty's untracked.txt still present" \
  || bad "B apply: feat-dirty's untracked.txt is gone"
[ -z "$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-dirty-*' 2>/dev/null)" ] \
  && ok "B apply: no archive directory was created for the dirty worktree" \
  || bad "B apply: an archive directory was created for the dirty worktree despite the HOLD"
present "B apply: feat-livepane (live)" "$wtLivepane"
present "B apply: feat-unreachable (unreachable)" "$wtUnreachable"
present "B apply: feat-open (OPEN PR)" "$wtOpen"
present "B apply: feat-closed (no disposition)" "$wtClosed"
present "B apply (H6): feat-nopr (no PR, no disposition)" "$wtNopr"
present "B apply (M1): feat-stale (deleted on origin)" "$wtStale"
[ -d "$B_PRIMARY/.git" ] && primary_still_main && ok "B apply: the primary checkout is untouched (still on main)" \
  || bad "B apply: the primary checkout was disturbed"

dest_merged=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-merged-*' 2>/dev/null | head -1)
m="$dest_merged/MANIFEST.sha256"
if [ -n "$dest_merged" ] && [ -f "$m" ]; then
  _manifest_has "$m" "$exp_merged_notes_sha" "tmp/notes.md" \
    && ok "B (M2): ignored tmp/notes.md copied and hashed" || bad "B (M2): tmp/notes.md missing: $(cat "$m")"
  awk -F'\t' '$1=="EXCLUDED" && $2=="1" && $3=="node_modules/" {f=1} END{exit !f}' "$m" \
    && awk -F'\t' '$1=="EXCLUDED" && $2=="1" && $3==".venv/" {f=1} END{exit !f}' "$m" \
    && ok "B (M2): node_modules/ and .venv/ recorded in the manifest as EXCLUDED" \
    || bad "B (M2): EXCLUDED lines missing: $(cat "$m")"
  [ ! -e "$dest_merged/files/node_modules" ] && [ ! -e "$dest_merged/files/.venv" ] \
    && ok "B (M2): node_modules/.venv were not copied" || bad "B (M2): regenerable dirs were copied"
else
  bad "B (M2): no manifest for feat-merged under $HERDR_ARCHIVE_ROOT/demo"
fi
dest_pullonly=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-pullonly-*' 2>/dev/null | head -1)
[ -n "$dest_pullonly" ] && grep -qF 'disposition=merged' "$dest_pullonly/DISPOSITION.txt" 2>/dev/null \
  && ok "B: feat-pullonly DISPOSITION.txt records merged" || bad "B: feat-pullonly disposition record missing/wrong"

printf '== scoped explicit dispositions ==\n'
out=$(AW --apply --branch=feat-closed --disposition=abandoned "$B_PRIMARY")
[ ! -d "$wtClosed" ] && ok "B: feat-closed removed once an explicit --disposition was given" || bad "B: feat-closed still present: $out"
dest_closed=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-closed-*' 2>/dev/null | head -1)
[ -n "$dest_closed" ] && grep -qF 'disposition=abandoned' "$dest_closed/DISPOSITION.txt" 2>/dev/null \
  && ok "B: feat-closed DISPOSITION.txt records the explicit abandoned disposition" \
  || bad "B: feat-closed disposition record missing/wrong"
[ -d "$wtLivepane" ] && [ -d "$wtUnreachable" ] && [ -d "$wtOpen" ] && [ -d "$wtDirty" ] && [ -d "$wtNopr" ] \
  && ok "B: the scoped --branch=feat-closed apply touched nothing else" \
  || bad "B: the scoped --branch=feat-closed apply removed an unrelated worktree"
out=$(AW --apply --branch=feat-nopr --disposition=superseded "$B_PRIMARY")
[ ! -d "$wtNopr" ] && ok "B (H6): feat-nopr removed only with an explicit --disposition=superseded" || bad "B: feat-nopr still present: $out"
dest_nopr=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-nopr-*' 2>/dev/null | head -1)
[ -n "$dest_nopr" ] && grep -qF 'disposition=superseded' "$dest_nopr/DISPOSITION.txt" 2>/dev/null \
  && ok "B (H6): feat-nopr DISPOSITION.txt records superseded" || bad "B: feat-nopr disposition record missing/wrong"

printf '== archive-worktrees.sh --apply --branch=feat-dirty --include-dirty: the explicit opt-in ==\n'
out=$(AW --apply --branch=feat-dirty --include-dirty "$B_PRIMARY")
dest_dirty=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-dirty-*' 2>/dev/null | head -1)
if [ -n "$dest_dirty" ] && [ -f "$dest_dirty/MANIFEST.sha256" ]; then
  manifest_dirty="$dest_dirty/MANIFEST.sha256"
  ok "B: --include-dirty archives the named worktree, manifest exists"
  _manifest_has "$manifest_dirty" "$exp_tracked_sha" "tracked.txt" \
    && ok "B: manifest records the modified TRACKED file's sha256" || bad "B: tracked.txt missing from manifest: $(cat "$manifest_dirty")"
  _manifest_has "$manifest_dirty" "$exp_untracked_sha" "untracked.txt" \
    && ok "B: manifest records the UNTRACKED file's sha256" || bad "B: untracked.txt missing from manifest"
  _manifest_has "$manifest_dirty" "$exp_ignored_sha" "tmp/sub/ignored.txt" \
    && ok "B: manifest records the IGNORED file's sha256" || bad "B: tmp/sub/ignored.txt missing from manifest"
  [ -f "$dest_dirty/branch.bundle" ] && git -C "$B_PRIMARY" bundle verify "$dest_dirty/branch.bundle" >/dev/null 2>&1 \
    && ok "B: feat-dirty's git bundle exists and verifies" || bad "B: feat-dirty bundle missing or fails verify"
  grep -qF 'disposition=merged' "$dest_dirty/DISPOSITION.txt" 2>/dev/null \
    && ok "B: feat-dirty DISPOSITION.txt records merged" || bad "B: feat-dirty DISPOSITION.txt wrong/missing"
else
  bad "B: no archive manifest found for feat-dirty under $HERDR_ARCHIVE_ROOT/demo after --include-dirty: $out"
fi
[ -d "$wtDirty" ] && row "$out" "$wtDirty" | grep -q LEFTOVER \
  && ok "B: --include-dirty archives but git worktree remove still correctly refuses (never --force)" \
  || bad "B: feat-dirty outcome wrong after --include-dirty (expected archived+LEFTOVER): $out"

[ -d "$B_PRIMARY/.git" ] && primary_still_main \
  && ok "B: the primary checkout is STILL untouched after every apply run" \
  || bad "B: the primary checkout was disturbed"

#######################################################################
# Section P: review r1 probes P1-P8 as permanent real negatives. Each one
# removed (or mis-previewed) a worktree on 6f442a0b.
#######################################################################
printf '\n== Section P: review r1 probes ==\n'
P_TMP="$TMP/P"; mkdir -p "$P_TMP"

printf '== P1: gh API down while an OPEN PR exists ==\n'
R="$P_TMP/p1"; mkrepo "$R" probe/p1; W="$WTROOT/p1-open"; mkwt "$R" p1-open "$W"
out=$(AW "$R")
row "$out" "$W" | grep -q 'HOLD.*OPEN' && ok "P1 control: gh up, the OPEN PR HOLDs" || bad "P1 control: $out"
out=$(GH_DOWN=1 AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'gh PR lookup failed' \
  && ok "P1: gh down HOLDs with the reason, never 'no PR'" || bad "P1 output: $out"
present "P1" "$W"

printf '== P2: live pane cwd beneath the worktree / behind a symlinked ancestor ==\n'
R="$P_TMP/p2"; mkrepo "$R" probe/p2
W="$WTROOT/p2-sub"; mkwt "$R" p2-sub "$W"; mkdir -p "$W/src"
Wl="$WTROOT/p2-link"; mkwt "$R" p2-link "$Wl"
ln -s "$WTROOT" "$TMP/wtlink"
pj=$(jq -nc --arg a "$W/src" --arg b "$TMP/wtlink/p2-link" \
  '{result:{panes:[{pane_id:"x1",cwd:$a},{pane_id:"x2",foreground_cwd:$b}]}}')
out=$(PANES_JSON="$pj" AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'live pane cwd' \
  && ok "P2: pane cwd <wt>/src HOLDs" || bad "P2 sub output: $out"
row "$out" "$Wl" | grep -q HOLD && row "$out" "$Wl" | grep -qi 'live pane cwd' \
  && ok "P2: pane cwd through a symlinked ancestor HOLDs" || bad "P2 link output: $out"
present "P2 (cwd = <wt>/src)" "$W"
present "P2 (cwd via symlink)" "$Wl"
pj='{"result":{"panes":[{"pane_id":"x3"}]}}'
out=$(PANES_JSON="$pj" AW "$R")
row "$out" "$W" | grep -qi 'HOLD.*report no cwd' \
  && ok "P2: a pane that reports no cwd HOLDs everything (unverifiable)" || bad "P2 no-cwd output: $out"

printf '== P3: branch carries an older MERGED PR AND a newer OPEN PR ==\n'
R="$P_TMP/p3"; mkrepo "$R" probe/p3; W="$WTROOT/p3-reused"; mkwt "$R" p3-reused "$W"
out=$(AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'pull/32 is OPEN' \
  && ok "P3: any OPEN PR HOLDs despite an older MERGED one" || bad "P3 output: $out"
present "P3" "$W"

printf '== P4: registry unreadable while a task is running in the worktree ==\n'
R="$P_TMP/p4"; mkrepo "$R" probe/p4; W="$WTROOT/p4-live"; mkwt "$R" p4-live "$W"
register_task run4 task4 w c cp cb p4 b4 "$R" "$W" p4-live >/dev/null || bad "P4: register_task failed"
set_task_state run4 task4 running >/dev/null || bad "P4: set_task_state failed"
out=$(AW "$R")
row "$out" "$W" | grep -q 'HOLD.*task task4' && ok "P4 control: readable registry HOLDs the live task" || bad "P4 control: $out"
chmod 000 "$(registry_db)"
out=$(AW --apply "$R")
chmod 600 "$(registry_db)"
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'registry' \
  && ok "P4: unreadable registry HOLDs with the reason" || bad "P4 output: $out"
present "P4" "$W"

printf '== P5: --branch scope with no repo argument spanning two repos ==\n'
CR="$HERDR_CODE_ROOT"
mkrepo "$CR/alpha" probe/alpha; mkrepo "$CR/beta" probe/beta
Wa="$WTROOT/alpha-shared"; Wb="$WTROOT/beta-shared"
mkwt "$CR/alpha" review/shared "$Wa"; mkwt "$CR/beta" review/shared "$Wb"
out=$(AW --apply --branch=review/shared --disposition=abandoned); rc=$?
[ "$rc" -ne 0 ] && ok "P5: refused (exit $rc) without a repo argument" || bad "P5: exit 0: $out"
present "P5 alpha" "$Wa"; present "P5 beta" "$Wb"
out=$(AW --apply --branch=review/shared --disposition=abandoned "$CR/alpha")
[ ! -d "$Wa" ] && [ -d "$Wb" ] && ok "P5: with one repo argument only that repo's worktree is removed" \
  || bad "P5 scoped: alpha=$([ -d "$Wa" ] && echo present || echo gone) beta=$([ -d "$Wb" ] && echo present || echo gone) $out"

printf '== P6: dirty linked worktree nested inside another worktree'"'"'s ignored tmp/ ==\n'
R="$P_TMP/p6"; mkrepo "$R" probe/p6; P="$WTROOT/p6-parent"; mkwt "$R" p6-parent "$P"
N="$P/tmp/nested"; mkwt "$R" p6-nested "$N"
printf 'irreplaceable uncommitted work\n' > "$N/precious.txt"
out=$(AW "$R")
row "$out" "$P" | grep -q HOLD && row "$out" "$P" | grep -qi 'nested git' \
  && ok "P6 (L2): the parent previews as HOLD (nested worktree), not archive" || bad "P6 preview: $out"
out=$(AW --apply "$R")
present "P6 parent" "$P"; present "P6 nested (dirty)" "$N"
[ -f "$N/precious.txt" ] && ok "P6: precious.txt intact" || bad "P6: precious.txt gone"

printf '== P7 (C1): never-archivable checkouts ==\n'
R="$P_TMP/p7"; mkrepo "$R" probe/p7
Wout="$P_TMP/outside/app"; mkdir -p "$P_TMP/outside"
G -C "$R" worktree add -q --detach "$Wout" main
Wapp="$WTROOT/p7-app"; G -C "$R" worktree add -q --detach "$Wapp" main
Wdet="$WTROOT/p7-detached"; G -C "$R" worktree add -q --detach "$Wdet" main
out=$(HERDR_APP_DIR="$Wapp" AW --apply "$R")
row "$out" "$Wout" | grep -q HOLD && row "$out" "$Wout" | grep -qi 'outside the allowed worktree roots' \
  && ok "P7: a detached checkout outside the allowed roots HOLDs" || bad "P7 outside: $out"
row "$out" "$Wapp" | grep -q HOLD && row "$out" "$Wapp" | grep -qi 'protected path' \
  && ok "P7: \$HERDR_APP_DIR HOLDs as a protected path" || bad "P7 app: $out"
row "$out" "$Wdet" | grep -q HOLD && row "$out" "$Wdet" | grep -qi 'detached HEAD — needs --worktree' \
  && ok "P7 (H6): a detached HEAD with no explicit disposition HOLDs" || bad "P7 detached: $out"
present "P7 outside roots" "$Wout"; present "P7 app dir" "$Wapp"; present "P7 detached" "$Wdet"
out=$(HERDR_APP_DIR="$Wapp" AW --apply --worktree="$Wout" --disposition=abandoned "$R")
row "$out" "$Wout" | grep -qi 'HOLD.*outside the allowed' && ok "P7: an explicit disposition cannot override the root allowlist" || bad "P7 outside explicit: $out"
out=$(HERDR_APP_DIR="$Wapp" AW --apply --worktree="$Wapp" --disposition=abandoned "$R")
row "$out" "$Wapp" | grep -qi 'HOLD.*protected path' && ok "P7: an explicit disposition cannot override the protected list" || bad "P7 app explicit: $out"
present "P7 outside roots (explicit)" "$Wout"; present "P7 app dir (explicit)" "$Wapp"
out=$(HERDR_APP_DIR="$Wapp" AW --apply --worktree="$Wdet" --disposition=superseded "$R")
[ ! -d "$Wdet" ] && ok "P7 (H6): a detached HEAD is removed only via --worktree + explicit disposition" || bad "P7 detached explicit: $out"
dest_det=$(find "$HERDR_ARCHIVE_ROOT/p7" -maxdepth 1 -type d -name 'detached-*' 2>/dev/null | head -1)
[ -n "$dest_det" ] && grep -qF 'disposition=superseded' "$dest_det/DISPOSITION.txt" 2>/dev/null \
  && ok "P7 (H6): detached DISPOSITION.txt records superseded" || bad "P7: detached disposition record missing/wrong"

printf '== P8: archive root not writable (partial-copy analog) ==\n'
R="$P_TMP/p8"; mkrepo "$R" probe/p8; W="$WTROOT/p8-merged"; mkwt "$R" p8-merged "$W"
mkdir -p "$W/tmp"; printf 'notes\n' > "$W/tmp/notes.md"
RO="$P_TMP/ro-archive"; mkdir -p "$RO"; chmod 555 "$RO"
out=$(HERDR_ARCHIVE_ROOT="$RO" AW --apply "$R")
chmod 755 "$RO"
row "$out" "$W" | grep -q 'REFUSED.*archiving failed: could not create' \
  && ok "P8 (L1): REFUSED with the actual reason, not an empty one" || bad "P8 output: $out"
present "P8" "$W"

#######################################################################
# Section R: review r2 probes as permanent real negatives. N4a, N6a, N6c,
# N9, N9b, N11, N12, N15 and L5 each REMOVED a worktree that must be kept
# on 64a0dc48; L1 and L3 mislabelled or always-LEFTOVER'd one.
#######################################################################
printf '\n== Section R: review r2 probes ==\n'
R_TMP="$TMP/R"; mkdir -p "$R_TMP" "$TMP/bin"
# A pass-through shasum: the archive copy hashes each file as it copies it,
# so the first call is mid-archive. HOOK_FILE, when set and present, runs
# ONCE there (it is renamed first) — the same mechanism review r2 used.
REAL_SHASUM=$(command -v shasum)
cat > "$TMP/bin/shasum" <<EOF
#!/bin/bash
if [ -n "\${HOOK_FILE:-}" ] && [ -f "\$HOOK_FILE" ]; then
  mv -f "\$HOOK_FILE" "\$HOOK_FILE.fired" && bash "\$HOOK_FILE.fired"
fi
exec "$REAL_SHASUM" "\$@"
EOF
chmod +x "$TMP/bin/shasum"
HOOKPATH="$TMP/bin:$PATH"
M=abababababababababababababababababababab
GH_PRS="$GH_PRS
probe/n4#40 n4-merged MERGED $M
probe/n6a#61 n6a-merged MERGED $M
probe/n6c#63 n6c-merged MERGED $M
probe/n9#91 n9-live MERGED $M
probe/n11#111 n11-busy MERGED $M
probe/n12#121 n12-fg MERGED $M
probe/n15#151 n15-merged MERGED $M
probe/l1#171 l1-a MERGED $M
probe/l3#173 l3-locked MERGED $M"
note() { mkdir -p "$1/tmp"; printf '%s\n' "${2:-notes}" > "$1/tmp/notes.md"; }
_locked_by_us() {               # <wt>; stdin: worktree list --porcelain. Locked by archive-worktrees.sh?
  awk -v w="$1" '/^worktree /{cur=substr($0,10)} /^locked archive-worktrees\.sh /{ if (cur == w) f=1 } END{exit !f}'
}
LOCKDIR="$HERDR_RUN_STATE_DIR/archive-worktrees.lock"

printf '== N6a (H1): a re-spawn writes .handoffs/SPEC.md + a pane + a running task mid-archive ==\n'
R="$R_TMP/n6a"; mkrepo "$R" probe/n6a; W="$WTROOT/n6a-merged"; mkwt "$R" n6a-merged "$W"; note "$W"
PF="$R_TMP/n6a-panes.json"; printf '%s\n' "$PANES_JSON" > "$PF"
cat > "$R_TMP/n6a-hook.sh" <<EOF
git -C "$R" worktree list --porcelain > "$R_TMP/n6a-porcelain.txt"
mkdir -p "$W/.handoffs"; echo 'SPEC written by a re-spawn mid-run' > "$W/.handoffs/SPEC.md"
jq -nc --arg c "$W" '{result:{panes:[{pane_id:"spawned",cwd:\$c}]}}' > "$PF"
. "$here/lib/run-registry.sh"
register_task run6 task6 w c cp cb p6 b6 "$R" "$W" n6a >/dev/null && set_task_state run6 task6 running >/dev/null
EOF
out=$(PATH="$HOOKPATH" HOOK_FILE="$R_TMP/n6a-hook.sh" PANES_FILE="$PF" AW --apply "$R")
[ -f "$R_TMP/n6a-hook.sh.fired" ] && ok "N6a: the mid-archive hook fired" || bad "N6a: hook never fired: $out"
row "$out" "$W" | grep -q 'REFUSED.*changed while archiving' \
  && ok "N6a: a pane/task/SPEC appearing mid-archive REFUSES the remove" || bad "N6a output: $out"
present "N6a" "$W"
[ -f "$W/.handoffs/SPEC.md" ] && ok "N6a: the re-spawn's SPEC.md survives" || bad "N6a: SPEC.md was destroyed"
_locked_by_us "$W" < "$R_TMP/n6a-porcelain.txt" \
  && ok "N6a: the worktree was git-worktree-locked while archiving" || bad "N6a: not locked mid-archive"
git -C "$R" worktree list --porcelain | _locked_by_us "$W" \
  && bad "N6a: still locked after the REFUSED" || ok "N6a: unlocked again after the REFUSED"
[ -n "$(find "$HERDR_ARCHIVE_ROOT/n6a" -maxdepth 1 -type d -name 'n6a-merged-*.partial' 2>/dev/null)" ] \
  && [ -z "$(find "$HERDR_ARCHIVE_ROOT/n6a" -maxdepth 1 -type d -name 'n6a-merged-*' ! -name '*.partial' 2>/dev/null)" ] \
  && ok "N6a (L2): the refused archive is left as .partial, never a finished-looking one" \
  || bad "N6a (L2): archive dirs: $(find "$HERDR_ARCHIVE_ROOT/n6a" -maxdepth 1 2>/dev/null | tr '\n' ' ')"

printf '== N6c (H1): only an IGNORED file appears mid-archive (git remove would delete it) ==\n'
R="$R_TMP/n6c"; mkrepo "$R" probe/n6c; W="$WTROOT/n6c-merged"; mkwt "$R" n6c-merged "$W"; note "$W"
printf 'mkdir -p "%s/.handoffs"; echo late > "%s/.handoffs/SPEC.md"\n' "$W" "$W" > "$R_TMP/n6c-hook.sh"
out=$(PATH="$HOOKPATH" HOOK_FILE="$R_TMP/n6c-hook.sh" AW --apply "$R")
row "$out" "$W" | grep -q 'REFUSED.*files changed during archiving' \
  && ok "N6c: a new ignored file mid-archive REFUSES the remove" || bad "N6c output: $out"
present "N6c" "$W"
[ -f "$W/.handoffs/SPEC.md" ] && ok "N6c: the late SPEC.md survives" || bad "N6c: the late SPEC.md was destroyed"

printf '== N9 (H2): HERDR_RUN_STATE_DIR points at a missing / empty registry while a task runs ==\n'
R="$R_TMP/n9"; mkrepo "$R" probe/n9; W="$WTROOT/n9-live"; mkwt "$R" n9-live "$W"; note "$W"
register_task run9 task9 w c cp cb p9 b9 "$R" "$W" n9-live >/dev/null || bad "N9: register_task failed"
set_task_state run9 task9 running >/dev/null || bad "N9: set_task_state failed"
out=$(AW "$R")
row "$out" "$W" | grep -q 'HOLD.*task task9' && ok "N9 control: the real registry HOLDs the live task" || bad "N9 control: $out"
out=$(HERDR_RUN_STATE_DIR="$R_TMP/runs-typo" AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'does not exist' \
  && ok "N9: a missing registry HOLDs (never 'nobody is working')" || bad "N9 output: $out"
present "N9 (missing registry)" "$W"
[ ! -e "$R_TMP/runs-typo" ] && ok "N9: the tool created no registry dir" || bad "N9: created $(ls "$R_TMP/runs-typo" 2>&1 | tr '\n' ' ')"
mkdir -p "$R_TMP/runs-empty"
HERDR_RUN_STATE_DIR="$R_TMP/runs-empty" bash -c '. "$1/lib/run-registry.sh" && registry_init' _ "$here" >/dev/null 2>&1 \
  || bad "N9b: could not create the empty registry fixture"
out=$(HERDR_RUN_STATE_DIR="$R_TMP/runs-empty" AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'never held a task' \
  && ok "N9b: an existing but never-used registry HOLDs" || bad "N9b output: $out"
present "N9b (empty registry)" "$W"

printf '== N11 (H3): a non-herdr process has its cwd inside the worktree ==\n'
R="$R_TMP/n11"; mkrepo "$R" probe/n11; W="$WTROOT/n11-busy"; mkwt "$R" n11-busy "$W"; note "$W"
( cd "$W" && exec sleep 300 ) & spid=$!
sleep 1
out=$(AW --apply "$R")
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi "process $spid has its cwd" \
  && ok "N11: a plain process in the worktree HOLDs it" || bad "N11 output: $out"
present "N11" "$W"

printf '== N12 (M1): pane cwd is the worktree, foreground_cwd elsewhere ==\n'
R="$R_TMP/n12"; mkrepo "$R" probe/n12; W="$WTROOT/n12-fg"; mkwt "$R" n12-fg "$W"; note "$W"
pj=$(jq -nc --arg c "$W" '{result:{panes:[{pane_id:"f1",cwd:$c,foreground_cwd:"/tmp"}]}}')
out=$(PANES_JSON="$pj" AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'live pane cwd' \
  && ok "N12: a pane whose shell cwd is the worktree HOLDs it" || bad "N12 output: $out"
present "N12" "$W"
out=$(PANES_JSON='{"result":{"panes":[]}}' AW "$R")
row "$out" "$W" | grep -qi 'HOLD.*returned no panes' \
  && ok "N12 (H2): an empty pane list HOLDs (wrong herdr server)" || bad "N12 empty list: $out"

printf '== N15 (M2): archive root inside the worktree being removed, or relative ==\n'
R="$R_TMP/n15"; mkrepo "$R" probe/n15; W="$WTROOT/n15-merged"; mkwt "$R" n15-merged "$W"; note "$W" "only copy"
out=$(HERDR_ARCHIVE_ROOT="$W/tmp/archive" AW --apply "$R")
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'archive root .* is inside this worktree' \
  && ok "N15: an archive root inside the worktree HOLDs" || bad "N15 output: $out"
present "N15" "$W"
[ ! -e "$W/tmp/archive" ] && ok "N15: nothing was archived into the worktree" || bad "N15: wrote $W/tmp/archive"
ln -s "$W" "$R_TMP/n15-link"
out=$(HERDR_ARCHIVE_ROOT="$R_TMP/n15-link/tmp/archive" AW --apply "$R")
row "$out" "$W" | grep -qi 'HOLD.*is inside this worktree' \
  && ok "N15: a symlinked spelling of that root HOLDs too" || bad "N15 symlinked root: $out"
present "N15 (symlinked root)" "$W"
out=$(HERDR_ARCHIVE_ROOT="rel/archive" AW --apply "$R"); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'not an absolute path' \
  && ok "N15: a relative archive root refuses the run" || bad "N15 relative: rc=$rc $out"
present "N15 (relative root)" "$W"

printf '== N4a (M3): a second --apply while one holds the lock; two concurrent runs ==\n'
R="$R_TMP/n4"; mkrepo "$R" probe/n4; W="$WTROOT/n4-merged"; mkwt "$R" n4-merged "$W"
note "$W"; printf 'more\n' > "$W/tmp/more.md"
n4_notes=$(shasum -a 256 "$W/tmp/notes.md" | cut -d' ' -f1); n4_more=$(shasum -a 256 "$W/tmp/more.md" | cut -d' ' -f1)
mkdir "$LOCKDIR" && printf '%s\n' "$$" > "$LOCKDIR/pid"
out=$(AW --apply "$R"); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "holds $LOCKDIR (pid $$)" \
  && ok "N4a: --apply refuses while another run holds the lock" || bad "N4a held lock: rc=$rc $out"
present "N4a (lock held)" "$W"
[ -d "$LOCKDIR" ] && ok "N4a: the refused run left the other run's lock alone" || bad "N4a: the refused run removed a lock it did not own"
rm -f "$LOCKDIR/pid"; rmdir "$LOCKDIR"
AW --apply "$R" > "$R_TMP/n4-A.out" & pa=$!
AW --apply "$R" > "$R_TMP/n4-B.out" & pb=$!
wait "$pa" "$pb"
[ ! -d "$W" ] && ok "N4a: two concurrent runs removed the worktree" \
  || bad "N4a concurrent: A: $(cat "$R_TMP/n4-A.out") B: $(cat "$R_TMP/n4-B.out")"
n4d=$(find "$HERDR_ARCHIVE_ROOT/n4" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
[ "$(printf '%s\n' "$n4d" | grep -c .)" -eq 1 ] && case "$n4d" in *.partial) false ;; esac \
  && ok "N4a: exactly one finished archive dir" || bad "N4a: archive dirs: $n4d"
[ "$(grep -vc '^EXCLUDED' "$n4d/MANIFEST.sha256" 2>/dev/null)" = 2 ] \
  && _manifest_has "$n4d/MANIFEST.sha256" "$n4_notes" tmp/notes.md && _manifest_has "$n4d/MANIFEST.sha256" "$n4_more" tmp/more.md \
  && [ -f "$n4d/DISPOSITION.txt" ] && [ -f "$n4d/branch.bundle" ] \
  && ok "N4a: its manifest holds both entries (never truncated by the other run)" \
  || bad "N4a: manifest: $(cat "$n4d/MANIFEST.sha256" 2>&1)"
[ ! -e "$LOCKDIR" ] && ok "N4a: the lock is released after the runs" || bad "N4a: lock left behind at $LOCKDIR"

printf '== L1: a registered worktree path swapped for a symlink to a sibling ==\n'
R="$R_TMP/l1"; mkrepo "$R" probe/l1
Wa="$WTROOT/l1-a"; Wb="$WTROOT/l1-b"; mkwt "$R" l1-a "$Wa"; mkwt "$R" l1-b "$Wb"
note "$Wa" a-notes; note "$Wb" b-notes
mv "$Wa" "$R_TMP/l1-a-moved"; ln -s "$Wb" "$Wa"
out=$(AW --apply "$R")
row "$out" "$Wa" | grep -q 'HOLD.*symlink' && ok "L1: a symlinked worktree path HOLDs" || bad "L1 output: $out"
[ -z "$(find "$HERDR_ARCHIVE_ROOT/l1" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
  && ok "L1: no archive was written (none under another worktree's label)" || bad "L1: archive written: $(find "$HERDR_ARCHIVE_ROOT/l1" -mindepth 1 -maxdepth 1)"
[ -d "$Wb" ] && [ -f "$R_TMP/l1-a-moved/tmp/notes.md" ] && ok "L1: both real directories intact" || bad "L1: a real directory is gone"

printf '== L3: a locked worktree previews as HOLD, not archive ==\n'
R="$R_TMP/l3"; mkrepo "$R" probe/l3; W="$WTROOT/l3-locked"; mkwt "$R" l3-locked "$W"; note "$W"
git -C "$R" worktree lock --reason "on a removable disk" "$W"
out=$(AW "$R")
row "$out" "$W" | grep -q 'HOLD.*locked' && ok "L3: a locked worktree HOLDs in preview" || bad "L3 output: $out"
out=$(AW --apply "$R")
[ -z "$(find "$HERDR_ARCHIVE_ROOT/l3" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
  && ok "L3: --apply wrote no archive for it" || bad "L3: archive written: $out"
present "L3" "$W"

printf '== L5: a detached worktree holding a refs/worktree ref ==\n'
R="$R_TMP/l5"; mkrepo "$R" probe/l5; W="$WTROOT/l5-det"; G -C "$R" worktree add -q --detach "$W" main
G -C "$W" commit -q --allow-empty -m "detached local work"; X=$(git -C "$W" rev-parse HEAD)
G -C "$W" update-ref refs/worktree/keep "$X"; G -C "$W" checkout -q --detach main
out=$(AW --apply --worktree="$W" --disposition=abandoned "$R")
row "$out" "$W" | grep -q 'HOLD.*worktree-private refs' && ok "L5: worktree-private refs HOLD" || bad "L5 output: $out"
present "L5" "$W"

#######################################################################
# Section S: review r3 probes S3 and S5 as permanent real negatives. On
# 67c7efe a re-spawn whose archive-lock check passed before the archive
# started, and whose SPEC.md write landed after the pre-remove re-check or
# in the unlock -> remove gap, lost that SPEC.md unarchived (S3); and a
# process holding a file open inside a worktree, its cwd elsewhere, did not
# hold it (S5).
#######################################################################
printf '\n== Section S: review r3 probes ==\n'
S_TMP="$TMP/S"; mkdir -p "$S_TMP"
REAL_GIT=$(command -v git); REAL_MV=$(command -v mv); REAL_DATE=$(command -v date); REAL_MKTEMP=$(command -v mktemp)
GH_PRS="$GH_PRS
probe/s3m#301 s3m-merged MERGED $M
probe/s3g#302 s3g-merged MERGED $M
probe/s3i#303 s3i-merged MERGED $M
probe/s5#501 s5-fd MERGED $M"

# More pass-through hooks for archive-worktrees.sh, each armed by its own
# variable and fired ONCE, like shasum's: HOOK_DATE at the archive's
# timestamp (every preview check passed; nothing fenced or locked yet),
# HOOK_MV at `mv <dest>.partial <dest>` (after the pre-remove re-check) and
# HOOK_RM at `git worktree remove` (after the unlock).
_hook_wrapper() {               # <name> <real binary> <HOOK var> <case pattern on " $* ">
  cat > "$TMP/bin/$1" <<EOF
#!/bin/bash
case " \$* " in
  $4) if [ -n "\${$3:-}" ] && [ -f "\$$3" ]; then "$REAL_MV" -f "\$$3" "\$$3.fired" && bash "\$$3.fired"; fi ;;
esac
exec "$2" "\$@"
EOF
  chmod +x "$TMP/bin/$1"
}
_hook_wrapper date "$REAL_DATE" HOOK_DATE '*" -u +%Y%m%dT%H%M%SZ "*'
_hook_wrapper mv "$REAL_MV" HOOK_MV '*".partial "*'
_hook_wrapper git "$REAL_GIT" HOOK_RM '*" worktree remove "*'

# The real spawn-task.sh, run from its own bin dir (HERDR_EXTRA_PATH, which
# config.sh puts first on PATH): verify-spawn-spec-proof.sh's herdr stub,
# plus two pass-through gates that PAUSE it until released —
#   GATE1 at its trunk lookup: after its archive-lock check, before anything
#         it writes into the worktree (and before the r3 fence check);
#   GATE2 at the mktemp for SPEC.md: after the r3 fence check, before the write.
# A gate is a path: the spawn touches <gate>.at on arrival, waits for <gate>.go.
SPAWN_BIN="$S_TMP/spawnbin"; mkdir -p "$SPAWN_BIN"
cat > "$SPAWN_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
	"tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
	"pane run")   : ;;
	"pane list")  printf '{"result":{"panes":[]}}\n' ;;
	*)            printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$SPAWN_BIN/herdr"
_gate_wrapper() {               # <name> <real binary> <GATE var> <case pattern on " $* ">
  cat > "$SPAWN_BIN/$1" <<EOF
#!/bin/bash
case " \$* " in
  $4) if [ -n "\${$3:-}" ] && mkdir "\$$3.taken" 2>/dev/null; then
        : > "\$$3.at"; n=0
        while [ ! -e "\$$3.go" ] && [ \$n -lt 1200 ]; do sleep 0.1; n=\$((n+1)); done
      fi ;;
esac
exec "$2" "\$@"
EOF
  chmod +x "$SPAWN_BIN/$1"
}
_gate_wrapper git "$REAL_GIT" GATE1 '*" symbolic-ref -q --short refs/remotes/origin/HEAD "*'
_gate_wrapper mktemp "$REAL_MKTEMP" GATE2 '*"/.SPEC."*'

_await() {                      # <file>...: wait (<= 120 s) until any of them exists
  local n=0 f
  while [ "$n" -lt 1200 ]; do
    for f in "$@"; do [ -e "$f" ] && return 0; done
    sleep 0.1; n=$((n+1))
  done
  return 1
}
_release_hook() {               # <hook file> <gate>.go <wait-for>...: open the gate, block until any <wait-for> exists
  local h="$1" g="$2" w; shift 2
  { printf 'touch "%s"\n' "$g"
    printf 'n=0; while [ $n -lt 1200 ]'
    for w in "$@"; do printf ' && [ ! -e "%s" ]' "$w"; done
    printf '; do sleep 0.1; n=$((n+1)); done\n'
  } > "$h"
}
_spawn() {                      # <repo> <branch> <brief> [VAR=value...]: real spawn-task.sh, own scratch registry
  local repo="$1" br="$2" brief="$3"; shift 3
  ( unset -f herdr gh
    env "$@" HERDR_EXTRA_PATH="$SPAWN_BIN" PATH="$SPAWN_BIN:$PATH" HERDR_WT_DIR="$WTROOT" \
      HERDR_RUN_STATE_DIR="$(mktemp -d)" bash "$here/spawn-task.sh" "$repo" "$br" quick /bin/true --brief "$brief" )
}
_s3_setup() {                   # <name>: spawn-task.sh made the worktree, its PR is MERGED -> sets R, W
  R="$S_TMP/$1"; mkrepo "$R" "probe/$1"
  printf '# ORIGINAL-%s brief\n' "$1" > "$S_TMP/$1-brief0.md"
  printf '# LATE-%s brief\n' "$1" > "$S_TMP/$1-late.md"
  _spawn "$R" "$1-merged" "$S_TMP/$1-brief0.md" > "$S_TMP/$1-spawn0.out" 2>&1 \
    || bad "$1: the first spawn failed: $(tail -3 "$S_TMP/$1-spawn0.out" | tr '\n' ' ')"
  W="$WTROOT/$1/$1-merged"
  G -C "$W" commit -q --allow-empty -m "$1 work"; G -C "$W" push -q origin "$1-merged"; G -C "$R" fetch -q origin
}
_respawn_bg() {                 # <name> [VAR=value...]: re-spawn with the LATE brief in the background; rc -> <name>.rc
  local n="$1"; shift
  ( _spawn "$R" "$n-merged" "$S_TMP/$n-late.md" "$@" > "$S_TMP/$n.out" 2>&1; printf '%s\n' "$?" > "$S_TMP/$n.rc" ) &
  spawn_pid=$!
}
_no_lost_write() {              # <name>: the re-spawn refused itself, or its SPEC.md still exists somewhere
  local n="$1" rc
  rc=$(cat "$S_TMP/$n.rc" 2>/dev/null || echo '?')
  if [ "$rc" = 0 ]; then
    if grep -qs "LATE-$n" "$W/.handoffs/SPEC.md" || grep -rqs "LATE-$n" "$HERDR_ARCHIVE_ROOT/$n"; then
      ok "$n: the re-spawn succeeded and its SPEC.md survives"
    else
      bad "$n: the re-spawn reported success but its SPEC.md is gone, deleted unarchived ($(row "$AWOUT" "$W"))"
    fi
  elif grep -q 'being archived' "$S_TMP/$n.out"; then
    ok "$n: the re-spawn refused itself at the archive fence, writing nothing"
  else
    bad "$n: the re-spawn failed for another reason (rc=$rc): $(tail -3 "$S_TMP/$n.out" | tr '\n' ' ')"
  fi
}
_archived_and_removed() {       # <name>: the archive still completed, holding the SPEC.md it verified
  [ ! -d "$W" ] && find "$HERDR_ARCHIVE_ROOT/$1" -path '*/files/.handoffs/SPEC.md' -exec grep -l "ORIGINAL-$1" {} + 2>/dev/null | grep -q . \
    && ok "$1: the archive still completes, with the SPEC.md it verified" || bad "$1: $(row "$AWOUT" "$W")"
}
_no_intent_left() {             # <name>: no spawn intent or archive fence outlives its process
  local left
  left=$(find "$R/.git/worktrees" -name 'herdr-*' 2>/dev/null)
  [ -z "$left" ] && ok "$1: no spawn intent or archive fence left behind" || bad "$1: left behind: $left"
}

printf '== S3 (L1): a re-spawn checked the lock before the archive began; its write lands after the re-check ==\n'
_s3_setup s3m
_respawn_bg s3m GATE1="$S_TMP/s3m-g1"
_await "$S_TMP/s3m-g1.at" "$S_TMP/s3m.rc" || bad "s3m: the re-spawn never reached its pause"
_release_hook "$S_TMP/s3m-hook.sh" "$S_TMP/s3m-g1.go" "$S_TMP/s3m.rc"
AWOUT=$(PATH="$HOOKPATH" HOOK_MV="$S_TMP/s3m-hook.sh" AW --apply "$R")
touch "$S_TMP/s3m-g1.go"; wait "$spawn_pid"
[ -f "$S_TMP/s3m-hook.sh.fired" ] && ok "s3m: the re-spawn was released after the re-check" || bad "s3m: hook never fired: $AWOUT"
_no_lost_write s3m
_archived_and_removed s3m
_no_intent_left s3m

printf '== S3 (L1): the same re-spawn released in the unlock -> remove gap ==\n'
_s3_setup s3g
_respawn_bg s3g GATE1="$S_TMP/s3g-g1"
_await "$S_TMP/s3g-g1.at" "$S_TMP/s3g.rc" || bad "s3g: the re-spawn never reached its pause"
_release_hook "$S_TMP/s3g-hook.sh" "$S_TMP/s3g-g1.go" "$S_TMP/s3g.rc"
AWOUT=$(PATH="$HOOKPATH" HOOK_RM="$S_TMP/s3g-hook.sh" AW --apply "$R")
touch "$S_TMP/s3g-g1.go"; wait "$spawn_pid"
[ -f "$S_TMP/s3g-hook.sh.fired" ] && ok "s3g: the re-spawn was released between unlock and remove" || bad "s3g: hook never fired: $AWOUT"
_no_lost_write s3g
_archived_and_removed s3g
_no_intent_left s3g

printf '== S3 (L1): a re-spawn already past its fence check before the archive fenced, writing after the re-check ==\n'
# HOOK_MV only fires when the re-check lets the run reach its rename (67c7efe,
# which has no fence): it releases the paused write there, before the remove.
_s3_setup s3i
_respawn_bg s3i GATE1="$S_TMP/s3i-g1" GATE2="$S_TMP/s3i-g2"
_await "$S_TMP/s3i-g1.at" "$S_TMP/s3i.rc" || bad "s3i: the re-spawn never reached its first pause"
_release_hook "$S_TMP/s3i-date.sh" "$S_TMP/s3i-g1.go" "$S_TMP/s3i-g2.at" "$S_TMP/s3i.rc"
_release_hook "$S_TMP/s3i-mv.sh" "$S_TMP/s3i-g2.go" "$S_TMP/s3i.rc"
AWOUT=$(PATH="$HOOKPATH" HOOK_DATE="$S_TMP/s3i-date.sh" HOOK_MV="$S_TMP/s3i-mv.sh" AW --apply "$R")
touch "$S_TMP/s3i-g1.go" "$S_TMP/s3i-g2.go"; wait "$spawn_pid"
[ -f "$S_TMP/s3i-date.sh.fired" ] && [ -f "$S_TMP/s3i-g2.at" ] \
  && ok "s3i: the re-spawn passed its own check before the archive fenced" || bad "s3i: choreography: $AWOUT"
_no_lost_write s3i
row "$AWOUT" "$W" | grep -q 'REFUSED.*changed while archiving: spawn-task pid' \
  && ok "s3i: the re-check sees the spawn's intent and REFUSES the remove" || bad "s3i output: $AWOUT"
present "s3i" "$W"
_no_intent_left s3i

printf '== S5 (L2): a process holds a file open inside the worktree, its cwd elsewhere ==\n'
R="$S_TMP/s5"; mkrepo "$R" probe/s5; W="$WTROOT/s5-fd"; mkwt "$R" s5-fd "$W"; note "$W"
( cd "$CWD_REPO" && exec 3<"$W/tmp/notes.md" && exec sleep 300 ) & fpid=$!
sleep 1
out=$(AW --apply "$R")
kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qF "process $fpid has $W/tmp/notes.md open" \
  && ok "S5: a file held open inside the worktree HOLDs it" || bad "S5 output: $out"
present "S5" "$W"
out=$(AW --apply "$R")
[ ! -d "$W" ] && ok "S5 control: once the file is closed the same worktree is archived and removed" || bad "S5 control: $out"

#######################################################################
# Section T: fix/archival-symlinks. A real-fleet --apply batch (form 8810,
# /tmp/archival/batch-1.log) refused 10 tourguide worktrees with "archiving
# failed: source file vanished before archiving: ingest/node_modules" (also
# farm-review/node_modules, node_modules) — each path was a SYMLINK into the
# primary checkout (ingest/node_modules -> ~/Code/tourguide/ingest/
# node_modules). `[ -f ]` follows a symlink to judge its TARGET, so a
# symlink to a directory read as "not a regular file" and was misreported
# as vanished. Second: the same batch's "run registry query failed;
# liveness cannot be verified" hit 14/200 reads intermittently under a busy
# registry even with `.timeout 5000`.
#######################################################################
printf '\n== Section T: symlinked regenerable dirs + a locked registry ==\n'
T_TMP="$TMP/T"; mkdir -p "$T_TMP"

printf '== T1: a symlinked node_modules into a scratch primary archives AS A SYMLINK; the target is untouched ==\n'
GH_PRS="$GH_PRS
probe/t1#71 t1-merged MERGED 7171717171717171717171717171717171717171"
R="$T_TMP/t1"; mkrepo "$R" probe/t1
# mkrepo's shared .gitignore uses 'node_modules/' (trailing slash), which
# gitignore semantics match ONLY a directory — a symlink never qualifies,
# so ingest/node_modules would read as untracked, not ignored. Real
# tourguide's .gitignore has the bare form too, which matches a symlink.
printf 'node_modules\n' >> "$R/.gitignore"
G -C "$R" add .gitignore && G -C "$R" commit -q -m "ignore node_modules symlinks too"
G -C "$R" push -q origin main
PRIMARY="$T_TMP/t1-primary-checkout"; mkdir -p "$PRIMARY/node_modules/pkg"
printf 'module.exports = 1\n' > "$PRIMARY/node_modules/pkg/index.js"
primary_before_sha=$(shasum -a 256 "$PRIMARY/node_modules/pkg/index.js" | cut -d' ' -f1)
W="$WTROOT/t1-merged"; mkwt "$R" t1-merged "$W"
mkdir -p "$W/ingest"
ln -s "$PRIMARY/node_modules" "$W/ingest/node_modules"
out=$(AW "$R")
row "$out" "$W" | grep -q '^  archive' \
  && ok "T1: a worktree with a symlinked node_modules previews archivable (never 'vanished')" || bad "T1 dry-run: $out"
out=$(AW --apply "$R")
[ ! -d "$W" ] && ok "T1: the worktree was archived and removed" || bad "T1 apply: $out"
dest_t1=$(find "$HERDR_ARCHIVE_ROOT/t1" -maxdepth 1 -type d -name 't1-merged-*' 2>/dev/null | head -1)
m="$dest_t1/MANIFEST.sha256"
[ -n "$dest_t1" ] && [ -f "$m" ] \
  && awk -F'\t' '$1=="SYMLINK" && $3=="ingest/node_modules" {f=1} END{exit !f}' "$m" \
  && ok "T1: the manifest records ingest/node_modules as a SYMLINK, never a vanished/copied file" \
  || bad "T1: manifest wrong/missing: $(cat "$m" 2>&1)"
recorded_target=$(awk -F'\t' '$1=="SYMLINK" && $3=="ingest/node_modules" {print $2}' "$m")
[ "$recorded_target" = "$PRIMARY/node_modules" ] \
  && ok "T1: the recorded target is the real primary checkout's node_modules path" || bad "T1: recorded target wrong: $recorded_target"
[ -L "$dest_t1/files/ingest/node_modules" ] \
  && [ "$(readlink "$dest_t1/files/ingest/node_modules")" = "$PRIMARY/node_modules" ] \
  && ok "T1: the archived copy is itself a symlink to the same target, never a copy of its content" \
  || bad "T1: archived entry is not a matching symlink"
primary_after_sha=$(shasum -a 256 "$PRIMARY/node_modules/pkg/index.js" 2>/dev/null | cut -d' ' -f1)
[ "$primary_after_sha" = "$primary_before_sha" ] \
  && ok "T1: the symlink target (primary checkout's node_modules) is byte-identical afterward" \
  || bad "T1: the primary checkout's node_modules was modified"
[ -d "$PRIMARY/node_modules" ] && ok "T1: the primary checkout's node_modules dir still exists (never removed)" \
  || bad "T1: the primary checkout's node_modules is gone"

printf '== T2: a symlink pointing outside every allowed root is recorded, never followed ==\n'
GH_PRS="$GH_PRS
probe/t2#72 t2-merged MERGED 7272727272727272727272727272727272727272"
R="$T_TMP/t2"; mkrepo "$R" probe/t2
printf 'outside-link\n' >> "$R/.gitignore"
G -C "$R" add .gitignore && G -C "$R" commit -q -m "ignore the outside-link symlink"
G -C "$R" push -q origin main
OUTSIDE="$T_TMP/t2-outside"; mkdir -p "$OUTSIDE"
printf 'do not touch\n' > "$OUTSIDE/secret.txt"
outside_before_sha=$(shasum -a 256 "$OUTSIDE/secret.txt" | cut -d' ' -f1)
W="$WTROOT/t2-merged"; mkwt "$R" t2-merged "$W"
ln -s "$OUTSIDE" "$W/outside-link"
out=$(AW --apply "$R")
[ ! -d "$W" ] && ok "T2: a worktree with a symlink to an arbitrary outside path archives and removes" || bad "T2 apply: $out"
dest_t2=$(find "$HERDR_ARCHIVE_ROOT/t2" -maxdepth 1 -type d -name 't2-merged-*' 2>/dev/null | head -1)
m2="$dest_t2/MANIFEST.sha256"
[ -n "$dest_t2" ] && [ -f "$m2" ] \
  && awk -F'\t' -v t="$OUTSIDE" '$1=="SYMLINK" && $2==t && $3=="outside-link" {f=1} END{exit !f}' "$m2" \
  && ok "T2: the manifest records the out-of-root symlink and its exact target" || bad "T2: manifest wrong/missing: $(cat "$m2" 2>&1)"
[ "$(find "$OUTSIDE" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] \
  && [ "$(shasum -a 256 "$OUTSIDE/secret.txt" | cut -d' ' -f1)" = "$outside_before_sha" ] \
  && ok "T2: the outside directory was never traversed or modified (never followed)" \
  || bad "T2: the outside directory was touched"

printf '== T3: a registry locked past the retries still HOLDs, with the real sqlite3 error visible ==\n'
R="$T_TMP/t3"; mkrepo "$R" probe/t3; W="$WTROOT/t3-live"; mkwt "$R" t3-live "$W"
T3_RUNS="$T_TMP/t3-runs"; mkdir -p "$T3_RUNS"
HERDR_RUN_STATE_DIR="$T3_RUNS" bash -c '
  . "$1/lib/run-registry.sh"
  registry_init && register_task runT3 taskT3 w c cp cb pT3 bT3 "$2" "$3" t3-live
' _ "$here" "$R" "$W" >/dev/null || bad "T3: could not seed the scratch registry"
T3_DB="$T3_RUNS/registry.sqlite3"
LOCKFIFO="$T_TMP/t3.fifo"; mkfifo "$LOCKFIFO"
# A scratch writer takes an OS-level EXCLUSIVE lock (locking_mode=EXCLUSIVE)
# and holds it open via the FIFO — a real SQLITE_BUSY-producing lock, not a
# simulated error string — until the archiver's retries have had their
# chance and this test releases it.
(
  sqlite3 "$T3_DB" > "$T_TMP/t3-writer.out" 2>&1 <<SQL
PRAGMA locking_mode=EXCLUSIVE;
BEGIN IMMEDIATE;
UPDATE tasks SET updated_at = updated_at;
.shell cat "$LOCKFIFO" >/dev/null
COMMIT;
SQL
) &
t3_writer=$!
sleep 0.4
out=$(HERDR_RUN_STATE_DIR="$T3_RUNS" HERDR_REGISTRY_BUSY_MS=200 HERDR_REGISTRY_BUSY_RETRIES=1 AW --apply "$R")
echo stop > "$LOCKFIFO"
wait "$t3_writer" 2>/dev/null
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'liveness cannot be verified' \
  && ok "T3: a locked registry still HOLDs (fail-closed)" || bad "T3 output: $out"
row "$out" "$W" | grep -qi 'locked' \
  && ok "T3: sqlite3's real error (database is locked) is visible in the HOLD reason" || bad "T3: no visible cause: $(row "$out" "$W")"
present "T3" "$W"

printf '== T4: an archived symlink replaced by a regular file before the pre-remove recheck REFUSEs (MED) ==\n'
GH_PRS="$GH_PRS
probe/t4#74 t4-merged MERGED 7474747474747474747474747474747474747474"
R="$T_TMP/t4"; mkrepo "$R" probe/t4
printf 'lnk4\n' >> "$R/.gitignore"
G -C "$R" add .gitignore && G -C "$R" commit -q -m "ignore lnk4"
G -C "$R" push -q origin main
OUT4="$T_TMP/t4-out"; mkdir -p "$OUT4"
W="$WTROOT/t4-merged"; mkwt "$R" t4-merged "$W"
ln -s "$OUT4" "$W/lnk4"
# A dedicated git wrapper, scoped to this one call via PATH, swaps the
# symlink for a regular file with new content exactly when `git bundle
# create` runs — between archive_copy_and_manifest's first verify (which
# still sees the intact symlink) and the pre-remove recheck's second one.
T4_BIN="$T_TMP/t4bin"; mkdir -p "$T4_BIN"
cat > "$T4_BIN/git" <<EOF
#!/bin/bash
case " \$* " in
  *" bundle create "*) rm -f "$W/lnk4"; printf 'NEW UNARCHIVED WORK\n' > "$W/lnk4" ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T4_BIN/git"
out=$(PATH="$T4_BIN:$PATH" AW --apply "$R")
row "$out" "$W" | grep -q 'REFUSED.*no longer a symlink' \
  && ok "T4: a symlink swapped for a file before the recheck REFUSEs the remove" || bad "T4 output: $out"
present "T4" "$W"
[ -f "$W/lnk4" ] && [ ! -L "$W/lnk4" ] && [ "$(cat "$W/lnk4")" = "NEW UNARCHIVED WORK" ] \
  && ok "T4: the unarchived replacement content was never lost (worktree not removed)" || bad "T4: lnk4 wrong/missing"

printf '== T5: a tracked dir replaced by a symlink never writes through it (LOW) ==\n'
# Direct against lib/worktree-archive.sh (same approach as review r1's own
# probe238.sh P7): archive-worktrees.sh's own archive_need_kb HOLDs this
# exact fixture first ("could not size the archive copy/bundle" — `du`
# cannot stat the vanished a/sub/b), which is correct fail-closed behavior
# but means the top-level script never reaches archive_copy_and_manifest
# here. The library function is what review r1 LOW actually fixed.
T5_TMP="$T_TMP/t5"; mkdir -p "$T5_TMP"
T5_WT="$T5_TMP/wt"; G init -q -b main "$T5_WT"
mkdir -p "$T5_WT/a/sub"; printf 'x\n' > "$T5_WT/a/sub/b"
G -C "$T5_WT" add a && G -C "$T5_WT" commit -q -m t
OUT5="$T5_TMP/out"; mkdir -p "$OUT5"; printf 'keep\n' > "$OUT5/keep.txt"
rm -r "$T5_WT/a"; ln -s "$OUT5" "$T5_WT/a"
(
  . "$here/lib/worktree-archive.sh"
  d="$T5_TMP/arch"; mkdir -p "$d"
  archive_copy_and_manifest "$T5_WT" "$d" "$(printf 'a\na/sub/b\n')"
  printf 'T5: copy rc=%s why=%s\n' "$?" "$_ARCHIVE_WHY"
) > "$T_TMP/t5.out" 2>&1
grep -q 'why=path beneath a symlink: a/sub/b' "$T_TMP/t5.out" \
  && ok "T5: a path beneath an already-archived symlink is refused before any mkdir" || bad "T5 output: $(cat "$T_TMP/t5.out")"
[ "$(find "$OUT5" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] && [ -f "$OUT5/keep.txt" ] \
  && ok "T5: the symlink target directory is untouched (nothing written through it)" \
  || bad "T5: target modified: $(find "$OUT5" 2>&1)"

printf '== T6: HERDR_REGISTRY_BUSY_RETRIES=abc still HOLDs within bounded time, never hangs (LOW) ==\n'
R="$T_TMP/t6"; mkrepo "$R" probe/t6; W="$WTROOT/t6-live"; mkwt "$R" t6-live "$W"
T6_RUNS="$T_TMP/t6-runs"; mkdir -p "$T6_RUNS"
HERDR_RUN_STATE_DIR="$T6_RUNS" bash -c '
  . "$1/lib/run-registry.sh"
  registry_init && register_task runT6 taskT6 w c cp cb pT6 bT6 "$2" "$3" t6-live
' _ "$here" "$R" "$W" >/dev/null || bad "T6: could not seed the scratch registry"
T6_DB="$T6_RUNS/registry.sqlite3"
LOCKFIFO6="$T_TMP/t6.fifo"; mkfifo "$LOCKFIFO6"
# Same real EXCLUSIVE-lock writer as T3. Unlike T3, this run's retries value
# is invalid — `[ 0 -ge abc ]` errors (rc=2) rather than comparing, so the
# unfixed cap never trips and _reg_ro spins until the writer releases; the
# 10s `timeout` turns that hang into a visible FAIL instead of wedging the
# whole suite when run against the pre-fix baseline.
(
  sqlite3 "$T6_DB" > "$T_TMP/t6-writer.out" 2>&1 <<SQL
PRAGMA locking_mode=EXCLUSIVE;
BEGIN IMMEDIATE;
UPDATE tasks SET updated_at = updated_at;
.shell cat "$LOCKFIFO6" >/dev/null
COMMIT;
SQL
) &
t6_writer=$!
sleep 0.4
out=$(timeout 10 env HERDR_RUN_STATE_DIR="$T6_RUNS" HERDR_REGISTRY_BUSY_MS=200 HERDR_REGISTRY_BUSY_RETRIES=abc \
  bash "$here/archive-worktrees.sh" --apply "$R" 2>&1)
rc=$?
echo stop > "$LOCKFIFO6"
wait "$t6_writer" 2>/dev/null
[ "$rc" -ne 124 ] && ok "T6: a non-numeric retries value no longer spins forever (terminated, rc=$rc)" \
  || bad "T6: still spinning past 10s with HERDR_REGISTRY_BUSY_RETRIES=abc (cap never trips)"
row "$out" "$W" | grep -q HOLD && row "$out" "$W" | grep -qi 'liveness cannot be verified' \
  && ok "T6: it still HOLDs (fail-closed), falling back to the default retry cap" || bad "T6 output: $out"
present "T6" "$W"

#######################################################################
# Section U: close-done-workers.sh --reason=superseded (brief 2026-10-06,
# "superseded close reason" — form 20261006T121930-8789, "build"). A review
# task's PR is still OPEN but a NEWER review of the exact same PR made it
# redundant (live examples w6G:pB/pC/pH/pM/pK in tntpgh-dev); every rule
# below is a hold, never a shim, and dry-run never mutates anything.
#######################################################################
printf '\n== Section U: close-done-workers.sh --reason=superseded ==\n'

U_TMP="$TMP/U"; mkdir -p "$U_TMP"
U_ORIGIN="$U_TMP/origin.git"
git init -q --bare "$U_ORIGIN"
U_WORK="$U_TMP/work"
git init -q -b main "$U_WORK"
G -C "$U_WORK" commit -q --allow-empty -m init
printf 'tmp/\n.handoffs/\n' > "$U_WORK/.gitignore"
git -C "$U_WORK" add .gitignore
G -C "$U_WORK" commit -q -m gitignore
git -C "$U_WORK" remote add origin "$U_ORIGIN"
git -C "$U_WORK" push -q origin main
U_WT_ROOT="$U_TMP/worktrees"; mkdir -p "$U_WT_ROOT"

# _u_case <old-label> <new-label> -> fresh org/repo#<N> PR (own GH_PRS line,
# own refs/pull/<N>/head), an OLD review task detached at the PR head
# (created_at backdated to 2020, so any default-timestamped NEW task sorts
# after it) and a NEW task reviewing the same PR. Sets U_PR, U_PR_SHA,
# U_WT, U_RUN/U_TASK (old), U_NEWRUN/U_NEWTASK (new).
_u_n=0
_u_case() {
  _u_n=$((_u_n + 1))
  local n br seed
  n=$((9000 + _u_n))
  br="pr-u$n"
  seed="$U_TMP/seed-$n"
  GH_PRS="$GH_PRS
org/repo#$n $br OPEN -"
  G -C "$U_WORK" worktree add -q -b "$br" "$seed" main
  G -C "$seed" commit -q --allow-empty -m "$br work"
  G -C "$seed" push -q origin "$br:refs/pull/$n/head"
  U_PR="$n"
  U_PR_SHA=$(git -C "$seed" rev-parse HEAD)
  git -C "$U_WORK" worktree remove --force "$seed" >/dev/null 2>&1

  U_WT="$U_WT_ROOT/wt-$n"
  git -C "$U_WORK" worktree add -q --detach "$U_WT" "$U_PR_SHA"
  U_RUN="runU$n"; U_TASK="taskU$n"
  register_task "$U_RUN" "$U_TASK" w c cp cb pD birthD-live "$U_WORK" "$U_WT" "${1:-review:old-$n}" \
    || bad "U setup: register $U_TASK"
  set_task_state "$U_RUN" "$U_TASK" running || bad "U setup: $U_TASK -> running"
  set_task_review_pr "$U_RUN" "$U_TASK" org/repo "$n" || bad "U setup: set_task_review_pr $U_TASK"
  sqlite3 "$(registry_db)" "UPDATE tasks SET created_at='2020-01-01T00:00:00Z' WHERE task_id='$U_TASK';"

  U_NEWRUN="runU${n}n"; U_NEWTASK="taskU${n}n"
  register_task "$U_NEWRUN" "$U_NEWTASK" w c cp cb "pDn$n" "birthDn$n" "$U_WORK" "/does/not/exist" "${2:-review:new-$n}" \
    || bad "U setup: register $U_NEWTASK"
  set_task_state "$U_NEWRUN" "$U_NEWTASK" running || bad "U setup: $U_NEWTASK -> running"
  set_task_review_pr "$U_NEWRUN" "$U_NEWTASK" org/repo "$n" || bad "U setup: set_task_review_pr $U_NEWTASK"
}

printf -- '-- rule 1: both review-class, same repo#PR, newer created after older --\n'

_u_case "implement:old-r1a" "review:new-r1a"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'not review-class' \
  && ok "U rule1a: old task not review-class HOLDs" || bad "U rule1a output: $out"

_u_case "review:old-r1b" "implement:new-r1b"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'not review-class' \
  && ok "U rule1b: --superseded-by task not review-class HOLDs" || bad "U rule1b output: $out"

_u_case "review:old-r1c-a" "review:new-r1c-a"; r1c_old="$U_TASK"
_u_case "review:old-r1c-b" "review:new-r1c-b"; r1c_cross_new="$U_NEWTASK"
out=$(bash "$here/close-done-workers.sh" --task="$r1c_old" --reason=superseded --superseded-by="$r1c_cross_new" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'reviews .*, not' \
  && ok "U rule1c: --superseded-by reviewing a DIFFERENT PR HOLDs" || bad "U rule1c output: $out"

_u_case "review:old-r1d" "review:new-r1d"
sqlite3 "$(registry_db)" "UPDATE tasks SET created_at='2019-01-01T00:00:00Z' WHERE task_id='$U_NEWTASK';"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'was not created after' \
  && ok "U rule1d: --superseded-by NOT created after this task HOLDs" || bad "U rule1d output: $out"

printf -- '-- rule 2: zero dirty tracked files, zero untracked files outside tmp/.handoffs --\n'

_u_case "review:old-r2a" "review:new-r2a"
printf 'tmp/\n.handoffs/\nextra\n' > "$U_WT/.gitignore"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'uncommitted tracked file' \
  && ok "U rule2a: a dirty TRACKED file HOLDs" || bad "U rule2a output: $out"

_u_case "review:old-r2b" "review:new-r2b"
printf 'x\n' > "$U_WT/stray.txt"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'untracked file(s) outside tmp/ and .handoffs/' \
  && ok "U rule2b: an untracked file outside tmp/.handoffs HOLDs" || bad "U rule2b output: $out"

printf -- '-- rule 3: old HEAD must be an ancestor of the CURRENT refs/pull/<N>/head --\n'

_u_case "review:old-r3" "review:new-r3"
# force refs/pull/<N>/head back to main's tip -- an ANCESTOR of old's HEAD,
# never the other way, so old's HEAD is no longer an ancestor of the ref.
G -C "$U_WORK" push -q --force origin "main:refs/pull/$U_PR/head"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'is not an ancestor of' \
  && ok "U rule3: HEAD no longer an ancestor of refs/pull/<N>/head HOLDs" || bad "U rule3 output: $out"

printf -- '-- rule 4: the archive dir must outlive the worktree; dry run never archives --\n'

_u_case "review:old-r4" "review:new-r4"
mkdir -p "$U_WT/.handoffs"
printf 'verified: ran the check, output attached\n' > "$U_WT/.handoffs/PROOF.md"
out=$(HERDR_ARCHIVE_ROOT="$U_WT/.archive-under-wt" bash "$here/close-done-workers.sh" --apply --reason=superseded \
  --task="$U_TASK" --superseded-by="$U_NEWTASK" --proof=".handoffs/PROOF.md#check" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'inside this worktree' \
  && ok "U rule4: an archive root beneath the worktree HOLDs" || bad "U rule4 output: $out"
check "U rule4: task untouched by the refused archive root" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- dry run: nothing to archive and rules 1-3 pass -> closable, never mutates the filesystem --\n'

_u_case "review:old-dry" "review:new-dry"
: > "$CALLS"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q '^  close' && printf '%s' "$out" | grep -q '(superseded)' \
  && ok "U dry-run: closable with the (superseded) marker, no --apply needed" || bad "U dry-run output: $out"
check "U dry-run: task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"
[ -d "$HERDR_ARCHIVE_ROOT" ] && find "$HERDR_ARCHIVE_ROOT" -maxdepth 2 -type d -name 'superseded-*' 2>/dev/null | grep -q . \
  && bad "U dry-run: an archive dir was created despite no --apply" \
  || ok "U dry-run: no superseded-* archive dir exists yet"
grep -q '^pane close$' "$CALLS" && bad "U dry-run: a pane was closed on a dry run" \
  || ok "U dry-run: no pane close for the dry run"

printf -- '-- positive: every rule holds -> --apply archives tmp/.handoffs, writes HEAD.txt, closes, records reason=superseded --\n'

_u_case "review:old-pos" "review:new-pos"
mkdir -p "$U_WT/tmp" "$U_WT/.handoffs"
printf 'pos notes\n' > "$U_WT/tmp/notes.md"
exp_pos_sha=$(shasum -a 256 "$U_WT/tmp/notes.md" | cut -d' ' -f1)
printf 'verified: ran the check, output attached\n' > "$U_WT/.handoffs/PROOF.md"
: > "$CALLS"
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" --superseded-by="$U_NEWTASK" \
  --proof=".handoffs/PROOF.md#check" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U positive: --apply exits 0" || bad "U positive exit $rc: $out"
check "U positive: old task completed" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "completed"
_uev() { sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.$1') FROM events WHERE task_id='$U_TASK' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';"; }
check "U positive: reason recorded is superseded, never shipped" "$(_uev reason)" "superseded"
check "U positive: detail records the old task id" "$(_uev detail.superseded_close.old_task)" "$U_TASK"
check "U positive: detail records superseded_by" "$(_uev detail.superseded_close.superseded_by)" "$U_NEWTASK"
check "U positive: detail records the old head" "$(_uev detail.superseded_close.old_head)" "$U_PR_SHA"
grep -q '^pane close$' "$CALLS" && ok "U positive: pane close was called" || bad "U positive: no pane close: $(cat "$CALLS")"
u_archive_dir=$(find "$HERDR_ARCHIVE_ROOT" -maxdepth 2 -type d -name "superseded-$U_PR-*" 2>/dev/null | head -1)
[ -n "$u_archive_dir" ] && [ -f "$u_archive_dir/HEAD.txt" ] \
  && ok "U positive: archive dir exists with HEAD.txt" || bad "U positive: no archive dir/HEAD.txt: $out"
[ "$(cat "$u_archive_dir/HEAD.txt" 2>/dev/null)" = "$U_PR_SHA" ] \
  && ok "U positive: HEAD.txt names the exact old head sha" || bad "U positive: HEAD.txt wrong: $(cat "$u_archive_dir/HEAD.txt" 2>&1)"
_manifest_has "$u_archive_dir/MANIFEST.sha256" "$exp_pos_sha" "tmp/notes.md" \
  && ok "U positive: tmp/notes.md archived with a matching sha256 in the manifest" \
  || bad "U positive: manifest missing/mismatched: $(cat "$u_archive_dir/MANIFEST.sha256" 2>&1)"

check "U positive: detail records pr_head" "$(_uev detail.superseded_close.pr_head)" "$U_PR_SHA"

printf -- '-- H1: deep-review:* is accepted on both sides (every live example is deep-review) --\n'

_u_case "deep-review:old-h1" "deep-review:new-h1"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q '^  close' && printf '%s' "$out" | grep -q '(superseded)' \
  && ok "U H1: deep-review:* labels on both sides are accepted (closable)" || bad "U H1 output: $out"

printf -- '-- mutant M3: same PR NUMBER in a DIFFERENT repo HOLDs, never "reviews the same PR" --\n'

_u_case "review:old-repocmp" "review:new-repocmp"
sqlite3 "$(registry_db)" "UPDATE tasks SET review_pr_repo='org/other-repo' WHERE task_id='$U_NEWTASK';"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'reviews org/other-repo#.*, not org/repo#' \
  && ok "U rule1 (mutant M3): same PR# in a DIFFERENT repo HOLDs" || bad "U rule1 (mutant M3) output: $out"

printf -- '-- M1: an ignored file OUTSIDE tmp/.handoffs (.private/) is archived, never silently dropped --\n'

echo '.private/' >> "$(git -C "$U_WORK" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
_u_case "review:old-m1" "review:new-m1"
mkdir -p "$U_WT/.private" "$U_WT/.handoffs"
printf 'ignored note outside tmp/.handoffs\n' > "$U_WT/.private/notes.txt"
exp_private_sha=$(shasum -a 256 "$U_WT/.private/notes.txt" | cut -d' ' -f1)
printf 'verified: ran the check, output attached\n' > "$U_WT/.handoffs/PROOF.md"
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" --superseded-by="$U_NEWTASK" \
  --proof=".handoffs/PROOF.md#check" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U M1: --apply closes despite an ignored file outside tmp/.handoffs" || bad "U M1 exit $rc: $out"
check "U M1: task completed" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "completed"
m1_archive_dir=$(find "$HERDR_ARCHIVE_ROOT" -maxdepth 2 -type d -name "superseded-$U_PR-*" 2>/dev/null | head -1)
_manifest_has "$m1_archive_dir/MANIFEST.sha256" "$exp_private_sha" ".private/notes.txt" \
  && ok "U M1: .private/notes.txt is archived with a matching sha256, never dropped" \
  || bad "U M1: manifest missing .private/notes.txt: $(cat "$m1_archive_dir/MANIFEST.sha256" 2>&1)"

printf -- '-- M3: rule-4 enumeration failing HOLDs, never reads as "nothing to archive" --\n'

_u_case "review:old-m3" "review:new-m3"
mkdir -p "$U_WT/.handoffs"
printf 'verified: ran the check, output attached\n' > "$U_WT/.handoffs/PROOF.md"
M3_BIN="$U_TMP/m3bin"; mkdir -p "$M3_BIN"
REAL_GIT=$(command -v git)
cat > "$M3_BIN/git" <<EOF
#!/bin/bash
if [ "\$1" = "-C" ] && [ "\$3" = "ls-files" ]; then
  case "\$*" in
    *--ignored*) exit 128 ;;
  esac
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$M3_BIN/git"
out=$(PATH="$M3_BIN:$PATH" bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" \
  --superseded-by="$U_NEWTASK" --proof=".handoffs/PROOF.md#check" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'could not list ignored artifacts' \
  && ok "U M3: a failing ignored-file enumeration HOLDs, never reads as nothing to archive" || bad "U M3 output: $out"
check "U M3: task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- M2: a reflog-only commit (left behind by re-detaching) HOLDs --\n'

_u_case "review:old-m2" "review:new-m2"
G -C "$U_WT" commit -q --allow-empty -m "stray local commit, later abandoned"
git -C "$U_WT" checkout -q --detach "$U_PR_SHA"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=superseded --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'reflog holds a commit' \
  && ok "U M2: a reflog-only commit left by re-detaching HOLDs" || bad "U M2 output: $out"

printf -- '-- M4: a CLOSED-unmerged PR keeps closing via --reason=superseded, with or without --superseded-by (regression) --\n'

_u_m4_mk() {                    # CLOSED-PR fixture -> U_M4_WT/U_M4_RUN/U_M4_TASK/U_M4_SHA/U_M4_N
  _u_n=$((_u_n + 1))
  local n br seed
  n=$((9000 + _u_n)); br="pr-u$n"; seed="$U_TMP/seed-$n"
  GH_PRS="$GH_PRS
org/repo#$n $br CLOSED -"
  G -C "$U_WORK" worktree add -q -b "$br" "$seed" main
  G -C "$seed" commit -q --allow-empty -m "$br work"
  G -C "$seed" push -q origin "$br:refs/pull/$n/head"
  U_M4_N="$n"
  U_M4_SHA=$(git -C "$seed" rev-parse HEAD)
  git -C "$U_WORK" worktree remove --force "$seed" >/dev/null 2>&1
  U_M4_WT="$U_WT_ROOT/wt-$n"
  git -C "$U_WORK" worktree add -q --detach "$U_M4_WT" "$U_M4_SHA"
  mkdir -p "$U_M4_WT/.handoffs"
  printf 'verified: ran the check, output attached\n' > "$U_M4_WT/.handoffs/PROOF.md"
  U_M4_RUN="runU$n"; U_M4_TASK="taskU$n"
  register_task "$U_M4_RUN" "$U_M4_TASK" w c cp cb pD birthD-live "$U_WORK" "$U_M4_WT" "review:old-$n" \
    || bad "U M4 setup: register $U_M4_TASK"
  set_task_state "$U_M4_RUN" "$U_M4_TASK" running || bad "U M4 setup: $U_M4_TASK -> running"
  set_task_review_pr "$U_M4_RUN" "$U_M4_TASK" org/repo "$n" || bad "U M4 setup: set_task_review_pr $U_M4_TASK"
}

_u_m4_mk
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_M4_TASK" \
  --proof=".handoffs/PROOF.md#check" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U M4: CLOSED + superseded with NO --superseded-by still closes (regression)" \
  || bad "U M4 (no flag) exit $rc: $out"
check "U M4: task completed (no flag)" "$(read_task "$U_M4_RUN" "$U_M4_TASK" | jq -r .state)" "completed"
_uev4a() { sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.$1') FROM events WHERE task_id='$U_M4_TASK' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';"; }
[ "$(_uev4a detail.detached_close.state)" = CLOSED ] \
  && ok "U M4: closed via the GENERIC path (detached_close), not the bypass (no flag)" \
  || bad "U M4: wrong detail shape (no flag): $(_uev4a detail.detached_close.state)"

_u_m4_mk
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_M4_TASK" \
  --superseded-by=does-not-exist-task --proof=".handoffs/PROOF.md#check" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U M4 (mutant M17/M19): CLOSED + superseded WITH --superseded-by still closes via the generic path" \
  || bad "U M4 (with flag) exit $rc: $out"
check "U M4: task completed (with flag)" "$(read_task "$U_M4_RUN" "$U_M4_TASK" | jq -r .state)" "completed"
_uev4b() { sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.$1') FROM events WHERE task_id='$U_M4_TASK' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';"; }
[ "$(_uev4b detail.detached_close.state)" = CLOSED ] \
  && ok "U M4 (mutant M17/M19): the OPEN-only gate kept --superseded-by from re-routing a CLOSED PR" \
  || bad "U M4: wrong detail shape (with flag): $(_uev4b detail.detached_close.state)"

printf -- '-- M12: the live source changing mid-archive fails manifest verification, never closes --\n'

_u_case "review:old-m12" "review:new-m12"
mkdir -p "$U_WT/tmp"
printf 'original content\n' > "$U_WT/tmp/notes.md"
cat > "$U_TMP/m12-hook.sh" <<EOF
printf 'mutated after the copy-time hash\n' > "$U_WT/tmp/notes.md"
EOF
out=$(PATH="$HOOKPATH" HOOK_FILE="$U_TMP/m12-hook.sh" bash "$here/close-done-workers.sh" --apply --reason=superseded \
  --task="$U_TASK" --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'verification failed' \
  && ok "U M12: the source changing mid-archive fails verification, never closes" || bad "U M12 output: $out"
check "U M12: task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- mutant M18: --superseded-by is ignored unless --reason=superseded (opt-in gate) --\n'

_u_case "review:old-m18" "review:new-m18"
out=$(bash "$here/close-done-workers.sh" --task="$U_TASK" --reason=no-follow-on --superseded-by="$U_NEWTASK" 2>&1)
printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'not yet closable' \
  && ok "U mutant M18: --superseded-by with --reason=no-follow-on never engages the bypass" || bad "U mutant M18 output: $out"

printf -- '-- N1 (mutant P1): set_task_state refuses a forged, empty or missing superseded_close detail --\n'

_u_case "review:old-n1" "review:new-n1"
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" \
  "$(jq -nc --arg t "$U_TASK" '{superseded_close:{old_task:$t, superseded_by:"does-not-exist", old_head:"deadbeef", archive:"/no/such/dir", pr:"org/repo#1"}}')" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "U N1 (mutant P1): a forged superseded_close (fake superseded_by/archive) is REFUSED" \
  || bad "U N1 forged: rc=$rc $out"
check "U N1: task untouched (forged)" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" '{"superseded_close":{}}' 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "U N1 (mutant P1): an empty superseded_close is REFUSED" || bad "U N1 empty: rc=$rc $out"
check "U N1: task untouched (empty)" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "U N1 (mutant P1): a missing detail (no superseded_close at all) is REFUSED" || bad "U N1 missing: rc=$rc $out"
check "U N1: task untouched (missing)" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- N1 (mutant P2): the OPEN-PR bypass completes with NO --proof at all --\n'

_u_case "review:old-noproof" "review:new-noproof"
mkdir -p "$U_WT/tmp"
printf 'no proof needed, the bypass evidence is\n' > "$U_WT/tmp/notes.md"
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" --superseded-by="$U_NEWTASK" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U N1 (mutant P2): --apply closes with NO --proof at all" || bad "U N1 (mutant P2) exit $rc: $out"
check "U N1 (mutant P2): task completed" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "completed"
_uevnp() { sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.$1') FROM events WHERE task_id='$U_TASK' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';"; }
[ -z "$(_uevnp proof)" ] && ok "U N2: no unchecked proof lands in the audit row when none was given" \
  || bad "U N2: proof field present with nothing given: $(_uevnp proof)"

printf -- '-- mutant M1b: a regenerable ignored dir is recorded EXCLUDED, never silently dropped --\n'

echo 'node_modules' >> "$(git -C "$U_WORK" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
_u_case "review:old-m1b" "review:new-m1b"
mkdir -p "$U_WT/node_modules/pkg" "$U_WT/tmp"
printf 'module.exports = 1\n' > "$U_WT/node_modules/pkg/index.js"
printf 'keep me\n' > "$U_WT/tmp/notes.md"
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" --superseded-by="$U_NEWTASK" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U mutant M1b: --apply closes with a regenerable ignored dir present" || bad "U mutant M1b exit $rc: $out"
m1b_archive_dir=$(find "$HERDR_ARCHIVE_ROOT" -maxdepth 2 -type d -name "superseded-$U_PR-*" 2>/dev/null | head -1)
grep -q '^EXCLUDED' "$m1b_archive_dir/MANIFEST.sha256" 2>/dev/null \
  && ok "U mutant M1b: node_modules is recorded EXCLUDED in the manifest" \
  || bad "U mutant M1b: no EXCLUDED line: $(cat "$m1b_archive_dir/MANIFEST.sha256" 2>&1)"

printf -- '-- T1: each _valid_superseded_detail check is pinned in isolation (V1-V10 + a valid-detail positive) --\n'

# Builds a detail that is REAL in every field except what each case below
# mutates: a genuine archive dir (with HEAD.txt) under HERDR_ARCHIVE_ROOT,
# naming the actual old/new task ids, the actual old head, and the actual
# repo#PR -- never the real close-done-workers.sh bypass itself (which
# would close the task, leaving nothing to mutate against), so each V-case
# below differs from a passing call by exactly the one field it names.
# Sets U_VALID_ARCHIVE (the archive dir it created) and U_VALID_DETAIL (its
# JSON) directly as globals -- never call this as $(...): the assignments
# would be thrown away in the subshell, same trap as archive_copy_and_manifest.
_u_valid_detail() {
  local repo_base ts dir
  repo_base="$(basename "$U_WORK")"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  dir="$HERDR_ARCHIVE_ROOT/$repo_base/superseded-$U_PR-$ts-$$-manual"
  mkdir -p "$dir"
  printf '%s\n' "$U_PR_SHA" > "$dir/HEAD.txt"
  U_VALID_ARCHIVE="$dir"
  U_VALID_DETAIL=$(jq -nc --arg t "$U_TASK" --arg s "$U_NEWTASK" --arg h "$U_PR_SHA" --arg a "$dir" --arg pr "org/repo#$U_PR" \
    '{superseded_close:{old_task:$t, superseded_by:$s, old_head:$h, archive:$a, pr:$pr}}')
}

_u_case "review:old-vpos" "review:new-vpos"
_u_valid_detail
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "U T1 positive: a valid hand-built detail with no proof completes" || bad "U T1 positive: rc=$rc $out"
check "U T1 positive: task completed" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "completed"

_u_case "review:old-v1" "review:new-v1"
_u_valid_detail
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c '.superseded_close.old_task = "wrong-task-id"')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V1): old_task mismatch alone is REFUSED" || bad "U T1 (V1): rc=$rc $out"
check "U T1 (V1): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v2" "review:new-v2"
sqlite3 "$(registry_db)" "UPDATE tasks SET label='implement:old-v2' WHERE task_id='$U_TASK';"
_u_valid_detail
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V2): old task not review-class alone is REFUSED" || bad "U T1 (V2): rc=$rc $out"
check "U T1 (V2): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v3" "review:new-v3"
_u_valid_detail
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c '.superseded_close.pr = "org/repo#1"')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V3): pr mismatch alone is REFUSED" || bad "U T1 (V3): rc=$rc $out"
check "U T1 (V3): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-l1v3" "review:new-l1v3"
sqlite3 "$(registry_db)" "UPDATE tasks SET review_pr_number=review_pr_number+1 WHERE task_id='$U_NEWTASK';"
_u_valid_detail
# L1 (mutant V3): the old-V3 test above is caught by the superseded_by-PR
# check (V7) instead, because its pr field still names THIS task's real PR
# while superseded_by's own recorded PR differs. Here detail.pr is changed
# to match superseded_by's (bumped) PR, so that check passes too -- only
# the standalone "pr == this task's own recorded PR" check (line ~976) can
# still catch it.
l1v3_new_pr=$(sqlite3 "$(registry_db)" "SELECT review_pr_number FROM tasks WHERE task_id='$U_NEWTASK';")
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c --arg pr "org/repo#$l1v3_new_pr" '.superseded_close.pr = $pr')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (L1/V3): detail.pr matching superseded_by's PR but not this task's own is REFUSED" \
  || bad "U T1 (L1/V3): rc=$rc $out"
check "U T1 (L1/V3): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v4" "review:new-v4"
_u_valid_detail
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c '.superseded_close.superseded_by = ""')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V4): empty superseded_by alone is REFUSED" || bad "U T1 (V4): rc=$rc $out"
check "U T1 (V4): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v5" "review:new-v5"
_u_valid_detail
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c '.superseded_close.superseded_by = "does-not-exist-task"')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V5): unregistered superseded_by alone is REFUSED" || bad "U T1 (V5): rc=$rc $out"
check "U T1 (V5): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v6" "review:new-v6"
sqlite3 "$(registry_db)" "UPDATE tasks SET label='implement:new-v6' WHERE task_id='$U_NEWTASK';"
_u_valid_detail
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V6): superseded_by not review-class alone is REFUSED" || bad "U T1 (V6): rc=$rc $out"
check "U T1 (V6): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v7" "review:new-v7"
sqlite3 "$(registry_db)" "UPDATE tasks SET review_pr_number=review_pr_number+1 WHERE task_id='$U_NEWTASK';"
_u_valid_detail
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V7): superseded_by reviewing a different PR alone is REFUSED" || bad "U T1 (V7): rc=$rc $out"
check "U T1 (V7): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v8" "review:new-v8"
sqlite3 "$(registry_db)" "UPDATE tasks SET created_at='2019-01-01T00:00:00Z' WHERE task_id='$U_NEWTASK';"
_u_valid_detail
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V8): superseded_by not created after this task alone is REFUSED" || bad "U T1 (V8): rc=$rc $out"
check "U T1 (V8): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v9" "review:new-v9"
_u_valid_detail
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c '.superseded_close.archive = "/no/such/archive/dir"')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V9): nonexistent archive dir alone is REFUSED" || bad "U T1 (V9): rc=$rc $out"
check "U T1 (V9): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v10" "review:new-v10"
_u_valid_detail
printf 'wrong-sha\n' > "$U_VALID_ARCHIVE/HEAD.txt"
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (V10): HEAD.txt not matching old_head alone is REFUSED" || bad "U T1 (V10): rc=$rc $out"
check "U T1 (V10): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- T1 (4a): archive location, naming, worktree-HEAD and manifest checks are each pinned in isolation --\n'

_u_case "review:old-v16" "review:new-v16"
_u_valid_detail
outside_dir="$U_TMP/outside-archive-root-$U_PR"
mkdir -p "$outside_dir"
printf '%s\n' "$U_PR_SHA" > "$outside_dir/HEAD.txt"
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c --arg a "$outside_dir" '.superseded_close.archive = $a')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (4a-location): an archive outside HERDR_ARCHIVE_ROOT alone is REFUSED" || bad "U T1 (4a-location): rc=$rc $out"
check "U T1 (4a-location): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-l2w1" "review:new-l2w1"
_u_valid_detail
# L2 (mutant W1): the 4a-location test above is also misnamed (it fails
# the naming check first), so it cannot pin the standalone containment
# check in isolation. Here the dir is correctly named superseded-<N>-*
# but still sits outside HERDR_ARCHIVE_ROOT.
outside_named_dir="$U_TMP/outside-root-l2w1/superseded-$U_PR-x"
mkdir -p "$outside_named_dir"
printf '%s\n' "$U_PR_SHA" > "$outside_named_dir/HEAD.txt"
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c --arg a "$outside_named_dir" '.superseded_close.archive = $a')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (L2/W1): a correctly-named archive OUTSIDE the archive root alone is REFUSED" \
  || bad "U T1 (L2/W1): rc=$rc $out"
check "U T1 (L2/W1): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v17" "review:new-v17"
_u_valid_detail
badname_dir="$HERDR_ARCHIVE_ROOT/$(basename "$U_WORK")/not-a-superseded-name-$U_PR"
mkdir -p "$badname_dir"
printf '%s\n' "$U_PR_SHA" > "$badname_dir/HEAD.txt"
d=$(printf '%s' "$U_VALID_DETAIL" | jq -c --arg a "$badname_dir" '.superseded_close.archive = $a')
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (4a-naming): an archive not named superseded-<PR>-* alone is REFUSED" || bad "U T1 (4a-naming): rc=$rc $out"
check "U T1 (4a-naming): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v18" "review:new-v18"
_u_valid_detail
G -C "$U_WT" commit -q --allow-empty -m "worktree moved after the archive was taken"
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (4a-worktree-head): old_head not matching the task worktree's real HEAD alone is REFUSED" || bad "U T1 (4a-worktree-head): rc=$rc $out"
check "U T1 (4a-worktree-head): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

_u_case "review:old-v19" "review:new-v19"
_u_valid_detail
mkdir -p "$U_VALID_ARCHIVE/files/tmp"
printf 'real content\n' > "$U_VALID_ARCHIVE/files/tmp/notes.md"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t12\ttmp/notes.md\n' > "$U_VALID_ARCHIVE/MANIFEST.sha256"
out=$(set_task_state "$U_RUN" "$U_TASK" completed superseded "" "$U_VALID_DETAIL" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (4a-manifest): a MANIFEST.sha256 entry that doesn't verify alone is REFUSED" || bad "U T1 (4a-manifest): rc=$rc $out"
check "U T1 (4a-manifest): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- L3 (fail closed): the manifest check REFUSES when archive_verify_manifest cannot be loaded --\n'

_u_case "review:old-l3" "review:new-l3"
_u_valid_detail
mkdir -p "$U_VALID_ARCHIVE/files/tmp"
printf 'real content\n' > "$U_VALID_ARCHIVE/files/tmp/notes.md"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t12\ttmp/notes.md\n' > "$U_VALID_ARCHIVE/MANIFEST.sha256"
L3_TMP="$U_TMP/l3"; mkdir -p "$L3_TMP/lib" "$L3_TMP/runs"
# A copy of run-registry.sh with no sibling worktree-archive.sh next to it,
# so the dynamic `. "$(dirname "${BASH_SOURCE[0]}")/worktree-archive.sh"`
# source attempt inside _valid_superseded_detail fails and
# archive_verify_manifest never becomes defined -- review PR #249 r4's F0j
# shape, isolated from the real lib/ (which is never touched).
cp "$here/lib/run-registry.sh" "$L3_TMP/lib/run-registry.sh"
sqlite3 "$(registry_db)" ".backup '$L3_TMP/runs/registry.sqlite3'"
out=$(HERDR_RUN_STATE_DIR="$L3_TMP/runs" bash -c \
  '. "$1/lib/run-registry.sh" && set_task_state "$2" "$3" completed superseded "" "$4"' \
  _ "$L3_TMP" "$U_RUN" "$U_TASK" "$U_VALID_DETAIL" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "U T1 (L3): a MANIFEST.sha256 present but archive_verify_manifest unloadable is REFUSED" \
  || bad "U T1 (L3): rc=$rc $out"
# Note: the specific "cannot load archive_verify_manifest" reason set inside
# _valid_superseded_detail is NOT what reaches the caller here -- a failed
# superseded-detail check always falls through to the generic
# _valid_proof_ref("") check, which resets _PROOF_REF_WHY to empty before
# refusing for lack of a --proof. rc alone is what distinguishes the fix
# (refused) from the L3 mutant (silently accepted, rc=0), same as every
# other V*/W* check in this section.
check "U T1 (L3): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"

printf -- '-- 4b: a symlinked archive repo_base dir is refused before anything is written through it --\n'

_u_case "review:old-4b" "review:new-4b"
u4b_root="$U_TMP/archive-root-4b"
mkdir -p "$u4b_root"
repo_base_4b="$(basename "$U_WORK")"
elsewhere_4b="$U_TMP/symlink-target-4b"
mkdir -p "$elsewhere_4b"
ln -s "$elsewhere_4b" "$u4b_root/$repo_base_4b"
mkdir -p "$U_WT/tmp"
printf 'should never reach the symlinked target\n' > "$U_WT/tmp/notes.md"
out=$(HERDR_ARCHIVE_ROOT="$u4b_root" bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" --superseded-by="$U_NEWTASK" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'symlink' \
  && ok "U (4b): a symlinked archive repo_base dir HOLDs" || bad "U (4b) exit $rc: $out"
check "U (4b): task untouched" "$(read_task "$U_RUN" "$U_TASK" | jq -r .state)" "running"
[ -z "$(find "$elsewhere_4b" -mindepth 1 2>/dev/null)" ] && ok "U (4b): nothing was written through the symlink" \
  || bad "U (4b): files appeared at the symlink target: $(find "$elsewhere_4b" -mindepth 1)"

printf -- '-- L4 (mutant B5): the symlinked repo_base check also holds via the GENERIC detached-close path --\n'

_u_m4_mk
b5_root="$U_TMP/archive-root-l4b5"
mkdir -p "$b5_root"
repo_base_b5="$(basename "$U_WORK")"
elsewhere_b5="$U_TMP/symlink-target-l4b5"
mkdir -p "$elsewhere_b5"
ln -s "$elsewhere_b5" "$b5_root/$repo_base_b5"
# B4 (above) only pins the superseded_check call site. --reason=superseded
# with NO --superseded-by on a CLOSED PR instead closes via the GENERIC
# detached-close path (_detached_pr_check, confirmed by M4's
# detail.detached_close.state assertion), which has its own, separate
# _archive_repo_base_why call site.
out=$(HERDR_ARCHIVE_ROOT="$b5_root" bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_M4_TASK" \
  --proof=".handoffs/PROOF.md#check" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q HOLD && printf '%s' "$out" | grep -qi 'symlink' \
  && ok "U T1 (L4/B5): a symlinked archive repo_base dir HOLDs via the generic detached-close path" \
  || bad "U T1 (L4/B5) exit $rc: $out"
check "U T1 (L4/B5): task untouched" "$(read_task "$U_M4_RUN" "$U_M4_TASK" | jq -r .state)" "running"
[ -z "$(find "$elsewhere_b5" -mindepth 1 2>/dev/null)" ] && ok "U T1 (L4/B5): nothing was written through the symlink" \
  || bad "U T1 (L4/B5): files appeared at the symlink target: $(find "$elsewhere_b5" -mindepth 1)"


printf -- '-- T2 (mutant V14): a proof GIVEN alongside a valid bypass still never lands in the audit row --\n'

_u_case "review:old-v14" "review:new-v14"
mkdir -p "$U_WT/tmp"
printf 'proof given but unused\n' > "$U_WT/tmp/notes.md"
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_TASK" --superseded-by="$U_NEWTASK" \
  --proof="https://github.com/org/repo/pull/1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "U T2 (mutant V14): --apply closes even with an unchecked --proof given" || bad "U T2 (mutant V14) exit $rc: $out"
_uevv14() { sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.$1') FROM events WHERE task_id='$U_TASK' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';"; }
[ -z "$(_uevv14 proof)" ] && ok "U T2 (mutant V14): the given proof never lands in the audit row" \
  || bad "U T2 (mutant V14): proof field present: $(_uevv14 proof)"

printf -- '-- T3 (mutant V15): CLOSED + superseded with NO --superseded-by and NO proof refuses BEFORE archiving --\n'

_u_m4_mk
out=$(bash "$here/close-done-workers.sh" --apply --reason=superseded --task="$U_M4_TASK" 2>&1)
rc=$?
[ "$rc" -eq 1 ] && ok "U T3 (mutant V15): exits 1 at the top level, never reaches the main scan" || bad "U T3 (mutant V15) exit $rc: $out"
check "U T3 (mutant V15): task untouched" "$(read_task "$U_M4_RUN" "$U_M4_TASK" | jq -r .state)" "running"
[ -z "$(find "$HERDR_ARCHIVE_ROOT" -maxdepth 2 -type d -name "detached-pr-$U_M4_N-*" 2>/dev/null)" ] \
  && ok "U T3 (mutant V15): no orphan archive dir was created" \
  || bad "U T3 (mutant V15): an archive dir was created despite the refusal"







printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
