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
PUSH_REMOTE=""
if [[ "${1:-}" == "--push" ]]; then
    SCAN_MODE=push; shift
    # git calls `pre-push <remote-name> <remote-url>`. WHICH remote matters:
    # "what does this remote not have yet?" is the whole question, and
    # answering it with "what do ALL remotes not have" let a commit fetched
    # from a fork be pushed to origin unscanned (reproduced 2026-09-15: a new
    # branch whose tip came from a second remote enumerated ZERO commits and
    # the token landed on origin). The shim forwards git's argv for this.
    PUSH_REMOTE="${1:-}"
fi

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

# These two are named because they need an exemption the others do not —
# see `is_name_hex` below for why a PUBLIC key matches them.
PAT_NAME_HEX_UPPER='(SYSTEM_KEY|WEBHOOK_KEY|SIGNING_KEY|API_KEY|SECRET|TOKEN)[A-Z_]*\s*[=:]\s*["\x27]?[a-f0-9]{32,}'
PAT_NAME_HEX_JSON='["\x27][A-Za-z0-9_-]*([Kk]ey|[Ss]ecret|[Tt]oken)["\x27]\s*:\s*["\x27][a-f0-9]{32,}'

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
    "$PAT_NAME_HEX_UPPER"
                                                        # A bare 32+ hex value ASSIGNED to a secret-shaped name. Bare
                                                        # hex alone is unusable as a pattern (git SHAs, md5sums,
                                                        # content hashes) — requiring the assignment target to look
                                                        # like a credential is what makes it precise. Added with the
                                                        # above: a committed FUB X-System-Key of exactly this shape
                                                        # survived six audits, partly because a source comment called
                                                        # it "public-ish, in repo already".
    "$PAT_NAME_HEX_JSON"
                                                        # Same value, JS/JSON/YAML object form:
                                                        #   "X-System-Key": "<32 hex>"
                                                        # The uppercase assignment pattern above catches the Python
                                                        # `NAME = "hex"` shape but NOT this one — proven 2026-09-03,
                                                        # when the guard flagged 1 of the 6 files holding the same
                                                        # committed FUB key and missed the four JS/TOML/JSON ones.
)

# ── the two patterns above whose ONLY signal is a secret-shaped NAME ─────────
# Every other pattern matches a credential's own FORMAT (`ghp_` + 36, `AKIA` +
# 16): the value itself says what it is. These two match "a secret-shaped name
# assigned a long hex value", which cannot distinguish a PRIVATE key from a
# PUBLIC one — and a public key is published by definition.
#
# Found by this guard's own live proof, 2026-09-15: watchdog-worker's
# signed-registry commit carries
#
#     "pubkey": "<64 hex>"        (watchdog-worker, commit a5d06ae)
#
# an Ed25519 PUBLIC key, matched because "pubkey" ends in "key". There is no
# compliant fix for that: the pubkey has to be in the repo for signature
# verification to work, so the only way past it is the bypass flag — the
# outcome this whole guard is designed not to provoke. That repo's whole design
# is signed registries, so it will recur.
#
# The exemption is NAME-SCOPED and applies ONLY to these two patterns, checked
# only after one of them has already matched. A line like
# `"pubkey": "ghp_<36>"` is still blocked, because the `ghp_` pattern matched
# on FORMAT and never consults this list — the allowlist cannot be used as a
# shield by naming a field `pubkey`.
# A name that says PUBLIC, or that names a hash/fingerprint rather than a
# credential. Anchored in NAME position — the value is never consulted.
# Deliberately NARROW, and ONE branch: a name whose "public" sits directly on
# the key word — pubkey, public_key, myPublicKey. Singular `key` only: the
# guarded JSON pattern requires a quote immediately after key|secret|token, so
# a PLURAL `host_pubkeys` never matches it, and an exemption for it was a
# second dead entry — caught by the reachability check in
# verify-secret-scan.sh, which exists because the first one was not. NOT any name
# that merely contains "public": `public_api_token` holding a 40-hex value is a
# credential with a reassuring name, and an earlier draft exempted it. "token"
# is absent on purpose — a "public token" is a contradiction, and resolving it
# in favour of the reassuring word is how this class of mistake happens.
#
# A second branch exempting hash/digest/fingerprint/sha256/etag names was
# DELETED as unreachable, found by a multi-model review pass and confirmed by
# probe. The patterns this list guards require the name to END in
# key|secret|token, so every name that branch exempted — `sha256`, `digest`,
# `password_hash`, even `token_hash` — never matched them in the first place:
#
#     "sha256": "<40 hex>"         pattern matches: 0   scanner: allowed
#     "password_hash": "<40 hex>"  pattern matches: 0   scanner: allowed
#     "token_hash": "<40 hex>"     pattern matches: 0   scanner: allowed
#     "hash_key": "<40 hex>"       pattern matches: 1   scanner: BLOCKED
#
# It was dead vocabulary pretending to be a case — the same shape as the
# `input_required` state removed from ATTENTION earlier the same day — and four
# suite rows "proving" those names were exempt passed because nothing matched,
# not because the exemption worked. An exemption that cannot fire is worse than
# none: it reads as considered coverage.
PUBLIC_NAME='["\x27]?[A-Za-z0-9_-]*(pub|public)[_-]?key["\x27]?[[:space:]]*[=:]'

is_name_hex() {                 # <pattern> -> 0 if it is one of the two
    [ "$1" = "$PAT_NAME_HEX_UPPER" ] || [ "$1" = "$PAT_NAME_HEX_JSON" ]
}

