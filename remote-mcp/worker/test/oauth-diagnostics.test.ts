import { describe, expect, it } from "vitest";
import { oauthDiagnostic, logOAuthError } from "../src/oauth-diagnostics";

describe("OAuth diagnostics without credential disclosure", () => {
  it("never invokes accessors and never replaces the provider response", () => {
    const getterCalls = { internal: 0, code: 0, status: 0 };
    const hostile = {
      get internal() { getterCalls.internal++; throw new Error("SENTINEL_SECRET"); },
      get code() { getterCalls.code++; return "SENTINEL_SECRET"; },
      get status() { getterCalls.status++; return "SENTINEL_SECRET"; },
    };
    const records: unknown[] = [];
    expect(logOAuthError(hostile, (record) => { records.push(record); })).toBeUndefined();
    expect(getterCalls).toEqual({ internal: 0, code: 0, status: 0 });
    expect(records).toEqual([{ event: "herdr.oauth_error", status: 0,
      code: "other", category: "other", reason: "other" }]);
    expect(logOAuthError({}, () => { throw new Error("SENTINEL_SECRET"); })).toBeUndefined();
  });
  it("does not invoke nested or stateful accessors", () => {
    let categoryCalls = 0;
    let reasonCalls = 0;
    let statusCalls = 0;
    const internal = {
      get category() { categoryCalls++; return "client-authentication"; },
      get reason() { reasonCalls++; return "client_secret_mismatch"; },
    };
    const event = {
      internal,
      get status() {
        statusCalls++;
        return statusCalls < 5 ? 401 : "SENTINEL_SECRET";
      },
    };
    const result = oauthDiagnostic(event);
    expect({ categoryCalls, reasonCalls, statusCalls }).toEqual({
      categoryCalls: 0, reasonCalls: 0, statusCalls: 0,
    });
    expect(JSON.stringify(result)).not.toContain("SENTINEL_SECRET");
    expect(result.status).toBe(0);
  });
  it("fails safe when a proxy rejects descriptor inspection", () => {
    const hostile = new Proxy({}, {
      getOwnPropertyDescriptor() { throw new Error("SENTINEL_SECRET"); },
    });
    const records: unknown[] = [];
    expect(logOAuthError(hostile, (record) => { records.push(record); })).toBeUndefined();
    expect(JSON.stringify(records)).not.toContain("SENTINEL_SECRET");
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
