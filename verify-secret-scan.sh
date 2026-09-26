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

# Our OWN published business identity is not client PII. The office address and
# the three canonical NAP lines are printed on every piece of public marketing
# and the broker office line is REQUIRED on licensee advertising by
# 49 Pa. Code 35.305(c); 412-367-5860 is West Penn Multi-List's published
# switchboard, quoted when documenting an MLS rule. Blocking these taught
# --no-verify on ordinary branding work (2026-09-16, tourguide sellers guide).
R="$(new_repo)"
cat > "$R/branding.js" <<'EOS'
const NAP = {
  office: "2100 Corporate Drive, Suite 200, Wexford, PA 15090",
  brokerPhone: "(724) 934-3400",
  direct: "(412) 844-5536",
  team: "(412) 900-2243",
  mlsSwitchboard: "412-367-5860",
};
EOS
git -C "$R" add branding.js
allows "$R" "our own published NAP (office + broker/team lines) is allowed"

# The phone pattern used to match INSIDE a longer digit run, so the Springer
# DOI below parsed as a phone number and blocked a commit whose only offence
# was citing a peer-reviewed paper (2026-09-16). The fixture is the real DOI;
# the substring it was misread as is deliberately not spelled out, because
# writing it in a comment re-trips the detector on this file.
R="$(new_repo)"
cat > "$R/sources.md" <<'EOS'
Seiler (2014), J. Real Estate Finance & Economics 49(2):237-255 —
https://link.springer.com/article/10.1007/s11146-013-9424-1
EOS
git -C "$R" add sources.md
allows "$R" "a DOI is not read as a phone number (digit-run false positive)"

# tntpgh-dev's published VIDEO metadata is public marketing content, not client
# PII. The titles come verbatim from the team's own YouTube channel and they are
# listing addresses because the videos are listing tours; `public/sitemap.xml`
# is generated from the same data at prebuild, so the addresses reappear in its
# video elements on every regeneration. Without these two exemptions the street
# check blocks the VideoObject schema work outright (2026-09-16, plan 013 P3).
R="$(new_repo)"
mkdir -p "$R/src/data"
printf '{"videos":[{"id":"x","title":"%s Original"}]}\n' "$BADSTREET" > "$R/src/data/videos.json"
git -C "$R" add src/data/videos.json
allows "$R" "a listing address in src/data/videos.json is published marketing, not PII"

R="$(new_repo)"
mkdir -p "$R/public"
printf '<video:title>%s</video:title>\n' "$BADSTREET" > "$R/public/sitemap.xml"
git -C "$R" add public/sitemap.xml
allows "$R" "the same address in the generated public/sitemap.xml is allowed too"

# ...and the exemption is a PATH exemption, never a content shield: the same
# value one directory over still blocks, and a real credential inside an
# exempted path is still caught by the credential half, which walks every
# staged file independently of this list.
R="$(new_repo)"
mkdir -p "$R/src/data"
printf '{"client":{"addr":"%s"}}\n' "$BADSTREET" > "$R/src/data/clients.json"
git -C "$R" add src/data/clients.json
blocks "$R" "the same address in a NON-exempt src/data file still blocks"

R="$(new_repo)"
mkdir -p "$R/src/data"
printf '{"videos":[],"token":"ghp_%s"}\n' "$(printf 'A%.0s' $(seq 36))" > "$R/src/data/videos.json"
git -C "$R" add src/data/videos.json
blocks "$R" "a credential inside the exempted videos.json is still blocked"

# ...and the exemption is ADDRESS-ONLY. A first draft put both paths in
# PII_EXCLUDES, which drops them from the whole PII input, so a real pre-push
# probe allowed a third-party email in videos.json and a non-fiction phone in
# sitemap.xml -- two public-output paths had become general PII bypasses
# (found in review, 2026-09-16). The phone and email detectors must still read
# every line of both files.
R="$(new_repo)"
mkdir -p "$R/src/data"
printf '{"videos":[{"contact":"%s"}]}\n' "$BADMAIL" > "$R/src/data/videos.json"
git -C "$R" add src/data/videos.json
blocks "$R" "a third-party email in the address-exempt videos.json still blocks"

R="$(new_repo)"
mkdir -p "$R/public"
printf '<video:description>call %s</video:description>\n' "$BADPHONE" > "$R/public/sitemap.xml"
git -C "$R" add public/sitemap.xml
blocks "$R" "a real phone in the address-exempt sitemap.xml still blocks"

# tntpgh-dev's image ASSET MANIFESTS are the same published listing pipeline
# output: every property entry's `source` is the MLS original's filename, which
# is the listing's street address. CI commits them on every data run (no hook
# on the runner), so the tracked files already hold thousands of these lines;
# only a local commit ever hits the street check (2026-09-26, market-listing
# media backfill). Street-detector exemption only, like videos.json above.
R="$(new_repo)"
mkdir -p "$R/src/assets"
printf '{"variants":[{"source":"src/assets/originals/properties/%s 1.webp"}]}\n' "$BADSTREET" > "$R/src/assets/asset-manifest.json"
git -C "$R" add src/assets/asset-manifest.json
allows "$R" "a listing address in src/assets/asset-manifest.json is published pipeline output"

R="$(new_repo)"
mkdir -p "$R/src/assets"
printf '{"variants":[{"source":"src/assets/originals/properties/%s 1.webp"}]}\n' "$BADSTREET" > "$R/src/assets/asset-manifest-hero.json"
git -C "$R" add src/assets/asset-manifest-hero.json
allows "$R" "the same address in src/assets/asset-manifest-hero.json is allowed too"

R="$(new_repo)"
mkdir -p "$R/src/assets"
printf '{"variants":[{"contact":"%s"}]}\n' "$BADMAIL" > "$R/src/assets/asset-manifest.json"
git -C "$R" add src/assets/asset-manifest.json
blocks "$R" "a third-party email in the address-exempt asset-manifest.json still blocks"

R="$(new_repo)"
mkdir -p "$R/src/assets"
printf '{"client":{"addr":"%s"}}\n' "$BADSTREET" > "$R/src/assets/clients.json"
git -C "$R" add src/assets/clients.json
blocks "$R" "the same address in a NON-manifest src/assets file still blocks"

printf '== ...and real-looking PII still blocks ==\n'
R="$(new_repo)"
printf 'owner = "%s"\n' "$BADMAIL" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a third-party email address is blocked"

