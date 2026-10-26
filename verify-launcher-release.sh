#!/usr/bin/env bash
# verify-launcher-release.sh <release_dir> <base_release_dir> <commit>
#
# READ-ONLY proof that an INSTALLED bound-launcher release matches a candidate
# herdr-control commit, for use on the Mac after a release is copied and before
# any deploy. Unlike verify-deploy-launcher-compat.sh (synthetic, CI), this reads
# the real artifact. It writes nothing outside a mktemp dir it removes.
#
#  1 the commit's config.sh names exactly this release's omp and its sha256;
#  2 the omp's embedded pins equal what the commit's tree produces
#    (lib_tree, spawn, selector, overlay) and the release's own companions
#    (binary, native, hook = agent-hooks/omp-herdr-control.ts, extension manifest);
#  3 every extensions.manifest entry hashes to its file;
#  4 the full tree (type, mode, sha256 per path) equals the base release except ./omp;
#  5 both release-label lines name this release directory;
#  6 the env-binding guard (issue #362: PI_CONFIG_FILES et al.) is present in the
#    release's omp, byte-identical to tests/fixtures/launcher-env-guard.v26g.sh,
#    and runs before the argv scan.
set -uo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <release_dir> <base_release_dir> <commit>" >&2; exit 2; }
rel="${1%/}" base="${2%/}" commit="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
ok()  { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
s() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
[ -d "$rel" ] || { echo "FAIL release dir absent: $rel"; exit 1; }
[ -d "$base" ] || { echo "FAIL base release dir absent: $base"; exit 1; }
git -C "$here" rev-parse --verify -q "$commit^{commit}" >/dev/null || { echo "FAIL unknown commit $commit"; exit 1; }
sha_commit="$(git -C "$here" rev-parse "$commit^{commit}")"
printf 'release %s\nbase    %s\ncommit  %s\n' "$rel" "$base" "$sha_commit"

tmp="$(mktemp -d)"; trap 'rm -r "$tmp"' EXIT
git -C "$here" archive "$sha_commit" config.sh lib spawn-task.sh herdr-select.sh agent-hooks | tar -x -C "$tmp"

# 1. config pin (text only; config.sh is not sourced)
want_bin="$(sed -n 's/^HERDR_OMP_BIN="\(.*\)"$/\1/p' "$tmp/config.sh" | sed "s#\$HOME#$HOME#")"
want_sha="$(sed -n 's/^HERDR_OMP_LAUNCHER_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' "$tmp/config.sh")"
omp="$rel/omp"; got_sha="$(s "$omp")"
[ "$want_bin" = "$omp" ] && ok "config HERDR_OMP_BIN = $omp" || bad "config HERDR_OMP_BIN '$want_bin' != $omp"
[ -n "$want_sha" ] && [ "$got_sha" = "$want_sha" ] && ok "omp sha256 $got_sha = config pin" || bad "omp sha256 $got_sha != config pin '$want_sha'"

# 2. embedded pins
pin() { awk -F= -v k="$1" '$1==k {print $2; exit}' "$omp"; }
lib_tree="$( (cd "$tmp" && find lib -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '*.pyo' -not -name '.DS_Store' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done) | shasum -a 256 | awk '{print $1}')"
check() { [ "$(pin "$1")" = "$2" ] && ok "$1 = $2 ($3)" || bad "$1 '$(pin "$1")' != $2 ($3)"; }
check lib_tree_sha "$lib_tree" "commit lib/"
check spawn_sha "$(s "$tmp/spawn-task.sh")" "commit spawn-task.sh"
check selector_sha "$(s "$tmp/herdr-select.sh")" "commit herdr-select.sh"
check overlay_sha "$(s "$tmp/agent-hooks/omp-worker-overlay.yml")" "commit overlay"
check hook_sha "$(s "$rel/extensions/herdr-control.ts")" "release extensions/herdr-control.ts"
[ "$(s "$rel/extensions/herdr-control.ts")" = "$(s "$tmp/agent-hooks/omp-herdr-control.ts")" ] \
  && ok "release hook == commit agent-hooks/omp-herdr-control.ts" || bad "release hook differs from commit agent-hooks/omp-herdr-control.ts"
check binary_sha "$(s "$rel/payload/omp")" "release payload/omp"
check native_sha "$(s "$rel/natives/18.10.4/pi_natives.darwin-arm64.node")" "release native"
check extension_manifest_sha "$(s "$rel/extensions.manifest")" "release extensions.manifest"

# 3. extension manifest entries
while read -r expected name extra; do
  [ -n "${expected:-}" ] || continue
  [ "$(s "$rel/extensions/$name")" = "$expected" ] || bad "extension $name hash != manifest"
done < "$rel/extensions.manifest"
ok "extensions.manifest entries checked ($(grep -c . "$rel/extensions.manifest"))"

# 4. full tree vs base (type, mode, sha256 per path), only ./omp may differ
manifest() {
  ( cd "$1" && find . -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
      if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"
      elif [ -d "$f" ]; then printf 'D %s %s\n' "$(stat -f %Lp "$f")" "$f"
      else printf 'F %s %s %s\n' "$(stat -f %Lp "$f")" "$(s "$f")" "$f"; fi; done )
}
manifest "$rel" > "$tmp/rel.m"; manifest "$base" > "$tmp/base.m"
d="$(diff <(grep -v ' \./omp$' "$tmp/base.m") <(grep -v ' \./omp$' "$tmp/rel.m"))"
[ -z "$d" ] && ok "tree identical to base except ./omp ($(wc -l < "$tmp/rel.m") entries)" || { bad "tree differs from base:"; printf '%s\n' "$d" | head -20; }
[ "$(stat -f %Lp "$omp")" = 555 ] && ok "omp mode 555" || bad "omp mode $(stat -f %Lp "$omp") != 555"
printf 'release manifest sha256 %s\n' "$(s "$tmp/rel.m")"

# 5. release labels
label="$(basename "$rel")"
n="$(grep -c -- "$label" "$omp")"
[ "$n" = 2 ] && grep -q "^export OMP_BOUND_RELEASE_ID=$label$" "$omp" && ok "release label $label x2" || bad "release label $label count $n"

# 6. env-binding guard (issue #362): release's own block vs the pinned fixture
# contract. Each defect mode fails closed (negative-tested below) so a wrong,
# missing, or tampered guard -- in the fixture OR the release -- is caught
# rather than silently skipped.
env_guard_fixture="$here/tests/fixtures/launcher-env-guard.v26g.sh"
env_guard_fixture_sha=b5192ce9510895be69c1dc76b23dc218feeb470b6a5b0c3f465f68ee61f64793
env_guard_block_of() { awk '/^for env_var in /,/^done$/' "$1" 2>/dev/null; }
env_guard_shape_ok() {
  printf '%s\n' "$1" | grep -q '^for env_var in PI_CONFIG_FILES ' \
    && printf '%s\n' "$1" | grep -q 'die "\$env_var may bypass the bound overlays"' \
    && printf '%s\n' "$1" | grep -q '^done$'
}
env_guard_digest() { printf '%s\n' "$1" | shasum -a 256 | awk '{print $1}'; }
load_env_guard() {  # <file> <pinned-sha>: prints block, nonzero on any defect
  [ -f "$1" ] || return 1
  local b; b="$(env_guard_block_of "$1")"
  [ -n "$b" ] && env_guard_shape_ok "$b" && [ "$(env_guard_digest "$b")" = "$2" ] || return 1
  printf '%s' "$b"
}
fixture_block="$(load_env_guard "$env_guard_fixture" "$env_guard_fixture_sha")" \
  && ok "env-guard fixture present, shape ok, digest pinned ($env_guard_fixture_sha)" \
  || bad "env-guard fixture missing/empty/wrong shape/digest mismatch: $env_guard_fixture"
rel_block="$(env_guard_block_of "$omp")"
[ -n "$rel_block" ] && env_guard_shape_ok "$rel_block" && [ "$(env_guard_digest "$rel_block")" = "$env_guard_fixture_sha" ] \
  && ok "release omp env-binding guard == pinned fixture ($env_guard_fixture_sha)" \
  || bad "release omp env-binding guard missing or differs from pinned fixture"
# env-guard must run before the argv scan, so PI_CONFIG_FILES etc. can never
# reach a --config <overlay> check that only validates the two herdr paths.
guard_line="$(grep -n '^for env_var in PI_CONFIG_FILES ' "$omp" | head -1 | cut -d: -f1)"
argv_line="$(grep -n '^args=("\$@")$' "$omp" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$argv_line" ] && [ "$guard_line" -lt "$argv_line" ] \
  && ok "env-binding guard (line $guard_line) runs before argv scan (line $argv_line)" \
  || bad "env-binding guard missing or does not precede the argv scan"

