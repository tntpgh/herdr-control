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
# IDENTITY-AWARE, because a stub that serves the same screen for ANY pane id
# lets rows pass for the wrong reason. Review proved exactly that: the
# sweep-loop row reported ok only because `$p` was accepted as a pane id, while
# against the real CLI (which exits 1 on an unknown pane) the guard failed
# open. Here an unknown id exits 1, like herdr.
cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
# args: pane read <pane> ...
[ "${1:-}" = pane ] || exit 0
case "${2:-}" in
  read)
    case "${3:-}" in
      wN:p7|wN:p8) cat "$WORK_PROMPTING" ;;
      wF:p3)       cat "$WORK_SHELL" ;;
      w8:p2H)      cat "$WORK_NUMBERED_PROSE" ;;
      wM:p8)       cat "$WORK_MIDPAINT" ;;    # real panel, options unparseable
      wM:p9)       cat "$WORK_THREEOPT" ;;    # real panel, extra option row
      *)           exit 1 ;;            # unknown pane, same as the real CLI
    esac ;;
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

# An agent pane that is NOT prompting but whose last message ends in a numbered
# list — the shape that caused a ~10% false-denial rate on the live fleet,
# because prompt_any_visible's numbered fallback matches it while the option
# parsers return nothing.
# Faithful to the measured case: prompt_any_visible's loose numbered fallback
# matches the list, while prompt_options REFUSES it because agent prose follows
# it (the staleness rule) — so the guard sees "a prompt" that its own parsers
# will not corroborate. That combination is what produced the live false
# denials, including on `send-text` to an idle agent.
cat > "$WORK/numbered.txt" <<'SCREEN'
  Handoff written. Still needs you:
  1. review PR #519
  2. decide on the tourguide trunk
  I will wait for your call before merging anything else.
╭── ⠙ 12m · Opus 5 · ~/Code/thurber-os · main ──────────────── 22% ──╮
╰────────────────────────────────────────────────────────────────────╯
SCREEN

# REAL panels whose options the parser will not enumerate. _prompt_menu_parse
# accepts `visible` once an Approve row is consumed but `complete` only for a
# fully-formed panel, so these are menu_visible=yes / options=EMPTY. omp panels
# carry no digits, so the numbered reader finds nothing either. This is the pane
# where a blind ENTER is MOST dangerous, and requiring parseable options made
# the guard allow it.
cat > "$WORK/midpaint.txt" <<'SCREEN'
  Running the migration now.
╭─ Allow tool: bash ───────────────────────────────────────────╮
│                                                              │
│ Command: psql -f drop_and_recreate.sql                       │
│                                                              │
│  ❯ Approve                                                   │
│ up/down navigate  enter select  esc cancel                   │
╰──────────────────────────────────────────────────────────────╯
SCREEN
cat > "$WORK/threeopt.txt" <<'SCREEN'
  Ready to apply.
╭─ Allow tool: bash ───────────────────────────────────────────╮
│                                                              │
│ Command: git push --force origin main                        │
│                                                              │
│  ❯ Approve                                                   │
│    Approve and don't ask again                               │
│    Deny                                                      │
│    Deny and stop                                             │
│                                                              │
│ up/down navigate  enter select  esc cancel                   │
╰──────────────────────────────────────────────────────────────╯
SCREEN

