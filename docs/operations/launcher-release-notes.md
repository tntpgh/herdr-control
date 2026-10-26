# Bound launcher release notes

Append one dated section per launcher release that changes what the bound
`omp` wrapper refuses, strips, or allows. `verify-launcher-release.sh` checks
the installed artifact against a commit; this file is the human-readable
record of *why* each environment binding is handled the way it is. See
`tests/fixtures/launcher-argv-guard.*.sh` for the pinned `--config`/`-e`
argv-allowlist contract and `tests/fixtures/launcher-env-guard.*.sh` for the
pinned environment-binding contract.

## Release after 2026-10-26-lanes-v26f (env-binding guard, issue #362)

**Gap.** The bound launcher's argv scan (lines 53-67 of v26f) refuses every
`--config` except the two pinned herdr overlays and rejects `--config=`,
`--profile`, `-e`, `--extension`, `--hook`, `--plugin-dir`, `--plugin-url`.
It never touched the inherited environment. omp loads `PI_CONFIG_FILES` (a
platform path-list) as settings overlays at the same precedence tier as
`--config` (`omp://config-usage.md` §4, layer 3), so any process able to set
the env of a bound launch injected an arbitrary overlay without tripping the
argv allowlist — same bypass class for every other `PI_*`/profile/memory
path variable that relocates where omp reads config, extensions, plugins,
or memory from.

**Fix.** Before the argv scan (`args=("$@")`), the launcher now refuses to
start (`die`, exit 78) when any of the variables marked REFUSE below is set
and non-empty. See `tests/fixtures/launcher-env-guard.v26g.sh` for the exact
pinned block; `verify-launcher-release.sh` checks it is present byte-for-byte
in the shipped release.

**Audit.** Every `PI_*` variable from `omp://environment-variables.md` that
names a config/extension/plugin/profile path, plus `MNEMOPI_DATA_DIR`
(`omp://user-facing-packages.md`) and `CLAUDE_CONFIG_DIR` (same loading
tier as a foreign-provider config root, `omp://config-usage.md` §1):

| Variable | Disposition | Reason |
| --- | --- | --- |
| `PI_CONFIG_FILES` | REFUSE | Settings-overlay path-list, layer 3 — the exact bypass in issue #362. |
| `OMP_PROFILE` | REFUSE | Relocates the entire native config root (`~/.omp/profiles/<name>/agent`): hooks, extensions, tools, settings, skills all move with it. Wins over `PI_PROFILE` even when empty. |
| `PI_PROFILE` | REFUSE | Legacy alias for `OMP_PROFILE`; same relocation when `OMP_PROFILE` is unset. |
| `PI_CONFIG_DIR` | REFUSE | Changes the `.omp` root dirname under home; moves every native-provider source. |
| `PI_CODING_AGENT_DIR` | REFUSE | Full agent-directory override for the default profile; changes `getAgentDir()` consumers (settings, runtime state, hooks). |
| `CLAUDE_CONFIG_DIR` | REFUSE | Redirects the Claude provider's user config root (priority 80). Settings merge visits providers high-to-low but *lower*-priority settings win conflicts (`omp://config-usage.md` §8 caveat), so a planted Claude `config.yml`/hooks dir can override native settings even with `--no-extensions` in effect (that flag only gates the extension-module surface, not settings/hooks/skills discovery). |
| `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | REFUSE | Redirect OMP's data/state/cache roots when the target `omp` subpath already exists. Conditional on a pre-planted directory, but the launcher cannot distinguish a benign operator XDG setup from a planted one, so it fails closed. |
| `MNEMOPI_DATA_DIR` | REFUSE | Redirects the standalone Mnemopi storage root the `mnemopi mcp` server (and `memory.backend: mnemopi` integration) reads/writes; a bound worker's memory tool calls would target an attacker-chosen store instead of the pinned one. |
| `PI_CODING_AGENT_SESSION_DIR` | ALLOW | Only moves where the session transcript starts; does not change which config/extension/plugin/memory source loads. |
| `PI_NATIVES_DIR` | ALLOW (already stripped) | The launcher unconditionally `export`s this itself (`export PI_NATIVES_DIR="$root/natives"`) immediately before `exec`, overwriting any inherited value — no refusal needed, the bypass is structurally impossible. |
| `OMP_AUTORESEARCH_DB_DIR` | ALLOW | Redirects only the per-project autoresearch DB/artifact root; not a config/extension/plugin/profile/memory loading path. |
| `OMP_WORKTREE_DIR` | ALLOW | Agent-managed worktree location only; unrelated to config loading. |
| `OMP_GITHUB_CACHE_DB` | ALLOW | GitHub view cache DB path only. |
| `PI_BUILD_URL`, `PI_GRAMMARS_URL` | ALLOW | Download-origin URLs for `omp update`/grammar fetches, not local config/extension loading paths; a bound worker spawn never triggers either. |
| `MNEMOPI_EMBEDDING_MODEL` | ALLOW | Names an embedding *model*, not a path; does not change which store or config loads. |

**Deferred (needs Terrence's call, same issue, optional item):** a pinned
`lib/no-auto-retain.yml` third bound overlay (`mnemopi: {autoRetain: false}`)
for the main conductor only — not implemented here.
