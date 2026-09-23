#!/usr/bin/env bash
# verify-typing-guard.sh — proof that send-to-agent.sh refuses to inject text
# into a composer a human is actively typing into RIGHT NOW, rather than
# racing them and interleaving both writers' text into one garbled line.
#
# Runs the REAL send-to-agent.sh and the REAL composer_looks_actively_typed
# (lib/prompt-parse.sh) against a stubbed herdr. Unlike verify-send-to-agent.sh
# (which keys its fixture screens off how many ENTERS have landed, to test
# post-injection submit confirmation), this suite keys off how many READS have
# happened, because the guard under test runs BEFORE any text is typed and
# BEFORE any Enter is pressed — there is nothing else to key off of.
#
#   bash verify-typing-guard.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SCREEN_DIR="$WORK/screens"
export READ_COUNTER="$WORK/read-count"
export KEYS="$WORK/keys.log"
export SENDTEXT="$WORK/send-text.log"
mkdir -p "$SCREEN_DIR"

PANE="w1:p1"
export PANE

# ---- the stub ---------------------------------------------------------------
# "pane read" replies with $SCREEN_DIR/<n>, where <n> is the READ number
# (1-indexed) of just the reads that matter to the guard under test —
# falling back to $SCREEN_DIR/last once a scenario's fixtures run out, so a
# steady-state tail does not need one file per read.
#
# Keyed on the `--lines` value (`$7`), not on call order: looks_like_
# permission_prompt reads with --lines 30 BEFORE the typing guard ever runs,
# and composer_stable_snapshot (both the guard and the post-injection submit
# loop) reads with --lines 12. Counting every read regardless of caller would
# make the permission check's own read silently consume index 1 of every
# scenario, shifting every fixture by one and making the arithmetic below
# impossible to get right by inspection. This way the permission check
# always sees one fixed, safe screen, and the counter tracks only the reads
# the guard itself is making.
herdr() {
  case "$1 $2" in
    "pane read")
      if [ "${7:-}" = "30" ]; then
        cat "$SCREEN_DIR/not-a-prompt" 2>/dev/null
        return 0
      fi
      local idx f
      idx=$(cat "$READ_COUNTER" 2>/dev/null); idx="${idx:-0}"
      idx=$((idx + 1))
      echo "$idx" >"$READ_COUNTER"
      f="$SCREEN_DIR/$idx"
      [ -f "$f" ] || f="$SCREEN_DIR/last"
      cat "$f" 2>/dev/null
      ;;
    "pane send-text")
      printf '%s\n' "$4" >>"$SENDTEXT"
      ;;
    "pane send-keys")
      printf '%s\n' "$4" >>"$KEYS"
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