printf '== EMAIL: a business PUBLISHED contact vs a person ==\n'
# The domain allowlist above is enumerated — one hand-added entry per vendor,
# forever, with the guard blocking honest work until someone adds it. A ROLE
# MAILBOX at a business domain is what a company prints on its own website, so
# it is exempt by SHAPE rather than by name. A person stays blocked wherever
# they work, and a role-shaped local part at a consumer provider is a person.
#
# Built from fragments like the other fixtures, so this file never carries a
# blockable literal — the first version of the hook's own comment for this
# rule blocked the commit that added it.
ROLE_BIZ="info@northside-ti""tle.com"
ROLE_BIZ2="escrow@allegheny-ti""tle.com"
PERSON_BIZ="kristin.re""ger@northside-ti""tle.com"
ROLE_CONSUMER="office@yah""oo.com"

R="$(new_repo)"
printf 'vendor = "%s"\nescrow = "%s"\n' "$ROLE_BIZ" "$ROLE_BIZ2" > "$R/vendors.md"
git -C "$R" add vendors.md
allows "$R" "a role mailbox at a business domain is allowed"

R="$(new_repo)"
printf 'vendor = "%s"\n' "$(printf '%s' "$ROLE_BIZ" | tr '[:lower:]' '[:upper:]')" > "$R/vendors.md"
git -C "$R" add vendors.md
allows "$R" "...case-insensitively, since a pasted contact is often capitalised"

R="$(new_repo)"
printf 'contact = "%s"\n' "$PERSON_BIZ" > "$R/vendors.md"
git -C "$R" add vendors.md
blocks "$R" "a NAMED individual at that same business domain still blocks"

R="$(new_repo)"
printf 'contact = "%s"\n' "$ROLE_CONSUMER" > "$R/vendors.md"
git -C "$R" add vendors.md
blocks "$R" "a role-shaped local part at a CONSUMER provider still blocks"

R="$(new_repo)"
printf 'cell = "%s"\n' "$BADPHONE" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a phone outside the 555-01xx fiction range is blocked"

R="$(new_repo)"
printf 'addr = "%s"\n' "$BADSTREET" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a real-looking street address is blocked"

printf '== STREET ADDRESS: already on the deployed trunk vs genuinely new ==\n'
# The other street exclusions are ENUMERATED (fixture words, two own-NAP
# entries), so every legitimate case needs the list extended by hand — and
# until it is, the guard blocks honest work, which is how people learn to
# route around it. #87 covered generated pipeline output by PATH. This covers
# what no path list anticipates (a blog post quoting a listing, a CMA, a press
# pitch) by asking whether the VALUE is already public.
#
# `new_repo` has no `origin`, so nothing is published there: that is the
# negative case and it must still block. The positive case needs a real bare
# upstream carrying the address, which is what the second repo builds — a stub
# would not exercise the `git grep <ref>` path the rule actually uses.
TRUNK_NUM=4821; TRUNK_ST="Pine""hurst"; TRUNK_SUF=Dr
TRUNK_ADDR="$TRUNK_NUM $TRUNK_ST $TRUNK_SUF"
OTHER_ADDR="1140 $(printf 'Rosslyn') Ave"

R="$(new_repo)"
printf 'addr = "%s"\n' "$OTHER_ADDR" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "an address on no published trunk is blocked"

R="$(new_repo)"
UP="$(mktemp -d)/upstream.git"
git init -q --bare "$UP"
printf 'listings = ["%s"]\n' "$TRUNK_ADDR" > "$R/listings.py"
git -C "$R" add listings.py
git -C "$R" -c user.email="$WANT_EMAIL" -c user.name=t commit -q --no-verify -m 'published listing data'
git -C "$R" remote add origin "$UP"
git -C "$R" push -q origin HEAD:refs/heads/main
git -C "$R" fetch -q origin
printf 'title = "%s, Pittsburgh PA"\n' "$TRUNK_ADDR" > "$R/post.md"
git -C "$R" add post.md
allows "$R" "an address already on origin/main is allowed"

# The trunk spells the suffix out where the commit abbreviates it.
printf 'title = "%s %s Drive"\n' "$TRUNK_NUM" "$TRUNK_ST" > "$R/post.md"
git -C "$R" add post.md
allows "$R" "a suffix spelling difference still matches the trunk"

# Case, too. The detector and the own-NAP exclusions are both
# case-insensitive, and any asymmetry between the halves of an exemption is
# where bypasses live — so the trunk lookup matches the same way. Without
# this row the `-i` can be dropped and nothing fails.
printf 'TITLE = "%s %s DR"\n' "$TRUNK_NUM" "$(printf '%s' "$TRUNK_ST" | tr '[:lower:]' '[:upper:]')" > "$R/post.md"
git -C "$R" add post.md
allows "$R" "a case difference still matches the trunk"

# ...and a DIFFERENT address still blocks in that same repo, which is what
# proves the allowance is per-ADDRESS and not a per-repo switch.
printf 'title = "%s"\n' "$OTHER_ADDR" > "$R/post.md"
git -C "$R" add post.md
blocks "$R" "a different, unpublished address still blocks in that repo"

# The baseline is the REMOTE trunk. A local commit must not be able to approve
# its own address: HEAD contains it, origin/main does not.
R="$(new_repo)"
UP2="$(mktemp -d)/upstream2.git"
git init -q --bare "$UP2"
printf 'seed = 1\n' > "$R/seed.py"
git -C "$R" add seed.py
git -C "$R" -c user.email="$WANT_EMAIL" -c user.name=t commit -q --no-verify -m seed
git -C "$R" remote add origin "$UP2"
git -C "$R" push -q origin HEAD:refs/heads/main
git -C "$R" fetch -q origin
printf 'addr = "%s"\n' "$OTHER_ADDR" > "$R/local.py"
git -C "$R" add local.py
git -C "$R" -c user.email="$WANT_EMAIL" -c user.name=t commit -q --no-verify -m 'local only'
printf 'again = "%s"\n' "$OTHER_ADDR" > "$R/again.py"
git -C "$R" add again.py
blocks "$R" "an address in LOCAL history only does not approve itself"

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
grep -q "$WANT_EMAIL" <<<"$OUT" \
    && ok "the identity refusal names the expected address" \
    || bad "identity refusal is not actionable: $OUT"

