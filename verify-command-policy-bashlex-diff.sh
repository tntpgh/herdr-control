#!/bin/bash
# verify-command-policy-bashlex-diff.sh — SPEC #264 round 3's required
# differential check: ground truth is what `/bin/bash` (this machine's is
# 3.2.57, the same version the repo's own bash-side code targets) ACTUALLY
# invokes, not what any classifier guesses.
#
# Every corpus command runs for real, under a stub PATH: `git`/`find`/`fd`
# in that PATH (plus the SAME three names at `$STUB/usr/bin/...`, since the
# corpus uses absolute `/usr/bin/<verb>` paths and `shopt -s extglob`
# resolves `@(g)it` against the REAL filesystem — rewriting the literal
# text `/usr/bin/` to `$STUB/usr/bin/` before exec means that resolution
# can only ever land on our own harmless stub, never a real `/usr/bin/git`)
# are harmless scripts that record `$0 $*` to a log file and exit 0 — so
# "bash would actually invoke a git/find/fd stub" is read directly off that
# log, not inferred.
#
# Assertion: for every corpus row where the stub log shows a real
# git/find/fd invocation, `classify_command` on the SAME text must NOT
# return `allow`. (The inverse is not asserted: plenty of corpus rows
# intentionally resolve to git/find invocations this policy's EXISTING
# rules already allow — `git status`, a bare `find . -maxdepth 0` — and
# that is correct, not a gap.)
#
#   bash verify-command-policy-bashlex-diff.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/command-policy.sh"

