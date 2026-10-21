#!/usr/bin/env bash
# Offline: temp git repos only; no herdr, no network.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/provisioned-links.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $1"; }
bad(){ fail=$((fail+1)); echo "FAIL $1"; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
mk(){ local w="$scratch/$1"; git init -q "$w"; printf '*\n' > /dev/null; mkdir -p "$w/.handoffs"; printf '*\n' > "$w/.handoffs/.gitignore"; mkdir -p "$scratch/venv"; echo "$w"; }
clean(){ [ -z "$(porcelain_without_provisioned "$1")" ]; }

w=$(mk a); ln -s "$scratch/venv" "$w/.venv-bashlex"; record_provisioned_link "$w" .venv-bashlex "$scratch/venv"
clean "$w" && ok "recorded untouched link is excused" || bad "recorded link still blocks"

w=$(mk b); ln -s "$scratch/venv" "$w/.venv-bashlex"
clean "$w" && bad "unrecorded (foreign) link excused" || ok "unrecorded link blocks"

w=$(mk c); mkdir -p "$scratch/evil"; ln -s "$scratch/evil" "$w/.venv-bashlex"; record_provisioned_link "$w" .venv-bashlex "$scratch/venv"
clean "$w" && bad "retargeted link excused" || ok "retargeted (tampered) link blocks"

w=$(mk d); mkdir "$w/.venv-bashlex"; touch "$w/.venv-bashlex/x"; record_provisioned_link "$w" .venv-bashlex "$scratch/venv"
clean "$w" && bad "real dir at recorded path excused" || ok "real dir at recorded path blocks"

w=$(mk e); ln -s "$scratch/venv" "$w/.venv-bashlex"; record_provisioned_link "$w" .venv-bashlex "$scratch/venv"; echo work > "$w/notes.txt"
out=$(porcelain_without_provisioned "$w"); [ "$out" = "?? notes.txt" ] && ok "real untracked work still reported" || bad "other work: [$out]"

porcelain_without_provisioned "$scratch/not-a-repo" >/dev/null && bad "git failure read as clean" || ok "git failure is nonzero (HOLD)"

echo "provisioned-links: $pass passed, $fail failed"; [ "$fail" = 0 ]
