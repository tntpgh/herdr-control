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

// Duet <-> Dot coordination (remote-mcp/README.md "Duet<->Dot coordination"): both are FULL
// connections (every scope, tasks included), labelled by the signed
// /admin/peers route, talking through a server-held peer inbox keyed by the
// verified (email, client_id) -- no Mac, no registered pane involved.
const FULL_SCOPES = ["herdr:read", "herdr:message", "herdr:message.owner", "herdr:task.start",
  "herdr:task.implement", "herdr:task.cancel"];
const MODE = { job_class: "research", secrets: "grant" as const, git: "none" as const, writes: [], net_read: [] };
const TASK_CONFIG = {
  mac_enabled: true, authorization_protocol: 1, repos: ["knowledge-base"],
  caps: { max_concurrent: 2, max_per_day: 10, max_minutes: 60 },
  modes: { research: MODE, implement: { ...MODE, job_class: "implement", secrets: "default" as const, git: "push-own-branch" as const } },
};

interface PeerInboxResult {
  me: string | null; peers: string[]; next_after_seq: number;
  messages: { seq: number; message_id: string; from: string; body: string; task_id: string | null }[];
}
interface PeerSendResult { message_id: string; to: string; shared_task_id: string | null }
interface PeersListed { peers: { label: string; actor: string; client_id: string }[] }

const grantClients = async () =>
  ((await (await signedPost("/admin/grants", { op: "list", user: USER })).json()) as GrantsListed).grants.map((g) => g.client_id);

// Connect a new client and (optionally) label it; returns its token and the
// verified client_id the provider issued it (the one grant that is new).
async function connectPeer(clientName: string, label?: string, scopes = FULL_SCOPES) {
  const before = new Set(await grantClients());
  const { access_token } = await oauthToken(scopes, USER, clientName);
  const clientId = (await grantClients()).find((c) => !before.has(c))!;
  if (label) {
    const set = await signedPost("/admin/peers", { op: "set", label, user: USER, client_id: clientId });
    expect(set.status).toBe(200);
  }
  return { token: access_token, clientId };
}

const inbox = async (token: string, after_seq = 0) =>
  callTool<PeerInboxResult>(token, "list_peer_messages", { after_seq });
const note = async (token: string, to: string, body: string, client_msg_id: string, task_id?: string) =>
  callTool<PeerSendResult>(token, "send_peer_message", { to, body, client_msg_id, ...(task_id ? { task_id } : {}) });

