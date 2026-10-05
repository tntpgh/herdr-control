#!/usr/bin/env bash
# verify-worktree-archival.sh — real-negative test suite for close-done-
# workers.sh's detached-HEAD close path and archive-worktrees.sh
# (2026-10-05-worktree-archival-and-detached-close proposal).
#
# Real git throughout: a real bare "origin" repo, real `git worktree add`,
# real `git ls-remote`/`rev-list`/`bundle`, real sha256 manifests. Only two
# EXTERNAL services are stubbed, both exported bash functions the scripts
# under test call as their own subprocess — `herdr` (never the real pane
# daemon) and `gh` (never a real GitHub call) — same pattern as
# verify-close-done-workers.sh.
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

TMP=$(mktemp -d)
export HERDR_RUN_STATE_DIR="$TMP/runs"
export HERDR_ARCHIVE_ROOT="$TMP/archive"

CALLS=$(mktemp)
export CALLS
herdr() {
  printf '%s\n' "$1 $2" >> "$CALLS"
  case "$1 $2" in
    "pane list")  printf '{"result":{"panes":[{"pane_id":"pD","agent_status":"idle","terminal_id":"birthD-live"}]}}\n' ;;
    "pane close") : ;;
    *) printf '{}\n' ;;
  esac
}
export -f herdr

# gh stub: `gh pr view <n> -R <slug> --json ... -q <jq>` (one object) and
# `gh pr list -R <slug> --head <branch> --state all --json ... -q <jq>`
# (one-element ARRAY, matching the real shape _gh_pr_lookup's --head jq
# filter expects: `sort_by(...) | .[0] // empty | ...`). GH_PRS is
# "<slug>#<n> <branch> <STATE> <merge-oid|->", one PR per line.
export GH_PRS="org/repo#42 pr-42 MERGED a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
org/repo#43 pr-43 OPEN -
org/repo#44 pr-44 CLOSED -
rtree/demo#1 feat-merged MERGED b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
rtree/demo#2 feat-open OPEN -
rtree/demo#3 feat-closed CLOSED -
rtree/demo#4 feat-pullonly MERGED c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
rtree/demo#5 feat-dirty MERGED d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"
gh() {
  local cmd="$1 $2" slug="" q="" head="" n="" prev="" a key br st oid num
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
    if [ "$cmd" = "pr view" ]; then
      jq -nc --arg s "$st" --arg u "https://github.com/$slug/pull/$num" --arg o "$oid" \
        '{state:$s, url:$u, mergeCommit:(if $o=="-" then null else {oid:$o} end)}' | jq -r "$q"
    else
      jq -nc --arg s "$st" --arg u "https://github.com/$slug/pull/$num" --arg o "$oid" \
        '[{state:$s, url:$u, mergeCommit:(if $o=="-" then null else {oid:$o} end)}]' | jq -r "$q"
    fi
    return 0
  done <<<"$GH_PRS"
  echo "GraphQL: Could not resolve to a PullRequest" >&2
  return 1
}
export -f gh

# shellcheck source=lib/run-registry.sh
. "$here/lib/run-registry.sh"

#######################################################################
# Section A: close-done-workers.sh's detached-HEAD close path
#######################################################################
printf '== Section A: close-done-workers.sh detached-HEAD close path ==\n'

A_TMP="$TMP/A"; mkdir -p "$A_TMP"
A_ORIGIN="$A_TMP/origin.git"
git init -q --bare "$A_ORIGIN"
A_WORK="$A_TMP/work"
git init -q -b main "$A_WORK"
git -C "$A_WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'tmp/\n.handoffs/\n' > "$A_WORK/.gitignore"
git -C "$A_WORK" add .gitignore
git -C "$A_WORK" -c user.email=t@t -c user.name=t commit -q -m gitignore
git -C "$A_WORK" remote add origin "$A_ORIGIN"
git -C "$A_WORK" push -q origin main

for n in 42 43 44; do
  git -C "$A_WORK" switch -q -c "pr-$n" main
  git -C "$A_WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "pr $n work"
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
git -C "$wtA" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "extra local commit"
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
check "positive: reason recorded is shipped" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.reason') FROM events WHERE task_id='taskA6' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';")" \
  "shipped"
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
B_ORIGIN="$B_TMP/origin.git"
git init -q --bare "$B_ORIGIN"
B_PRIMARY="$B_TMP/demo"
git init -q -b main "$B_PRIMARY"
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'tmp/\n.handoffs/\n' > "$B_PRIMARY/.gitignore"
git -C "$B_PRIMARY" add .gitignore
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q -m gitignore
git -C "$B_PRIMARY" remote add origin "$B_ORIGIN"
git -C "$B_PRIMARY" push -q origin main
git -C "$B_PRIMARY" config herdr.origin-slug rtree/demo

