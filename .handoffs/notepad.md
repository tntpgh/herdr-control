# herdr-control notepad

## 2026-11-04 — firstmate-dashboard (branch fm/fm-dashboard, https://github.com/tntpgh/herdr-control/pull/412)

### Completed
- New `firstmate-dashboard/` (fmdata.py, render.py, server.py, check.py, launchd.sh, plist template, fixtures/) + CI `.github/workflows/firstmate-dashboard.yml` + README Files row.
- Read-only view of a Firstmate home via its CLIs (`fm-tasks-axi.sh`, `fm-crew-state.sh` with `FM_CREW_STATE_NO_FORGE=1`, `fm-inbox.sh receipts`); only write is `fm-inbox.sh note --request-id` bound to the decision text's digest.
- `/api/summary` + `/api/projects` keep the field names `agent-hooks/omp-herdr-control.ts` and `fleet-tools.ts` read; a failed read returns 503 with no counts.
- Imports `lib/hub_ui` (palette, BASE_CSS, STATIC_ASSETS ship art); no dependency on hub.py or the run registry.

### Defects found and fixed (measured in real Chrome, scratch home)
- `Referrer-Policy: no-referrer` made Chrome send `Origin: null` on the page's own form POST -> 421. Now `same-origin`.
- Early POST refusal left the body on the keep-alive socket; next request parsed it as a request line (501). Body now read before any refusal.
- Both have regression checks in check.py.

### Deliberately NOT done
- Not installed (`launchd.sh install` not run). It refuses while `com.herdr-control.hub` is loaded or the port is busy.
- 8600 was occupied by `hub.py` (pid 52700) respawned by an omp-herdr-bound session's `ensureHub()`; not stopped (not this lane's).
- `/api/panes` (read by agent-edge.sh) not served; agent-edge treats its absence as `unknown`.
- `~/.omp/agent/rules/conductor-decisions.md` still routes decisions to formserve + herdr hub `/decisions`; needs captain update, outside this repo.

### Proof
- `python3 firstmate-dashboard/check.py` -> 43 ok, `all checks passed`.
- `firstmate-dashboard/launchd.sh render --home ~/Code/firstmate | plutil -lint -` -> OK.
- Real-home run: `python3 firstmate-dashboard/server.py --home ~/Code/firstmate --port <spare>`; `curl -s 127.0.0.1:<spare>/api/summary`.

## Completed
- fm-mcp-p2 (branch fm/fm-mcp-p2): Bebop Phase 2. Worker: fm:* scopes (read/reports/request/decide-note/peer), CLIENT_GRANTS dot/duet ceilings + default deny, TOOL_CATALOG per-tool limits (re-checked atomically inside sendOwnerMessage/sendPeerMessage), client_label on audit, duplicate audit rows, typed decisions/reports/posture tools, request_task/answer_decision as notes only, bebop canonical + herdr-mcp alias (per-origin provider + helpers, 421 unknown host). Publisher: decisions/reports/posture/pr_url fields with redaction, note kinds re-checked on Mac, symlinked data/<id> refused. issue-client dot/duet profiles + contract test (now in CI). provision.sh multi-host Access + domains + VERIFY. README scope matrix, herdr-mcp comparison, client reconnect, Bebop cutover runbook with rollback.
- Verified: tsc clean, vitest 133/133, authorization-offline 35, verify-fm-publisher 41, verify-issue-client 10, live --dry-run OK. Security review: 0 high/critical; lows fixed.

## Recommended next steps
- Bebop cutover steps 1–5 done; 6+7 (LEGACY_HERDR_SCOPES=false, drop herdr-mcp alias) in branch fm/bebop-finish. After merge: provision.sh --apply, then dashboard cleanup (herdr-mcp Workers custom domain if left, herdr-mcp.teamthurber.com/authorize off the Access app).
- Phase 3: delete dormant herdr message/task DO paths, publisher.py, tasks.py.

## Key decisions
- Worker script name stays herdr-mcp so DO/KV/grants carry over; one Access app covers both hosts so ACCESS_AUD is unchanged.
- duet ceiling excludes fm:decide-note; legacy herdr:message.owner never maps to fm:decide-note.