g() {                                   # <screen> <command> -> rc, out in $OUT
  # HERDR_EXTRA_PATH, not just PATH: config.sh PREPENDS it, so a stub that is
  # only on PATH loses to the real binary and every row here would pass or fail
  # against whatever the live panes happen to be showing. (That is exactly what
  # happened while writing this: 16 rows "failed" because the stub was never
  # consulted.)
  OUT="$(HERDR_EXTRA_PATH="$WORK/bin" PATH="$WORK/bin:$PATH" \
         WORK_PROMPTING="$WORK/prompting.txt" WORK_SHELL="$WORK/shell.txt" \
         WORK_NUMBERED_PROSE="$WORK/numbered.txt" \
         WORK_MIDPAINT="$WORK/midpaint.txt" WORK_THREEOPT="$WORK/threeopt.txt" WORK="$WORK" \
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
# The full call INSIDE the message, not a fragment: the old fixture omitted
# `herdr pane` entirely, so it passed even under a guard doing no
# command-position analysis at all (proved by mutation).
want_allow prompting 'git commit -m "deny herdr pane send-keys wN:p7 ENTER"' 'a commit message containing the whole call is not a call'
want_allow prompting 'herdr pane list'                       'other herdr subcommands are untouched'

printf '== every target in the command, and only resolvable ones ==\n'
# A greedy extractor checked ONE call per command: with two on a line the last
# won, across newlines the first did, so the prompting pane escaped whenever it
# sat on the unchecked side. That is a hand-unrolled sweep.
want_deny prompting 'herdr pane send-keys wF:p3 ENTER && herdr pane send-keys wN:p7 ENTER' \
  'the prompting pane is caught when it is second'
want_deny prompting 'herdr pane send-keys wN:p7 ENTER && herdr pane send-keys wF:p3 ENTER' \
  'and when it is first'
want_deny prompting 'herdr pane send-keys wN:p7 ENTER
herdr pane send-keys wF:p3 ENTER' 'and across newlines'
want_allow shell 'herdr pane send-keys wF:p3 ENTER && herdr pane send-keys wF:p3 2' \
  'two calls to a non-prompting pane stay allowed'

# Quoting an argument is ordinary hygiene. The quotes used to survive into the
# pane id, the read failed, and the guard allowed.
want_deny prompting 'herdr pane send-keys "wN:p7" ENTER'  'a double-quoted pane id is still that pane'
want_deny prompting "herdr pane send-keys 'wN:p7' ENTER"  'a single-quoted pane id too'

# The sweep shape: the id is not known until the loop runs, so no liveness
# question can be asked about it. Treating "cannot read that pane" as "not
# prompting" failed open on the only spelling a real sweep uses.
want_deny prompting 'for p in wN:p7 wN:p8; do herdr pane send-keys $p ENTER; done' \
  'a run-time pane id is refused rather than assumed idle'
want_deny prompting 'echo wN:p7 | xargs -I{} herdr pane send-keys {} ENTER' \
  'and an xargs placeholder likewise'
g prompting 'for p in wN:p7 wN:p8; do herdr pane send-keys $p ENTER; done'
case "$OUT" in
  *"computed at run time"*) ok 'and the refusal explains why it cannot be checked' ;;
  *) bad 'ambiguous pane message' "$(printf '%s' "$OUT" | head -2)" ;;
esac

printf '== a pane that only LOOKS like it is prompting ==\n'
# prompt_any_visible is the loosest predicate in prompt-parse.sh: its numbered
# fallback matches an agent's ordinary prose summary. Denying on a "prompt" its
# own parsers cannot corroborate produced a ~10% false-denial rate on live
# panes, including send-text to an idle agent - the everyday way to message one.
want_allow numbered 'herdr pane send-keys w8:p2H ENTER' \
  'a numbered prose list is not an answerable prompt'
want_allow numbered "herdr pane send-text w8:p2H 'status?'" \
  'and messaging that agent is not answering it'

printf '== a panel the parser can SEE but not enumerate ==\n'
# Requiring a parseable option list fixed a ~10% false-denial rate and then
# allowed these, which is the wrong direction: the library fails closed on a
# panel it cannot enumerate, and reading fail-closed as no-prompt inverts it.
want_deny midpaint 'herdr pane send-keys wM:p8 ENTER' \
  'a panel painted mid-frame is still a prompt'
want_deny threeopt 'herdr pane send-keys wM:p9 ENTER' \
  'a panel with an extra option row is still a prompt'
g midpaint 'herdr pane send-keys wM:p8 ENTER'
case "$OUT" in
  *"not parseable"*) ok 'and the refusal says to read it rather than listing nothing' ;;
  *) bad 'unparseable panel' "no warning in the denial: $(printf '%s' "$OUT" | tail -2)" ;;
esac

printf '== writing ABOUT the side door is not using it ==\n'
# Every one of these was DENIED before quoted spans were blanked.
want_allow prompting 'echo "swept 4 panes; herdr pane send-keys wN:p7 ENTER was how"' \
  'a note with a semicolon inside the quotes'
want_allow prompting 'echo "see the note (herdr pane send-keys wN:p7 ENTER)"' \
  'a parenthesised mention'
# The do/then/else split used to run in a later sed with no quote state, and a
# computed pane id is refused without any liveness check — so describing the
# incident was denied deterministically, whatever the fleet was doing.
want_allow prompting 'echo "the incident: for p in $panes; do herdr pane send-keys $p ENTER; done"' \
  'prose describing the sweep, quoted, with a do-loop inside'

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
  *) bad 'denial message' "no option list: $(printf '%s' "$OUT" | tail -2)" ;;
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