B_WT="$B_TMP/worktrees"; mkdir -p "$B_WT"

# 1. feat-merged: clean, reachable via a normal pushed branch, MERGED PR.
git -C "$B_PRIMARY" switch -q -c feat-merged main
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat-merged work"
git -C "$B_PRIMARY" push -q origin feat-merged
git -C "$B_PRIMARY" fetch -q origin
git -C "$B_PRIMARY" switch -q main
wtMerged="$B_WT/feat-merged"; git -C "$B_PRIMARY" worktree add -q "$wtMerged" feat-merged

# 2. feat-livepane: reachable, but a non-terminal registry row owns it.
git -C "$B_PRIMARY" switch -q -c feat-livepane main
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat-livepane work"
git -C "$B_PRIMARY" push -q origin feat-livepane
git -C "$B_PRIMARY" fetch -q origin
git -C "$B_PRIMARY" switch -q main
wtLivepane="$B_WT/feat-livepane"; git -C "$B_PRIMARY" worktree add -q "$wtLivepane" feat-livepane
register_task runB2 taskB2 w c cp cb pLive birthLive "$B_PRIMARY" "$wtLivepane" "live-pane-owner" || bad "register taskB2"
set_task_state runB2 taskB2 running || bad "taskB2 -> running"

# 3. feat-unreachable: a local-only commit, never pushed, no PR.
git -C "$B_PRIMARY" switch -q -c feat-unreachable main
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local only, never pushed"
git -C "$B_PRIMARY" switch -q main
wtUnreachable="$B_WT/feat-unreachable"; git -C "$B_PRIMARY" worktree add -q "$wtUnreachable" feat-unreachable

# 4. feat-pullonly: pushed ONLY as refs/pull/4/head, never as a normal
#    branch -- reachable ONLY via the refs/pull/N/head fallback.
git -C "$B_PRIMARY" switch -q -c feat-pullonly main
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat-pullonly work"
git -C "$B_PRIMARY" push -q origin feat-pullonly:refs/pull/4/head
git -C "$B_PRIMARY" switch -q main
wtPullonly="$B_WT/feat-pullonly"; git -C "$B_PRIMARY" worktree add -q "$wtPullonly" feat-pullonly

# 5. feat-open: reachable, OPEN PR.
git -C "$B_PRIMARY" switch -q -c feat-open main
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat-open work"
git -C "$B_PRIMARY" push -q origin feat-open
git -C "$B_PRIMARY" fetch -q origin
git -C "$B_PRIMARY" switch -q main
wtOpen="$B_WT/feat-open"; git -C "$B_PRIMARY" worktree add -q "$wtOpen" feat-open

# 6. feat-closed: reachable, CLOSED-unmerged PR.
git -C "$B_PRIMARY" switch -q -c feat-closed main
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat-closed work"
git -C "$B_PRIMARY" push -q origin feat-closed
git -C "$B_PRIMARY" fetch -q origin
git -C "$B_PRIMARY" switch -q main
wtClosed="$B_WT/feat-closed"; git -C "$B_PRIMARY" worktree add -q "$wtClosed" feat-closed

# 7. feat-dirty: reachable, MERGED PR, plus tracked/untracked/ignored content.
git -C "$B_PRIMARY" switch -q -c feat-dirty main
printf 'original\n' > "$B_PRIMARY/tracked.txt"
git -C "$B_PRIMARY" add tracked.txt
git -C "$B_PRIMARY" -c user.email=t@t -c user.name=t commit -q -m "add tracked.txt"
git -C "$B_PRIMARY" push -q origin feat-dirty
git -C "$B_PRIMARY" fetch -q origin
git -C "$B_PRIMARY" switch -q main

wtDirty="$B_WT/feat-dirty"; git -C "$B_PRIMARY" worktree add -q "$wtDirty" feat-dirty
printf 'original\nmore\n' > "$wtDirty/tracked.txt"
printf 'untracked content\n' > "$wtDirty/untracked.txt"
mkdir -p "$wtDirty/tmp/sub"
printf 'ignored content\n' > "$wtDirty/tmp/sub/ignored.txt"
exp_tracked_sha=$(shasum -a 256 "$wtDirty/tracked.txt" | cut -d' ' -f1)
exp_untracked_sha=$(shasum -a 256 "$wtDirty/untracked.txt" | cut -d' ' -f1)
exp_ignored_sha=$(shasum -a 256 "$wtDirty/tmp/sub/ignored.txt" | cut -d' ' -f1)

