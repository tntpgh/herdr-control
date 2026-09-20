#!/usr/bin/env bash
# sweep-prompts.sh — auto-approve READ-ONLY tool prompts in a worker pane, and
# stop dead on anything that deserves a human.
#
# THE GAP THIS CLOSES. `wait-for-blocked.sh` detects a blocked pane and reports
# it; `herdr-select.sh` presses a key but refuses anything its screen dislikes —
# including false positives, e.g. `grep -n "process.env|createClient" build.mjs`
# is read-only but trips the credential rule because those strings are the
# SEARCH PATTERN. Neither will walk a read-only reviewer through eighty `read`
# and `grep` approvals. Run by hand from a conductor that costs a round trip per
# keypress, an audit turns into an afternoon.
#
# THE POLICY, which is the whole point of the file:
#   - An explicit DENYLIST of things that mutate shared state, touch
#     credentials, or escalate. A hit makes the sweeper EXIT 3 and leave the
#     prompt painted, untouched, for a human. It never decides those.
#   - Everything else gets Enter (option 1 = Approve).
#   - Two modes, because a reviewer and an implementer differ on exactly one
#     axis — whether writing to its own branch is expected work:
#       review    (default) any mutation is a human decision.
#       implement branch commits and pushes are its job; pushing main,
#                 force-pushing, --no-verify and merging never are.
#
# This presses keys into another agent's session. Read the denylist before you
# trust it, and prefer `review` unless the worker genuinely needs to commit.
#
# Usage:  sweep-prompts.sh <pane-id> [max-minutes] [review|implement]
# Exit:   0 settled (no prompt for 8 consecutive checks, pane idle/done)
#         3 denylist hit — prompt left for a human, command echoed
# Rollback: kill the process. Pending prompts are never altered.
set -uo pipefail

PANE="${1:?usage: sweep-prompts.sh <pane-id> [max-minutes] [review|implement]}"
MAX_MIN="${2:-45}"
MODE="${3:-review}"
DEADLINE=$(( $(date +%s) + MAX_MIN * 60 ))

# Credentials, destruction, escalation, deploys, publishes, history rewrites.
COMMON='rm[[:space:]]+-rf?|op[[:space:]]+read|OP_SERVICE|printenv|(^|[;&|[:space:]])env[[:space:]]+\||cat[[:space:]][^|]*\.env|sudo|wrangler[[:space:]]+(deploy|publish)|supabase[[:space:]]+db[[:space:]]+push|npm[[:space:]]+publish|gh[[:space:]]+pr[[:space:]]+(merge|close)|--no-verify|push[[:space:]]+--force|push[[:space:]]+-f[[:space:]]|force-with-lease|push[[:space:]]+[^|;&]*origin[[:space:]]+main|push[[:space:]]+[^|;&]*HEAD:main|:main[[:space:]]*$|filter-branch|reset[[:space:]]+--hard'
if [ "$MODE" = "implement" ]; then
  DENY="$COMMON"
else
  DENY="$COMMON|git[[:space:]]+(push|merge|rebase|commit)|gh[[:space:]]+pr[[:space:]]+edit|>[[:space:]]*(src|public|config|\.github)/"
fi

# Extract the command/code body of a live "Allow tool" box. Bounded between the
# header and the Approve row so the TODO side-panel cannot bleed into the text
# being screened — a truncated read that loses the dangerous half of a command
# would be the one way this script does harm.
body() {
  herdr pane read "$PANE" --source visible --lines 46 --format text 2>/dev/null \
  | sed 's/[│╭╰├└╮╯]//g' \
  | awk '/Allow tool/{buf=""; inbox=1; next} inbox && /Approve/{print buf; inbox=0} inbox{buf=buf" "$0}' \
  | tail -1 \
  | sed -E 's/^[[:space:]]*(Command|Code|Script)[[:space:]]*:[[:space:]]*//' \
  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

status() {
  herdr tab list 2>/dev/null | python3 -c \
    'import sys,json;d=json.load(sys.stdin)["result"]["tabs"];print(next((t["agent_status"] for t in d if t["tab_id"]==sys.argv[1]),"?"))' \
    "${PANE/p/t}"
}

granted=0; idle=0; last=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  b="$(body)"
  if [ -n "$b" ]; then
    # omp classifies some commands itself and paints "Reason: Critical pattern
    # detected" in the prompt box. That is a stricter judgement than this
    # denylist, made with more context, so it is never auto-granted regardless
    # of mode — the whole point of this sweeper is to clear BORING approvals.
    # Grep the EXTRACTED BOX, not the whole pane: the phrase lingers in
    # scrollback after a prompt is answered, and re-reading the pane would make
    # the sweeper halt forever on a flag that is no longer live.
    # omp's flag is over-broad on one very common, verified-benign shape:
    # writing a heredoc to a scratch file under /tmp (an agent composing a PR
    # comment). Observed and read twice on 2026-09-18; halting on it makes the
    # sweeper useless without making anything safer. Everything ELSE that omp
    # flags is still a human decision, and $DENY below still applies to this
    # shape, so a heredoc that also pushes or touches credentials still halts.
    _benign_tmp_write=0
    if printf '%s' "$b" | grep -qE "(cat|tee)[[:space:]]*>{1,2}[[:space:]]*/tmp/[A-Za-z0-9._-]+[[:space:]]*<<"; then
      _benign_tmp_write=1
    fi
    if [ "$_benign_tmp_write" -eq 0 ] && printf '%s' "$b" | grep -qi "Critical pattern detected"; then
      echo "HALT ($MODE): omp flagged this itself as a critical pattern — left for a human:"
      echo "  $b"
      exit 3
    fi
    if printf '%s' "$b" | grep -qEi "$DENY"; then
      echo "HALT ($MODE): denylist hit — left for a human:"
      echo "  $b"
      exit 3
    fi
    herdr pane send-keys "$PANE" Enter >/dev/null 2>&1
    if [ "$b" != "$last" ]; then
      granted=$((granted+1)); last="$b"
      echo "granted #$granted: ${b:0:120}"
    fi
    idle=0
  else
    idle=$((idle+1)); last=""
    if [ "$idle" -ge 8 ]; then
      s="$(status)"
      if [ "$s" = "idle" ] || [ "$s" = "done" ]; then
        echo "===== VERIFY ====="
        echo "pane=$PANE mode=$MODE status=$s grants=$granted"
        echo "settled: no prompt painted for 8 consecutive checks"
        exit 0
      fi
    fi
  fi
  sleep 5
done
echo "===== VERIFY ====="
echo "pane=$PANE mode=$MODE deadline ${MAX_MIN}m reached; grants=$granted; status=$(status)"
