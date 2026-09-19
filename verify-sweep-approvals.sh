#!/usr/bin/env bash
# verify-sweep-approvals.sh — the sweep removes TYPING, never authority.
#
# The guard that denies `herdr pane send-keys <pane> ENTER` made the compliant
# path cost four manual steps per pane, and an expensive safe path is one people
# route around. This script exists to make it cheap. What it must never do is
# become a second, softer way to answer a prompt — so these rows pin the
# boundary: every answer goes through herdr-select.sh with a prompt id, nothing
# unparseable is answered, nothing the classifier declines is answered, no
# option that widens future posture is chosen, and no key is ever sent directly.
#
#   bash verify-sweep-approvals.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SWEEP="$here/sweep-approvals.sh"
pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# ── a stub herdr: two panes, one prompting, one a shell ────────────────────
cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
case "${2:-}" in
  list) printf '{"panes":[{"pane_id":"wX:p1","label":"review:pr1"},{"pane_id":"wX:p2","label":"shell"}]}\n' ;;
  read)
    case "${3:-}" in
      wX:p1) cat "${FAKE_PROMPTING:?}" ;;
      wX:p2) cat "${FAKE_SHELL:?}" ;;
      *) exit 1 ;;
    esac ;;
  send-keys|send-text)
    # A direct keypress from this script would be the whole point missed.
    printf '%s\n' "SENT-KEYS $*" >> "$WORK/calls"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/herdr"

# A stub herdr-select that records what it was asked to do, and can emulate its
# real refusals — including exit 8, the clipped-approval refusal measured live.
cat > "$WORK/bin/select" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "SELECT $*" >> "$WORK/calls"
[ -n "${SELECT_CLIPPED:-}" ] && { echo "herdr-select: approval arguments are clipped" >&2; exit 8; }
[ -n "${SELECT_REFUSE:-}" ] && { echo "herdr-select: the prompt in that pane no longer matches" >&2; exit 6; }
exit 0
STUB
chmod +x "$WORK/bin/select"

# EXACTLY the two-option shape, because that is the only one the menu parser
# enumerates: measured, both of its passes require the literal labels
# "Approve" then "Deny" (prompt-parse.sh:619,621,657). A third option row, a
# missing Deny, or a reversed order is visible-but-unparseable, and any other
# affirmative label ("Yes", "Allow once", "Approve (always)") is not visible at
# all. The first version of this fixture had three rows and therefore tested
# the unparseable path while claiming to test answering.
cat > "$WORK/prompting.txt" <<'SCREEN'
  I need to run the test suite for the fix.
╭─ Allow tool: bash ───────────────────────────────────────────╮
│                                                              │
│ Command: git status --short && git log --oneline -5          │
│                                                              │
│  ❯ Approve                                                   │
│    Deny                                                      │
│                                                              │
│ up/down navigate  enter select  esc cancel                   │
╰──────────────────────────────────────────────────────────────╯
SCREEN
cat > "$WORK/shell.txt" <<'SCREEN'
~/Code/herdr-control took 2m11s
~/Code/herdr-control
❯
SCREEN
# A real panel whose options the parser will not enumerate (mid-paint).
# Visible but NOT enumerable: a panel whose Deny row has not painted yet.
cat > "$WORK/midpaint.txt" <<'SCREEN'
  Applying the migration.
╭─ Allow tool: bash ───────────────────────────────────────────╮
│                                                              │
│ Command: psql -f drop_and_recreate.sql                       │
│                                                              │
│  ❯ Approve                                                   │
│                                                              │
│ up/down navigate  enter select  esc cancel                   │
╰──────────────────────────────────────────────────────────────╯
SCREEN
# A prompt whose command the classifier will NOT wave through.
cat > "$WORK/dangerous.txt" <<'SCREEN'
  Cleaning up the release.
╭─ Allow tool: bash ───────────────────────────────────────────╮
│                                                              │
│ Command: git push --force origin main                        │
│                                                              │
│  ❯ Approve                                                   │
│    Deny                                                      │
│                                                              │
│ up/down navigate  enter select  esc cancel                   │
╰──────────────────────────────────────────────────────────────╯
SCREEN

