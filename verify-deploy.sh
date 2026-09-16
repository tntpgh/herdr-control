#!/usr/bin/env bash
# verify-deploy.sh — the service must run a KNOWN revision, not "whatever is
# checked out".
#
# WHY THIS EXISTS: `hub.py` was launched straight out of the working checkout,
# so a reboot, a KeepAlive respawn, or `restart.sh` while a feature branch was
# checked out silently ran that branch's hub — and nothing said so. That is the
# same defect class as the git-hook shims that pointed into a branch-local path
# on 2026-09-15 and killed every commit in 18 repos after a switch, one
# directory over. This suite pins the properties that make it not recur:
#
#   * the deployed worktree is DETACHED, so it has no branch to follow;
#   * switching branches in the developer checkout does not move it;
#   * a revision whose hub.py does not compile is rolled back, not served;
#   * an unresolvable revision is refused rather than guessed;
#   * `app_rev` reports the sha, so "did the deploy take?" is a fact.
#
#   bash verify-deploy.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/launchd/agent-lib.sh"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── a scratch source repo: one good commit, one that does not parse ─────────
# Real history always compiles, so the rollback path can only be exercised
# against a repo built for it. HERDR_APP_SRC is the seam.
SRC="$WORK/src"
mkdir -p "$SRC/lib"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email tnt@teamthurber.com
git -C "$SRC" config user.name t
printf 'print("hub v1")\n' > "$SRC/hub.py"
printf 'x = 1\n' > "$SRC/lib/herdr_live.py"
git -C "$SRC" add -A
git -C "$SRC" commit -qm "v1" --no-verify
GOOD="$(git -C "$SRC" rev-parse HEAD)"
printf 'def broken(:\n' > "$SRC/hub.py"
git -C "$SRC" add -A
git -C "$SRC" commit -qm "v2, unparseable" --no-verify
BROKEN="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" checkout -q "$GOOD" -- hub.py
git -C "$SRC" add -A
git -C "$SRC" commit -qm "v3, parses again" --no-verify
GOOD2="$(git -C "$SRC" rev-parse HEAD)"
# A revision whose hub.py is FINE and whose lib/ does not parse. hub.py puts
# its own lib/ on sys.path and imports from it at module load, so this crashes
# the service — and a hub.py-only compile gate accepted it (review, proven).
printf 'def broken(:\n' > "$SRC/lib/herdr_live.py"
git -C "$SRC" add -A
git -C "$SRC" commit -qm "v4, unparseable lib/" --no-verify
BROKEN_LIB="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" checkout -q "$GOOD2" -- lib/herdr_live.py
git -C "$SRC" add -A
git -C "$SRC" commit -qm "v5, lib parses again" --no-verify
GOOD3="$(git -C "$SRC" rev-parse HEAD)"

export HERDR_APP_SRC="$SRC"
export HERDR_APP_DIR="$WORK/app"

printf '== a deploy pins a revision ==\n'
if deploy_app "$GOOD" >/dev/null 2>&1; then
    ok "deploying a good revision succeeds"
else
    bad "deploying a good revision failed"
fi
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ] \
    && ok "app_rev reports the deployed sha" \
    || bad "app_rev says '$(app_rev)', expected $(git -C "$SRC" rev-parse --short "$GOOD")"
git -C "$HERDR_APP_DIR" symbolic-ref -q HEAD >/dev/null \
    && bad "the deployed worktree is on a BRANCH — a branch can move under it" \
    || ok "the deployed worktree is DETACHED, so no branch can move it"
[ -f "$HERDR_APP_DIR/lib/herdr_live.py" ] \
    && ok "siblings come with it (hub.py resolves lib/ and *.sh relative to itself)" \
    || bad "the deployed tree is missing lib/ — hub.py would read a mixture"

printf '== the developer checkout cannot move production ==\n'
# THE point of the whole change: branch work in the source must not change what
# the service would run on its next respawn.
git -C "$SRC" checkout -q -b feature
printf 'print("hub from a feature branch")\n' > "$SRC/hub.py"
git -C "$SRC" add -A
git -C "$SRC" commit -qm "feature work" --no-verify
if [ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ]; then
    ok "a branch switch + commit in the checkout leaves the deployed rev untouched"
else
    bad "the deployed rev followed the checkout to $(app_rev)"
fi
grep -q 'hub v1' "$HERDR_APP_DIR/hub.py" \
    && ok "and the deployed FILE is still the deployed revision's" \
    || bad "the deployed file changed: $(head -1 "$HERDR_APP_DIR/hub.py")"
