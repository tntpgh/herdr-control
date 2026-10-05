import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { ConsumerPosition, HerdrState } from "../src/state";
import type { Env } from "../src/types";
import { BASE, callTool, oauthToken, signedSync, syncBody } from "./helpers";

const e = env as unknown as Env;
let fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
const caller = { email: "tnt@teamthurber.com", client_id: "zero-client", client_name: "Zero" };
const scopes = ["herdr:read"];
beforeEach(async () => {
  await reset();
  fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
});

// Seed a mixed-visibility feed through real SQLite storage, including another
// sender's private metadata. Consumer cursors are global scan positions, not
// permission to retrieve that sender's events.
async function seedEvents() {
  await runInDurableObject(fleet, (_o: HerdrState, state) => {
    for (let i = 1; i <= 3; i++) {
      state.storage.sql.exec(`INSERT INTO task_events
        (remote_task_id, type, at, visibility, sender_actor, sender_client)
        VALUES ('', 'owner.reply_ready', ?, 'owner_private', ?, ?)`, Date.now(),
        i === 2 ? "another@teamthurber.com" : caller.email, caller.client_id);
    }
  });
}

async function row() {
  return runInDurableObject(fleet, (_o: HerdrState, state) =>
    state.storage.sql.exec(`SELECT * FROM event_consumers`).toArray());
}