run() {                                   # <prompting-fixture> [args...] -> $OUT, $RC
  local f="$1"; shift
  OUT="$(cd "$here" && WORK="$WORK" \
    HERDR_EXTRA_PATH="$WORK/bin" PATH="$WORK/bin:$PATH" \
    HERDR_BIN="$WORK/bin/herdr" HERDR_SELECT="$WORK/bin/select" \
    FAKE_PROMPTING="$WORK/$f" FAKE_SHELL="$WORK/shell.txt" \
    bash "$SWEEP" "$@" 2>&1)"; RC=$?
}
calls() { cat "$WORK/calls" 2>/dev/null; }
reset() { : > "$WORK/calls"; }

printf '== the survey ==\n'
reset; run prompting.txt
case "$OUT" in
  *wX:p1*) ok "a prompting pane is listed" ;;
  *) bad "survey" "prompting pane missing: $OUT" ;;
esac
case "$OUT" in
  *wX:p2*) bad "survey" "listed a pane that is not asking anything" ;;
  *) ok "and a pane that is not asking is not listed" ;;
esac
case "$OUT" in
  *"policy: allow"*) ok "with the classifier's verdict for the command behind it" ;;
  *) bad "survey" "no verdict shown: $OUT" ;;
esac
[ -z "$(calls)" ] \
  && ok "and the default survey answers NOTHING" \
  || bad "survey" "it acted: $(calls)"

printf '== answering, only through herdr-select ==\n'
reset; run prompting.txt --answer
case "$(calls)" in
  *"SELECT wX:p1 1 --expect-prompt-id "*) ok "answers via herdr-select, with an option number and a prompt id" ;;
  *) bad "answer" "wrong call: $(calls)" ;;
esac
case "$(calls)" in
  *SENT-KEYS*) bad "answer" "it sent a raw key itself" ;;
  *) ok "and never sends a key itself" ;;
esac
# The option rule, driven DIRECTLY: a three-option panel cannot reach it,
# because the menu parser does not enumerate one (see the fixture note), so
# testing this only end-to-end would have left it untested.
# shellcheck source=/dev/null
. "$SWEEP"
_opt() { narrow_affirmative "$(printf '%b' "$1")" 2>/dev/null || printf 'none'; }
[ "$(_opt '1\tApprove\n2\tDeny')" = 1 ] \
  && ok "narrow_affirmative picks a plain Approve" \
  || bad "option rule" "plain Approve -> $(_opt '1\tApprove\n2\tDeny')"
# Operational for THIS command, but a decision about every LATER prompt, which
# is not a peer's to make.
[ "$(_opt "1\tApprove and don't ask again\n2\tDeny")" = none ] \
  && ok "and refuses an affirmative that also changes future prompts" \
  || bad "option rule" "took the widening option"
[ "$(_opt '1\tYes, and remember this decision for the rest of the session\n2\tNo')" = none ] \
  && ok "including the remember-for-the-session wording" \
  || bad "option rule" "took a session-wide option"
[ "$(_opt '1\tApprove\n2\tApprove and always allow\n3\tDeny')" = 1 ] \
  && ok "and prefers the narrow one when both are offered" \
  || bad "option rule" "did not prefer the narrow affirmative"
[ "$(_opt '1\tDeny\n2\tCancel')" = none ] \
  && ok "and finds nothing to press when there is no affirmative at all" \
  || bad "option rule" "invented an affirmative"

# An answer with no prompt id would be an answer nothing binds to — the exact
# TOCTOU window --expect-prompt-id exists to close. Driven by overriding
# prompt_id after sourcing, because no fixture can make the real one empty.
( # subshell: the override must not leak into later rows
  . "$SWEEP"
  prompt_id() { printf ''; }
  export HERDR_BIN="$WORK/bin/herdr" HERDR_SELECT="$WORK/bin/select"
  export FAKE_PROMPTING="$WORK/prompting.txt" FAKE_SHELL="$WORK/shell.txt" WORK="$WORK"
  export PATH="$WORK/bin:$PATH" HERDR_EXTRA_PATH="$WORK/bin"
  MODE=answer
  : > "$WORK/calls"
  out="$(sweep_main 2>&1)"
  case "$out" in
    *"HELD: no prompt id"*) printf '  ok    an answer with no prompt id is held, never sent unbound\n' ;;
    *) printf '  FAIL  no-prompt-id: %s\n' "$(printf '%s' "$out" | tail -2)" ;;
  esac
  [ -s "$WORK/calls" ] && printf '  FAIL  no-prompt-id: it called herdr-select anyway\n' || true
) | tee "$WORK/subrows"
grep -q '^  ok' "$WORK/subrows" && pass=$((pass+1)) || fail=$((fail+1))
grep -q '^  FAIL' "$WORK/subrows" && fail=$((fail+1)) || true