# negatives: load_env_guard must fail closed on every defect mode
mkdir -p "$tmp/env_neg"
load_env_guard "$tmp/env_neg/absent.sh" "$env_guard_fixture_sha" >/dev/null \
  && bad "missing env-guard fixture loaded" || ok "missing env-guard fixture fails closed"
: > "$tmp/env_neg/empty.sh"
load_env_guard "$tmp/env_neg/empty.sh" "$env_guard_fixture_sha" >/dev/null \
  && bad "empty env-guard fixture loaded" || ok "empty env-guard fixture fails closed"
sed 's/may bypass the bound overlays/may bypass the bound overlays!/' "$env_guard_fixture" > "$tmp/env_neg/tampered.sh"
load_env_guard "$tmp/env_neg/tampered.sh" "$env_guard_fixture_sha" >/dev/null \
  && bad "tampered env-guard fixture loaded" || ok "tampered env-guard fixture: digest mismatch fails closed"
load_env_guard "$env_guard_fixture" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null \
  && bad "wrong env-guard pin accepted" || ok "wrong pinned env-guard digest fails closed"
printf 'for env_var in PI_CONFIG_FILES; do\n  :\ndone\n' > "$tmp/env_neg/shape.sh"
load_env_guard "$tmp/env_neg/shape.sh" "$(env_guard_digest "$(env_guard_block_of "$tmp/env_neg/shape.sh")")" >/dev/null \
  && bad "wrong-shape env-guard loaded" || ok "wrong-shape env-guard fails closed even with a matching digest"
printf '' > "$tmp/env_neg/no_guard_omp"
rel_block_missing="$(env_guard_block_of "$tmp/env_neg/no_guard_omp")"
[ -z "$rel_block_missing" ] && ok "a release omp with no env-guard block is detected as absent" \
  || bad "env_guard_block_of found a block that should not exist"

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
