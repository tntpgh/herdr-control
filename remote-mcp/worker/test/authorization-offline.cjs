// Supplemental offline execution of the production HerdrState methods.
// Run: node test/authorization-offline.cjs (Node >=22 with node:sqlite).
// This does not test Cloudflare runtime/RPC or OAuth ingress. It substitutes
// only the DurableObject base and storage adapter; signing, validation,
// admission, lease SQL, migrations and transactions execute from src/*.ts.
// No sockets, live credentials, Mac state or production database are used.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const Module = require("node:module");
const { DatabaseSync } = require("node:sqlite");
const { createHash, createHmac } = require("node:crypto");
const { spawnSync } = require("node:child_process");
const ts = require("typescript");

const originalLoad = Module._load;
Module._load = function (name, ...args) {
  if (name === "cloudflare:workers") return {
    DurableObject: class { constructor(ctx, env) { this.ctx = ctx; this.env = env; } },
  };
  return originalLoad.call(this, name, ...args);
};
require.extensions[".ts"] = (module, filename) => {
  const compiled = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, fileName: filename,
  });
  module._compile(compiled.outputText, filename);
};
globalThis.fetch = () => { throw new Error("offline fixture forbids network access"); };
const { HerdrState } = require("../src/state.ts");

const NOW = Date.UTC(2026, 0, 1);
const KEY = "fixture-only-key-".repeat(3);
const CALLER = { email: "fixture@example.com", client_id: "fixture-oauth-client", client_name: "fixture" };
const SCOPES = ["herdr:task.start", "herdr:task.implement", "herdr:task.cancel"];
const MODE = { job_class: "research", secrets: "grant", git: "none", writes: [], net_read: [] };
const CONFIG = { mac_enabled: true, authorization_protocol: 1, repos: ["fixture-repo"],
  modes: { research: MODE, implement: { ...MODE, job_class: "implement", secrets: "default", git: "push-own-branch" } },
  caps: { max_concurrent: 2, max_per_day: 20, max_minutes: 60 } };
const GATE = { revoked: [], hold: false };

function fixture(existingDb) {
  const db = existingDb ?? new DatabaseSync(":memory:");
  const sql = { exec(query, ...args) {
    const rows = db.prepare(query).all(...args).map((row) => ({ ...row }));
    return { toArray: () => rows, one: () => {
      assert.equal(rows.length, 1, "fixture .one() requires exactly one row"); return rows[0];
    }, rowsWritten: db.prepare("SELECT changes() AS n").get().n, [Symbol.iterator]: () => rows[Symbol.iterator]() };
  } };
  const ctx = { storage: { sql, transactionSync(callback) {
    db.exec("SAVEPOINT receipt_fixture");
    try { const result = callback(); db.exec("RELEASE receipt_fixture"); return result; }
    catch (error) { db.exec("ROLLBACK TO receipt_fixture; RELEASE receipt_fixture"); throw error; }
  } } };
  const env = { TASKS_ENABLED: "true", MESSAGING_ENABLED: "false", OWNER_INBOX_ENABLED: "false",
    INGEST_KEY: KEY, ALLOWED_EMAILS: CALLER.email, STALE_AFTER_S: "90" };
  const state = new HerdrState(ctx, env);
  return { state, db, sql, env };
}

