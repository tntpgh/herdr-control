#!/usr/bin/env bash
# Shared git pre-commit secret guard — the free local substitute for GitHub push
# protection, which is unavailable on private repos without paid Secret Protection
# (verified 2026-07-30: PATCH accepted, status stayed "disabled").
#
# Origin: promoted from ~/Code/knowledge-base/.git/hooks/pre-commit, which already
# did this well. Installed into every repo's .git/hooks/pre-commit as a one-line
# caller, so fixes here take effect everywhere at once. Worktrees inherit it
# automatically (they share the main repo's hooks dir).
set -euo pipefail

# The filter EXCLUDES deletions and nothing else, on purpose. It used to be an
# allow-list of status letters, and the letter nobody thought of was the hole,
# twice:
#
#   ACM  -> `git mv` a file that stays similar enough for rename detection and
#           append a token: the change records as one rename (R096 in the
#           probe), the list comes back EMPTY, and the hook scans nothing while
#           the token lands. Proved 2026-09-12. Conditional — a small file
#           records as D+A, which ACM does catch — which is why it survived.
#   ACMR -> replace a SYMLINK with a regular file carrying a credential: the
#           change records as `T` (typechange) and the list comes back EMPTY
#           again. Proved 2026-09-15 in a throwaway repo with no hooks path:
#           `git diff --cached --name-status` showed `T link.sh`,
#           `--diff-filter=ACMR` printed nothing, the scanner exited 0, and the
#           staged content held a live-shaped 40-char ghp_ token. The same
#           shape as the rename hole, one letter over.
#
# So: `d` (lower-case = EXCLUDE) drops only D, and every present-or-future
# status letter (A C M R T U X B) is scanned by default. A detection control
# must fail toward scanning; deletions are the one class that cannot carry
# staged content — and `git show ":$path"` on a deleted path fails, which would
# trip the unreadable-file refusal below and block every commit that deletes
# something. Never mix cases in one filter: `--diff-filter=Ad` is rejected.
#
# ONE constant, three call sites. Three literals that must agree is the real
# defect: this early `exit 0` disagreeing with the scan loop's own filter is
# exactly how an empty list becomes a silent pass. verify-secret-scan.sh greps
# for any `--diff-filter=` in this file that is not "$DIFF_FILTER".
DIFF_FILTER=d
# ── what this scans: the INDEX, or a pushed RANGE ────────────────────────────
# `pre-commit` and `pre-merge-commit` are the only hooks git runs when a commit
# is CREATED by `git commit`. They are not run by:
#
#   git am              (runs applypatch-msg / pre-applypatch / post-applypatch)
#   git cherry-pick     (no commit-creation hook at all)
#   git revert          (same)
#   git rebase          (same, for every commit it replays)
#
# So every one of those paths wrote commits this guard never read. `git am` of
# a patch carrying a credential, or a cherry-pick of a commit made in a repo
# whose hooks were not installed, landed unscanned — and the fleet has no
# GitHub push protection to catch it on the far side (private repos, paid
# feature, verified 2026-07-30).
#
# `--push` closes the class rather than the cases: whatever created a commit,
# it has to be pushed to leave this machine. Hooked to `pre-push`, this reads
# git's stdin protocol (`<local ref> <local sha> <remote ref> <remote sha>`)
# and scans every commit being sent that the remote does not already have.
#
# Two deliberate differences from index mode, both because the subject is
# different:
#
#   * It scans ADDED LINES per commit, not file content at the tip. A secret
#     added in one commit and removed in a later one is still in the history
#     being published — reading only the tip would call that clean.
#   * It does NOT check author identity. In the index the fix is `git config`
#     plus `--amend`; in a range the offending commits may be years old and
#     already public (knowledge-base carries 648 commits attributed to another
#     account), so enforcing it here would block every push of that branch
#     forever, with no compliant path. A guard with no compliant path gets
#     bypassed, which costs more than the drift it was watching.
SCAN_MODE=index
if [[ "${1:-}" == "--push" ]]; then SCAN_MODE=push; fi

