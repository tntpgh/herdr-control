#!/usr/bin/env bash
# remote-mcp/scripts/provision.sh — stand up Bebop (the herdr-mcp Worker) end to end.
#
#   bash remote-mcp/scripts/provision.sh            # dry run: report state, change nothing
#   bash remote-mcp/scripts/provision.sh --apply    # create what is missing, deploy, verify
#
# Idempotent: every step checks its own precondition, so a second --apply only
# re-deploys and re-prints VERIFY. Prints no secret value, ever (fingerprints only).
#
#   1. KV namespace "herdr-mcp-oauth" (OAuth provider storage)
#   2. Access app "herdr-mcp-authorize" on <host>/authorize for bebop.teamthurber.com
#      and every alias host (path-scoped, Google Workspace IdP pinned, email
#      policy) — ONE app, so the Worker's single ACCESS_AUD covers every host;
#      an existing app missing a host gets it added (same app, same AUD)
#   3. KV id + Access AUD written into worker/wrangler.jsonc (both public ids)
#   4. Ingest key: 1Password item herdr-mcp-ingest-key (created via op-write
#      from a 600 template file, never argv), mirrored into
#      ~/.config/op/launchd-secrets.env as HERDR_MCP_INGEST_KEY (backed up first)
#   5. wrangler deploy + `wrangler secret put INGEST_KEY` (value on stdin);
#      each custom domain checked via the API, attached if the deploy did not
set -euo pipefail

APPLY=0
case "${1:-}" in --apply) APPLY=1 ;; ""|--dry-run) ;; *) echo "usage: $0 [--apply]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORKER="$HERE/worker"
WRANGLER_CFG="$WORKER/wrangler.jsonc"
ACC="0a23a3902c4f431f05d46c86c1fa7b81"
HOST="bebop.teamthurber.com"
# Served too during the hostname cutover (wrangler.jsonc ALIAS_URLS + routes).
# Drop a host here in the same change that drops it there.
ALIAS_HOSTS=("herdr-mcp.teamthurber.com")
HOSTS=("$HOST" "${ALIAS_HOSTS[@]}")
APP_PATH="authorize"
APP_NAME="herdr-mcp-authorize"
EMAILS="tnt@teamthurber.com"
KV_TITLE="herdr-mcp-oauth"
ITEM="herdr-mcp-ingest-key"
SECRETS_FILE="$HOME/.config/op/launchd-secrets.env"
TEAM="thurberteam.cloudflareaccess.com"
fp() { shasum -a 256 | cut -c1-12; }
for bin in jq curl op npx python3 shasum; do command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }; done
(( APPLY )) || echo "DRY RUN — nothing will change. Re-run with --apply."
cd "$WORKER"
# --apply bundles exactly the lockfile, never whatever node_modules is lying
# around (stale, hand-patched, or from before an override): build_sha must
# describe what runs.
if (( APPLY )); then npm ci --silent; else [ -d node_modules ] || npm ci --silent; fi

echo "== 1. KV namespace '$KV_TITLE'"
kv_id() { npx wrangler kv namespace list 2>/dev/null | jq -r --arg t "$KV_TITLE" '.[] | select(.title==$t) | .id' | head -1; }
KV_ID="$(kv_id)"
if [[ -z "$KV_ID" && $APPLY == 1 ]]; then
  npx wrangler kv namespace create "$KV_TITLE" >/dev/null
  KV_ID="$(kv_id)"
fi
echo "   id=${KV_ID:-<missing>}"