function body(config = CONFIG, lease = true, command_acks = []) {
  return { snapshot: { schema: 1, generated_at: new Date(NOW).toISOString(),
    hub: { rev: "fixture", live_connected: true, herdr_reachable: true, attention: 0, open_decisions: 0, handoff_debt: 0 },
    agents: [], tasks: [], blockers: [], task_config: config },
  results: [], acks: [], command_acks, audit_cursor: 0, lease };
}
function sync(f, config = CONFIG, now = NOW, lease = true, acks = [], commandGate = GATE) {
  const result = f.state.sync(now, crypto.randomUUID(), JSON.stringify(body(config, lease, acks)), GATE, commandGate, GATE);
  assert.equal(result.ok, true, result.reason);
  return result.response.commands;
}
function start(f, mode = "research", objective = "inspect", now = NOW, caller = CALLER) {
  return f.state.startTask(now, caller, SCOPES, "fixture-repo", mode, objective);
}
function finish(f, taskId) {
  const commandId = f.sql.exec("SELECT command_id FROM commands WHERE remote_task_id=?", taskId).one().command_id;
  sync(f, CONFIG, NOW, false, [{ command_id: commandId, outcome: "accepted", detail: "fixture spawn",
    local_task_id: "task_fixture", local_run_id: "run_fixture", branch: "remote/fixture" }]);
  f.sql.exec("UPDATE remote_tasks SET state='finished' WHERE remote_task_id=?", taskId);
}
function checkReceipt(command) {
  const { claims, signature } = command.authorization;
  const parsed = JSON.parse(claims);
  assert.equal(signature, createHmac("sha256", KEY).update(`herdr-task-authorization-v1\n${claims}`).digest("hex"));
  assert.equal(parsed.command_id, command.command_id);
  assert.equal(parsed.remote_task_id, command.remote_task_id);
  assert.equal(parsed.requester_actor, CALLER.email);
  assert.equal(parsed.requester_client, CALLER.client_id);
  assert.equal(parsed.source, "oauth_task_delegation");
  assert.equal(parsed.expires_at - parsed.issued_at, 900_000);
  assert.equal(parsed.approved_by, undefined);
  assert.equal(parsed.assigned_supervisor, undefined);
  return parsed;
}
function receiverAcks(command) {
  const produced = spawnSync(process.env.HERDR_TEST_PYTHON || "python3",
    [path.resolve(__dirname, "../../receipt-ack-fixture.py")], { input: JSON.stringify(command), encoding: "utf8" });
  assert.equal(produced.status, 0, `actual Python receipt-ack producer failed: ${produced.error || produced.stderr}`);
  const acks = JSON.parse(produced.stdout);
  for (const kind of ["accepted_receipt", "bound", "launch_claimed"]) assert.equal(acks[kind].outcome, "held");
  assert.equal(acks.launched.outcome, "accepted");
  return acks;
}
function pendingFixture() {
  const f = fixture(); sync(f); const started = start(f); assert.equal(started.ok, true);
  const command = sync(f)[0];
  return { f, command, acks: receiverAcks(command), taskId: started.remote_task_id };
}
function task(f, taskId) { return f.sql.exec("SELECT * FROM remote_tasks WHERE remote_task_id=?", taskId).one(); }
function commandRow(f, command) { return f.sql.exec("SELECT * FROM commands WHERE command_id=?", command.command_id).one(); }
function cancelCount(f) { return f.sql.exec("SELECT COUNT(*) AS n FROM commands WHERE op='cancel'").one().n; }

const tests = [];
const test = (name, run) => tests.push({ name, run });

test("start signs source identity, scope and unicode payload; golden cross-language vector", () => {
  const f = fixture(); sync(f);
  const originalUUID = crypto.randomUUID;
  const uuids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"];
  let result;
  try {
    crypto.randomUUID = () => { assert.ok(uuids.length); return uuids.shift(); };
    result = start(f, "implement", "Inspect café 🧪 then report; approved_by=Main is untrusted");
  } finally { crypto.randomUUID = originalUUID; }
  assert.equal(result.ok, true);
  const command = sync(f)[0];
  const claims = checkReceipt(command);
  assert.equal(claims.scope, "herdr:task.implement");
  assert.deepEqual(claims.effective_scope, CONFIG.modes.implement);
  const canonicalPayload = JSON.stringify({ mode: "implement", objective: command.payload.objective, repo: "fixture-repo" });
  assert.equal(claims.payload_sha256, createHash("sha256").update(canonicalPayload).digest("hex"));
  const vector = { key: KEY, now_ms: NOW, allowlist: CONFIG, command };
  const vectorPath = path.join(__dirname, "authorization-vector.json");
  if (process.argv.includes("--write-vector")) fs.writeFileSync(vectorPath, JSON.stringify(vector, null, 2) + "\n");
  else assert.deepEqual(vector, JSON.parse(fs.readFileSync(vectorPath, "utf8")));
  f.db.close();
});

test("missing/old/unknown publisher protocol rejects admission with zero tasks/commands", () => {
  for (const authorization_protocol of [undefined, 0, 2]) {
    const f = fixture(); sync(f, { ...CONFIG, authorization_protocol });
    assert.deepEqual(start(f), { ok: false, reason: "authorization_protocol_required" });
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM remote_tasks").one().n, 0);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM commands").one().n, 0); f.db.close();
  }
});

