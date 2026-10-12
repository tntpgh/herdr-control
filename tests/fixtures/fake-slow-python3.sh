#!/usr/bin/env bash
# A fake interpreter that LOOKS real to resolve-hub-python.sh's floor probe
# (`python3.N -c CODE`, must exit fast reporting >=3.11) but HANGS forever
# when actually invoked with real arguments — simulating a wedged
# prompt-occurrence.py (e.g. a stuck sqlite lock on the registry). Used by
# verify-occurrence-cold-cache.sh to prove runOccurrenceAsync's bounded
# subprocess lifetime actually kills a hung child instead of stalling the
# queue forever.
#
# Round 8 review (finding 3): the original version used `exec sleep 86400`,
# which REPLACES this process's own image rather than creating a real
# grandchild — a plain `child.kill()` on the direct PID would have killed
# it just fine, so it could never discriminate that from the process-GROUP
# kill the fix (finding 2) actually requires. This version backgrounds a
# REAL grandchild (`sleep`, inheriting this script's own stdout/stderr, the
# same pipe fds Node is reading) and then blocks on it with `wait`. A
# SIGKILL to just this script's own PID kills bash but leaves `sleep`
# running as an orphan STILL holding the pipe open, so Node's 'close' event
# would never fire — only a kill that reaches the whole process group (both
# this script and its backgrounded sleep, since neither calls setsid) lets
# 'close' fire at all. The deliberately distinctive duration below
# (864017s, not a value anything else on the system would plausibly use)
# doubles as a unique pgrep marker so the test can assert no orphan of
# this fixture survives a kill.
case "${1:-}" in
  -c) exit 0 ;;
  *)
    sleep 864017 &
    wait
    ;;
esac
