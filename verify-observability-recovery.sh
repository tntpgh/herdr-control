#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); work=$(mktemp -d "${TMPDIR:-/tmp}/herdr-observe-recover.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
ok=0; bad=0
pass(){ echo "ok - $*"; ok=$((ok+1)); }; fail(){ echo "not ok - $*"; bad=$((bad+1)); }

mkdir -p "$work/bin" "$work/repo/.git" "$work/control/lib" "$work/control/agent-hooks" "$work/home/.omp/agent/extensions" "$work/runtime/18.10.4"
cat >"$work/bin/launchctl-unobservable" <<'EOF'
#!/bin/sh
exit 77
EOF
cat >"$work/bin/curl-unobservable" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$work/bin/"*
set +e
out=$(HERDR_LAUNCHCTL="$work/bin/launchctl-unobservable" HERDR_CURL="$work/bin/curl-unobservable" PROBE_READY_SECS=0 bash "$here/restart.sh" --verify 2>&1); rc=$?
set -e
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'HEALTH UNOBSERVABLE' && pass "sandbox invisibility is UNOBSERVABLE (exit 2)" || fail "sandbox invisibility classification: rc=$rc $out"
printf '%s' "$out" | grep -q 'CONFIRMED_DOWN' && fail "unobservable was mislabeled down" || pass "unobservable never claims confirmed down"
cat >"$work/bin/launchctl-empty" <<'EOF'
#!/bin/sh
[ "$1" = print ] && exit 0
[ "$1" = list ] && exit 0
exit 2
EOF
chmod +x "$work/bin/launchctl-empty"
set +e; st=$(HERDR_LAUNCHCTL="$work/bin/launchctl-empty" bash -c '. "$1/launchd/agent-lib.sh"; agent_status com.herdr-control.hub' _ "$here" 2>&1); src=$?; set -e
[ "$src" = 2 ] && [ "$st" = 'UNOBSERVABLE launchctl_list_empty' ] && pass "successful but empty launchctl list is unobservable" || fail "empty launchd classification: rc=$src $st"
cat >"$work/bin/launchctl-visible-absent" <<'EOF'
#!/bin/sh
[ "$1" = print ] && exit 0
[ "$1" = list ] && { printf '123\t0\tcom.example.visible\n'; exit 0; }
exit 2
EOF
chmod +x "$work/bin/launchctl-visible-absent"
set +e; st=$(HERDR_LAUNCHCTL="$work/bin/launchctl-visible-absent" bash -c '. "$1/launchd/agent-lib.sh"; agent_status com.herdr-control.hub' _ "$here" 2>&1); src=$?; set -e
[ "$src" = 1 ] && [ "$st" = NOT-LOADED ] && pass "nonempty visible launchd list plus absent label is confirmed down" || fail "visible absent launchd classification: rc=$src $st"
set +e
out=$(HERDR_LAUNCHCTL="$work/bin/launchctl-visible-absent" HERDR_CURL="$work/bin/curl-unobservable" PROBE_READY_SECS=0 bash "$here/restart.sh" --verify 2>&1); rc=$?
set -e
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'HEALTH CONFIRMED_DOWN' && ! printf '%s' "$out" | grep -q 'HEALTH UNOBSERVABLE' && pass "confirmed outage takes precedence over mixed unobservable probes" || fail "mixed-state precedence: rc=$rc $out"
cat >"$work/bin/launchctl-running" <<'EOF'
#!/bin/sh
[ "$1" = print ] && exit 0
[ "$1" = list ] && { printf '11\t0\tcom.herdr-control.hub\n12\t0\tcom.herdr-control.bridge\n13\t0\tcom.herdr-control.auth-broker\n14\t0\tcom.herdr-control.auth-gateway\n'; exit 0; }
exit 2
EOF
cat >"$work/bin/curl-panes-loss" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/summary'*) printf '{"rev":"85ff0af"}'; exit 0;;
  *'/api/panes'*)
    count=$(cat "$PANES_COUNT" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" >"$PANES_COUNT"
    [ "$count" = 1 ] && { printf '{"connected":false,"stats":{"last_error":"fixture"}}'; exit 0; }
    exit 7;;
  *'127.0.0.1:8765'*) printf 401; exit 0;;
  *'127.0.0.1:4000'*) printf 401; exit 0;;
  *) printf 200; exit 0;;
esac
EOF
chmod +x "$work/bin/launchctl-running" "$work/bin/curl-panes-loss"; : >"$work/panes-count"
set +e
out=$(PANES_COUNT="$work/panes-count" HERDR_LAUNCHCTL="$work/bin/launchctl-running" HERDR_CURL="$work/bin/curl-panes-loss" PROBE_READY_SECS=1 bash "$here/restart.sh" --verify 2>&1); rc=$?
set -e
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'HEALTH UNOBSERVABLE' && pass "connected-false followed by visibility loss remains conservatively unobservable" || fail "panes visibility-loss policy: rc=$rc $out"

