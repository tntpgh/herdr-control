#!/usr/bin/env bash
# Start a NEW repo from an existing one's code without inheriting its git history
# — and prove the result is clean before the first commit.
#
# Why this exists (2026-09-03): knowledge-base carried four credentials and two
# client-PII caches in history. Three of the four were already scrubbed from the
# tip, so the tip TREE was clean while every clone still shipped the secrets.
# `git filter-repo` on a 946-commit / 135-branch repo breaks every existing clone
# and still cannot recall copies already distributed. Extracting the tree and
# starting a fresh history sidesteps all of that in one move.
#
# The trap this tool exists to catch: dropping history fixes CREDENTIALS but does
# NOT fix PII baked into the tree. The same audit found 72 distinct real client
# addresses at the tip of knowledge-base — in test fixtures, in
# server/entity_graph.py, and in a tracked connectors/*.json — and 32 of a
# 40-value sample matched live entities in the production graph. A fresh history
# would have carried every one of them into the new project.
#
#   usage: fresh-extract.sh <src-repo> <ref> <dest-dir> [--init] [--force]
#
#     --init   run `git init` + first commit, but ONLY if the scan is clean
#     --force  init even with findings (records them in the commit message)
#
# Exit 0 = clean. Exit 3 = findings. Exit 2 = usage/precondition error.
set -euo pipefail

SRC="${1:-}"; REF="${2:-}"; DEST="${3:-}"; shift 3 2>/dev/null || true
DO_INIT=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --init)  DO_INIT=1 ;;
    --force) FORCE=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done
[ -n "$SRC" ] && [ -n "$REF" ] && [ -n "$DEST" ] || {
  sed -n '25,31p' "$0" >&2; exit 2; }
[ -d "$SRC/.git" ] || { echo "not a git repo: $SRC" >&2; exit 2; }
[ -e "$DEST" ] && { echo "destination already exists: $DEST" >&2; exit 2; }

# Resolve the ref in the SOURCE repo before extracting: a typo'd ref must fail
# loudly here rather than silently produce an empty tree. `git archive` on a bad
# ref does error, but naming the resolved sha in the report is what makes the
# extraction auditable later.
SHA="$(git -C "$SRC" rev-parse --verify "$REF^{commit}")" || {
  echo "cannot resolve ref '$REF' in $SRC" >&2; exit 2; }

mkdir -p "$DEST"
git -C "$SRC" archive "$SHA" | tar -x -C "$DEST"
echo "extracted $(git -C "$SRC" rev-parse --short "$SHA") ($REF) -> $DEST"
echo "  files: $(find "$DEST" -type f | wc -l | tr -d ' ')   history: none (this is the point)"
echo

FINDINGS=0
SKIP_DIR='/(\.git|node_modules|\.venv|__pycache__|dist|build)/'
SKIP_EXT='\.(png|jpe?g|gif|ico|pdf|woff2?|eot|tt[fc]|otf|zip|gz|tar|bin|db|sqlite3?|lock|pyc)$'

_files() {
  find "$DEST" -type f | grep -Ev "$SKIP_DIR" | grep -Ev "$SKIP_EXT"
}

# ── 1. credentials ──────────────────────────────────────────────────────────
# Reuses the SAME pattern list as the shared pre-commit guard, so the two can
# never drift into disagreeing about what a secret looks like. If that file
# moves, this must fail loudly rather than silently scan nothing.
GUARD="$HOME/.claude/hooks/secret-scan-pre-commit.sh"
echo "== credentials =="
if [ -r "$GUARD" ]; then
  # shellcheck disable=SC1090
  PATTERNS=()
  eval "$(sed -n '/^PATTERNS=(/,/^)/p' "$GUARD")"
  echo "  using ${#PATTERNS[@]} patterns from the shared guard"
  for P in "${PATTERNS[@]}"; do
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      echo "  FOUND  ${f#"$DEST"/}  <- /$P/"
      FINDINGS=$((FINDINGS + 1))
    done < <(_files | xargs -r grep -lE "$P" 2>/dev/null || true)
  done
  [ "$FINDINGS" -eq 0 ] && echo "  clean"
else
  echo "  ERROR: shared guard not readable at $GUARD — refusing to report 'clean'" >&2
  FINDINGS=$((FINDINGS + 1))
fi
echo

# ── 2. PII, which dropping history does NOT fix ─────────────────────────────
# Synthetic values are allowed and expected in fixtures. The point is to force a
# decision on every value that does NOT look synthetic, not to ban test data.
#   phones : 555-0100..555-0199 are reserved for fiction (and 555-01xx broadly)
#   emails : example.com / example.org / example.net are RFC 2606 reserved
#   streets: no reserved standard, so a local convention list is used
echo "== PII (real-looking values that a fresh history would carry forward) =="
PII_REPORT="$(python3 - "$DEST" <<'PY'
import re, sys, pathlib, collections
root = pathlib.Path(sys.argv[1])
skip_dir = re.compile(r'/(\.git|node_modules|\.venv|__pycache__|dist|build)/')
skip_ext = {'.png','.jpg','.jpeg','.gif','.ico','.pdf','.woff','.woff2','.eot','.ttf',
            '.otf','.zip','.gz','.tar','.bin','.db','.sqlite','.sqlite3','.lock','.pyc'}

