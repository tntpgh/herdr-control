# CI-FIXTURE-ONLY contract for the bound omp launcher's env-binding guard
# block (issue #362). Provenance: no installed release currently carries this
# block (confirmed by `grep -nE 'PI_CONFIG_FILES|OMP_PROFILE|MNEMOPI_DATA_DIR'
# against the 2026-10-26-lanes-v26f release: no match); this is the pinned
# contract the release AFTER v26f must splice into `omp` between the
# offline_overlay readability check and `args=("$@")`, in the same style as
# the existing argv-allowlist fixture (launcher-argv-guard.v26d.sh). Each
# refused variable's presence (any non-empty value) dies before exec, so a
# caller cannot swap config/extension/plugin/profile/memory-storage paths
# out from under the bound overlays. Digest of the body below this header
# (the `for env_var in ... done` block, verified with:
# awk '/^for env_var in /,/^done$/' tests/fixtures/launcher-env-guard.v26g.sh | shasum -a 256):
# b5192ce9510895be69c1dc76b23dc218feeb470b6a5b0c3f465f68ee61f64793
for env_var in PI_CONFIG_FILES OMP_PROFILE PI_PROFILE PI_CONFIG_DIR PI_CODING_AGENT_DIR CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME MNEMOPI_DATA_DIR; do
  [ -z "${!env_var:-}" ] || die "$env_var may bypass the bound overlays"
done