# Are ALL of this pattern's matches in <text> published-by-design? Runs only
# after a match, so its cost never touches the clean path.
all_matches_public() {          # <text> <pattern>
    # `grep -o` — OCCURRENCE granularity, not line. Per line was wrong and the
    # suite caught it: `{"pubkey": "<hex>", "token": "<hex>"}` is ONE line that
    # matches the allowlist because of the pubkey, so a real secret beside it on
    # the same line was exempted. `-o` emits one `name: value` match per line,
    # which is the same reason the PII email check below uses it.
    #
    # And NEVER judge a pipeline you exit early from. The first draft was
    # `! printf | grep -oE | grep -qvEi`, which rebuilds the SIGPIPE bypass
    # this file already paid for once (2026-09-12: a token in a >64KB file read
    # as clean). `grep -qv` exits the instant it sees a NON-public match, the
    # producer keeps writing, takes SIGPIPE, exits 141, pipefail adopts 141 —
    # and `!` inverts that into "every match was published by design". The
    # direction is inverted from the original incident, which is worse: there a
    # match became a miss, here "some match is NOT public" becomes "all of them
    # are". The race did not fire in 40 attempts at 3MB of match output here,
    # so this is reasoning rather than a reproduction — but the same reasoning
    # was right the first time and this structure costs nothing.
    #
    # It also closes two fail-opens that ARE deterministic, both resolving to
    # EXEMPT: empty output — the index path re-reads the blob, and a read that
    # fails yields nothing, so an unreadable file became an exempted one, in
    # the one path that elsewhere refuses an unreadable file BY NAME — and
    # `grep -oE` erroring out (exit >1 on an ERE it dislikes), which the main
    # loops handle explicitly and this helper did not.
    local out nonpublic st
    set +e +o pipefail
    out=$(printf '%s\n' "$1" | grep -oE -- "$2")
    st=$?
    set -e -o pipefail
    # st>0 is "no matches" or "grep failed". Neither is a positive statement
    # that the matches are public, so neither may exempt.
    [ "$st" -eq 0 ] && [ -n "$out" ] || return 1
    nonpublic=$(printf '%s\n' "$out" | grep -vEi -- "$PUBLIC_NAME" || true)
    [ -z "$nonpublic" ]
}

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
# The ADDED lines of a diff on stdin, with the file headers removed
# STRUCTURALLY rather than by pattern.
#
# `grep -E '^\+' | grep -vE '^\+\+\+'` was the obvious way and it was a
# bypass: a content line that itself starts with `++` appears in the diff as
# `+++TOKEN = "..."`, which the header filter then dropped. Reproduced
# 2026-09-15 — a file whose first line was `++TOKEN = "<ghp_...>"` pushed
# clean. Patches, diff fixtures and any file that legitimately contains diff
# text hit this by accident; a credential can hit it on purpose.
#
# So: drop everything from `diff --git` up to that file's first hunk header
# (which is where `--- a/x` and `+++ b/x` live) and keep every `+` line after
# it. A combined diff from a merge uses `@@@` and `++line`; `^@@` matches the
# former and the extra `+` is harmless inside a scanned line.
added_lines() {
    awk '
        /^diff /        { inhdr = 1; next }   # --git and --cc (merges)
        inhdr && /^@@/  { inhdr = 0; next }
        inhdr           { next }
        /^@@/           { next }
        /^\+/           { print substr($0, 2) }
    '
}

