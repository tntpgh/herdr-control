// Per-client identity for the two allow-listed apps, Dot (ChatGPT) and Duet
// (Claude.ai). Each connects with its Client ID Metadata Document URL as its
// OAuth client_id, so the Worker's caller.client_id -- derived from the
// verified resource token, never from the request body or a self-declared
// client_name -- names the app itself, and policy.ts CLIENT_GRANTS gives it a
// label (dot/duet). Every note carries that verified id and label to the Mac;
// revocation, status and replies are per connection, not per email.
import { reset } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { OwnerMessageRecord } from "../src/state";
import { callTool, DOT, DUET, oauthToken, signedPost, signedSync, snapshot, syncBody } from "./helpers";

const ownerSnapshot = () => snapshot({ owners: [{ label: "firstmate", live: true }] });

interface OwnerOutboxRow {
  exchange_id: string; owner_label: string; body: string;
  sender: string; sender_client: string; client_name: string; sender_label: string; kind: string;
}
interface SyncReply { owner_outbox: OwnerOutboxRow[] }
const syncJson = async (r: Response): Promise<SyncReply> => r.json();

interface GrantsListed { grants: { grant_id: string; client_id: string; scope: string[] }[] }
const USER = "tnt@teamthurber.com";
const NOTE_SCOPES = ["fm:read", "fm:request", "fm:peer"];

beforeEach(() => reset());

async function connect(client: "dot" | "duet", scopes = NOTE_SCOPES) {
  const { access_token, scope } = await oauthToken(scopes, USER, client);
  expect(scope.split(" ").sort()).toEqual([...scopes].sort());
  return access_token;
}

async function hello(token: string, clientMsgId: string) {
  const sent = await callTool<{ exchange_id: string; state: string }>(token, "send_owner_message",
    { owner_label: "firstmate", body: "hello", client_msg_id: clientMsgId });
  expect(sent.isError).toBe(false);
  return sent.data.exchange_id;
}

