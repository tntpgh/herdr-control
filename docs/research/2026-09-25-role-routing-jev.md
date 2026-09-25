# Role routing and optional JEV feasibility

## Verdict

JEV is feasible as an optional, fail-closed triage provider. The deterministic
router remains the default and the human-only command boundary remains owned by
`herdr-select.sh` and `lib/command-policy.sh`. JEV may classify a task role and
risk; it MUST NOT approve commands, secrets, pushes, merges, governance, or
external communications.

## Sources

- Firstmate architecture and MIT project: https://github.com/kunchenguid/firstmate
  and https://raw.githubusercontent.com/kunchenguid/firstmate/main/docs/architecture.md
- TypeSafe quickstart: https://docs.typesafe.ai/introduction/quickstart
- LangChain JEV harness article: https://www.langchain.com/blog/building-a-harness-with-jev

The TypeSafe quickstart documents `POST https://api.typesafe.ai/v1/systemone`,
`Authorization: Bearer <TYPESAFE_API_KEY>`, JSON state, model `jev-latest`, and
named typed questions. This implementation uses only Python's standard-library
`urllib.request`; no TypeSafe SDK is installed or required.

## Exact API contract used here

Request body:

```json
{
  "state": "<brief>",
  "model": "jev-latest",
  "questions": {
    "role": {
      "type": "choice",
      "instructions": "...",
      "criteria": {
        "orchestrator": "...",
        "planner": "...",
        "implementer": "...",
        "trivial": "...",
        "escalate": "..."
      }
    },
    "risk_high": {
      "type": "noul",
      "instructions": "..."
    }
  }
}
```

The client accepts only an `answers.role` object with `type: choice`, an exact
allowed role, and numeric confidence in `[0, 1]`; confidence below `0.75`
fails closed. It accepts only `answers.risk_high` with `type: noul` and numeric
probability in `[0, 1]`; probability `>= 0.5` forces `escalate`. The emitted
JSON is redacted to provider, role, job class, confidence, risk flag, reason,
and model. API failures, malformed answers, low confidence, and high risk all
return nonzero. The output never includes the API key or raw API state.

## Local capability

JEV capability: TYPESAFE_API_KEY absent.

Therefore no live API call was attempted. Fake-server tests exercise valid,
malformed, low-confidence, high-risk, and approval-shaped responses locally.

## Observed limits

- The deterministic router intentionally escalates auth, security, secrets,
money, production, destructive, migration, and external-communication briefs.
- JEV is an optional classifier, not an authorization mechanism. A successful
classification still does not create a command-policy exception.
- No local latency, cost, accuracy, or vendor speed claim is asserted here.
- `scripts/route-task.sh` and `spawn-task.sh --route ... --brief ...` have no
worktree, tab, registry, or other external side effect before routing succeeds.
Existing explicit job-class invocations retain their prior argument shape.
