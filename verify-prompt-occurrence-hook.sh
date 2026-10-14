#!/usr/bin/env bash
# verify-prompt-occurrence-hook.sh — the TS hook's wiring into
# lib/prompt-occurrence.py (docs/plans/dot-herdr-recovery-slices.md §2):
# agent-hooks/omp-herdr-control.ts's onApprovalRequested/onApprovalResolved/
# onExecutionEnd actually record seen/authorized/completed/withdrawn against
# the real registry schema, under a real worker identity. No live herdr, no
# network — same bun -e + stub-herdr-adjacent pattern as verify-omp-hooks.sh,
# but against a REAL lib/prompt-occurrence.py (HERDR_CONTROL_DIR is this repo
# root, not a shim) and a real temporary registry.sqlite3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# -- bound defer requires a usable proposal, not merely a durable seen row --
persist_out="$(bun -e '
const m = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const row = (proposal) => JSON.stringify({occ_key:"k",written:"seen",proposal});
console.log(`written:${m.parsePersistedResponse(row("written"),"seen",true)}`);
console.log(`exists:${m.parsePersistedResponse(row("exists"),"seen",true)}`);
console.log(`too_large:${m.parsePersistedResponse(row("too_large"),"seen",true)}`);
' 2>/dev/null)"
printf '%s\n' "$persist_out" | grep -q '^written:true$' && ok "bound seen row defers when its proposal was written" || bad "bound written proposal was not accepted"
printf '%s\n' "$persist_out" | grep -q '^exists:true$' && ok "bound duplicate defers when its exact proposal exists" || bad "bound existing proposal was not accepted"
printf '%s\n' "$persist_out" | grep -q '^too_large:false$' && ok "oversized bound proposal fails persistence and is denied immediately" || bad "oversized bound proposal was allowed to defer"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"
mkdir -p "$STATE"
DB="$STATE/registry.sqlite3"

RUN_ID="r1"; TASK_ID="t1"; PANE_ID="w1:p1"; PANE_BIRTH="w1term"

sqlite3 "$DB" "
CREATE TABLE events (
  sequence    INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id    TEXT NOT NULL UNIQUE,
  run_id      TEXT NOT NULL,
  task_id     TEXT NOT NULL DEFAULT '',
  type        TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  payload     TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE tasks (
  task_id TEXT, run_id TEXT, pane_id TEXT, pane_birth TEXT NOT NULL DEFAULT ''
);
INSERT INTO tasks (task_id, run_id, pane_id, pane_birth)
  VALUES ('$TASK_ID', '$RUN_ID', '$PANE_ID', '$PANE_BIRTH');
" || { echo "fixture: failed to seed registry schema" >&2; exit 1; }

run_bun() {
  HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$STATE" \
  HERDR_RUN_ID="$RUN_ID" HERDR_TASK_ID="$TASK_ID" HERDR_PANE_ID="$PANE_ID" \
  bun -e "$1" 2>&1
}

# -- approval requested twice (repeat firing) must not lose cached input ----
out1="$(run_bun '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_call"]({ toolName: "bash", toolCallId: "call-1", input: { command: "git status" } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "call-1", sessionId: "sess-1" });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "call-1", sessionId: "sess-1" });
await new Promise(r => setTimeout(r, 200));
console.log("OK");
')"
echo "$out1" | grep -q OK && ok "two repeat approval-requested firings run without throwing" \
  || bad "repeat firing crashed: $out1"

occ_count="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_seen';")"
[ "$occ_count" = "1" ] && ok "exactly one seen row for two repeated firings (idempotent, not dropped)" \
  || bad "expected exactly 1 seen row, got $occ_count"

# -- a full approve -> complete cycle resolves completed --------------------
# ctx carries a real session id (sessionIdOf reads ctx.sessionManager.
# getSessionId()): identity_verified requires both pane_birth (from the
# seeded registry row) and native_session to be non-empty (M1, Main review).
sqlite3 "$DB" "DELETE FROM events;"
run_bun '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
const ctx = { sessionManager: { getSessionId: () => "sess-2" } };
handlers["tool_call"]({ toolName: "bash", toolCallId: "call-2", input: { command: "git status" } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "call-2" }, ctx);
handlers["tool_approval_resolved"]({ toolName: "bash", toolCallId: "call-2", approved: true }, ctx);
handlers["tool_execution_end"]({ toolName: "bash", toolCallId: "call-2", result: {}, isError: false }, ctx);
await new Promise(r => setTimeout(r, 200));
' >/dev/null

lifecycle="$(python3 "$here/lib/prompt-occurrence.py" fold --db "$DB" --run "$RUN_ID" --task "$TASK_ID" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(iter(d.values()))["lifecycle"])' 2>/dev/null)"
[ "$lifecycle" = "resolved:completed" ] && ok "approve -> execution_end resolves completed" \
  || bad "expected resolved:completed, got '$lifecycle'"