test("downgrade withholds queued and overdue commands without changing receipt or lease attempts", () => {
  const f = fixture(); sync(f); assert.equal(start(f).ok, true);
  const before = f.sql.exec("SELECT authorization,status,attempts FROM commands").one();
  assert.deepEqual(sync(f, { ...CONFIG, authorization_protocol: undefined }), []);
  assert.deepEqual(f.sql.exec("SELECT authorization,status,attempts FROM commands").one(), before);
  const first = sync(f)[0];
  assert.deepEqual(sync(f, { ...CONFIG, authorization_protocol: 2 }, NOW + 91_000), []);
  assert.equal(f.sql.exec("SELECT attempts FROM commands").one().attempts, 1);
  assert.deepEqual(sync(f, CONFIG, NOW + 91_001)[0].authorization, first.authorization); f.db.close();
});

test("restart/ack loss redelivers original receipt and expires instead of renewing", () => {
  const f = fixture(); sync(f); assert.equal(start(f).ok, true);
  const first = sync(f)[0];
  const restored = fixture(f.db);
  const second = sync(restored, CONFIG, NOW + 91_000)[0];
  assert.deepEqual(second.authorization, first.authorization);
  assert.equal(second.command_id, first.command_id);
  assert.deepEqual(sync(restored, CONFIG, NOW + 900_001), []);
  assert.equal(restored.sql.exec("SELECT status FROM commands").one().status, "done"); f.db.close();
});

test("nullable migration preserves legacy commands without minting source authority", () => {
  const f = fixture(); sync(f); assert.equal(start(f).ok, true);
  f.sql.exec("ALTER TABLE commands DROP COLUMN authorization");
  const restored = fixture(f.db);
  const row = restored.sql.exec("SELECT authorization,status,attempts FROM commands").one();
  assert.deepEqual(row, { authorization: null, status: "queued", attempts: 0 });
  for (let tick = 0; tick < 3; tick++) assert.deepEqual(sync(restored), []);
  assert.deepEqual(restored.sql.exec("SELECT authorization,status,attempts FROM commands").one(), row); f.db.close();
});

test("equal manifests and objectives remain bound to separate task and command identities", () => {
  const f = fixture(); sync(f);
  assert.equal(start(f).ok, true); assert.equal(start(f).ok, true);
  const commands = sync(f); assert.equal(commands.length, 2);
  const left = checkReceipt(commands[0]); const right = checkReceipt(commands[1]);
  assert.deepEqual(left.effective_scope, right.effective_scope);
  assert.equal(left.payload_sha256, right.payload_sha256);
  assert.notEqual(left.command_id, right.command_id); assert.notEqual(left.remote_task_id, right.remote_task_id);
  assert.notEqual(commands[0].authorization.signature, commands[1].authorization.signature); f.db.close();
});

test("source substitution and changed payload invalidate the authenticated binding", () => {
  const f = fixture(); sync(f); assert.equal(start(f).ok, true);
  const command = sync(f)[0]; const claims = checkReceipt(command);
  const altered = command.authorization.claims.replace(CALLER.email, "Main");
  assert.notEqual(command.authorization.signature,
    createHmac("sha256", KEY).update(`herdr-task-authorization-v1\n${altered}`).digest("hex"));
  assert.notEqual(claims.payload_sha256, createHash("sha256").update(JSON.stringify({ mode: "research",
    objective: "different command", repo: "fixture-repo" })).digest("hex")); f.db.close();
});

test("receipt write failure atomically rolls back task, command and event creation", () => {
  const f = fixture(); sync(f);
  f.sql.exec("CREATE TRIGGER reject_receipt BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'fixture receipt persistence failure'); END");
  assert.throws(() => start(f), /fixture receipt persistence failure/);
  for (const table of ["remote_tasks", "commands", "task_events"]) {
    assert.equal(f.sql.exec(`SELECT COUNT(*) AS n FROM ${table}`).one().n, 0);
  }
  f.db.close();
});

test("event/audit failure also rolls back a stored receipt and task", () => {
  for (const table of ["task_events", "audit"]) {
    const f = fixture(); sync(f);
    f.sql.exec(`CREATE TRIGGER reject_receipt BEFORE INSERT ON ${table} BEGIN SELECT RAISE(ABORT,'fixture audit failure'); END`);
    assert.throws(() => start(f), /fixture audit failure/);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM remote_tasks").one().n, 0);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM commands").one().n, 0); f.db.close();
  }
});