printf '== what it refuses to answer ==\n'
reset; run dangerous.txt --answer
case "$OUT" in
  *"HELD: policy says"*) ok "a command the classifier declines is held for a human" ;;
  *) bad "hold" "answered or misreported: $OUT" ;;
esac
[ -z "$(calls)" ] \
  && ok "and herdr-select is not even called for it" \
  || bad "hold" "called anyway: $(calls)"

reset; run midpaint.txt --answer
case "$OUT" in
  *"NOT PARSEABLE"*) ok "a panel whose options cannot be parsed is reported" ;;
  *) bad "unparseable" "$OUT" ;;
esac
case "$OUT" in
  *"HELD: a prompt that cannot be parsed"*) ok "and held, never answered — it is the most dangerous one" ;;
  *) bad "unparseable" "not held: $OUT" ;;
esac
[ -z "$(calls)" ] || bad "unparseable" "acted on it: $(calls)"

printf '== herdr-select refusals are results, not errors ==\n'
# Measured live on 2026-09-18: a command that did not fit the approval box.
# Nobody, human or peer, can see all of what they would approve.
reset; OUT="$(cd "$here" && WORK="$WORK" HERDR_EXTRA_PATH="$WORK/bin" PATH="$WORK/bin:$PATH" \
  HERDR_BIN="$WORK/bin/herdr" HERDR_SELECT="$WORK/bin/select" SELECT_CLIPPED=1 \
  FAKE_PROMPTING="$WORK/prompting.txt" FAKE_SHELL="$WORK/shell.txt" bash "$SWEEP" --answer 2>&1)"
case "$OUT" in
  *"NEEDS THE WORKER"*"clipped"*) ok "a clipped approval says the WORKER has to re-issue it smaller" ;;
  *) bad "clipped" "$OUT" ;;
esac
case "$OUT" in
  *send-to-agent.sh*) ok "and names the tool for telling it so" ;;
  *) bad "clipped" "no actionable next step: $OUT" ;;
esac
reset; OUT="$(cd "$here" && WORK="$WORK" HERDR_EXTRA_PATH="$WORK/bin" PATH="$WORK/bin:$PATH" \
  HERDR_BIN="$WORK/bin/herdr" HERDR_SELECT="$WORK/bin/select" SELECT_REFUSE=1 \
  FAKE_PROMPTING="$WORK/prompting.txt" FAKE_SHELL="$WORK/shell.txt" bash "$SWEEP" --answer 2>&1)"
case "$OUT" in
  *"herdr-select refused (exit 6)"*) ok "any other refusal is surfaced with its exit code" ;;
  *) bad "refusal" "swallowed: $OUT" ;;
esac

printf '== the survey is machine-readable too ==\n'
reset; run prompting.txt --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and d[0]["pane"]=="wX:p1" and d[0]["verdict"]=="allow" and d[0]["parseable"]==1' 2>/dev/null \
  && ok "--json emits one object per prompting pane, with verdict and parseability" \
  || bad "json" "not parseable or wrong shape: $(printf '%s' "$OUT" | head -c 200)"
[ -z "$(calls)" ] || bad "json" "the json survey acted: $(calls)"

printf '== nothing asking ==\n'
reset; run shell.txt
case "$OUT" in
  *"No pane is asking anything"*) ok "says so plainly when no pane is prompting" ;;
  *) bad "empty" "$OUT" ;;
esac

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