# ═════════════════════════════════════════════════════════════════════════════
printf '== PUSH MODE: the paths that never run a commit hook ==\n'
# `pre-commit` and `pre-merge-commit` are the ONLY hooks git runs when `git
# commit` creates a commit. `git am`, `cherry-pick`, `revert` and every
# `rebase` replay write commits without running either, and this fleet has no
# GitHub push protection behind them (private repos, paid feature). Each of
# those paths was a free pass for a credential, and the only place to catch the
# CLASS rather than the cases is `pre-push`: however a commit was made, it has
# to be pushed to leave the machine.
#
# These drive the REAL hook through a REAL `git push` to a local bare remote,
# with all three hooks installed — not by calling the scanner directly, because
# what is under test includes git's own pre-push stdin protocol.
push_repo() {                   # -> prints path to a repo with 3 hooks + a remote
    local r bare
    r="$(new_repo)"
    bare="$(mktemp -d "$WORK/bare.XXXXXX")"
    {
        git -C "$bare" init -q --bare
        git -C "$r" remote add origin "$bare"
        mkdir -p "$r/.git/hooks"
        printf '#!/usr/bin/env bash\nexec bash %s\n' "$HOOK" > "$r/.git/hooks/pre-commit"
        printf '#!/usr/bin/env bash\nexec bash %s\n' "$HOOK" > "$r/.git/hooks/pre-merge-commit"
        # `"$@"` because git calls pre-push as `<remote-name> <remote-url>`
        # and the scanner needs the remote to answer "what does THIS remote
        # not have yet?". The installed shim forwards it the same way.
        printf '#!/usr/bin/env bash\nexec bash %s --push "$@"\n' "$HOOK" > "$r/.git/hooks/pre-push"
        chmod +x "$r/.git/hooks/pre-commit" "$r/.git/hooks/pre-merge-commit" "$r/.git/hooks/pre-push"
        git -C "$r" push -q origin main
    } >&2
    printf '%s' "$r"
}

pushes() {                      # <repo> <label> [refspec] — push MUST succeed
    local r="$1" label="$2" ref="${3:-main}"
    if OUT="$(git -C "$r" push origin "$ref" 2>&1)"; then
        ok "$label"
    else
        bad "$label — BLOCKED: $OUT"
    fi
}

refuses_push() {                # <repo> <label> — push MUST be refused
    local r="$1" label="$2"
    if OUT="$(git -C "$r" push origin main 2>&1)"; then
        bad "$label — ALLOWED (hook output: ${OUT:-<silent>})"
    else
        ok "$label"
    fi
}

# cherry-pick: git runs NO commit-creation hook, so the token lands locally.
R="$(push_repo)"
git -C "$R" switch -q -c side
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" > "$R/creds.sh"
git -C "$R" add creds.sh
git -C "$R" commit -qm "token" --no-verify
SIDE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" switch -q main
git -C "$R" cherry-pick "$SIDE" >/dev/null 2>&1
refuses_push "$R" "a CHERRY-PICKED secret is refused at push"
grep -q "rotate at the provider" <<<"$OUT" \
    && ok "the push refusal says to rotate FIRST" \
    || bad "push refusal is not actionable: $OUT"

