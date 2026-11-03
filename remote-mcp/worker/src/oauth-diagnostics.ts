// Only allowlisted protocol enums leave this boundary. Never serialize the event,
// description, headers, request, props, client/grant identifiers or internal.detail.
const codes = new Set(["invalid_request", "invalid_client", "invalid_grant", "unauthorized_client",
  "unsupported_grant_type", "invalid_scope", "invalid_token", "insufficient_scope", "invalid_target",
  "server_error", "temporarily_unavailable"]);
const categories = new Set(["token-endpoint-request", "client-authentication", "client-id-metadata-document",
  "authorization-code-grant", "refresh-token-grant", "resource-indicator", "token-issuance",
  "token-revocation", "client-registration", "protected-resource", "token-exchange-callback"]);
const reasons = new Set(["method_not_allowed", "repeated_parameter", "grant_type_not_supported",
  "grant_type_not_registered", "client_not_found", "client_secret_mismatch", "multiple_authentication_methods",
  "metadata_resolution_failed", "code_replayed", "code_verifier_mismatch", "redirect_uri_mismatch",
  "grant_not_found", "refresh_token_missing", "refresh_token_malformed", "refresh_token_mismatch",
  "refresh_token_expired", "client_mismatch", "scope_not_granted", "resource_not_configured",
  "resource_grant_mismatch", "legacy_grant_unbound", "kv_rate_limited", "requested_ttl_too_short",
  "token_missing", "json_malformed", "metadata_invalid", "callback_denied", "payload_too_large",
  "token_not_found", "token_expired", "audience_mismatch", "resolver_rejected", "callback_error"]);
const ownData = (value: unknown, key: string): unknown => {
  if (value === null || typeof value !== "object") return undefined;
  try {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return descriptor && "value" in descriptor ? descriptor.value : undefined;
  } catch {
    return undefined;
  }
};
const label = (value: unknown, allowed: Set<string>) =>
  typeof value === "string" && allowed.has(value) ? value : "other";

export function oauthDiagnostic(event: unknown) {
  const internal = ownData(event, "internal");
  const code = ownData(event, "code");
  const status = ownData(event, "status");
  const category = ownData(internal, "category");
  const reason = ownData(internal, "reason");
  return {
    event: "herdr.oauth_error",
    code: label(code, codes),
    status: typeof status === "number" && Number.isInteger(status) && status >= 400 && status <= 599 ? status : 0,
    category: label(category, categories),
    reason: label(reason, reasons),
  };
}

// Observability must never replace a protocol error with a thrown exception.
// In particular, never log the caught error: it may hold untrusted input.
export function logOAuthError(event: unknown, sink?: (record: ReturnType<typeof oauthDiagnostic>) => void): void {
  try {
    (sink ?? console.warn)(oauthDiagnostic(event));
  } catch {
    // Preserve the provider's original OAuth response, even if logging fails.
  }
}
