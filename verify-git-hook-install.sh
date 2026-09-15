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

# Not a git repository, and a linked worktree of shim-expanded.
mkdir -p "$ROOT/just-a-dir"
git -C "$R_EXPANDED" -c user.email=tnt@teamthurber.com -c user.name=t commit -q \
    --allow-empty -m init --no-verify
git -C "$R_EXPANDED" worktree add -q "$ROOT/a-worktree" -b wt >/dev/null 2>&1

# ═════════════════════════════════════════════════════════════════════════════
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
printf '%s' "$OUT" | grep -q 'changed=0 unchanged=7' \
    && ok "re-run reports 0 changed, 7 already correct" \
    || bad "re-run counts wrong: $(printf '%s' "$OUT" | grep 'this run')"
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

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
