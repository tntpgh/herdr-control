#!/usr/bin/env bash
# install.sh — wire herdr-control into Claude Code, omp, and (optionally) launchd.
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
#                                      # herdr-ops skill copy) to point at THIS one —
#                                      # applies to BOTH the Claude hooks below and
#                                      # the omp extension symlink
#
# What it registers in ~/.claude/settings.json:
#   Notification -> agent-hooks/claude-notify.sh       alert you when an agent needs input
#   PreToolUse   -> agent-hooks/claude-pretooluse-cache.sh  cache the tool+command so
#                                                       the Notification alert above can
#                                                       show what is being approved, not
#                                                       just that something needs approval
#   PostToolUse  -> herdr-resolve.sh                   retract alerts answered in the terminal
#   PostToolUse  -> agent-hooks/interval-reconcile.sh  throttled mid-session reconciliation
#   Stop         -> herdr-resolve.sh                   backstop for the same
#   SessionStart -> agent-hooks/session-reconcile.sh   report task-state changes missed while
#                                                       no conductor was watching (wake persistence)
#
# settings.json is EDITED IN PLACE, never replaced: it is a personal file that
# routinely holds secrets and unrelated config, so this merges only the entries
# above, skips any already present, and writes a timestamped backup first.
#
# What it symlinks for omp (Oh My Pi), under ~/.omp/agent/extensions/ (or
# $PI_CODING_AGENT_DIR/extensions when set):
#   herdr-control.ts -> agent-hooks/omp-herdr-control.ts   the same four jobs
#                                                           above, via omp's
#                                                           tool_call / tool_result /
#                                                           before_agent_start /
#                                                           agent_end extension events
#
# omp has no settings.json-style hook config to merge into — its extensions
# are plain files it auto-discovers by directory, resolved to their REALPATH
# before import. A symlink into this checkout gets the same "edit here, no
# reinstall needed" property the Claude wiring gets from invoking scripts by
# path; it just can't be merged the way JSON can, so a real (non-symlink)
# file already at that path is left alone and reported, never clobbered.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

APPLY=0; BRIDGE=0; REPOINT=0
for a in "$@"; do
  case "$a" in
    --apply)   APPLY=1 ;;
    --bridge)  BRIDGE=1 ;;
    --repoint) REPOINT=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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
    ("PreToolUse",   f'bash {here}/agent-hooks/claude-pretooluse-cache.sh',
        ("claude-pretooluse-cache.sh",), True, 10),
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

# ---- herdr Agents sidebar config -------------------------------------------
# docs/herdr-config-snippet.toml's [ui.sidebar.agents] block replaces herdr's
# bare "workspace / tab" default agent-card row with $task/$status (smart-
# name.sh's label, attention.sh's honest waiting reason) — without it, every
# tab herdr-control's own tools didn't explicitly label (most notably a
# workspace's own root tab, ensure-workspace.sh) shows up in the Agents panel
# as generic noise instead of real work. Paired with sidebar_min_width: herdr
# auto-scales the sidebar to fit the SHORTEST row's content (state_icon +
# workspace + tab), so short workspace/tab names can leave the $task/$status
# rows below them truncated even though smart-name.sh's own naming budget
# (30 chars, smart-name.sh's NAMING_INSTRUCTION) fits well inside herdr's
# documented 36-column max — the sidebar just never grew that wide on its
# own. A floor, not a fixed width: workspaces that need more still grow past
# it, this only stops it shrinking below what a full task label needs.
#
# config.toml is EDITED IN PLACE with a backup first, same "never silently
# replace personal config" posture as settings.json above. The [ui.sidebar.
# agents] table is pure append (it does not exist in herdr's shipped
# defaults); sidebar_min_width is inserted into the EXISTING bare [ui] table
# if one is already present (TOML forbids a second [ui] header), else a new
# one is appended.
HERDR_CONFIG="${HERDR_CONFIG:-$HOME/.config/herdr/config.toml}"
need_agents_block=0; need_sidebar_width=0
if [ -f "$HERDR_CONFIG" ]; then
  grep -q '^\[ui\.sidebar\.agents\]' "$HERDR_CONFIG" 2>/dev/null || need_agents_block=1
  grep -q '^sidebar_min_width' "$HERDR_CONFIG" 2>/dev/null || need_sidebar_width=1
fi
if [ ! -f "$HERDR_CONFIG" ]; then
  echo "  ! no herdr config at $HERDR_CONFIG — skipping Agents sidebar setup (herdr not configured yet?)" >&2
elif [ "$need_agents_block" = 0 ] && [ "$need_sidebar_width" = 0 ]; then
  echo "  = herdr Agents sidebar config already wired -> $HERDR_CONFIG"
elif [ "$APPLY" = 1 ]; then
  cp "$HERDR_CONFIG" "${HERDR_CONFIG}.bak-herdr-control-$(date +%Y%m%d%H%M%S)"
  if [ "$need_sidebar_width" = 1 ]; then
    if grep -q '^\[ui\]$' "$HERDR_CONFIG"; then
      awk '{print} /^\[ui\]$/ && !d {print "sidebar_min_width = 34"; d=1}' "$HERDR_CONFIG" > "${HERDR_CONFIG}.tmp" \
        && mv "${HERDR_CONFIG}.tmp" "$HERDR_CONFIG"
    else
      printf '\n[ui]\nsidebar_min_width = 34\n' >> "$HERDR_CONFIG"
    fi
    echo "  + set sidebar_min_width = 34 in $HERDR_CONFIG"
  fi
  if [ "$need_agents_block" = 1 ]; then
    {
      printf '\n'
      sed -n '/^# ---- Agent sidebar cards/,/^\]$/p' "$here/docs/herdr-config-snippet.toml"
    } >> "$HERDR_CONFIG"
    echo "  + appended [ui.sidebar.agents] to $HERDR_CONFIG"
  fi
  echo "    (backup written alongside it)"
  if command -v herdr >/dev/null 2>&1 && herdr server reload-config >/dev/null 2>&1; then
    echo "    reloaded: herdr server reload-config"
    echo "    NOTE: some sidebar settings only apply to a freshly attached client —"
    echo "    detach and run \`herdr session attach default\` (or reattach however you"
    echo "    normally do) if the change doesn't show up immediately."
  else
    echo "    ! reload-config failed or herdr unreachable — restart herdr, or run: herdr server reload-config" >&2
  fi