DOMAINS_JSON="$(printf '%s\n' "${HOSTS[@]}" | jq -R --arg p "$APP_PATH" '. + "/" + $p' | jq -sc .)"
echo "== 2. Access app '$APP_NAME' on $(jq -r 'join(", ")' <<<"$DOMAINS_JSON")"
ZT="$(op read 'op://secrets/shared-cloudflare-zero-trust-key/credential')"
API="https://api.cloudflare.com/client/v4/accounts/$ACC/access"
# Tokens go to curl as a header FILE (-H @fd), never in argv where `ps` shows them.
authed() { local tok="$1"; shift; curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$tok") -H 'Content-Type: application/json' "$@"; }
cf() { authed "$ZT" "$@"; }
IDP="$(cf "$API/identity_providers" | jq -r '[.result[]? | select(.type=="google-apps")][0].id // empty')"
[[ -n "$IDP" ]] || { echo "   BLOCKER: Google Workspace IdP not found; allowed_idps must be pinned" >&2; exit 1; }
APP_JSON="$(cf "$API/apps" | jq -c --arg n "$APP_NAME" 'first(.result[]? | select(.name==$n)) // empty')"
if [[ -z "$APP_JSON" && $APPLY == 1 ]]; then
  INCLUDE="$(printf '%s\n' "${EMAILS//,/$'\n'}" | jq -R '{email: {email: .}}' | jq -sc .)"
  BODY="$(jq -nc --arg name "$APP_NAME" --arg domain "$HOST/$APP_PATH" --argjson doms "$DOMAINS_JSON" --argjson include "$INCLUDE" --arg idp "$IDP" '{
    name: $name, type: "self_hosted", domain: $domain, self_hosted_domains: $doms,
    session_duration: "24h", app_launcher_visible: false, auto_redirect_to_identity: true,
    allowed_idps: [$idp],
    policies: [ { name: "herdr-mcp-emails", decision: "allow", precedence: 1, include: $include } ]
  }')"
  RESP="$(cf -X POST "$API/apps" --data "$BODY")"
  jq -e .success <<<"$RESP" >/dev/null || { echo "   create FAILED: $(jq -c .errors <<<"$RESP")" >&2; exit 1; }
  APP_JSON="$(jq -c .result <<<"$RESP")"
fi
APP_ID=""; AUD=""
if [[ -n "$APP_JSON" ]]; then APP_ID="$(jq -r .id <<<"$APP_JSON")"; AUD="$(jq -r .aud <<<"$APP_JSON")"; fi
echo "   id=${APP_ID:-<missing>} aud=${AUD:-<missing>}"
if [[ -n "$APP_JSON" ]]; then
  got_idps="$(jq -r '(.allowed_idps // []) | join(",")' <<<"$APP_JSON")"
  [[ "$got_idps" == "$IDP" ]] || { echo "   MISMATCH: idps=$got_idps" >&2; exit 1; }
  missing="$(jq -r --argjson want "$DOMAINS_JSON" '$want - (.self_hosted_domains // [.domain]) | join(" ")' <<<"$APP_JSON")"
  if [[ -n "$missing" ]]; then
    echo "   missing host(s): $missing"
    if (( APPLY )); then
      # Same app, same AUD: only the host list grows. Read-only fields are
      # dropped; newer apps also carry `destinations`, kept in step.
      UPD="$(jq -c --argjson doms "$DOMAINS_JSON" --arg domain "$HOST/$APP_PATH" '
        del(.id, .uid, .aud, .created_at, .updated_at)
        | .domain = $domain | .self_hosted_domains = $doms
        | if has("destinations") then .destinations = [$doms[] | {type: "public", uri: .}] else . end' <<<"$APP_JSON")"
      RESP="$(cf -X PUT "$API/apps/$APP_ID" --data "$UPD")"
      jq -e .success <<<"$RESP" >/dev/null || { echo "   update FAILED: $(jq -c .errors <<<"$RESP")" >&2; exit 1; }
      APP_JSON="$(jq -c .result <<<"$RESP")"
      [[ "$(jq -r .aud <<<"$APP_JSON")" == "$AUD" ]] || { echo "   AUD changed on update; ACCESS_AUD must follow" >&2; exit 1; }
      echo "   added: $missing (aud unchanged)"
    fi
  fi
fi

echo "== 3. ids into wrangler.jsonc"
if [[ -n "$KV_ID" && -n "$AUD" ]]; then
  if (( APPLY )); then
    KV_ID="$KV_ID" AUD="$AUD" python3 - "$WRANGLER_CFG" <<'PY'
import os, re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'("binding": "OAUTH_KV", "id": ")[^"]*(")', lambda m: m.group(1) + os.environ["KV_ID"] + m.group(2), s)
s = re.sub(r'("ACCESS_AUD": ")[^"]*(")', lambda m: m.group(1) + os.environ["AUD"] + m.group(2), s)
open(p, "w").write(s)
PY
  fi
  echo "   wrangler.jsonc: kv=$(grep -o '"OAUTH_KV", "id": "[^"]*"' "$WRANGLER_CFG" | cut -d'"' -f6) aud=$(grep -o '"ACCESS_AUD": "[^"]*"' "$WRANGLER_CFG" | cut -d'"' -f4 | cut -c1-12)…"
else
  echo "   skipped (ids not yet created)"
fi

echo "== 4. ingest key"
KEY="$(op read "op://secrets/$ITEM/credential" 2>/dev/null || true)"
if [[ -z "$KEY" && $APPLY == 1 ]]; then
  KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  TPL="$(mktemp)"; chmod 600 "$TPL"; trap 'rm -f "$TPL"' EXIT   # the key never outlives a failed op-write
  KEY="$KEY" ITEM="$ITEM" python3 -c 'import json,os; print(json.dumps({"title": os.environ["ITEM"], "category": "API_CREDENTIAL",
    "fields": [{"id": "credential", "label": "credential", "type": "CONCEALED", "value": os.environ["KEY"]},
               {"id": "notesPlain", "label": "notesPlain", "type": "STRING", "purpose": "NOTES",
                "value": "HMAC key: herdr-control remote-mcp publisher -> herdr-mcp Worker (INGEST_KEY). Mirrored in ~/.config/op/launchd-secrets.env."}]}))' > "$TPL"
  op-write item create --vault Secrets --template "$TPL" >/dev/null
  rm -f "$TPL"
  KEY="$(op read "op://secrets/$ITEM/credential")"
