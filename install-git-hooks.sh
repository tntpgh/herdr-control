#!/usr/bin/env bash
# install-git-hooks.sh — point every ~/Code repo's `pre-commit` AND
# `pre-merge-commit` at the TRACKED secret scanner in this checkout.
#
# WHY THIS IS A SECOND INSTALLER, not part of install.sh: install.sh wires THIS
# MACHINE's agent tooling (Claude settings.json hooks, the omp extension symlink,
# launchd plists) into this checkout. Everything it touches belongs to the user's
# agent environment. This script mutates OTHER PEOPLE'S REPOSITORIES — 18 of them
# — which is a different blast radius, needs its own --undo, and must never be a
# side effect of "wire herdr-control into Claude Code". Read install.sh's header
# before merging the two; the conclusion there was that they stay separate.
#
# WHY IT EXISTS AT ALL: the scanner used to live only at
# ~/.claude/hooks/secret-scan-pre-commit.sh — untracked, unreviewed, no history,
# no CI — and 18 repos executed it on every commit. It carried a real bypass
# (--diff-filter=ACM omitting renames) for an unknown length of time. Pointing
# the fleet at a tracked, tested copy is what makes the next fix reviewable.
#
#   bash install-git-hooks.sh              # DRY RUN — show what would change
#   bash install-git-hooks.sh --dry-run    # same thing, said out loud
#   bash install-git-hooks.sh --apply      # make the changes
#   bash install-git-hooks.sh --undo       # restore what --apply replaced
#   bash install-git-hooks.sh --apply --allow-unreviewed=<reason>
#                                          # deploy a scanner origin/main does
#                                          # NOT carry (a fix that must go live
#                                          # before its PR merges). Recorded in
#                                          # .rev as reviewed: no, with the
#                                          # reason and a 7-day expiry that
#                                          # VERIFY gets louder about.
#
# Dry run is the DEFAULT, matching install.sh: a script that rewrites hooks in 18
# repositories should not do it because someone typed its name.
#
# WHAT IT WILL NOT TOUCH:
#   * a directory that is not a git repository
#   * a linked WORKTREE — worktrees share the main repo's hooks dir, so they are
#     already covered by their parent and writing there would be a duplicate
#     write to the same file under a second name
#   * a repo running NO secret scan today. That repo made a different choice and
#     this script does not overrule it; opting it in is a separate decision.
#   * a hook this script did not write and does not recognise as the fleet shim
#     — someone's own pre-commit is reported and left exactly alone.
#
# IDEMPOTENT: a hook already pointing at this checkout is left untouched. Safe to
# re-run; safe to re-run after --undo.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# GIT ENVIRONMENT, UNSET FIRST. Every provenance question below is asked with
# `git -C "$here"`, and an inherited GIT_DIR/GIT_WORK_TREE OVERRIDES -C
# discovery — so the reviewed-check, the revision record and the VERIFY
# comparison would all answer about a DIFFERENT repository than the file being
# deployed. Demonstrated by review: with only GIT_DIR changed, a weakened
# scanner that is correctly refused gets deployed with `reviewed: yes`, a
# plausible `rev: <sha> main clean`, and `matches origin/main: yes`. git sets
# GIT_DIR for every hook, alias, `rebase -x`, `bisect run` and filter
# subprocess, so this arrives by inheritance, not by an attacker.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CEILING_DIRECTORIES

HOOK_SRC="$here/git-hooks/secret-scan-pre-commit.sh"

