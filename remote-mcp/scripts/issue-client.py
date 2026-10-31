#!/usr/bin/env python3
"""Confirm and label a herdr-mcp OAuth connection as a known client, with
an explicit scope profile (SPEC: .handoffs/DUET-IDENTITY-SPEC-20261031.md
-- "duet", "dot" (alias: "zero"), and any future client of the same kind).

    python3 remote-mcp/scripts/issue-client.py list
    python3 remote-mcp/scripts/issue-client.py label duet --client-id CLIENT_ID --profile full [--apply]
    python3 remote-mcp/scripts/issue-client.py label dot --client-id CLIENT_ID [--apply]
    python3 remote-mcp/scripts/issue-client.py label dot --grant-id GRANT_ID [--apply]

Does NOT register an OAuth client and does NOT touch a token: an MCP client
(Duet's, Dot's, ChatGPT's, Claude's -- any OAuth-2.1-capable MCP client)
already does its own DCR + PKCE + consent the moment Terrence adds
https://herdr-mcp.teamthurber.com/mcp as a connector in its settings and
signs in. A client registered via CIMD (client ID metadata document --
Claude.ai's own id is the URL https://claude.ai/oauth/mcp-oauth-client-metadata,
ChatGPT's is https://chatgpt.com/oauth/client.json) has that URL AS its
client_id, compared byte-for-byte below like any other id -- no special
casing needed. This script runs AFTER consent: Terrence completes the
consent page in HIS OWN browser himself (ticking exactly the boxes for the
chosen --profile), then `list` to find the new grant, then `label <name>`
to record which one is duet/dot going forward AND to refuse, loudly, if its
scope is not EXACTLY that profile's set -- catching a stray or missing tick
before the credential is ever used.

--profile (default peer-inbox):
  peer-inbox  herdr:read, herdr:message.owner -- read assigned, reply,
              ack, report-blocked. Never herdr:message, never any
              herdr:task.*.
  full        peer-inbox plus herdr:message, herdr:task.start,
              herdr:task.implement, herdr:task.cancel -- app-to-app
              messaging and task start/implement/cancel, for a client
              trusted with the whole surface.
Either way the check is an EXACT set match: anything extra or missing is
refused, never silently narrowed or widened.

What this never does, by construction (no code path touches /oauth/token):
mint a credential, see a bearer token, or print one. `--apply` only writes
a NON-secret local label (client_id -> name) to
~/.local/state/herdr/remote-mcp/client-labels.json -- client_id is a
provider-issued public identifier (the registered OAuth client's own id,
not a credential), already visible unredacted in `grants.py list`.

Revoking one client's access later, independent of the others:
    python3 remote-mcp/scripts/grants.py revoke GRANT_ID --apply
(grant_id is what `list`/`label` below print; see grants.py's own docstring
-- deleting one grant's tokens and queued sends never touches another's).

Signed with the publisher's HERDR_MCP_INGEST_KEY (same lookup as
publisher.py/grants.py); the Worker audits every call (admin_list).
label is a dry run unless --apply.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grants import call, ingest_key, show  # noqa: E402

STATE = Path(os.environ.get("HERDR_STATE_DIR", Path.home() / ".local/state/herdr"))
LABELS_PATH = STATE / "remote-mcp" / "client-labels.json"

# The SPEC's "peer inbox only" scope, exactly: read assigned (get_owner_
# message_status), reply/ack/report-blocked (send_owner_message -- its body
# is free text, so an ack or a blocked-report is just what the text says).
# Never herdr:message (send_message to a task's agent) and never any
# herdr:task.* -- that denial is enforced HERE, not hoped for on the
# consent page.
PEER_INBOX_SCOPE = frozenset({"herdr:read", "herdr:message.owner"})

# The full surface: peer-inbox plus app-to-app messaging and all three task
# verbs. Still an EXACT-set check below -- granting this profile is a
# deliberate per-client decision, never a default.
FULL_SCOPE = frozenset({
    "herdr:read", "herdr:message", "herdr:task.start",
    "herdr:task.implement", "herdr:task.cancel", "herdr:message.owner",
})

SCOPE_PROFILES: dict[str, frozenset[str]] = {"peer-inbox": PEER_INBOX_SCOPE, "full": FULL_SCOPE}

# "zero" was the peer-inbox client's working name before it was renamed to
# "dot"; keep it resolving to the same label rather than minting a second
# name for the same client.
NAME_ALIASES: dict[str, str] = {"zero": "dot"}


def load_labels() -> dict[str, str]:
    try:
        return json.loads(LABELS_PATH.read_text())
    except (OSError, ValueError):
        return {}


def save_labels(labels: dict[str, str]) -> None:
    LABELS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = LABELS_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(labels, indent=2, sort_keys=True) + "\n")
    tmp.replace(LABELS_PATH)


def find_grant(grants: list[dict], client_id: str | None, grant_id: str | None) -> dict | None:
    for g in grants:
        if grant_id and g["grant_id"] == grant_id:
            return g
        if client_id and g["client_id"] == client_id:
            return g
    return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=["list", "label"])
    ap.add_argument("name", nargs="?", help="label op only: duet, dot (alias: zero), ...")
    ap.add_argument("--client-id")
    ap.add_argument("--grant-id")
    ap.add_argument("--profile", choices=sorted(SCOPE_PROFILES), default="peer-inbox",
                     help="scope this grant must EXACTLY match (default: peer-inbox)")
    ap.add_argument("--user", default="tnt@teamthurber.com")
    ap.add_argument("--apply", action="store_true", help="label: actually record it (default is a dry run)")
    a = ap.parse_args(argv)
    key = ingest_key()
    if not key:
        print("HERDR_MCP_INGEST_KEY not found (env or ~/.config/op/launchd-secrets.env)", file=sys.stderr)
        return 2
    status, listed = call(key, {"op": "list", "user": a.user})
    if status != 200:
        print(f"list failed: HTTP {status} {listed.get('error')}", file=sys.stderr)
        return 1
    labels = load_labels()
    grants = listed["grants"]

    if a.op == "list":
        print(f"grants for {a.user}:")
        show(grants)
        if labels:
            print("labelled:")
            for client_id, name in sorted(labels.items()):
                match = next((g for g in grants if g["client_id"] == client_id), None)
                print(f"  {name}: client={client_id}" + (f"  grant={match['grant_id']}" if match else "  (grant no longer listed)"))
        return 0

    if not a.name:
        ap.error("label needs a NAME (duet, dot, ...)")
    if not a.client_id and not a.grant_id:
        ap.error("label needs --client-id or --grant-id (see `list`)")
    name = NAME_ALIASES.get(a.name, a.name)
    if name != a.name:
        print(f"'{a.name}' is an alias for '{name}'; labelling as '{name}'.")
    want = SCOPE_PROFILES[a.profile]
    g = find_grant(grants, a.client_id, a.grant_id)
    if g is None:
        print(f"no grant matches --client-id/--grant-id among {a.user}'s {len(grants)} grant(s); run `list` first", file=sys.stderr)
        return 1
    have = frozenset(g["scope"])
    print(f"grant {g['grant_id']}  client={g['client_id']}  scope={','.join(sorted(have))}")
    if have != want:
        extra = have - want
        missing = want - have
        print(f"FAIL  not the '{a.profile}' scope (SPEC: '{a.profile}' gets exactly {sorted(want)}).", file=sys.stderr)
        if extra:
            print(f"  extra (must be removed -- revoke this grant and re-consent without ticking it): {sorted(extra)}", file=sys.stderr)
        if missing:
            print(f"  missing: {sorted(missing)}", file=sys.stderr)
        return 1
    existing = next((n for c, n in labels.items() if c == g["client_id"] and n != name), None)
    if existing:
        print(f"FAIL  client {g['client_id']} is already labelled '{existing}'; pick one name per client", file=sys.stderr)
        return 1
    if not a.apply:
        print(f"DRY RUN — scope OK. Would label client={g['client_id']} as '{name}' ({a.profile}). Re-run with --apply.")
        return 0
    labels[g["client_id"]] = name
    save_labels(labels)
    print("===== VERIFY =====")
    after = load_labels()
    good = after.get(g["client_id"]) == name
    print(f"  {LABELS_PATH}: {json.dumps(after, sort_keys=True)}")
    print(f"OK  '{name}' -> {g['client_id']}" if good else "FAIL  label did not persist")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
