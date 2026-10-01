// Pure policy: connection state, message-target resolution, message text
// rules, rate limits. No I/O, so every rule here is unit-tested directly.
import type { Snapshot, TaskRow } from "./types";

export type ConnectionState = "connected" | "degraded" | "disconnected" | "never_connected";

export interface Connection {
  state: ConnectionState;
  last_sync_at: string | null;
  age_seconds: number | null;
  stale_after_seconds: number;
  herdr_live: boolean | null;
  hub_rev: string | null;
  note: string;
}

export function connection(snapshot: Snapshot | null, lastSyncMs: number | null, nowMs: number, staleAfterS: number): Connection {
  if (!snapshot || lastSyncMs === null) {
    return {
      state: "never_connected", last_sync_at: null, age_seconds: null, stale_after_seconds: staleAfterS,
      herdr_live: null, hub_rev: null, note: "The Mac publisher has never synced. No herdr data is available.",
    };
  }
  const age = Math.max(0, Math.round((nowMs - lastSyncMs) / 1000));
  const base = {
    last_sync_at: new Date(lastSyncMs).toISOString(), age_seconds: age, stale_after_seconds: staleAfterS,
    herdr_live: snapshot.hub.live_connected, hub_rev: snapshot.hub.rev,
  };
  if (age > staleAfterS) {
    return { ...base, state: "disconnected",
      note: `No sync from the Mac for ${age}s. Everything below is the last known state as of last_sync_at, not live. Messages are refused until it reconnects.` };
  }
  if (!snapshot.hub.live_connected) {
    return { ...base, state: "degraded",
      note: "The Mac is syncing but the hub has lost its live herdr connection; task states are registry-only and may lag." };
  }
  return { ...base, state: "connected", note: "Live." };
}

// A task may receive a message only while a live agent is working it.
export const MESSAGEABLE_STATES: Record<string, true> = {
  starting: true, running: true, blocked: true, stalled: true, ready_review: true,
};

export function messageable(task: TaskRow): boolean {
  return MESSAGEABLE_STATES[task.state] === true && task.agent_live && !!task.pane_id && !!task.agent_id;
}

export type Resolution =
  | { ok: true; task: TaskRow }
  | { ok: false; reason: string; candidates?: string[] };

// target = a task_id, an agent_id, or a task label (the "named agent").
// Exactly one match, and it must be messageable; anything else is refused.
export function resolveTarget(snapshot: Snapshot, target: string): Resolution {
  const t = target.trim();
  if (!t) return { ok: false, reason: "empty_target" };
  const byId = snapshot.tasks.find((x) => x.task_id === t);
  const byAgent = byId ? undefined : snapshot.tasks.filter((x) => x.agent_id === t && messageable(x));
  let hits: TaskRow[];
  if (byId) hits = [byId];
  else if (byAgent && byAgent.length) hits = byAgent;
  else hits = snapshot.tasks.filter((x) => x.label === t && messageable(x));
  if (hits.length === 0) {
    const agent = snapshot.agents.find((a) => a.agent_id === t || a.label === t);
    if (agent && !agent.task_id) return { ok: false, reason: "agent_has_no_task" };
    const anyLabel = snapshot.tasks.some((x) => x.label === t);
    return { ok: false, reason: anyLabel ? "task_not_messageable" : "unknown_target" };
  }
  if (hits.length > 1) return { ok: false, reason: "ambiguous_target", candidates: hits.map((h) => h.task_id) };
  const task = hits[0]!;
  if (!messageable(task)) return { ok: false, reason: "task_not_messageable" };
  return { ok: true, task };
}

export const MAX_MESSAGE_CHARS = 2000;

// Delivery types the text into an agent's composer and presses Enter, so the
// text must be exactly one line of printable characters: no control bytes
// (ESC sequences, CR/LF that would submit early). The publisher adds a fixed
// prefix, so the agent never sees text that starts with "/" or "!".
export function sanitizeMessage(text: string): { ok: true; text: string } | { ok: false; reason: string } {
  // eslint-disable-next-line no-control-regex
  const cleaned = text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ").replace(/\s+/g, " ").trim();
  if (!cleaned) return { ok: false, reason: "empty_text" };
  if (cleaned.length > MAX_MESSAGE_CHARS) return { ok: false, reason: `text_too_long (max ${MAX_MESSAGE_CHARS})` };
  return { ok: true, text: cleaned };
}

export const RATE_PER_MINUTE = 5;
export const RATE_PER_HOUR = 30;

export function rateLimited(recentMs: number[], nowMs: number): string | null {
  const minute = recentMs.filter((t) => nowMs - t < 60_000).length;
  const hour = recentMs.filter((t) => nowMs - t < 3_600_000).length;
  if (minute >= RATE_PER_MINUTE) return `rate_limited (${RATE_PER_MINUTE}/minute)`;
  if (hour >= RATE_PER_HOUR) return `rate_limited (${RATE_PER_HOUR}/hour)`;
  return null;
}