# The installed shim embeds $here — the absolute path of the checkout this ran
# from — so installing from a DISPOSABLE checkout points every hook in every
# repo at a path that is about to vanish. This is not hypothetical: this
# script's own first dry run was executed from /tmp/w-secret-guard, a linked
# worktree that no longer exists. Had that been `--apply`, all ~36 hooks across
# ~18 repos would now die with a bare `bash: .../secret-scan-pre-commit.sh: No
# such file or directory` on every commit — fail-closed, fleet-wide, and the
# fastest possible route to a `--no-verify` habit, which is the one outcome this
# guard cannot survive.
#
# So refuse: a linked worktree (its .git is a FILE, not a directory) or any
# checkout under a temp root is not a home for 36 hook shims. --dry-run is
# always allowed, because seeing what would happen from anywhere is harmless.
_disposable=""
case "$here" in
  /tmp/*|/private/tmp/*|/var/folders/*|"${TMPDIR:-/nonexistent}"*) _disposable="a temp directory" ;;
esac
[ -z "$_disposable" ] && [ -f "$here/.git" ] && _disposable="a linked git worktree"
LEGACY_SRC="$HOME/.claude/hooks/secret-scan-pre-commit.sh"
MARK="# installed by herdr-control install-git-hooks.sh"
# The predecessor's marker. Its hooks are ours to replace: same content, written
# by /tmp/install-merge-hooks.sh on 2026-09-12 before the scanner was tracked.
LEGACY_MARK="# installed by install-merge-hooks.sh 2026-09-12"
BACKUP_SUFFIX=".pre-herdr-guard"
ROOT="${CODE_ROOT:-$HOME/Code}"

MODE=dry
ALLOW_UNREVIEWED=0
ALLOW_UNREVIEWED_REASON=""
for a in "$@"; do
  case "$a" in
    --dry-run) MODE=dry ;;
    --apply)   MODE=apply ;;
    --undo)    MODE=undo ;;
    --allow-unreviewed=*)
      ALLOW_UNREVIEWED=1
      # SANITISED on parse. The reason is interpolated into .rev, and both
      # consumers used to ask `grep -q '^reviewed: *yes'` ANYWHERE in the file —
      # so a newline in the reason forged a `reviewed:   yes` line and silenced
      # every unreviewed warning, on a record that simultaneously said
      # `reviewed: no`. An audit record that the audited party can write lines
      # into is not a record.
      ALLOW_UNREVIEWED_REASON=$(printf '%s' "${a#*=}" | tr -d '\n\r' | cut -c1-200)
      ;;
    --allow-unreviewed)
      echo "REFUSING: --allow-unreviewed needs a reason: --allow-unreviewed=<why>" >&2
      echo "  It puts a scanner no review approved in front of 18 repositories," >&2
      echo "  and the reason is what makes the record answerable later." >&2
      exit 2 ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# `--allow-unreviewed=` — one keystroke past the bare form — used to set the
# flag with an empty reason and record "(none given)", defeating the entire
# justification for requiring one. Whitespace-only is the same thing.
if [ "$ALLOW_UNREVIEWED" = 1 ]; then
  case "$(printf '%s' "$ALLOW_UNREVIEWED_REASON" | tr -d '[:space:]')" in
    "") echo "REFUSING: --allow-unreviewed needs a REASON, not an empty one." >&2
        echo "  It puts a scanner no review approved in front of 18 repositories," >&2
        echo "  and the reason is what makes the record answerable later." >&2
        echo "    bash $0 --apply --allow-unreviewed='#89 detector hotfix'" >&2
        exit 2 ;;
  esac
fi

# These are the user's own repositories. Running this under sudo would write
# root-owned hook files into all of them, which silently breaks every later
# commit as the normal user.
if [ "$(id -u)" = "0" ]; then
  echo "REFUSING: run as yourself, not root — these are your user's repositories." >&2
  exit 2
fi
[ -r "$HOOK_SRC" ] || { echo "REFUSING: tracked scanner not readable at $HOOK_SRC" >&2; exit 2; }
# A scanner that cannot run is worse than none: it would exit non-zero on every
# commit and teach --no-verify. Prove it parses before pointing 18 repos at it.
bash -n "$HOOK_SRC" || { echo "REFUSING: $HOOK_SRC is not valid bash" >&2; exit 2; }

HOOK_DEPLOY_DIR="${HERDR_HOOK_DEPLOY_DIR:-$HOME/.local/share/herdr-control/hooks}"
HOOK_DEPLOY="$HOOK_DEPLOY_DIR/secret-scan-pre-commit.sh"
HOOK_DEPLOY_REV="$HOOK_DEPLOY_DIR/.rev"

# The $here refusal above was written when the shim exec'd "$here/git-hooks/...".
# It no longer does — see HOOK_DEPLOY below; the installed shim is
#   exec bash ~/.local/share/herdr-control/hooks/secret-scan-pre-commit.sh --push "$@"
# so the scanner is COPIED to a stable path and the source checkout may vanish
# immediately afterwards without breaking a single hook. Refusing a linked
# worktree therefore protects nothing, and it has a cost that showed up the
# moment it mattered: on 2026-09-16 the fleet was running an unreviewed branch
# and the only permanent checkout was in use by another session on that very
# branch, so the correct fix — deploy origin/main from a clean worktree — was
# the one thing this refusal forbade.
#
# What actually matters is WHAT is deployed, not WHERE it was read from, and
# that is gated below by _src_reviewed. A disposable source now warns.
if [ -n "$_disposable" ] && [ "$MODE" != dry ]; then
  echo "note: source checkout is $_disposable ($here)."
  echo "  Harmless — the scanner is copied to $HOOK_DEPLOY_DIR"
  echo "  and the shims point THERE, so this path may disappear afterwards."
fi

# WHERE THE SHIM POINTS. Not into the working tree.
#
# Pointing at "$here/git-hooks/..." looks elegant — a fix in the checkout is
# live everywhere with no reinstall — but the path only exists on branches that
# carry the file. Reproduced live on 2026-09-15: hooks installed while this
# branch was checked out, then the checkout moved to a branch predating the
# tracked scanner, and every commit in all 18 repos died with
#   bash: /Users/thurbs/Code/herdr-control/git-hooks/secret-scan-pre-commit.sh:
#   No such file or directory
# The guard fails closed, which is right, but a guard that breaks every commit
# whenever someone changes branch is a guard that gets bypassed within a day.
#
# So --apply COPIES the tracked scanner to a stable path outside any working
# tree and points the shims there. Re-running --apply refreshes the copy, which
# is the one step a scanner change now needs. `git-hooks/` stays the source of
# truth; this is its deployment.

# WHICH REVISION the fleet runs — recorded, and checked before it is written.
#
# Measured 2026-09-16: every one of the 18 repos was executing the scanner
# from an OPEN pull request (#88, carrying a CHANGES REQUESTED verdict with
# two HIGH findings), and three PII cases that origin/main blocks were allowed
# fleet-wide: an allowlisted business address laundering a third-party address
# on the same line, a larger house number ending in an allowlisted one, and a
# second phone number after a business phone sharing one separator. The exact
# inputs are in verify-secret-scan.sh, which is where address- and
# phone-shaped fixtures are allowed to live.
# Nothing was broken and nothing lied. The shared checkout had been switched
# to that branch, `--apply` copied whatever `git-hooks/` held at that instant,
# and the copy outlived the branch switch. `$here` was checked for being
# DISPOSABLE but never for being REVIEWED, and the copy carried no provenance,
# so "which revision is the fleet's only credential guard running?" could only
# be answered by diffing blobs by hand.
#
# Same defect the hub had before #84: the thing that answers was whatever
# happened to be checked out. Same fix — deploy a known revision, record it,
# and make the mismatch loud.
# The repo we ask about MUST be the repo the file came from. Without this, a
# `$here` that is not a checkout at all (a tarball extract, a `cp -R` copy)
# answers every question with a failure that used to read as "unknown", and
# unknown used to deploy.
_src_repo_ok() {
  local top srcdir
  top=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || return 1
  # BOTH sides physically resolved. On macOS /var, /tmp and /etc are symlinks
  # into /private, so `rev-parse --show-toplevel` answers /private/var/... for
  # a checkout the caller reached as /var/... — a plain prefix test then fails
  # for a perfectly good repo. It fails CLOSED (the deploy is refused), but the
  # refusal blames a missing origin/main, which is the wrong reason and would
  # send someone hunting a remote that is fine.
  top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  srcdir=$(cd "$(dirname "$HOOK_SRC")" 2>/dev/null && pwd -P) || return 1
  case "$srcdir/" in
    "$top"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Blob OIDs, not command substitution. `[ "$(git show ...)" = "$(cat ...)" ]`
# compares content MODULO TRAILING NEWLINES, because `$(...)` strips them — so
# two files whose sha256 differ compared equal and the report said
# "matches origin/main: yes" while the bytes did not. Review reproduced it by
# appending two newlines. A blob OID is exact and is also what git itself uses.
# FULLY QUALIFIED refs only. `origin/main` is an AMBIGUOUS refname: git resolves
# refs/heads/<name> and refs/tags/<name> BEFORE refs/remotes/<name>, so a local
# branch or tag literally called `origin/main` — `git branch origin/main`, or
# any tool that mirrors remote names locally — becomes the thing this gate
# compares against. Review deployed a weakened scanner that way with rc=0,
# `reviewed: yes`, `main-blob` equal to it and `matches origin/main: yes`. git
# does warn that the name is ambiguous, but both call sites discarded stderr, so
# it was invisible. A TAG is the worst case: fetch never prunes it, so the false
# anchor is permanent.
MAIN_REF=refs/remotes/origin/main
_blob_at() {                              # <ref> -> OID on stdout, or nothing
  git -C "$here" rev-parse -q --verify "$1:git-hooks/secret-scan-pre-commit.sh" 2>/dev/null
}

# IDENTITY, THREE TIMES, AND THEY ARE DIFFERENT QUESTIONS.
#
# 1. "Is this the checkout of the reviewed blob?" — provenance, and the one the
#    gate and the report ask. Answered with `git hash-object --path <tracked
#    path>`, which applies the attributes of the TRACKED path to whatever file
#    it is given. That is what makes a snapshot named `…sh.new.$$` hash as if it
#    were `…sh`, and that asymmetry is what produced the first defect here:
#    plain `hash-object` applies gitattributes BY PATH, so two byte-identical
#    files hashed differently and a correct deploy was refused as "differs from
#    refs/remotes/origin/main" — or, past the gate, went live with no record at
#    all while `cmp` called the bytes identical.
#
#    Raw `cat-file blob | cmp` was the first fix and it was wrong in the other
#    direction: in any checkout that normalises this path (`text`,
#    `eol=crlf`, or core.autocrlf=true) the working file LEGITIMATELY differs
#    from the blob — measured at 33 bytes vs 35 — so a pristine checkout with no
#    local edit would be refused on every run, with no operator-side fix and one
#    obvious reflex: `--allow-unreviewed`, the exact habit this control exists
#    to prevent.
#
# 2. "Are the bytes now live the bytes I judged?" — integrity across the rename,
#    answered by sha256 of the same file before and after, which is immune to
#    attributes and to path entirely. Unchanged.
#
# 3. The human-readable blob: field, `--no-filters`, so the record names the
#    literal bytes on disk whatever the attributes say.
_TRACKED=git-hooks/secret-scan-pre-commit.sh
_oid_as_tracked() {                       # <file> -> OID as if it were $_TRACKED
  git -C "$here" hash-object --path "$_TRACKED" -- "$1" 2>/dev/null
}
_same_as_main() {                         # <file> -> 0 if it is the reviewed blob
  local a b
  a=$(_oid_as_tracked "$1"); b=$(_blob_at "$MAIN_REF")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}
_same_as_head() {                         # <file> -> 0 if it is HEAD's blob
  local a b
  a=$(_oid_as_tracked "$1"); b=$(_blob_at HEAD)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}
_oid_of() { git hash-object --no-filters "$1" 2>/dev/null; }
_sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# ONE SNAPSHOT is copied, judged, installed and recorded.
#
# The first version read HOOK_SRC twice: `cat` for the reviewed-check, `cp` for
# the deploy. Review won that race on iteration 4 of 40 with a background
# writer doing atomic `mv`s — the deployed copy was the WEAKENED file and .rev
# affirmatively recorded `reviewed: yes` with the sha256 of the weakened bytes,
# so even the stale-record check could not fire. In the workflow this very
# change describes (a sibling session switching branches in the shared
# checkout) that writer is not hypothetical.
#
# So: copy FIRST, then judge the copy, then rename it into place. Everything
# below — the gate, the record, the hash — describes $tmp, the exact bytes that
# become the fleet's scanner.
#
# Returns: 0 deployed · 1 could not deploy (nothing installed) · 3 refused as
# unreviewed (nothing installed) · 4 installed but the record could not be
# written (the fleet IS running the new bytes).
DEPLOY_REVIEWED=unknown
DEPLOY_REV=""
DEPLOY_SNAP_OID=""
DEPLOY_SNAP_SHA=""
DEPLOY_SNAP=""
DEPLOY_MAIN_OID=""

# JUDGE, then INSTALL — two steps, because a dry run must be able to reach the
# verdict without touching anything. The gate used to live inside the install
# path, so `--dry-run` said nothing at all about the one decision --apply makes:
# from a weakened checkout it printed WOULD REPOINT for every repo and not a
# word about review, and `--dry-run --allow-unreviewed` was byte-identical to a
# plain dry run. A preview that omits the thing which decides whether --apply
# refuses is not a preview.
# <workspace-dir> — where the snapshot is taken. A DRY RUN passes a TEMP dir,
# because this used to `mkdir -p` the LIVE deploy directory and write
# `secret-scan-pre-commit.sh.new.<pid>` beside the fleet's scanner immediately
# after printing "nothing will be changed" — and an interrupted dry run left
# that file sitting there. --apply still snapshots beside the target, so the
# rename stays atomic and on one filesystem.
#
# -> 0 judged (verdict in DEPLOY_*) · 1 source unusable · 2 workspace unusable
judge_snapshot() {                        # <workspace-dir>
  local ws="${1:?judge_snapshot needs a workspace}"
  mkdir -p "$ws" 2>/dev/null || return 2
  DEPLOY_SNAP="$ws/secret-scan-pre-commit.sh.new.$$"
  : > "$DEPLOY_SNAP" 2>/dev/null || return 2
  cp "$HOOK_SRC" "$DEPLOY_SNAP" || { rm -f "$DEPLOY_SNAP"; return 1; }
  chmod 0755 "$DEPLOY_SNAP" || { rm -f "$DEPLOY_SNAP"; return 1; }
  # A scanner that cannot run is worse than none: it would fail every commit
  # and teach --no-verify.
  bash -n "$DEPLOY_SNAP" || { rm -f "$DEPLOY_SNAP"; return 1; }

  DEPLOY_SNAP_OID=$(_oid_of "$DEPLOY_SNAP")
  DEPLOY_SNAP_SHA=$(_sha_of "$DEPLOY_SNAP")
  local head_oid sha br state
  if _src_repo_ok; then
    DEPLOY_MAIN_OID=$(_blob_at "$MAIN_REF")
    head_oid=$(_blob_at HEAD)
    sha=$(git -C "$here" rev-parse --short HEAD 2>/dev/null)
    br=$(git -C "$here" rev-parse --abbrev-ref HEAD 2>/dev/null)
    # clean/dirty/absent by BLOB IDENTITY, not by `git diff --quiet`, which
    # exits 0 both for "unmodified" and for "this path is not in HEAD at all"
    # (untracked, gitignored, or a symlink out of the tree). Review deployed a
    # weakened untracked scanner that .rev then called `clean` against a commit
    # which did not contain it.
    if [ -z "$head_oid" ]; then state=absent-from-HEAD
    elif _same_as_head "$DEPLOY_SNAP"; then state=clean
    else state=dirty; fi
    DEPLOY_REV="${sha:-unknown} ${br:-DETACHED} $state"
  else
    DEPLOY_REV="unknown (not a git checkout, or $HOOK_SRC is outside it)"
  fi

  if [ -z "$DEPLOY_MAIN_OID" ]; then
    DEPLOY_REVIEWED="no (no $MAIN_REF to compare)"
  elif _same_as_main "$DEPLOY_SNAP"; then
    DEPLOY_REVIEWED=yes
  else
    DEPLOY_REVIEWED="no (differs from $MAIN_REF)"
  fi
}

# Returns: 0 installed · 1 could not install · 4 installed but the record could
# not be written (the fleet IS running the new bytes) · 5 the bytes that went
# live are not the bytes that were judged.
install_snapshot() {
  mv -f "$DEPLOY_SNAP" "$HOOK_DEPLOY" || { rm -f "$DEPLOY_SNAP"; return 1; }

  # POST-CONDITION, measured rather than asserted. This is the real defence for
  # the property a structural test row kept failing to pin: three separate
  # textual evasions satisfied that row, and one of them — recording `blob:`
  # from a fresh read of the SOURCE — passed all 68 rows while reintroducing
  # exactly the provenance defect this change exists to fix. Measuring what is
  # live closes the class instead of describing it.
  local live_sha live_oid
  live_sha=$(_sha_of "$HOOK_DEPLOY")
  live_oid=$(_oid_of "$HOOK_DEPLOY")
  [ -n "$live_sha" ] && [ "$live_sha" = "$DEPLOY_SNAP_SHA" ] || return 5

  # Provenance beside the copy, written to a temp and renamed so two concurrent
  # runs cannot tear it. `blob:` and `sha256:` are measured FROM THE INSTALLED
  # FILE, never from the source or from an intention.
  local rtmp="$HOOK_DEPLOY_REV.new.$$"
  {
    printf 'rev:        %s\n' "$DEPLOY_REV"
    printf 'source:     %s\n' "$HOOK_SRC"
    printf 'blob:       %s\n' "$live_oid"
    printf 'reviewed:   %s\n' "$DEPLOY_REVIEWED"
    [ "$DEPLOY_REVIEWED" = yes ] || {
      printf 'reason:     %s\n' "${ALLOW_UNREVIEWED_REASON:-(none given)}"
      printf 'expires:    %s\n' "$(_expiry_iso)"
    }
    printf 'main-ref:   %s\n' "$MAIN_REF"
    printf 'main-blob:  %s\n' "${DEPLOY_MAIN_OID:-none}"
    printf 'main-dated: %s\n' "$(git -C "$here" log -1 --format=%cI "$MAIN_REF" 2>/dev/null || printf unknown)"
    printf 'deploy-dir: %s\n' "$HOOK_DEPLOY_DIR"
    printf 'sha256:     %s\n' "$live_sha"
    printf 'deployed:   %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$rtmp" 2>/dev/null && mv -f "$rtmp" "$HOOK_DEPLOY_REV" 2>/dev/null || {
    rm -f "$rtmp"
    return 4
  }
}

# An unreviewed deployment gets a deadline, because "deliberate, recorded and
# permanent until someone remembers" is weaker than this file's own doctrine for
# the one control between a credential and a push. Nothing consults .rev at
# commit time (the shims exec the scanner directly), so the deadline is a
# REPORTING deadline: VERIFY gets louder once it passes.
UNREVIEWED_TTL_DAYS=7
# The FIRST `reviewed:` field, not a grep of the whole file — see the reason
# sanitising above. Both are needed: one stops the line being written, the other
# stops it mattering if it ever is.
_recorded_reviewed() {
  sed -n 's/^reviewed:[[:space:]]*//p' "$HOOK_DEPLOY_REV" 2>/dev/null | head -1 | awk '{print $1}'
}