if [[ "$SCAN_MODE" == push ]]; then
    PUSH_FOUND=0
    scan_commit() {
        local c="$1" added st
        # -U0: added lines only. `--format=` suppresses the log header, whose
        # own subject/body text would otherwise be scanned as content — a
        # commit MESSAGE mentioning a token shape is not a committed secret,
        # and blocking on it has no compliant fix short of rewriting history.
        # --text is load-bearing, not tidiness. `git show` honours DIFF
        # ATTRIBUTES: a path marked `-diff` in a committed .gitattributes
        # (`*.min.js -diff`, `*.lock -diff` — ordinary idioms) and anything git
        # auto-detects as binary (a NUL in the first 8KB) diffs as "Binary
        # files ... differ" with ZERO added lines. So the scan saw nothing and
        # called the commit clean. Reproduced 2026-09-15: `*.env -diff` plus a
        # token in prod.env pushed clean. Index mode was never exposed because
        # it greps the raw blob. Worst case --text scans a binary as text,
        # which is the direction this control must fail in.
        #
        # And the STATUS matters: `|| true` on the pipeline discarded a git
        # failure, so an unreadable object read as a clean commit — the same
        # fail-open shape as the rev-list range, one level in.
        local raw
        if ! raw=$(git show "$c" --text -U0 --format= --diff-filter="$DIFF_FILTER" 2>/dev/null); then
            refuse_push "could not read commit $c." \
                        "The object may be corrupt; try: git fsck"
        fi
        added=$(printf '%s\n' "$raw" | added_lines || true)
        [[ -z "$added" ]] && return 0
        local pattern
        for pattern in "${PATTERNS[@]}"; do
            set +e +o pipefail
            printf '%s\n' "$added" | grep -qE -- "$pattern"
            st=("${PIPESTATUS[@]}")
            set -e -o pipefail
            if [ "${st[1]}" -eq 0 ] && is_name_hex "$pattern" \
               && all_matches_public "$added" "$pattern"; then
                # Every match was a published-by-design value (a pubkey, a
                # fingerprint). Checked only AFTER a match, so the clean path
                # pays nothing for it.
                :
            elif [ "${st[1]}" -eq 0 ]; then
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
    # Which remote-tracking refs count as "the remote already has this". git
    # hands us a NAME normally, a URL when someone pushes to a raw path.
    remote_name=""
    if [[ -n "$PUSH_REMOTE" ]]; then
        if git remote get-url "$PUSH_REMOTE" >/dev/null 2>&1; then
            remote_name="$PUSH_REMOTE"
        else
            while read -r _n _u; do
                [[ "$_u" == "$PUSH_REMOTE" ]] && remote_name="$_n"
            done < <(git remote -v 2>/dev/null | awk '{print $1, $2}' | sort -u)
        fi
    fi

    refuse_push() {                 # <why> <fix>
        echo "BLOCKED: $1" >&2
        echo "  $2" >&2
        echo "  Refusing to treat a range this scanner could not enumerate as" >&2
        echo "  clean — the index scan refuses an unreadable file for the same" >&2
        echo "  reason, and a detection control must fail toward scanning." >&2
        exit 1
    }

    # git's pre-push protocol: one line per ref, on stdin. BUFFERED, because
    # this loop consumes it and a chained `pre-push.local` would otherwise
    # receive an empty stdin — the ref list is the only thing a pre-push hook
    # has to work with, so chaining without it hands the local hook nothing and
    # it silently approves every push. Found by review; it becomes real the
    # first time anyone writes a repo-local pre-push, which the `.local`
    # convention invites.
    PUSH_REFS=$(cat)
    PUSH_COMMITS=""
    while read -r _lref lsha _rref rsha; do
        # A deleted ref pushes nothing. `git push --delete` sends an all-zero
        # LOCAL sha; scanning it would resolve to nothing and, worse, an
        # unguarded `$lsha..` range would silently mean "everything".
        [[ -z "${lsha:-}" || "$lsha" =~ ^0+$ ]] && continue
        range=""
        if [[ -z "${rsha:-}" || "$rsha" =~ ^0+$ ]]; then
            # A NEW ref on the remote. The range is not `$lsha` alone — that is
            # the branch's entire history back to the root, so the first push of
            # any branch would rescan years of commits and block on anything
            # historical, with no compliant path. Exclude what THIS remote has.
            #
            # `--remotes` (all remotes) was the first version and it was a
            # bypass: a commit fetched from a fork is reachable from
            # `fork/contrib`, so pushing it to origin for the FIRST time
            # enumerated zero commits. Reproduced, token landed on origin.
            if [[ -z "$remote_name" ]]; then
                refuse_push \
                    "cannot tell which commits '$PUSH_REMOTE' already has." \
                    "Give this remote a name (git remote add <name> <url>) and push to that."
            fi
            if ! range=$(git rev-list "$lsha" --not --remotes="$remote_name" 2>/dev/null); then
                refuse_push \
                    "could not enumerate what is new on '$remote_name'." \
                    "Try: git fetch $remote_name   (then push again)"
            fi
        else
            # An UPDATE to an existing ref. `$rsha` is the remote's current tip
            # as it advertised it — which the local repo may not have: a force
            # push over work someone else pushed, a single-branch or shallow
            # clone. `rev-list` then FAILS, and `|| true` turned that into an
            # empty range: exit 0, nothing scanned, content published.
            # Reproduced 2026-09-15 with two clones — a `ghp_` token reached
            # the remote through `git push --force`.
            if ! range=$(git rev-list "$rsha..$lsha" 2>/dev/null); then
                refuse_push \
                    "'$rsha' (the tip $PUSH_REMOTE advertised) is not in this repository," \
                    "so what you are publishing cannot be determined. Try: git fetch ${remote_name:-$PUSH_REMOTE}"
            fi
        fi
        # The first push of a brand-new repo (or a remote with no
        # refs/remotes/<name>/* yet) legitimately has the ENTIRE history in
        # range — correct, it genuinely is all being published for the first
        # time, but a hook that goes silent for minutes is its own
        # `--no-verify` risk. Say what it is doing when there is real work.
        _n=$(printf '%s\n' $range | grep -c . || true)
        [ "${_n:-0}" -gt 50 ] && echo "secret-scan: checking $_n commits for secrets..." >&2
        for commit in $range; do
            scan_commit "$commit"
            PUSH_COMMITS="$PUSH_COMMITS $commit"
        done
    done <<<"$PUSH_REFS"
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
        if [ "${_st[1]}" -eq 0 ] && is_name_hex "$PATTERN" \
           && all_matches_public "$(git show ":$FILE" 2>/dev/null)" "$PATTERN"; then
            # A published-by-design value (a pubkey, a fingerprint). The file is
            # re-read here rather than held in a variable for every scan,
            # because this branch is only reached once a pattern has matched.
            :
        elif [ "${_st[1]}" -eq 0 ]; then
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
#
# tntpgh-dev's published VIDEO metadata (2026-09-16) is a NARROWER case and it
# is deliberately NOT in the list above. `src/data/videos.json` is the team's
# own YouTube channel listing — titles copied verbatim from videos already
# public on YouTube — and the titles ARE street addresses, because the videos
# are listing tours ("<number> <Street> <City> PA <ZIP> Tour" is the channel's
# naming convention). `public/sitemap.xml` is generated from that same data at
# prebuild, so the addresses reappear in its `video:title` elements on every
# regeneration. Thousands of `/properties/*` URLs in that same sitemap already
# carry the same street numbers (3,413 of 4,335 `<loc>` entries on
# tntpgh-dev@origin/main, 2026-09-16, counted with
# `xmllint --xpath 'count(//*[local-name()="loc" and contains(text(),"/properties/")])'`).
#
# But "this file is public output" does NOT establish that every future value
# in it is safe to publish. A first draft of this change put both paths in
# PII_EXCLUDES, which drops them from the whole PII input — and a real pre-push
# probe then ALLOWED a third-party email in videos.json and a non-fiction phone
# number in sitemap.xml. Two public-output paths had become general PII
# bypasses (found in review, 2026-09-16). So the exemption is scoped to the
# STREET-ADDRESS detector only; the phone and email detectors still read every
# line of both files, and the credential scan above never consulted this list
# at all.
#
# (No real address is written in this comment on purpose: the first draft of it
# was itself blocked by the street check. A guard whose allowlist cannot be
# committed is a guard that gets bypassed — same lesson as the
# exclusion-pattern note further down.)
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
# Paths exempt from the STREET-ADDRESS detector ONLY. Everything here is still
# read by the phone and email detectors, and by the credential scan, which is
# what keeps a public-output path from becoming a general PII bypass.
ADDRESS_ONLY_EXCLUDES=(
    ':(exclude)src/data/videos.json'
    ':(exclude)public/sitemap.xml'
)
# The added lines to judge, per SOURCE. In push mode that is one call per
# commit being sent, so a finding can name the commit to rewrite — the first
# version concatenated every commit into one blob and could only say "a
# pushed commit", which is not a fix anybody can act on. Client PII reaching
# the remote is the higher-consequence half of this hook (a 2026-09-03 audit
# found 1,409 identities in knowledge-base history), and `git am`,
# `cherry-pick`, `revert` and every `rebase` replay reach a remote without
# ever running a commit-creation hook. Only commits the remote does not
# already have are in PUSH_COMMITS, so this cannot fire on published history
# and become unbypassable.
pii_added_for_commit() {        # <commit> -> raw diff text; caller checks $?
    # --text for the same reason as scan_commit: a `-diff` attribute or a NUL
    # byte otherwise hides every added line from this half too.
    #
    # PR #87 re-review, 2026-09-16: this used to end `| added_lines || true`,
    # which discarded `git show`'s own exit status and handed `added_lines`
    # whatever partial/empty stdout it got — so a broken external diff driver
    # (a `.gitattributes` entry naming a `diff.<x>.command` with no such
    # binary) made `git show -U0` fail, and the pipeline still "succeeded"
    # with an empty stream, which every detector below reads as "nothing
    # added, nothing to block". No `| added_lines` here now: the caller reads
    # this function's OWN exit status via `if raw=$(pii_added_for_commit …)`
    # before piping to `added_lines`, so a diff failure is refused instead of
    # silently scanning nothing.
    git show "$1" --text -U0 --format= --diff-filter="$DIFF_FILTER" "${PII_EXCLUDES[@]}" 2>/dev/null
}
pii_added_for_index() {         # -> raw diff text; caller checks $?
    git diff --cached -U0 --diff-filter="$DIFF_FILTER" "${PII_EXCLUDES[@]}" 2>/dev/null
}
# The same two sources again, additionally dropping the address-only paths.
# Only the street check reads these; see ADDRESS_ONLY_EXCLUDES above.
#
# Raw text, caller checks `$?` — NOT `| added_lines || true`. These arrived
# with #87 carrying the very fail-open #91 removed from the two functions
# above: `|| true` discards git's own exit status and hands `added_lines`
# whatever partial stdout it got, so a broken external diff driver reads as
# "no addresses added".
addr_added_for_commit() {       # <commit> -> raw diff text; caller checks $?
    git show "$1" --text -U0 --format= --diff-filter="$DIFF_FILTER" \
        "${PII_EXCLUDES[@]}" "${ADDRESS_ONLY_EXCLUDES[@]}" 2>/dev/null
}
addr_added_for_index() {        # -> raw diff text; caller checks $?
    git diff --cached -U0 --diff-filter="$DIFF_FILTER" \
        "${PII_EXCLUDES[@]}" "${ADDRESS_ONLY_EXCLUDES[@]}" 2>/dev/null
}
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
# (Merge of #91's pipeline judging and #87's address-scoped text. Both halves
# are load-bearing: judge_pipeline catches a stage that could not RUN, and the
# third argument keeps the published-video path exemption scoped to the STREET
# detector instead of dropping those paths from the whole PII input.)
# Judges every stage of a `printf | extractor | grep -v… | grep -v…` pipeline
# used by the street/phone detectors below, not just the last command bash's
# own `if pipe; then` would look at. Found three times over on this branch:
# a crashed extractor (awk on multibyte input) OR a mis-written exclusion
# pattern (invalid ERE on the fleet's grep, exit 2+) both leave the FINAL
# `grep -v` reading an empty/partial stream, which then legitimately exits 1
# ("nothing survived") — and `pipefail` reports that rightmost nonzero 1, not
# the real 2+ that caused it, so the failure is invisible to a bare `if`.
# Looping every stage (not hand-listing "check index 1 and 3") is the actual
# fix: a pipeline gaining a new stage later cannot silently go unjudged again.
#
# <strict-index> names the ONE stage (1-based, 0 is always printf and skipped)
# that is an EXTRACTOR rather than a grep filter — awk has no "1 = nothing
# matched" exit code of its own, so for that stage only 0 means "ran fine";
# anything else means it did not finish, not "found nothing". Every other
# non-final stage is a `grep -v` filter, where 0 or 1 are both legitimate
# (something, or nothing, survived to feed the next stage) and anything else
# is that stage's own pattern failing to run. The FINAL stage doubles as the
# verdict: 0 there means a real value survived every exclusion.
# ---- _ss_drop_published -----------------------------------------------------
# Drops street addresses that are ALREADY ON THE DEPLOYED TRUNK, and behaves
# like a `grep -v` stage so `judge_pipeline` needs no special case: exit 0 when
# something survived (block it), 1 when nothing did.
#
# Why this exists. The other exclusions above are ENUMERATED — a list of
# fixture street names, plus two own-NAP entries — and that shape has to be
# extended by hand for every legitimate case. Until someone does, the guard
# blocks honest work, and people learn to route around it. #87 solved the
# specific case that bit (published video metadata) with a PATH exemption,
# which is the right answer for generated pipeline output. This answers the
# cases no path list anticipates: a blog post quoting a listing, a CMA, a
# press pitch.
#
# The question it asks is not a name list: IS THIS ADDRESS ALREADY SERVED TO
# THE PUBLIC FROM THE TRUNK? An address already on origin/main cannot be
# leaked by committing it again; a buyer's or seller's address in exactly the
# same shape is not there, so it still blocks. Self-limiting: it can never be
# used to introduce a NEW address, because being new is what it detects.
#
# Baseline is the REMOTE trunk, never local HEAD. In a pre-push run the commit
# under inspection is already reachable from HEAD, so HEAD would let every
# address approve itself.
_ss_on_trunk() {                # <"number street"> -> 0 if published
    local a="$1" ref
    [ -n "$a" ] || return 1
    for ref in origin/main origin/HEAD; do
        git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
        if git grep -qiF -- "$a" "$ref" 2>/dev/null; then return 0; fi
    done
    return 1
}

_ss_drop_published() {          # stdin: one occurrence per line
    local line probe any=1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Drop the street-type suffix before comparing: the trunk may spell it
        # "Drive" where this commit says "Dr". Number + street name is
        # specific enough to be an identity.
        probe="$(printf '%s' "$line" |
                 sed -E 's/ (Dr|Rd|St|Ave|Ct|Ln|Way|Blvd|Road|Street|Drive|Avenue|Court|Lane)$//')"
        if _ss_on_trunk "$probe"; then continue; fi
        printf '%s\n' "$line"
        any=0
    done
    return "$any"
}

