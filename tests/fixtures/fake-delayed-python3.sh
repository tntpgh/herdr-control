#!/usr/bin/env bash
# Passes resolve-hub-python.sh's floor probe (`-c CODE`) instantly, same as
# the other fake interpreters here. For a REAL invocation, delegates to a
# genuine python3 so the write actually lands in the database — but when
# one of the forwarded arguments is the literal marker "overtaketest1", it
# sleeps first. Used by verify-occurrence-cold-cache.sh (round 8, finding
# 4) to widen the race window between "hubPythonCache becomes warm" and
# "the occurrence that triggered the resolve has actually finished
# persisting" — exactly the window a later, unrelated occurrence must not
# be able to overtake.
case "${1:-}" in
  -c) exit 0 ;;
  *)
    for a in "$@"; do
      if [ "$a" = "overtaketest1" ]; then
        sleep 1
        break
      fi
    done
    exec python3 "$@"
    ;;
esac