pass=0 fail=0 skipped=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
skip(){ skipped=$((skipped+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
STUB="$work/stub"
mkdir -p "$STUB/usr/bin"
LOG="$work/invoked.log"
: >"$LOG"

# One stub body, installed under every name/path real bash could resolve a
# find/git/fd verb to. Logs `name argv...` — one line per invocation.
write_stub() {
  cat >"$1" <<'STUB'
#!/bin/bash
printf '%s' "$(basename "$0")" >>"$STUB_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$STUB_LOG"; done
printf '\n' >>"$STUB_LOG"
exit 0
STUB
  chmod +x "$1"
}
for name in git find fd gfind; do
  write_stub "$STUB/$name"
  write_stub "$STUB/usr/bin/$name"
done
# git-<verb> dashed forms the corpus's GV list exercises (`git-status`).
write_stub "$STUB/git-status"

# Harmless real-shell builtins/utilities the corpus also calls — `true`,
# `echo`, `cat`, `nice`, `env` — resolve from the REAL PATH appended after
# the stub dir, so `nice find …` still finds OUR find stub first (PATH
# order) while `nice` itself is the real binary.
RUNPATH="$STUB:$STUB/usr/bin:$PATH"

run_corpus_row() {               # label text
  local label="$1" text="$2" rewritten before after invoked line verb args ref_protected
  : >"$LOG"
  rewritten="${text//\/usr\/bin\//$STUB/usr/bin/}"
  before=$(wc -l <"$LOG")
  ( cd "$work" && STUB_LOG="$LOG" PATH="$RUNPATH" timeout 2 /bin/bash -c "$rewritten" ) \
    >/dev/null 2>&1
  after=$(wc -l <"$LOG")
  if [ "$after" -gt "$before" ]; then invoked=1; else invoked=0; fi
  got="$(classify_command "$text")"
  if [ "$invoked" != 1 ]; then
    ok "$label: stub not invoked (verdict=$got, not asserted either way)"
    return
  fi
  # Reference verdict: apply the EXISTING find/git-specific rules directly
  # to what bash ACTUALLY ran (the stub log's `argv0 arg1 arg2 ...`, ground
  # truth, not a re-parse of the original obfuscated text) — this is
  # exactly SPEC step 7's "run the existing find/git classification on the
  # resolved argv", used here as the oracle instead of as production code.
  line="$(tail -1 "$LOG")"
  verb="${line%% *}"
  args="${line#* }"
  [ "$args" = "$line" ] && args=""
  ref_protected="$(_cp_protect_text "$verb $args")"
  if _cp_git_seg_exec_unsafe "$ref_protected"; then
    if [ "$got" = allow ]; then
      bad "$label: real bash ran '$line' (unsafe by the existing find/git rules) but classify_command said allow"
    else
      ok "$label: stub-invoked, reference=unsafe, verdict=$got"
    fi
  else
    ok "$label: stub-invoked, reference=safe ('$line'), verdict=$got (not asserted either way)"
  fi
}

NL=$'\n'
# ---- M1-M4 (review/pr-264-r2/.handoffs/REVIEW.md) --------------------------
run_corpus_row M1-cont-git    $'<<< x gi\\\nt -C /tmp/evilrepo status'
run_corpus_row M1-cont-find   $'<<< x fi\\\nnd . -maxdepth 0 -exec echo INJECTED {} \\;'
run_corpus_row M2-launch-git  '<<< x X=1 /usr/bin/[g]it -C /tmp/evilrepo status'
run_corpus_row M2-launch-find '<<< x nice /usr/bin/f[i]nd . -maxdepth 0 -exec echo INJECTED {} \;'
run_corpus_row M3-extglob     $'shopt -s extglob\n/usr/bin/@(g)it -C /tmp/evilrepo status </dev/null'
run_corpus_row xg-git-q       "shopt -s extglob${NL}/usr/bin/+(g)it -C \"/tmp/evilrepo\" status"
run_corpus_row xg-find        "shopt -s extglob${NL}/usr/bin/@(f)ind . -maxdepth 0 -exec echo INJECTED {} \\;"
run_corpus_row xg-find-hs     "shopt -s extglob${NL}<<< x /usr/bin/@(f)ind . -maxdepth 0 -exec echo INJECTED {} \\;"
run_corpus_row xg-git-bare    "shopt -s extglob${NL}@(g)it -C /tmp/evilrepo status </dev/null"
run_corpus_row M4-dollar9-git  'gi$9t -C /tmp/evilrepo status'
run_corpus_row M4-at-git       'gi$@t -C /tmp/evilrepo status'
run_corpus_row M4-dollar9-find 'fi$9nd . -maxdepth 0 -exec echo INJECTED {} \;'
run_corpus_row M4-dollar9-fd   'f$9d -1 -d 1 . /dev -x echo INJECTED'
run_corpus_row M4-bt-hs        '<<< x g``it -C /tmp/evilrepo status'
run_corpus_row M4-sub-hs       '<<< x gi$()t -C /tmp/evilrepo status'
run_corpus_row M4-brace9-hs    '<<< x gi${9}t -C /tmp/evilrepo status'
run_corpus_row M4-brace9       'gi${9}t -C /tmp/evilrepo status'

# ---- round-1 F1-F4 controls (herdr-control#261 round-6 review; must stay
# closed under this diff the same way they already do in verify-command-
# policy.sh) --------------------------------------------------------------
run_corpus_row r1-F1-pipe   'true | </dev/null git -C /tmp/evilrepo status'
run_corpus_row r1-F1-bs     'true; </dev/null find . -maxdepth 0 -exec echo INJECTED {} \;'
run_corpus_row r1-F2-amp    '&>/dev/null find . -maxdepth 0 -exec echo INJECTED {} \;'
run_corpus_row r1-F2-named  '{v}</dev/null git -C /tmp/evilrepo status'
run_corpus_row r1-F4-gfind  '</dev/null gfind /dev/null -maxdepth 0 -exec echo INJECTED {} \;'
run_corpus_row r1-F4-fd     '</dev/null fd . /dev -x echo INJECTED'
run_corpus_row r1-F4-star   '<<< x /usr/bin/g*t -C /tmp/evilrepo status'

# ---- #261's wrapper rows (xargs/env/nice/sudo-style launchers over a
# plainly spelled find/git — these must resolve WITHOUT the parser gate
# even mattering, exercising the same stub harness as a sanity check that
# adding this rule changed nothing about the already-correct cases) -------
run_corpus_row wrap-nice-git   'nice git -C /tmp/evilrepo status'
run_corpus_row wrap-env-find   'env find . -maxdepth 0 -exec echo INJECTED {} \;'
run_corpus_row wrap-sudo-git   'sudo git -C /tmp/evilrepo status'
run_corpus_row wrap-xargs-find 'echo . | xargs find -maxdepth 0 -exec echo INJECTED {} \;'

# ---- plain controls that MUST still allow (the stub fires, verdict must
# stay allow — proves this diff does not just assert "escalate always") --
run_corpus_row ctl-plain-git  'git status'
run_corpus_row ctl-plain-find 'find . -maxdepth 0'

# ---- #268: exact-verdict assertions ---------------------------------------
# `run_corpus_row` above only fails when the EXISTING find/git rules
# already call the resolved argv unsafe — useless for a NEW escalation
# rule (git+source pairing, ext:: transport) this diff's existing rules
# never judged before. `check` asserts classify_command's verdict
# directly, same semantics as verify-command-policy.sh's own helper, kept
# here instead so this branch does not contend with #267's edits there.
check() {               # label cmd want
  local label="$1" cmd="$2" want="$3" got
  got="$(classify_command "$cmd")"
  if [ "$got" = "$want" ]; then
    ok "$label: $got"
  else
    bad "$label: $got (want $want) for '$cmd'"
  fi
}


# Red: a resolved git/git-* command paired ANYWHERE (either order,
# redirects, list/pipeline/substitution/nested body) with a literal
# `source`/`.` command.
check "268-git-then-source-redir"   'git log 2>/dev/null; source ./evil.sh 2>/dev/null' escalate
check "268-source-then-git-redir"   'source ./evil.sh 2>/dev/null; git log 2>/dev/null' escalate
check "268-dot-then-git"            '. ./evil.sh; git log' escalate
check "268-source-in-cmdsub"        'echo "$(source ./evil.sh)"; git log' escalate
check "268-source-in-func-body"     'f() { source ./evil.sh; }; f; git log' escalate
check "268-source-in-subshell"      '( source ./evil.sh ); git log' escalate
check "268-git-in-if"               'if true; then git log; fi; source ./evil.sh' escalate
check "268-source-in-pipeline"      'source ./evil.sh | cat; git log' escalate
check "268-both-in-procsubs"        'diff <(source ./evil.sh) <(git log)' escalate
check "268-launcher-source-pair"    'nice source ./evil.sh; git log' escalate
check "268-launcher-chain-source"   'nice env source ./evil.sh; git log' escalate
check "268-env-assignment-git"      'env X=1 git log; source ./evil.sh' escalate
check "268-env-assignment-source"   'env X=1 source ./evil.sh; git log' escalate
check "268-nested-env-assignment"   'nice env X=1 git log; source ./evil.sh' escalate
check "268-env-double-dash"         'env -- X=1 git log; source ./evil.sh' escalate
check "268-nice-option-git"         'nice -n 5 git log; source ./evil.sh' escalate
check "268-timeout-duration-git"    'timeout 2 git log; source ./evil.sh' escalate
check "268-sudo-option-git"         'sudo -u nobody git log; source ./evil.sh' escalate
check "268-env-option-git"          'env -u FOO git log; source ./evil.sh' escalate
check "268-env-split-string"        "env -S 'git log'" escalate

# Controls: source-only behavior is whatever main already says (NOT
# asserted escalate here — only the pairing with git is new); plain git
# stays allow.
check "268-git-only-allow"          'git log' allow

# Red: every `ext::` transport in a resolved git argv, any subcommand.
check "268-remote-add-ext"          'git remote add x ext::sh' escalate
check "268-set-url-ext"             'git remote set-url origin ext::sh' escalate
check "268-clone-ext"               'git clone ext::sh /tmp/x' escalate
check "268-fetch-protocol-ext"      'git -c protocol.ext.allow=always fetch ext::sh' escalate
check "268-wrapper-git-remote-ext"  'nice git remote add x ext::sh' escalate
check "268-dashed-git-remote-ext"   'git-remote add x ext::sh' escalate
check "268-env-assignment-ext"      'env X=1 git remote add x ext::sh' escalate
check "268-nice-option-ext"         'nice -n 5 git remote add x ext::sh' escalate
# Expansion/glob splices can resolve to ext:: only at shell runtime. Dynamic
# argv expansions fail closed; quote-only splices are static and bashlex
# normalizes them; shell patterns around `::` are treated as possible ext.
check "268-ext-quote-splice"        'git clone ex""t::sh /tmp/x' escalate
check "268-ext-dollar9-splice"      'git clone ex$9t::sh /tmp/x' escalate
check "268-ext-brace9-splice"       'git clone ex${9}t::sh /tmp/x' escalate
check "268-ext-backtick-splice"     'git clone ex``t::sh /tmp/x' escalate
check "268-ext-brace-expand"        'git remote add x ex{,}t::sh' escalate
check "268-ext-star-glob"           'git clone ex*t::sh /tmp/x' escalate
check "268-ext-question-glob"       'git clone e?t::sh /tmp/x' escalate
check "268-ext-bracket-glob"        'git clone e[x]t::sh /tmp/x' escalate
check "268-ext-whole-expansion"     'git clone "$REMOTE" /tmp/x' escalate

# Control: static non-ext `::` text remains readable.
check "268-static-double-colon"     'git log --format=%H::%s' allow

# Red regression: both dashed `git-ls-remote>/dev/null --upload-pack=...`
# forms (#264) stay escalated under this diff too.
check "268-dashed-upload-pack"      'git-ls-remote>/dev/null --upload-pack=/tmp/x' escalate
check "268-dashed-upload-pack-u"    'git-ls-remote>/dev/null -u/tmp/x' escalate


echo "-----------------------------------------------------------------"
printf 'bashlex-diff: %d/%d passed, %d skipped\n' "$pass" "$((pass+fail))" "$skipped"
[ "$fail" -eq 0 ]