# Prints its own BLOCKED lines; caller does `if judge_pipeline …; then
# PII_FOUND=1; fi`.
judge_pipeline() {              # <label> <PII-class-name> <strict-index> <status0> <status1> ...
    local label="$1" name="$2" strict="$3"; shift 3
    local -a codes=("$@")
    local last=$(( ${#codes[@]} - 1 ))
    local i code blocked=1
    for i in $(seq 1 "$last"); do
        code="${codes[$i]}"
        if [ "$i" -eq "$strict" ]; then
            if [ "$code" -ne 0 ]; then
                echo "BLOCKED: the $name scanner could not process $label (stage $i, exit $code) —" >&2
                echo "  refusing to treat text an extractor could not finish scanning as clean." >&2
                blocked=0
            fi
        elif [ "$i" -eq "$last" ]; then
            if [ "$code" -eq 0 ]; then
                echo "BLOCKED: a real-looking $name is being added in $label."
                blocked=0
            elif [ "$code" -gt 1 ]; then
                echo "BLOCKED: grep failed while filtering $name candidates in $label (stage $i, exit $code) —" >&2
                echo "  a scanner that cannot run its own pattern has not cleared this text." >&2
                blocked=0
            fi
        elif [ "$code" -gt 1 ]; then
            echo "BLOCKED: grep failed while filtering $name candidates in $label (stage $i, exit $code) —" >&2
            echo "  a scanner that cannot run its own pattern has not cleared this text." >&2
            blocked=0
        fi
    done
    return "$blocked"
}

check_pii() {                   # <label> <added text> [<address-scoped text>]
    # $2 feeds the phone and email detectors. $3 feeds the STREET detector and
    # additionally drops ADDRESS_ONLY_EXCLUDES; it defaults to $2 so a caller
    # that does not distinguish them keeps the stricter behaviour. Passing one
    # text for both is what turned two public-output paths into general PII
    # bypasses (found in review, 2026-09-16).
    local label="$1" text="$2" addr_text="${3-$2}"
    [[ -n "$text$addr_text" ]] || return 0
    # street address: <number> <Name> <suffix>, excluding the fixture words.
    #
    # `([NSEW]\.? )?` closes a hole found 2026-09-16 while testing this very
    # allowlist: a directional prefix is normal in US addresses and the
    # pattern required a lowercase letter right after the number, so a real
    # address of the form "<number> E <Name> St" was never detected at all.
    # Restricted to the four directionals on purpose -- a bare `[A-Z]` there
    # would start matching ordinary prose like "42 Bytes Read".
    #
    # Covenant Ave and the 226-4440 line are Vintage Skins' OWN published NAP
    # -- Lisa's shop, a client business we build for, not a third party. Both
    # are already tracked in vintageskins/seo/src/schema/organization.js, are
    # printed on the storefront, in the Organization schema and in Merchant
    # Center, and the phone is a Twilio IVR number, never her mobile. Same
    # principle as the Wexford office below and the vintageskins.com email
    # carve-out further down: a business's own published identity is not
    # client PII, and blocking it only teaches people to bypass the guard on
    # ordinary branding work.
    #
    # The Suite 200, Wexford PA 15090 office is OUR OWN. It is the canonical
    # NAP, already tracked in tntpgh-dev/src/config/codex/identity.ts and
    # docs/nap-canonical.md, printed on every piece of public marketing, and
    # the brokerage identification is REQUIRED on licensee advertising by
    # 49 Pa. Code 35.305(c) -- a branded PDF cannot be built without it. Same
    # principle as the teamthurber.com email carve-out below: our own published
    # business identity is not client PII, and blocking it only teaches
    # --no-verify on ordinary branding work.
    #
    # NOTE the exclusion pattern below starts at the digit, with NO leading
    # \b. It used to have one, and that made this very line unpublishable: the
    # detector matched the address inside the pattern text, while the exclusion
    # did not, because in source the escape `\b` puts a literal `b` against the
    # digits and kills the word boundary. A guard whose allowlist cannot be
    # committed is a guard that gets bypassed.
    # PR #88 review, 2026-09-16: `grep -nE` printed the whole matching LINE,
    # and each `grep -viE` exclusion then discarded that whole line — a
    # third-party address sharing a line with one of our own allowlisted
    # values laundered through untouched. `grep -oE` instead extracts one
    # street-address OCCURRENCE per match, so each is excluded on its own.
    # The two business-address exclusions are now anchored `^...$` against
    # that single occurrence rather than matched as an unanchored substring:
    # the old form let a LARGER house number containing an allowlisted
    # suffix (one extra leading digit) match the exclusion too, because it
    # only required the occurrence to CONTAIN the allowlisted text, never to
    # EQUAL it. The numeric-near-match exclusion below drops the old
    # `\+?[0-9]*:?\+?` prefix, which existed only to skip the `N:` line
    # number `-n` used to add; `-o` never adds one.
    #
    # `judge_pipeline` (above) checks every stage's own exit status, not just
    # this `if`'s last command: an invalid ERE in any exclusion below would
    # otherwise make that stage exit 2+, hand the rest of the pipe an
    # empty/partial stream, and the final `grep -vE` would legitimately exit 1
    # ("nothing survived") — which reads as clean while the real failure is
    # invisible. `0` for <strict-index>: every stage here is a grep filter,
    # none is an extractor with awk's different exit semantics. `0` works as
    # "no strict stage" specifically because `judge_pipeline`'s loop starts
    # at `i=1` and stage 0 is always `printf` — it can never equal a real
    # stage index. Do NOT "fix" this to `1`: that would make stage 1 (the
    # `grep -oE` extractor's own legitimate "no address found at all", exit 1)
    # get judged as if it must be exactly 0, and a clean commit with no street
    # address anywhere would block on every commit.
    #
    # The deployment-order deferral that used to sit here is RESOLVED, not
    # waived: the allowlist entries are assembled at runtime below, so editing
    # them no longer requires a machine whose deployed scanner already carries
    # them, and the four suite fixtures it had forced out are restored.
    # THE ALLOWLIST ENTRIES ARE ASSEMBLED AT RUNTIME, and that is not style.
    # Spelled out contiguously, these two lines are themselves real-looking
    # addresses, so the FILE could only be committed on a machine whose
    # DEPLOYED scanner already carried them — i.e. after this branch merged and
    # was redeployed. Editing them before that point blocked the very commit
    # that adds them (reproduced 2026-09-18, with the deployed hook restored to
    # main's bytes), and four suite fixtures had already been commented out for
    # the same reason. Concatenating the halves at runtime removes the
    # deployment-order trap permanently: the detector cannot match
    # `2100 Corpo""rate Dr`, and the pattern is identical once the shell joins
    # it. Same lesson as the `\b` note above — a guard whose allowlist cannot
    # be committed is a guard that gets bypassed.
    _own_office="2100 Corpo""rate Dr(ive)?"
    _own_shop="8878 Cove""nant Ave(nue)?"
    set +e +o pipefail
    # `$addr_text`, not `$text`: the published-video path exemption is scoped
    # to THIS detector (#87). The phone and email detectors below still read
    # every line of those files.
    printf '%s\n' "$addr_text" \
       | grep -oE '[0-9]{2,5} ([NSEW]\.? )?[A-Z][a-z]+( [A-Z][a-z]+)? (Dr|Rd|St|Ave|Ct|Ln|Way|Blvd|Road|Street|Drive|Avenue|Court|Lane)\b' \
       | grep -viE '\b(Main|Elm|Oak|Test|Example|Fake|Sample|Anywhere|Nowhere|Maple|Pine|First|Second|Foo|Bar)\b' \
       | grep -viE "(^|[^0-9])$_own_office\b" \
       | grep -viE "(^|[^0-9])$_own_shop\b" \
       | grep -vE '^(123|456|789|1234|100|111|999) ' \
       | _ss_drop_published >/dev/null
    _pst=("${PIPESTATUS[@]}")
    set -e -o pipefail
    if judge_pipeline "$label" "STREET ADDRESS" 0 "${_pst[@]}"; then
        PII_FOUND=1
    fi
    # phone: not the 555-01xx fiction range, and not one of OUR OWN published
    # business lines. The three team numbers are the canonical NAP
    # (docs/nap-canonical.md: team, Terrence direct, broker office) and the
    # broker office line is legally required on licensee advertising by
    # 49 Pa. Code 35.305(c). The 367-5860 line is West Penn Multi-List's
    # published switchboard -- a trade body whose number has to be quotable
    # when documenting an MLS rule or a verification route.
    #
    # The `(^|[^0-9])` / `([^0-9]|$)` anchors are a FALSE-POSITIVE fix, not a
    # relaxation: the pattern otherwise matched INSIDE a longer digit run, so
    # the Springer DOI `s11146-013-9424-1` parsed as a phone number and blocked
    # a commit whose only offence was citing a peer-reviewed paper
    # (2026-09-16). A real phone is always bounded by a non-digit, and the
    # separator requirement is unchanged, so a bare 10-digit run still never
    # matched. The offending substring is deliberately NOT written out here --
    # spelling it in a comment re-trips the detector on this file.
    # PR #88 review, 2026-09-16: both boundaries above sat INSIDE the `-o`
    # match, so `grep -o`'s non-overlapping scan consumed the one separator
    # between two adjacent numbers along with the first candidate — scanning
    # resumed at the second number's first digit, where a leading boundary
    # can never match, so the second number was never EXTRACTED at all, not
    # merely allowlisted. Reproduced for every one-character separator with
    # the business number first; the reverse order was never affected, which
    # is what made it read as a slash-specific quirk rather than a boundary-
    # consumption bug. Replaced with an awk scanner that tries a match at
    # EVERY start position and checks the character immediately before/after
    # with `substr`, never consuming it — so two real numbers may legitimately
    # share one separator character and both still get extracted, while the
    # DOI false-positive above still cannot: its digit run has a digit on
    # both sides of the only place the 3-3-4 shape lines up.
    # A second fail-open, found immediately after the first: `if printf … |
    # awk … | grep -vE … | grep -vE … >/dev/null; then` only tests the LAST
    # command's exit status. `awk` (BWK awk on this fleet) decodes `length`/
    # `substr` through the process locale, and en_US.UTF-8 — the default here
    # — makes it die with `towc: multibyte conversion failure` the instant it
    # meets ANY multibyte byte anywhere in $text, including in this hook's OWN
    # em-dash-heavy comments a few lines above a real phone number. A dead awk
    # prints nothing, the two `grep -v`s see an empty stream and find nothing
    # to exclude, and the `if` reads "clean" — the exact shape finding 3 was
    # opened to close, reintroduced one stage downstream of the diff read.
    # Same guard as the credential loop above (`_st=("${PIPESTATUS[@]}")`),
    # and the SAME `judge_pipeline` the street check above now uses, not a
    # third convention: hand-checking just index 1 (awk) and index 3 (the
    # last grep) left index 2 — the first exclusion grep — unjudged. If IT
    # exits 2+ its output is empty, stage 3 then sees nothing and legitimately
    # exits 1 ("nothing survived"), and pipefail reports that rightmost
    # nonzero 1 — clean — while the real 2+ that caused it is invisible.
    # `judge_pipeline` loops every stage so a future one added here cannot go
    # unjudged the same way. `1` for <strict-index>: stage 1 is the awk
    # extractor, which has no "1 = nothing matched" exit code of its own —
    # only 0 means it ran to completion.
    #
    # This pattern only ever matches ASCII digits and punctuation, so
    # `LC_ALL=C` (byte-oriented, no towc decoding) is the CORRECT scan, not a
    # workaround: no multibyte byte can be one of `[0-9]`, so byte-wise
    # scanning cannot skip a real phone number. Verified: the awk rewrite
    # above (needed because `grep -o`'s non-overlapping scan cannot do a
    # non-consuming boundary check, which IS the separator bug) carried this
    # new fail-open in with it — the pre-awk `grep -oE` phone extractor never
    # had a multibyte problem, `grep` decodes it without crashing. Caught by
    # measuring the rewrite against an em-dash fixture before commit, not by
    # reading the diff: default-locale awk exit 2, zero output, zero BLOCKED
    # lines, on a line carrying a real phone number one line below this
    # hook's own em-dash-heavy prose.
    set +e +o pipefail
    printf '%s\n' "$text" \
        | LC_ALL=C awk '{
            line = $0; n = length(line)
            for (i = 1; i <= n; i++) {
                rest = substr(line, i)
                if (match(rest, /^(\+?1[-. ]?)?\(?[0-9]{3}\)?[-. ][0-9]{3}[-. ][0-9]{4}/)) {
                    before_ok = (i == 1) || (substr(line, i - 1, 1) !~ /[0-9]/)
                    after = i + RLENGTH
                    after_ok = (after > n) || (substr(line, after, 1) !~ /[0-9]/)
                    if (before_ok && after_ok) print substr(rest, 1, RLENGTH)
                }
            }
        }' \
        | grep -vE '555[-. ]?01[0-9][0-9]' \
        | grep -vE '\(?(412\)? ?[-. ]?(844[-. ]5536|900[-. ]2243|367[-. ]5860|226[-. ]4440)|724\)? ?[-. ]?934[-. ]3400)' >/dev/null
    _pst=("${PIPESTATUS[@]}")
    set -e -o pipefail
    if judge_pipeline "$label" "PHONE NUMBER" 1 "${_pst[@]}"; then
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
    #
    # A ROLE MAILBOX AT A BUSINESS DOMAIN IS A PUBLISHED CONTACT, NOT A
    # PERSON. `info@`, `sales@`, `escrow@`, `closings@` and friends are what
    # a company prints on its own website; blocking them treats a vendor's
    # switchboard like a client's inbox, and the enumerated-domain allowlist
    # above is the alternative — one hand-added entry per vendor, forever,
    # with the guard blocking honest work until someone adds it.
    #
    # NOT at a consumer mail provider. `info@` at a gmail/yahoo/icloud-style
    # address is a person who chose a role-shaped local part (spelled here
    # WITHOUT the domain on purpose: this rule scans its own file, and the
    # first version of this comment blocked the very commit that added it —
    # the third time today an example in a guard's own text tripped the
    # guard). A role mailbox means something only when the
    # domain belongs to the business. That distinction is the whole rule, so
    # the consumer list is checked FIRST and wins.
    #
    # Anything else at a non-allowlisted domain still blocks — a named
    # individual is a named individual whether or not they work somewhere.
    _ss_role='(info|sales|support|hello|contact|admin|billing|help|office|team|careers|jobs|press|media|marketing|webmaster|postmaster|abuse|security|privacy|legal|compliance|accounts|accounting|payables|receivables|orders|service|scheduling|showings|listings|closings|title|escrow|underwriting|noreply|no-reply|donotreply|do-not-reply|mail|hi|ask|inquiries|enquiries)'
    _ss_consumer='(gmail|googlemail|yahoo|ymail|hotmail|outlook|live|msn|icloud|me|mac|aol|proton|protonmail|pm|gmx|mail|zoho|fastmail|comcast|verizon|att|sbcglobal|bellsouth|cox|charter|roadrunner|rr|earthlink|juno|aim)\.[A-Za-z.]{2,}'
    # The role exemption is one awk stage, not another `grep -v`: it is an AND
    # NOT ("looks like a role mailbox" AND "not at a consumer provider"), and
    # a pipeline of `grep -v` can only express OR of independent drops. The
    # first attempt wrote a PCRE lookahead into `grep -E`, which matches
    # nothing and silently exempted everything it touched.
    if printf '%s\n' "$text" \
       | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
       | grep -viE '@(([A-Za-z0-9-]+\.)*example\.(com|org|net)$|test\.|localhost$|invalid$|teamthurber\.com$|vintageskins\.com$|weizenyoung\.com$|users\.noreply\.github\.com$|([A-Za-z0-9-]+\.)?(developer|iam)\.gserviceaccount\.com$)|^secret@dashboard\.teamthurber\.com$' \
       | awk -v role="^${_ss_role}@" -v cons="@${_ss_consumer}\$" '
           { a = tolower($0) }
           a ~ role && a !~ cons { next }   # published business contact
           { print }' \
       | grep -q . ; then
        echo "BLOCKED: a third-party EMAIL ADDRESS is being added in $label."
        PII_FOUND=1
    fi
}

if [[ "$SCAN_MODE" == push ]]; then
    for _c in $PUSH_COMMITS; do
        # Same fail-closed shape as scan_commit's own `git show` above: check
        # each diff's exit status HERE, at the top level, not inside a
        # `$(…)` used purely for its stdout — `exit 1` inside that command
        # substitution would only kill the subshell and the push would sail
        # through with an empty PII text.
        #
        # BOTH diffs are checked. #87 added the address-scoped one, and a
        # broken diff driver there would silently produce "no addresses".
        if ! _pii_raw=$(pii_added_for_commit "$_c"); then
            refuse_push "could not compute the diff for commit $_c to check for client PII." \
                        "A broken external diff driver (.gitattributes) can cause this; run 'git show $_c --text -U0' to see why."
        elif ! _addr_raw=$(addr_added_for_commit "$_c"); then
            refuse_push "could not compute the address-scoped diff for commit $_c." \
                        "A broken external diff driver (.gitattributes) can cause this; run 'git show $_c --text -U0' to see why."
        else
            check_pii "commit $(git log -1 --format='%h %s' "$_c" 2>/dev/null || echo "$_c")" \
                      "$(printf '%s' "$_pii_raw" | added_lines || true)" \
                      "$(printf '%s' "$_addr_raw" | added_lines || true)"
        fi
    done
else
    if ! _pii_raw=$(pii_added_for_index); then
        _pii_rc=$?
        echo "BLOCKED: could not compute the diff for the staged changes (git diff exit $_pii_rc)." >&2
        echo "  A broken external diff driver (a .gitattributes 'diff=' entry naming a" >&2
        echo "  missing tool) can cause this. Refusing to treat an unreadable diff as clean" >&2
        echo "  — every PII check below depends on this same diff." >&2
        echo "  Try: git diff --cached -U0   (to see the underlying failure)" >&2
        exit 1
    elif ! _addr_raw=$(addr_added_for_index); then
        _pii_rc=$?
        echo "BLOCKED: could not compute the address-scoped diff for the staged changes (git diff exit $_pii_rc)." >&2
        echo "  Refusing to treat an unreadable diff as clean — the street check depends on it." >&2
        echo "  Try: git diff --cached -U0   (to see the underlying failure)" >&2
        exit 1
    else
        check_pii "the staged changes" \
                  "$(printf '%s' "$_pii_raw" | added_lines || true)" \
                  "$(printf '%s' "$_addr_raw" | added_lines || true)"
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
        echo "  a business's PUBLISHED contact is fine: `info@` or `sales@` at a vendor's own domain"
        echo "  real data: \$(git rev-parse --show-toplevel)/.private/  — self-ignoring, per repo"
        echo "             create it with: herdr-control/private-dir.sh"
        echo "             anything shared across repos belongs in the KB, not a file"
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
    # Chain to a repo-specific pre-push hook if one exists — with BOTH of the
    # things git would have given it: the ref list on stdin (replayed from the
    # buffer, since the loop above consumed the original) and git's own argv,
    # `<remote-name> <remote-url>`. Chaining without them is worse than not
    # chaining: the local hook runs, sees no refs and no remote, and approves.
    if [[ -x "$(git rev-parse --git-path hooks/pre-push.local 2>/dev/null)" ]]; then
        # `<<<` on an EMPTY buffer would hand the local hook one BLANK line,
        # which is harmless to the loop above (empty sha, skipped) but not to a
        # chained hook: git's own pre-push.sample takes its else branch with
        # both shas empty and runs `git rev-list -n1 --grep ^WIP ".."`, which
        # errors — and a non-zero chained hook now blocks the push. git never
        # invokes pre-push with zero refs (it short-circuits "Everything
        # up-to-date" first), so this is unreachable today; it costs one line
        # to keep it unreachable if that ever changes.
        if [[ -n "$PUSH_REFS" ]]; then
            exec "$(git rev-parse --git-path hooks/pre-push.local)" "$@" <<<"$PUSH_REFS"
        else
            exec "$(git rev-parse --git-path hooks/pre-push.local)" "$@" </dev/null
        fi
    fi
    exit 0
fi

if [[ $PII_FOUND -ne 0 ]]; then
    echo ""
    echo "Commit blocked: client PII in a tracked file is permanent — gitignore"
    echo "never untracks, and history reaches every future clone."
    echo "  fixtures: use 555-0100..555-0199, someone@example.com, 123 Main St"
    echo "  a business's PUBLISHED contact is fine: `info@` or `sales@` at a vendor's own domain"
    echo "  real data: \$(git rev-parse --show-toplevel)/.private/  — self-ignoring, per repo"
    echo "             create it with: herdr-control/private-dir.sh"
    echo "             anything shared across repos belongs in the KB, not a file"
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