if [[ "$SCAN_MODE" == index ]]; then
    STAGED=$(git diff --cached --name-only --diff-filter="$DIFF_FILTER" 2>/dev/null)
    [[ -z "$STAGED" ]] && exit 0
fi

# ── commit identity ──────────────────────────────────────────────────────────
# Every repo here belongs to the `tntpgh` GitHub account, so every commit must
# be authored as tnt@teamthurber.com. Checked here because the global config
# being right is NOT sufficient: a per-repo `user.email` silently overrides it,
# and no document can catch that.
#
# Found 2026-09-04: ~/Code/knowledge-base carried a local override of
# `thurbs@users.noreply.github.com`, which is the noreply address of a DIFFERENT
# GitHub account, so 648 of its commits are attributed there instead of tntpgh.
# Its worktrees (including kb-deploy) inherited it, because worktrees share the
# main repo's config. Nothing surfaced it for months; `git log` shows a name, and
# the name was already "tntpgh".
#
# Runs before the secret scan on purpose: attribution is cheap to check and the
# fix is one command, so there is no reason to make someone wait for a full
# content scan to be told their identity is wrong.
# Index mode only — see the SCAN_MODE header for why a pushed range cannot
# enforce this without becoming unbypassable.
WANT_EMAIL="tnt@teamthurber.com"
HAVE_EMAIL="$(git config user.email || true)"
if [[ "$SCAN_MODE" == index && "$HAVE_EMAIL" != "$WANT_EMAIL" ]]; then
    echo "BLOCKED: commit author email is '${HAVE_EMAIL:-<unset>}', expected '$WANT_EMAIL'."
    echo "  Every repo here is under the tntpgh GitHub account; a different address"
    echo "  attributes the commit to another account and cannot be corrected later"
    echo "  without rewriting history."
    echo ""
    echo "  Fix (usually a stale per-repo override shadowing a correct global):"
    echo "    git config --local --unset user.email   # then re-check: git var GIT_AUTHOR_IDENT"
    echo ""
    echo "  If a different identity is genuinely intended, commit with --no-verify"
    echo "  and say so out loud."
    exit 1
fi

# Patterns that indicate a hardcoded secret (not an op:// reference)
PATTERNS=(
    'AIzaSy[A-Za-z0-9_-]{33}'                          # Google API keys
    'AKIA[0-9A-Z]{16}'                                 # AWS access key IDs
    'sk-[A-Za-z0-9]{32,}'                              # OpenAI / Anthropic API keys (no-hyphen variant)
    'sk-(ant|proj)-[A-Za-z0-9_-]{20,}'                 # Anthropic / OpenAI project keys (hyphenated variant — the
                                                        # plain sk- pattern above requires 32+ chars with NO hyphens,
                                                        # so sk-ant-api03-... / sk-proj-... slip past it untouched)
    'eyJ[A-Za-z0-9_-]{100,}\.[A-Za-z0-9_-]{20,}'       # JWT tokens
    'service_role\s*=\s*["\x27][A-Za-z0-9_\-\.]{30,}'  # Supabase service role keys
    'ops_eyJ[A-Za-z0-9_-]{50,}'                        # 1Password service-account token (vault-wide!)
    'cfut_[A-Za-z0-9]{30,}'                            # Cloudflare API token
    'gh[pousr]_[A-Za-z0-9]{36,}'                        # GitHub PAT (classic)
    'github_pat_[A-Za-z0-9_]{50,}'                     # GitHub PAT (fine-grained)
    'xox[abposr]-[A-Za-z0-9-]{10,}'                    # Slack bot/user/... tokens
    'xapp-[0-9]-[A-Za-z0-9]+-[0-9]+-[a-f0-9]{32,}'     # Slack APP-level token (xapp-1-...) — a distinct shape
                                                        # from xoxb-/xoxp-, not covered by the xox[abposr]- pattern
    'sk_live_[A-Za-z0-9]{20,}'                         # Stripe live secret key
    '-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----'          # SSH / PGP / PEM private key headers (RSA, OPENSSH, EC,
                                                        # DSA, PGP PRIVATE, and a bare PRIVATE KEY, all in one)
    'fka_[A-Za-z0-9]{30,}'                             # Follow Up Boss API key. Added 2026-09-03 after a LIVE one
                                                        # (verified: /v1/identity -> 200) was found committed in two
                                                        # repos and had sat in history since 2026-07-13. FUB holds all
                                                        # client PII, so this is the highest-consequence shape here —
                                                        # and it was the one shape this guard could not see.
    '(SYSTEM_KEY|WEBHOOK_KEY|SIGNING_KEY|API_KEY|SECRET|TOKEN)[A-Z_]*\s*[=:]\s*["\x27]?[a-f0-9]{32,}'
                                                        # A bare 32+ hex value ASSIGNED to a secret-shaped name. Bare
                                                        # hex alone is unusable as a pattern (git SHAs, md5sums,
                                                        # content hashes) — requiring the assignment target to look
                                                        # like a credential is what makes it precise. Added with the
                                                        # above: a committed FUB X-System-Key of exactly this shape
                                                        # survived six audits, partly because a source comment called
                                                        # it "public-ish, in repo already".
    '["\x27][A-Za-z0-9_-]*([Kk]ey|[Ss]ecret|[Tt]oken)["\x27]\s*:\s*["\x27][a-f0-9]{32,}'
                                                        # Same value, JS/JSON/YAML object form:
                                                        #   "X-System-Key": "<32 hex>"
                                                        # The uppercase assignment pattern above catches the Python
                                                        # `NAME = "hex"` shape but NOT this one — proven 2026-09-03,
                                                        # when the guard flagged 1 of the 6 files holding the same
                                                        # committed FUB key and missed the four JS/TOML/JSON ones.
)

