#!/usr/bin/env bash
# lib/bashlex-preflight.sh — durable bashlex-venv preflight for a freshly
# created TASK WORKTREE (spawn-task.sh), separate from provision_bashlex_venv
# (launchd/agent-lib.sh), which actually `uv pip install`s the pinned
# interpreter into the developer checkout and the deployed app.
#
# Problem this closes: `lib/command-policy.sh`'s `_cp_bashlex_findgit_present`
# and every `verify-*.sh` suite's own prerequisite check look for
# `<here>/.venv-bashlex/bin/python3` relative to the worktree they are running
# in. A worktree `git worktree add` creates is a bare checkout — it never had
# `install.sh --apply` run inside it, has no venv of its own, and `.venv-bashlex/`
# is gitignored so nothing about it travels with the branch. Every find/git-
# shaped command then escalates (correct, fail-closed) and every verify-*.sh
# PREREQ check refuses to run (also correct) — but three workers in one day
# burned whole suite runs (352/5, etc.) discovering this the hard way instead
# of being told up front. This never loosens the gate: a worktree that still
# has no working interpreter after this runs is exactly as fail-closed as one
# this file never touched.
#
# The shared checkout (`install.sh --apply`) and the deployed app
# (`restart.sh --deploy`) already carry a real, network-provisioned venv. A
# read-only symlink is the cheap, correct reuse — `uv pip install --require-
# hashes` again per worktree would need network on every spawn for a pure
# Python package. SPEC #264's hash-pin requirement is preserved: the SOURCE
# venv is itself `--require-hashes` provisioned, and this file re-checks its
# installed version against the SAME pin (`lib/bashlex-requirements.txt`)
# before linking, so a stale or mismatched source venv is refused, not reused.

# provision_worktree_bashlex_venv <worktree_dir> <shared_checkout_root>
#
# Links `<worktree_dir>/.venv-bashlex` to the first candidate source venv
# (shared checkout, then the deployed app at $HERDR_APP_DIR) whose installed
# `bashlex` version matches the pin in lib/bashlex-requirements.txt, verified
# by actually importing it through the worktree-local symlink before trusting
# it. Writes `.handoffs/bashlex-provenance.txt` either way — which source
# (or none) and which version — so a worker or a human reading the worktree
# never has to re-derive why the parser gate is open or closed. Never exits
# nonzero in a way callers need to check: like `provision_bashlex_venv`, a
# failed provision here is reported, not fatal — the ALREADY fail-closed
# find/git gate is what actually protects the pane either way.
provision_worktree_bashlex_venv() {
  local wt="$1" root="$2"
  local self here reqs pinned_ver prov_dir prov_file
  self="${BASH_SOURCE[0]}"
  here="$(cd "$(dirname "$self")/.." && pwd)"
  reqs="$here/lib/bashlex-requirements.txt"
  prov_dir="$wt/.handoffs"
  mkdir -p "$prov_dir" 2>/dev/null
  prov_file="$prov_dir/bashlex-provenance.txt"

  if [ ! -f "$reqs" ]; then
    printf 'bashlex: no %s in this revision — skipping (pre-#264 checkout?)\n' "$reqs" > "$prov_file" 2>/dev/null
    return 0
  fi
  pinned_ver="$(sed -n 's/^bashlex==\([0-9.][0-9.]*\).*/\1/p' "$reqs" | head -1)"
  if [ -z "$pinned_ver" ]; then
    printf 'bashlex: could not parse a pinned version out of %s — refusing to link, parser gate stays fail-closed\n' "$reqs" > "$prov_file" 2>/dev/null
    return 1
  fi

  local candidates=("$root/.venv-bashlex" "${HERDR_APP_DIR:-$HOME/.local/share/herdr-control/app}/.venv-bashlex")
  local src src_ver notes="" chosen="" chosen_ver=""
  for src in "${candidates[@]}"; do
    [ -x "$src/bin/python3" ] || { notes="${notes}no interpreter at $src/bin/python3; "; continue; }
    src_ver="$("$src/bin/python3" -c 'from importlib.metadata import version; print(version("bashlex"))' 2>/dev/null)"
    if [ -z "$src_ver" ]; then
      notes="${notes}$src: bashlex not importable; "
      continue
    fi
    if [ "$src_ver" != "$pinned_ver" ]; then
      notes="${notes}$src: bashlex $src_ver != pinned $pinned_ver; "
      continue
    fi
    chosen="$src"; chosen_ver="$src_ver"
    break
  done

  if [ -n "$chosen" ]; then
    ln -sfn "$chosen" "$wt/.venv-bashlex" 2>/dev/null
    if [ -x "$wt/.venv-bashlex/bin/python3" ] &&
       "$wt/.venv-bashlex/bin/python3" -c 'import bashlex' >/dev/null 2>&1; then
      {
        printf 'bashlex venv: linked (read-only reuse)\n'
        printf 'worktree_path: %s\n' "$wt/.venv-bashlex"
        printf 'source: %s\n' "$chosen"
        printf 'bashlex_version: %s (pinned %s)\n' "$chosen_ver" "$pinned_ver"
        printf 'linked_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$prov_file" 2>/dev/null
      echo "  bashlex venv ok (worktree): $wt/.venv-bashlex -> $chosen (bashlex $chosen_ver)"
      return 0
    fi
    # Symlink created but doesn't actually work (source removed/mutated
    # between the check above and here) — remove it rather than leave a
    # broken link that looks provisioned to a casual `ls`. Falls through to
    # the fail-closed report below.
    rm -f "$wt/.venv-bashlex" 2>/dev/null
    notes="${notes}$chosen: passed the version check but failed to import through the worktree symlink; "
  fi

  {
    printf 'bashlex venv: NOT linked in this worktree\n'
    printf 'worktree_path: %s (absent)\n' "$wt/.venv-bashlex"
    printf 'pinned_version: %s (from %s)\n' "$pinned_ver" "$reqs"
    printf 'candidates_tried: %s\n' "${candidates[*]}"
    [ -n "$notes" ] && printf 'reason: %s\n' "$notes"
    printf 'fix: run `install.sh --apply` in %s (needs uv + network once) to provision its .venv-bashlex, then re-run spawn-task.sh so this preflight can link it — until then the find/git parser gate (lib/command-policy.sh _cp_bashlex_findgit_present) fails CLOSED here: every find/git-shaped command escalates, and verify-*.sh suites with a bashlex prerequisite (verify-approval-payload.sh, verify-prompt-occurrence-notify.sh, verify-command-policy-bashlex-diff.sh) refuse to run rather than report those holds as pass/fail.\n' "$root"
  } > "$prov_file" 2>/dev/null
  echo "spawn-task: bashlex venv not available for this worktree — parser self-check stays fail-closed (see $prov_file)" >&2
  return 1
}
