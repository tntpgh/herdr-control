#!/usr/bin/env bash
# verify-worktree-archival.sh — real-negative test suite for close-done-
# workers.sh's detached-HEAD close path and archive-worktrees.sh
# (2026-10-05-worktree-archival-and-detached-close proposal; review r1 of
# PR #236, whose probes P1-P8 are Section P below, and review r2, whose
# probes are Section R).
#
# Real git throughout: a real bare "origin" repo, real `git worktree add`,
# real `git ls-remote`/`rev-list`/`bundle`, real sha256 manifests, real
# lsof. Only two EXTERNAL services are stubbed, both exported bash functions
# the scripts under test call as their own subprocess — `herdr` (never the
# real pane daemon) and `gh` (never a real GitHub call) — same pattern as
# verify-close-done-workers.sh. Section R adds a pass-through `shasum` on
# PATH whose only job is to run a hook mid-archive. Every repo, worktree,
# registry, archive root and code root lives under one mktemp dir; nothing
# here touches ~/Code.
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

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
