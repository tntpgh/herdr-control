#!/usr/bin/env bash
# verify-spawn-root-tab.sh — spawn-task.sh closes herdr's empty auto-created
# root tab ONLY when that same call created the workspace, never another tab.
#
# The regression: the cleanup used to close any other tab whose pane had no
# `.agent`. herdr 0.9.2 clears a self-reported agent ~0.5s after its pane is
# back at an idle shell (herdr#4687), so a worker that exited to its shell lost
# its tab to the next spawn in the same repo. herdr is stubbed; nothing live.
#
# Exit: 0 all checks passed, 1 a check failed
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n       %s\n' "$1" "$2"; fail=1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo="$work/repo"; mkdir -p "$repo"; git -C "$repo" init -q
repo=$(cd "$repo" && pwd -P)

# EXISTING=1: the repo already has workspace w1 with a finished worker's tab
# (tOld) whose pane is at a shell, so it reports no agent. EXISTING=0: no
# workspace yet; `workspace create` returns w1 with auto root tab tRoot.
cat > "$work/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/herdr.log"
case "\$1 \$2" in
  "pane list")
    if [ "\${EXISTING:-0}" = 1 ]; then
      printf '{"result":{"panes":[{"pane_id":"pOld","tab_id":"tOld","workspace_id":"w1","cwd":"$repo"}]}}\n'
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  "tab list")
    if [ "\${EXISTING:-0}" = 1 ]; then
      printf '{"result":{"tabs":[{"tab_id":"tOld","workspace_id":"w1"},{"tab_id":"t1","workspace_id":"w1"}]}}\n'
    else
      printf '{"result":{"tabs":[{"tab_id":"tRoot","workspace_id":"w1"},{"tab_id":"t1","workspace_id":"w1"}]}}\n'
    fi ;;
  "workspace create") printf '{"result":{"workspace":{"workspace_id":"w1","active_tab_id":"tRoot"}}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
STUB
chmod +x "$work/herdr"

spawn() {  # <EXISTING> <branch>
  : > "$work/herdr.log"
  env EXISTING="$1" HERDR_EXTRA_PATH="$work" PATH="$work:$PATH" HERDR_WT_DIR="$work/wt-$2" \
    HERDR_RUN_STATE_DIR="$work/state-$2" \
    bash "$here/spawn-task.sh" "$repo" "$2" quick /bin/true >/dev/null 2>&1
}

spawn 1 reuse
if ! grep -q '^tab create' "$work/herdr.log"; then
  bad "harness: the spawn reached tab create" "$(tr '\n' ';' < "$work/herdr.log")"
elif grep -q '^tab close' "$work/herdr.log"; then
  bad "an existing workspace loses no tab" "closed: $(grep '^tab close' "$work/herdr.log" | tr '\n' ';')"
else
  ok "an existing workspace loses no tab, even one whose pane reports no agent"
fi

spawn 0 fresh
if grep -qx 'tab close tRoot' "$work/herdr.log" && [ "$(grep -c '^tab close' "$work/herdr.log")" = 1 ]; then
  ok "a workspace this call created has its empty root tab closed, and only that"
else
  bad "new workspace root tab" "closes: $(grep '^tab close' "$work/herdr.log" | tr '\n' ';') log: $(grep -c . "$work/herdr.log") lines"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
