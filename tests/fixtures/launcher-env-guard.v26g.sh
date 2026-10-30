# CI-FIXTURE-ONLY contract for the bound omp launcher's env-binding guard
# block (issue #362). Provenance: no installed release currently carries this
# block (confirmed by `grep -nE 'PI_CONFIG_FILES|OMP_PROFILE|MNEMOPI_DATA_DIR'
# against the 2026-10-26-lanes-v26f release: no match); this is the pinned
# contract the release AFTER v26f must splice into `omp` between the
# offline_overlay readability check and `args=("$@")`, in the same style as
# the existing argv-allowlist fixture (launcher-argv-guard.v26d.sh). Each
# refused variable's PRESENCE (set at all, including explicitly empty, e.g.
# `CLAUDE_CONFIG_DIR=""`) dies before exec -- an explicitly-empty
# `CLAUDE_CONFIG_DIR` resolves to the process cwd rather than the default
# `~/.claude` (docs/operations/launcher-release-notes.md), so a
# `[ -z "$v" ]`-shaped non-empty check would miss that exact bypass
# (v26h-r2 MEDIUM fix, issue #362). The parameter expansion below tests existence
# (`${!env_var+x}` expands to `x` iff the var is SET, regardless of value;
# unset -> empty, caught by `-z`), not value, so a caller cannot swap
# config/extension/plugin/profile/memory-storage paths out from under the
# bound overlays by setting a refused var to the empty string either. Digest
# of the body below this header (the `for env_var in ... done` block,
# verified with:
# awk '/^for env_var in /,/^done$/' tests/fixtures/launcher-env-guard.v26g.sh | shasum -a 256):
# a600b2183c675e46d433676100b9b9e36356afd20f821549466da0afb460da95
for env_var in PI_CONFIG_FILES OMP_PROFILE PI_PROFILE PI_CONFIG_DIR PI_CODING_AGENT_DIR CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME MNEMOPI_DATA_DIR; do
  [ -z "${!env_var+x}" ] || die "$env_var may bypass the bound overlays"
done
