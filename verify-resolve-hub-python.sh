#!/usr/bin/env bash
# verify-resolve-hub-python.sh — the >=3.11 floor in launchd/resolve-hub-python.sh,
# bound to the commit (round 7 review, finding 3: this used to live only as an
# untracked .handoffs/ scratch script).
#
# At 42f7ea44, the resolver had no floor at all (any versioned python3.N).
# The first round 6 fix added a floor but checked only the FILENAME — a
# symlink NAMED python3.14 pointing at a real sub-3.11 interpreter still
# passed. The corrected fix actually runs each candidate
# (`sys.version_info >= (3, 11)`), highest-named first per directory, trying
# the next-highest-named candidate in the SAME directory before moving on if
# the real version check fails.
#
# old_py is a tiny FAKE interpreter (tests/fixtures/fake-old-python3.sh), not
# this machine's real /usr/bin/python3: that binary is a thin Apple launcher
# whose reported version depends on the CALLER's PATH/toolchain resolution
# (3.9.6 under a forced minimal PATH, 3.14.4 under a normal shell PATH) —
# exactly the ambiguity this script exists to remove, so it cannot also
# serve as a "known-bad, fixed-version" fixture. good_py is this machine's
# real pinned interpreter, confirmed >=3.11 below; the test self-skips if
# that is ever not true (e.g. a CI box with no Homebrew python3.11+).
#
#   bash verify-resolve-hub-python.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
skip() { printf '  skip  %s\n' "$1"; }

good_py="$(command -v python3.14 || command -v python3)"
old_py="$here/tests/fixtures/fake-old-python3.sh"

if ! "$good_py" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  skip "this machine's real pinned interpreter ($good_py) is not >=3.11 — nothing to prove the floor against"
  printf '\npassed=0 failed=0\nPASS (skipped, no fixtures available)\n'
  exit 0
fi
if [ ! -x "$old_py" ]; then
  skip "$old_py missing or not executable"
  printf '\npassed=0 failed=0\nPASS (skipped, no fixtures available)\n'
  exit 0
fi

only_low="$(mktemp -d)"
ln -s "$old_py" "$only_low/python3.9"

low_dir="$(mktemp -d)"; high_dir="$(mktemp -d)"
ln -s "$old_py" "$low_dir/python3.9"
ln -s "$good_py" "$high_dir/python3.14"

lying_dir="$(mktemp -d)"
ln -s "$old_py" "$lying_dir/python3.14"     # NAMED 3.14, REALLY sub-3.11 — must be refused
ln -s "$good_py" "$lying_dir/python3.11"    # NAMED 3.11, REALLY >=3.11 — the fallback must reach this

printf '== a search path whose only candidate is a REAL sub-3.11 interpreter must fail closed ==\n'
out="$(HERDR_HUB_PYTHON_DIRS="$only_low" bash "$here/launchd/resolve-hub-python.sh" 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && ok "refuses (rc=$rc), prints nothing on stdout" \
  || bad "expected refusal, got rc=$rc out=[$out]"

printf '== a search path whose first dir is a real sub-3.11 but a LATER dir has a real 3.11+ must keep scanning ==\n'
out="$(HERDR_HUB_PYTHON_DIRS="$low_dir:$high_dir" bash "$here/launchd/resolve-hub-python.sh" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$high_dir/python3.14" ] && ok "skips the real-sub-3.11 first dir and finds the real 3.11+ in the next dir" \
  || bad "expected $high_dir/python3.14, got rc=$rc out=[$out]"

printf '== a symlink NAMED python3.14 pointing at a REAL sub-3.11 interpreter must be refused, not trusted by name ==\n'
out="$(HERDR_HUB_PYTHON_DIRS="$lying_dir" bash "$here/launchd/resolve-hub-python.sh" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$lying_dir/python3.11" ] && ok "rejects the lying python3.14 symlink (real version <3.11) and falls back, in the SAME directory, to the genuinely-3.11+ python3.11 entry" \
  || bad "expected the lying python3.14 refused and python3.11 (real) returned instead; got rc=$rc out=[$out]"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