describe("durable consumer positions", () => {
  it("two conditional writers race: one wins, the loser changes nothing", async () => {
    await seedEvents();
    const start = await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero");
    const results = await Promise.all([
      fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 1, start.lease_epoch!),
      fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 3, start.lease_epoch!),
    ]);
    expect(results.map((r) => r.result).sort()).toEqual(["committed_cursor_mismatch", "ok"]);
    const winner = results.find((r) => r.result === "ok")!;
    expect((await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero")).committed_cursor)
      .toBe(winner.committed_cursor);
    const before = await row();
    expect((await fleet.commitConsumerPosition(Date.now() + 1000, caller, scopes, "zero", 0, 3, start.lease_epoch!)).result)
      .toBe("committed_cursor_mismatch");
    expect(await row()).toEqual(before);
  });

  it("rejects a stale epoch without changing checkpoint or diagnostics", async () => {
    await seedEvents();
    const start = await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero");
    const before = await row();
    expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 1, start.lease_epoch! - 1)).result)
      .toBe("lease_epoch_mismatch");
    expect(await row()).toEqual(before);
  });

  it("rejects backwards, beyond-watermark and invalid commits; equal cursor is a read-only no-op", async () => {
    await seedEvents();
    const start = await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero");
    expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 2, start.lease_epoch!)).result).toBe("ok");
    const before = await row();
    for (const [cursor, result] of [[1, "cursor_backwards"], [4, "cursor_past_latest"], [-1, "invalid_arguments"],
      [1.5, "invalid_arguments"], [Number.MAX_SAFE_INTEGER + 1, "invalid_arguments"]] as const) {
      expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 2, cursor, start.lease_epoch!)).result)
        .toBe(result);
      expect(await row()).toEqual(before);
    }
    expect((await fleet.commitConsumerPosition(Date.now() + 1000, caller, scopes, "zero", 2, 2, start.lease_epoch!)).result)
      .toBe("ok");
    expect(await row()).toEqual(before);
  });

  it("same consumer name is isolated by tenant and original sender/client", async () => {
    await seedEvents();
    const mine = await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero");
    await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 3, mine.lease_epoch!);
    for (const other of [{ ...caller, email: "other@teamthurber.com" }, { ...caller, client_id: "other-client" }]) {
      expect((await fleet.commitConsumerPosition(Date.now(), other, scopes, "zero", 3, 3, mine.lease_epoch!)).result)
        .toBe("consumer_not_found");
      const theirs = await fleet.getConsumerPosition(Date.now(), other, scopes, "zero");
      expect(theirs.committed_cursor).toBe(0);
      expect((await fleet.commitConsumerPosition(Date.now(), other, scopes, "zero", 3, 3, theirs.lease_epoch!)).result)
        .toBe("committed_cursor_mismatch");
    }
    expect((await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero")).committed_cursor).toBe(3);
    const visible = await fleet.listEvents(0, null, caller, 100);
    expect(visible.events.map((event) => event.cursor)).toEqual([1, 3]);
    // Exact identity columns, not an opaque 32-bit scope hash, own the row.
    expect((await row()).map((r) => r.committed_cursor).sort()).toEqual([0, 0, 3]);
  });

  it("scope changes are refused without rebinding; scope order and client display name do not matter", async () => {
    await seedEvents();
    const originalScopes = ["herdr:read", "herdr:message.owner"];
    const start = await fleet.getConsumerPosition(Date.now(), caller, originalScopes, "zero");
    const before = await row();
    expect((await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero")).result).toBe("cursor_scope_mismatch");
    expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 1, start.lease_epoch!)).result)
      .toBe("cursor_scope_mismatch");
    expect(await row()).toEqual(before);
    expect((await fleet.getConsumerPosition(Date.now(), { ...caller, client_name: "renamed" },
      [...originalScopes].reverse(), "zero")).result).toBe("ok");
    expect(await row()).toEqual(before);
  });

  it("zero and nonzero checkpoints below a non-prefix pruning floor return an explicit gap", async () => {
    await seedEvents();
    const start = await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero");
    await fleet.getConsumerPosition(Date.now(), caller, scopes, "unread");
    await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 1, start.lease_epoch!);
    await runInDurableObject(fleet, (_o: HerdrState, state) => {
      state.storage.sql.exec(`INSERT OR REPLACE INTO kv (k,v) VALUES ('replay_floor_cursor','2')`);
      state.storage.sql.exec(`DELETE FROM task_events WHERE cursor=2`);
    });
    const before = await row();
    for (const id of ["zero", "unread", "new-after-prune"]) {
      const gap = await fleet.getConsumerPosition(Date.now(), caller, scopes, id);
      expect(gap).toMatchObject({ result: "cursor_pruned", latest_cursor: 3, replay_floor_cursor: 2 });
    }
    const afterCreation = await row();
    expect(afterCreation.filter((r) => r.consumer_id !== "new-after-prune")).toEqual(before);
    expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 1, 3, start.lease_epoch!)).result)
      .toBe("cursor_pruned");
    expect(await row()).toEqual(afterCreation);
  });

  it("pruning all retained rows preserves the watermark and boundary checkpoint", async () => {
    await seedEvents();
    const start = await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero");
    await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 3, start.lease_epoch!);
    await runInDurableObject(fleet, (_o: HerdrState, state) => {
      state.storage.sql.exec(`INSERT OR REPLACE INTO kv (k,v) VALUES ('replay_floor_cursor','3')`);
      state.storage.sql.exec(`DELETE FROM task_events`);
    });
    expect(await fleet.getConsumerPosition(Date.now(), caller, scopes, "zero"))
      .toMatchObject({ result: "ok", committed_cursor: 3, latest_cursor: 3, replay_floor_cursor: 3 });
    expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 3, 4, start.lease_epoch!)).result)
      .toBe("cursor_past_latest");
    expect((await fleet.listEvents(3, null, caller, 100)).latest_cursor).toBe(3);
  });

  it("requires herdr:read and refuses missing consumers without creating or acknowledging one", async () => {
    await seedEvents();
    expect((await fleet.getConsumerPosition(Date.now(), caller, [], "zero")).result).toBe("insufficient_scope");
    expect((await fleet.commitConsumerPosition(Date.now(), caller, scopes, "zero", 0, 1, 1)).result).toBe("consumer_not_found");
    expect(await row()).toEqual([]);
  });

  it("MCP read/restart/replay never acknowledges; commit persists the fully handled prefix", async () => {
    await signedSync(syncBody());
    await seedEvents();
    const { access_token } = await oauthToken(scopes);
    const start = await callTool<ConsumerPosition>(access_token, "get_consumer_position", { consumer_id: "zero" });
    expect(start.isError).toBe(false);
    expect(start.data.committed_cursor).toBe(0);
    await callTool(access_token, "list_events", { since_cursor: 0 });
    expect((await callTool<ConsumerPosition>(access_token, "get_consumer_position", { consumer_id: "zero" })).data.committed_cursor).toBe(0);
    const commit = await callTool<ConsumerPosition>(access_token, "commit_consumer_position", {
      consumer_id: "zero", expected_committed_cursor: 0, new_cursor: 1, lease_epoch: start.data.lease_epoch,
    });
    expect(commit.isError).toBe(false);
    expect(commit.data).toMatchObject({ result: "ok", committed_cursor: 1 });
    // Every MCP call constructs a fresh server. A fresh call resumes durable state.
    expect((await callTool<ConsumerPosition>(access_token, "get_consumer_position", { consumer_id: "zero" })).data.committed_cursor).toBe(1);
    const stale = await callTool<ConsumerPosition>(access_token, "commit_consumer_position", {
      consumer_id: "zero", expected_committed_cursor: 0, new_cursor: 2, lease_epoch: start.data.lease_epoch,
    });
    expect(stale.isError).toBe(true);
    expect(stale.data.error).toBe("committed_cursor_mismatch");
  });

  it("does not list consumer tools for a token without read scope", async () => {
    const { access_token } = await oauthToken(["herdr:message"]);
    const response = await SELF.fetch(`${BASE}/mcp`, {
      method: "POST", headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    });
    const body = await response.json() as { result: { tools: { name: string }[] } };
    expect(body.result.tools.map((tool) => tool.name)).not.toContain("commit_consumer_position");
    expect(body.result.tools.map((tool) => tool.name)).not.toContain("get_consumer_position");
  });
});
