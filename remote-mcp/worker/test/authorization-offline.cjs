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
function sync(f, config = CONFIG, now = NOW, lease = true, acks = []) {
  const result = f.state.sync(now, crypto.randomUUID(), JSON.stringify(body(config, lease, acks)), GATE, GATE, GATE);
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

let failed = 0;
for (const { name, run } of tests) {
  try { run(); console.log(`PASS ${name}`); }
  catch (error) { failed++; console.error(`FAIL ${name}\n${error.stack}`); }
}
console.log(`${tests.length - failed} passed; ${failed} failed; Cloudflare/OAuth integration not exercised`);
process.exitCode = failed ? 1 : 0;