test("resume requires publisher protocol and binds original mapping to a new child receipt", () => {
  const f = fixture(); sync(f); const started = start(f, "implement"); assert.equal(started.ok, true);
  sync(f); finish(f, started.remote_task_id);
  sync(f, { ...CONFIG, authorization_protocol: undefined });
  assert.deepEqual(f.state.resumeTask(NOW, CALLER, SCOPES, started.remote_task_id, "continue"),
    { ok: false, reason: "authorization_protocol_required" });
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM remote_tasks").one().n, 1);
  sync(f);
  const resumed = f.state.resumeTask(NOW, CALLER, SCOPES, started.remote_task_id, "continue");
  assert.equal(resumed.ok, true); assert.notEqual(resumed.remote_task_id, started.remote_task_id);
  const command = sync(f)[0]; const claims = checkReceipt(command);
  assert.equal(command.op, "resume"); assert.equal(claims.mode, "implement");
  assert.equal(claims.scope, "herdr:task.implement");
  assert.deepEqual(command.payload, { local_task_id: "task_fixture", local_run_id: "run_fixture",
    branch: "remote/fixture", repo: "fixture-repo", mode: "implement", text: "continue" }); f.db.close();
});

test("cancel remains deliverable after publisher downgrade and carries no approval receipt", () => {
  const f = fixture(); sync(f); const started = start(f); sync(f);
  finish(f, started.remote_task_id); f.sql.exec("UPDATE remote_tasks SET state='running'");
  sync(f, { ...CONFIG, authorization_protocol: undefined });
  assert.equal(f.state.cancelTask(NOW, CALLER, SCOPES, started.remote_task_id).ok, true);
  const commands = sync(f, { ...CONFIG, authorization_protocol: undefined });
  assert.equal(commands.length, 1); assert.equal(commands[0].op, "cancel");
  assert.equal(commands[0].authorization, undefined); f.db.close();
});

test("missing signing key fails before task or command creation", () => {
  const f = fixture(); sync(f); f.env.INGEST_KEY = "";
  assert.deepEqual(start(f), { ok: false, reason: "authorization_not_configured" });
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM remote_tasks").one().n, 0);
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM commands").one().n, 0); f.db.close();
});

test("actual Python held→bound→claimed→accepted acks retain receipt/expiry and converge without duplicate audit", () => {
  const { f, command, acks, taskId } = pendingFixture();
  const original = commandRow(f, command);
  sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
  assert.equal(task(f, taskId).local_task_id, "");
  for (let replay = 0; replay < 10; replay++) sync(f, CONFIG, NOW, false, [acks.bound, acks.launch_claimed]);
  const held = commandRow(f, command);
  assert.equal(held.status, "delivering"); assert.equal(held.outcome, "held");
  for (const field of ["payload", "authorization", "expires_at", "lease_until", "attempts"]) assert.equal(held[field], original[field]);
  assert.equal(task(f, taskId).state, "starting");
  assert.equal(task(f, taskId).local_task_id, acks.bound.local_task_id);
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM audit WHERE decision='held'").one().n, 1);
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM task_events WHERE type='command_held'").one().n, 1);
  sync(f, CONFIG, NOW, false, [acks.launched, acks.bound]);
  assert.equal(commandRow(f, command).status, "done"); assert.equal(commandRow(f, command).outcome, "accepted");
  assert.equal(task(f, taskId).state, "running"); assert.equal(cancelCount(f), 0); f.db.close();
});

test("actual Python accepted→held ack order cannot downgrade or erase accepted launch mapping", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.launched]); const acceptedTask = task(f, taskId); const acceptedCommand = commandRow(f, command);
  for (let replay = 0; replay < 10; replay++) sync(f, CONFIG, NOW, false, [acks.accepted_receipt, acks.bound, acks.launch_claimed]);
  assert.deepEqual(task(f, taskId), acceptedTask); assert.deepEqual(commandRow(f, command), acceptedCommand);
  assert.equal(acceptedTask.local_task_id, acks.launched.local_task_id);
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM audit WHERE decision='held'").one().n, 0);
  assert.equal(cancelCount(f), 0); f.db.close();
});