_expiry_iso() {
  date -u -v+"${UNREVIEWED_TTL_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "+${UNREVIEWED_TTL_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf unknown
}

# The shim is one exec, so the scanner is never copied into a repo. Extra argv
# (pre-push passes `--push`) is appended verbatim, THEN git's own hook
# arguments via "$@". `exec` keeps stdin, where pre-push's ref list arrives.
#
# Forwarding "$@" is load-bearing for pre-push: git calls it as
# `pre-push <remote-name> <remote-url>`, and the scanner needs the remote to
# answer "which commits does THIS remote not have yet?". Without it the
# scanner fell back to "what no remote has", and a commit fetched from a fork
# could be pushed to origin unscanned (reproduced 2026-09-15).
hook_body() {                             # [extra scanner args...]
  printf '#!/usr/bin/env bash\n%s\nexec bash %q' "$MARK" "$HOOK_DEPLOY"
  local a
  for a in "$@"; do printf ' %q' "$a"; done
  printf ' "$@"\n'
}

# THE DEPLOY TARGET is where 54 shims will point, so it gets the same scrutiny
# the SOURCE used to get. `HERDR_HOOK_DEPLOY_DIR=/tmp/... --apply` against the
# real fleet reproduces exactly the fleet-wide fail-closed breakage the old
# source refusal existed to prevent — and the suite sets that variable on every
# run, so a copy-pasted command with one variable dropped is the realistic
# path. A temp deploy dir is fine for a TEST (which also redirects CODE_ROOT);
# it is never right for the real fleet.
case "$HOOK_DEPLOY_DIR" in
  /tmp/*|/private/tmp/*|/var/folders/*|"${TMPDIR:-/nonexistent}"*)
    # Physically resolved, not string-compared. `CODE_ROOT=$HOME/Code/` with a
    # trailing slash, or `$HOME/./Code`, walked straight past the equality test
    # and rewrote the fleet's shims to a temp path — which is exactly the outage
    # that happened here during mutation testing.
    _root_p=$(cd "$ROOT" 2>/dev/null && pwd -P)
    _fleet_p=$(cd "$HOME/Code" 2>/dev/null && pwd -P)
    if [ "$MODE" = apply ] && [ -n "$_root_p" ] && [ "$_root_p" = "$_fleet_p" ]; then
      echo "REFUSING: deploy target $HOOK_DEPLOY_DIR is under a temp root," >&2
      echo "  but CODE_ROOT is the real fleet ($ROOT). Every shim in every repo" >&2
      echo "  would exec a path that disappears on reboot — fail-closed, fleet-" >&2
      echo "  wide, on every commit. Drop HERDR_HOOK_DEPLOY_DIR, or redirect" >&2
      echo "  CODE_ROOT too if this was meant to be a test." >&2
      exit 2
    fi ;;
esac

# The state the fleet is in RIGHT NOW, printed on the refusal path too. After an
# --allow-unreviewed deployment the corrective action is to re-run --apply
# without the flag — which refuses and exits before VERIFY, so the operator
# doing the right thing was told nothing about what is executing, and the
# unreviewed scanner stayed live and unmentioned. The refusal even read as
# though nothing was at risk ("would put code no review has approved in front
# of every commit") when it already had.
_report_live_state() {                    # to stderr, for the refusal path
  [ -r "$HOOK_DEPLOY_REV" ] || { echo "  The fleet has no recorded deployment at $HOOK_DEPLOY." >&2; return; }
  echo "  NOTHING CHANGED. The fleet is STILL running:" >&2
  sed 's/^/    /' "$HOOK_DEPLOY_REV" >&2
  [ "$(_recorded_reviewed)" = yes ] \
    || echo "  That live deployment is UNREVIEWED. Deploy from $MAIN_REF to clear it." >&2
}

if [ "$MODE" = dry ]; then
  echo "DRY RUN — nothing will be changed. Re-run with --apply."
  # Reach the verdict without installing, and without touching the live deploy
  # directory: snapshot into a temp dir, judge, report, delete.
  _dry_ws=$(mktemp -d 2>/dev/null) || _dry_ws=""
  judge_snapshot "${_dry_ws:-$HOOK_DEPLOY_DIR}"; _jrc=$?
  if [ "$_jrc" = 0 ]; then
    echo "would deploy: ${DEPLOY_SNAP_OID:-unknown}  reviewed=$DEPLOY_REVIEWED"
    if [ "$DEPLOY_REVIEWED" = yes ]; then
      :
    elif [ "$ALLOW_UNREVIEWED" = 1 ]; then
      echo "  --apply WOULD DEPLOY IT ANYWAY (--allow-unreviewed given), recorded as reviewed: no"
      echo "  reason would be: $ALLOW_UNREVIEWED_REASON"
    else
      echo "  --apply WOULD REFUSE. Override with --apply --allow-unreviewed=<reason>."
    fi
  elif [ "$_jrc" = 2 ]; then
    # Blaming the SOURCE for a workspace problem is the same misattribution as
    # the old "could not deploy" message that fired after a successful deploy.
    echo "would deploy: NOTHING — the snapshot workspace is not writable"
  else
    echo "would deploy: NOTHING — $HOOK_SRC is not usable (see above)"
  fi
  rm -f "$DEPLOY_SNAP"
  [ -n "$_dry_ws" ] && rmdir "$_dry_ws" 2>/dev/null
fi

if [ "$MODE" = apply ]; then
  # Best effort freshness: origin/main is whatever this checkout last saw, so a
  # scanner fix merged upstream would otherwise be "reviewed: yes" while the
  # fleet runs the pre-fix detector. Failure is fine (offline, no remote) — the
  # record carries main-dated and VERIFY says how old it is.
  git -C "$here" fetch --quiet origin main 2>/dev/null || true
  judge_snapshot "$HOOK_DEPLOY_DIR"; _jrc=$?
  if [ "$_jrc" = 2 ]; then
    echo "REFUSING: deploy target $HOOK_DEPLOY_DIR is not writable (nothing installed)" >&2
    _report_live_state
    exit 2
  fi
  if [ "$_jrc" != 0 ]; then
    echo "REFUSING: could not prepare $HOOK_SRC for deployment (nothing installed)" >&2
    _report_live_state
    exit 2
  fi
  if [ "$DEPLOY_REVIEWED" != yes ] && [ "$ALLOW_UNREVIEWED" != 1 ]; then
    rm -f "$DEPLOY_SNAP"
    echo "REFUSING: this scanner is $DEPLOY_REVIEWED." >&2
    echo "  It would go in front of every commit and every push in $ROOT/*," >&2
    echo "  and because the copy outlives a branch switch it would leave no" >&2
    echo "  record of which revision — so it is not deployed." >&2
    echo "  source: $HOOK_SRC" >&2
    echo "  rev:    $DEPLOY_REV" >&2
    _report_live_state
    echo "  Either merge it first, or say so explicitly:" >&2
    echo "    bash $0 --apply --allow-unreviewed=<reason>" >&2
    exit 2
  fi
  install_snapshot; _drc=$?
  case "$_drc" in
    0) echo "deployed:  $HOOK_SRC -> $HOOK_DEPLOY"
       echo "revision:  $DEPLOY_REV  reviewed=$DEPLOY_REVIEWED"
       [ "$DEPLOY_REVIEWED" = yes ] || \
         echo "           UNREVIEWED, expires $(_expiry_iso) — reason: ${ALLOW_UNREVIEWED_REASON:-(none given)}" ;;
    4) echo "DEPLOYED BUT UNRECORDED: $HOOK_DEPLOY is live and carrying the new" >&2
       echo "  bytes ($DEPLOY_SNAP_OID), but $HOOK_DEPLOY_REV could not be" >&2
       echo "  written — so the provenance record still describes the PREVIOUS" >&2
       echo "  generation. The fleet is running the new scanner. Fix the record:" >&2
       echo "    ls -l $HOOK_DEPLOY_REV   # read-only, immutable, or not yours?" >&2
       exit 2 ;;
    5) echo "REFUSING TO VOUCH: the bytes now live at $HOOK_DEPLOY are not the" >&2
       echo "  bytes that were judged ($DEPLOY_SNAP_OID). Something rewrote the" >&2
       echo "  deployed file between the rename and this check, so no provenance" >&2
       echo "  record was written — the record would have named bytes nobody" >&2
       echo "  reviewed. Re-run --apply from a quiet checkout." >&2
       exit 2 ;;
    *) echo "REFUSING: could not deploy the scanner to $HOOK_DEPLOY (nothing installed)" >&2
       exit 2 ;;
  esac
fi
echo "scanner: $HOOK_SRC"
echo "shims exec: $HOOK_DEPLOY"
echo


# Is this a hook we may replace? Either it carries a marker we wrote, or it is
# nothing BUT a call to the shared scanner.
#
# The second test is a whole-file property, not a grep for a known path. The
# fleet shim exists in at least three spellings — an expanded /Users/thurbs/...
# path, a literal $HOME, and a tilde (slack-instagram-unfurl, found by this
# script's own first dry run) — and matching a fixed list quietly classified the
# tilde one as somebody's bespoke hook. Requiring that every meaningful line is
# an `exec bash <...>secret-scan-pre-commit.sh` covers every spelling there can
# be, while a hook that does ANY other work fails it and is left alone.
ours() {                                  # <hook path>
  [ -f "$1" ] || return 1
  grep -qF "$MARK"        "$1" && return 0
  grep -qF "$LEGACY_MARK" "$1" && return 0
  local meaningful
  meaningful="$(grep -vE '^[[:space:]]*(#|$)' "$1")"
  [ -n "$meaningful" ] || return 1
  printf '%s\n' "$meaningful" \
    | grep -qvE '^[[:space:]]*exec[[:space:]]+bash[[:space:]]+.*secret-scan-pre-commit\.sh' \
    && return 1
  return 0
}

already_ours() {                          # <hook path> [scanner args...]
  # BYTE COMPARISON against the body we would write, not a set of substring
  # greps. Three times in one day the grep form has called a broken shim
  # correct, because each fix added an element the check did not know to look
  # for:
  #
  #   * it grepped $HOOK_SRC (the in-tree path) while a correct shim execs
  #     $HOOK_DEPLOY, so every hook was reported as needing a rewrite;
  #   * it could not see a `pre-push` shim missing `--push` (index scan on a
  #     push: exits 0 on a clean index and reads as a working guard);
  #   * it could not see one missing `"$@"` — which leaves the scanner with no
  #     remote name, so every NEW-branch push is refused with "give this
  #     remote a name", advice that does not apply to an ordinary origin.
  #     That is a refusal with no compliant fix, i.e. the shape that gets a
  #     guard bypassed.
  #
  # We GENERATE the body, so the honest question is "is this file exactly what
  # we would write?" — which needs no maintenance when the body changes again.
  # It also refuses a file that merely MENTIONS the deployed path: a comment,
  # an early `exit 0`, or a wrapper around it used to count as coverage.
  local hk="$1"; shift
  [ -f "$hk" ] || return 1
  [ "$(cat "$hk")" = "$(hook_body "$@")" ]
}

installed=0 skipped=0 restored=0 foreign=0 noscan=0 worktrees=0 notrepo=0

place_hook() {                            # <repo> <hook path> <hook name> [scanner args...]
  local repo="$1" hk="$2" name="$3" b="$2$BACKUP_SUFFIX"
  local label="$(basename "$repo")/$name"
  shift 3

  # "$@" and not "${1:-}": an empty placeholder would make hook_body emit a
  # quoted empty argument and no hook would ever compare equal.
  if already_ours "$hk" "$@"; then
    skipped=$((skipped+1)); printf '  =  %-44s already points at this checkout\n' "$label"; return
  fi
  if [ -f "$hk" ] && ! ours "$hk"; then
    foreign=$((foreign+1)); printf '  !  %-44s has its OWN hook — left alone\n' "$label"; return
  fi

  if [ "$MODE" = dry ]; then
    if [ -f "$hk" ]; then printf '  ~  %-44s WOULD REPOINT at the tracked copy\n' "$label"
    else                  printf '  +  %-44s WOULD INSTALL\n' "$label"; fi
    installed=$((installed+1)); return
  fi

  mkdir -p "$(dirname "$hk")"
  # Keep exactly one backup: the state before this script first touched the repo.
  # Overwriting it on a re-run would replace the user's original hook with our
  # own, so --undo would restore this script's output instead of undoing it.
  # ... and never back up a hook THIS SCRIPT wrote. A previous generation of
  # our own shim is not the user's hook, and preserving it means `--undo`
  # reinstates a version with a known hole — the suite caught exactly that: a
  # `pre-push` missing `"$@"` was backed up, repaired, and then restored by
  # undo. The legacy fleet shims (`exec bash ~/.claude/...`) carry no MARK, so
  # the rollback path that actually matters is untouched.
  if [ -f "$hk" ] && [ ! -e "$b" ] && ! grep -qF "$MARK" "$hk"; then cp -p "$hk" "$b"; fi
  hook_body "$@" > "$hk"
  chmod +x "$hk"
  installed=$((installed+1)); printf '  +  %-44s installed\n' "$label"
}

undo_hook() {                             # <repo> <hook path> <hook name>
  local repo="$1" hk="$2" name="$3" b="$2$BACKUP_SUFFIX"
  local label="$(basename "$repo")/$name"
  # Only ever removes a hook carrying THIS script's marker: a hook someone
  # rewrote by hand since is not ours to revert.
  [ -f "$hk" ] && grep -qF "$MARK" "$hk" || return
  if [ -e "$b" ]; then
    mv "$b" "$hk"; printf '  <  %-44s restored the hook that was here before\n' "$label"
  else
    # Nothing was here before. For the COMMIT hooks, removing outright would
    # leave the repo with no secret scan at all — strictly worse than the
    # state this script found — so fall back to the untracked scanner.
    #
    # For `pre-push` that fallback is actively harmful, which is why the hook
    # NAME is used here rather than ignored. No repo had a pre-push before
    # this change, so there is never a backup for it, and the legacy path is
    # now an 8-line forwarder into the deployed scanner WITHOUT `--push`:
    # git would invoke it as `pre-push origin <url>`, `$1` would be `origin`,
    # and the scanner would run its INDEX scan during a push. That judges
    # whatever happens to be STAGED — so the push is not scanned at all, and a
    # staged fixture token or a stale per-repo user.email would refuse the
    # push with commit-shaped advice. Meanwhile VERIFY would file the repo
    # under "still on the untracked copy", which reads as coverage.
    #
    # The untracked scanner never had a push mode. There is nothing to revert
    # to, so remove it and say so.
    if [ "$name" = pre-push ]; then
      rm -f "$hk"; printf '  <  %-44s removed (no push scan existed before)\n' "$label"
    elif [ -r "$LEGACY_SRC" ]; then
      printf '#!/usr/bin/env bash\nexec bash %q\n' "$LEGACY_SRC" > "$hk"; chmod +x "$hk"
      printf '  <  %-44s reverted to the untracked scanner\n' "$label"
    else
      rm -f "$hk"; printf '  <  %-44s removed (nothing was here before)\n' "$label"
    fi
  fi
  restored=$((restored+1))
}

for d in "$ROOT"/*/; do
  repo="${d%/}"
  if [ ! -e "$repo/.git" ]; then notrepo=$((notrepo+1)); continue; fi
  # `.git` as a FILE means a linked worktree. Its hooks dir is the parent's, so
  # it is already covered and writing here would be a second name for one file.
  if [ -f "$repo/.git" ]; then
    worktrees=$((worktrees+1))
    printf '  .  %-44s worktree — covered by its parent repo\n' "$(basename "$repo")"
    continue
  fi
  # The hooks dir GIT WILL USE, not the one we assume. `core.hooksPath`
  # redirects it repo-wide, and a hook written to `.git/hooks` in a repo that
  # sets it is a file git never runs — installed, executable, reported as
  # coverage, and dead. Exactly the failure shape as this morning's shims
  # pointing into a deleted worktree, one config key over. `rev-parse
  # --git-path hooks` is the only answer that accounts for it (measured: it
  # resolves tg-portal's to tourguide's, which is what git does).
  hooks_dir="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)"
  [ -n "$hooks_dir" ] || hooks_dir="$repo/.git/hooks"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
  if [ "$hooks_dir" != "$repo/.git/hooks" ]; then
    # Visible, because it means another directory owns this repo's guard.
    printf '  i  %-44s core.hooksPath -> %s\n' "$(basename "$repo")" "$hooks_dir"
  fi
  pc="$hooks_dir/pre-commit"
  pmc="$hooks_dir/pre-merge-commit"
  # THREE hooks, because `pre-commit` and `pre-merge-commit` are only run when
  # `git commit` creates the commit. `git am`, `cherry-pick`, `revert` and
  # every `rebase` replay write commits without running either, so those paths
  # were unscanned — and there is no GitHub push protection behind them
  # (private repos, paid feature). `pre-push` closes the class: however a
  # commit was made, it has to be pushed to leave the machine.
  pp="$hooks_dir/pre-push"

  # Only repos ALREADY running the scan on ordinary commits. A repo without it
  # has made a different choice and opting it in is not this script's call.
  if ! grep -q "secret-scan" "$pc" 2>/dev/null && ! grep -q "secret-scan" "$pmc" 2>/dev/null; then
    noscan=$((noscan+1))
    printf '  -  %-44s no secret scan today — NOT opted in\n' "$(basename "$repo")"
    continue
  fi

  case "$MODE" in
    undo) undo_hook "$repo" "$pc" pre-commit; undo_hook "$repo" "$pmc" pre-merge-commit
          undo_hook "$repo" "$pp" pre-push ;;
    *)    place_hook "$repo" "$pc" pre-commit; place_hook "$repo" "$pmc" pre-merge-commit
          place_hook "$repo" "$pp" pre-push --push ;;
  esac
