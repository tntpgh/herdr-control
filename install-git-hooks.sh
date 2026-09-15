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
for a in "$@"; do
  case "$a" in
    --dry-run) MODE=dry ;;
    --apply)   MODE=apply ;;
    --undo)    MODE=undo ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

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

# See the $here note at the top. A dry run from anywhere is fine; writing 36
# shims that point into a directory somebody is about to delete is not.
if [ -n "$_disposable" ] && [ "$MODE" != dry ]; then
  echo "REFUSING: this checkout is $_disposable ($here)." >&2
  echo "  The hooks this writes hard-code that path, so every commit in every" >&2
  echo "  repo would break the moment it disappears. Run --apply from the" >&2
  echo "  permanent checkout instead:  cd ~/Code/herdr-control && bash install-git-hooks.sh --apply" >&2
  exit 2
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
HOOK_DEPLOY_DIR="${HERDR_HOOK_DEPLOY_DIR:-$HOME/.local/share/herdr-control/hooks}"
HOOK_DEPLOY="$HOOK_DEPLOY_DIR/secret-scan-pre-commit.sh"

deploy_scanner() {
  mkdir -p "$HOOK_DEPLOY_DIR" || return 1
  # Atomic: a half-written scanner is a broken guard in every repo at once.
  local tmp="$HOOK_DEPLOY.new.$$"
  cp "$HOOK_SRC" "$tmp" || return 1
  chmod 0755 "$tmp" || return 1
  bash -n "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$HOOK_DEPLOY" || return 1
}

# The shim is one exec, so the scanner is never copied into a repo. Extra
# argv (pre-push passes `--push`) is appended verbatim; `exec` keeps stdin, and
# pre-push's ref list arrives THERE, not in argv.
hook_body() {                             # [extra scanner args...]
  printf '#!/usr/bin/env bash\n%s\nexec bash %q' "$MARK" "$HOOK_DEPLOY"
  local a
  for a in "$@"; do printf ' %q' "$a"; done
  printf '\n'
}

[ "$MODE" = dry ] && echo "DRY RUN — nothing will be changed. Re-run with --apply."
if [ "$MODE" = apply ]; then
  deploy_scanner || { echo "REFUSING: could not deploy the scanner to $HOOK_DEPLOY" >&2; exit 2; }
  echo "deployed:  $HOOK_SRC -> $HOOK_DEPLOY"
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

already_ours() {                          # <hook path> [required extra arg]
  # Compare against the DEPLOYED path, which is what a correct shim execs. This
  # tested $HOOK_SRC (the in-tree source) and so reported every hook as needing
  # a rewrite on a second --apply — idempotence the suite checks by asserting
  # `changed=0 unchanged=7`.
  #
  # The second argument matters for pre-push: a shim that execs the right
  # scanner WITHOUT `--push` runs the index scan on a push, where the index is
  # unrelated to what is being sent — it would exit 0 on staged-nothing and
  # read as a guard that is present and working. Treat it as needing a rewrite.
  [ -f "$1" ] || return 1
  grep -qF "$HOOK_DEPLOY" "$1" || return 1
  [ -n "${2:-}" ] && { grep -qF -- "$2" "$1" || return 1; }
  return 0
}

installed=0 skipped=0 restored=0 foreign=0 noscan=0 worktrees=0 notrepo=0

place_hook() {                            # <repo> <hook path> <hook name> [scanner args...]
  local repo="$1" hk="$2" name="$3" b="$2$BACKUP_SUFFIX"
  local label="$(basename "$repo")/$name"
  shift 3

  if already_ours "$hk" "${1:-}"; then
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
  if [ -f "$hk" ] && [ ! -e "$b" ]; then cp -p "$hk" "$b"; fi
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
    # Nothing was here before. Removing it outright would leave the repo with no
    # secret scan at all, which is strictly worse than the state this script
    # found; fall back to the untracked scanner if it still exists.
    if [ -r "$LEGACY_SRC" ]; then
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
tracked=0 legacy=0 unguarded=0
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
  else
    legacy=$((legacy+1))
  fi
done
echo "  repos on the TRACKED scanner (all 3 hooks):  $tracked"
echo "  repos still on the untracked ~/.claude copy: $legacy"
echo "  repos missing one of the three hooks:        $unguarded"
echo "  repos deliberately NOT opted in (no scan):   $noscan"
echo "  worktrees covered by a parent repo:          $worktrees"
echo "  non-repo directories ignored:                $notrepo"
echo "  this run: changed=$installed unchanged=$skipped foreign=$foreign restored=$restored"
echo
echo "PROVE THE SCANNER ITSELF: bash $here/verify-secret-scan.sh"
echo "ROLLBACK: bash $0 --undo   (only hooks carrying this script's marker)"