test("actual Python held binding remains cancellable and later accepted ack cannot revive it", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.bound]);
  assert.deepEqual(f.state.cancelTask(NOW, CALLER, SCOPES, taskId), { ok: true, state: "cancelling" });
  const cancellations = sync(f, CONFIG, NOW, true, [acks.launch_claimed, acks.launched]);
  assert.equal(task(f, taskId).state, "cancelling");
  assert.equal(task(f, taskId).local_task_id, acks.bound.local_task_id);
  assert.equal(cancellations.length, 1); assert.equal(cancellations[0].op, "cancel");
  assert.equal(cancellations[0].payload.local_task_id, acks.bound.local_task_id); assert.equal(cancelCount(f), 1);
  sync(f, CONFIG, NOW, false, [{ command_id: cancellations[0].command_id, outcome: "accepted", detail: "fixture stopped" }, acks.bound]);
  assert.equal(task(f, taskId).state, "cancelled"); assert.equal(commandRow(f, command).outcome, "accepted"); f.db.close();
});

test("cancel before an unbound held ack learns its target once bound evidence arrives", () => {
  const { f, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
  assert.equal(f.state.cancelTask(NOW, CALLER, SCOPES, taskId).state, "cancelling"); assert.equal(cancelCount(f), 0);
  sync(f, CONFIG, NOW, false, [acks.bound, acks.bound, acks.launched]);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(cancelCount(f), 1);
  assert.equal(task(f, taskId).local_task_id, acks.bound.local_task_id); f.db.close();
});

test("revocation covers held in-flight source and queues a stop for its known local mapping", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.bound]);
  assert.deepEqual(f.state.pendingCommandSenders(NOW), [{ actor: CALLER.email, client_id: CALLER.client_id, scope: "herdr:task.start" }]);
  const revoked = { revoked: [{ actor: CALLER.email, client_id: CALLER.client_id }], hold: false };
  const cancellations = sync(f, CONFIG, NOW, true, [], revoked);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(cancellations.length, 1);
  assert.equal(cancellations[0].payload.local_task_id, acks.bound.local_task_id);
  assert.equal(commandRow(f, command).outcome, "refused");
  sync(f, CONFIG, NOW, false, [acks.launched, acks.bound], revoked);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(commandRow(f, command).outcome, "late_accepted");
  assert.equal(cancelCount(f), 1); f.db.close();
});

test("revoked unbound hold reopens only stop tracking when later mapping arrives", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
  const revoked = { revoked: [{ actor: CALLER.email, client_id: CALLER.client_id }], hold: false };
  sync(f, CONFIG, NOW, false, [], revoked); assert.equal(task(f, taskId).state, "cancelled");
  const cancellations = sync(f, CONFIG, NOW, true, [acks.launched, acks.bound], revoked);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(task(f, taskId).local_task_id, acks.launched.local_task_id);
  assert.equal(commandRow(f, command).outcome, "late_accepted");
  assert.equal(cancellations.length, 1); assert.equal(cancellations[0].op, "cancel");
  assert.equal(cancelCount(f), 1); f.db.close();
});

test("bound hold expiry queues cancellation without extending receipt or losing target", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.launch_claimed]);
  const before = commandRow(f, command); const expiredAt = NOW + 900_001;
  const cancellations = sync(f, CONFIG, expiredAt);
  assert.equal(cancellations.length, 1); assert.equal(cancellations[0].op, "cancel");
  assert.equal(cancellations[0].payload.local_task_id, acks.launch_claimed.local_task_id);
  assert.equal(task(f, taskId).state, "cancelling");
  assert.equal(commandRow(f, command).expires_at, before.expires_at);
  assert.equal(commandRow(f, command).authorization, before.authorization);
  sync(f, CONFIG, expiredAt + 1, false, [acks.launched, acks.bound]);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(cancelCount(f), 1);
  assert.equal(commandRow(f, command).outcome, "late_accepted"); f.db.close();
});

test("unbound hold expiry creates one durable uncertainty item; late binding is cancel-only", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
  assert.deepEqual(sync(f, CONFIG, NOW + 900_001), []);
  assert.equal(commandRow(f, command).outcome, "held_expired"); assert.equal(task(f, taskId).state, "blocked");
  for (let replay = 0; replay < 10; replay++) assert.deepEqual(sync(f, CONFIG, NOW + 3_600_001 + replay), []);
  assert.equal(task(f, taskId).state, "blocked");
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM task_events WHERE type='launch_outcome_unknown'").one().n, 1);
  const cancellations = sync(f, CONFIG, NOW + 3_600_011, true, [acks.bound, acks.bound]);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(cancellations.length, 1);
  assert.equal(cancellations[0].payload.local_task_id, acks.bound.local_task_id);
  sync(f, CONFIG, NOW + 3_600_012, false, [acks.launched, acks.accepted_receipt]);
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(cancelCount(f), 1); f.db.close();
});

