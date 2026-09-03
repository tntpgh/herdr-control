#!/usr/bin/env bash
# The "higher watcher" docs/b2a-local-sentinel-design.md asks for.
#
# runtime/local_sentinel.py (thurber-os) is a deterministic, read-only, no-LLM
# health check that runs every 120s and writes ONE artifact: a local
# heartbeat.json. Its own docstring is emphatic — "The ONLY write is to the local
# heartbeat file ... never to KB or the network" — so nothing in Neon can ever
# attest to it, and the design says instead: "Written to a local heartbeat file;
# a higher watcher reads its age."
#
# That watcher never got built, so as of 2026-09-02 nothing read the file,
# is_alive() had zero callers, and the sentinel's launchd job was not even
# installed. It had been silent since 2026-07-20 and no signal existed anywhere.
#
# This is that watcher, and it lives here because CADENCE has to match: the
# heartbeat TTL is 5 minutes, so a nightly or 30-minute check would be
# meaningless. engineering-ledger-poll already runs every 5 minutes on the Mac.
#
# Reports a one-line status into the same OBSERVE stream as everything else:
#   sentinel: healthy age=42s
#   sentinel: DEGRADED age=31s failed=ledger_liveness,rating_usefulness
#   sentinel: STALE age=931s (ttl=300s) — the local eye is dead
#   sentinel: ABSENT (no heartbeat file) — never run, or not installed
HEARTBEAT_TTL_S=300   # runtime/local_sentinel.py HEARTBEAT_TTL (5 min)

sentinel_watch() {
    local hb="$HOME/Library/Application Support/thurber-os/local-sentinel/heartbeat.json"
    if [ ! -f "$hb" ]; then
        echo "sentinel: ABSENT (no heartbeat at $hb) — never run, or launchd job not installed"
        return 0
    fi
    python3 - "$hb" "$HEARTBEAT_TTL_S" <<'PY'
import json, sys
from datetime import datetime, timezone
path, ttl = sys.argv[1], int(sys.argv[2])
try:
    rec = json.load(open(path))
    created = rec["envelope"]["timestamps"]["created_at"]
    ts = datetime.fromisoformat(created)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
except Exception as e:
    # A malformed heartbeat is a DEAD sentinel, not a healthy one — say so rather
    # than swallowing it into an "ok".
    print(f"sentinel: UNREADABLE heartbeat ({type(e).__name__}) — treat as dead")
    raise SystemExit(0)
age = int((datetime.now(timezone.utc) - ts).total_seconds())
verdict = (rec.get("verdict") or {})
status = verdict.get("status", "unknown")
failed = ",".join(verdict.get("failed_signals") or []) or "none"
if age > ttl:
    print(f"sentinel: STALE age={age}s (ttl={ttl}s) — the local eye is dead")
elif status != "healthy":
    print(f"sentinel: DEGRADED age={age}s failed={failed}")
else:
    print(f"sentinel: healthy age={age}s")
PY
    return 0
}
