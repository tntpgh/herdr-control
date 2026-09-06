#!/usr/bin/env bash
# lib/pending-queue.sh — the ONE implementation of pending.jsonl's concurrency
# rules, shared by its three users:
#
#   herdr-notify.sh   APPENDS an alert when a worker starts waiting
#   herdr-select.sh   DROPS the alert that a Slack answer just carried
#   herdr-resolve.sh  DROPS alerts it has retracted, in a multi-second sweep
#
# Every one of them is a read-modify-write on the same file, and two independent
# review passes found real bugs in doing it three different ways:
#
#   * the sweep used to rewrite the file wholesale, erasing an alert appended
#     mid-sweep (an armed Slack message with no record, un-retractable) and
#     resurrecting one that had just been answered (so the next sweep deleted
#     the message carrying the operator's own decision)
#   * herdr-select skipping its drop when the sweep held the lock was NOT safe:
#     pressing Enter unblocks the worker, whose own PostToolUse hook starts a
#     sweep microseconds later, so the collision is CAUSED by the keypress. The
#     "retract it later" fallback is exactly the outcome that must never happen
#     for a Slack-answered alert
#   * `cat "$tmp" > "$file"` truncates in place, so a reader can see a torn
#     line; one malformed line makes every later jq fail and pins the queue
#
# So: acquire with a bounded wait (never a one-shot skip), reclaim a stale lock
# (a SIGKILL at the hook timeout must not disable retraction forever), and only
# ever replace the file by atomic rename.

# Seconds a caller waits for the lock before giving up. The keypress/alert has
# already landed by the time any of these run, so waiting is cheap and losing
# the race is not.
: "${PENDING_LOCK_WAIT_S:=5}"
# A lock older than this is assumed to belong to a process that died without
# releasing it. The sweep is bounded to a few deletes, so a minute is far past
# any legitimate hold.
: "${PENDING_LOCK_STALE_S:=60}"

_pending_lock_age_s() {                # <lockdir> -> age in seconds, or empty
  local d="$1" mtime now
  mtime=$(stat -f %m "$d" 2>/dev/null) || mtime=$(stat -c %Y "$d" 2>/dev/null) || return 1
  now=$(date +%s)
  printf '%s' "$(( now - mtime ))"
}

pending_lock() {                       # <lockdir> -> 0 acquired, 1 gave up
  local lockdir="$1" waited=0 age
  while :; do
    mkdir "$lockdir" 2>/dev/null && return 0
    age=$(_pending_lock_age_s "$lockdir" 2>/dev/null || true)
    if [ -n "$age" ] && [ "$age" -gt "$PENDING_LOCK_STALE_S" ]; then
      # Stale: the holder died (SIGKILL at a hook timeout leaves no trap to
      # run). Reclaim rather than let retraction stop forever.
      rmdir "$lockdir" 2>/dev/null
      continue
    fi
    # Integer-only arithmetic: 10 ticks of 0.1s per second of budget.
    [ "$waited" -ge $(( PENDING_LOCK_WAIT_S * 10 )) ] && return 1
    sleep 0.1
    waited=$(( waited + 1 ))
  done
}

pending_unlock() { rmdir "$1" 2>/dev/null || true; }

# Replace the queue with stdin, atomically. mv is a rename within the same
# directory, so a concurrent reader sees either the old file or the new one and
# never a partial write.
pending_replace() {                    # <file> < new-contents
  local file="$1" tmp
  tmp="$file.$$.tmp"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

pending_drop() {                       # <file> <jq-filter-arg-name> <value>
  # Drop every entry whose <arg> equals <value>, under whatever lock the caller
  # already holds. jq failure must never truncate the queue: a lost entry is a
  # question that can never be retracted, so only a successful filter is kept.
  local file="$1" arg="$2" val="$3" tmp
  [ -s "$file" ] || return 0
  tmp="$file.$$.drop"
  if jq -c --arg v "$val" "select(.$arg != \$v)" < "$file" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}