git -C "$SRC" checkout -q main

printf '== a revision that does not compile is not served ==\n'
OUT="$(deploy_app "$BROKEN" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "deploying an unparseable revision FAILS" \
                || bad "an unparseable revision deployed successfully"
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ] \
    && ok "the previous revision is still what is deployed" \
    || bad "left the app at $(app_rev) after a failed deploy"
python3 -m py_compile "$HERDR_APP_DIR/hub.py" 2>/dev/null \
    && ok "so the deployed hub.py still compiles" \
    || bad "the deployed hub.py does not compile after a rolled-back deploy"

printf '== a revision whose lib/ does not parse is not served either ==\n'
# hub.py alone compiled fine in this revision; 17/17 passed while this shipped.
deploy_app "$GOOD2" >/dev/null 2>&1
OUT="$(deploy_app "$BROKEN_LIB" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "a broken lib/ fails the deploy (the gate compiles the TREE)" \
                || bad "a revision with an unparseable lib/ deployed with rc=0"
[ "$(app_rev_sha)" = "$(git -C "$SRC" rev-parse --short "$GOOD2")" ] \
    && ok "and the previous revision is still deployed" || bad "left the app at $(app_rev_sha)"
if python3 -c "import sys; sys.path.insert(0, '$HERDR_APP_DIR/lib'); import herdr_live" 2>/dev/null; then
    ok "the deployed tree still imports"
else
    bad "the deployed tree does not import after a rolled-back deploy"
fi

printf '== the app dir can be LOST and still recovered ==\n'
# The unrecoverable case: `git worktree add` refuses a path still registered in
# .git/worktrees, so once the dir vanished (a cleanup, a disk repair, a mv, a
# Migration Assistant restore) BOTH documented repairs refused forever while
# launchd KeepAlive-looped a missing hub.py. The only way out was a
# `git worktree prune` the operator had to already know about.
deploy_app "$GOOD2" >/dev/null 2>&1
mv "$HERDR_APP_DIR" "$WORK/vanished"
if OUT="$(deploy_app "$GOOD2" 2>&1)"; then
    ok "a deploy re-creates the app dir after it is lost"
else
    bad "deploy cannot recover a lost app dir: $OUT"
fi
[ -f "$HERDR_APP_DIR/hub.py" ] && ok "and hub.py is there again" || bad "no hub.py after recovery"
rm -rf "$WORK/vanished"

printf '== a deploy is authoritative over the deployed tree ==\n'
# A hand-patch made in the deployed dir during an incident used to survive a
# deploy that then reported a clean sha — a second source of "what is running".
printf 'x = 999  # hand-edit\n' > "$HERDR_APP_DIR/lib/herdr_live.py"
printf 'print("stray")\n' > "$HERDR_APP_DIR/stray.py"
deploy_app "$GOOD3" >/dev/null 2>&1
grep -q 'hand-edit' "$HERDR_APP_DIR/lib/herdr_live.py" \
    && bad "a local edit in the deployed tree survived a deploy" \
    || ok "a local edit in the deployed tree is overwritten by the deploy"
[ -f "$HERDR_APP_DIR/stray.py" ] \
    && bad "an untracked file survived the deploy" \
    || ok "and untracked files are cleaned"
case "$(app_rev)" in
    *-dirty) bad "app_rev still reports dirty after a clean deploy" ;;
    *)       ok "app_rev reports a clean sha" ;;
esac
printf 'x = 1  # dirty again\n' >> "$HERDR_APP_DIR/lib/herdr_live.py"
case "$(app_rev)" in
    *-dirty) ok "and reports -dirty when the tree does NOT match the sha" ;;
    *)       bad "app_rev reported a clean sha for a modified tree: $(app_rev)" ;;
esac
deploy_app "$GOOD3" >/dev/null 2>&1

printf '== refusals ==\n'
BEFORE_REFUSAL="$(app_rev_sha)"      # whatever is deployed right now, not a constant
if deploy_app "no-such-revision" >/dev/null 2>&1; then
    bad "an unresolvable revision was accepted"
else
    ok "an unresolvable revision is refused, not guessed"
fi
[ "$(app_rev_sha)" = "$BEFORE_REFUSAL" ] \
    && ok "and a refused deploy changes nothing" \
    || bad "a refused deploy moved the app from $BEFORE_REFUSAL to $(app_rev_sha)"

