#!/usr/bin/env bash
# A minimal stand-in for "a real interpreter the floor check proves is
# below 3.11" — avoids depending on this machine's /usr/bin/python3, which
# is itself a thin Apple launcher whose reported version depends on the
# CALLER's PATH/toolchain resolution, not a fixed value — exactly the
# ambiguity verify-resolve-hub-python.sh exists to remove, so reusing it as
# a "known-bad" fixture would be circular. Only implements enough of the
# `python3 -c CODE` surface launchd/resolve-hub-python.sh's floor check
# actually invokes: always behaves as "below 3.11".
case "${1:-}" in
  -c) exit 1 ;;
  *) echo "Python 3.0.0 (fake, always reports below the floor)"; exit 0 ;;
esac