describe("per-client identity", () => {
  it("each note is attributed to its OWN verified client and the Worker's label for it", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const dot = await connect("dot");
    const duet = await connect("duet");
    const fromDot = await hello(dot, "cm-dot");
    const fromDuet = await hello(duet, "cm-duet");

    const { owner_outbox } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    // Same single allowed account; only the verified client tells them apart.
    expect(owner_outbox.every((m) => m.sender === USER && m.kind === "message")).toBe(true);
    const byId = new Map(owner_outbox.map((m) => [m.exchange_id, m]));
    expect([byId.get(fromDot)?.sender_client, byId.get(fromDot)?.sender_label]).toEqual([DOT, "dot"]);
    expect([byId.get(fromDuet)?.sender_client, byId.get(fromDuet)?.sender_label]).toEqual([DUET, "duet"]);
  });

  it("a duplicate client_msg_id returns the ORIGINAL exchange, never a second queue entry", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const token = await connect("duet");
    const first = await callTool<{ exchange_id: string; state: string }>(token, "send_owner_message",
      { owner_label: "firstmate", body: "first body", client_msg_id: "dup-1" });
    const retry = await callTool<{ exchange_id: string; state: string }>(token, "send_owner_message",
      { owner_label: "firstmate", body: "a different body -- must not matter", client_msg_id: "dup-1" });
    expect(retry.data).toEqual(first.data);
    const { owner_outbox } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(owner_outbox).toHaveLength(1);
  });

  it("delivery and reply times are recorded", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const token = await connect("dot");
    const id = await hello(token, "cm-times");
    await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: id, outcome: "delivered" }] }));

    const status = await callTool<{ owner_message: OwnerMessageRecord }>(token, "get_owner_message_status", { exchange_id: id });
    expect([status.data.owner_message.status, status.data.owner_message.kind]).toEqual(["delivered", "message"]);
    expect(status.data.owner_message.delivered_at).not.toBeNull();

    await signedSync(syncBody({
      snapshot: ownerSnapshot(),
      owner_replies: [{ exchange_id: id, owner_label: "firstmate", body: "ack", responded_at: new Date().toISOString(),
        artifact_revision: "rev1", session: "w1:p1" }],
    }));
    const reply = await callTool<{ reply: { responded_at: string } }>(token, "get_owner_reply", { exchange_id: id });
    expect(reply.isError).toBe(false);
    expect(reply.data.reply.responded_at).toBeTruthy();
  });

  it("revocation is per-grant: revoking Dot's credential cancels only Dot's queued note", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const dot = await connect("dot");
    const listed: GrantsListed = await (await signedPost("/admin/grants", { op: "list", user: USER })).json();
    expect(listed.grants.map((g) => g.client_id)).toEqual([DOT]);
    const duet = await connect("duet");

    const goneId = await hello(dot, "cm-gone");
    const keptId = await hello(duet, "cm-kept");
    expect((await signedPost("/admin/grants", { op: "revoke", user: USER, grant_id: listed.grants[0]!.grant_id })).status).toBe(200);

    const { owner_outbox } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(owner_outbox.map((m) => m.exchange_id)).toEqual([keptId]);
    expect(owner_outbox.map((m) => m.exchange_id)).not.toContain(goneId);
  });

  it("an owner exchange's status and reply belong to the sending connection, not the whole email", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const duet = await connect("duet");
    const dot = await connect("dot");
    const id = await hello(duet, "cm-duet-owner");
    expect((await callTool(duet, "get_owner_message_status", { exchange_id: id })).isError).toBe(false);
    expect((await callTool(dot, "get_owner_message_status", { exchange_id: id })).data.error).toBe("not_found");
    await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: id, outcome: "delivered" }] }));
    await signedSync(syncBody({
      snapshot: ownerSnapshot(),
      owner_replies: [{ exchange_id: id, owner_label: "firstmate", body: "ack", responded_at: new Date().toISOString(),
        artifact_revision: "rev1", session: "w1:p1" }],
    }));
    expect((await callTool(duet, "get_owner_reply", { exchange_id: id })).isError).toBe(false);
    expect((await callTool(dot, "get_owner_reply", { exchange_id: id })).data.error).toBe("not_found");
  });
});

// Duet <-> Dot coordination (remote-mcp/README.md "Duet<->Dot coordination"):
// labelled by the signed /admin/peers route, talking through a server-held
// peer inbox keyed by the verified (email, client_id) -- no Mac involved.
interface PeerInboxResult {
  me: string | null; peers: string[]; next_after_seq: number;
  messages: { seq: number; message_id: string; from: string; body: string; task_id: string | null; created_at: string }[];
}
interface PeerSendResult { message_id: string; to: string }
interface PeersListed { peers: { label: string; actor: string; client_id: string }[] }

async function label(client: "dot" | "duet") {
  const set = await signedPost("/admin/peers", { op: "set", label: client, user: USER, client_id: client === "dot" ? DOT : DUET });
  expect(set.status).toBe(200);
}

const inbox = async (token: string, after_seq = 0) =>
  callTool<PeerInboxResult>(token, "list_peer_messages", { after_seq });
const note = async (token: string, to: string, body: string, client_msg_id: string) =>
  callTool<PeerSendResult>(token, "send_peer_message", { to, body, client_msg_id });

