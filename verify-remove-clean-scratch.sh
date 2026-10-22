#!/usr/bin/env bash
# Offline: temp git repos and a local bare "remote" only.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; s="$here/remove-clean-scratch.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $1"; }; bad(){ fail=$((fail+1)); echo "FAIL $1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
git init -q --bare "$t/remote.git"
git init -q "$t/main"; git -C "$t/main" -c user.email=x@y -c user.name=x commit -q --allow-empty -m base
git -C "$t/main" remote add origin "$t/remote.git"; git -C "$t/main" push -q origin HEAD:refs/heads/main; git -C "$t/main" fetch -q origin
wt(){ git -C "$t/main" worktree add -q --detach "$t/$1" HEAD; echo "$t/$1"; }

p=$(wt clean); out=$(bash "$s" --apply "$p"); [ ! -d "$p" ] && ok "clean detached pushed tree removed" || bad "clean not removed: $out"

p=$(wt link); mkdir -p "$t/venv"; ln -s "$t/venv" "$p/.venv-bashlex"
bash "$s" --apply "$p" >/dev/null; { [ -d "$p" ] && [ -L "$p/.venv-bashlex" ]; } && ok "untracked symlink HOLDs and is NOT unlinked" || bad "symlink tree touched"

p=$(wt untracked); echo x > "$p/notes"; bash "$s" --apply "$p" >/dev/null; [ -f "$p/notes" ] && ok "untracked file HOLDs" || bad "untracked removed"

p=$(wt ign); printf 'cache\n' > "$p/.git-info-exclude-test"; echo cache >> "$(git -C "$p" rev-parse --git-common-dir)/info/exclude"; rm "$p/.git-info-exclude-test"; echo y > "$p/cache"
bash "$s" --apply "$p" >/dev/null; [ -f "$p/cache" ] && ok "ignored file HOLDs" || bad "ignored removed"

p=$(wt local); git -C "$p" -c user.email=x@y -c user.name=x commit -q --allow-empty -m only-here
bash "$s" --apply "$p" >/dev/null; [ -d "$p" ] && ok "unpushed HEAD HOLDs" || bad "unpushed removed"

git -C "$t/main" worktree add -q "$t/br" -b feature; bash "$s" --apply "$t/br" >/dev/null; [ -d "$t/br" ] && ok "branch worktree HOLDs" || bad "branch removed"

bash "$s" --apply "$t/main" >/dev/null; [ -d "$t/main/.git" ] && ok "main checkout HOLDs" || bad "main removed"

p=$(wt dry); bash "$s" "$p" >/dev/null; [ -d "$p" ] && ok "dry run changes nothing" || bad "dry run removed"

echo "remove-clean-scratch: $pass passed, $fail failed"; [ "$fail" = 0 ]
