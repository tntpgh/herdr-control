#!/usr/bin/env bash
# install.sh — wire herdr-control into Claude Code and (optionally) launchd.
#
# The scripts in this repo are useless until something CALLS them. That wiring
# lived only in one machine's ~/.claude/settings.json, so a clone gave you every
# tool and no integration. This does the wiring.
#
#   ./install.sh              # show what would change, touch nothing
#   ./install.sh --apply      # make the changes
#   ./install.sh --apply --bridge     # also install the launchd bridge daemon (macOS)
#   ./install.sh --apply --repoint    # ALSO repoint any job already wired at a
#                                      # different checkout (e.g. an APM-deployed
#                                      # herdr-ops skill copy) to point at THIS one
#
# What it registers in ~/.claude/settings.json:
#   Notification -> agent-hooks/claude-notify.sh       alert you when an agent needs input
#   PostToolUse  -> herdr-resolve.sh                   retract alerts answered in the terminal
#   PostToolUse  -> agent-hooks/interval-reconcile.sh  throttled mid-session reconciliation
#   Stop         -> herdr-resolve.sh                   backstop for the same
#   SessionStart -> agent-hooks/session-reconcile.sh   report task-state changes missed while
#                                                       no conductor was watching (wake persistence)
#
# settings.json is EDITED IN PLACE, never replaced: it is a personal file that
# routinely holds secrets and unrelated config, so this merges only the entries
# above, skips any already present, and writes a timestamped backup first.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

APPLY=0; BRIDGE=0; REPOINT=0
for a in "$@"; do
  case "$a" in
    --apply)   APPLY=1 ;;
    --bridge)  BRIDGE=1 ;;
    --repoint) REPOINT=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
[ "$APPLY" = 1 ] || echo "DRY RUN — nothing will be changed. Re-run with --apply."

# ---- dependencies ----------------------------------------------------------
missing=""
for c in jq python3 herdr curl; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
[ -n "$missing" ] && { echo "missing required commands:$missing" >&2; exit 1; }
echo "deps ok: jq python3 herdr curl"

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
[ -f "$SETTINGS" ] || { echo "no Claude settings at $SETTINGS — is Claude Code installed?" >&2; exit 1; }

# ---- hook registration -----------------------------------------------------
HERE="$here" APPLY="$APPLY" REPOINT="$REPOINT" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os, shutil, collections, datetime, sys

here     = os.environ["HERE"]
apply_   = os.environ["APPLY"] == "1"
repoint  = os.environ["REPOINT"] == "1"
settings = os.environ["SETTINGS"]

# (event, command to add, names that mean "this job is already wired", async, timeout).
# The aliases matter: an existing install may call the same job through a
# differently-named script — e.g. an APM-deployed herdr-ops, or the original
# slack-notify.sh this hook was extracted from. Matching only our own filename
# would add a SECOND hook doing the same work, so every alert would double.
#
# async=False ONLY for session-reconcile.sh: it must run to completion and
# have its stdout captured BEFORE the session's first turn, so its
# hookSpecificOutput.additionalContext actually lands in context — an async
# ("defer hook execution") SessionStart hook's output is not guaranteed to
# arrive in time, which would silently defeat the whole point of this hook.
# Every other hook here fires mid-session and must never block the agent, so
# those stay async=True (interval-reconcile.sh included: its expensive path
# only runs once per HERDR_RECONCILE_INTERVAL_S and must not stall a tool call
# on the rare tick it does real work).
wanted = [
    ("Notification", f'bash {here}/agent-hooks/claude-notify.sh',
        ("claude-notify.sh", "slack-notify.sh", "herdr-notify.sh"), True, 10),
    ("PostToolUse",  f'bash {here}/herdr-resolve.sh',  ("herdr-resolve.sh",), True, 10),
    ("PostToolUse",  f'bash {here}/agent-hooks/interval-reconcile.sh',
        ("interval-reconcile.sh",), True, 20),
    ("Stop",         f'bash {here}/herdr-resolve.sh',  ("herdr-resolve.sh",), True, 10),
    ("SessionStart", f'bash {here}/agent-hooks/session-reconcile.sh',
        ("session-reconcile.sh",), False, 20),
]

with open(settings, encoding="utf-8") as f:
    d = json.load(f, object_pairs_hook=collections.OrderedDict)
hooks = d.setdefault("hooks", collections.OrderedDict())