describe("Duet <-> Dot peer coordination", () => {
  it("labels are set only by the signed admin route, and only for a live grant holding fm:peer", async () => {
    const readOnly = await connect("dot", ["fm:read"]);
    const duet = await connect("duet");
    const set = (body: Record<string, unknown>) => signedPost("/admin/peers", { op: "set", user: USER, ...body });
    expect((await set({ label: "duet", client_id: "https://nowhere.example/client.json" })).status).toBe(404);
    expect((await set({ label: "dot", client_id: DOT })).status).toBe(400); // grant_lacks_scope
    expect((await set({ label: "Bad_Label", client_id: DUET })).status).toBe(400);
    expect((await set({ label: "duet", client_id: DUET })).status).toBe(200);
    const listed: PeersListed = await (await signedPost("/admin/peers", { op: "list" })).json();
    expect(listed.peers).toEqual([{ label: "duet", actor: USER, client_id: DUET, set_at: expect.any(String) }]);
    expect((await inbox(duet)).data.me).toBe("duet");
    expect((await callTool(readOnly, "list_peer_messages", {})).isError).toBe(true);
    expect((await signedPost("/admin/peers", { op: "remove", label: "duet" })).status).toBe(200);
    expect((await inbox(duet)).data.me).toBeNull();
  });

  it("a Dot -> Duet note lands only in Duet's inbox, sanitized, with no Mac ever connected", async () => {
    const duet = await connect("duet");
    const dot = await connect("dot");
    await label("duet");
    await label("dot");

    const sent = await note(dot, "duet", "pick up [KB-12] and ping @owner", "dot-1");
    expect(sent.isError).toBe(false);
    expect(sent.data.to).toBe("duet");

    const got = await inbox(duet);
    expect([got.data.me, got.data.peers]).toEqual(["duet", ["dot"]]);
    expect(got.data.messages).toHaveLength(1);
    const m = got.data.messages[0]!;
    expect([m.message_id, m.from]).toEqual([sent.data.message_id, "dot"]);
    expect(m.body).not.toContain("[");
    expect(m.body).not.toContain("@owner");
    expect((await inbox(duet, got.data.next_after_seq)).data.messages).toEqual([]);
    expect((await inbox(dot)).data.messages).toEqual([]);
  });

  it("refuses an unlabelled sender, a self-send and an unknown peer; a repeated client_msg_id returns the original", async () => {
    const duet = await connect("duet");
    const dot = await connect("dot");
    await label("duet");
    expect((await note(dot, "duet", "hi", "o-1")).data.error).toBe("sender_not_labelled");
    await label("dot");
    expect((await note(duet, "duet", "hi", "d-self")).data.error).toBe("peer_is_self");
    expect((await note(duet, "nobody", "hi", "d-none")).data.error).toBe("peer_not_found");

    const first = await note(duet, "dot", "first", "d-1");
    const retry = await note(duet, "dot", "a different body -- must not matter", "d-1");
    expect(retry.data).toEqual(first.data);
    const { audit } = (await (await signedSync(syncBody())).json()) as { audit: { tool: string; decision: string; reason: string; client_label: string }[] };
    const decisions = audit.filter((a) => a.tool === "send_peer_message").map((a) => `${a.client_label}:${a.decision}:${a.reason}`);
    expect(decisions).toEqual(["dot:refused:sender_not_labelled", "duet:refused:peer_is_self", "duet:refused:peer_not_found",
      "duet:queued:", "duet:duplicate:"]);
  });

  it("keeps the owner-route rate limit: the 11th note in a minute is refused", async () => {
    const duet = await connect("duet");
    await connect("dot");
    await label("duet");
    await label("dot");
    const outcomes: string[] = [];
    for (let i = 0; i < 11; i++) outcomes.push((await note(duet, "dot", `n${i}`, `rl-${i}`)).data.error ?? "ok");
    expect(outcomes).toEqual([...Array(10).fill("ok"), "rate_limited"]);
  });

  it("peer.message_ready wakes only the recipient's event feed", async () => {
    const duet = await connect("duet");
    const dot = await connect("dot");
    await label("duet");
    await label("dot");
    const sent = await note(dot, "duet", "your turn", "dot-ev");
    const events = async (token: string) =>
      (await callTool<{ events: { type: string; subject: { kind: string; id: string } | null }[] }>(token, "list_events", { since_cursor: 0 }))
        .data.events.filter((e) => e.type === "peer.message_ready");
    expect(await events(duet)).toEqual([
      expect.objectContaining({ type: "peer.message_ready", subject: { kind: "peer_message", id: sent.data.message_id } })]);
    expect(await events(dot)).toEqual([]);
  });
});
