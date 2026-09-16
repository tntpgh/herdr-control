#!/usr/bin/env bash
# verify-raw-answer-guard.sh — the side door that let an agent answer four
# review panes with a blind Enter on 2026-09-16 stays shut.
#
# The guard decides from TWO things: what the command would do, and whether the
# target pane is asking something right now. Both halves are faked here — a
# stub `herdr` on PATH serves a canned screen — so the rows are deterministic
# and do not need a live pane that happens to be blocked.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
GUARD="$here/guard-raw-prompt-answer.sh"
pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stub herdr whose `pane read` prints whatever screen the test selected. The
# guard shells out to the real prompt-parse.sh, so the screens have to be real
# shapes: an omp approval panel, and a plain shell prompt.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
# args: pane read <pane> ...
case "${2:-}" in
  read) cat "${HERDR_FAKE_SCREEN:?}" ;;
  list) printf '{"result":{"panes":[]}}\n' ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/herdr"

cat > "$WORK/prompting.txt" <<'SCREEN'
  I need to run the test suite to check the fix.
╭─ Allow tool: bash ───────────────────────────────────────────╮
│                                                              │
│ Command: git push --force origin main                        │
│                                                              │
│  ❯ Approve                                                   │
│    Deny                                                      │
│                                                              │
│ up/down navigate  enter select  esc cancel                   │
│                                                              │
╰──────────────────────────────────────────────────────────────╯
SCREEN
cat > "$WORK/shell.txt" <<'SCREEN'
~/Code/herdr-control took 2m11s
~/Code/herdr-control
❯
SCREEN

g() {                                   # <screen> <command> -> rc, out in $OUT
  # HERDR_EXTRA_PATH, not just PATH: config.sh PREPENDS it, so a stub that is
  # only on PATH loses to the real binary and every row here would pass or fail
  # against whatever the live panes happen to be showing. (That is exactly what
  # happened while writing this: 16 rows "failed" because the stub was never
  # consulted.)
  OUT="$(HERDR_EXTRA_PATH="$WORK/bin" PATH="$WORK/bin:$PATH" \
         HERDR_FAKE_SCREEN="$WORK/$1.txt" \
         HERDR_SANCTIONED_ANSWER= bash "$GUARD" "$2" 2>&1)"
  return $?
}
want_deny() {                           # <screen> <command> <desc>
  if g "$1" "$2"; then bad "$3" "allowed (rc=0)"; else ok "$3"; fi
}
want_allow() {                          # <screen> <command> <desc>
  if g "$1" "$2"; then ok "$3"; else bad "$3" "denied: $(printf '%s' "$OUT" | head -1)"; fi
}

printf '== a prompting pane: keys that COMMIT a choice ==\n'
# This is the exact call that swept four panes. Enter accepts whatever is
# highlighted — here, an rm -rf of a repo's .git.
want_deny prompting 'herdr pane send-keys wN:p7 ENTER'        'a blind ENTER into a prompting pane is denied'
want_deny prompting 'herdr pane send-keys wN:p7 Enter'        'the mixed-case spelling too'
want_deny prompting 'herdr pane send-keys wN:p7 RETURN'       'and RETURN'
want_deny prompting 'herdr pane send-keys wN:p7 2'            'a bare digit (the numbered shape IS the answer)'
want_deny prompting 'herdr pane send-keys wN:p7 DOWN ENTER'   'navigation followed by ENTER in one call'
want_deny prompting "herdr pane send-text wN:p7 'yes'"        'any send-text into a prompting pane'
want_deny prompting "herdr pane send-text wN:p7 'looks fine'" 'including text that is not an answer at all'
# The absolute path spelling an agent is just as likely to write.
want_deny prompting '/opt/homebrew/bin/herdr pane send-keys wN:p7 ENTER' 'an absolute herdr path is still herdr'

printf '== a prompting pane: keys that cannot approve anything ==\n'
want_allow prompting 'herdr pane send-keys wN:p7 ESCAPE'  'ESCAPE (cancels) stays allowed'
want_allow prompting 'herdr pane send-keys wN:p7 CTRL_C'  'CTRL_C stays allowed'
want_allow prompting 'herdr pane send-keys wN:p7 DOWN'    'arrows alone only move the highlight'
want_allow prompting 'herdr pane read wN:p7 --source visible' 'reading a prompting pane is not answering it'

