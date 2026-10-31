// Duet/Zero per-client identity (SPEC: .handoffs/DUET-IDENTITY-SPEC-20261031.md,
// T first-hand YES 2026-10-31; same rules applied to a second client "zero").
// The existing OAuth/DCR machinery already does almost everything the SPEC
// asks for -- each connected client gets its own provider-issued client_id,
// the Worker derives `caller.client_id` from the verified resource token
// (mcp.ts's apiHandler), never from request body or the self-declared
// client_name a DCR registration can claim to be anything, and a scope
// simply never requested (herdr:task.*) is never admitted (mcp.ts only
// registers a tool when the token's own scopes include it). The ONE real
// gap was state.ts's dueOwners SELECT, which read sender_client_name (the
// SPOOFABLE client-declared name) but never sender_client (the VERIFIED
// provider client_id) into owner_outbox -- so two connections under the
// same email were indistinguishable downstream. Fixed there; this file
// proves the whole chain end to end for two independently-issued clients.
import { reset } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { OwnerMessageRecord } from "../src/state";
import { callTool, oauthToken, signedPost, signedSync, snapshot, syncBody } from "./helpers";

const ownerSnapshot = () => snapshot({ owners: [{ label: "conductor", live: true }] });

interface OwnerOutboxRow {
  exchange_id: string; owner_label: string; body: string;
  sender: string; sender_client: string; client_name: string;
}
interface SyncReply { owner_outbox: OwnerOutboxRow[] }
const syncJson = async (r: Response): Promise<SyncReply> => r.json();

interface GrantsListed { grants: { grant_id: string; client_id: string; scope: string[] }[] }
const USER = "tnt@teamthurber.com";

// Peer-inbox only, exactly as the SPEC requires: read assigned (get_owner_
// message_status), reply (send_owner_message), ack/report-blocked (same
// tool -- the body is free text, never typed/auto-approved either way).
// Deliberately NEVER herdr:task.start/.implement/.cancel.
const PEER_INBOX_SCOPES = ["herdr:read", "herdr:message.owner"];

beforeEach(() => reset());

async function connect(clientName: string) {
  const { access_token, scope } = await oauthToken(PEER_INBOX_SCOPES, USER, clientName);
  expect(scope.split(" ").sort()).toEqual([...PEER_INBOX_SCOPES].sort());
  return access_token;
}

async function hello(token: string, clientMsgId: string) {
  const sent = await callTool<{ exchange_id: string; state: string }>(token, "send_owner_message",
    { owner_label: "conductor", body: "hello", client_msg_id: clientMsgId });
  expect(sent.isError).toBe(false);
  return sent.data.exchange_id;
}

describe.each(["duet", "zero"])("%s: per-client identity (DUET-IDENTITY-SPEC-20261031)", (name) => {
  it("a hello is attributed to its OWN verified client, distinct from two other connections under the same email", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const root = await connect("root");
    const chat = await connect("chat");
    const token = await connect(name);

    await hello(root, "cm-root");
    await hello(chat, "cm-chat");
    const id = await hello(token, `cm-${name}`);

    const { owner_outbox } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(owner_outbox).toHaveLength(3);
    // Every sender is the SAME single allowed account (one owner, SPEC's
    // "server derives the sender from the authenticating credential" --
    // never from anything client-supplied): only sender_client (the
    // verified, provider-issued OAuth client_id) tells the three apart.
    expect(owner_outbox.every((m) => m.sender === USER)).toBe(true);
    const distinctClients = new Set(owner_outbox.map((m) => m.sender_client));
    expect(distinctClients.size).toBe(3);
    const mine = owner_outbox.find((m) => m.exchange_id === id);
    expect(mine?.sender_client).toBeTruthy();
    const others = owner_outbox.filter((m) => m.exchange_id !== id);
    expect(others.some((m) => m.sender_client === mine?.sender_client)).toBe(false);
  });

  it("a duplicate client_message_id is rejected: the ORIGINAL exchange, never a second queue entry", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const token = await connect(name);
    const first = await callTool<{ exchange_id: string; state: string }>(token, "send_owner_message",
      { owner_label: "conductor", body: "first body", client_msg_id: "dup-1" });
    const retry = await callTool<{ exchange_id: string; state: string }>(token, "send_owner_message",
      { owner_label: "conductor", body: "a different body -- must not matter", client_msg_id: "dup-1" });
    expect(retry.data).toEqual(first.data);
    const { owner_outbox } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(owner_outbox).toHaveLength(1);
  });

  it("task.start is denied: a peer-inbox token never admits task.*", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const token = await connect(name);
    const r = await callTool(token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    expect(r.isError).toBe(true);
  });

  it("delivery and reply times are recorded", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const token = await connect(name);
    const id = await hello(token, `cm-times-${name}`);
    await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: id, outcome: "delivered" }] }));

    const status = await callTool<{ owner_message: OwnerMessageRecord }>(token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("delivered");
    expect(status.data.owner_message.delivered_at).not.toBeNull();

    await signedSync(syncBody({
      snapshot: ownerSnapshot(),
      owner_replies: [{ exchange_id: id, owner_label: "conductor", body: "ack", responded_at: new Date().toISOString(),
        artifact_revision: "rev1", session: "w1:p1" }],
    }));
    const reply = await callTool<{ reply: { responded_at: string } }>(token, "get_owner_reply", { exchange_id: id });
    expect(reply.isError).toBe(false);
    expect(reply.data.reply.responded_at).toBeTruthy();
  });

  it("revocation is per-grant: revoking THIS client's credential cancels only its own queued message", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    // connect() first: beforeEach's reset() guarantees this is the only
    // grant for USER yet, so the listed grant_id is unambiguously mine --
    // same capture-before-the-second-connection shape as flow.test.ts's
    // own "revokes one connection, leaving the other working" test.
    const mine = await connect(name);
    const mineListed: GrantsListed = await (await signedPost("/admin/grants", { op: "list", user: USER })).json();
    expect(mineListed.grants).toHaveLength(1);
    const mineGrantId = mineListed.grants[0]!.grant_id;
    const other = await connect(name === "duet" ? "zero" : "duet");

    const goneId = await hello(mine, "cm-gone");
    const keptId = await hello(other, "cm-kept");

    const res = await signedPost("/admin/grants", { op: "revoke", user: USER, grant_id: mineGrantId });
    expect(res.status).toBe(200);

    const { owner_outbox } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    const ids = owner_outbox.map((m) => m.exchange_id);
    expect(ids).toContain(keptId);
    expect(ids).not.toContain(goneId);
  });
});
