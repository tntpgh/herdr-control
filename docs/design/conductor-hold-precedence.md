# Task-scoped automatic-approval hold

Status: design candidate only. This document and its executable model do not
activate a live policy or create a hold.

## Incident and invariant

After a person denied a draft-publication prompt, the worker rewrote only the
PR body and received a new prompt id. Peer automation then approved the new
prompt because command policy judged its shape independently. Prompt identity
is therefore too narrow for the owner's instruction: stop publishing this
task's flawed revision.

The required invariant is:

> An active, task-scoped owner/conductor hold defeats every automatic approval
> route, including peer, scope, file, and ownership grants. Rewording the
> command, changing its prompt id, or changing the automatic grant does not
> clear the hold.

## Bounded state

A hold is a durable registry record bound to `task_id`, the task's current
`pane_birth`, a semantic scope, its creator, reason, and creation time. Initial
scope vocabulary is deliberately closed:

- `remote-publication`: creating/updating a PR, pushing a branch, or otherwise
  publishing the task's current revision remotely.
- `all-automatic-approvals`: emergency stop for this task only.

Unknown hold scopes are invalid. While either hold is active, an action whose
semantic scope cannot be classified fails closed instead of escaping the hold.

It is neither global nor permanent. It ends only through an explicit release
bound to the same task and pane birth by human authority, or by the registered
live conductor using the reviewed conductor path with a non-empty reason.
Worker activity, a new prompt id, a rewritten body, another peer process, task
state churn, and an ownership grant never release it. Pane recycling makes an
old hold inapplicable to the new birth but preserves its audit record.

## Enforcement point

Enforce once in `herdr-select.sh` after task/pane identity is freshly bound and
before `peer_decide`, audit insertion, or any key/action dispatch. Human Deny
remains available. Human approval may release explicitly, but must not silently
combine release and approval. Conductor approval refuses while held and tells
the conductor to perform the separate reviewed release first.

The same predicate must guard exact bound-tool authorization so the hook route
cannot bypass the terminal route. A refusal records `approval_held` with the
hold id, task, pane birth, semantic scope, proposed command digest, actor, and
authority; it records no approval and sends no key.

## Acquisition

Do not infer a durable task hold from every ordinary Deny. A human Deny of an
action positively classified as `remote-publication` atomically creates a
bounded denial fence for that task and pane birth. The fence expires after 30
minutes unless explicitly released sooner; this blocks an immediate
rewrite/new-prompt-id retry without turning one Deny into permanent global
policy. An explicit owner/conductor `HOLD` upgrades the fence to a durable hold
(`remote-publication` or `all-automatic-approvals`) with no time-based release.
Other Denies remain occurrence-local. The incident's explicit `HOLD ... STOP
before push` maps to the durable `remote-publication` hold.

Release is a separate transition. It requires the same task and pane birth and
either human authority or the registered live conductor through the reviewed
path with a non-empty reason. Worker/peer/grant authority, an empty reason,
wrong task/birth, a stale conductor, or a request combining release with an
approval all refuse.

## Review boundary

Parser validity, watchdog terminology, and provenance are observability fixes
and can ship independently. This hold changes authorization precedence and
requires its own frozen-diff review and owner approval before activation.
