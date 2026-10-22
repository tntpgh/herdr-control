# lib/provisioned-links.sh — symlinks the launcher itself put into a worker
# worktree (today: .venv-bashlex), recorded so close-done-workers.sh can tell
# them apart from a worker's own untracked files.
#
# Before this, every spawn-task worktree carried an untracked .venv-bashlex
# link (lib/bashlex-preflight.sh) that `git status --porcelain` counts, so the
# closer HELD every finished pane forever (2026-10-21: five done panes held).
#
# The manifest lives in .handoffs/ (self-ignoring, never committed). A path is
# excused ONLY while it is still a symlink whose target equals the recorded
# one — a retargeted link, a real file/dir at that path, or a link the
# manifest never recorded still counts as uncommitted work and still HOLDs.

provisioned_links_manifest() { printf '%s/.handoffs/provisioned-links.tsv' "$1"; }

# record_provisioned_link <worktree> <relpath> <target>
record_provisioned_link() {
  local wt="$1" rel="$2" target="$3" mf
  mf="$(provisioned_links_manifest "$wt")"
  mkdir -p "$(dirname "$mf")" 2>/dev/null || return 1
  case "$rel$target" in *$'\t'*|*$'\n'*) return 1 ;; esac
  printf '%s\t%s\n' "$rel" "$target" >> "$mf"
}

# _provisioned_link_ok <worktree> <relpath> -> 0 when <relpath> is an
# untouched launcher-provisioned symlink.
_provisioned_link_ok() {
  local wt="$1" rel="$2" mf want have
  mf="$(provisioned_links_manifest "$wt")"
  [ -f "$mf" ] || return 1
  [ -L "$wt/$rel" ] || return 1
  want="$(awk -F'\t' -v r="$rel" '$1==r{t=$2} END{print t}' "$mf")"
  [ -n "$want" ] || return 1
  have="$(readlink "$wt/$rel")"
  [ "$have" = "$want" ]
}

# porcelain_without_provisioned <worktree> — `git status --porcelain` with
# the untouched provisioned links removed. Prints nothing when clean; exits
# nonzero if git itself fails (callers must HOLD, never read that as clean).
porcelain_without_provisioned() {
  local wt="$1" out line rel
  out="$(git -C "$wt" status --porcelain 2>/dev/null)" || return 1
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      '?? '*)
        rel="${line#?? }"; rel="${rel%/}"
        _provisioned_link_ok "$wt" "$rel" && continue
        ;;
    esac
    printf '%s\n' "$line"
  done <<<"$out"
}
