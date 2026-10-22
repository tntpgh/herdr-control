#!/usr/bin/env bash
# verify-deploy-launcher-compat.sh — offline, credential-free regression for
# deploy_app's launcher preflight (launchd/agent-lib.sh _deploy_launcher_preflight).
#
# Claim under test: a revision whose lib/ tree differs from the bound
# launcher's lib_tree_sha is REFUSED before anything is deployed, and the
# same revision is accepted once a launcher pinning its exact content is
# named by its own config.sh. A candidate that changes lib/ without a
# matching launcher release is therefore never "deployable".
#
# Uses the REAL function against a scratch git repo built from this
# checkout. Nothing outside $WORK is read or written; no network, no secrets.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/launchd/agent-lib.sh"

fails=0
ok()  { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

WORK="$(mktemp -d)"; trap 'rm -r "$WORK"' EXIT
repo="$WORK/repo"; mkdir -p "$repo"
git -C "$here" archive HEAD config.sh lib spawn-task.sh herdr-select.sh agent-hooks/omp-worker-overlay.yml | tar -x -C "$repo"
git -C "$repo" init -q && git -C "$repo" -c user.email=ci@example.com -c user.name=ci add -A \
  && git -C "$repo" -c user.email=ci@example.com -c user.name=ci commit -qm base

lib_tree() {  # <dir> -> the launcher's lib_tree_sha formula
  ( cd "$1" && find lib -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '*.pyo' -not -name '.DS_Store' \
      | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) | shasum -a 256 | awk '{print $1}'
}
s() { shasum -a 256 "$1" | awk '{print $1}'; }

# pin_launcher <name> <lib_tree_sha>: fixture launcher pinning the repo's
# current spawn/selector/overlay and the given lib tree, named by config.sh.
pin_launcher() {
  local bin="$WORK/$1/omp"; mkdir -p "$WORK/$1"
  printf '#!/bin/sh\nexit 0\nlib_tree_sha=%s\nspawn_sha=%s\nselector_sha=%s\noverlay_sha=%s\n' \
    "$2" "$(s "$repo/spawn-task.sh")" "$(s "$repo/herdr-select.sh")" "$(s "$repo/agent-hooks/omp-worker-overlay.yml")" > "$bin"
  local cfg; cfg="$(grep -vE '^HERDR_OMP_(BIN|LAUNCHER_SHA256)=' "$repo/config.sh")"
  printf 'HERDR_OMP_BIN="%s"\nHERDR_OMP_LAUNCHER_SHA256="%s"\n%s\n' "$bin" "$(s "$bin")" "$cfg" > "$repo/config.sh"
  git -C "$repo" -c user.email=ci@example.com -c user.name=ci commit -qam "pin $1"
}

old_tree="$(lib_tree "$repo")"
pin_launcher old "$old_tree"
_deploy_launcher_preflight "$repo" HEAD 2>/dev/null && ok "matching launcher accepted" || bad "matching launcher refused"

# Candidate changes lib/ but keeps the old launcher pin -> must be refused.
printf '# candidate change\n' >> "$repo/lib/run-registry.sh"
git -C "$repo" -c user.email=ci@example.com -c user.name=ci commit -qam "lib change, old pin"
out="$(_deploy_launcher_preflight "$repo" HEAD 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSED .* lib_tree_sha'; then ok "lib change + old launcher pin refused (lib_tree_sha)"
else bad "lib change + old launcher pin NOT refused (rc=$rc): $out"; fi

# Same candidate with a launcher release pinning its exact lib tree -> accepted.
pin_launcher new "$(lib_tree "$repo")"
_deploy_launcher_preflight "$repo" HEAD 2>/dev/null && ok "candidate + matching new launcher accepted" || bad "candidate + matching new launcher refused"

# Launcher bytes not matching config's digest -> refused.
printf '# tampered\n' >> "$WORK/new/omp"
_deploy_launcher_preflight "$repo" HEAD 2>/dev/null && bad "tampered launcher accepted" || ok "tampered launcher refused (digest)"

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