test("changed mapping and partial accepted acks stay held; valid Python result can still resolve", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.bound]);
  sync(f, CONFIG, NOW, false, [{ ...acks.launched, local_task_id: "task_other" }]);
  assert.equal(task(f, taskId).local_task_id, acks.bound.local_task_id);
  assert.equal(commandRow(f, command).status, "delivering"); assert.equal(task(f, taskId).state, "starting");
  const { local_run_id, ...partial } = acks.launched;
  sync(f, CONFIG, NOW, false, [partial]); assert.equal(commandRow(f, command).status, "delivering");
  sync(f, CONFIG, NOW, false, [acks.launched]); assert.equal(task(f, taskId).state, "running");
  assert.equal(cancelCount(f), 0); f.db.close();
});

test("unknown and never-leased ack IDs cannot create a mapping or revive execution", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [{ ...acks.launched, command_id: "cmd_never_issued" }]);
  assert.equal(task(f, taskId).local_task_id, ""); assert.equal(commandRow(f, command).status, "delivering");
  f.sql.exec("UPDATE commands SET status='queued',attempts=0 WHERE command_id=?", command.command_id);
  sync(f, CONFIG, NOW, false, [acks.launched, acks.bound]);
  assert.equal(task(f, taskId).local_task_id, ""); assert.equal(commandRow(f, command).status, "queued");
  assert.equal(cancelCount(f), 0); f.db.close();
});

test("review regression: retired unbound launch retains failed-stop retry and requires conclusive stop", () => {
  const { f, command, acks, taskId } = pendingFixture();
  const receipt = commandRow(f, command);
  sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
  const revoked = { revoked: [{ actor: CALLER.email, client_id: CALLER.client_id }], hold: false };
  sync(f, CONFIG, NOW, false, [], revoked); assert.equal(task(f, taskId).state, "cancelled");
  const stop = sync(f, CONFIG, NOW, true, [acks.launched], revoked)[0];
  assert.equal(task(f, taskId).state, "cancelling"); assert.equal(stop.op, "cancel");
  const retry = sync(f, CONFIG, NOW + 1, true, [{ command_id: stop.command_id, outcome: "failed", detail: "fixture transient stop failure" }], revoked)[0];
  assert.equal(retry.op, "cancel"); assert.notEqual(retry.command_id, stop.command_id);
  assert.equal(retry.payload.local_task_id, acks.launched.local_task_id);
  assert.equal(task(f, taskId).state, "cancelling");
  assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM task_events WHERE type='cancellation_reopened'").one().n, 1);
  assert.equal(commandRow(f, command).authorization, receipt.authorization);
  assert.equal(commandRow(f, command).expires_at, receipt.expires_at);
  sync(f, CONFIG, NOW + 2, false, [{ command_id: retry.command_id, outcome: "accepted", detail: "fixture stopped" }], revoked);
  assert.equal(task(f, taskId).state, "cancelled");
  assert.equal(commandRow(f, command).outcome, "late_accepted"); f.db.close();
});

test("late held and accepted target evidence from failed/timed-out/cancelled rows opens stop tracking only", () => {
  for (const previous of ["failed", "timed_out", "cancelled"]) {
    for (const receiptKind of ["bound", "launched"]) {
      const { f, command, acks, taskId } = pendingFixture();
      const original = commandRow(f, command);
      f.sql.exec("UPDATE commands SET status='done',outcome='expired' WHERE command_id=?", command.command_id);
      f.sql.exec("UPDATE remote_tasks SET state=? WHERE remote_task_id=?", previous, taskId);
      if (previous === "timed_out") f.sql.exec("INSERT INTO task_events(remote_task_id,type,at,detail) VALUES (?,'timed_out',?,'{}')", taskId, NOW);
      const stop = sync(f, CONFIG, NOW, true, [acks[receiptKind]])[0];
      assert.equal(stop.op, "cancel"); assert.equal(task(f, taskId).state, "cancelling");
      assert.equal(commandRow(f, command).expires_at, original.expires_at);
      assert.equal(commandRow(f, command).authorization, original.authorization);
      const recovery = f.sql.exec("SELECT detail FROM task_events WHERE type='cancellation_reopened'").one();
      assert.equal(JSON.parse(recovery.detail).previous_state, previous);
      sync(f, CONFIG, NOW + 1, false, [{ command_id: stop.command_id, outcome: "accepted", detail: "fixture stopped" }]);
      assert.equal(task(f, taskId).state, previous === "timed_out" ? "timed_out" : "cancelled");
      assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM commands WHERE op='cancel' AND status IN ('queued','delivering')").one().n, 0);
      f.db.close();
    }
  }
});