# Binary and generated formats only. `lock` was in this list until 2026-09-09,
# which made the PII-exclusion comment below FALSE where it mattered: it says
# "the credential scan still walks every staged file, lockfiles included", but
# `*.lock` was skipped here, so a token in yarn.lock was never read. Proven on
# a real negative — a ghp_ token staged in yarn.lock was ALLOWED, the same
# token in wrangler.toml was blocked. Lockfiles are text, they are greppable,
# and they legitimately carry registry URLs that can embed credentials
# (https://user:token@registry/...), so they get scanned like anything else.
# package-lock.json was always scanned — it ends in .json — which is exactly
# how inconsistent this was.
SKIP_EXT='\.(pyc|pyo|pyd|png|jpg|jpeg|gif|svg|ico|pdf|woff2?|eot|ttf|otf|zip|tar|gz|bin)$'

FOUND=0

# ── push mode ────────────────────────────────────────────────────────────────
# Reached only from `pre-push`. Scans the ADDED LINES of every commit being
# sent that the remote does not already have, with the same PATTERNS above —
# one pattern list, two content sources, so a pattern fixed for commits is
# fixed for pushes in the same edit.
if [[ "$SCAN_MODE" == push ]]; then
    PUSH_FOUND=0
    scan_commit() {
        local c="$1" added st
        # -U0: added lines only. `--format=` suppresses the log header, whose
        # own subject/body text would otherwise be scanned as content — a
        # commit MESSAGE mentioning a token shape is not a committed secret,
        # and blocking on it has no compliant fix short of rewriting history.
        added=$(git show "$c" -U0 --format= --diff-filter="$DIFF_FILTER" 2>/dev/null \
                | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^\+//' || true)
        [[ -z "$added" ]] && return 0
        local pattern
        for pattern in "${PATTERNS[@]}"; do
            set +e +o pipefail
            printf '%s\n' "$added" | grep -qE -- "$pattern"
            st=("${PIPESTATUS[@]}")
            set -e -o pipefail
            if [ "${st[1]}" -eq 0 ]; then
                # The commit, not just the pattern: in a range the operator
                # needs to know WHICH commit to rewrite, and `git log --oneline`
                # on a sha is the next command either way.
                echo "BLOCKED: potential secret in commit $(git log -1 --format='%h %s' "$c" 2>/dev/null || echo "$c")"
                echo "         (pattern: $pattern)"
                PUSH_FOUND=1
            elif [ "${st[1]}" -gt 1 ]; then
                # Same reasoning as the index loop: a scanner that cannot run
                # its own pattern has not cleared anything.
                echo "BLOCKED: grep failed on commit $c (exit ${st[1]}, pattern: $pattern) —" >&2
                echo "  refusing to treat an unscannable commit as clean." >&2
                PUSH_FOUND=1
            fi
        done
    }
    # git's pre-push protocol: one line per ref, on stdin.
    PUSH_COMMITS=""
    while read -r _lref lsha _rref rsha; do
        # A deleted ref pushes nothing. `git push --delete` sends an all-zero
        # LOCAL sha; scanning it would resolve to nothing and, worse, an
        # unguarded `$lsha..` range would silently mean "everything".
        [[ -z "${lsha:-}" || "$lsha" =~ ^0+$ ]] && continue
        range=""
        if [[ -z "${rsha:-}" || "$rsha" =~ ^0+$ ]]; then
            # A NEW branch on the remote. The range is not `$lsha` alone —
            # that is the branch's entire history back to the root, so the
            # first push of any branch would rescan years of commits and
            # block on anything historical, with no compliant path. Exclude
            # everything the remote already has.
            range=$(git rev-list --no-merges "$lsha" --not --remotes 2>/dev/null || true)
        else
            range=$(git rev-list --no-merges "$rsha..$lsha" 2>/dev/null || true)
        fi
        for commit in $range; do
            scan_commit "$commit"
            PUSH_COMMITS="$PUSH_COMMITS $commit"
        done
    done
    # The PII checks are shared: this falls through to them with the pushed
    # commits in PUSH_COMMITS, rather than carrying a second copy of three
    # regexes that would drift from the index copy. The index file-walk and
    # `git diff --cached` below are skipped — on a push, whatever happens to
    # be staged is unrelated to what is being sent.
fi

if [[ "$SCAN_MODE" == index ]]; then
# NUL-delimited, not `for FILE in $STAGED` — an unquoted word-split loop
# silently skips (git show falls through 2>/dev/null into "no output") any
# staged path containing whitespace, which is a general bypass: stage a
# secret in a file literally named "with space name.txt" and this hook
# never looks at it. `-z` + `read -r -d ''` can't be split by anything.
while IFS= read -r -d '' FILE; do
    [[ "$FILE" =~ $SKIP_EXT ]] && continue

    # Readability is a property of the FILE, not of a pattern. Checking it
    # inside the pattern loop printed the same refusal 17 times for one corrupt
    # blob, plus 17 lines of git's own stderr — and the operator-facing message
    # is the thing that has to survive: the rename and SIGPIPE bypasses both
    # hid behind output nobody read.
    set +e
    git show ":$FILE" >/dev/null 2>&1
    _rd=$?
    set -e
    if [ "$_rd" -ne 0 ]; then
        echo "UNREADABLE: could not read staged $FILE (git show exit $_rd) —" >&2
        echo "  refusing to treat an unreadable file as clean." >&2
        FOUND=1
        continue
    fi

    for PATTERN in "${PATTERNS[@]}"; do
        # Inspect BOTH exit codes, because `set -o pipefail` (line 10) turns a
        # successful match into a miss on any file bigger than the pipe buffer.
        #
        # `grep -q` exits the instant it matches. `git show` is then killed by
        # SIGPIPE (141), pipefail adopts 141 as the pipeline's status, the `if`
        # reads FALSE, and FOUND is never set. Measured 2026-09-12: a `ghp_`
        # token on line 1 of a 7 MB file was ALLOWED (rc=0) while the same
        # token at the BOTTOM of the same file was BLOCKED — 16 KB blocks,
        # 64 KB and up allow. Minified bundles, lockfiles, CSVs, JSON dumps,
        # SQL fixtures: any generated text file over 64 KB was a free pass, and
        # unlike the rename bypass it needs no `git mv`, just a large file.
        #
        # So: run the pipeline with pipefail OFF and judge the statuses
        # separately. `set +e` as well, because outside an `if` condition a
        # clean no-match (grep 1) is a failing command and errexit would abort
        # the hook — which reads as "blocked" and flags every clean large file.
        # Capture both statuses in the SAME statement; any simple command in
        # between resets PIPESTATUS.
        set +e +o pipefail
        git show ":$FILE" | grep -qE -- "$PATTERN"
        _st=("${PIPESTATUS[@]}")
        set -e -o pipefail
        if [ "${_st[1]}" -eq 0 ]; then
            echo "BLOCKED: potential secret in $FILE  (pattern: $PATTERN)"
            FOUND=1
        elif [ "${_st[1]}" -gt 1 ]; then
            # grep 0 = match, 1 = clean, ANYTHING ELSE is an error — most
            # likely a pattern valid in GNU ERE but not the BSD grep this
            # fleet runs, which would make grep exit 2 for every file and
            # every pattern and silently scan NOTHING. Judging only `-eq 0`
            # conflated that with "clean", which is precisely the
            # status-conflation this fix was opened to remove — committed in
            # its own new lines, one field over.
            echo "BLOCKED: grep failed on $FILE (exit ${_st[1]}, pattern: $PATTERN) —" >&2
            echo "  a scanner that cannot run its own pattern has not cleared this file." >&2
            FOUND=1
        fi
    done
done < <(git diff --cached -z --name-only --diff-filter="$DIFF_FILTER" 2>/dev/null)
fi

# ── client PII ───────────────────────────────────────────────────────────────
# Credentials were never the bigger body. A 2026-09-03 audit found 1,409
# identities / 678 emails / 734 phones in knowledge-base history, plus 72 real
# client street addresses still at the tip — in test fixtures, in
# server/entity_graph.py, and in a tracked connectors/*.json. 32 of a 40-value
# sample matched live entities in the production graph. This is a real-estate
# brokerage, so that is fiduciary exposure, and no credential pattern sees it.
#
# Scoped to ADDED lines only (`git diff --cached -U0` then `^+`). Scanning whole
# files would fire on every pre-existing value in every commit that touches
# those files, which is how a check like this gets disabled in a week.
#
# Synthetic values are allowed on purpose: 555-01xx is reserved for fiction,
# example.com/.org/.net by RFC 2606, and Main/Elm/123-style streets are the
# local fixture convention. Use those in tests and this never fires.
PII_FOUND=0
# Public MLS listing artifacts are marketing content, not client PII: the
# site PUBLISHES these addresses (tntpgh-dev listing pipeline data). Client
# PII never lives in these paths; everything else still gets scanned.
#
# Same argument for the tourguide worker's TEAM_AGENTS_JSON (2026-09-06): it is
# OUR OWN licensed agents' published contact details — the identical roster is
# on teamthurber.com and already tracked in wrangler.toml — and the file cannot
# reference anything external, so the roster has to be inline. Excluding it
# relaxes the PII checks ONLY: the credential scan above walks every staged
# file independently of $ADDED, so a token pasted here is still blocked
# (proven on a real negative, 2026-09-06).
# ONE exclusion list, used by both content sources (the index here, a pushed
# commit in push mode). Two copies of a pathspec is how the modes come to
# disagree about what counts as client PII.
PII_EXCLUDES=(
    -- .
    ':(exclude)src/data/propx-*.json'
    ':(exclude)src/data/price-band-evidence.json'
    ':(exclude)src/data/sold-subdivision-context.json'
    ':(exclude)cloudflare/worker/wrangler*.toml'
    ':(exclude)**/package-lock.json' ':(exclude)package-lock.json'
    ':(exclude)**/yarn.lock' ':(exclude)**/pnpm-lock.yaml'
)
if [[ "$SCAN_MODE" == push ]]; then
    # The same added lines, from the commits being pushed. Client PII reaching
    # the remote is the higher-consequence half of this hook (a 2026-09-03
    # audit found 1,409 identities in knowledge-base history), and `git am`,
    # `cherry-pick`, `revert` and every `rebase` replay reach the remote
    # without ever running a commit-creation hook. Only commits the remote
    # does not already have are in PUSH_COMMITS, so this cannot fire on
    # published history and become unbypassable.
    ADDED=""
    for _c in $PUSH_COMMITS; do
        ADDED="$ADDED
$(git show "$_c" -U0 --format= --diff-filter="$DIFF_FILTER" "${PII_EXCLUDES[@]}" 2>/dev/null \
  | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^\+//' || true)"
    done
else
    ADDED="$(git diff --cached -U0 --diff-filter="$DIFF_FILTER" \
             "${PII_EXCLUDES[@]}" 2>/dev/null \
             | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^\+//' || true)"
fi
# Lockfiles are excluded from the PII checks only. npm records each package
# MAINTAINER's address (maintainer@example.com and friends), published metadata, not
# client PII, and it arrives whenever a dependency is added. Blocking it teaches
# people to reach for --no-verify on an ordinary `npm install`, which is exactly
# how a real secret gets through. The credential scan still walks every staged
# file, lockfiles included.

# The diff marker is stripped HERE, once, rather than worked around per check.
# Left in place it becomes the local part of an address: a decorator line like
# @pytest.mark.parametrize acquires the marker as a prefix, and the result parses
# as an email whose domain is pytest.mark.parametrize and whose TLD is
# "parametrize" -- not in the allowlist, so every commit adding a parametrized
# test was BLOCKED as a third-party email.
#
# That has no compliant path. You cannot stop using decorators, so the only way
# past it is --no-verify, which is how a guard stops guarding.
#
# The street check below still carries its own marker workaround for the same
# root cause. knowledge-base/scripts/scan_diff.py strips the marker and this did
# not, which is how the two implementations came to disagree on one diff.
if [[ -n "$ADDED" ]]; then
    # street address: <number> <Name> <suffix>, excluding the fixture words
    if printf '%s\n' "$ADDED" \
       | grep -nE '[0-9]{2,5} [A-Z][a-z]+( [A-Z][a-z]+)? (Dr|Rd|St|Ave|Ct|Ln|Way|Blvd|Road|Street|Drive|Avenue|Court|Lane)\b' \
       | grep -viE '\b(Main|Elm|Oak|Test|Example|Fake|Sample|Anywhere|Nowhere|Maple|Pine|First|Second|Foo|Bar)\b' \
       | grep -vE '^\+?[0-9]*:?\+?(123|456|789|1234|100|111|999) ' >/dev/null; then
        echo "BLOCKED: a real-looking STREET ADDRESS is being added."
        PII_FOUND=1
    fi
    # phone: not the 555-01xx fiction range
    if printf '%s\n' "$ADDED" \
       | grep -E '(\+?1[-. ]?)?\(?[0-9]{3}\)?[-. ][0-9]{3}[-. ][0-9]{4}' \
       | grep -vE '555[-. ]?01[0-9][0-9]' >/dev/null; then
        echo "BLOCKED: a real-looking PHONE NUMBER is being added."
        PII_FOUND=1
    fi
    # email: not a reserved/example domain, and not our own team domain
    # *.gserviceaccount.com is a Google SERVICE ACCOUNT identity — a machine
    # principal that has to be written down to be granted access, not a person.
    # It is not client PII and blocking it only pushes it into a --no-verify.
    # Exact synthetic URL-userinfo fixture, not an email identity; keep other subdomain addresses blocked.
    #
    # The gserviceaccount entries were written as `iam\.gserviceaccount\.com`
    # anchored right after the @, which no real service account matches: they
    # are always `<name>@<project-id>.iam.gserviceaccount.com`. So the allowlist
    # never fired and the exemption it documents did not exist (proven
    # 2026-09-09: kb@proj.iam.gserviceaccount.com was BLOCKED). Allow the
    # project-id label explicitly, and only for that domain.
    # `([A-Za-z0-9-]+\.)*example\.(com|org|net)`: RFC 2606 reserves example.com
    # AND everything beneath it, so db.example.com is exactly as synthetic as
    # example.com. Anchoring at the bare domain blocked a test fixture using
    # user:pw@db.example.com (2026-09-09) — the same subdomain mistake as the
    # gserviceaccount entry a few hours earlier. Twice in one day for this
    # pattern shape: when allowlisting a reserved domain, allow its subdomains.
    # Each alternative is anchored with `$`: `grep -o` emits one address per
    # line, so an unanchored `@teamthurber\.com` also matched
    # an address whose allowlisted domain was followed by more labels (two-model review, 2026-09-09).
    # `test\.` and `localhost`/`invalid` are RFC 2606/6761 reserved and stay
    # prefix/word matches on purpose. vintageskins.com and weizenyoung.com are
    # our own client-business domains (Lisa's shop; the family), not third
    # parties — that is why they are exempt.
    if printf '%s\n' "$ADDED" \
       | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
       | grep -viE '@(([A-Za-z0-9-]+\.)*example\.(com|org|net)$|test\.|localhost$|invalid$|teamthurber\.com$|vintageskins\.com$|weizenyoung\.com$|users\.noreply\.github\.com$|([A-Za-z0-9-]+\.)?(developer|iam)\.gserviceaccount\.com$)|^secret@dashboard\.teamthurber\.com$' >/dev/null; then
        echo "BLOCKED: a third-party EMAIL ADDRESS is being added."
        PII_FOUND=1
    fi
fi

# One verdict per mode, so the advice matches what the operator can actually
# do: an index finding is fixed by editing the file before committing, a push
# finding needs the credential rotated FIRST — it is already in local history
# and a rewrite does not un-leak anything that was already pushed.
if [[ "$SCAN_MODE" == push ]]; then
    if [[ $PII_FOUND -ne 0 ]]; then
        echo ""
        echo "Push blocked: a commit being pushed adds client PII, and pushing"
        echo "publishes it to every future clone."
        echo "  fixtures: use 555-0100..555-0199, someone@example.com, 123 Main St"
        echo "  real data: keep it in the DB or a gitignored path"
        echo "  rewrite the commit (git rebase -i <sha>^), do not push past this"
        echo "If this is genuinely synthetic, extend the allowlist in this hook."
        exit 1
    fi
    if [[ ${PUSH_FOUND:-0} -ne 0 ]]; then
        echo ""
        echo "Push blocked: the commits above carry a hardcoded secret, and"
        echo "pushing publishes history — a rewrite afterwards is not a fix,"
        echo "the credential is already out."
        echo "  rotate at the provider FIRST, then rewrite the commit:"
        echo "    git rebase -i <sha>^     # edit it out, then push again"
        echo "  store the new value in 1Password and reference it via op://"
        echo "If this is a false positive, extend PATTERNS in this hook rather"
        echo "than using --no-verify, so the next person is protected too."
        exit 1
    fi
    # Chain to a repo-specific pre-push hook if one exists.
    if [[ -x "$(git rev-parse --git-path hooks/pre-push.local 2>/dev/null)" ]]; then
        exec "$(git rev-parse --git-path hooks/pre-push.local)"
    fi
    exit 0
fi

if [[ $PII_FOUND -ne 0 ]]; then
    echo ""
    echo "Commit blocked: client PII in a tracked file is permanent — gitignore"
    echo "never untracks, and history reaches every future clone."
    echo "  fixtures: use 555-0100..555-0199, someone@example.com, 123 Main St"
    echo "  real data: keep it in the DB or a gitignored path, never in a commit"
    echo "If this is genuinely synthetic, extend the allowlist in this hook rather"
    echo "than using --no-verify, so the next person is protected too."
    exit 1
fi

if [[ $FOUND -ne 0 ]]; then
    echo ""
    echo "Commit blocked: review the files above and remove hardcoded secrets."
    echo "Store credentials in 1Password and reference via op:// in .env.op."
    echo "If this is a false positive, commit with --no-verify and say so out loud."
    exit 1
fi

# Chain to a repo-specific hook if one exists, so local checks still run.
if [[ -x "$(git rev-parse --git-path hooks/pre-commit.local 2>/dev/null)" ]]; then
    exec "$(git rev-parse --git-path hooks/pre-commit.local)"
fi
