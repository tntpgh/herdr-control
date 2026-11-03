import { describe, expect, it } from "vitest";
import { oauthDiagnostic, logOAuthError } from "../src/oauth-diagnostics";

describe("OAuth diagnostics without credential disclosure", () => {
  it("never throws or returns a replacement response when diagnostics fail", () => {
    const hostile = { get internal() { throw new Error("SENTINEL_SECRET"); } };
    let calls = 0;
    expect(logOAuthError(hostile, () => { calls++; })).toBeUndefined();
    expect(calls).toBe(0);
    expect(logOAuthError({}, () => { throw new Error("SENTINEL_SECRET"); })).toBeUndefined();
  });
  it("keeps the stable failure reason and drops every free-text field", () => {
    const result = oauthDiagnostic({ status: 401, code: "invalid_client", description: "SENTINEL_SECRET",
      headers: { authorization: "SENTINEL_SECRET" }, request: "SENTINEL_SECRET",
      internal: { category: "client-authentication", reason: "client_secret_mismatch", detail: "SENTINEL_SECRET" } });
    expect(result).toEqual({ event: "herdr.oauth_error", status: 401, code: "invalid_client",
      category: "client-authentication", reason: "client_secret_mismatch" });
    expect(JSON.stringify(result)).not.toContain("SENTINEL_SECRET");
  });
  it("maps unknown labels and invalid status to safe placeholders", () => {
    expect(oauthDiagnostic({ status: "401", code: "SENTINEL_SECRET",
      internal: { category: "SENTINEL_SECRET", reason: "SENTINEL_SECRET" } }))
      .toEqual({ event: "herdr.oauth_error", status: 0, code: "other", category: "other", reason: "other" });
  });
  it("handles absent or malformed inputs without leaking their values", () => {
    for (const input of [null, undefined, "SENTINEL_SECRET", {}, { internal: null, status: NaN }]) {
      expect(oauthDiagnostic(input)).toEqual({ event: "herdr.oauth_error", status: 0,
        code: "other", category: "other", reason: "other" });
    }
  });
});
