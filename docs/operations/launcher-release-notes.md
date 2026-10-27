# Bound launcher release notes

Per-release notes for the hand-authored `omp` bound-launcher wrapper (`HERDR_OMP_BIN`
in `config.sh`). This file is new as of issue #362; no prior release-notes file
existed in this repo (release pins like `a68f8d4` carried no accompanying notes).

## Release after `2026-10-26-lanes-v26f` — env-binding guard (issue #362)

### Gap

The bound launcher's argv scan (`tests/fixtures/launcher-argv-guard.v26d.sh`)
refuses every `--config` value except the two pinned herdr overlays, but does
not touch the process environment. `PI_CONFIG_FILES` (omp precedence layer 3,
`omp://config-usage.md` §4) loads settings overlays from env exactly like
`--config` does from argv, so any caller that can set the launched process's
environment bypasses the argv allowlist entirely. Proof: `omp config get
mnemopi.autoRetain` flips from `true` to `false` under
`PI_CONFIG_FILES=$TMPDIR/noretain.yml`, with no `PI_CONFIG|env -i|unset`
handling anywhere in the v26e/v26f launcher text.

### Fix

Before `exec`, in the hand-authored `omp` wrapper, between the
`offline_overlay` readability check and `args=("$@")`: refuse to start (exit
78, clear per-variable message) if any variable in the classification table
below is **set at all**, including explicitly empty (e.g.
`CLAUDE_CONFIG_DIR=""`) -- an explicitly-empty `CLAUDE_CONFIG_DIR` resolves
to the process cwd rather than the default `~/.claude` (table below), so a
non-empty-only test would miss that exact bypass (v26h-r2 MEDIUM fix, issue
#362). Contract
pinned at `tests/fixtures/launcher-env-guard.v26g.sh`; `verify-launcher-release.sh`
check 6 verifies an installed release's `omp` carries this exact block,
digest-matched, running before the argv scan; check 6b statically confirms
the pinned contract tests presence (`${!env_var+x}`), not value.

### Classification: every env var that changes a config, extension, plugin,
### profile, or memory-storage path

Audited from `omp://environment-variables.md` (full doc) and
`omp://config-usage.md` (full doc): every `PI_*`/`OMP_*` variable in
"Storage and config root paths" (§6), `CLAUDE_CONFIG_DIR` (same loading tier
per `config-usage.md` §1), and `MNEMOPI_DATA_DIR`
(`omp://user-facing-packages.md`, standalone `mnemopi` CLI storage root).

| Variable | Disposition | Reason |
| --- | --- | --- |
| `PI_CONFIG_FILES` | **REFUSE** | Platform path-list of settings overlays loaded before `--config`; the exact bypass in issue #362. |
| `OMP_PROFILE` | **REFUSE** | Canonical profile selector; relocates the entire OMP user config/data/state root (`~/.omp/profiles/<name>/...`), including hooks, tools, extensions, skills, and memory. Wins even when explicitly empty. |
| `PI_PROFILE` | **REFUSE** | Legacy profile selector, same relocation as `OMP_PROFILE` when the canonical var is unset. |
| `PI_CONFIG_DIR` | **REFUSE** | Changes the config-root dirname under home (default `.omp`) used by the generic config helpers. |
| `PI_CODING_AGENT_DIR` | **REFUSE** | Full agent-directory override for the default profile; changes `getAgentDir()` consumers (native discovery, settings, runtime state, memory DB location). |
| `CLAUDE_CONFIG_DIR` | **REFUSE** | Overrides the Claude-source config root the native provider also honors as a config/extension source (`config-usage.md` §1), relative to process cwd. |
| `XDG_DATA_HOME` | **REFUSE** | Redirects the OMP data root (profiles, skills, sessions) when the target root already exists. |
| `XDG_STATE_HOME` | **REFUSE** | Redirects the OMP state root (same existing-root condition as `XDG_DATA_HOME`). |
| `XDG_CACHE_HOME` | **REFUSE** | Redirects the OMP cache root (same existing-root condition). |
| `MNEMOPI_DATA_DIR` | **REFUSE** | Relocates memory-store data for the `mnemopi` package family. `mnemosyne-memory-backend.md` documents the in-process `memory.backend: mnemopi` path as using the agent memories dir instead, but refusing costs nothing legitimate in a bound launch and closes the gap if that boundary ever narrows. |
| `PI_CODING_AGENT_SESSION_DIR` | ALLOWED | Initial session-directory override consumed by launch argument parsing; changes where a session's transcript is written, not which config/extension/plugin/profile/memory-store loads. |
| `PI_NATIVES_DIR` | ALLOWED | Native addon/grammar extraction-cache root, not a config or memory-store path; structurally safe because `spawn-task.sh` already unconditionally re-exports it before exec (hardcoded, not attacker-controlled). |
| `OMP_AUTORESEARCH_DB_DIR` | ALLOWED | Per-project autoresearch DB / project-artifact root, unrelated to config/extension/plugin/profile/memory loading. |
| `OMP_WORKTREE_DIR` | ALLOWED | Agent-managed worktrees directory, unrelated to config loading. |
| `OMP_GITHUB_CACHE_DB` | ALLOWED | GitHub view-cache database path, unrelated to config loading. |
| `PI_BUILD_URL` | ALLOWED | Origin URL for `omp update`'s build service, not a filesystem path; downloads are verified against the origin's own size/SHA-256 answer, so an overridden origin cannot silently swap a trusted-looking artifact in. |
| `PI_GRAMMARS_URL` | ALLOWED | Base URL for on-demand tree-sitter grammar downloads; each asset is verified against the addon's pinned SHA-256 before landing, same reasoning as `PI_BUILD_URL`. |
| `MNEMOPI_EMBEDDING_MODEL` | ALLOWED | Selects an embedding model id (string), not a storage path. |
| `PWD` | ALLOWED | Used only for canonical-cwd matching in path helpers (symlink resolution), not an alternate load root; the process's actual working directory still comes from the kernel, not this variable. |

### What a release must verify

1. `verify-launcher-release.sh` check 6 passes against the installed release
   before it is pinned in `config.sh`: the env-guard block is present,
   digest-matches `tests/fixtures/launcher-env-guard.v26g.sh`, and precedes
   the argv-allowlist scan.
2. The release's `omp` refuses to start (exit 78, naming the offending
   variable) when any REFUSE-listed variable above is set, including set to
   the empty string, and starts normally with a clean environment or any
   ALLOWED variable set. Proof pattern: `tmp/verify-env-guard-proof.sh` in
   this worktree (never run against the installed release directly; built
   from the pinned fixture).
3. `BASH_ENV` / `ENV` are unset before any shell the launcher or its spawned
   workers start non-interactively (see `docs/design/launcher-env-guard.md`
   for the threat and exact handling).
