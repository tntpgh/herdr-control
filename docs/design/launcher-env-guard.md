# Launcher env-binding guard (issue #362)

## Problem

The bound launcher's argv scan (`tests/fixtures/launcher-argv-guard.v26d.sh`)
refuses every `--config` value except the two pinned herdr overlays, and
refuses `--profile`, `-e`, `--extension`, `--hook`, `--plugin-dir`,
`--plugin-url`. It never touches the process environment. omp loads several
environment variables as config/extension/plugin/profile/memory-path
overrides with precedence equal to or higher than argv (`omp://config-usage.md`
§4, layer 3: `PI_CONFIG_FILES` loads before `--config` overlays). Any caller
that controls the launched process's environment — not just its argv —
bypasses the allowlist entirely. Confirmed live (omp 18.12.6):

```
$ omp config get mnemopi.autoRetain                                   -> true
$ PI_CONFIG_FILES=$TMPDIR/noretain.yml omp config get mnemopi.autoRetain -> false
```

## Classification table

Full table with per-variable reasoning: `docs/operations/launcher-release-notes.md`.
Summary:

| Disposition | Variables |
| --- | --- |
| **REFUSE** (exit 78 before exec) | `PI_CONFIG_FILES`, `OMP_PROFILE`, `PI_PROFILE`, `PI_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `CLAUDE_CONFIG_DIR`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `MNEMOPI_DATA_DIR` |
| ALLOWED (reason given) | `PI_CODING_AGENT_SESSION_DIR`, `PI_NATIVES_DIR`, `OMP_AUTORESEARCH_DB_DIR`, `OMP_WORKTREE_DIR`, `OMP_GITHUB_CACHE_DB`, `PI_BUILD_URL`, `PI_GRAMMARS_URL`, `MNEMOPI_EMBEDDING_MODEL`, `PWD` |

Refuse, not strip, for the ten above: per issue #362's own framing, silently
dropping a config-path variable hides a caller that expected it to apply; a
loud `die` surfaces the mistake (or the attack) instead of producing
quietly-wrong behavior. Contract pinned at
`tests/fixtures/launcher-env-guard.v26g.sh`; verified by
`verify-launcher-release.sh` check 6 and (runtime) `tmp/verify-env-guard-proof.sh`.

## `BASH_ENV` / `ENV` threat

`BASH_ENV` and `ENV` are POSIX/bash shell startup-file variables: when bash
starts **non-interactively** to run a script or a `bash -c <command>`
invocation, it reads `$BASH_ENV`, expands it, and sources that file before
running anything else — the same mechanism as `~/.bashrc` for interactive
shells, but for scripted/one-shot invocations. POSIX `sh` has the equivalent
`ENV` variable. This is exactly the shape of every bash-tool invocation a
bound omp session makes (`bash -c '<command>'`, non-interactive, no login).

This differs from the ten REFUSE variables above in one critical way: it is
not an input to **omp's own** config discovery, so the bound launcher
starting successfully proves nothing about it. The risk fires later and
downstream, every time the bash tool (or any extension/hook that shells out)
starts a non-interactive bash subprocess that inherits the bound session's
environment:

1. A caller sets `BASH_ENV=/path/to/payload.sh` in the environment the bound
   launcher execs into.
2. omp runs normally; the launcher's argv scan and (after this change) its
   REFUSE guard both pass, because `BASH_ENV` is not on either list and
   never appears in argv at all.
3. Every subsequent `bash -c '<reviewed command>'` the bash tool runs first
   silently sources `payload.sh` — arbitrary shell code, functions, aliases,
   or a `PATH` rewrite — **before** the reviewed command text executes.

This is a materially different attack surface than the ten REFUSE variables:
it does not need the bash tool's own command string to contain anything
suspicious, so it is invisible to `command-policy.sh`/`pretool-shadow.sh`'s
static text analysis of the command being approved. The approved command and
the command that actually runs can differ by whatever `payload.sh` injects
(a function shadowing `git`, an exported `GIT_SSH_COMMAND`, a background
process) — the reviewer only ever sees the former.

### Recommended handling: unset, not refuse, at the launcher

Unlike the ten REFUSE variables, `BASH_ENV`/`ENV` should be **unconditionally
unset** by the launcher before `exec`, not refused:

- No legitimate bound-session workflow sets `BASH_ENV`/`ENV` on purpose — the
  "silently dropping hides an expectant caller" argument that justifies
  REFUSE for `PI_CONFIG_FILES` et al. does not apply, because nobody expects
  a worker's bash-tool invocations to pick up an external shell rc file.
- The launcher itself is not a shell *script being run non-interactively
  with these vars set* in the dangerous sense (it runs once, at process
  start, and this guard governs it directly); the actual hazard is
  reintroduced every time it is inherited by a later subprocess. Unsetting
  it at the top of the process tree is the one point that closes every
  downstream path at once, including hooks/extensions that shell out
  directly rather than through the bash tool.
- A hard refuse would make a bound session fail outright on a plausible false
  positive (a parent process or container `ENTRYPOINT` exporting `ENV=/etc/profile`
  for POSIX compliance, unrelated to any attack) with no user-facing benefit
  over simply not propagating it.

Concretely: `unset BASH_ENV ENV` immediately after the REFUSE guard block
(same place in the launcher, before `exec`), unconditional — no value is
legitimate to keep.

### What a release must verify

1. The launcher wrapper's text contains `unset BASH_ENV ENV` (or equivalent)
   after the REFUSE guard block and before `exec`.
2. Runtime negative: set `BASH_ENV=<file with a sentinel>`, launch the
   candidate, and run a bash-tool-shaped non-interactive `bash -c 'echo ok'`
   downstream of it; the sentinel must not execute and must not appear in
   output or in the subprocess's own `BASH_ENV`. (Not yet implemented as an
   automated check in this change — `verify-launcher-release.sh` only
   confirms the REFUSE block's presence/digest/ordering today; a future
   release adding the `unset` line should add the matching negative the same
   way check 6 was added here.)
3. The same two variables are added to the audit table in
   `docs/operations/launcher-release-notes.md` with disposition `STRIPPED`
   once the `unset` line ships, distinct from `REFUSE` (exit 78) and
   `ALLOWED`.

This document captures the design and acceptance criteria; implementing the
`unset BASH_ENV ENV` line and its negative test is follow-on work, scoped
separately per this task's SPEC (which asked for the REFUSE guard plus this
design, not the strip implementation).
