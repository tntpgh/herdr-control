#!/usr/bin/env bash
# Tests for write-handoff.sh. The load-bearing behaviour is IDEMPOTENCY: a
# notepad is append-only, so a second run must not double the section.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/write-handoff.sh"
pass=0 fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }

D="$(mktemp -d)"
printf '\n# Session 2026-01-01 - a thing happened\n\n## Completed\n- x\n' > "$D/handoff.md"
: > "$D/np1.md"; : > "$D/np2.md"

echo "== first run appends to every notepad =="
"$SUT" "$D/handoff.md" "$D/np1.md" "$D/np2.md" >/dev/null 2>&1
for f in np1 np2; do
    n=$(grep -c "a thing happened" "$D/$f.md")
    [ "$n" = 1 ] && ok "$f.md has the section once" || no "$f.md" "count=$n"
done

echo
echo "== re-run must NOT duplicate (the whole point) =="
"$SUT" "$D/handoff.md" "$D/np1.md" "$D/np2.md" >/dev/null 2>&1
for f in np1 np2; do
    n=$(grep -c "a thing happened" "$D/$f.md")
    [ "$n" = 1 ] && ok "$f.md still has it exactly once" || no "$f.md" "duplicated: count=$n"
done

echo
echo "== a DIFFERENT handoff still appends =="
printf '\n# Session 2026-01-02 - another thing\n\n## Completed\n- y\n' > "$D/h2.md"
"$SUT" "$D/h2.md" "$D/np1.md" >/dev/null 2>&1
n=$(grep -cE "a thing happened|another thing" "$D/np1.md")
[ "$n" = 2 ] && ok "np1.md now has both sections" || no "np1.md" "expected 2 got $n"

echo
echo "== refusals =="
"$SUT" "$D/nope.md" "$D/np1.md" >/dev/null 2>&1 && no "missing handoff" "exited 0" || ok "missing handoff file refused"
: > "$D/empty.md"
"$SUT" "$D/empty.md" "$D/np1.md" >/dev/null 2>&1 && no "empty handoff" "exited 0" || ok "empty handoff refused"
printf 'no heading here\njust prose\n' > "$D/nohead.md"
"$SUT" "$D/nohead.md" "$D/np1.md" >/dev/null 2>&1 && no "headingless" "exited 0" || ok "headingless handoff refused (undedupable)"

# A decorative rule is a valid markdown heading but a useless key: it matches every
# notepad that ever used the same banner. This silently no-opped a real session save.
printf '# ==========\n# =====\n\nbody\n' > "$D/deco.md"
"$SUT" "$D/deco.md" "$D/np1.md" >/dev/null 2>&1 && no "decorative heading" "exited 0" || ok "decorative-only heading refused"

# A banner ABOVE a real title must key on the title, not the banner.
: > "$D/np3.md"
printf '# =====\n# Session 2026-03-03 - real title\n\nbody\n' > "$D/banner.md"
"$SUT" "$D/banner.md" "$D/np3.md" >/dev/null 2>&1
n=$(grep -c "real title" "$D/np3.md")
[ "$n" = 1 ] && ok "banner then title: wrote once" || no "banner then title" "count=$n"
"$SUT" "$D/banner.md" "$D/np3.md" >/dev/null 2>&1
n=$(grep -c "real title" "$D/np3.md")
[ "$n" = 1 ] && ok "banner then title: re-run still once" || no "banner re-run" "duplicated: count=$n"
"$SUT" "$D/handoff.md" "$D/absent-notepad.md" >/dev/null 2>&1 && no "missing notepad" "exited 0" || ok "missing notepad reported, not created"
[ -f "$D/absent-notepad.md" ] && no "missing notepad" "was created" || ok "missing notepad really not created"
"$SUT" >/dev/null 2>&1 && no "no args" "exited 0" || ok "no args shows usage"

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