PHONE  = re.compile(r'\b(?:\+?1[-. ]?)?\(?\d{3}\)?[-. ]\d{3}[-. ]\d{4}\b')
EMAIL  = re.compile(r'\b[\w.+-]+@[\w-]+\.[a-z]{2,}\b', re.I)
STREET = re.compile(r'\b\d{2,5} [A-Z][a-z]+(?: [A-Z][a-z]+)? '
                    r'(?:Dr|Rd|St|Ave|Ct|Ln|Way|Blvd|Road|Street|Drive|Avenue|Court|Lane)\b')

SYNTH_STREET = re.compile(r'\b(Main|Elm|Oak|Test|Example|Fake|Sample|Anywhere|Nowhere|'
                          r'Maple|Pine|First|Second|Foo|Bar)\b', re.I)
SYNTH_NUM    = re.compile(r'^(123|456|789|1234|100|111|999)\b')
SYNTH_EMAIL  = re.compile(r'@(example\.(com|org|net)|test\.|localhost|invalid$|'
                          r'teamthurber\.com)', re.I)
SYNTH_PHONE  = re.compile(r'555[-. ]?01\d\d')

found = collections.defaultdict(lambda: collections.defaultdict(set))
for p in root.rglob('*'):
    if not p.is_file() or skip_dir.search(str(p)) or p.suffix.lower() in skip_ext:
        continue
    try:
        text = p.read_text(errors='ignore')
    except OSError:
        continue
    rel = str(p.relative_to(root))
    for v in PHONE.findall(text):
        if not SYNTH_PHONE.search(v): found['phone'][rel].add(v)
    for v in EMAIL.findall(text):
        if not SYNTH_EMAIL.search(v): found['email'][rel].add(v)
    for v in STREET.findall(text):
        if not (SYNTH_STREET.search(v) or SYNTH_NUM.match(v)): found['street'][rel].add(v)

total = 0
for kind in ('street', 'phone', 'email'):
    files = found[kind]
    distinct = len({v for s in files.values() for v in s})
    total += distinct
    if not files:
        print(f"  {kind:7} clean")
        continue
    print(f"  {kind:7} {distinct} distinct real-looking value(s) in {len(files)} file(s)")
    for rel, vals in sorted(files.items(), key=lambda kv: -len(kv[1]))[:10]:
        print(f"          {len(vals):3} distinct  {rel}")
print(f"\n  PII_TOTAL={total}")
PY
)"
echo "$PII_REPORT" | grep -v '^  PII_TOTAL='
# Parsed from the single scan above rather than re-running it: one pass, one
# source of truth for both the human report and the exit status.
PII_TOTAL="$(printf '%s\n' "$PII_REPORT" | sed -n 's/^  PII_TOTAL=//p')"
PII_TOTAL="${PII_TOTAL:-0}"

echo "== verdict =="
if [ "$FINDINGS" -gt 0 ]; then
  echo "  $FINDINGS credential finding(s) — DO NOT commit this tree as-is."
else
  echo "  credentials: clean"
fi
echo "  PII: $PII_TOTAL distinct real-looking value(s) in the tree"
cat <<'NOTE'
       A non-zero count is not automatically a blocker — it is a decision. Each
       value must be replaced with a synthetic one or consciously accepted.
       Dropping git history does NOTHING about these: they are in the files.
NOTE

if [ "$DO_INIT" -eq 1 ]; then
  if [ "$FINDINGS" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
    echo "  refusing --init with credential findings (pass --force to override)" >&2
    exit 3
  fi
  git -C "$DEST" init -q
  git -C "$DEST" add -A
  git -C "$DEST" commit -q -m "initial commit

Extracted from $(basename "$SRC") at $(git -C "$SRC" rev-parse --short "$SHA") ($REF)
with NO inherited git history, via herdr-control/fresh-extract.sh.

History was deliberately not carried over: the source repo's history contained
credentials that had already been scrubbed from its tip, so every clone shipped
secrets the working tree no longer showed. A fresh history is the only removal
that cannot be undone by a stale clone.

Credential scan: $FINDINGS finding(s) using the shared pre-commit pattern list.
PII scan: see the tool's report; real-looking values in the tree are NOT removed
by starting a fresh history and must be handled separately."
  echo "  git history initialized: $(git -C "$DEST" rev-parse --short HEAD)"
fi

[ "$FINDINGS" -gt 0 ] && exit 3
exit 0