fi
if [[ -n "$KEY" ]]; then
  echo "   1Password $ITEM fingerprint $(printf %s "$KEY" | fp)"
  FILE_KEY="$(HERDR_MCP_INGEST_KEY= python3 "$HERE/publisher.py" --print-key-fingerprint 2>/dev/null || true)"
  if [[ "$FILE_KEY" != "$(printf %s "$KEY" | fp)" && $APPLY == 1 ]]; then
    mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
    cp -p "$SECRETS_FILE" "$SECRETS_FILE.bak.$(date +%Y%m%d%H%M%S)"
    KEY="$KEY" python3 - "$SECRETS_FILE" <<'PY'
import os, sys
p = sys.argv[1]
lines = [l for l in open(p).read().splitlines() if not l.strip().removeprefix("export ").startswith("HERDR_MCP_INGEST_KEY=")]
lines.append("HERDR_MCP_INGEST_KEY=" + os.environ["KEY"])
open(p, "w").write("\n".join(lines) + "\n")
PY
  fi
  echo "   launchd-secrets.env fingerprint $(HERDR_MCP_INGEST_KEY= python3 "$HERE/publisher.py" --print-key-fingerprint 2>/dev/null || echo '<missing>')"
else
  echo "   <missing>"
fi

# The deploy is stamped with the commit it was built from, so /healthz proves
# what is running. Only a clean tree whose HEAD is on the remote gets stamped.
SHA="$(git -C "$HERE" rev-parse HEAD)"
DIRTY="$(git -C "$HERE" status --porcelain -- . | head -1)"
PUSHED="$(git -C "$HERE" branch -r --contains "$SHA" 2>/dev/null | head -1)"
echo "== build $SHA  clean=$([[ -z "$DIRTY" ]] && echo yes || echo no)  on-remote=$([[ -n "$PUSHED" ]] && echo yes || echo no)"

if (( APPLY )); then
  echo "== 5. deploy"
  [[ -n "$KV_ID" && -n "$AUD" && -n "$KEY" ]] || { echo "   refusing: an id or the key is missing" >&2; exit 1; }
  # First --apply fills the KV/AUD ids into wrangler.jsonc and stops here; commit
  # and push them, then re-run, so the deployed config is exactly a commit.
  [[ -z "$DIRTY" && -n "$PUSHED" ]] || {
    echo "   stopping before deploy: remote-mcp/ has uncommitted or unpushed changes (first run: the filled-in ids)." >&2
    echo "   commit + push them, then re-run --apply; the deploy is stamped with that commit." >&2
    git -C "$HERE" status --short -- . >&2; exit 1; }
  npx wrangler deploy --var "BUILD_SHA:$SHA" --tag "${SHA:0:12}" --message "herdr-mcp ${SHA:0:12}" 2>&1 | grep -vE '^\s*$' | tail -8
  # A secret upload publishes a new, untagged version on top of the stamped
  # deploy, so only do it when the secret is missing (first deploy). /healthz
  # build_sha is the proof either way: the secret version keeps every var.
  if npx wrangler secret list 2>/dev/null | jq -e '.[] | select(.name=="INGEST_KEY")' >/dev/null; then
    echo "   INGEST_KEY already set (key fingerprint above)"
  else
    printf %s "$KEY" | npx wrangler secret put INGEST_KEY >/dev/null && echo "   INGEST_KEY set"
  fi
  CFK="$(op read 'op://secrets/shared-cloudflare-api-key/credential')"
  ZONE=""
  for h in "${HOSTS[@]}"; do
    DOM="$(authed "$CFK" "https://api.cloudflare.com/client/v4/accounts/$ACC/workers/domains?hostname=$h" | jq -r '.result[0].service // empty')"
    if [[ "$DOM" != "herdr-mcp" ]]; then
      [[ -n "$ZONE" ]] || ZONE="$(authed "$CFK" 'https://api.cloudflare.com/client/v4/zones?name=teamthurber.com' | jq -r '.result[0].id')"
      echo "   attaching custom domain $h"
      authed "$CFK" -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/$ACC/workers/domains" \
        -d "$(jq -nc --arg h "$h" --arg z "$ZONE" '{environment:"production", hostname:$h, service:"herdr-mcp", zone_id:$z}')" \
        | jq -c '{success, errors}'
    fi
  done