else
  [ "$need_agents_block" = 1 ] && echo "  + would append [ui.sidebar.agents] sidebar block -> $HERDR_CONFIG"
  [ "$need_sidebar_width" = 1 ] && echo "  + would set sidebar_min_width = 34 -> $HERDR_CONFIG"
fi

# ---- omp extension symlink --------------------------------------------------
# omp auto-discovers extension modules from $PI_CODING_AGENT_DIR/extensions
# when set, else ~/.omp/agent/extensions/ — honoring the operator's own agent
# dir override the same way the block above honors $CLAUDE_SETTINGS. omp's
# loader resolves each entry to its REALPATH before dynamic-importing it, so
# a symlink into THIS checkout is picked up and reloads on every edit — the
# same live-checkout property `bash $here/...` gives the Claude hooks,
# achieved differently because omp has no settings.json-style command
# string to merge a path into.
OMP_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
OMP_EXT_DIR="$OMP_AGENT_DIR/extensions"
OMP_LINK="$OMP_EXT_DIR/herdr-control.ts"
OMP_TARGET="$here/agent-hooks/omp-herdr-control.ts"

if [ -L "$OMP_LINK" ] && [ "$(readlink "$OMP_LINK")" = "$OMP_TARGET" ]; then
  echo "  = omp extension already wired -> $OMP_LINK"
elif [ -L "$OMP_LINK" ]; then
  # Points somewhere else — a different checkout, an APM-deployed copy, or a
  # stale link from a machine move. Same --repoint gate as the Claude hooks
  # above: repointing an existing install is a deliberate opt-in, never
  # something a plain re-run does on its own.
  omp_have=$(readlink "$OMP_LINK")
  if [ "$REPOINT" = 1 ]; then
    if [ "$APPLY" = 1 ]; then
      ln -sf "$OMP_TARGET" "$OMP_LINK"
      echo "  ~ omp extension repointed: $omp_have -> $OMP_TARGET"
    else
      echo "  ~ omp extension repoint:"
      echo "      $omp_have"
      echo "      -> $OMP_TARGET"
    fi
  else
    echo "  = omp extension already wired at a DIFFERENT path -> $omp_have"
    echo "      pass --repoint to point this job at $OMP_TARGET"
  fi
elif [ -e "$OMP_LINK" ]; then
  # A real (non-symlink) file already occupies this path — never ours to
  # delete. Mirrors settings.json's "never overwrite personal config"
  # posture above: report and refuse rather than guess it is safe to replace.
  echo "  ! omp extension refusing to overwrite non-symlink file -> $OMP_LINK" >&2
elif [ "$APPLY" = 1 ]; then
  mkdir -p "$OMP_EXT_DIR"
  ln -s "$OMP_TARGET" "$OMP_LINK"
  echo "  + omp extension $OMP_LINK -> $OMP_TARGET"
else
  echo "  + omp extension $OMP_LINK -> $OMP_TARGET"
fi

# ---- bridge daemon (optional, macOS) ---------------------------------------
if [ "$BRIDGE" = 1 ]; then
  PLIST="$HOME/Library/LaunchAgents/com.herdr-control.bridge.plist"

  # A bridge daemon may already be installed under a DIFFERENT label — one
  # machine had it under a different reverse-DNS label, pointed at an
  # ~/.claude/skills/herdr-ops copy. Writing our own label on top of that does not
  # replace it, it ADDS a second daemon: two Socket-Mode clients on one Slack app,
  # so every reply is delivered twice and both race to press keys at the same
  # prompt. Same "detect, do not duplicate" rule the hook wiring above follows.
  #
  # Not auto-fixed, because which copy should own the daemon is an operator
  # decision and the other plist may be hand-maintained: repointing an existing
  # plist's ProgramArguments at this checkout is usually right, but that is a
  # choice, not a default.
  OTHER_BRIDGE=""
  for p in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$p" ] || continue
    [ "$p" = "$PLIST" ] && continue
    if grep -q 'slack-bridge/run-bridge.sh' "$p" 2>/dev/null; then
      OTHER_BRIDGE="$p"
      break
    fi
  done
  if [ -n "$OTHER_BRIDGE" ]; then
    echo "  ! another bridge LaunchAgent already exists: $OTHER_BRIDGE" >&2
    echo "  ! installing $PLIST too would run TWO daemons — every Slack reply delivered twice." >&2
    echo "  ! repoint that plist's ProgramArguments at $here/slack-bridge/run-bridge.sh instead," >&2
    echo "  ! or remove it first. Skipping the bridge step." >&2
  elif [ "$APPLY" = 1 ]; then
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    sed -e "s|__RUN_BRIDGE__|$here/slack-bridge/run-bridge.sh|" \
        -e "s|__LOG_PATH__|$HOME/Library/Logs/com.herdr-control.bridge.log|g" \
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