# git am: runs applypatch hooks only, never pre-commit.
R="$(push_repo)"
git -C "$R" switch -q -c patchsrc
printf 'AWS_KEY = "%s"\n' "$AWS" > "$R/creds.sh"
git -C "$R" add creds.sh
git -C "$R" commit -qm "token via patch" --no-verify
git -C "$R" format-patch -1 -o "$R/patches" -q
git -C "$R" switch -q main
git -C "$R" am "$R"/patches/*.patch >/dev/null 2>&1
refuses_push "$R" "a secret applied with git am is refused at push"

# Add-then-remove: the TIP is clean, the history being published is not. Only a
# per-commit scan sees this; reading the tip would call it clean.
R="$(push_repo)"
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" > "$R/creds.sh"
git -C "$R" add creds.sh
git -C "$R" commit -qm "oops" --no-verify
printf 'GITHUB_TOKEN = "$(op read op://secrets/x/credential)"\n' > "$R/creds.sh"
git -C "$R" add creds.sh
git -C "$R" commit -qm "use op:// instead" --no-verify
if grep -q "$GHP" "$R/creds.sh"; then
    bad "fixture wrong: the tip still holds the token"
else
    ok "the tip is clean, so only a per-commit scan can see this"
fi
refuses_push "$R" "a secret added and later removed is still refused at push"

# Client PII on the same path: the higher-consequence half of this hook.
R="$(push_repo)"
printf 'buyer_phone = "%s"\n' "$BADPHONE" > "$R/lead.py"
git -C "$R" add lead.py
git -C "$R" commit -qm "lead" --no-verify
refuses_push "$R" "client PII in a pushed commit is refused"

# A commit MESSAGE that merely mentions a token shape is not a committed
# secret, and blocking it has no compliant fix short of rewriting history — so
# the scan must read the diff, not the log header.
R="$(push_repo)"
printf 'nothing secret\n' > "$R/notes.md"
git -C "$R" add notes.md
git -C "$R" commit -qm "remove the $GHP token from settings" --no-verify
pushes "$R" "a token shape in the COMMIT MESSAGE does not block the push"

# Controls: a guard that blocks ordinary work gets bypassed.
R="$(push_repo)"
printf '# notes\nop://secrets/thing/credential\n' > "$R/notes.md"
git -C "$R" add notes.md
git -C "$R" commit -qm "notes" --no-verify
pushes "$R" "a clean push is allowed"

# A NEW branch must not rescan history back to the root: on the first push of
# any branch that would block on anything historical, with no compliant path.
# Only commits the remote does not already have are in scope.
R="$(push_repo)"
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" > "$R/old.sh"
git -C "$R" add old.sh
git -C "$R" commit -qm "historical secret, already published" --no-verify
git -C "$R" push -q --no-verify origin main
git -C "$R" switch -q -c feature
printf 'clean\n' > "$R/new.txt"
git -C "$R" add new.txt
git -C "$R" commit -qm "clean work" --no-verify
pushes "$R" "a NEW branch is scanned for its OWN commits, not all history" feature

# Deleting a remote branch pushes no content. An unguarded range here would
# resolve to "everything".
if OUT="$(git -C "$R" push origin --delete feature 2>&1)"; then
    ok "deleting a remote branch is not scanned as a range"
else
    bad "branch deletion was refused: $OUT"
fi

# Index mode is unchanged: the identity check still fires on a commit, and must
# NOT fire on a push — a pushed range can hold commits whose author is already
# public and unfixable (648 of them in knowledge-base), so enforcing it there
# has no compliant path and would only teach --no-verify.
R="$(push_repo)"
git -C "$R" config user.email "thurbs@users.noreply.github.com"
printf 'clean\n' > "$R/ok.txt"
git -C "$R" add ok.txt
blocks "$R" "index mode still refuses the wrong commit identity"
git -C "$R" commit -qm "wrong identity" --no-verify
pushes "$R" "push mode does NOT enforce commit identity"

# ═════════════════════════════════════════════════════════════════════════════
printf '== PUSH MODE: the four bypasses security review reproduced ==\n'
# Every one of these was ALLOWED by the first version of push mode and put a
# live-shaped token on the remote. They are the reason this mode fails closed.

# 1. A force push whose remote sha is not in the local object DB. git passes
#    the tip the REMOTE advertised; after someone else pushes, we do not have
#    it, `rev-list "$rsha..$lsha"` FAILS, and `|| true` made that an empty
#    range: exit 0, nothing scanned, token published.
BARE="$(mktemp -d "$WORK/forcebare.XXXXXX")"
git -C "$BARE" init -q --bare
A="$(new_repo)"; git -C "$A" remote add origin "$BARE"; git -C "$A" push -q origin main
B="$(new_repo)"; git -C "$B" remote add origin "$BARE"
git -C "$B" fetch -q origin; git -C "$B" reset -q --hard origin/main
printf 'other work\n' > "$B/other.txt"; git -C "$B" add other.txt
git -C "$B" commit -qm other --no-verify; git -C "$B" push -q origin main
printf '#!/usr/bin/env bash\nexec bash %s --push "$@"\n' "$HOOK" > "$A/.git/hooks/pre-push"
chmod +x "$A/.git/hooks/pre-push"
printf 'GITHUB_TOKEN = "%s"\n' "$GHP" > "$A/creds.sh"
git -C "$A" add creds.sh; git -C "$A" commit -qm "token" --no-verify
if OUT="$(git -C "$A" push --force origin main 2>&1)"; then
    bad "a force push over unfetched work was ALLOWED: $OUT"
else
    ok "a force push whose remote tip is unknown locally is refused"
fi
grep -q "git fetch" <<<"$OUT" \
    && ok "and the refusal names the fix (git fetch)" \
    || bad "refusal has no compliant path: $OUT"
if git -C "$BARE" log -p --all 2>/dev/null | grep -q "$GHP"; then
    bad "the token reached the remote anyway"
else
    ok "and nothing reached the remote"
fi

# 2. `--not --remotes` (ALL remotes) let a commit fetched from a second remote
#    be pushed to origin for the first time with zero commits enumerated.
O2="$(mktemp -d "$WORK/o2.XXXXXX")"; F2="$(mktemp -d "$WORK/f2.XXXXXX")"
git -C "$O2" init -q --bare; git -C "$F2" init -q --bare
FORKW="$(new_repo)"; git -C "$FORKW" remote add origin "$F2"
printf 'AWS_KEY = "%s"\n' "$AWS" > "$FORKW/creds.sh"
git -C "$FORKW" add creds.sh; git -C "$FORKW" commit -qm "fork token" --no-verify
git -C "$FORKW" push -q origin main
C="$(new_repo)"; git -C "$C" remote add origin "$O2"; git -C "$C" push -q origin main
printf '#!/usr/bin/env bash\nexec bash %s --push "$@"\n' "$HOOK" > "$C/.git/hooks/pre-push"
chmod +x "$C/.git/hooks/pre-push"
git -C "$C" remote add fork "$F2"; git -C "$C" fetch -q fork
git -C "$C" checkout -q -b feature fork/main
if OUT="$(git -C "$C" push origin feature 2>&1)"; then
    bad "a fork's commit was pushed to origin unscanned: $OUT"
else
    ok "a commit reachable only from ANOTHER remote is still scanned for this one"
fi
if git -C "$O2" log -p --all 2>/dev/null | grep -q "$AWS"; then
    bad "the fork's token reached origin"
else
    ok "and it did not reach origin"
fi

# 3. A conflict resolution lives ONLY in the merge commit's own diff, and
#    `--no-merges` skipped every merge.
R="$(push_repo)"
printf 'base\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -qm base --no-verify; git -C "$R" push -q origin main
git -C "$R" checkout -q -b theirs
printf 'theirs\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm theirs --no-verify
git -C "$R" checkout -q main
printf 'ours\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm ours --no-verify
git -C "$R" merge theirs >/dev/null 2>&1 || true
printf 'TOKEN = "%s"\n' "$GHP" > "$R/f"; git -C "$R" add f
git -C "$R" commit -qm "resolve the conflict" --no-verify >/dev/null 2>&1
[ "$(git -C "$R" rev-list --parents -1 HEAD | wc -w | tr -d ' ')" -eq 3 ] \
    && ok "fixture is a real MERGE commit (two parents)" \
    || bad "fixture is not a merge commit, so this case proves nothing"
refuses_push "$R" "a secret introduced by a merge's own conflict resolution is refused"

# 4. A content line that itself starts with `++` appears in the diff as
#    `+++TOKEN = ...`, which the `^\+\+\+` header filter dropped. Patch files
#    and diff fixtures hit this by accident; a credential can on purpose.
R="$(push_repo)"
printf '++TOKEN = "%s"\n' "$GHP" > "$R/leak.diff"
git -C "$R" add leak.diff
git -C "$R" commit -qm "a patch-shaped file" --no-verify
refuses_push "$R" "a token on a line starting with ++ is not mistaken for a diff header"

# The same shape in the PII half, which used the identical extraction.
R="$(push_repo)"
printf '++contact = "%s"\n' "$BADPHONE" > "$R/lead.diff"
git -C "$R" add lead.diff
git -C "$R" commit -qm "patch-shaped PII" --no-verify
refuses_push "$R" "and the PII half sees it too"
grep -qE "in commit [0-9a-f]{7}" <<<"$OUT" \
    && ok "the PII refusal names the COMMIT to rewrite" \
    || bad "PII refusal does not say which commit: $OUT"

# 5. `git show` honours DIFF ATTRIBUTES. A path marked `-diff` in a committed
#    .gitattributes diffs as "Binary files ... differ" with zero added lines,
#    so the scan saw nothing and called the commit clean. `*.min.js -diff` and
#    `*.lock -diff` are ordinary idioms, and a token in a lockfile was already
#    a real incident here. Index mode was never exposed: it greps the blob.
R="$(push_repo)"
printf '*.env -diff\n' > "$R/.gitattributes"
git -C "$R" add .gitattributes
git -C "$R" commit -qm "diff attributes" --no-verify
git -C "$R" push -q origin main
printf 'TOKEN = "%s"\n' "$GHP" > "$R/prod.env"
git -C "$R" add prod.env
git -C "$R" commit -qm "config" --no-verify
git -C "$R" show HEAD --format= -U0 | grep -q 'Binary files' \
    && ok "fixture really is hidden from a plain diff (Binary files ... differ)" \
    || bad "fixture does not reproduce the -diff attribute, so this proves nothing"
refuses_push "$R" "a -diff attribute does not hide a secret from the push scan"

# The same shape with NO .gitattributes at all: git auto-detects binary from a
# NUL in the first 8KB, which any generated file can carry.
R="$(push_repo)"
printf 'TOKEN = "%s"\n\0binary\n' "$GHP" > "$R/blob.dat"
git -C "$R" add blob.dat
git -C "$R" commit -qm "a generated blob" --no-verify
git -C "$R" show HEAD --format= -U0 | grep -q 'Binary files' \
    && ok "fixture is auto-detected as binary" \
    || bad "fixture is not auto-detected as binary"
refuses_push "$R" "and NUL-auto-detection does not hide one either"

# ═════════════════════════════════════════════════════════════════════════════
printf '== PUBLISHED-BY-DESIGN values are not credentials ==\n'
# Two patterns match "a secret-shaped NAME assigned a long hex value", which
# cannot tell a PRIVATE key from a PUBLIC one. Found by this guard's own live
# proof: watchdog-worker's signed-registry commit carries an Ed25519 pubkey as
# `"pubkey": "<64 hex>"`, matched because "pubkey" ends in "key". A pubkey MUST
# be in the repo for verification to work, so that refusal has no compliant fix
# and the only way past it is the bypass flag — the outcome this guard cannot
# survive.
#
# The exemption is NAME-scoped, applies only to those two patterns, and is
# consulted only after one of them has matched. The last two cases are the ones
# that matter: it must not become a shield.
PUBHEX="$(printf '8a88e3dd7409f195fd52db2d3cba5d72')$(printf 'ca6709bf1d94121bf3748801b40f6f5c')"

pub_case() {                    # <file> <content> <expect: block|allow> <label>
    local f="$1" content="$2" expect="$3" label="$4" r
    r="$(new_repo)"
    printf '%s\n' "$content" > "$r/$f"
    git -C "$r" add "$f"
    if [ "$expect" = block ]; then blocks "$r" "$label"; else allows "$r" "$label"; fi
}

pub_case f.json "{\"pubkey\": \"$PUBHEX\"}"      allow \
    "an Ed25519 pubkey in JSON is not a secret"
pub_case f.json "{\"public_key\": \"$PUBHEX\"}"  allow \
    "nor is public_key"
pub_case f.json "{\"token\": \"$PUBHEX\"}"       block \
    "a secret-shaped name with the SAME value still blocks"
pub_case f.json "{\"api_key\": \"$PUBHEX\"}"     block \
    "and so does api_key"
pub_case s.py   "SYSTEM_KEY = \"$PUBHEX\""       block \
    "and the uppercase assignment form"
# The abuse case: naming a field `pubkey` must not launder a real token. The
# format patterns never consult the allowlist.
pub_case f.json "{\"pubkey\": \"$GHP\"}"         block \
    "naming a field pubkey does NOT launder a ghp_ token"
# One public value and one real secret in the same file: not ALL matches are
# public, so it blocks.
pub_case f.json "{\"pubkey\": \"$PUBHEX\", \"token\": \"$PUBHEX\"}" block \
    "a pubkey next to a real secret still blocks"
# An earlier draft of PUBLIC_NAME allowed any name CONTAINING "public" and any
# name STARTING with a hash word. Both were too wide, and both are credentials
# with a reassuring name — the exact mistake the FUB key made ("public-ish, in
# repo already", six audits).
pub_case f.json "{\"public_api_token\": \"$PUBHEX\"}" block \
    "public_api_token is a credential, not a public value"
pub_case f.json "{\"hash_key\": \"$PUBHEX\"}" block \
    "an HMAC key in a field named hash_key is still a key"
pub_case f.json "{\"digest_key\": \"$PUBHEX\"}" block \
    "and a hash word does not launder a key suffix"
pub_case f.json "{\"publictoken\": \"$PUBHEX\"}" block \
    "a \"public token\" is a contradiction, so it blocks"
# Names a security reviewer named as real-world credentials, each of which an
# earlier draft of PUBLIC_NAME exempted because it matched pub/public or a hash
# word as a SUBSTRING anywhere in the name.
pub_case f.json "{\"publish_token\": \"$PUBHEX\"}" block \
    "publish_token (the NPM_PUBLISH_TOKEN shape) is a bearer secret"
pub_case f.json "{\"pubsub_api_key\": \"$PUBHEX\"}" block \
    "and a Google Pub/Sub api key is not a public key"
pub_case f.json "{\"digest_secret\": \"$PUBHEX\"}" block \
    "a hash word does not launder a secret suffix"
# The hash word may END the name — that is a hash OF something, not a key.

# The exemption must not be decided by a pipeline it exits early from. Round
# one of this file's SIGPIPE incident (2026-09-12) was a `grep -q` reader
# killing a `git show` producer; the first draft of all_matches_public rebuilt
# it one layer in, where the inverted status reads as "every match is public".
# A file whose FIRST match is a real secret followed by thousands of public
# ones is the shape that exercises it: the reader can exit while the producer
# is still writing.
R="$(new_repo)"
{
    printf '"api_key": "%s",\n' "$PUBHEX"
    i=0; while [ "$i" -lt 5000 ]; do printf '"pubkey_%s": "%s",\n' "$i" "$PUBHEX"; i=$((i+1)); done
} > "$R/big.json"
git -C "$R" add big.json
blocks "$R" "a real secret among thousands of public values still blocks (no early-exit judgement)"

# ── the exemption must be REACHABLE ─────────────────────────────────────────
# An earlier version of PUBLIC_NAME carried a second branch for hash/digest/
# fingerprint names. It could never fire: the patterns it guards require the
# name to END in key|secret|token, so `sha256`, `password_hash` and even
# `token_hash` never matched them in the first place — and four rows "proving"
# those names were exempt passed because NOTHING MATCHED, not because the
# exemption worked. An exemption that cannot fire is worse than none: it reads
# as considered coverage. So every name this list exempts must be one a guarded
# pattern actually matches.
PAT_JSON=$(sed -n "s/^PAT_NAME_HEX_JSON=//p" "$HOOK" | head -1); PAT_JSON=${PAT_JSON#\'}; PAT_JSON=${PAT_JSON%\'}
PAT_UPPER=$(sed -n "s/^PAT_NAME_HEX_UPPER=//p" "$HOOK" | head -1); PAT_UPPER=${PAT_UPPER#\'}; PAT_UPPER=${PAT_UPPER%\'}
PUB_LIST=$(sed -n "s/^PUBLIC_NAME=//p" "$HOOK" | head -1)
for nm in pubkey public_key myPublicKey; do
    line="{\"$nm\": \"$PUBHEX\"}"
    if printf '%s\n' "$line" | grep -qE -- "$PAT_JSON" || printf '%s\n' "$line" | grep -qE -- "$PAT_UPPER"; then
        ok "the exemption for '$nm' is reachable (a guarded pattern matches it)"
    else
        bad "'$nm' is exempted from a pattern that never matches it — dead allowlist entry"
    fi
done
# And the branch that was deleted must stay deleted: these names are not
# matched by the guarded patterns, so exempting them would be fiction.
for nm in sha256 password_hash token_hash host_pubkeys; do
    line="{\"$nm\": \"$PUBHEX\"}"
    if printf '%s\n' "$line" | grep -qE -- "$PAT_JSON"; then
        bad "'$nm' now matches a guarded pattern — it needs a real decision, not silence"
    else
        ok "'$nm' never matched a guarded pattern, so it needs no exemption"
    fi
done
printf '%s' "$PUB_LIST" | grep -qE 'fingerprint|checksum|digest|sha256|etag|hash' \
    && bad "the unreachable hash branch is back in PUBLIC_NAME" \
    || ok "PUBLIC_NAME carries only the reachable public-key branch"

# ═════════════════════════════════════════════════════════════════════════════
printf '== a chained pre-push.local gets what git would have given it ==\n'
# The ref list is the ONLY input a pre-push hook has, and this scanner's loop
# consumes it. Chaining without replaying it is worse than not chaining: the
# local hook runs, sees no refs and no remote, and approves. Same for argv —
# git calls pre-push as `<remote-name> <remote-url>`.
R="$(push_repo)"
cat > "$R/.git/hooks/pre-push.local" <<'LOCAL'
#!/usr/bin/env bash
# Records what it was handed, then approves.
printf 'argv=%s\n' "$*" > "$PWD/.git/chained.txt"
printf 'stdin=%s\n' "$(cat)" >> "$PWD/.git/chained.txt"
exit 0
LOCAL
chmod +x "$R/.git/hooks/pre-push.local"
printf 'clean work\n' > "$R/ok.txt"
git -C "$R" add ok.txt
git -C "$R" commit -qm "clean" --no-verify
pushes "$R" "a clean push still succeeds with a chained local hook"
if [ -f "$R/.git/chained.txt" ]; then
    ok "the chained hook actually ran"
else
    bad "the chained pre-push.local never ran"
fi
grep -q 'stdin=.*refs/heads' "$R/.git/chained.txt" 2>/dev/null \
    && ok "and received the REF LIST on stdin (replayed after our loop ate it)" \
    || bad "chained hook got an empty stdin: $(cat "$R/.git/chained.txt" 2>/dev/null)"
grep -q 'argv=origin ' "$R/.git/chained.txt" 2>/dev/null \
    && ok "and git's argv (remote name and url)" \
    || bad "chained hook got no argv: $(cat "$R/.git/chained.txt" 2>/dev/null)"
# And a chained hook that REFUSES must be able to stop the push.
R="$(push_repo)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/.git/hooks/pre-push.local"
chmod +x "$R/.git/hooks/pre-push.local"
printf 'clean\n' > "$R/ok.txt"
git -C "$R" add ok.txt
git -C "$R" commit -qm "clean" --no-verify
refuses_push "$R" "a chained hook's refusal still stops the push"
# The shapes that MUST stay exempt, beyond the plain `pubkey` above.
pub_case f.json "{\"myPublicKey\": \"$PUBHEX\"}" allow \
    "camelCase publicKey is exempt"

# ═════════════════════════════════════════════════════════════════════════════
printf '== PR #88 REVIEW: street/phone OCCURRENCE boundaries ==\n'
# `grep -nE` used to print the whole matching LINE and each `grep -viE`
# exclusion discarded that whole line, so a third-party address sharing a
# line with one of our own allowlisted values laundered through untouched.
# Fixed by switching to `grep -oE` (one occurrence per match) with the
# business exclusions anchored `^...$` against that single occurrence.
#
# These fixtures deliberately use the pre-existing "123 Main St" /
# "412-555-0142" (555-01xx) fixture values, NOT the Vintage Skins/office NAP
# values (the shop's own street address and phone number, spelled out
# plainly in the hook's own allowlist comments, deliberately not repeated
# here) that the actual anchored
# exclusions in the hook allowlist. The bug reproduces identically either
# way — the whole-line/consumed-boundary mechanism doesn't care WHICH
# allowlist entry is doing the laundering, generic fixture words are excluded
# by the exact same buggy whole-line/non-overlapping logic as the NAP values
# are. Using the generic ones here is a deployment-ordering constraint, not a
# test-quality one: this machine's currently-installed pre-commit hook has
# been redeployed from `main`, which does not carry the Covenant/Corporate/
# 226-4440 allowlist entries from #88's still-unmerged branch at all (main's
# street/phone checks have no business-NAP exemption whatsoever) — so a
# fixture spelling those literal values out, even correctly built at runtime
# via `$(printf …)` the way BADSTREET/BADPHONE/BADMAIL are, would itself read
# as real third-party PII to the currently-deployed guard and block this very
# commit. $BADSTREET/$BADPHONE are built at runtime (see file header) so this
# file's own diff never carries the unblocked literal form either way.
R="$(new_repo)"
printf 'shop="123 Main St"; client="%s"\n' "$BADSTREET" > "$R/lead.txt"
git -C "$R" add lead.txt
blocks "$R" "our own street + a third-party street on ONE line (own first) is blocked"

R="$(new_repo)"
printf 'client="%s"; shop="123 Main St"\n' "$BADSTREET" > "$R/lead.txt"
git -C "$R" add lead.txt
blocks "$R" "our own street + a third-party street on ONE line (own second) is blocked"

# The old exclusion had no left-side house-number boundary, so an unanchored
# substring match let a LARGER house number containing an allowlisted suffix
# through: 18878 contains 8878, 12100 contains 2100. The generic fixture words
# (Main/Elm/Oak) cannot reproduce it — they are word-boundary entries, and a
# larger number in front of "Main" is excluded by that list regardless — so
# the shape needs the NUMBER-anchored entries, which is why these four cases
# were deferred.
#
# The deferral reason was that writing those literals here would itself read
# as third-party PII to a main-based deployed hook and block this very commit.
# That is solved the same way $BADSTREET solves it: ASSEMBLE THEM AT RUNTIME,
# so no contiguous `<number> <Street> <Suffix>` ever appears in this file. The
# tests then run against the BRANCH hook under test, not the deployed one, and
# nothing has to wait for a deployment.
NAP_ST="8878 Cove""nant Ave"          # Vintage Skins' own published address
NAP_OFF="2100 Corpo""rate Drive"      # the Wexford broker office (49 Pa. Code 35.305(c))
NAP_PH="412-$(printf '226')-4440"     # Vintage Skins' own published line

# A larger house number on the same street is SOMEONE ELSE'S address.
R="$(new_repo)"
printf 'addr = "1%s"\n' "$NAP_ST" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a larger house number containing the Covenant allowlist suffix is blocked"

R="$(new_repo)"
printf 'addr = "1%s"\n' "$NAP_OFF" > "$R/crm.py"
git -C "$R" add crm.py
blocks "$R" "a larger house number containing the Corporate allowlist suffix is blocked"

# ...and the allowlist still does its job for the exact published values,
# which is the half that keeps branding work from teaching people --no-verify.
R="$(new_repo)"
printf 'shop = "%s"\n' "$NAP_ST" > "$R/about.md"
git -C "$R" add about.md
allows "$R" "the Vintage Skins shop address alone is allowed"

R="$(new_repo)"
printf 'phone = "%s"\n' "$NAP_PH" > "$R/about.md"
git -C "$R" add about.md
allows "$R" "the Vintage Skins shop phone alone is allowed"

# The phone boundary bug: `grep -o`'s non-overlapping scan consumed the ONE
# separator between two adjacent numbers along with the first match, so
# scanning resumed at the second number's first digit where a leading
# boundary can never match — the second number was never EXTRACTED, not
# merely allowlisted. Reproduced for EVERY one-character separator with the
# business number first; the reverse order was always fine, which is what
# made it look like a slash-specific quirk. Swept here so a fix that only
# special-cases `/` cannot pass. `412-555-0142` (555-01xx) stands in for the
# business-NAP number here too, same deployment-order reason as above; the
# consumed-boundary mechanism is identical regardless of which allowlisted
# number sits on the left.
for _sep in '/' ',' ';' ' ' '|' ':' '&' '+'; do
    R="$(new_repo)"
    printf 'contact = "412-555-0142%s%s"\n' "$_sep" "$BADPHONE" > "$R/lead.txt"
    git -C "$R" add lead.txt
    blocks "$R" "own then third-party phone, separator [$_sep], is blocked"

    R="$(new_repo)"
    printf 'contact = "%s%s412-555-0142"\n' "$BADPHONE" "$_sep" > "$R/lead.txt"
    git -C "$R" add lead.txt
    blocks "$R" "third-party then own phone, separator [$_sep], stays blocked"
done

# The directional-prefix fix (`([NSEW]\.? )?`) must keep matching a real
# address and must NOT start matching ordinary prose that happens to have a
# number followed by two capitalized words.
R="$(new_repo)"
printf 'address="4821 E %s Dr"\n' "$(printf 'Pinehurst')" > "$R/lead.txt"
git -C "$R" add lead.txt
blocks "$R" "a directional-prefixed third-party street address is blocked"

R="$(new_repo)"
printf '%s\n' '42 Bytes Read' > "$R/notes.md"
git -C "$R" add notes.md
allows "$R" "ordinary prose (42 Bytes Read) is not read as a street address"

R="$(new_repo)"
printf '%s\n' '100 E Commits Ahead' > "$R/notes.md"
git -C "$R" add notes.md
allows "$R" "ordinary prose (100 E Commits Ahead) is not read as a street address"

# The hook staged as its own content: it necessarily discusses its own
# allowlist values and pattern text in comments, and must not trip its own
# detectors.
R="$(new_repo)"
mkdir -p "$R/git-hooks"
cp "$HOOK" "$R/git-hooks/secret-scan-pre-commit.sh"
git -C "$R" add git-hooks/secret-scan-pre-commit.sh
allows "$R" "the hook staged as its own content is allowed"


# ═════════════════════════════════════════════════════════════════════════════
printf '== PR #87 RE-REVIEW: index-mode fail-open on a broken external diff driver ==\n'
# `pii_added_for_index` used to end `| added_lines || true`, discarding
# `git diff`'s own exit status. Any repo whose .gitattributes binds a file
# type to an external diff driver whose binary is missing gets `git diff
# --cached -U0` exit 128, and the pipeline still "succeeded" with an empty
# stream — every PII detector then concluded clean. The credential scan is
# UNAFFECTED here: it reads blobs directly via `git show :$FILE`, never a
# diff, so this fixture carries NO credential-shaped value on purpose — a
# credential in it would let the credential scan's unrelated BLOCKED line
# pass this case for the wrong reason. Confirmed against the byte-identical
# deployed fleet hook, 2026-09-16.
R="$(new_repo)"
git -C "$R" config diff.boom.command false
printf '*.txt diff=boom\n' > "$R/.gitattributes"
git -C "$R" add .gitattributes
git -C "$R" commit -qm "diff attributes"
printf 'addr="%s"; email="%s"; phone="%s"\n' "$BADSTREET" "$BADMAIL" "$BADPHONE" > "$R/lead.txt"
git -C "$R" add lead.txt
if (cd "$R" && git diff --cached -U0 >/dev/null 2>&1); then
    bad "fixture's own git diff --cached did not fail — this case proves nothing"
else
    ok "fixture reproduces a broken external diff driver (git diff --cached fails)"
fi
scan "$R"; RC=$?
[ "$RC" -ne 0 ] \
    && ok "a broken diff driver plus PII-only content (no credential) is BLOCKED in index mode" \
    || bad "a broken diff driver plus PII-only content was ALLOWED in index mode: $OUT"
printf '%s' "$OUT" | grep -qi 'diff' \
    && ok "the refusal names the diff failure" \
    || bad "the refusal does not mention the diff failure: $OUT"
printf '%s' "$OUT" | grep -qE 'STREET ADDRESS|PHONE NUMBER|EMAIL ADDRESS' \
    && bad "the refusal names a PII class instead of the diff failure: $OUT" \
    || ok "the refusal names the diff failure, not a PII class"

printf '\n-- push mode: the same class of broken driver is already refused --\n'
# `--text` (used by both scan_commit's read and pii_added_for_commit) forces
# an internal textual diff and bypasses a full `diff.<x>.command` override —
# proved directly: the index-mode fixture above, replayed through `git show
# --text -U0` instead of `git diff --cached -U0`, does NOT fail. It does NOT
# bypass a `diff.<x>.textconv` override, so that variant still breaks `git
# show <commit> --text -U0`. scan_commit's own read-status check (an earlier
# PR, unconditional per commit, no PII_EXCLUDES pathspec to narrow it) refuses
# the push before this branch's new pii_added_for_commit guard would ever
# run — this is proven below by asserting the SAME result against a copy of
# the pre-fix hook, not assumed. The new push-mode guard is still correct
# defense-in-depth (every extractor, both paths, per the fix) — it is just
# not the code path THIS particular mechanism reaches, so this case is a
# non-regression control, not a case this branch newly fixes.
R="$(push_repo)"
git -C "$R" config diff.boom.textconv /nonexistent/binary-does-not-exist
printf '*.txt diff=boom\n' > "$R/.gitattributes"
git -C "$R" add .gitattributes
git -C "$R" commit -qm "diff attributes" --no-verify
printf 'addr="%s"; email="%s"; phone="%s"\n' "$BADSTREET" "$BADMAIL" "$BADPHONE" > "$R/lead.txt"
git -C "$R" add lead.txt
git -C "$R" commit -qm "lead, PII only, no credential shape" --no-verify
if git -C "$R" show HEAD --text -U0 --format= >/dev/null 2>&1; then
    bad "fixture's own git show --text -U0 did not fail — this case proves nothing"
else
    ok "fixture reproduces a broken textconv driver (git show --text -U0 fails)"
fi
refuses_push "$R" "a broken textconv driver plus PII-only content is refused in push mode"
printf '%s' "$OUT" | grep -qE 'STREET ADDRESS|PHONE NUMBER|EMAIL ADDRESS' \
    && bad "the push refusal names a PII class instead of the read failure: $OUT" \
    || ok "the push refusal does not name a PII class (existing read-failure guard)"

# ═════════════════════════════════════════════════════════════════════════════
printf '== PR #88 AWK REWRITE: a multibyte byte must not blind the phone scanner ==\n'
# The occurrence-boundary fix above needed an awk scanner (`grep -o`'s
# non-overlapping match cannot do a non-consuming boundary check, which IS
# the separator bug) — but the pre-awk `grep -oE` phone extractor never had a
# multibyte problem; grep decodes it without crashing. The awk rewrite
# carried a NEW fail-open in with it: BWK awk decodes `length`/`substr`
# through the process locale, and en_US.UTF-8 makes it die with `towc:
# multibyte conversion failure` on ANY multibyte byte in the scanned text —
# including an ordinary em dash in this hook's OWN comments a line or two
# above a real phone number. A dead awk prints nothing and the exclusion
# greps see an empty stream, which read as clean. Fixed with `LC_ALL=C`
# (byte-oriented; this pattern only ever matches ASCII, so no real phone
# number can be skipped) plus `judge_pipeline` failing closed on awk's own
# nonzero exit. Caught by measuring the rewrite against this exact fixture
# before commit, not by reading the diff — this bug never reached
# origin/fix/pii-guard-own-nap-and-doi or the deployed fleet hook; it lived
# only inside this branch's own development between the finding-2 fix and
# this one. Kept as a permanent case anyway: without it, the exact same
# regression can come back the next time someone touches this pipeline, and
# the suite would report green while the hook silently scans nothing, same
# as it did here.
R="$(new_repo)"
printf 'prose with an em dash %s here\nphone=%s\n' "$(printf '\xe2\x80\x94')" "$BADPHONE" > "$R/lead.txt"
git -C "$R" add lead.txt
scan "$R"; RC=$?
[ "$RC" -ne 0 ] \
    && ok "a multibyte byte plus a real phone number is BLOCKED (was silently allowed)" \
    || bad "a multibyte byte plus a real phone number was ALLOWED: $OUT"
printf '%s' "$OUT" | grep -qE 'STREET ADDRESS|EMAIL ADDRESS' \
    && bad "the refusal names an unrelated PII class: $OUT" \
    || ok "the refusal correctly attributes to the phone check, not another class"

R="$(new_repo)"
printf 'prose with an em dash %s here, nothing else\n' "$(printf '\xe2\x80\x94')" > "$R/notes.md"
git -C "$R" add notes.md
allows "$R" "a multibyte byte alone (no PII) is not itself a finding (no false positive)"

printf '\n== judge_pipeline: every non-printf stage is judged, not just the last one ==\n'
# Direct unit test of the shared helper (same extraction technique this file
# already uses for PAT_JSON/PUB_LIST below): hand-checking index 1 (awk) and
# the last index only, as the first cut of the multibyte fix did, left the
# FIRST exclusion grep (index 2 in the phone pipeline) unjudged. If it exits
# 2+, its output is empty, the last grep then sees nothing and legitimately
# exits 1 ("nothing survived"), and pipefail reports that rightmost nonzero 1
# — clean — while the real 2+ that caused it is invisible. `judge_pipeline`
# loops every stage so this and any future stage cannot go unjudged.
JP_SRC=$(awk '/^judge_pipeline\(\) \{/,/^}/' "$HOOK")
[ -n "$JP_SRC" ] && eval "$JP_SRC"
if ! declare -f judge_pipeline >/dev/null; then
    bad "judge_pipeline not found in $HOOK — the extraction pattern drifted from the source"
else
    ok "judge_pipeline extracted from the hook for direct testing"
    jp_case() {              # <label> <expect: block|allow> <strict> <codes...>
        local label="$1" expect="$2"; shift 2
        local out got
        if out=$(judge_pipeline "test" "PHONE NUMBER" "$@" 2>&1); then got=block; else got=allow; fi
        if [ "$got" = "$expect" ]; then
            ok "$label"
        else
            bad "$label (got=$got want=$expect): $out"
        fi
    }
    # stage0=printf(0, skipped) stage1=awk(0, ok) stage2=first exclusion grep
    # stage3=last exclusion grep. strict=1 (awk is the extractor).
    jp_case "stage 2 errors, stage 3 looks clean -> BLOCK (the gap this closes)" block 1 0 0 2 1
    jp_case "every stage clean/no-match -> ALLOW (no false positive)" allow 1 0 0 1 1
    jp_case "last stage finds a survivor (0) -> BLOCK" block 1 0 0 1 0
    jp_case "the extractor stage itself errors -> BLOCK" block 1 0 2 1 1
    jp_case "the last stage itself errors -> BLOCK" block 1 0 0 1 2
    # strict=0 is the street call's "no extractor stage" sentinel, valid only
    # because the loop starts at i=1 and stage 0 is always printf.
    jp_case_street() {
        local label="$1" expect="$2"; shift 2
        local out got
        if out=$(judge_pipeline "test" "STREET ADDRESS" 0 "$@" 2>&1); then got=block; else got=allow; fi
        if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label (got=$got want=$expect): $out"; fi
    }
    jp_case_street "street pipeline: all-grep, every stage clean -> ALLOW" allow 0 1 1 1 1
    jp_case_street "street pipeline: an exclusion grep errors -> BLOCK" block 0 1 2 1 1
fi

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