reset_state() {
  rm -rf "$SCREEN_DIR"; mkdir -p "$SCREEN_DIR"
  echo 0 >"$READ_COUNTER"; : >"$KEYS"; : >"$SENDTEXT"
  # Consumed by looks_like_permission_prompt's own --lines 30 read, which
  # runs before the typing guard on every call that isn't --force. Ordinary
  # ready-prompt shape — matches none of send-to-agent.sh's prompt regexes,
  # so the permission check reports "no prompt" and control reaches the
  # typing guard, which is what every scenario here actually wants to test.
  printf '  Ready\n\xe2\x9d\xaf\n' >"$SCREEN_DIR/not-a-prompt"
}
screen() { cat >"$SCREEN_DIR/$1"; }
last_as() { cp "$SCREEN_DIR/$1" "$SCREEN_DIR/last"; }
send() { ( bash "$here/send-to-agent.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }

printf '== idle composer: two identical pre-injection reads -> proceeds, types normally ==\n'
reset_state
screen 1 <<'EOF'
  Ready
❯
EOF
last_as 1
send "a normal message"; rc=$?
[ "$rc" -ne 6 ] && ok "not refused as typing (rc=$rc)" || bad "wrongly refused an idle composer"
[ -s "$SENDTEXT" ] && ok "text was typed" || bad "text never typed on an idle composer"

printf '\n== actively typing: composer keeps changing across all 3 checks -> REFUSED, nothing typed ==\n'
reset_state
screen 1 <<'EOF'
❯ hel
EOF
screen 2 <<'EOF'
❯ hell
EOF
screen 3 <<'EOF'
❯ hello
EOF
screen 4 <<'EOF'
❯ hello t
EOF
screen 5 <<'EOF'
❯ hello th
EOF
screen 6 <<'EOF'
❯ hello the
EOF
last_as 6
send "an injected message"; rc=$?
[ "$rc" -eq 6 ] && ok "exit 6 REFUSED" || bad "exit $rc (expected 6): $(cat "$WORK/out.txt") / $(cat "$WORK/err.txt")"
[ ! -s "$SENDTEXT" ] && ok "text NEVER typed — no interleaving with the live human" || bad "typed anyway: $(cat "$SENDTEXT")"
grep -qi "typing right now" "$WORK/err.txt" && ok "refusal names what it saw" || bad "stderr: $(cat "$WORK/err.txt")"

printf '\n== typing that STOPS mid-check: settles by the 2nd pair -> proceeds ==\n'
reset_state
screen 1 <<'EOF'
❯ hel
EOF
screen 2 <<'EOF'
❯ hello
EOF
screen 3 <<'EOF'
❯ hello
EOF
last_as 3
send "a message after they paused"; rc=$?
[ "$rc" -ne 6 ] && ok "not refused once typing settled (rc=$rc)" || bad "refused despite settling"
[ -s "$SENDTEXT" ] && ok "text was typed once the composer went quiet" || bad "text never typed"

# Regression, 2026-09-23: the guard compared the whole bottom-of-pane window,
# so a WORKING omp conductor — output streaming, spinner/elapsed/cost ticking in
# the composer's own top border — read as "typing" on every check, and every
# push wake into it was refused with exit 6. Shape copied from a live omp pane:
# `╭── <status> ──╮` border, then the input on the `╰─` row.
# A live busy pane changes on EVERY read, so every one of the guard's six reads
# gets a distinct screen — a fixture that settles after two would let the old
# whole-window compare pass on its second pair and prove nothing.
printf '\n== busy omp agent, EMPTY composer: output + status border churn on every read -> proceeds ==\n'
reset_state
spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴)
for i in 1 2 3 4 5 6; do
  screen "$i" <<EOF
│ $ git show --stat 68d8edc | head -50                                │
├─── Output ──────────────────────────────────────────────────────────┤
│  streamed output line $i                                            │

 • Background job completed [bash] bg_$i (11.5s)
╭── ${spin[$((i - 1))]} 13m  Opus 5.5  ~/Code/tntpgh-dev  main ?$i  14.4$i ───42%───╮
╰─                                                                ─╯
EOF
done
last_as 6
send "[HERDR-PEER-SIGNAL] worker w1H:p2 needs input"; rc=$?
[ "$rc" -ne 6 ] && ok "busy agent is not mistaken for a typing human (rc=$rc)" || bad "refused a busy agent's empty composer as typing"
[ -s "$SENDTEXT" ] && ok "wake text was typed" || bad "wake never typed into a busy agent"

printf '\n== busy omp agent AND a human typing on the ╰─ row -> still REFUSED ==\n'
reset_state
i=0
for typed in 'hel' 'hell' 'hello' 'hello t' 'hello th' 'hello the'; do
  i=$((i + 1))
  screen "$i" <<EOF
│ streamed output line $i                                             │
╭── ⠙ 13m  Opus 5.5  ~/Code/tntpgh-dev  main ?2  14.$i ───42%───╮
╰─ $typed
EOF
done
last_as 6
send "[HERDR-PEER-SIGNAL] worker w1H:p2 needs input"; rc=$?
[ "$rc" -eq 6 ] && ok "exit 6 REFUSED — the input row itself changed" || bad "exit $rc (expected 6): $(cat "$WORK/err.txt")"
[ ! -s "$SENDTEXT" ] && ok "nothing interleaved into the human's input" || bad "typed anyway: $(cat "$SENDTEXT")"

printf '\n== --force bypasses the typing guard on purpose ==\n'
reset_state
screen 1 <<'EOF'
❯ hel
EOF
screen 2 <<'EOF'
❯ hell
EOF
screen 3 <<'EOF'
❯ hello
EOF
last_as 3
send --force "sent despite active typing"; rc=$?
[ "$rc" -ne 6 ] && ok "--force is not refused as typing (rc=$rc)" || bad "--force still refused"
[ -s "$SENDTEXT" ] && ok "--force types anyway, as documented" || bad "--force did not type"

printf '\n== --submit-only never runs the typing guard (nothing NEW is being typed) ==\n'
reset_state
screen 1 <<'EOF'
❯ operator typed this
EOF
screen 2 <<'EOF'
❯ operator typed this
EOF
last_as 2
send --submit-only; rc=$?
[ "$rc" -ne 6 ] && ok "--submit-only is never refused as typing (rc=$rc)" || bad "--submit-only wrongly refused"
[ ! -s "$SENDTEXT" ] && ok "--submit-only still types nothing (unchanged behaviour)" || bad "send-text called under --submit-only"

printf '\n== a permission prompt still refuses FIRST, before the typing check ever runs ==\n'
reset_state
cat >"$SCREEN_DIR/not-a-prompt" <<'EOF'
 Do you want to proceed?
❯ 1. Yes
  2. No
EOF
send "some message"; rc=$?
[ "$rc" -eq 5 ] && ok "exit 5 REFUSED (permission prompt), not 6" || bad "exit $rc (expected 5): $(cat "$WORK/out.txt")"
[ ! -s "$SENDTEXT" ] && ok "text never typed into a live prompt" || bad "typed into a prompt"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
