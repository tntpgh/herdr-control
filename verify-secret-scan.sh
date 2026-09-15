#!/usr/bin/env bash
# verify-secret-scan.sh — prove git-hooks/secret-scan-pre-commit.sh actually
# blocks what it claims to block, on real git repositories.
#
# WHY THIS EXISTS: until 2026-09-12 that scanner was a single untracked file in
# ~/.claude/hooks with no repo, no history, no review and no CI, installed as
# `pre-commit` in 19 repos. It carried a real bypass for an unknown length of
# time: the staged-file list used `--diff-filter=ACM`, which omits `R`, so a
# `git mv` of a file similar enough for rename detection plus an appended token
# produced an EMPTY file list — the hook scanned nothing and allowed the commit.
# It survived because it does not reproduce on a toy fixture: a small file
# records as D+A, which ACM does catch. The `rename bypass` case below is that
# exact shape, with a file large enough to be detected as a rename.
#
# Every fixture credential/PII value is BUILT AT RUNTIME from fragments. Written
# literally, they would match the scanner's own patterns and this file could not
# be committed into a repo the scanner guards. Do not "simplify" them to
# literals.
#
#   bash verify-secret-scan.sh
#   SECRET_SCAN_HOOK=/some/other/copy.sh bash verify-secret-scan.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

