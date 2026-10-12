#!/usr/bin/env bash
# A fake interpreter that LOOKS real to resolve-hub-python.sh's floor probe
# (`python3.N -c CODE`, must exit fast reporting >=3.11) but HANGS forever
# when actually invoked with real arguments — simulating a wedged
# prompt-occurrence.py (e.g. a stuck sqlite lock on the registry). Used by
# verify-occurrence-cold-cache.sh to prove runOccurrenceAsync's bounded
# subprocess lifetime actually kills a hung child instead of stalling the
# flush queue forever.
case "${1:-}" in
  -c) exit 0 ;;
  *) exec sleep 86400 ;;
esac