printf '== a pane that is not asking anything ==\n'
want_allow shell 'herdr pane send-keys wF:p3 ENTER'        'ENTER into a shell pane is ordinary'
want_allow shell "herdr pane send-text wF:p3 'git status'" 'typing into a shell pane is ordinary'
want_allow shell 'herdr pane send-keys wF:p3 2'            'a digit into a shell pane is ordinary'

printf '== not this guard'"'"'s business ==\n'
want_allow prompting 'echo herdr pane send-keys wN:p7 ENTER' 'the words inside an echo are not a call'
want_allow prompting "printf '%s' 'herdr pane send-text x y'"  'nor inside a quoted printf argument'
# A command position is not only "after a delimiter": a sweep loop puts the
# call after `do`, and that is where this guard matters most — one blind Enter
# per pane, at machine speed.
want_deny  prompting 'true && herdr pane send-keys wN:p7 ENTER' 'after && it is a real call'
want_deny  prompting 'for p in a b; do herdr pane send-keys $p ENTER; done' 'inside a sweep loop (after `do`)'
want_deny  prompting 'if true; then herdr pane send-keys wN:p7 ENTER; fi'   'after `then`'
want_deny  prompting 'herdr pane send-keys wN:p7 ENTER # sweeping'          'with a trailing comment'
want_allow prompting 'git commit -m "send-keys ENTER"'       'a commit message mentioning it is not a call'
want_allow prompting 'herdr pane list'                       'other herdr subcommands are untouched'

printf '== the sanctioned tools are not denied by it ==\n'
OUT="$(HERDR_EXTRA_PATH="$WORK/bin" PATH="$WORK/bin:$PATH" HERDR_FAKE_SCREEN="$WORK/prompting.txt" \
       HERDR_SANCTIONED_ANSWER=1 bash "$GUARD" 'herdr pane send-keys wN:p7 ENTER' 2>&1)"
# shellcheck disable=SC2181
[ $? -eq 0 ] && ok 'HERDR_SANCTIONED_ANSWER=1 (set by herdr-select.sh) passes through' \
             || bad 'sanctioned marker' 'the accountable path would be denied by the guard'
for f in herdr-select.sh send-to-agent.sh; do
  grep -q 'export HERDR_SANCTIONED_ANSWER=1' "$here/$f" \
    && ok "$f marks itself sanctioned" \
    || bad "$f" 'does not set the marker, so the guard would deny the path it recommends'
done

printf '== the denial has to be actionable ==\n'
g prompting 'herdr pane send-keys wN:p7 ENTER'
# Not just the STRING "herdr-select.sh" — the runnable invocation, with this
# pane and a placeholder where the option number goes. A denial that only
# gestures at the right tool gets routed around; the first version of this row
# passed while the guidance line had been deleted, because the path still
# appeared elsewhere in the message.
printf '%s' "$OUT" | grep -qE 'herdr-select\.sh[[:space:]]+wN:p7[[:space:]]+<option-number>' \
  && ok 'the denial gives the runnable herdr-select.sh invocation' \
  || bad 'denial message' "no runnable invocation: $(printf '%s' "$OUT" | grep -c . ) lines"
case "$OUT" in
  *expect-prompt-id*) ok 'and the flag that closes the TOCTOU gap' ;;
  *) bad 'denial message' 'omits --expect-prompt-id' ;;
esac
case "$OUT" in
  *Approve*Deny*|*Deny*Approve*) ok 'and shows the options actually on offer' ;;
  *"not parseable"*) ok 'or says plainly that it could not read them' ;;
  *) bad 'denial message' "no option list and no warning: $(printf '%s' "$OUT" | tail -2)" ;;
esac
# The command behind the prompt is the reason answering blind is unsafe; a
# denial that hides it invites the reader to re-approve from memory.
case "$OUT" in
  *"raw keypress"*) ok 'and says why a keypress is the problem' ;;
  *) bad 'denial message' 'does not explain the hazard' ;;
esac

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