done

echo
echo "===== VERIFY ====="
# WHAT THE FLEET IS EXECUTING, asked of the deployed copy rather than of this
# checkout. Every other line of this report describes the SHIMS, which is why
# 18 repos could run an open PR's scanner with the whole report green.
if [ -r "$HOOK_DEPLOY" ]; then
  _dep_sha=$(shasum -a 256 "$HOOK_DEPLOY" | cut -d' ' -f1)
  printf '  deployed scanner: %s\n' "$HOOK_DEPLOY"
  if [ -r "$HOOK_DEPLOY_REV" ]; then
    sed 's/^/    /' "$HOOK_DEPLOY_REV"
    # An unreviewed deployment is a headline, not a field. Nothing consults .rev
    # at commit time — the shims exec the scanner directly — so this report is
    # the only place the state is ever mentioned, and it used to be one line
    # among eleven.
    if [ "$(_recorded_reviewed)" != yes ]; then
      _why=$(sed -n 's/^reason:[[:space:]]*//p' "$HOOK_DEPLOY_REV")
      _exp=$(sed -n 's/^expires:[[:space:]]*//p' "$HOOK_DEPLOY_REV")
      _dep=$(sed -n 's/^deployed:[[:space:]]*//p' "$HOOK_DEPLOY_REV")
      _days=""
      if [ -n "$_dep" ]; then
        _t=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$_dep" +%s 2>/dev/null || date -u -d "$_dep" +%s 2>/dev/null)
        [ -n "$_t" ] && _days=$(( ( $(date +%s) - _t ) / 86400 ))
      fi
      echo "    UNREVIEWED DEPLOYMENT: the fleet has been running unreviewed bytes${_days:+ for ${_days}d}"
      echo "      reason: ${_why:-(none recorded)}"
      # An unparseable or missing deadline used to SKIP this check, so an
      # unreviewed deployment silently never expired — the quiet default on a
      # control whose whole point is not being forgotten. Louder is correct.
      _et=""
      [ -n "$_exp" ] && [ "$_exp" != unknown ] && \
        _et=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$_exp" +%s 2>/dev/null || date -u -d "$_exp" +%s 2>/dev/null)
      if [ -z "$_et" ]; then
        echo "      NO USABLE DEADLINE recorded (expires: ${_exp:-absent}) — treat it as expired."
        echo "      Deploy from $MAIN_REF to clear this."
      elif [ "$(date +%s)" -gt "$_et" ]; then
        echo "      EXPIRED $_exp — this was meant to be temporary. Deploy from $MAIN_REF."
      else
        echo "      expires: $_exp"
      fi
    fi
    _rec=$(sed -n 's/^sha256:[[:space:]]*//p' "$HOOK_DEPLOY_REV")
    if [ "$_rec" != "$_dep_sha" ]; then
      echo "    STALE RECORD: .rev describes different bytes than the deployed file"
      # And the provenance line below must not contradict it. Review drove that
      # comparison to a false YES: a deployed file that had DRIFTED (same text,
      # CRLF) normalised to the anchor's OID under a text attribute, so the
      # block said both "STALE RECORD" and "matches origin/main: yes". A report
      # that asserts both is worse than one that admits it cannot tell — the
      # reader believes the friendlier line.
      _dep_drifted=1
    fi
  else
    echo "    no .rev — deployed before provenance was recorded, or written by hand"
  fi
  # By BLOB OID, and with an explicit verdict when it cannot be established.
  # The first version wrapped this in `if _mainblob=$(...); then` with no else,
  # so a fleet running a weakened branch scanner produced a VERIFY block with
  # no origin/main line at all — and silence in a report whose whole purpose is
  # answering "what is the fleet running" reads as a pass.
  # Asked the same way the gate asks it. This line was the one place the
  # path-sensitive hash survived, and review drove it to BOTH a false NO on a
  # byte-identical deployment and a false YES on a deployment whose bytes
  # provably differed from the anchor — the original "report says yes while the
  # bytes are not the reviewed ones" failure, in the surface this whole change
  # exists to provide.
  _dep_drifted=${_dep_drifted:-0}
  _dep_oid=$(_oid_as_tracked "$HOOK_DEPLOY")
  _main_oid=$(_src_repo_ok && _blob_at "$MAIN_REF")
  if [ -z "$_main_oid" ]; then
    echo "    matches origin/main: CANNOT TELL — no origin/main resolvable from $here."
    echo "      The fleet's scanner is UNVERIFIED. git -C $here fetch origin main"
  elif [ "$_dep_drifted" = 1 ]; then
    echo "    matches origin/main: CANNOT VOUCH — the deployed file has changed"
    echo "      since it was recorded, so what it resembles now proves nothing."
    echo "      redeploy from a checkout on main:  bash $0 --apply"
  elif [ "$_main_oid" = "$_dep_oid" ]; then
    # "yes" here means "this is the checkout of the reviewed blob", which under
    # normalising attributes is NOT the same claim as "the bytes are identical".
    # Say which one is being made, so nobody reads filter-equivalence as byte
    # identity — the report is the surface this whole change exists to provide.
    if git -C "$here" cat-file blob "$MAIN_REF:$_TRACKED" 2>/dev/null | cmp -s - "$HOOK_DEPLOY"; then
      echo "    matches origin/main: yes (byte-identical to the reviewed blob)"
    else
      echo "    matches origin/main: yes (this checkout of the reviewed blob;"
      echo "      the bytes differ from the blob by this repo's line-ending"
      echo "      attributes, which is what git itself calls unmodified)"
    fi
    # origin/main is only as fresh as the last fetch, so "yes" against a stale
    # ref can still mean the fleet is running a pre-fix detector.
    _md=$(git -C "$here" log -1 --format=%ct "$MAIN_REF" 2>/dev/null)
    if [ -n "$_md" ]; then
      _age=$(( ( $(date +%s) - _md ) / 86400 ))
      [ "$_age" -gt 14 ] && echo "      but origin/main here is ${_age}d old — fetch before trusting this"
    fi
  else
    echo "    matches origin/main: NO — the fleet is NOT running the reviewed scanner"
    echo "      deployed blob $_dep_oid vs origin/main $_main_oid"
    echo "      redeploy from a checkout on main:  bash $0 --apply"
  fi