primary_still_main() {
  [ "$(git -C "$B_PRIMARY" symbolic-ref -q --short HEAD 2>/dev/null)" = main ]
}

printf '== archive-worktrees.sh dry run: previews every scenario, mutates nothing ==\n'
out=$(bash "$here/archive-worktrees.sh" "$B_PRIMARY" 2>&1)
printf '%s\n' "$out" | grep -qF "$wtLivepane" && printf '%s\n' "$out" | grep -A0 "$wtLivepane" | grep -q HOLD \
  && ok "B: feat-livepane HOLDs (live registry row)" || bad "B dry-run feat-livepane: $out"
printf '%s\n' "$out" | grep -F "$wtLivepane" | grep -qi 'running/blocked' \
  && ok "B: feat-livepane HOLD names the live task" || bad "B dry-run feat-livepane detail: $out"
printf '%s\n' "$out" | grep -F "$wtUnreachable" | grep -q HOLD \
  && printf '%s\n' "$out" | grep -F "$wtUnreachable" | grep -qi 'no remote ref' \
  && ok "B: feat-unreachable HOLDs (no remote, no PR)" || bad "B dry-run feat-unreachable: $out"
printf '%s\n' "$out" | grep -F "$wtOpen" | grep -q HOLD \
  && printf '%s\n' "$out" | grep -F "$wtOpen" | grep -qi OPEN \
  && ok "B: feat-open HOLDs (OPEN PR)" || bad "B dry-run feat-open: $out"
printf '%s\n' "$out" | grep -F "$wtClosed" | grep -q HOLD \
  && printf '%s\n' "$out" | grep -F "$wtClosed" | grep -qi 'disposition=abandoned\|superseded' \
  && ok "B: feat-closed HOLDs (CLOSED, no --disposition)" || bad "B dry-run feat-closed: $out"
printf '%s\n' "$out" | grep -F "$wtMerged" | grep -q 'archive' \
  && ! printf '%s\n' "$out" | grep -F "$wtMerged" | grep -q HOLD \
  && ok "B: feat-merged previews archivable, not held" || bad "B dry-run feat-merged: $out"
printf '%s\n' "$out" | grep -F "$wtPullonly" | grep -q 'archive' \
  && ! printf '%s\n' "$out" | grep -F "$wtPullonly" | grep -q HOLD \
  && ok "B: feat-pullonly reachable via refs/pull/4/head fallback, previews archivable" \
  || bad "B dry-run feat-pullonly: $out"
printf '%s\n' "$out" | grep -F "$wtDirty" | grep -q HOLD \
  && printf '%s\n' "$out" | grep -F "$wtDirty" | grep -qi 'dirty: uncommitted work' \
  && ok "B: feat-dirty HOLDs in preview (dirty tracked/untracked work, never swept by default)" \
  || bad "B dry-run feat-dirty: $out"
printf '%s\n' "$out" | grep -qF "$B_PRIMARY " \
  && bad "B dry-run: the PRIMARY checkout was printed as a row" \
  || ok "B dry-run: the primary checkout was never printed as a row"

printf '== archive-worktrees.sh --apply (batch, no --branch/--disposition/--include-dirty) ==\n'
out=$(bash "$here/archive-worktrees.sh" --apply "$B_PRIMARY" 2>&1)
[ ! -d "$wtMerged" ] && ok "B apply: feat-merged removed" || bad "B apply: feat-merged still present"
[ ! -d "$wtPullonly" ] && ok "B apply: feat-pullonly removed" || bad "B apply: feat-pullonly still present"

# required real negative: a dirty worktree in a batch --apply stays
# completely untouched -- not archived, not removed, not even partially
# copied -- "never touch the dirty list" unless named explicitly.
printf '%s\n' "$out" | grep -F "$wtDirty" | grep -q HOLD \
  && printf '%s\n' "$out" | grep -F "$wtDirty" | grep -qi 'dirty: uncommitted work' \
  && ok "B apply: a dirty worktree HOLDs in a batch apply, not archived" \
  || bad "B apply: feat-dirty was not held for being dirty: $out"
[ -d "$wtDirty" ] && ok "B apply: feat-dirty's directory still exists (untouched)" || bad "B apply: feat-dirty directory gone"
[ "$(shasum -a 256 "$wtDirty/tracked.txt" 2>/dev/null | cut -d' ' -f1)" = "$exp_tracked_sha" ] \
  && ok "B apply: feat-dirty's tracked.txt is byte-for-byte untouched" || bad "B apply: feat-dirty's tracked.txt was modified"