printf '== rolling forward and back is a sha ==\n'
deploy_app "$GOOD2" >/dev/null 2>&1
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD2")" ] \
    && ok "rolling forward works" || bad "roll forward left $(app_rev)"
deploy_app "$GOOD" >/dev/null 2>&1
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ] \
    && ok "rolling BACK is the same command with an older sha" || bad "roll back left $(app_rev)"

printf '== the rendered plist points at the deployed app, not a checkout ==\n'
# Asserted against the RENDERED FILE, not by grepping install.sh for a sed
# expression: a source grep passes for a line that is unreachable, shadowed by
# a later render, or resolving an empty variable.
OUT_PLIST="$WORK/hub.plist"
render_hub_plist "$here/com.herdr-control.hub.plist.template" "$OUT_PLIST"
# plutil's JSON escapes every `/` as `\/`, so compare with the escapes removed
# rather than against the raw path.
ARGS="$(plutil -extract ProgramArguments json -o - "$OUT_PLIST" 2>/dev/null | tr -d '\\\\')"
printf '%s' "$ARGS" | grep -qF "$HERDR_APP_DIR/hub.py" \
    && ok "the rendered ProgramArguments names the deployed hub.py" \
    || bad "rendered plist does not name $HERDR_APP_DIR/hub.py: $ARGS"
printf '%s' "$ARGS" | grep -qF "$here/hub.py" \
    && bad "the rendered plist names this checkout" \
    || ok "and does not name this checkout"
printf '%s' "$ARGS" | grep -qE '"/hub\.py"' \
    && bad "HERDR_APP_DIR was empty when rendering — the plist points at /hub.py" \
    || ok "and is not a bare /hub.py from an empty app dir"

printf '== the SERVED rev must equal the DEPLOYED rev ==\n'
# "the port answers 200" and "the revision I deployed is answering" are
# different claims. hub.py exits 0 when :8600 is already open, and the omp
# extension starts a hub from the CHECKOUT on session start — so a stale
# process holding the port keeps every HTTP check green while serving code
# nobody deployed. Only comparing the revisions separates the two.
LIVE_REV="$(curl -s --max-time 5 http://127.0.0.1:8600/api/summary 2>/dev/null \
            | sed -n 's/.*"rev": *"\([^"]*\)".*/\1/p')"
REAL_APP="$HOME/.local/share/herdr-control/app"
if [ -n "$LIVE_REV" ] && [ -d "$REAL_APP" ]; then
    WANT_REV="$(git -C "$REAL_APP" describe --always --dirty --abbrev=7 2>/dev/null)"
    [ "$LIVE_REV" = "$WANT_REV" ] \
        && ok "the hub answering :8600 runs the deployed revision ($LIVE_REV)" \
        || bad "serving $LIVE_REV but $WANT_REV is deployed — something else holds :8600"
else
    printf '  .     no hub serving locally, or no deployed app — skipped\n'
fi
# And the field itself must be dirty-aware, or the comparison above cannot see
# a hand-patched deployed tree.
grep -q 'describe", "--always", "--dirty"' "$here/hub.py" \
    && ok "the served rev is dirty-aware (rev-parse cannot see a modified tree)" \
    || bad "hub.py still reports the rev with rev-parse, which is blind to local edits"

printf '== the plist installed on THIS machine ==\n'
LIVE_PLIST="$HOME/Library/LaunchAgents/com.herdr-control.hub.plist"
if [ -f "$LIVE_PLIST" ]; then
    LIVE_ARGS="$(plutil -extract ProgramArguments json -o - "$LIVE_PLIST" 2>/dev/null | tr -d '\\\\')"
    LIVE_APP="$HOME/.local/share/herdr-control/app/hub.py"
    # The POSITIVE fact, and that the file exists: "does not mention ~/Code" was
    # satisfied by any path at all, including one pointing at a deployed dir
    # that had been lost — the failure mode this change introduces.
    if printf '%s' "$LIVE_ARGS" | grep -qF "$LIVE_APP"; then
        ok "the installed plist runs the deployed app"
        [ -f "$LIVE_APP" ] && ok "and that file exists" \
            || bad "the installed plist points at $LIVE_APP, which does NOT exist — launchd is looping"
    else
        bad "the installed plist does not run $LIVE_APP (it runs: $LIVE_ARGS)"
    fi
else
    printf '  .     no hub plist installed on this machine — skipped\n'
fi

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
