#!/usr/bin/env bash
# verify-formserve-title-consistency.sh — formserve refuses a form whose
# recorded title does not match its visible heading.
#
# Why this exists: incident 2026-10-30, two hook-mode forms were built by
# copying another form's <head>. The hub recorded their title as "Forward
# Flow first text message wording", while the page's own <h2> said "Let
# workers run without me approving every step?" — the hub list mislabeled a
# live approval form. Static at serve time, same reasoning as
# verify-formserve-answerable.sh: a form that renders correctly can still be
# mislabeled, and only a title check at serve time catches it before the
# human sees the wrong label in the inbox.
#
# Entirely sandboxed: HERDR_STATE_ROOT points at a scratch dir for every run,
# never the live ~/.local/state/herdr/forms. Nothing here touches, restarts
# or rewrites an existing served form.
set -uo pipefail

FORMSERVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/formserve.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/formserve-title.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HERDR_STATE_ROOT="$WORK/state"
FORMS_DIR="$HERDR_STATE_ROOT/forms"
fails=0

form_body() {  # <heading-tag> <heading-text> <title-tag-or-empty>
  local tag=$1 heading=$2 title=$3
  {
    echo "<html><head>"
    [ -n "$title" ] && echo "<title>$title</title>"
    echo "</head><body>"
    echo "<$tag>$heading</$tag>"
    cat <<'HTML'
<form id="f">
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
  } > "$WORK/$4.html"
}

form_body h2 "Let workers run without me approving every step?" \
  "Forward Flow first text message wording" mismatch
form_body h2 "Approve this?" "Approve this?" match
form_body h2 "Should I deploy now?" "" heading_only

ok() { printf '  ok   %s\n' "$1"; }
not_ok() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo "== formserve title-consistency preflight =="

# 1. mismatched <title> vs <h2>: refused, nothing registered.
out=$(python3 "$FORMSERVE" "$WORK/mismatch.html" --port 0 --no-open --timeout 1 2>&1)
rc=$?
if [ "$rc" -eq 2 ] \
  && printf '%s' "$out" | grep -q "Forward Flow first text message wording" \
  && printf '%s' "$out" | grep -q "Let workers run without me approving every step?" \
  && printf '%s' "$out" | grep -q -- "--title"; then
  ok "mismatched <title>/<h2> refused (exit 2), both strings named"
else
  not_ok "mismatched <title>/<h2>: expected exit 2 + both strings, got exit $rc: $(printf '%s' "$out" | head -3)"
fi
if [ -z "$(ls -A "$FORMS_DIR" 2>/dev/null)" ]; then
  ok "mismatch refusal registered nothing"
else
  not_ok "mismatch refusal left state behind: $(ls "$FORMS_DIR")"
fi

# 2. matching <title>/<h2>: serves, state records that title.
rm -rf "$FORMS_DIR"; mkdir -p "$FORMS_DIR"
out=$(python3 "$FORMSERVE" "$WORK/match.html" --port 0 --no-open --timeout 1 \
  --request-id req-match-1 2>&1)
rc=$?
rec="$(ls "$FORMS_DIR"/*.json 2>/dev/null | head -1)"
port="$(printf '%s' "$out" | grep -o '127\.0\.0\.1:[0-9]*' | head -1 | cut -d: -f2)"
if [ "$rc" -ne 2 ] && [ -n "$rec" ] && [ "$(jq -r .title "$rec")" = "Approve this?" ]; then
  ok "matching <title>/<h2> served with title 'Approve this?'"
else
  not_ok "matching <title>/<h2>: rc=$rc rec=$rec title=$(jq -r .title "$rec" 2>/dev/null)"
fi
if [ -n "$rec" ] && [ -n "$port" ] \
  && [ "$(jq -r .request_id "$rec")" = "req-match-1" ] \
  && [ "$(jq -r .port "$rec")" = "$port" ]; then
  ok "state request_id and port match the served page ($port)"
else
  not_ok "state request_id/port mismatch: rec=$(jq -c '{request_id,port}' "$rec" 2>/dev/null) served_port=$port"
fi

# 3. heading only, no <title> tag at all: serves, state uses the heading.
rm -rf "$FORMS_DIR"; mkdir -p "$FORMS_DIR"
python3 "$FORMSERVE" "$WORK/heading_only.html" --port 0 --no-open --timeout 1 >/dev/null 2>&1
rec="$(ls "$FORMS_DIR"/*.json 2>/dev/null | head -1)"
if [ -n "$rec" ] && [ "$(jq -r .title "$rec")" = "Should I deploy now?" ]; then
  ok "heading-only page uses the heading as the title"
else
  not_ok "heading-only page: title=$(jq -r .title "$rec" 2>/dev/null)"
fi

# 4. --title overrides a mismatch explicitly instead of refusing.
rm -rf "$FORMS_DIR"; mkdir -p "$FORMS_DIR"
out=$(python3 "$FORMSERVE" "$WORK/mismatch.html" --port 0 --no-open --timeout 1 \
  --title "Explicit override title" 2>&1)
rc=$?
rec="$(ls "$FORMS_DIR"/*.json 2>/dev/null | head -1)"
if [ "$rc" -ne 2 ] && [ -n "$rec" ] && [ "$(jq -r .title "$rec")" = "Explicit override title" ]; then
  ok "--title overrides a mismatch and serves with the given title"
else
  not_ok "--title override: rc=$rc title=$(jq -r .title "$rec" 2>/dev/null)"
fi

# 5. a file under $HERDR_STATE_ROOT/runs/action-forms/ is herdr-action's own
#    claim-once form; formserve must refuse to hand-serve a copy of it (a
#    hand-served copy collected a human answer herdr-action then correctly
#    rejected as unbound to any request).
action_forms_dir="$HERDR_STATE_ROOT/runs/action-forms"
mkdir -p "$action_forms_dir"
cp "$WORK/match.html" "$action_forms_dir/req-55512-1.html"
rm -rf "$FORMS_DIR"; mkdir -p "$FORMS_DIR"
out=$(python3 "$FORMSERVE" "$action_forms_dir/req-55512-1.html" --port 0 --no-open --timeout 1 2>&1)
rc=$?
if [ "$rc" -eq 2 ] \
  && printf '%s' "$out" | grep -q "herdr-action serves this form itself" \
  && printf '%s' "$out" | grep -q "herdr-action.sh show req-55512 for its id"; then
  ok "a form under runs/action-forms/ is refused (exit 2), names req-55512"
else
  not_ok "runs/action-forms/ form: expected exit 2 + id in message, got exit $rc: $(printf '%s' "$out" | head -2)"
fi
if [ -z "$(ls -A "$FORMS_DIR" 2>/dev/null)" ]; then
  ok "action-forms refusal registered nothing"
else
  not_ok "action-forms refusal left state behind: $(ls "$FORMS_DIR")"
fi

# 6. positive control: the identical bytes served from OUTSIDE action-forms/
#    still serve fine — the guard is path-scoped, not a blanket content block.
rm -rf "$FORMS_DIR"; mkdir -p "$FORMS_DIR"
out=$(python3 "$FORMSERVE" "$WORK/match.html" --port 0 --no-open --timeout 1 2>&1)
rc=$?
if [ "$rc" -ne 2 ]; then
  ok "the same bytes served from outside action-forms/ are not refused"
else
  not_ok "false-positive: identical content outside action-forms/ was refused: $(printf '%s' "$out" | head -2)"
fi

if [ "$fails" -eq 0 ]; then
  echo "# all checks passed"
  exit 0
fi
echo "# $fails check(s) FAILED"
exit 1