# -- a deny resolves declined, never approved, with no completion that follows
sqlite3 "$DB" "DELETE FROM events;"
run_bun '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_call"]({ toolName: "bash", toolCallId: "call-3", input: { command: "rm -rf /" } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "call-3" });
handlers["tool_approval_resolved"]({ toolName: "bash", toolCallId: "call-3", approved: false, reason: "denied" });
await new Promise(r => setTimeout(r, 200));
' >/dev/null

lifecycle="$(python3 "$here/lib/prompt-occurrence.py" fold --db "$DB" --run "$RUN_ID" --task "$TASK_ID" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(iter(d.values()))["lifecycle"])' 2>/dev/null)"
[ "$lifecycle" = "resolved:declined" ] && ok "deny resolves declined directly" \
  || bad "expected resolved:declined, got '$lifecycle'"

# -- aborted before any decision resolves withdrawn, not completed ----------
sqlite3 "$DB" "DELETE FROM events;"
run_bun '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_call"]({ toolName: "bash", toolCallId: "call-4", input: { command: "git status" } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "call-4" });
handlers["tool_execution_end"]({ toolName: "bash", toolCallId: "call-4", result: {}, isError: true });
await new Promise(r => setTimeout(r, 200));
' >/dev/null

lifecycle="$(python3 "$here/lib/prompt-occurrence.py" fold --db "$DB" --run "$RUN_ID" --task "$TASK_ID" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(iter(d.values()))["lifecycle"])' 2>/dev/null)"
[ "$lifecycle" = "resolved:withdrawn" ] && ok "execution end with no decision resolves withdrawn" \
  || bad "expected resolved:withdrawn, got '$lifecycle'"

# -- an ordinary auto-approved call never records an occurrence at all ------
sqlite3 "$DB" "DELETE FROM events;"
run_bun '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_call"]({ toolName: "read", toolCallId: "call-5", input: { path: "/tmp/x" } });
handlers["tool_execution_end"]({ toolName: "read", toolCallId: "call-5", result: {}, isError: false });
await new Promise(r => setTimeout(r, 200));
' >/dev/null
occ_count="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type LIKE 'prompt_occ_%';")"
[ "$occ_count" = "0" ] && ok "an auto-approved call (no approval event) records zero occurrence rows" \
  || bad "expected 0 occurrence rows for an unprompted call, got $occ_count"

# -- #277: a write's complete input reaches the registry and a proposal file -
sqlite3 "$DB" "DELETE FROM events;"
WCONTENT="$(for i in $(seq 1 40); do printf 'line %02d of a long multi-line write\n' "$i"; done)"; export WCONTENT
run_bun '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
const ctx = { cwd: "'"$WORK"'", sessionManager: { getSessionId: () => "sess-w" } };
const input = { path: ".handoffs/plan.md", content: process.env.WCONTENT };
handlers["tool_call"]({ toolName: "write", toolCallId: "call-w", input }, ctx);
handlers["tool_approval_requested"]({ toolName: "write", toolCallId: "call-w" }, ctx);
await new Promise(r => setTimeout(r, 300));
handlers["tool_approval_resolved"]({ toolName: "write", toolCallId: "call-w", approved: true }, ctx);
handlers["tool_execution_start"]({ toolName: "write", toolCallId: "call-w", args: input }, ctx);
await new Promise(r => setTimeout(r, 300));
' >/dev/null
seen="$(sqlite3 "$DB" "SELECT payload FROM events WHERE type='prompt_occ_seen';")"
want_sha="$(WCONTENT="$WCONTENT" python3 -c 'import hashlib,json,os
body=json.dumps({"tool":"write","input":{"path":".handoffs/plan.md","content":os.environ["WCONTENT"]},"known":True},sort_keys=True,separators=(",",":"))
print(hashlib.sha256(body.encode()).hexdigest())')"
[ "$(printf '%s' "$seen" | jq -r .payload_sha256)" = "$want_sha" ] && [ "$(printf '%s' "$seen" | jq -r .cwd)" = "$WORK" ] \
  && [ "$(printf '%s' "$seen" | jq -r '.dispatched_at_ms | type')" = number ] \
  && ok "write approval records the full payload sha256, cwd and dispatch time" || bad "write seen row: $seen"
key="$(printf '%s' "$seen" | jq -r .occ_key)"
[ "$(jq -r .input.content "$STATE/proposals/$key.json" 2>/dev/null)" = "$WCONTENT" ] \
  && ok "the proposal file holds the complete multi-line content" || bad "proposal file missing or incomplete"
case "$seen" in *"line 20 of"*) bad "raw content leaked into the shared events table" ;; *) ok "no raw content in the events table" ;; esac
[ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_started';")" = 1 ] \
  && ok "execution start of the approved write is timestamped" || bad "no prompt_occ_started row"

printf -- '-----\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
