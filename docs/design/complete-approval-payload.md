# Complete approval payload for write/edit (herdr-control #277)

## Bug (before this change)

herdr-select judged `write`/`edit` approvals on the scraped terminal panel. The
panel is clipped (`[…Nch elided…]`), wrap-dependent, and multi-row, so the
judgment saw a partial picture of the payload, and `code_ref_inspect` misread a
write panel as "runs a script file". The hook never recorded the tool input for
these tools (`cacheBashInput` was bash-only), so `prompt_occ_seen.input_digest`
was null and no complete payload existed anywhere but the terminal. Evidence:
`.handoffs/PROVENANCE.md` (task `task_20261013T171009Z_440_10041`).

## Decision: exact protocol binding, otherwise human-only

Stock OMP 18.10.4 at `687892d1046ecaf18829b45f5b86928a308258f4` resolves an
approval only by a keypress on whatever prompt is painted; it has no
request-id-targeted resolver. The companion pinned OMP source patch adds
`omp.tool-approval-binding.v1`: a one-shot request ID bound
to session, tool call, tool name, and a SHA-256 digest of the complete effective
arguments. Two queued write/edit prompts
can render identically. An edit panel shows only `File:` names, and a write
panel shows the target plus the first 2000 UTF-16 units of content. So
a check before Enter cannot prove which call the key approves. One example:
another responder answers the reviewed prompt A, and queued prompt B paints in
its place. The screen digest is unchanged, so Enter approves B while the audit
names A. No screen-side check (panel corroboration, prompt epochs, lost-`seen`
markers) closes this.

Herdr persists that exact binding alongside the proposal. After review,
`herdr-select` records authorization without pressing a terminal key; the hook
then resolves the same request tuple through OMP's resolver. OMP recomputes the
digest immediately before execution. If any v1 field or resolver is missing,
Herdr never presses Approve on a `write`/`edit` for a peer or conductor and the
operation remains human-only. Deny and recognized humans answering their own
screen are unaffected.

## What the change keeps: the complete-payload review artifact

The change reuses the existing occurrence record (`lib/prompt-occurrence.py`,
run registry `events`). There is no new store.

| Step | Where | What |
|---|---|---|
| dispatch | `omp-herdr-control.ts` | For a bound request, verifies OMP's canonical effective-arguments JSON against its SHA-256 and builds the proposal from that exact value, never the earlier `tool_call` cache. Passes the envelope to `seen` on stdin, never argv. |
| proposal | `prompt-occurrence.py seen` | Records `input_digest`, the full `payload_sha256`, `cwd`, dispatch time and opaque OMP binding identifiers in the registry. The mode-0600 proposal stores the full input and canonical OMP JSON; review independently hashes the canonical bytes and requires its parsed value to equal the proposal input. Raw input never enters shared events. |
| review | `prompt-occurrence.py proposal [--show] [--expect-sha]` | Finds the one occurrence whose recorded screen prompt id is on screen. Requires: identity verified, same pane lifetime, parseable, still `requested`, no mismatch. Recomputes both hashes from the file and checks them against the registry row. Re-resolves every target now: realpath must stay inside the worker's worktree, with no `..` component, no final-component symlink, no hard link (`st_nlink > 1`, mirroring the dispatch guard), no `.git`, and no URL/`~` forms. Returns the exact payload. `--show` prints the payload in full with its sha256 for the human; `--expect-sha` confirms it is still the payload that was reviewed. |
| resolution/refusal | `herdr-select.sh` | With an exact persisted v1 request+digest, records authorization and sends no terminal key; the hook calls the targeted resolver. Without it, a non-human attempt exits 8 with no key pressed. Shared audit text carries only header + sha256, never the raw body. |
| execution | OMP + `omp-herdr-control.ts` | The hook resolves the exact tuple. OMP recomputes the argument digest and emits a dedicated block-only `tool_execution_validate` immediately before mutation; Herdr reruns only its authoritative worker path/scope guard, closing post-review target, ancestor-symlink, and hard-link swaps without replaying side-effecting `tool_call` handlers. Lifecycle reset denies and settles pending requests. |
| retention | `prompt-occurrence.py` | The proposal file is deleted when the occurrence resolves: completed, declined, withdrawn, or a deny decision. Proposals and orphaned temp files older than 24 h are swept on the next write. |

The review artifact refuses, and fails closed on, each of these:
- no occurrence, or no file;
- a malformed or other-version file;
- an identity or tool mismatch;
- a hash mismatch (truncation or substitution);
- an occurrence mismatch event;
- a resolved occurrence, or unproven identity;
- a sha other than `--expect-sha`;
- a target outside the worktree, or one using `..`, a symlink, a hard link or `.git`.

Concurrency/restart: the occurrence key is (run, task, pane, pane_birth,
native_session, tool_call_id). Lookups go through the selecting pane's own
registered task, so another task's proposal can never match. A restarted omp
gets a new session and call id; the old occurrence never matches the new
screen prompt, and its file is removed on resolution. OMP's resolver is
one-shot, rejects every tuple mismatch, clears pending bindings on session
switch/shutdown, and rechecks the argument digest immediately before execution.

Ceilings:
- Inputs over 200,000 JSON characters are not recorded, and proposals over
  256 KiB are not written. Bound deferral requires the proposal result to be
  `written` or `exists`; otherwise the exact request is denied immediately
  rather than waiting for its timeout. A prompt pending
  over 24 h loses its swept proposal.
- Raw Enter remains the stock human path for requests that were not deferred;
  deferred requests have no terminal-key fallback.

## Not in this change: durable workspace permission policy

Issue #277 also proposed treating writes confined to a worker's own
`.handoffs/` as a standing permission category. This implementation does not
make that broader policy change; it only makes each existing approval exact.
