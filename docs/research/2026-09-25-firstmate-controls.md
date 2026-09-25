# Firstmate controls reuse audit

Date: 2026-09-25. Firstmate source reviewed at commit
[`b42d4fa8a752fad9a5f0235783b02534bce29219`](https://github.com/kunchenguid/firstmate/tree/b42d4fa8a752fad9a5f0235783b02534bce29219).
This audit is deliberately about control shapes, not a wholesale adoption of its
yolo posture.

## Reuse matrix

| Control | Existing herdr-control / open-PR coverage | Decision |
|---|---|---|
| Native status events / transition table | PR #142's research maps Firstmate's `fm-transition-lib.sh:70-103` to herdr status events; current `lib/run-registry.sh:405-427` enforces lifecycle transitions and `lib/reconcile.sh:178-226` consumes native status/session evidence. | Reuse existing registry and PR #142 work; no duplicate table. |
| Durable inbox / control verbs | Firstmate's [`fm-send.sh`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/bin/fm-send.sh) records a sequenced inbox and uses allowlisted keys/verbs. Herdr's `send-to-agent.sh:17-23` is typed terminal delivery, not a durable inbox; neither PR #142 nor #143 adds one. | Gap remains. Do not widen this task into a second control plane. |
| Hook-owned watcher lifecycle | Firstmate's [`omp.md`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/docs/supervision-protocols/omp.md) makes the extension own watcher arm/restart and generation handoff. Herdr's `agent-hooks/omp-herdr-control.ts:437-568` owns reconciliation callbacks, while `attention-tick.sh` remains activity-driven; PR #142's `wake-on-evidence.sh` change is an interruption diagnostic, not a watcher owner. | Gap remains. No duplicate watcher implementation. |
| Generation-bound wake acknowledgement | Current `lib/push-wake.sh:94-135` rejects terminal/recycled worker generations before `input_required`; `herdr-select.sh:248-253` rejects recycled target panes immediately before keypress. PR #142 additionally supersedes stale grace holds in `lib/alert-gate.sh:114-148`. | Reuse current pane birth, prompt, and wake keys; no duplicate acknowledgement path. |
| Pre-tool registration / ownership | Firstmate's [`subagent-guard.md`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/docs/subagent-guard.md) blocks delegation-shaped tools before untracked work exists, using shape matching and explicit observer/todo exclusions. Neither open PR wires an equivalent guard; PR #143's `tool_call` change caches input only. | Implement the smallest missing control: `lib/pretool-registration.sh`, called by the OMP `tool_call` hook only for fleet-creating tool names. |

## Implemented boundary

`lib/pretool-registration.sh` follows Firstmate's narrow pre-tool boundary but
keeps herdr-control's controls intact:

- `task`, `agent`, `workflow`, `spawn`, `worktree`, and future names matching the
  delegation stems are refused unless `HERDR_RUN_ID` + `HERDR_TASK_ID` identify
  a registry row in an active state.
- The registry row must own the current `HERDR_PANE_ID`; its `pane_birth` must
  equal the live `herdr pane list` generation; and the tool cwd must remain
  under the registered worktree. Missing or unreadable proof refuses.
- Observer/todo names and MCP tools are not delegation creation, matching
  Firstmate's explicit exclusions. Ordinary tools are untouched and continue
  through omp approvals and `herdr-select.sh`.
- The OMP extension returns `{block:true}` on refusal. It does not enable
  auto-approval, alter `herdr-select.sh`, weaken human-only command classes,
  bypass audit rows, or read worker-writable identity files as authority.

This is a trust-boundary guard against stale or accidental orchestration, not
same-user process containment; a process that can alter the host registry or
herdr socket is outside this layer's threat model, as stated in
`docs/approval-policy.md:111-129`.

## Source mapping

- Firstmate shape guard and fail-closed purpose: [`docs/subagent-guard.md`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/docs/subagent-guard.md#L43-L74).
- Firstmate native transition record and policy: [`bin/fm-transition-lib.sh`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/bin/fm-transition-lib.sh#L1-L103).
- Firstmate durable control plane: [`bin/fm-send.sh`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/bin/fm-send.sh#L1-L30).
- Firstmate hook-owned omp watcher: [`docs/supervision-protocols/omp.md`](https://github.com/kunchenguid/firstmate/blob/b42d4fa8a752fad9a5f0235783b02534bce29219/docs/supervision-protocols/omp.md#L1-L24).
- Herdr open-PR comparison: [PR #142](https://github.com/tntpgh/herdr-control/pull/142) (`agent-edge.sh`, `attention-tick.sh`, `lib/alert-gate.sh`, and `docs/research/2026-09-24-conductor-friction-and-firstmate.md`) and [PR #143](https://github.com/tntpgh/herdr-control/pull/143) (`agent-hooks/omp-herdr-control.ts`, `lib/run-registry.sh`, `lib/scoped-policy.sh`, and `docs/research/scoped-approval.md`).

The remaining durable-inbox and hook-owned-watcher gaps are intentionally
reported, not hidden behind a partial implementation. The one shipped change
is the pre-tool registration/ownership guard, with a negative proof in
`verify-pretool-registration.sh`.