def find_hook(ev, aliases):
    # Returns (hook_dict, current_command) for the first hook entry under
    # this event whose command matches one of the job's aliases — a
    # reference into the live `hooks` structure, so repointing it below is an
    # in-place mutation, not a second data structure to keep in sync.
    #
    # Matching used to be raw substring containment (`if a in cmd`). That
    # means any command string that merely CONTAINS an alias as a substring
    # anywhere — e.g. a hook literally named "my-herdr-notify.sh.bak"
    # contains "herdr-notify.sh" — got misidentified as "already wired",
    # even though it is a completely unrelated hook. With --repoint that is
    # not cosmetic: this function's return value gets mutated in place
    # below (`h["command"] = new_cmd`), so a substring false-positive would
    # silently corrupt an unrelated entry in a file that routinely holds
    # secrets and unrelated config. Compare basenames of whitespace-split
    # command tokens instead, so a match requires the alias to be an exact
    # path segment (the script's own filename), not a substring anywhere.
    for g in hooks.get(ev, []):
        for h in g.get("hooks", []):
            cmd = h.get("command", "")
            basenames = {os.path.basename(tok.strip("'\"")) for tok in cmd.split()}
            for a in aliases:
                if a in basenames:
                    return h, cmd
    return None, None

add_todo = []       # (ev, cmd, is_async, timeout) — brand new hook groups
repoint_todo = []    # (hook_dict, ev, old_cmd, new_cmd) — existing, path differs

for ev, cmd, aliases, is_async, timeout in wanted:
    h, have = find_hook(ev, aliases)
    if have is None:
        add_todo.append((ev, cmd, is_async, timeout))
        print(f"  + {ev:13s} {cmd}")
    elif have == cmd:
        print(f"  = {ev:13s} already wired -> {have}")
    elif repoint:
        repoint_todo.append((h, ev, have, cmd))
        print(f"  ~ {ev:13s} repoint:")
        print(f"      {have}")
        print(f"      -> {cmd}")
    else:
        print(f"  = {ev:13s} already wired at a DIFFERENT path -> {have}")
        print(f"      pass --repoint to point this job at {cmd}")

if not add_todo and not repoint_todo:
    print("nothing to do — every hook is registered and pointed at this checkout")
    sys.exit(0)

if not apply_:
    print("(dry run — re-run with --apply to write these)")
    sys.exit(0)

stamp  = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = f"{settings}.bak-herdr-{stamp}"
shutil.copy2(settings, backup)

for h, ev, old_cmd, new_cmd in repoint_todo:
    h["command"] = new_cmd
    print(f"  repointed {ev}: {old_cmd} -> {new_cmd}")

for ev, cmd, is_async, timeout in add_todo:
    hooks.setdefault(ev, []).append(collections.OrderedDict([
        ("matcher", ""),
        ("hooks", [collections.OrderedDict([
            ("type", "command"), ("command", cmd),
            ("timeout", timeout), ("async", is_async)])]),
    ]))

tmp = settings + ".tmp-herdr"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
json.load(open(tmp, encoding="utf-8"))   # never leave broken settings behind
# open(tmp, "w") creates the tmp file at the umask-default mode (typically
# 0o644), which silently drops any hardening the user applied to the
# original — e.g. chmod 600 because, per the header above, this file
# routinely holds secrets. os.replace() swaps inodes, it does not carry
# permission bits with it, so without this the file would get quietly
# world/group-readable again on every --apply. `settings` still exists on
# disk at this point (replace hasn't happened yet), so copy its mode onto
# tmp before the swap.
os.chmod(tmp, os.stat(settings).st_mode & 0o777)
os.replace(tmp, settings)
print(f"wrote {settings}  (backup: {backup})")
PY
rc=$?
[ "$rc" -eq 0 ] || { echo "hook registration failed (settings.json untouched)" >&2; exit "$rc"; }

# ---- bridge daemon (optional, macOS) ---------------------------------------
if [ "$BRIDGE" = 1 ]; then
  PLIST="$HOME/Library/LaunchAgents/com.herdr-control.bridge.plist"
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|__RUN_BRIDGE__|$here/slack-bridge/run-bridge.sh|" \
      "$here/slack-bridge/com.herdr-control.bridge.plist.template" > "$PLIST"
    launchctl unload "$PLIST" 2>/dev/null
    launchctl load "$PLIST" && echo "bridge daemon loaded ($PLIST)"
  else
    echo "  + would install launchd plist -> $PLIST"
  fi
fi

cat <<EOF

Next, if you have not already:
  1. cp slack-bridge/herdr-bridge.env.example ~/.config/herdr-bridge.env
     and fill it in (Slack app setup: slack-bridge/SETUP.md)
  2. chmod 600 ~/.config/herdr-bridge.env
  3. start the bridge:  ./slack-bridge/run-bridge.sh   (or --bridge for launchd)
EOF
