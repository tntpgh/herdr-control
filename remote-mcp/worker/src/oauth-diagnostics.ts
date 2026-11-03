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
const object = (v: unknown): Record<string, unknown> =>
  v !== null && typeof v === "object" ? v as Record<string, unknown> : {};
const label = (v: unknown, allowed: Set<string>) => typeof v === "string" && allowed.has(v) ? v : "other";

export function oauthDiagnostic(event: unknown) {
  const e = object(event);
  const internal = object(e.internal);
  return {
    event: "herdr.oauth_error",
    code: label(e.code, codes),
    status: typeof e.status === "number" && Number.isInteger(e.status) && e.status >= 400 && e.status <= 599 ? e.status : 0,
    category: label(internal.category, categories),
    reason: label(internal.reason, reasons),
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