test("lost stop ACK expires into bounded retry while original launch receipt stays fixed", () => {
  const { f, command, acks, taskId } = pendingFixture();
  sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
  const revoked = { revoked: [{ actor: CALLER.email, client_id: CALLER.client_id }], hold: false };
  sync(f, CONFIG, NOW, false, [], revoked);
  const first = sync(f, CONFIG, NOW, true, [acks.launched], revoked)[0];
  const original = commandRow(f, command);
  const afterExpiry = sync(f, CONFIG, NOW + 900_001, true, [], revoked);
  assert.equal(afterExpiry.length, 1); assert.equal(afterExpiry[0].op, "cancel");
  assert.notEqual(afterExpiry[0].command_id, first.command_id);
  assert.equal(task(f, taskId).state, "cancelling");
  // A result from the retired stop cannot certify the timing of a newer
  // stop; its current retry remains pending until its own result arrives.
  sync(f, CONFIG, NOW + 900_002, false, [{ command_id: first.command_id, outcome: "accepted", detail: "old stop response" }], revoked);
  assert.equal(task(f, taskId).state, "cancelling");
  assert.equal(commandRow(f, command).expires_at, original.expires_at);
  assert.equal(commandRow(f, command).authorization, original.authorization);
  sync(f, CONFIG, NOW + 900_003, false, [{ command_id: afterExpiry[0].command_id, outcome: "accepted", detail: "current stop confirmed" }], revoked);
  assert.equal(task(f, taskId).state, "cancelled"); f.db.close();
});

test("failed or lost stops exhaust five retries into one durable recovery item without false completion", () => {
  for (const failure of ["failed", "lost"]) {
    const { f, command, acks, taskId } = pendingFixture();
    sync(f, CONFIG, NOW, false, [acks.accepted_receipt]);
    const revoked = { revoked: [{ actor: CALLER.email, client_id: CALLER.client_id }], hold: false };
    sync(f, CONFIG, NOW, false, [], revoked);
    let stop = sync(f, CONFIG, NOW, true, [acks.launched], revoked)[0];
    const original = commandRow(f, command);
    let now = NOW;
    for (let attempt = 0; attempt < 6; attempt++) {
      now += failure === "lost" ? 900_001 : 1;
      const next = sync(f, CONFIG, now, true, failure === "lost" ? []
        : [{ command_id: stop.command_id, outcome: "failed", detail: "fixture transport failed" }], revoked);
      assert.equal(task(f, taskId).state, "cancelling");
      if (attempt < 5) { assert.equal(next.length, 1); stop = next[0]; assert.equal(stop.op, "cancel"); }
      else assert.deepEqual(next, []);
    }
    assert.equal(cancelCount(f), 6);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM task_events WHERE type='cancel_retry_queued'").one().n, 5);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM task_events WHERE type='cancel_stuck'").one().n, 1);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM commands WHERE op='cancel' AND status IN ('queued','delivering')").one().n, 0);
    for (let repeat = 0; repeat < 10; repeat++) assert.deepEqual(sync(f, CONFIG, now + repeat + 1, true, [acks.launched, acks.bound], revoked), []);
    assert.equal(task(f, taskId).state, "cancelling"); assert.equal(cancelCount(f), 6);
    assert.equal(f.sql.exec("SELECT COUNT(*) AS n FROM task_events WHERE type='cancel_stuck'").one().n, 1);
    assert.equal(commandRow(f, command).expires_at, original.expires_at);
    assert.equal(commandRow(f, command).authorization, original.authorization); f.db.close();
  }
});

let failed = 0;
for (const { name, run } of tests) {
  try { run(); console.log(`PASS ${name}`); }
  catch (error) { failed++; console.error(`FAIL ${name}\n${error.stack}`); }
}
console.log(`${tests.length - failed} passed; ${failed} failed; Cloudflare/OAuth integration not exercised`);
process.exitCode = failed ? 1 : 0;