describe("Duet <-> Dot peer coordination", () => {
  it("labels are set only by the signed admin route, and only for a live grant holding herdr:message.owner", async () => {
    const duet = await connectPeer("duet");
    const readOnly = await connectPeer("viewer", undefined, ["herdr:read"]);
    const set = (body: Record<string, unknown>) => signedPost("/admin/peers", { op: "set", user: USER, ...body });
    expect((await set({ label: "duet", client_id: "no-such-client" })).status).toBe(404);
    expect((await set({ label: "viewer", client_id: readOnly.clientId })).status).toBe(400); // grant_lacks_scope
    expect((await set({ label: "Bad_Label", client_id: duet.clientId })).status).toBe(400);
    expect((await set({ label: "duet", client_id: duet.clientId })).status).toBe(200);
    const listed: PeersListed = await (await signedPost("/admin/peers", { op: "list" })).json();
    expect(listed.peers).toEqual([{ label: "duet", actor: USER, client_id: duet.clientId, set_at: expect.any(String) }]);
    expect((await inbox(duet.token)).data.me).toBe("duet");
    expect((await signedPost("/admin/peers", { op: "remove", label: "duet" })).status).toBe(200);
    expect((await inbox(duet.token)).data.me).toBeNull();
  });

  it("a Dot -> Duet note lands only in Duet's inbox, sanitized, with no Mac ever connected", async () => {
    const duet = await connectPeer("duet", "duet");
    const dot = await connectPeer("dot", "dot");
    const other = await connectPeer("chat"); // same email, unlabelled

    const sent = await note(dot.token, "duet", "pick up [KB-12] and ping @owner", "dot-1");
    expect(sent.isError).toBe(false);
    expect(sent.data.to).toBe("duet");

    const got = await inbox(duet.token);
    expect([got.data.me, got.data.peers]).toEqual(["duet", ["dot"]]);
    expect(got.data.messages).toHaveLength(1);
    const m = got.data.messages[0]!;
    expect([m.message_id, m.from, m.task_id]).toEqual([sent.data.message_id, "dot", null]);
    expect(m.body).not.toContain("[");
    expect(m.body).not.toContain("@owner");
    expect((await inbox(duet.token, got.data.next_after_seq)).data.messages).toEqual([]);

    expect((await inbox(dot.token)).data.messages).toEqual([]);
    const theirs = await inbox(other.token);
    expect([theirs.data.me, theirs.data.messages]).toEqual([null, []]);
  });

  it("refuses an unlabelled sender, a self-send and an unknown peer; a repeated client_msg_id returns the original", async () => {
    const duet = await connectPeer("duet", "duet");
    await connectPeer("dot", "dot");
    const other = await connectPeer("chat");
    expect((await note(other.token, "duet", "hi", "o-1")).data.error).toBe("sender_not_labelled");
    expect((await note(duet.token, "duet", "hi", "d-self")).data.error).toBe("peer_is_self");
    expect((await note(duet.token, "nobody", "hi", "d-none")).data.error).toBe("peer_not_found");

    const first = await note(duet.token, "dot", "first", "d-1");
    const retry = await note(duet.token, "dot", "a different body -- must not matter", "d-1");
    expect(retry.data).toEqual(first.data);
    const { audit } = (await (await signedSync(syncBody())).json()) as { audit: { tool: string; decision: string; reason: string }[] };
    const decisions = audit.filter((a) => a.tool === "send_peer_message").map((a) => `${a.decision}:${a.reason}`);
    expect(decisions).toEqual(["refused:sender_not_labelled", "refused:peer_is_self", "refused:peer_not_found", "queued:"]);
  });

  it("keeps the owner-route rate limit: the 11th note in a minute is refused", async () => {
    const duet = await connectPeer("duet", "duet");
    await connectPeer("dot", "dot");
    const outcomes: string[] = [];
    for (let i = 0; i < 11; i++) outcomes.push((await note(duet.token, "dot", `n${i}`, `rl-${i}`)).data.error ?? "ok");
    expect(outcomes).toEqual([...Array(10).fill("ok"), "rate_limited"]);
  });

  it("peer.message_ready wakes only the recipient's event feed", async () => {
    const duet = await connectPeer("duet", "duet");
    const dot = await connectPeer("dot", "dot");
    const sent = await note(dot.token, "duet", "your turn", "dot-ev");
    const events = async (token: string) =>
      (await callTool<{ events: { type: string; subject: { kind: string; id: string } | null }[] }>(token, "list_events", { since_cursor: 0 }))
        .data.events.filter((e) => e.type === "peer.message_ready");
    expect(await events(duet.token)).toEqual([
      expect.objectContaining({ type: "peer.message_ready", subject: { kind: "peer_message", id: sent.data.message_id } })]);
    expect(await events(dot.token)).toEqual([]);
  });

  it("a task is the starter's until shared; sharing grants read, never cancel", async () => {
    await signedSync(syncBody({ snapshot: snapshot({ task_config: TASK_CONFIG }) }));
    const duet = await connectPeer("duet", "duet");
    const dot = await connectPeer("dot", "dot");
    const started = await callTool<{ task_id: string; state: string }>(dot.token, "start_task",
      { repo: "knowledge-base", mode: "research", objective: "survey the KB" });
    expect(started.isError).toBe(false);
    const taskId = started.data.task_id;

    expect((await callTool(duet.token, "get_task_answer", { task_id: taskId })).data.error).toBe("not_found");
    // Duet cannot share what it did not start.
    expect((await note(duet.token, "dot", "here", "d-share", taskId)).data.error).toBe("not_your_task");

    const shared = await note(dot.token, "duet", "take a look", "dot-share", taskId);
    expect(shared.data.shared_task_id).toBe(taskId);
    expect((await inbox(duet.token)).data.messages[0]?.task_id).toBe(taskId);
    const answer = await callTool<{ task_id: string; state: string }>(duet.token, "get_task_answer", { task_id: taskId });
    expect([answer.isError, answer.data.task_id, answer.data.state]).toEqual([false, taskId, "queued"]);
    expect((await callTool(duet.token, "cancel_task", { task_id: taskId })).data.error).toBe("not_your_task");
    expect((await callTool(dot.token, "get_task_answer", { task_id: taskId })).isError).toBe(false);
  });

  it("an owner exchange's status and reply belong to the sending connection, not the whole email", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const duet = await connectPeer("duet");
    const dot = await connectPeer("dot");
    const id = await hello(duet.token, "cm-duet-owner");
    expect((await callTool(duet.token, "get_owner_message_status", { exchange_id: id })).isError).toBe(false);
    expect((await callTool(dot.token, "get_owner_message_status", { exchange_id: id })).data.error).toBe("not_found");
    await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: id, outcome: "delivered" }] }));
    await signedSync(syncBody({
      snapshot: ownerSnapshot(),
      owner_replies: [{ exchange_id: id, owner_label: "conductor", body: "ack", responded_at: new Date().toISOString(),
        artifact_revision: "rev1", session: "w1:p1" }],
    }));
    expect((await callTool(duet.token, "get_owner_reply", { exchange_id: id })).isError).toBe(false);
    expect((await callTool(dot.token, "get_owner_reply", { exchange_id: id })).data.error).toBe("not_found");
  });
});
