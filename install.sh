#!/usr/bin/env bash
# install.sh — wire herdr-control into Claude Code and (optionally) launchd.
#
# The scripts in this repo are useless until something CALLS them. That wiring
# lived only in one machine's ~/.claude/settings.json, so a clone gave you every
# tool and no integration. This does the wiring.
#
#   ./install.sh              # show what would change, touch nothing
#   ./install.sh --apply      # make the changes
#   ./install.sh --apply --bridge   # also install the launchd bridge daemon (macOS)
#
# What it registers in ~/.claude/settings.json:
#   Notification -> hooks/claude-notify.sh   alert you when an agent needs input
#   PostToolUse  -> herdr-resolve.sh         retract alerts answered in the terminal
#   Stop         -> herdr-resolve.sh         backstop for the same
#
# settings.json is EDITED IN PLACE, never replaced: it is a personal file that
# routinely holds secrets and unrelated config, so this merges only the entries
# above, skips any already present, and writes a timestamped backup first.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

APPLY=0; BRIDGE=0
for a in "$@"; do
  case "$a" in
    --apply)  APPLY=1 ;;
    --bridge) BRIDGE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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
HERE="$here" APPLY="$APPLY" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os, shutil, collections, datetime, sys

here     = os.environ["HERE"]
apply_   = os.environ["APPLY"] == "1"
settings = os.environ["SETTINGS"]

# (event, command to add, names that mean "this job is already wired").
# The aliases matter: an existing install may call the same job through a
# differently-named script — e.g. an APM-deployed herdr-ops, or the original
# slack-notify.sh this hook was extracted from. Matching only our own filename
# would add a SECOND hook doing the same work, so every alert would double.
wanted = [
    ("Notification", f'bash {here}/hooks/claude-notify.sh',
        ("claude-notify.sh", "slack-notify.sh", "herdr-notify.sh")),
    ("PostToolUse",  f'bash {here}/herdr-resolve.sh',  ("herdr-resolve.sh",)),
    ("Stop",         f'bash {here}/herdr-resolve.sh',  ("herdr-resolve.sh",)),
]

with open(settings, encoding="utf-8") as f:
    d = json.load(f, object_pairs_hook=collections.OrderedDict)
hooks = d.setdefault("hooks", collections.OrderedDict())

def existing(ev, aliases):
    for g in hooks.get(ev, []):
        for h in g.get("hooks", []):
            cmd = h.get("command", "")
            for a in aliases:
                if a in cmd:
                    return cmd
    return None

todo = []
for ev, cmd, aliases in wanted:
    have = existing(ev, aliases)
    if have:
        print(f"  = {ev:13s} already wired -> {have}")
    else:
        todo.append((ev, cmd))
        print(f"  + {ev:13s} {cmd}")

if not todo:
    print("nothing to do — all hooks already registered")
    sys.exit(0)

if not apply_:
    print("(dry run — re-run with --apply to write these)")
    sys.exit(0)

stamp  = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = f"{settings}.bak-herdr-{stamp}"
shutil.copy2(settings, backup)

for ev, cmd in todo:
    hooks.setdefault(ev, []).append(collections.OrderedDict([
        ("matcher", ""),
        ("hooks", [collections.OrderedDict([
            ("type", "command"), ("command", cmd),
            ("timeout", 10), ("async", True)])]),
    ]))

tmp = settings + ".tmp-herdr"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
json.load(open(tmp, encoding="utf-8"))   # never leave broken settings behind
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
