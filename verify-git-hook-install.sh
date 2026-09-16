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
OUT="$(CODE_ROOT="$ROOT" bash -c "cd $WORK && mkdir -p gh && cp broken.sh gh/secret-scan-pre-commit.sh && sed 's|\$here/git-hooks|$WORK/gh|' $INSTALLER > $WORK/i.sh && bash $WORK/i.sh --apply" 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "refuses to deploy a scanner that is not valid bash" || bad "deployed a broken scanner (rc=$rc)"

# ===== which revision the fleet runs =====
#
# All 18 repos executed an OPEN PR's scanner on 2026-09-16, which allowed three
# PII cases origin/main blocks. Nothing in this suite noticed, because every
# other check here describes the SHIMS, and the shims were perfect: they all
# pointed at the one deployed copy. What was missing was any statement about
# WHAT that copy is.
_prov_env() {                 # a throwaway repo + remote, $WORK/prov
  rm -rf "$WORK/prov"; mkdir -p "$WORK/prov"
  git init -q "$WORK/prov/src"
  git -C "$WORK/prov/src" config user.email t@e.c
  git -C "$WORK/prov/src" config user.name t
  mkdir -p "$WORK/prov/src/git-hooks"
  cp "$here/git-hooks/secret-scan-pre-commit.sh" "$WORK/prov/src/git-hooks/secret-scan-pre-commit.sh"
  cp "$INSTALLER" "$WORK/prov/src/install-git-hooks.sh"
  git -C "$WORK/prov/src" add -A >/dev/null
  git -C "$WORK/prov/src" commit -qm base
  git init -q --bare "$WORK/prov/remote.git"
  git -C "$WORK/prov/src" remote add origin "$WORK/prov/remote.git"
  git -C "$WORK/prov/src" push -q origin HEAD:refs/heads/main
  git -C "$WORK/prov/src" fetch -q origin
}
_prov_run() {                 # [extra args...] -> rc, output in $OUT
  OUT="$(cd "$WORK/prov/src" && CODE_ROOT="$WORK/prov/none" \
    HERDR_HOOK_DEPLOY_DIR="$WORK/prov/deploy" bash install-git-hooks.sh "$@" 2>&1)"
}

_prov_env
_prov_run --apply
if [ -r "$WORK/prov/deploy/.rev" ]; then
  grep -q '^reviewed: yes' "$WORK/prov/deploy/.rev" \
    && ok "--apply records the deployed revision and that it is reviewed" \
    || bad ".rev written but not marked reviewed: $(cat "$WORK/prov/deploy/.rev")"
  # The point of the record is naming the REVISION — "reviewed: yes" without a
  # sha would have described the 2026-09-16 deployment perfectly and still left
  # nobody able to say which commit the fleet was running.
  grep -qE '^rev:[[:space:]]+[0-9a-f]{7,}[[:space:]]' "$WORK/prov/deploy/.rev" \
    && ok ".rev names the source commit, not just its review status" \
    || bad ".rev has no resolvable revision line: $(sed -n 1p "$WORK/prov/deploy/.rev")"
  _s=$(shasum -a 256 "$WORK/prov/deploy/secret-scan-pre-commit.sh" | cut -d' ' -f1)
  grep -q "^sha256:[[:space:]]*$_s\$" "$WORK/prov/deploy/.rev" \
    && ok ".rev's sha256 is of the bytes actually deployed" \
    || bad ".rev sha256 does not match the deployed file"
else
  bad "--apply wrote no .rev provenance record"
fi

# The gate that was missing. An unreviewed scanner is the one thing that must
# not reach 18 repos silently — a weakened detector lives on a branch BEFORE
# review catches it, which is exactly what happened with #87 and #88.
printf '\n# local edit\n' >> "$WORK/prov/src/git-hooks/secret-scan-pre-commit.sh"
_prov_run --apply
[ -n "$OUT" ] && printf '%s' "$OUT" | grep -q 'REFUSING' \
  && ok "refuses to deploy a scanner origin/main does not carry" \
  || bad "deployed an unreviewed scanner: $(printf '%s' "$OUT" | tail -2)"
printf '%s' "$OUT" | grep -q -- '--allow-unreviewed' \
  && ok "the refusal names the explicit escape hatch" \
  || bad "refusal does not say how to proceed deliberately"

_prov_run --apply --allow-unreviewed
grep -q '^reviewed: no' "$WORK/prov/deploy/.rev" 2>/dev/null \
  && ok "--allow-unreviewed deploys but records reviewed=no" \
  || bad "escape hatch did not record that the source was unreviewed"

# And the report has to SAY so afterwards, because that deployment outlives the
# branch it came from.
_prov_run --dry-run
printf '%s' "$OUT" | grep -q 'matches origin/main: NO' \
  && ok "VERIFY reports a deployed scanner that is not the reviewed one" \
  || bad "VERIFY stayed silent about a drifted deployment"
git -C "$WORK/prov/src" checkout -- git-hooks/secret-scan-pre-commit.sh
_prov_run --apply
_prov_run --dry-run
printf '%s' "$OUT" | grep -q 'matches origin/main: yes' \
  && ok "VERIFY confirms a deployment that does match origin/main" \
  || bad "VERIFY cannot recognise a correct deployment"

# A hand-written or stale .rev must not be believed.
printf 'rev: bogus\nsha256: 0000\n' > "$WORK/prov/deploy/.rev"
_prov_run --dry-run
printf '%s' "$OUT" | grep -q 'STALE RECORD' \
  && ok "VERIFY catches a .rev describing bytes other than the deployed file" \
  || bad "a stale .rev was reported as provenance"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