HOOK="${SECRET_SCAN_HOOK:-$here/git-hooks/secret-scan-pre-commit.sh}"
[ -r "$HOOK" ] || { echo "no scanner at $HOOK" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The scanner refuses any commit not authored as this address, before it looks
# at content at all — so every fixture repo must carry it or every case below
# would "block" for the wrong reason and prove nothing.
WANT_EMAIL="tnt@teamthurber.com"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ── fixtures assembled at runtime ────────────────────────────────────────────
# `gh` + `p_` + 36 chars: matches 'gh[pousr]_[A-Za-z0-9]{36,}'. The literal
# never appears in this file, so this file is committable.
GHP="gh""p_$(printf 'a%.0s' $(seq 1 40))"
AWS="AK""IA$(printf 'Q%.0s' $(seq 1 16))"
# A third-party email: not example.com/.org/.net, not teamthurber.com, not any
# other allowlisted domain — so it must trip the PII check.
BADMAIL="jdoe@$(printf 'acme')corp.biz"
# A phone outside the 555-01xx fiction range.
BADPHONE="412-$(printf '867')-5309"
# "Pinehurst" is deliberately NOT the allowlisted word "Pine": the allowlist is
# \b-anchored, so Pinehurst is a real-looking street and must block.
BADSTREET="4821 $(printf 'Pinehurst') Dr"

# ── helpers ──────────────────────────────────────────────────────────────────
# `mktemp -d`, not a counter: new_repo is always called in a command
# substitution, so a counter increments in a SUBSHELL and never advances —
# every case would silently reuse one repo and inherit the previous case's
# index. Setup chatter goes to stderr so only the path reaches stdout.
new_repo() {                    # -> prints path to a fresh repo with one commit
    local r
    r="$(mktemp -d "$WORK/repo.XXXXXX")"
    {
        git -C "$r" init -q -b main
        git -C "$r" config user.email "$WANT_EMAIL"
        git -C "$r" config user.name  "tntpgh"
        git -C "$r" config commit.gpgsign false
        printf 'readme\n' > "$r/README.md"
        git -C "$r" add README.md
        git -C "$r" commit -qm init --no-verify
    } >&2
    printf '%s' "$r"
}

# A file long enough that appending one line still scores as a RENAME (>50%
# similarity) rather than delete+add. This is the whole point of the bypass
# case: a two-line fixture records as D+A and ACM catches it.
big_file() {                    # <path>
    local i
    : > "$1"
    for i in $(seq 1 200); do printf 'line %s of ordinary source code\n' "$i" >> "$1"; done
}

scan() {                        # <repo> -> rc; output in $OUT
    OUT="$(cd "$1" && bash "$HOOK" 2>&1)"
    return $?
}

blocks() {                      # <repo> <label> — the scan MUST exit non-zero
    local r="$1" label="$2"
    if scan "$r"; then
        bad "$label — ALLOWED (scanner output: ${OUT:-<silent>})"
    else
        ok "$label"
    fi
}

allows() {                      # <repo> <label> — the scan MUST exit zero
    local r="$1" label="$2"
    if scan "$r"; then
        ok "$label"
    else
        bad "$label — BLOCKED: $OUT"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
printf '== THE RENAME BYPASS: git mv + append must be seen ==\n'
# Revert --diff-filter=ACMR to ACM in the scanner and this case, and only this
# case, goes red. That is the regression it exists to catch.
R="$(new_repo)"
big_file "$R/config.py"
git -C "$R" add config.py
git -C "$R" commit -qm "add config" --no-verify
git -C "$R" mv config.py settings.py
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" >> "$R/settings.py"
git -C "$R" add settings.py
# Guard the guard: if git did NOT record this as a rename, the case is not
# testing what it claims and must fail loudly rather than pass vacuously.
if git -C "$R" diff --cached --name-status -M | grep -q '^R'; then
    ok "fixture really is a rename (git detected R)"
else
    bad "fixture did not record as a rename — case proves nothing: $(git -C "$R" diff --cached --name-status -M)"
fi
[ -z "$(git -C "$R" diff --cached --name-only --diff-filter=ACM)" ] \
    && ok "ACM alone sees an EMPTY file list (the bypass, still reproducible)" \
    || bad "ACM sees files here — fixture no longer reproduces the original bypass"
blocks "$R" "renamed file with an appended token is BLOCKED"

printf '== THE TYPECHANGE BYPASS: symlink replaced by a regular file ==\n'
# The rename hole taught the wrong lesson: the fix added ONE letter (R) to an
# allow-list, and the next letter nobody thought of was another hole. Replace a
# SYMLINK with a regular file carrying a credential and git records `T`, which
# --diff-filter=ACMR does not select, so the file list came back EMPTY and the
# scanner exited 0 with a live-shaped token staged.
#
# Observed 2026-09-15 against BOTH the then-merged scanner and the copy in force
# on this machine: `git diff --cached --name-status` -> `T link.sh`,
# `--diff-filter=ACMR` -> nothing, scanner rc=0. The filter is now `d`
# (exclude deletions only), so every status letter is scanned by default.
#
# Revert the filter to any allow-list that omits T and only this case goes red.
R="$(new_repo)"
printf 'real content\n' > "$R/real.txt"
ln -s real.txt "$R/link.sh"
git -C "$R" add -A
git -C "$R" commit -qm "add a symlink" --no-verify
[ "$(git -C "$R" ls-files -s link.sh | cut -c1-6)" = "120000" ] \
    && ok "fixture really committed a symlink (mode 120000)" \
    || bad "fixture is not a symlink — case proves nothing: $(git -C "$R" ls-files -s link.sh)"
rm "$R/link.sh"
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" > "$R/link.sh"
git -C "$R" add link.sh
git -C "$R" diff --cached --name-status | grep -q '^T' \
    && ok "fixture really is a typechange (git recorded T)" \
    || bad "fixture did not record as a typechange: $(git -C "$R" diff --cached --name-status)"
[ -z "$(git -C "$R" diff --cached --name-only --diff-filter=ACMR)" ] \
    && ok "ACMR sees an EMPTY file list (the bypass, still reproducible)" \
    || bad "ACMR sees files here — fixture no longer reproduces the bypass"
blocks "$R" "symlink replaced by a token-carrying regular file is BLOCKED"

# META: make the NEXT status letter a red suite rather than a review question.
# Every `--diff-filter=` in the scanner must go through the one constant, and
# that constant must be the exclude form. Three literals that must agree is the
# defect underneath both bypasses: the early `exit 0` filter disagreeing with
# the scan loop's filter is how an empty list becomes a silent pass.
# Comment lines are excluded: the scanner's own comments NAME the historical
# allow-lists (ACM, ACMR, Ad) as part of explaining why they were holes, and a
# meta-test that cannot tell documentation from code would force those
# explanations to be deleted.
_filters=$(grep -vE '^[[:space:]]*#' "$HOOK" | grep -oE -- '--diff-filter=[^ ]*' \
           | grep -v '^--diff-filter="\$DIFF_FILTER"$' || true)
[ -z "$_filters" ] \
    && ok "every --diff-filter in the scanner uses the shared constant" \
    || bad "literal --diff-filter found (must be \"\$DIFF_FILTER\"): $(printf '%s' "$_filters" | tr '\n' ' ')"
grep -qE '^DIFF_FILTER=d$' "$HOOK" \
    && ok "the constant is the EXCLUDE form (d), not an allow-list" \
    || bad "DIFF_FILTER is not 'd' — an allow-list is how T and R were missed: $(grep -E '^DIFF_FILTER=' "$HOOK")"
[ -n "$(git -C "$R" diff --cached --name-only --diff-filter=d)" ] \
    && ok "filter=d DOES list the typechange the allow-list missed" \
    || bad "filter=d missed the typechange fixture — the fix does not do what it claims"

printf '== THE PIPE-BUFFER BYPASS: a secret near the top of a LARGE file ==\n'
# `grep -q` exits on match, `git show` dies of SIGPIPE (141), and `set -o
# pipefail` adopts 141 as the pipeline status — so the `if` read FALSE and the
# token sailed through. Measured 2026-09-12 against the then-live scanner: a
# ghp_ token on line 1 of a 7 MB file was ALLOWED while the SAME token at the
# bottom of the SAME file was blocked. 16 KB blocked, 64 KB and up allowed.
#
# Worse than the rename bypass: it needs no `git mv`, just a file bigger than
# the pipe buffer — a minified bundle, a lockfile, a CSV, a JSON dump.
#
# The pair is the point. `top` alone could pass on a scanner that blocks
# everything, so `clean_big` guards against exactly the false-positive
# regression the first cut of this fix introduced (errexit aborting on a clean
# no-match, which reads as "blocked" for every large file).
R="$(new_repo)"
python3 - "$R" "$GHP" <<'PYX'
import sys
r, ghp = sys.argv[1], sys.argv[2]
pad = ("x" * 80 + "\n") * 90000          # ~7 MB, far past the 64 KB pipe buffer
open(f"{r}/top.txt", "w").write(f'TOKEN = "{ghp}"\n' + pad)
open(f"{r}/bottom.txt", "w").write(pad + f'TOKEN = "{ghp}"\n')
open(f"{r}/clean_big.txt", "w").write(pad)
PYX
# Guard the guard: the fixture must actually exceed the pipe buffer, or this
# case proves nothing.
sz=$(wc -c < "$R/top.txt" | tr -d ' ')
[ "$sz" -gt 65536 ] \
    && ok "fixture exceeds the 64 KB pipe buffer ($sz bytes)" \
    || bad "fixture is only $sz bytes — too small to reproduce the bypass"

git -C "$R" add top.txt
blocks "$R" "token at the TOP of a large file is BLOCKED"
git -C "$R" reset -q
git -C "$R" add bottom.txt
blocks "$R" "token at the BOTTOM of a large file is BLOCKED"
git -C "$R" reset -q
git -C "$R" add clean_big.txt
allows "$R" "a large file with NO token is allowed (no errexit false positive)"
git -C "$R" reset -q

printf '== a scanner that cannot run its own pattern has not cleared anything ==\n'
# A grep ERROR (exit 2) is not a clean file. The trigger is a maintainer
# editing PATTERNS, not an attacker: a construct valid in GNU ERE but not the
# BSD grep this fleet runs makes grep exit 2 for EVERY file and EVERY pattern,
# so the whole guard silently scans nothing. Judging only `-eq 0` conflated
# that with "clean" — the same status conflation the SIGPIPE fix removed, one
# field over, committed in its own new lines.
R="$(new_repo)"
printf 'nothing interesting here\n' > "$R/a.txt"
git -C "$R" add a.txt
# Build a copy of the scanner whose FIRST pattern is invalid ERE. `[` is an
# unterminated bracket expression: grep exits 2, not 0 or 1.
BROKEN="$WORK/broken-scanner.sh"
sed -E 's/^PATTERNS=\(/PATTERNS=(\n    "["/' "$HOOK" > "$BROKEN"
if bash -n "$BROKEN" 2>/dev/null && grep -qE '^\s+"\["' "$BROKEN"; then
    ok "fixture scanner really carries an invalid pattern"
    OUT="$(cd "$R" && bash "$BROKEN" 2>&1)"; RC=$?
    [ "$RC" -ne 0 ] \
        && ok "a pattern grep cannot compile BLOCKS rather than silently passing" \
        || bad "grep error treated as clean — the whole guard scans nothing: rc=$RC ${OUT:-<silent>}"
else
    bad "could not build the broken-pattern fixture — case proves nothing"
fi

printf '== an unreadable staged file is reported ONCE, not once per pattern ==\n'
# 17 identical refusals plus 17 lines of git stderr for one corrupt blob buries
# the message, and the operator-facing message is the thing that has to
# survive — the rename and SIGPIPE bypasses both hid behind output nobody read.
R="$(new_repo)"
printf 'clean line\n' > "$R/a.txt"
git -C "$R" add a.txt
BLOB="$(git -C "$R" rev-parse :a.txt)"
rm -f "$R/.git/objects/${BLOB:0:2}/${BLOB:2}"
OUT="$(cd "$R" && bash "$HOOK" 2>&1)"; RC=$?
N="$(printf '%s\n' "$OUT" | grep -c 'refusing to treat an unreadable file as clean' || true)"
[ "$RC" -ne 0 ] && ok "an unreadable staged file is refused" \
               || bad "an unreadable staged file was treated as clean (rc=$RC)"
[ "$N" -eq 1 ] && ok "the refusal is printed once, not once per pattern" \
               || bad "printed $N times — one per pattern buries the message"

printf '== ordinary cases ==\n'
R="$(new_repo)"
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" > "$R/deploy.sh"
git -C "$R" add deploy.sh
blocks "$R" "a token in a newly ADDED file is blocked"

R="$(new_repo)"
printf 'x = 1\n' > "$R/app.py"
git -C "$R" add app.py
git -C "$R" commit -qm app --no-verify
printf 'AWS_KEY = "%s"\n' "$AWS" >> "$R/app.py"
git -C "$R" add app.py
blocks "$R" "a token added by MODIFYING a tracked file is blocked"

R="$(new_repo)"
printf 'def add(a, b):\n    return a + b\n' > "$R/math.py"
git -C "$R" add math.py
allows "$R" "an ordinary clean commit is allowed"

printf '== MERGE COMMITS (the pre-merge-commit path) ==\n'
# git runs `pre-commit` for an ordinary commit and `pre-merge-commit` for a
# merge that commits automatically. Same script, different hook name — which is
# why install-git-hooks.sh installs both. Before that, a token committed on a
# branch with --no-verify reached main through `git merge --no-ff` unscanned.
R="$(new_repo)"
git -C "$R" checkout -qb feature
printf 'SECRET = "%s"\n' "$GHP" > "$R/worker.py"
git -C "$R" add worker.py
git -C "$R" commit -qm "worker" --no-verify
git -C "$R" checkout -q main
printf 'note\n' >> "$R/README.md"
git -C "$R" add README.md
git -C "$R" commit -qm "diverge" --no-verify
git -C "$R" merge --no-ff --no-commit feature >/dev/null 2>&1
[ -f "$R/.git/MERGE_HEAD" ] \
    && ok "fixture is a real pending merge (MERGE_HEAD present)" \
    || bad "merge did not stage — case proves nothing"
blocks "$R" "a token arriving through a MERGE is blocked"

R="$(new_repo)"
git -C "$R" checkout -qb clean-feature
printf 'ok\n' > "$R/notes.txt"
git -C "$R" add notes.txt
git -C "$R" commit -qm notes --no-verify
git -C "$R" checkout -q main
printf 'note\n' >> "$R/README.md"
git -C "$R" add README.md
git -C "$R" commit -qm "diverge" --no-verify
git -C "$R" merge --no-ff --no-commit clean-feature >/dev/null 2>&1
allows "$R" "a clean merge is allowed (the guard is not a merge blocker)"

printf '== ALLOWLIST: synthetic fixtures must not be blocked ==\n'
# If these fire, people reach for --no-verify on ordinary test data and the
# guard stops guarding. That failure mode is why the allowlist exists.
R="$(new_repo)"
cat > "$R/fixture.py" <<'EOS'
CONTACT = {
    "email": "someone@example.com",
    "email2": "agent@teamthurber.com",
    "phone": "412-555-0142",
    "street": "123 Main St",
}
EOS
git -C "$R" add fixture.py
allows "$R" "555-01xx / example.com / 123 Main St fixtures are allowed"

R="$(new_repo)"
cat > "$R/svc.py" <<'EOS'
SERVICE_ACCOUNT = "kb@my-project-id.iam.gserviceaccount.com"
DB_URL = "postgres://user:pw@db.example.com:5432/app"
EOS
git -C "$R" add svc.py
allows "$R" "service-account and example.com SUBDOMAIN identities are allowed"

R="$(new_repo)"
cat > "$R/test_x.py" <<'EOS'
@pytest.mark.parametrize("a,b", [(1, 2)])
def test_add(a, b):
    assert a + b == 3
EOS
git -C "$R" add test_x.py
allows "$R" "a parametrize decorator is not read as an email address"

printf '== ...and real-looking PII still blocks ==\n'
R="$(new_repo)"
printf 'owner = "%s"\n' "$BADMAIL" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a third-party email address is blocked"

R="$(new_repo)"
printf 'cell = "%s"\n' "$BADPHONE" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a phone outside the 555-01xx fiction range is blocked"

R="$(new_repo)"
printf 'addr = "%s"\n' "$BADSTREET" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a real-looking street address is blocked"

printf '== NON-UTF8 BYTES: a binary-ish staged file must not blind the scan ==\n'
# `git show | grep` on a file holding an invalid UTF-8 byte is where a scanner
# quietly stops matching (grep declaring the stream binary, or failing outright
# under a UTF-8 locale). The property is that the token is still found, and that
# the scan does not die on the byte.
R="$(new_repo)"
printf 'TOKEN = "%s"\n' "$GHP" > "$R/blob.dat"
printf 'prefix \377\376 suffix\n' >> "$R/blob.dat"
git -C "$R" add blob.dat
blocks "$R" "a token beside an invalid UTF-8 byte is still found"

R="$(new_repo)"
printf 'harmless \377\376 bytes\n' > "$R/blob.dat"
git -C "$R" add blob.dat
allows "$R" "an invalid UTF-8 byte alone is not itself a finding"

printf '== paths the loop could silently skip ==\n'
R="$(new_repo)"
printf 'TOKEN = "%s"\n' "$GHP" > "$R/with space name.txt"
git -C "$R" add "with space name.txt"
blocks "$R" "a token in a path containing spaces is blocked"

R="$(new_repo)"
printf 'TOKEN = "%s"\n' "$GHP" > "$R/logo.png"
git -C "$R" add logo.png
allows "$R" "a skipped binary extension is not scanned (documented tradeoff)"

R="$(new_repo)"
printf '  "resolved": "https://npm:%s@registry.example.com/x"\n' "$GHP" > "$R/yarn.lock"
git -C "$R" add yarn.lock
blocks "$R" "a token in yarn.lock is blocked (lockfiles are scanned for creds)"

printf '== nothing staged, and the identity gate ==\n'
R="$(new_repo)"
allows "$R" "an empty index exits 0 without scanning"

R="$(new_repo)"
git -C "$R" config user.email "thurbs@users.noreply.github.com"
printf 'x = 1\n' > "$R/app.py"
git -C "$R" add app.py
blocks "$R" "a commit authored as the wrong account is blocked"
scan "$R"
printf '%s' "$OUT" | grep -q "$WANT_EMAIL" \
    && ok "the identity refusal names the expected address" \
    || bad "identity refusal is not actionable: $OUT"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