else
  echo "  deployed scanner: MISSING at $HOOK_DEPLOY — every shim is dead"
fi
echo
tracked=0 legacy=0 unguarded=0 ownpush=0
for d in "$ROOT"/*/; do
  repo="${d%/}"
  [ -d "$repo/.git" ] || continue
  # Same resolution as the install loop: verifying `.git/hooks` in a repo that
  # redirects `core.hooksPath` would report a guard that git never runs.
  hooks_dir="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)"
  [ -n "$hooks_dir" ] || hooks_dir="$repo/.git/hooks"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
  pc="$hooks_dir/pre-commit"; pmc="$hooks_dir/pre-merge-commit"
  pp="$hooks_dir/pre-push"
  grep -q "secret-scan" "$pc" 2>/dev/null || grep -q "secret-scan" "$pmc" 2>/dev/null || continue
  all=1
  for h in "$pc" "$pmc" "$pp"; do [ -x "$h" ] || all=0; done
  if [ "$all" = 0 ]; then
    unguarded=$((unguarded+1)); echo "  INCOMPLETE: $(basename "$repo") — one of the three hooks is missing"
  elif already_ours "$pc" && already_ours "$pmc" && already_ours "$pp" --push; then
    tracked=$((tracked+1))
  elif [ -f "$pp" ] && ! ours "$pp"; then
    # Its own pre-push, which this script will never touch. That is the right
    # behaviour, but it is NOT "still on the untracked ~/.claude copy" — that
    # bucket reads as coverage, and there is none: the untracked scanner has no
    # push mode at all, so `git am`, cherry-pick, revert and rebase replays in
    # this repo reach the remote unscanned. Its own line, so it is visible.
    ownpush=$((ownpush+1))
    echo "  OWN PRE-PUSH: $(basename "$repo") — its push path is NOT scanned by this guard"
  else
    legacy=$((legacy+1))
  fi
done
echo "  repos on the TRACKED scanner (all 3 hooks):  $tracked"
echo "  repos still on the untracked ~/.claude copy: $legacy"
echo "  repos with their OWN pre-push (no push scan): $ownpush"
echo "  repos missing one of the three hooks:        $unguarded"
echo "  repos deliberately NOT opted in (no scan):   $noscan"
echo "  worktrees covered by a parent repo:          $worktrees"
echo "  non-repo directories ignored:                $notrepo"
echo "  this run: changed=$installed unchanged=$skipped foreign=$foreign restored=$restored"
echo
echo "PROVE THE SCANNER ITSELF: bash $here/verify-secret-scan.sh"
echo "ROLLBACK: bash $0 --undo   (only hooks carrying this script's marker)"