[ -f "$wtDirty/untracked.txt" ] && ok "B apply: feat-dirty's untracked.txt still present (not swept into an archive)" \
  || bad "B apply: feat-dirty's untracked.txt is gone"
dest_dirty_batch=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-dirty-*' 2>/dev/null | head -1)
[ -z "$dest_dirty_batch" ] && ok "B apply: no archive directory was ever created for the dirty worktree" \
  || bad "B apply: an archive directory was created for the dirty worktree despite the HOLD: $dest_dirty_batch"

[ -d "$wtLivepane" ] && ok "B apply: feat-livepane (live) was NEVER removed" || bad "B apply: feat-livepane disappeared"
[ -d "$wtUnreachable" ] && ok "B apply: feat-unreachable (unreachable) was NEVER removed" || bad "B apply: feat-unreachable disappeared"
[ -d "$wtOpen" ] && ok "B apply: feat-open (OPEN PR) was NEVER removed" || bad "B apply: feat-open disappeared"
[ -d "$wtClosed" ] && ok "B apply: feat-closed (no disposition) was NEVER removed" || bad "B apply: feat-closed disappeared"
[ -d "$B_PRIMARY/.git" ] && primary_still_main && ok "B apply: the primary checkout is untouched (still on main)" \
  || bad "B apply: the primary checkout was disturbed"

dest_pullonly=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-pullonly-*' 2>/dev/null | head -1)
[ -n "$dest_pullonly" ] && grep -qF 'disposition=merged' "$dest_pullonly/DISPOSITION.txt" 2>/dev/null \
  && ok "B: feat-pullonly DISPOSITION.txt records merged (reachable via pull-ref fallback)" \
  || bad "B: feat-pullonly disposition record missing/wrong"

printf '== archive-worktrees.sh --apply --branch=feat-closed --disposition=abandoned ==\n'
out=$(bash "$here/archive-worktrees.sh" --apply --branch=feat-closed --disposition=abandoned "$B_PRIMARY" 2>&1)
[ ! -d "$wtClosed" ] && ok "B: feat-closed removed once an explicit --disposition was given" || bad "B: feat-closed still present: $out"
dest_closed=$(find "$HERDR_ARCHIVE_ROOT/demo" -maxdepth 1 -type d -name 'feat-closed-*' 2>/dev/null | head -1)
[ -n "$dest_closed" ] && grep -qF 'disposition=abandoned' "$dest_closed/DISPOSITION.txt" 2>/dev/null \
  && ok "B: feat-closed DISPOSITION.txt records the explicit abandoned disposition" \
  || bad "B: feat-closed disposition record missing/wrong"
[ -d "$wtLivepane" ] && [ -d "$wtUnreachable" ] && [ -d "$wtOpen" ] && [ -d "$wtDirty" ] \
  && ok "B: the scoped --branch=feat-closed apply touched nothing else" \
  || bad "B: the scoped --branch=feat-closed apply removed an unrelated worktree"

printf '== archive-worktrees.sh --apply --branch=feat-dirty --include-dirty: the explicit opt-in ==\n'
out=$(bash "$here/archive-worktrees.sh" --apply --branch=feat-dirty --include-dirty "$B_PRIMARY" 2>&1)
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
  [ -f "$dest_dirty/branch.bundle" ] && git bundle verify "$dest_dirty/branch.bundle" >/dev/null 2>&1 \
    && ok "B: feat-dirty's git bundle exists and verifies" || bad "B: feat-dirty bundle missing or fails verify"
  grep -qF 'disposition=merged' "$dest_dirty/DISPOSITION.txt" 2>/dev/null \
    && ok "B: feat-dirty DISPOSITION.txt records merged" || bad "B: feat-dirty DISPOSITION.txt wrong/missing"
else
  bad "B: no archive manifest found for feat-dirty under $HERDR_ARCHIVE_ROOT/demo after --include-dirty"
fi
[ -d "$wtDirty" ] && printf '%s\n' "$out" | grep -F "$wtDirty" | grep -q LEFTOVER \
  && ok "B: --include-dirty archives but git worktree remove still correctly refuses (never --force)" \
  || bad "B: feat-dirty outcome wrong after --include-dirty (expected archived+LEFTOVER): $out"

[ -d "$B_PRIMARY/.git" ] && primary_still_main \
  && ok "B: the primary checkout is STILL untouched after every apply run" \
  || bad "B: the primary checkout was disturbed"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
