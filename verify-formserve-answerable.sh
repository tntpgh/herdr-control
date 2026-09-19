#!/usr/bin/env bash
# verify-formserve-answerable.sh — formserve refuses to serve a decision that
# cannot record an answer.
#
# Why this exists: on 2026-09-17 THREE of the day's forms were served, listed
# `open` in the hub inbox, announced to Terrence, and could not be answered at
# all — one sat dead for 19 hours. Every one rendered perfectly, so the skill's
# own "verify it rendered" check passed; the Send button just silently did
# nothing. Rendering is not answerability, and only a served form that has been
# clicked proves the latter — so the check has to be static, at serve time.
#
# The three shapes below are the real ones, copied from the forms that failed:
#   no_handler      — nothing calls submitAnswers(); the browser does a native
#                     form post carrying no token, and nothing is recorded
#   orphan_button   — <button form="f"> with no <form id="f">: the control is
#                     associated with a form that does not exist, so clicking
#                     fires no event anywhere
#   cancels_itself  — <form onsubmit="return false"> with no handler
#
# Plus one positive control, because a guard that refuses everything is not a
# guard. Exit 0 = all four behaved.
set -uo pipefail

FORMSERVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/formserve.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/formserve-answerable.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
fails=0

cat > "$WORK/good.html" <<'HTML'
<html><body><form id="f">
<input type="radio" name="q1" value="a" required>
<button type="submit" form="f">Send answers</button></form>
<script>
document.getElementById("f").addEventListener("submit", function (e) {
  e.preventDefault();
  var fd = new FormData(e.target);
  window.submitAnswers({ q1: fd.get("q1") });
});
</script></body></html>
HTML

cat > "$WORK/no_handler.html" <<'HTML'
<html><body><form id="f"><button type="submit">Send answers</button></form></body></html>
HTML

cat > "$WORK/orphan_button.html" <<'HTML'
<html><body><form method="POST" action="/submit">
<button type="submit" form="f">Send answers</button></form>
<script>
document.querySelector("form").addEventListener("submit", function (e) {
  e.preventDefault(); window.submitAnswers({});
});
</script></body></html>
HTML

cat > "$WORK/cancels_itself.html" <<'HTML'
<html><body><form onsubmit="return false;">
<button type="submit">Send answers</button></form></body></html>
HTML

check() {  # <fixture> <expect: refuse|serve>
  local name=$1 expect=$2 out rc
  # --timeout 1 so the positive control serves, waits out one second with no
  # answer, and exits on its own; a refusal never reaches the serve path.
  out=$(python3 "$FORMSERVE" "$WORK/$name.html" --port 0 --no-open --timeout 1 2>&1)
  rc=$?
  if [ "$expect" = refuse ]; then
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "cannot record an answer"; then
      printf '  ok   %-16s refused (exit 2): %s\n' "$name" \
        "$(printf '%s' "$out" | sed -n 's/^  - //p' | head -1 | cut -c1-64)"
    else
      printf '  FAIL %-16s expected exit 2 + reason, got exit %s: %s\n' \
        "$name" "$rc" "$(printf '%s' "$out" | head -1)"
      fails=$((fails + 1))
    fi
  else
    # exit 1 = served, waited, nobody answered. Exit 2 would mean the guard
    # rejected a form that IS answerable, which is the worse failure.
    if [ "$rc" -eq 2 ]; then
      printf '  FAIL %-16s answerable form was REFUSED: %s\n' "$name" \
        "$(printf '%s' "$out" | head -2 | tail -1)"
      fails=$((fails + 1))
    else
      printf '  ok   %-16s served (exit %s)\n' "$name" "$rc"
    fi
  fi
}

echo "== formserve answerability preflight =="
check good           serve
check no_handler     refuse
check orphan_button  refuse
check cancels_itself refuse

if [ "$fails" -eq 0 ]; then
  echo "# all formserve answerability checks passed"
  exit 0
fi
echo "# $fails check(s) FAILED"
exit 1
