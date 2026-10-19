#!/usr/bin/env bash
# verify-ensure-workspace.sh — pins the canonical-workspace-routing fix:
# ensure-workspace.sh --lookup <repo> must prefer a workspace LABELLED for
# that repo over a cwd-match, and must never return a cwd-matched workspace
# that is labelled for a DIFFERENT repo (a contaminated space) — only an
# untagged (default-numeric-label) space is an acceptable cwd fallback.
# Bug observed live 2026-10-19: a stray knowledge-base pane sitting in the
# tntpgh-dev-labelled space made `--lookup knowledge-base` return tntpgh-dev,
# self-reinforcing every KB spawn into the wrong workspace.
#
#   bash verify-ensure-workspace.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

stub_dir=$(mktemp -d)

# Two real git repos so repo_root() resolves cwds to real top-levels.
KB_RAW=$(mktemp -d -t kb-raw); git -C "$KB_RAW" init -q -b main 2>/dev/null
git -C "$KB_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
TNT_RAW=$(mktemp -d -t tntpgh-dev-raw); git -C "$TNT_RAW" init -q -b main 2>/dev/null
git -C "$TNT_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# repo_root uses basename(root) as the label, so give each real repo dirs the
# matching basename.
KB=$(mktemp -d -t knowledge-base-XXXX); rm -rf "$KB"; mv "$KB_RAW" "$KB"
mv "$KB" "$(dirname "$KB")/knowledge-base" 2>/dev/null || true
KB="$(dirname "$KB")/knowledge-base"
TNT=$(mktemp -d -t tntpgh-dev-base-XXXX); rm -rf "$TNT"; mv "$TNT_RAW" "$TNT"
mv "$TNT" "$(dirname "$TNT")/tntpgh-dev" 2>/dev/null || true
TNT="$(dirname "$TNT")/tntpgh-dev"

run_lookup() {   # <repo> <workspace_list_json> <pane_list_json>
  local repo="$1" wsj="$2" pnj="$3"
  cat > "$stub_dir/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list") printf '%s\n' '$wsj' ;;
  "pane list")       printf '%s\n' '$pnj' ;;
  *) printf '{"result":{}}\n' ;;
esac
STUB
  chmod +x "$stub_dir/herdr"
  HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" bash "$HERE/ensure-workspace.sh" --lookup "$repo" 2>/dev/null
  echo "EXIT:$?"
}

# ---- scenario A: contaminated — tntpgh-dev space holds panes from BOTH
# tntpgh-dev and knowledge-base, no "knowledge-base" space exists. ----------
WS_A='{"result":{"workspaces":[{"workspace_id":"w7Y","label":"tntpgh-dev"}]}}'
PN_A=$(printf '{"result":{"panes":[{"workspace_id":"w7Y","cwd":"%s"},{"workspace_id":"w7Y","cwd":"%s"}]}}' "$TNT" "$KB")

out=$(run_lookup "$KB" "$WS_A" "$PN_A")
exit_line=$(printf '%s\n' "$out" | tail -1)
check "contaminated: KB lookup must NOT return tntpgh-dev's workspace" "$exit_line" "EXIT:2"

out=$(run_lookup "$TNT" "$WS_A" "$PN_A")
got=$(printf '%s\n' "$out" | head -1)
check "contaminated: tntpgh-dev lookup still returns w7Y" "$got" "w7Y"

# ---- scenario B: valid canonical — a "knowledge-base" labelled space
# exists alongside the contaminated one. ------------------------------------
WS_B='{"result":{"workspaces":[{"workspace_id":"w7Y","label":"tntpgh-dev"},{"workspace_id":"wKB","label":"knowledge-base"}]}}'
out=$(run_lookup "$KB" "$WS_B" "$PN_A")
got=$(printf '%s\n' "$out" | head -1)
check "valid canonical: KB lookup returns the canonical labelled space" "$got" "wKB"

# ---- scenario C: missing canonical, untagged (numeric-labelled) space
# holds a KB pane — fallback must still match it. ---------------------------
WS_C='{"result":{"workspaces":[{"workspace_id":"w3","label":"3"}]}}'
PN_C=$(printf '{"result":{"panes":[{"workspace_id":"w3","cwd":"%s"}]}}' "$KB")
out=$(run_lookup "$KB" "$WS_C" "$PN_C")
got=$(printf '%s\n' "$out" | head -1)
check "untagged fallback: numeric-labelled space with KB pane matches" "$got" "w3"

# ---- scenario D: legitimate worktree — a KB worktree pane sits inside the
# canonical KB space itself; must resolve there (not create a new one). ----
KB_WT="$HOME/.herdr/worktrees/knowledge-base/some-branch"
mkdir -p "$(dirname "$KB_WT")"
if [ ! -e "$KB_WT" ]; then
  git -C "$KB" worktree add -q -b verify-ensure-workspace-wt "$KB_WT" 2>/dev/null || mkdir -p "$KB_WT"
fi
WS_D='{"result":{"workspaces":[{"workspace_id":"wKB","label":"knowledge-base"}]}}'
PN_D=$(printf '{"result":{"panes":[{"workspace_id":"wKB","cwd":"%s"}]}}' "$KB_WT")
out=$(run_lookup "$KB" "$WS_D" "$PN_D")
got=$(printf '%s\n' "$out" | head -1)
check "worktree pane resolves to canonical KB space" "$got" "wKB"
if git -C "$KB" worktree list 2>/dev/null | grep -q "$KB_WT"; then
  git -C "$KB" worktree remove -f "$KB_WT" >/dev/null 2>&1
fi

rm -rf "$stub_dir" "$KB" "$TNT"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
