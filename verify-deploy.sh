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
printf '%s' "$OUT" | grep -qi 'rolling back' \
    && ok "and says it is rolling back" || bad "no rollback message: $OUT"
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ] \
    && ok "the previous revision is still what is deployed" \
    || bad "left the app at $(app_rev) after a failed deploy"
python3 -m py_compile "$HERDR_APP_DIR/hub.py" 2>/dev/null \
    && ok "so the deployed hub.py still compiles" \
    || bad "the deployed hub.py does not compile after a rolled-back deploy"

printf '== refusals ==\n'
if deploy_app "no-such-revision" >/dev/null 2>&1; then
    bad "an unresolvable revision was accepted"
else
    ok "an unresolvable revision is refused, not guessed"
fi
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ] \
    && ok "and a refused deploy changes nothing" || bad "a refused deploy moved the app"

printf '== rolling forward and back is a sha ==\n'
deploy_app "$GOOD2" >/dev/null 2>&1
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD2")" ] \
    && ok "rolling forward works" || bad "roll forward left $(app_rev)"
deploy_app "$GOOD" >/dev/null 2>&1
[ "$(app_rev)" = "$(git -C "$SRC" rev-parse --short "$GOOD")" ] \
    && ok "rolling BACK is the same command with an older sha" || bad "roll back left $(app_rev)"

printf '== the installer must not point launchd at a working checkout ==\n'
# The regression that started this: the plist rendered $here/hub.py.
grep -q 's|__HUB_PY__|\$HERDR_APP_DIR/hub.py|' "$here/install.sh" \
    && ok "install.sh renders the plist against the deployed app dir" \
    || bad "install.sh does not render the deployed path"
grep -q 's|__HUB_PY__|\$here/hub.py|' "$here/install.sh" \
    && bad "install.sh still renders a checkout path into the plist" \
    || ok "and no longer renders a checkout path"
# And the live plist, when one is installed on this machine.
LIVE_PLIST="$HOME/Library/LaunchAgents/com.herdr-control.hub.plist"
if [ -f "$LIVE_PLIST" ]; then
    if grep -q "$HOME/Code/" "$LIVE_PLIST"; then
        bad "the INSTALLED plist still launches hub.py from a working checkout"
    else
        ok "the installed plist does not launch from a working checkout"
    fi
else
    printf '  .     no hub plist installed on this machine — skipped\n'
fi

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
