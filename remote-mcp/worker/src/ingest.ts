// Publisher -> Worker authentication. Separate from OAuth on purpose: the Mac
// is a machine, not a user, and must never hold a user token.
//
// signature = hex(HMAC-SHA256(INGEST_KEY, `${ts}.${nonce}.${hex(sha256(body))}`))
// Headers: x-herdr-ts (unix seconds), x-herdr-nonce (16-64 hex), x-herdr-sig.
// The caller (HerdrState) rejects a nonce it has already seen.

export const MAX_SKEW_S = 300;
export const MAX_BODY_BYTES = 2_000_000;

const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sign(key: string, ts: string, nonce: string, body: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const bodyHash = hex(await crypto.subtle.digest("SHA-256", enc.encode(body)));
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(`${ts}.${nonce}.${bodyHash}`)));
}

export type IngestCheck = { ok: true; body: string; nonce: string } | { ok: false; status: number; reason: string };

export async function verifyIngest(request: Request, key: string | undefined, nowS: number): Promise<IngestCheck> {
  if (!key || key.length < 32) return { ok: false, status: 503, reason: "ingest_not_configured" };
  const ts = request.headers.get("x-herdr-ts") ?? "";
  const nonce = request.headers.get("x-herdr-nonce") ?? "";
  const sig = request.headers.get("x-herdr-sig") ?? "";
  if (!/^\d{9,11}$/.test(ts) || !/^[0-9a-f]{16,64}$/.test(nonce) || !/^[0-9a-f]{64}$/.test(sig)) {
    return { ok: false, status: 401, reason: "bad_headers" };
  }
  if (Math.abs(nowS - Number(ts)) > MAX_SKEW_S) return { ok: false, status: 401, reason: "stale_timestamp" };
  const len = Number(request.headers.get("content-length") ?? "0");
  if (len > MAX_BODY_BYTES) return { ok: false, status: 413, reason: "too_large" };
  const body = await request.text();
  if (body.length > MAX_BODY_BYTES) return { ok: false, status: 413, reason: "too_large" };
  const want = await sign(key, ts, nonce, body);
  // Constant-time compare of two equal-length hex strings.
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ sig.charCodeAt(i);
  if (diff !== 0) return { ok: false, status: 401, reason: "bad_signature" };
  return { ok: true, body, nonce };
}
