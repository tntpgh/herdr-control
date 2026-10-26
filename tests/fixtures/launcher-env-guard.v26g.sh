# CI-FIXTURE-ONLY copy of the bound omp launcher's env-binding guard block (lines for env_var in .. done).
# Provenance: AUTHORED for issue #362 (PI_CONFIG_FILES bypasses the --config overlay
# allowlist: a process that can set the env of a bound launch loads an arbitrary
# settings overlay through PI_CONFIG_FILES, the same precedence-3 mechanism as
# --config, without tripping the --config argv allowlist). No installed release
# contains this block yet; it is the pinned contract for the release that
# ships after 2026-10-26-lanes-v26f (v26g or later), to be spliced into omp
# immediately after `[ -r "$offline_overlay" ] || die ...` and before
# `args=("$@")`. Each refused variable is audited in
# docs/operations/launcher-release-notes.md. PI_NATIVES_DIR is deliberately
# absent: the launcher already unconditionally re-exports it itself right
# before exec, so an inherited value can never reach the binary.
# Block sha256 (body below this header) b5192ce9510895be69c1dc76b23dc218feeb470b6a5b0c3f465f68ee61f64793.
# NOT runtime proof: once a release ships this block, the installed wrapper is
# checked separately (verify-launcher-release.sh, installed mode).
for env_var in PI_CONFIG_FILES OMP_PROFILE PI_PROFILE PI_CONFIG_DIR PI_CODING_AGENT_DIR CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME MNEMOPI_DATA_DIR; do
  [ -z "${!env_var:-}" ] || die "$env_var may bypass the bound overlays"
done