fi

echo
echo "===== VERIFY ====="
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# The expectation comes from what this deploy shipped (wrangler.jsonc
# OWNER_INBOX_ENABLED): the note scopes are offered only while it is on.
# Non-comment lines only, any spacing, any case; absent means off.
WANT_INBOX="$(grep -v '^[[:space:]]*//' "$WRANGLER_CFG" | grep -oiE '"OWNER_INBOX_ENABLED"[[:space:]]*:[[:space:]]*"[a-z]+"' | tail -1 | cut -d'"' -f4 | tr 'A-Z' 'a-z' || true)"
if [ "$WANT_INBOX" = true ]; then
  WANT_SCOPES='["fm:read","fm:reports","fm:request","fm:decide-note","fm:peer"]'
else
  WANT_SCOPES='["fm:read","fm:reports"]'
fi
for h in "${HOSTS[@]}"; do
  B="https://$h"
  ROLE=alias; [[ "$h" == "$HOST" ]] && ROLE=canonical
  echo "-- $B ($ROLE)"
  echo "PRM resource:          $(curl -s "$B/.well-known/oauth-protected-resource/mcp" | jq -r '.resource // "FAIL"')   (want $B/mcp)"
  echo "AS issuer / S256 / iss: $(curl -s "$B/.well-known/oauth-authorization-server" | jq -r '"\(.issuer) / \(.code_challenge_methods_supported|index("S256")!=null) / \(.authorization_response_iss_parameter_supported)"')   (want $B / true / true)"
  echo "AS scopes_supported:   $(curl -s "$B/.well-known/oauth-authorization-server" | jq -c '.scopes_supported')   (want $WANT_SCOPES)"
  HZ="$(curl -s --max-time 15 "$B/healthz" || true)"   # a network failure is a MISMATCH, not an abort
  echo "/healthz:              $(printf '%s' "$HZ" | jq -c '{build_sha, host_role, scopes_offered, legacy_herdr_scopes, clients}' 2>/dev/null || echo "<no JSON response>")"
  echo "                       (want build_sha $SHA, host_role $ROLE, scopes_offered $WANT_SCOPES): $(printf '%s' "$HZ" | jq -r --arg s "$SHA" --arg r "$ROLE" --argjson o "$WANT_SCOPES" 'if .build_sha==$s and .host_role==$r and .scopes_offered==$o then "OK" else "MISMATCH" end' 2>/dev/null | grep . || echo MISMATCH)"
  echo "/mcp no token:         $(code -X POST "$B/mcp")   (want 401)"
  echo "/authorize no session: $(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' "$B/authorize" | cut -c1-80)   (want 302 -> $TEAM)"
  echo "/ingest unsigned:      $(code -X POST "$B/ingest/sync")   (want 401; 503 = INGEST_KEY not set)"
done
echo "unknown host (edge):   $(code -H 'Host: nope.teamthurber.com' "https://$HOST/healthz")   (want 421 or an edge refusal; never 200 -- the Worker's own 421 is proven by the test suite)"
echo "live version:          $(npx wrangler deployments status 2>/dev/null | grep -E 'Version|Tag|Message' | tr -s ' ' | paste -sd ';' -)"
echo
echo "ROLLBACK (README \"Bebop cutover runbook\" for the staged version):"
echo "  npx wrangler rollback                      # previous Worker version; DO, KV and grants untouched"
echo "  npx wrangler delete herdr-mcp            # Worker, DO, custom domain routes -- last resort, loses state"
echo "  curl -X DELETE -H @<(printf 'Authorization: Bearer %s\\n' \"\$ZT\") $API/apps/${APP_ID:-<id>}"
echo "  npx wrangler kv namespace delete --namespace-id ${KV_ID:-<id>}"
echo "  op-write item delete $ITEM --vault Secrets --archive; remove HERDR_MCP_INGEST_KEY from $SECRETS_FILE"
