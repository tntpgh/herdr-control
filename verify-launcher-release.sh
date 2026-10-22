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
#  5 both release-label lines name this release directory.
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

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