# Missing prior runtime refuses exact mode and requires an explicit version-changing exception.
cat >"$work/bin/lsof-missing" <<'EOF'
#!/bin/sh
case " $* " in *' -d cwd '*) printf 'p999\nfcwd\nn/tmp/fake-repo\n';; *) printf 'p999\nftxt\nn/missing/18.9.2/bin/omp\nftxt\nn/missing/18.9.2/pi_natives.darwin-arm64.node\n';; esac
EOF
cat >"$work/bin/ps-stable" <<'EOF'
#!/bin/sh
case " $* " in *' lstart= '*) echo 'Wed Oct 14 00:00:00 2026';; *' command= '*) echo 'omp --resume fake-session';; *) exit 2;; esac
EOF
chmod +x "$work/bin/lsof-missing" "$work/bin/ps-stable"
cp /opt/homebrew/bin/omp "$work/runtime/18.10.4/omp"
cp "$HOME/.omp/natives/18.10.4/pi_natives.darwin-arm64.node" "$work/runtime/18.10.4/pi_natives.darwin-arm64.node"
printf '%s\n' '{"type":"session","version":3,"id":"019fb853-95d1-7000-ae32-17a9b4c19eb7","timestamp":"2026-07-31T13:18:33.425Z","cwd":"/tmp","title":"Recovery fixture","titleSource":"auto"}' >"$work/session.jsonl"; printf 'x\n' >"$work/control/config.sh"; printf 'x\n' >"$work/control/agent-hooks/omp-worker-overlay.yml"; printf '# fixture\n' >"$work/control/lib/command-policy.sh"; printf 'export default function () {}\n' >"$work/home/.omp/agent/extensions/herdr-control.ts"
git -C "$work/repo" init -q; printf 'aaaa\n' >"$work/repo/tracked"; git -C "$work/repo" -c user.name=t -c user.email=t@x add tracked; git -C "$work/repo" -c user.name=t -c user.email=t@x commit -qm init
set +e
HERDR_LSOF="$work/bin/lsof-missing" HERDR_PS="$work/bin/ps-stable" HERDR_HOOK="$work/home/.omp/agent/extensions/herdr-control.ts" HERDR_CONTROL_DIR="$work/control" "$here/session-recovery.sh" snapshot --pid 999 --pane p --terminal t --session-file "$work/session.jsonl" --repo "$work/repo" --out "$work/exact" --environment-reviewed >"$work/exact.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] && grep -q 'exact recovery unavailable' "$work/exact.out" && pass "deleted prior runtime fails closed" || fail "deleted prior runtime did not fail closed"
cat >"$work/bin/ps-mutate" <<'EOF'
#!/bin/sh
count=$(cat "$MUTATE_COUNT" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" >"$MUTATE_COUNT"
[ "$count" = 3 ] && printf 'cccc\n' >"$MUTATE_REPO/tracked"
case " $* " in *' lstart= '*) echo 'Wed Oct 14 00:00:00 2026';; *' command= '*) echo 'omp --resume fake-session';; *) exit 2;; esac
EOF
chmod +x "$work/bin/ps-mutate"
printf 'bbbb\n' >"$work/repo/tracked"; : >"$work/mutate-count"
set +e
MUTATE_COUNT="$work/mutate-count" MUTATE_REPO="$work/repo" HERDR_LSOF="$work/bin/lsof-missing" HERDR_PS="$work/bin/ps-mutate" HERDR_HOOK="$work/home/.omp/agent/extensions/herdr-control.ts" HERDR_CONTROL_DIR="$work/control" "$here/session-recovery.sh" snapshot --pid 999 --pane p --terminal t --session-file "$work/session.jsonl" --repo "$work/repo" --out "$work/mutating" --environment-reviewed --allow-version-change --source-version 18.9.2 --fallback-binary "$work/runtime/18.10.4/omp" --fallback-native "$work/runtime/18.10.4/pi_natives.darwin-arm64.node" >"$work/mutating.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] && grep -q 'worktree content changed' "$work/mutating.out" && pass "same-status mid-snapshot content mutation is refused" || fail "mid-snapshot mutation: rc=$rc $(cat "$work/mutating.out")"
git -C "$work/repo" checkout -q -- tracked
cat >"$work/bin/ps-control-mutate" <<'EOF'
#!/bin/sh
count=$(cat "$MUTATE_COUNT" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" >"$MUTATE_COUNT"
[ "$count" = 3 ] && printf 'export default function () { }\n' >"$MUTATE_HOOK"
case " $* " in *' lstart= '*) echo 'Wed Oct 14 00:00:00 2026';; *' command= '*) echo 'omp --resume fake-session';; *) exit 2;; esac
EOF
chmod +x "$work/bin/ps-control-mutate"; : >"$work/control-mutate-count"
set +e
MUTATE_COUNT="$work/control-mutate-count" MUTATE_HOOK="$work/home/.omp/agent/extensions/herdr-control.ts" HERDR_LSOF="$work/bin/lsof-missing" HERDR_PS="$work/bin/ps-control-mutate" HERDR_HOOK="$work/home/.omp/agent/extensions/herdr-control.ts" HERDR_CONTROL_DIR="$work/control" "$here/session-recovery.sh" snapshot --pid 999 --pane p --terminal t --session-file "$work/session.jsonl" --repo "$work/repo" --out "$work/control-mutating" --environment-reviewed --allow-version-change --source-version 18.9.2 --fallback-binary "$work/runtime/18.10.4/omp" --fallback-native "$work/runtime/18.10.4/pi_natives.darwin-arm64.node" >"$work/control-mutating.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] && grep -q 'authority inputs changed' "$work/control-mutating.out" && pass "mid-snapshot hook/config/overlay/authority mutation is refused" || fail "control mutation: rc=$rc $(cat "$work/control-mutating.out")"
printf 'export default function () {}\n' >"$work/home/.omp/agent/extensions/herdr-control.ts"
printf 'ignored-state/\n' >"$work/repo/.gitignore"; git -C "$work/repo" -c user.name=t -c user.email=t@x add .gitignore; git -C "$work/repo" -c user.name=t -c user.email=t@x commit -qm ignore-fixture; mkdir "$work/repo/ignored-state"; printf x >"$work/repo/ignored-state/opaque"
set +e
HERDR_LSOF="$work/bin/lsof-missing" HERDR_PS="$work/bin/ps-stable" HERDR_HOOK="$work/home/.omp/agent/extensions/herdr-control.ts" HERDR_CONTROL_DIR="$work/control" "$here/session-recovery.sh" snapshot --pid 999 --pane p --terminal t --session-file "$work/session.jsonl" --repo "$work/repo" --out "$work/ignored" --environment-reviewed --allow-version-change --source-version 18.9.2 --fallback-binary "$work/runtime/18.10.4/omp" --fallback-native "$work/runtime/18.10.4/pi_natives.darwin-arm64.node" >"$work/ignored.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] && grep -q 'ignored paths' "$work/ignored.out" && pass "excluded ignored state holds migration without disclosure" || fail "ignored state refusal: rc=$rc $(cat "$work/ignored.out")"
rm -rf "$work/repo/ignored-state"
HERDR_LSOF="$work/bin/lsof-missing" HERDR_PS="$work/bin/ps-stable" HERDR_HOOK="$work/home/.omp/agent/extensions/herdr-control.ts" HERDR_CONTROL_DIR="$work/control" "$here/session-recovery.sh" snapshot --pid 999 --pane p --terminal t --session-file "$work/session.jsonl" --repo "$work/repo" --out "$work/exception" --environment-reviewed --allow-version-change --source-version 18.9.2 --fallback-binary "$work/runtime/18.10.4/omp" --fallback-native "$work/runtime/18.10.4/pi_natives.darwin-arm64.node" >/dev/null
[ "$(jq -r .recovery_mode "$work/exception/manifest.json")" = version-changing ] && [ "$(jq -r .source_version "$work/exception/manifest.json")" = 18.9.2 ] && pass "version-changing exception is explicit and recorded" || fail "exception metadata"
(cd "$work/exception" && shasum -a 256 -c SHA256SUMS >/dev/null) && pass "complete recovery bundle verifies" || fail "bundle verification"
revision=0123456789abcdef0123456789abcdef01234567
jq -n --argjson checked_at_epoch "$(date -u +%s)" --arg verifier_sha256 "$(shasum -a 256 "$here/restart.sh" | awk '{print $1}')" --arg bundle_manifest_sha256 "$(shasum -a 256 "$work/exception/manifest.json" | awk '{print $1}')" --arg deployed_revision "$revision" '{schema:1,status:"HEALTHY",checked_at_epoch:$checked_at_epoch,verifier_sha256:$verifier_sha256,bundle_manifest_sha256:$bundle_manifest_sha256,deployed_revision:$deployed_revision}' >"$work/health.json"
[ ! -e "$work/exception/LIVE_ACCEPTED_AT" ] && "$here/session-recovery.sh" accept "$work/exception" --evidence "$work/health.json" --revision "$revision" >/dev/null && [ -e "$work/exception/LIVE_ACCEPTED_AT" ] && pass "fresh acceptance is bundle/revision/verifier-bound" || fail "acceptance binding"
set +e; "$here/session-recovery.sh" accept "$work/exception" --evidence "$work/health.json" --revision 1123456789abcdef0123456789abcdef01234567 >"$work/wrong.out" 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] && grep -q 'not bound' "$work/wrong.out" && pass "wrong-revision acceptance is refused" || fail "wrong revision acceptance"
set +e; "$here/session-recovery.sh" accept "$work/exception" --evidence "$work/health.json" --revision 01234567zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz >"$work/tail.out" 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] && grep -q 'exactly 40 lowercase hexadecimal' "$work/tail.out" && pass "non-hex revision tail is refused before evidence comparison" || fail "invalid-tail revision validation"

echo "# $ok passed, $bad failed"; [ "$bad" = 0 ]
