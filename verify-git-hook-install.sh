#!/usr/bin/env bash
# verify-git-hook-install.sh — prove install-git-hooks.sh only ever touches what
# it claims to touch.
#
# This script rewrites .git/hooks in ~18 real repositories. The dangerous
# failures are not "it did not install"; they are "it clobbered a hook someone
# wrote", "it opted in a repo that deliberately runs no scan", and "--undo left
# a repo with no secret scan at all". Each has a case here.
#
# Runs entirely against a synthetic $CODE_ROOT — never the real ~/Code.
#
#   bash verify-git-hook-install.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
INSTALLER="$here/install-git-hooks.sh"
[ -r "$INSTALLER" ] || { echo "no installer at $INSTALLER" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# The SOURCE of truth in the repo...
TRACKED="$here/git-hooks/secret-scan-pre-commit.sh"
# ...and where --apply DEPLOYS it, which is what the shims must exec. Pointing
# shims into the working tree broke every commit in every repo the moment the
# checkout moved to a branch without git-hooks/ (observed 2026-09-15), so the
# deployed path is the contract now. The suite overrides it to stay in its own
# sandbox.
DEPLOY_DIR="$WORK/deployed"
DEPLOYED="$DEPLOY_DIR/secret-scan-pre-commit.sh"
LEGACY="$HOME/.claude/hooks/secret-scan-pre-commit.sh"

# ── a synthetic fleet ────────────────────────────────────────────────────────
ROOT="$WORK/Code"; mkdir -p "$ROOT"

mk_repo() {                         # <name> -> a real repo, no hooks
    local r="$ROOT/$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main
    printf '%s' "$r"
}
put_hook() {                        # <repo> <hook name> <content...>
    printf '%s\n' "${@:3}" > "$1/.git/hooks/$2"
    chmod +x "$1/.git/hooks/$2"
}
run() {                             # <mode...> -> rc; output in $OUT
    OUT="$(CODE_ROOT="$ROOT" HERDR_HOOK_DEPLOY_DIR="$DEPLOY_DIR" bash "$INSTALLER" "$@" 2>&1)"
    return $?
}

# Each spelling of the fleet shim that actually exists on this machine. The
# tilde form was misclassified as a bespoke hook by the first draft, which would
# have left one repo behind silently.
SHIM_EXPANDED="$LEGACY"
R_EXPANDED="$(mk_repo shim-expanded)"
put_hook "$R_EXPANDED" pre-commit '#!/usr/bin/env bash' "exec bash \"$SHIM_EXPANDED\""
put_hook "$R_EXPANDED" pre-merge-commit '#!/usr/bin/env bash' "exec bash \"$SHIM_EXPANDED\""

R_HOME="$(mk_repo shim-home)"
put_hook "$R_HOME" pre-commit '#!/usr/bin/env bash' 'exec bash "$HOME/.claude/hooks/secret-scan-pre-commit.sh"'

R_TILDE="$(mk_repo shim-tilde)"
put_hook "$R_TILDE" pre-commit '#!/usr/bin/env bash' 'exec bash ~/.claude/hooks/secret-scan-pre-commit.sh "$@"'

# A repo whose pre-commit does REAL work of its own as well as calling the scan.
# Replacing it would delete that work.
R_OWN="$(mk_repo has-own-hook)"
put_hook "$R_OWN" pre-commit '#!/usr/bin/env bash' 'npm run lint || exit 1' \
    'exec bash ~/.claude/hooks/secret-scan-pre-commit.sh'

# A repo that runs no secret scan at all. Out of scope by decision, not oversight.
R_NONE="$(mk_repo no-scan)"
put_hook "$R_NONE" pre-commit '#!/usr/bin/env bash' 'echo lint-only'

# A repo that REDIRECTS its hooks with core.hooksPath. git then ignores
# `.git/hooks` entirely, so a hook written there is installed, executable,
# counted as coverage — and never runs. Same failure shape as a shim pointing
# into a deleted worktree, one config key over.
R_REDIR="$(mk_repo hooks-redirected)"
mkdir -p "$R_REDIR/.githooks"
git -C "$R_REDIR" config core.hooksPath "$R_REDIR/.githooks"
printf '#!/usr/bin/env bash\nexec bash ~/.claude/hooks/secret-scan-pre-commit.sh\n' \
    > "$R_REDIR/.githooks/pre-commit"
chmod +x "$R_REDIR/.githooks/pre-commit"

# Not a git repository, and a linked worktree of shim-expanded.
mkdir -p "$ROOT/just-a-dir"
git -C "$R_EXPANDED" -c user.email=tnt@teamthurber.com -c user.name=t commit -q \
    --allow-empty -m init --no-verify
git -C "$R_EXPANDED" worktree add -q "$ROOT/a-worktree" -b wt >/dev/null 2>&1

# ═════════════════════════════════════════════════════════════════════════════
# The marker every generation of the shim carries. A stale-shim fixture without
# it is not a stale shim, it is somebody else's file, and the suite would then
# be testing the wrong rule.
MARKER="# installed by herdr-control install-git-hooks.sh"

printf '== DRY RUN changes nothing on disk ==\n'
before="$(cat "$R_EXPANDED/.git/hooks/pre-commit")"
run --dry-run
[ "$(cat "$R_EXPANDED/.git/hooks/pre-commit")" = "$before" ] \
    && ok "a dry run leaves hook files byte-identical" || bad "dry run wrote to disk"
printf '%s' "$OUT" | grep -q 'DRY RUN' && ok "says it is a dry run" || bad "silent about being a dry run"
run                          # no arguments at all
[ "$(cat "$R_EXPANDED/.git/hooks/pre-commit")" = "$before" ] \
    && ok "NO ARGUMENTS is a dry run, not an install" || bad "bare invocation mutated 18 repos' worth of hooks"

printf '== --apply: every spelling of the fleet shim is repointed ==\n'
run --apply
for r in "$R_EXPANDED" "$R_HOME" "$R_TILDE"; do
    n="$(basename "$r")"
    if grep -qF "$DEPLOYED" "$r/.git/hooks/pre-commit" 2>/dev/null; then
        ok "$n/pre-commit now points at the deployed copy"
    else
        bad "$n/pre-commit not repointed: $(cat "$r/.git/hooks/pre-commit" 2>/dev/null)"
    fi
done
[ -x "$R_HOME/.git/hooks/pre-merge-commit" ] && grep -qF "$DEPLOYED" "$R_HOME/.git/hooks/pre-merge-commit" \
    && ok "a MISSING pre-merge-commit is created (the merge path was unscanned)" \
    || bad "pre-merge-commit not installed where absent"
[ -x "$R_TILDE/.git/hooks/pre-commit" ] && ok "written hooks are executable" || bad "hook not executable"
# The THIRD hook. `pre-commit`/`pre-merge-commit` only fire when `git commit`
# creates the commit, so `git am`, `cherry-pick`, `revert` and every `rebase`
# replay wrote commits no scan ever read. `pre-push` is where that class is
# caught, and it MUST carry `--push`: the same shim without the flag runs the
# INDEX scan during a push, where the index is unrelated to what is being sent
# — it would exit 0 on a clean index and read as a guard that is working.
if [ -x "$R_HOME/.git/hooks/pre-push" ] && grep -qF "$DEPLOYED" "$R_HOME/.git/hooks/pre-push"; then
    ok "pre-push is installed (git am / cherry-pick / rebase are commit-hook-free)"
else
    bad "pre-push not installed: $(cat "$R_HOME/.git/hooks/pre-push" 2>/dev/null)"
fi
grep -qF -- "--push" "$R_HOME/.git/hooks/pre-push" 2>/dev/null \
    && ok "and it execs the scanner in PUSH mode, not index mode" \
    || bad "pre-push shim is missing --push: $(cat "$R_HOME/.git/hooks/pre-push" 2>/dev/null)"
# A shim pointing at the right scanner WITHOUT the flag must be treated as
# needing a rewrite, not as already correct — otherwise a half-installed guard
# survives every future --apply.
printf '#!/usr/bin/env bash\n%s\nexec bash %s\n' "$MARKER" "$DEPLOYED" > "$R_HOME/.git/hooks/pre-push"
chmod +x "$R_HOME/.git/hooks/pre-push"
run --apply
grep -qF -- "--push" "$R_HOME/.git/hooks/pre-push" \
    && ok "a pre-push shim missing --push is repaired on the next --apply" \
    || bad "left a pre-push shim running the index scan"
# ... and one missing `"$@"`, which an earlier state of this very branch wrote.
# git passes `pre-push <remote-name> <remote-url>`; without the forward the
# scanner has no remote, so every NEW-branch push is refused with "give this
# remote a name" — advice that does not apply to an ordinary origin, leaving
# no compliant fix. A substring check cannot see this, which is why
# already_ours compares the file against the body we would write.
printf '#!/usr/bin/env bash\n%s\nexec bash %s --push\n' "$MARKER" "$DEPLOYED" > "$R_HOME/.git/hooks/pre-push"
chmod +x "$R_HOME/.git/hooks/pre-push"
run --apply
grep -qF -- '"$@"' "$R_HOME/.git/hooks/pre-push" \
    && ok "a pre-push shim that does not forward git's argv is repaired" \
    || bad "left a shim with no remote name: $(cat "$R_HOME/.git/hooks/pre-push")"
# And a file that merely MENTIONS the deployed path must not count as ours.
# The safe outcome is NOT to overwrite it — a hook this script did not write
# is never clobbered — but it must be reported as foreign and must NOT be
# counted as coverage, which is what the old substring check did.
printf '#!/usr/bin/env bash\nexit 0   # exec bash %s --push "$@"\n' "$DEPLOYED" \
    > "$R_HOME/.git/hooks/pre-push"
chmod +x "$R_HOME/.git/hooks/pre-push"
run --apply
grep -q '^exit 0' "$R_HOME/.git/hooks/pre-push" \
    && ok "a hook that only mentions the scanner is left alone, not clobbered" \
    || bad "overwrote a hook this script did not write"
printf '%s' "$OUT" | grep -q 'shim-home/pre-push .*has its OWN hook' \
    && ok "and is reported as foreign rather than silently accepted" \
    || bad "an unrecognised pre-push was not reported: $(printf '%s' "$OUT" | grep pre-push)"
# VERIFY prints counts, not a per-repo verdict for the healthy cases, so the
# observable is the bucket: a repo whose pre-push we do not recognise must
# land OUTSIDE "on the TRACKED scanner". Other fixtures are fully tracked, so
# this asserts the not-tracked bucket is non-empty rather than a global zero.
printf '%s' "$OUT" | grep -qE 'untracked ~/\.claude copy: *[1-9]' \
    && ok "and the repo is NOT counted as covered" \
    || bad "counted a repo with an unrecognised pre-push as fully tracked: $(printf '%s' "$OUT" | grep -E 'TRACKED|untracked')"
# ... and it gets its OWN bucket, not the "untracked ~/.claude copy" one. That
# label reads as coverage and there is none: the untracked scanner never had a
# push mode, so git am / cherry-pick / revert / rebase replays in that repo
# reach the remote unscanned. Review carried this forward as a LOW; it becomes
# real the first time someone writes a repo-local pre-push.
printf '%s' "$OUT" | grep -qE 'OWN PRE-PUSH: shim-home' \
    && ok "a repo with its own pre-push is named, not filed under coverage" \
    || bad "no OWN PRE-PUSH line: $(printf '%s' "$OUT" | grep -E 'OWN|untracked')"
printf '%s' "$OUT" | grep -qE 'OWN pre-push \(no push scan\): *[1-9]' \
    && ok "and counted in a bucket whose name says its push path is unscanned" \
    || bad "the own-pre-push counter did not move: $(printf '%s' "$OUT" | grep -E 'OWN|untracked')"
# Restore a correct shim for the rest of the suite.
run --apply >/dev/null 2>&1 || true
rm -f "$R_HOME/.git/hooks/pre-push"
run --apply
# core.hooksPath: the hooks must land where GIT looks, not where we assume.
if [ -x "$R_REDIR/.githooks/pre-commit" ] && grep -qF "$DEPLOYED" "$R_REDIR/.githooks/pre-commit"; then
    ok "a core.hooksPath repo is guarded in the dir git actually reads"
else
    bad "wrote to .git/hooks in a repo that redirects hooksPath: $(cat "$R_REDIR/.githooks/pre-commit" 2>/dev/null)"
fi
[ -x "$R_REDIR/.githooks/pre-push" ] && grep -qF -- "--push" "$R_REDIR/.githooks/pre-push" \
    && ok "and its push path too" || bad "core.hooksPath repo has no working pre-push"
[ ! -e "$R_REDIR/.git/hooks/pre-commit" ] \
    && ok "and NOTHING was written to the dir git ignores" \
    || bad "installed a hook git will never run (.git/hooks with hooksPath set)"
printf '%s' "$OUT" | grep -q 'core.hooksPath ->' \
    && ok "the redirect is reported, not silently followed" \
    || bad "followed a hooksPath redirect without saying so"

printf '== what it must NOT touch ==\n'
grep -q 'npm run lint' "$R_OWN/.git/hooks/pre-commit" \
    && ok "a repo's own hook is left byte-for-byte alone" \
    || bad "clobbered a bespoke pre-commit: $(cat "$R_OWN/.git/hooks/pre-commit")"
# Its MERGE path is still unscanned, and a bespoke pre-commit is not a decision
# about merges — the repo already accepts this scan on ordinary commits. So the
# pre-merge-commit IS installed while the pre-commit is left alone. The two
# hooks are judged independently, which is the only way to protect the merge
# path of a repo that has customised the commit path.
[ -x "$R_OWN/.git/hooks/pre-merge-commit" ] && grep -qF "$DEPLOYED" "$R_OWN/.git/hooks/pre-merge-commit" \
    && ok "its unscanned MERGE path is still closed (hooks judged independently)" \
    || bad "left the merge path of a customised repo unscanned"
grep -q 'lint-only' "$R_NONE/.git/hooks/pre-commit" && [ ! -e "$R_NONE/.git/hooks/pre-merge-commit" ] \
    && ok "a repo running no secret scan is not opted in" \
    || bad "opted in a repo that had made a different choice"
[ ! -e "$ROOT/a-worktree/.git/hooks" ] \
    && ok "a linked worktree is skipped (its hooks dir is the parent's)" \
    || bad "wrote hooks into a worktree"
printf '%s' "$OUT" | grep -q 'worktree — covered by its parent' \
    && ok "and says so rather than staying silent" || bad "worktree skipped without explanation"

printf '== idempotence ==\n'
snapshot="$(cat "$R_EXPANDED/.git/hooks/pre-commit")"
run --apply
[ "$(cat "$R_EXPANDED/.git/hooks/pre-commit")" = "$snapshot" ] \
    && ok "a second --apply changes nothing" || bad "re-run rewrote an already-correct hook"
# `changed=0` is the idempotence claim. The companion count is COMPUTED from
# what is on disk rather than hardcoded: it was pinned at `unchanged=7`, so
# adding the third hook per repo (pre-push, the one that closes `git am` and
# the sequencer paths) failed this suite on an incidental constant instead of
# on any behaviour. Each opted-in repo contributes one row per hook it carries.
# Any hooks dir, not just `.git/hooks`: one fixture redirects core.hooksPath,
# and the count has to follow the installer's own resolution.
on_disk=$(find "$ROOT" -type f \
          \( -name pre-commit -o -name pre-merge-commit -o -name pre-push \) \
          -exec grep -lF "$DEPLOYED" {} + 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$OUT" | grep -q "changed=0 unchanged=$on_disk" \
    && ok "re-run reports 0 changed and $on_disk already correct" \
    || bad "re-run counts wrong (expected unchanged=$on_disk): $(printf '%s' "$OUT" | grep 'this run')"
# The backup must still be the ORIGINAL hook, not this script's own output —
# otherwise --undo restores an install instead of undoing one.
grep -qF 'secret-scan-pre-commit.sh' "$R_TILDE/.git/hooks/pre-commit$(printf '.pre-herdr-guard')" \
    && ! grep -qF "$TRACKED" "$R_TILDE/.git/hooks/pre-commit.pre-herdr-guard" \
    && ok "the backup still holds the pre-install hook after a second --apply" \
    || bad "backup overwritten with our own hook: $(cat "$R_TILDE/.git/hooks/pre-commit.pre-herdr-guard" 2>/dev/null)"

printf '== --undo restores, and never leaves a repo unguarded ==\n'
run --undo
grep -qF 'secret-scan-pre-commit.sh' "$R_TILDE/.git/hooks/pre-commit" \
    && ! grep -qF "$TRACKED" "$R_TILDE/.git/hooks/pre-commit" \
    && ok "a replaced hook is restored to what was there before" \
    || bad "undo did not restore: $(cat "$R_TILDE/.git/hooks/pre-commit" 2>/dev/null)"
# shim-home had NO pre-merge-commit before. Undo must not hand the repo back
# with our hook still in place, and must not leave the merge path scanned by
# a file we just deleted.
if [ -e "$R_HOME/.git/hooks/pre-merge-commit" ]; then
    grep -qF "$TRACKED" "$R_HOME/.git/hooks/pre-merge-commit" \
        && bad "undo left our hook behind" \
        || ok "a hook we created falls back to the untracked scanner rather than vanishing"
else
    ok "a hook we created is removed when there is no scanner to fall back to"
fi
# pre-push is the one hook whose "fall back to the untracked scanner" is
# HARMFUL. No repo had a pre-push before this change, so there is never a
# backup, and the legacy path is a forwarder into the deployed scanner with no
# `--push`: git would call it `pre-push origin <url>`, `$1` would be `origin`,
# and the scanner would run its INDEX scan during a push — judging whatever is
# STAGED, so the push goes unscanned while an executable "secret-scan" hook
# sits there and VERIFY files the repo as covered.
if [ -e "$R_HOME/.git/hooks/pre-push" ]; then
    bad "undo left a pre-push behind: $(cat "$R_HOME/.git/hooks/pre-push")"
else
    ok "undo REMOVES a pre-push rather than reverting it to an index scan"
fi
grep -q 'npm run lint' "$R_OWN/.git/hooks/pre-commit" \
    && ok "undo still does not touch a bespoke hook" || bad "undo damaged a foreign hook"
run --undo
ok "--undo is safe to run twice (rc=$?)"

printf '== refusals ==\n'
run --nonsense; rc=$?
[ "$rc" = 2 ] && ok "an unknown option exits 2 rather than guessing" || bad "unknown option rc=$rc"
OUT="$(CODE_ROOT="$ROOT" bash "$INSTALLER" --help 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q -- '--undo' \
    && ok "--help documents --undo" || bad "help output unusable"
# A scanner that does not parse must never be pointed at 18 repos: it would fail
# every commit and teach --no-verify, which is how a guard stops guarding.
printf 'if then fi(\n' > "$WORK/broken.sh"
# HERDR_HOOK_DEPLOY_DIR is redirected here too. Unmutated this row is safe —
# the `bash -n` refusal fires before anything is written — but with the single
# guard it NAMES mutated away it would mkdir the LIVE fleet directory, and with
# three guards off it would write `if then fi(` over the live scanner. It was
# the only installer invocation in this file still pointing at the real path.
OUT="$(CODE_ROOT="$ROOT" HERDR_HOOK_DEPLOY_DIR="$WORK/broken-deploy" bash -c "cd $WORK && mkdir -p gh && cp broken.sh gh/secret-scan-pre-commit.sh && sed 's|\$here/git-hooks|$WORK/gh|' $INSTALLER > $WORK/i.sh && HERDR_HOOK_DEPLOY_DIR=$WORK/broken-deploy bash $WORK/i.sh --apply" 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "refuses to deploy a scanner that is not valid bash" || bad "deployed a broken scanner (rc=$rc)"

# ===== which revision the fleet runs =====
#
# All 18 repos executed an OPEN PR's scanner on 2026-09-16, which allowed three
# PII cases origin/main blocks. Nothing in this suite noticed, because every
# other check here describes the SHIMS — and the shims were perfect: they all
# pointed at the one deployed copy. What was missing was any statement about
# WHAT that copy is.
#
# The rows below were written twice. The first set passed a green run while a
# security review found three HIGH bypasses, so each row now names the bypass
# it closes, and the fixtures build the AWKWARD repo shapes (renamed remote,
# single-branch clone, no .git, inherited GIT_DIR) rather than only the happy
# one.
_iso() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }
_prov_repo() {                # <dir> [days-old] -> repo with origin/main
  rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"
  git init -q "$WORK/$1/src"
  git -C "$WORK/$1/src" config user.email t@e.c
  git -C "$WORK/$1/src" config user.name t
  mkdir -p "$WORK/$1/src/git-hooks"
  cp "$here/git-hooks/secret-scan-pre-commit.sh" "$WORK/$1/src/git-hooks/secret-scan-pre-commit.sh"
  cp "$INSTALLER" "$WORK/$1/src/install-git-hooks.sh"
  git -C "$WORK/$1/src" add -A >/dev/null
  GIT_COMMITTER_DATE="$(_iso "${2:-0}")" \
    git -C "$WORK/$1/src" commit -qm base --date="$(_iso "${2:-0}")"
  git init -q --bare "$WORK/$1/remote.git"
  git -C "$WORK/$1/src" remote add origin "$WORK/$1/remote.git"
  git -C "$WORK/$1/src" push -q origin HEAD:refs/heads/main
  git -C "$WORK/$1/src" fetch -q origin
}
_prov_weaken() { printf '\n# WEAKENED\nexit 0\n' >> "$WORK/$1/src/git-hooks/secret-scan-pre-commit.sh"; }
_prov_run() {                 # <dir> [extra args...] -> rc in $RC, output in $OUT
  local d="$1"; shift
  OUT="$(cd "$WORK/$d/src" && CODE_ROOT="$WORK/$d/none" \
    HERDR_HOOK_DEPLOY_DIR="$WORK/$d/deploy" bash install-git-hooks.sh "$@" 2>&1)"
  RC=$?
}
_prov_landed() { [ -f "$WORK/$1/deploy/secret-scan-pre-commit.sh" ]; }

_prov_repo happy
_prov_run happy --apply
if [ -r "$WORK/happy/deploy/.rev" ]; then
  grep -q '^reviewed: *yes' "$WORK/happy/deploy/.rev" \
    && ok "--apply records the deployed revision and that it is reviewed" \
    || bad ".rev not marked reviewed" "$(cat "$WORK/happy/deploy/.rev")"
  grep -qE '^rev: +[0-9a-f]{7,} +[^ ]+ +clean' "$WORK/happy/deploy/.rev" \
    && ok ".rev names the source commit and the state of that file" \
    || bad ".rev revision line" "$(sed -n 1p "$WORK/happy/deploy/.rev")"
  # The record must describe the DEPLOYED bytes. A sha256 of $HOOK_SRC passed
  # the first version of this row in every fixture, because source and copy
  # were always identical there — and telling them apart is exactly what the
  # TOCTOU finding turned on.
  _s=$(shasum -a 256 "$WORK/happy/deploy/secret-scan-pre-commit.sh" | cut -d' ' -f1)
  _b=$(git hash-object "$WORK/happy/deploy/secret-scan-pre-commit.sh")
  grep -q "^sha256: *$_s\$" "$WORK/happy/deploy/.rev" \
    && grep -q "^blob: *$_b\$" "$WORK/happy/deploy/.rev" \
    && ok ".rev's sha256 AND blob oid are of the bytes actually deployed" \
    || bad ".rev hashes" "do not match the deployed file"
else
  bad "--apply wrote no .rev provenance record" ""
fi

printf '== the gate: an unreviewed scanner must not reach 18 repos ==\n'
_prov_repo diff; _prov_weaken diff
_prov_run diff --apply
{ [ "$RC" = 2 ] && ! _prov_landed diff; } \
  && ok "refuses a scanner origin/main does not carry, and installs nothing" \
  || bad "unreviewed scanner" "rc=$RC landed=$(_prov_landed diff && echo yes || echo no)"
printf '%s' "$OUT" | grep -q -- '--allow-unreviewed' \
  && ok "the refusal names the explicit escape hatch" \
  || bad "refusal" "does not say how to proceed deliberately"
_prov_run diff --apply --allow-unreviewed
grep -q '^reviewed: *no (differs from origin/main)' "$WORK/diff/deploy/.rev" 2>/dev/null \
  && ok "--allow-unreviewed deploys and records WHY it was unreviewed" \
  || bad "escape hatch" "$(grep '^reviewed' "$WORK/diff/deploy/.rev" 2>/dev/null)"

# HOOK-DEPLOY-01: "cannot verify" used to mean "deploy anyway". Three shapes,
# all reachable without an attacker: a renamed remote, a single-branch clone of
# a PR branch, and a directory copy with no .git at all.
printf '== a control that cannot verify its input must not deploy it ==\n'
_prov_repo rename; _prov_weaken rename
git -C "$WORK/rename/src" remote rename origin upstream
_prov_run rename --apply
{ [ "$RC" = 2 ] && ! _prov_landed rename; } \
  && ok "a renamed remote refuses rather than deploying 'unknown'" \
  || bad "renamed remote" "rc=$RC landed=$(_prov_landed rename && echo yes || echo no)"
printf '%s' "$OUT" | grep -q 'no origin/main to compare' \
  && ok "and says the reason is that it could not compare" \
  || bad "renamed remote" "reason not stated: $(printf '%s' "$OUT" | grep -m1 REFUSING)"

_prov_repo branchclone
git -C "$WORK/branchclone/src" switch -qc feature
printf '\n# WEAKENED on feature\nexit 0\n' >> "$WORK/branchclone/src/git-hooks/secret-scan-pre-commit.sh"
git -C "$WORK/branchclone/src" commit -qam w
git -C "$WORK/branchclone/src" push -q origin feature
git clone -q --single-branch --branch feature "$WORK/branchclone/remote.git" "$WORK/branchclone/clone"
cp "$INSTALLER" "$WORK/branchclone/clone/install-git-hooks.sh"
OUT="$(cd "$WORK/branchclone/clone" && CODE_ROOT="$WORK/branchclone/none" \
  HERDR_HOOK_DEPLOY_DIR="$WORK/branchclone/deploy" bash install-git-hooks.sh --apply 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && ! _prov_landed branchclone; } \
  && ok "a single-branch clone of a PR branch refuses" \
  || bad "single-branch clone" "rc=$RC landed=$(_prov_landed branchclone && echo yes || echo no)"

_prov_repo nogit; _prov_weaken nogit
cp -R "$WORK/nogit/src" "$WORK/nogit/plain"; rm -rf "$WORK/nogit/plain/.git"
OUT="$(cd "$WORK/nogit/plain" && CODE_ROOT="$WORK/nogit/none" \
  HERDR_HOOK_DEPLOY_DIR="$WORK/nogit/deploy" bash install-git-hooks.sh --apply 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && ! _prov_landed nogit; } \
  && ok "a source that is not a git checkout at all refuses" \
  || bad "non-checkout source" "rc=$RC landed=$(_prov_landed nogit && echo yes || echo no)"

# HOOK-DEPLOY-02: git sets GIT_DIR for every hook, alias and `rebase -x`, so an
# inherited value arrives without an attacker — and it used to make the gate,
# the record and the VERIFY line all answer about a DIFFERENT repository.
printf '== the questions must be about the repo the file came from ==\n'
_prov_repo envA; _prov_weaken envA
_prov_repo envB
OUT="$(cd "$WORK/envA/src" && CODE_ROOT="$WORK/envA/none" \
  HERDR_HOOK_DEPLOY_DIR="$WORK/envA/deploy" \
  GIT_DIR="$WORK/envB/src/.git" GIT_WORK_TREE="$WORK/envB/src" \
  bash install-git-hooks.sh --apply 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && ! _prov_landed envA; } \
  && ok "an inherited GIT_DIR cannot bless a weakened scanner" \
  || bad "GIT_DIR" "rc=$RC landed=$(_prov_landed envA && echo yes || echo no): $(printf '%s' "$OUT" | grep -m1 'revision:')"
# The refusal above holds even WITHOUT the unset, because _src_repo_ok notices
# that HOOK_SRC is outside the inherited repo — so it cannot tell whether the
# environment was sanitized. This row can: with GIT_DIR unset the record names
# envA's real commit; with it honoured, the repo cannot be identified at all.
_prov_repo envC
OUT="$(cd "$WORK/envC/src" && CODE_ROOT="$WORK/envC/none" \
  HERDR_HOOK_DEPLOY_DIR="$WORK/envC/deploy" \
  GIT_DIR="$WORK/envB/src/.git" GIT_WORK_TREE="$WORK/envB/src" \
  bash install-git-hooks.sh --apply 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -qE '^rev: +[0-9a-f]{7,}' "$WORK/envC/deploy/.rev" 2>/dev/null; then
  ok "and the record still names the repo the file came from"
else
  bad "GIT_DIR provenance" "rc=$RC rev=$(grep -m1 '^rev:' "$WORK/envC/deploy/.rev" 2>/dev/null)"
fi

# HOOK-DEPLOY-07: `git diff --quiet HEAD -- <path>` exits 0 both for
# "unmodified" and for "not in HEAD at all", so an untracked weakened scanner
# was recorded as `clean` against a commit that did not contain it.
printf '== the record must not claim more than it knows ==\n'
_prov_repo untracked
git -C "$WORK/untracked/src" rm -q --cached git-hooks/secret-scan-pre-commit.sh
printf 'git-hooks/\n' > "$WORK/untracked/src/.gitignore"
git -C "$WORK/untracked/src" add .gitignore
git -C "$WORK/untracked/src" commit -qm ignore
_prov_run untracked --apply --allow-unreviewed
grep -qE '^rev: .*(absent-from-HEAD|not a git checkout)' "$WORK/untracked/deploy/.rev" 2>/dev/null \
  && ok "a scanner absent from HEAD is not recorded as 'clean'" \
  || bad "provenance state" "$(grep -m1 '^rev:' "$WORK/untracked/deploy/.rev" 2>/dev/null)"

# HOOK-DEPLOY-06: `[ "$(git show ...)" = "$(cat ...)" ]` compares content modulo
# trailing newlines, because $( ) strips them — the report said "yes" for bytes
# whose sha256 differed.
_prov_repo trailing
printf '\n\n' >> "$WORK/trailing/src/git-hooks/secret-scan-pre-commit.sh"
_prov_run trailing --apply
[ "$RC" = 2 ] \
  && ok "bytes differing only in trailing newlines are NOT 'the reviewed scanner'" \
  || bad "byte comparison" "rc=$RC — trailing-newline difference treated as identical"

printf '== the report has to say what the fleet is running ==\n'
_prov_repo drift
_prov_run drift --apply
_prov_weaken drift
_prov_run drift --apply --allow-unreviewed
_prov_run drift --dry-run
printf '%s' "$OUT" | grep -q 'matches origin/main: NO' \
  && ok "VERIFY reports a deployed scanner that is not the reviewed one" \
  || bad "VERIFY" "stayed silent about a drifted deployment"
printf '%s' "$OUT" | grep -qE 'deployed blob [0-9a-f]{7,} vs origin/main [0-9a-f]{7,}' \
  && ok "and names both blobs, so the drift is checkable by hand" \
  || bad "VERIFY" "does not identify the two versions"
git -C "$WORK/drift/src" checkout -- git-hooks/secret-scan-pre-commit.sh
_prov_run drift --apply
_prov_run drift --dry-run
printf '%s' "$OUT" | grep -q 'matches origin/main: yes' \
  && ok "VERIFY confirms a deployment that does match origin/main" \
  || bad "VERIFY" "cannot recognise a correct deployment"

# HOOK-DEPLOY-05: silence in a report whose purpose is answering "what is the
# fleet running" reads as a pass.
git -C "$WORK/drift/src" remote remove origin
_prov_run drift --dry-run
printf '%s' "$OUT" | grep -q 'matches origin/main: CANNOT TELL' \
  && ok "with no origin/main, VERIFY says so instead of omitting the line" \
  || bad "VERIFY" "printed no verdict at all when the ref was unresolvable"

# origin/main is only as fresh as the last fetch, so a match against a stale
# ref can still mean the fleet runs a pre-fix detector.
_prov_repo old 60
_prov_run old --apply
_prov_run old --dry-run
printf '%s' "$OUT" | grep -qE 'origin/main here is [0-9]+d old' \
  && ok "a match against a long-stale origin/main is flagged as stale" \
  || bad "freshness" "no staleness warning for a 60-day-old ref"

# HOOK-DEPLOY-03 was a TOCTOU: the bytes checked against origin/main were read
# with `cat`, the bytes deployed were read again with `cp`. Review won that race
# on iteration 4 of 40 with a background writer, and .rev then recorded
# `reviewed: yes` over the WEAKENED bytes, so no later check could notice.
printf '== a concurrent writer cannot slip past the gate ==\n'
_prov_repo race
cp "$WORK/race/src/git-hooks/secret-scan-pre-commit.sh" "$WORK/race/good"
printf '#!/usr/bin/env bash\nexit 0\n# WEAKENED-BY-RACE\n' > "$WORK/race/bad"
(
  for _ in $(seq 1 600); do
    cp "$WORK/race/bad"  "$WORK/race/swap" && mv -f "$WORK/race/swap" "$WORK/race/src/git-hooks/secret-scan-pre-commit.sh"
    cp "$WORK/race/good" "$WORK/race/swap" && mv -f "$WORK/race/swap" "$WORK/race/src/git-hooks/secret-scan-pre-commit.sh"
  done
) >/dev/null 2>&1 & _racer=$!
_race_hit=0
for _i in $(seq 1 25); do
  _prov_run race --apply
  if [ -f "$WORK/race/deploy/secret-scan-pre-commit.sh" ] \
     && grep -q 'WEAKENED-BY-RACE' "$WORK/race/deploy/secret-scan-pre-commit.sh" 2>/dev/null; then
    _race_hit=1; break
  fi
  rm -f "$WORK/race/deploy/secret-scan-pre-commit.sh"
done
kill "$_racer" 2>/dev/null; wait "$_racer" 2>/dev/null
[ "$_race_hit" = 0 ] \
  && ok "25 attempts against a concurrent writer deployed no unreviewed bytes" \
  || bad "TOCTOU" "a weakened scanner reached the deploy path with no refusal"

# STRUCTURAL and ORDER-AWARE, labelled as such because the alternatives are
# worse — and because the first version of this row was too weak to be worth
# having. It grepped for the presence of three strings, so review passed three
# ordering INVERSIONS straight through it (install-before-judge; a fresh
# `install -m 0755 "$HOOK_SRC" "$HOOK_DEPLOY"` after the mv; judging a fresh
# read of the source), one of which failed no row in the whole file.
#
# The property is an ordering inside one function: the bytes judged must be the
# bytes installed. After the fix the window is too small for the race row above
# to hit, and the honest alternative — a test seam running a command between
# copy and judgement — would put an env-driven exec inside the fleet's
# credential guard, a worse defect than the one it tests. So this asserts the
# ORDER by line number, and refuses any second content read of $HOOK_SRC or any
# install of $HOOK_DEPLOY that is not the rename of the snapshot.
_ds=$(sed -n '/^deploy_scanner() {/,/^}/p' "$INSTALLER")
_ln() { printf '%s\n' "$_ds" | grep -nE "$1" | head -1 | cut -d: -f1; }
_cp_snap=$(_ln '^[[:space:]]*cp "\$HOOK_SRC" "\$tmp"')
_judge=$(_ln 'git hash-object "\$tmp"')
_install=$(_ln '^[[:space:]]*mv -f "\$tmp" "\$HOOK_DEPLOY"')
# every way the deployed file could be written, other than renaming the snapshot
_other_write=$(printf '%s\n' "$_ds" | grep -cE '(cp|install|cat|tee|ln)[^|]*"\$HOOK_DEPLOY"')
# every second read of the source's CONTENT after it was copied
_src_reads=$(printf '%s\n' "$_ds" | grep -cE '(cp|cat|hash-object|shasum|install)[^|]*"\$HOOK_SRC"')
if [ -n "$_cp_snap" ] && [ -n "$_judge" ] && [ -n "$_install" ] \
   && [ "$_cp_snap" -lt "$_judge" ] && [ "$_judge" -lt "$_install" ] \
   && [ "$_other_write" = 0 ] && [ "$_src_reads" = 1 ]; then
  ok "the snapshot is copied, THEN judged, THEN installed — and nothing else writes the deployed file"
else
  bad "TOCTOU structure" \
    "cp=$_cp_snap judge=$_judge install=$_install other_writes=$_other_write src_reads=$_src_reads"
fi

printf '== the review anchor must be one specific ref ==\n'
# `origin/main` is an AMBIGUOUS refname: git resolves refs/heads/<name> and
# refs/tags/<name> BEFORE refs/remotes/<name>. A local branch or tag literally
# called origin/main therefore became the thing the gate compared against, and a
# weakened scanner deployed with reviewed: yes and matches origin/main: yes. git
# warns that the name is ambiguous; both call sites discarded stderr.
_prov_repo anchorbranch; _prov_weaken anchorbranch
git -C "$WORK/anchorbranch/src" add -A >/dev/null
git -C "$WORK/anchorbranch/src" commit -qm weakened
git -C "$WORK/anchorbranch/src" branch origin/main
_prov_run anchorbranch --apply
{ [ "$RC" = 2 ] && ! _prov_landed anchorbranch; } \
  && ok "a local BRANCH named origin/main cannot become the review anchor" \
  || bad "ambiguous ref" "rc=$RC landed=$(_prov_landed anchorbranch && echo yes || echo no)"

# A tag is the worse case: fetch never prunes it, so the false anchor is permanent.
_prov_repo anchortag; _prov_weaken anchortag
git -C "$WORK/anchortag/src" add -A >/dev/null
git -C "$WORK/anchortag/src" commit -qm weakened
git -C "$WORK/anchortag/src" tag origin/main
_prov_run anchortag --apply
{ [ "$RC" = 2 ] && ! _prov_landed anchortag; } \
  && ok "nor a TAG of that name, which no fetch will ever prune" \
  || bad "ambiguous ref" "rc=$RC landed=$(_prov_landed anchortag && echo yes || echo no)"

# And the fully-qualified anchor must still accept an ordinary checkout, or the
# fix would simply have broken deployment.
_prov_repo anchorok
_prov_run anchorok --apply
{ [ "$RC" = 0 ] && _prov_landed anchorok && grep -q '^reviewed: *yes' "$WORK/anchorok/deploy/.rev"; } \
  && ok "a legitimate checkout still deploys against the qualified ref" \
  || bad "anchor" "a good checkout was refused: rc=$RC"
grep -q '^main-ref: *refs/remotes/origin/main' "$WORK/anchorok/deploy/.rev" \
  && ok "and the record names WHICH ref was the anchor" \
  || bad "anchor record" "$(grep -m1 'main-ref' "$WORK/anchorok/deploy/.rev" 2>/dev/null)"

printf '== the deploy TARGET gets the same scrutiny as the source ==\n'
_prov_repo target
# A FAKE $HOME, so `$ROOT = $HOME/Code` is true of a fixture tree and not of
# the real fleet. This row asserts a REFUSAL, which means the moment the guard
# it tests is mutated away, whatever CODE_ROOT points at gets 3 shims per repo
# written into it. With the real path that is not a test, it is an outage: it
# happened here — mutating the deploy-target check rewrote all 54 shims in 18
# repos to exec a temp dir that no longer existed, and every commit in every
# repo failed with "No such file or directory" until they were redeployed. A
# suite row must never be able to reach the live fleet, mutated or not.
mkdir -p "$WORK/target/home/Code/fixture-repo"
git init -q "$WORK/target/home/Code/fixture-repo"
# Every spelling of the same directory. The check was string equality, so
# `$HOME/Code/` with a trailing slash and `$HOME/./Code` both walked past it —
# and that is precisely the outage that happened here during mutation testing.
for _spell in "$WORK/target/home/Code" "$WORK/target/home/Code/" "$WORK/target/home/./Code"; do
  OUT="$(cd "$WORK/target/src" && HOME="$WORK/target/home" CODE_ROOT="$_spell" \
    HERDR_HOOK_DEPLOY_DIR="$WORK/target/tmpdeploy" bash install-git-hooks.sh --apply 2>&1)"; RC=$?
  { [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'REFUSING: deploy target'; } \
    && ok "a temp deploy dir is refused for CODE_ROOT spelled '${_spell##*home}'" \
    || bad "deploy target" "rc=$RC for $_spell — 54 shims would exec a vanishing path"
done
OUT="$(cd "$WORK/target/src" && HOME="$WORK/target/home" CODE_ROOT="$WORK/target/home/Code" \
  HERDR_HOOK_DEPLOY_DIR="$WORK/target/tmpdeploy" bash install-git-hooks.sh --apply 2>&1)"; RC=$?
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'REFUSING: deploy target' \
  && ok "a temp deploy dir is refused when CODE_ROOT is the real fleet" \
  || bad "deploy target" "rc=$RC — 54 shims would exec a path that vanishes"
_prov_run target --dry-run
printf '%s' "$OUT" | grep -q "$WORK/target/deploy" \
  && ok "and the disposable-source note names the real deploy dir" \
  || bad "note" "hardcodes a path the scanner was not copied to"

printf '%s' "$(bash "$INSTALLER" --help 2>&1)" | grep -q -- '--allow-unreviewed' \
  && ok "--help documents the escape hatch" \
  || bad "--help" "the bypass is discoverable only from a refusal message"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
