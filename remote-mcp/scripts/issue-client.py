#!/usr/bin/env python3
"""Confirm and label a Bebop OAuth connection as a known client, with an
explicit scope profile (SPEC: .handoffs/DUET-IDENTITY-SPEC-20261031.md --
"duet", "dot" (alias: "zero")).

    python3 remote-mcp/scripts/issue-client.py list
    python3 remote-mcp/scripts/issue-client.py label dot --client-id CLIENT_ID [--apply]
    python3 remote-mcp/scripts/issue-client.py label duet --client-id CLIENT_ID --peer [--apply]
    python3 remote-mcp/scripts/issue-client.py label dot --grant-id GRANT_ID --profile read [--apply]
    python3 remote-mcp/scripts/issue-client.py label dot --client-id CLIENT_ID --profile legacy-peer-inbox [--apply]
    python3 remote-mcp/scripts/issue-client.py peers
    python3 remote-mcp/scripts/issue-client.py unpeer duet [--apply]

Does NOT register an OAuth client and does NOT touch a token: Claude.ai and
ChatGPT run their own CIMD + PKCE + consent the moment Terrence adds
https://bebop.teamthurber.com/mcp as a connector and signs in. Each uses its
client ID metadata document URL AS its client_id (Claude.ai:
https://claude.ai/oauth/mcp-oauth-client-metadata, ChatGPT:
https://chatgpt.com/oauth/client.json) -- the ids the Worker's CLIENT_GRANTS
(worker/src/policy.ts) allow; any other client gets no consent page at all.
This script runs AFTER consent: `list` to find the new grant, then
`label <name>` to record which one is duet/dot AND to refuse, loudly, if its
scope is not EXACTLY the profile's set -- catching a stray or missing tick
before the credential is used.

--profile (default: the name's own profile, for dot and duet):
  dot                fm:read, fm:reports, fm:request, fm:decide-note, fm:peer
                     -- Dot's whole grant ceiling.
  duet               the same five scopes -- Duet's whole grant ceiling, equal
                     to Dot's. A Duet grant from before parity (no
                     fm:decide-note) fails this; reconnect to re-consent.
  read               fm:read, fm:reports -- look, never write.
  legacy-peer-inbox  herdr:read, herdr:message.owner -- a connection made at
                     herdr-mcp before the cutover; honoured only if the
                     Worker's LEGACY_HERDR_SCOPES is set back to "true".
Either way the check is an EXACT set match: anything extra or missing is
refused, never silently narrowed or widened. A client with several grants
is checked against the one that matches, if any.

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

Duet<->Dot coordination (remote-mcp/README.md section of that name):
`label ... --peer` also pushes the label to the Worker (signed /admin/peers)
so the two apps can address each other with send_peer_message; the Worker
re-checks the grant is live and effectively holds fm:peer. `peers` lists the
Worker's labels; `unpeer <name>` removes one. No reconnect needed.

Signed with the publisher's HERDR_MCP_INGEST_KEY (same lookup as
publisher.py/grants.py); the Worker audits every call (admin_list,
admin_peers_*). label and unpeer are dry runs unless --apply.
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
PEERS_PATH = "/admin/peers"

# Each profile is an exact scope set. The Worker enforces the same ceilings
# (policy.ts CLIENT_GRANTS); this check catches a stray tick on the Mac
# before the credential is used.
FM_ALL = frozenset({"fm:read", "fm:reports", "fm:request", "fm:decide-note", "fm:peer"})
SCOPE_PROFILES: dict[str, frozenset[str]] = {
    "dot": FM_ALL,
    "duet": FM_ALL,
    "read": frozenset({"fm:read", "fm:reports"}),
    "legacy-peer-inbox": frozenset({"herdr:read", "herdr:message.owner"}),
}

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


def find_grant(grants: list[dict], client_id: str | None, grant_id: str | None,
               want: frozenset[str] = frozenset()) -> dict | None:
    """The grant named by --grant-id, else the client's grant whose scope is
    exactly `want`, else the client's first grant (to report what is wrong)."""
    if grant_id:
        return next((g for g in grants if g["grant_id"] == grant_id), None)
    mine = [g for g in grants if client_id and g["client_id"] == client_id]
    return next((g for g in mine if frozenset(g["scope"]) == want), mine[0] if mine else None)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=["list", "label", "peers", "unpeer"])
    ap.add_argument("name", nargs="?", help="label op only: duet, dot (alias: zero), ...")
    ap.add_argument("--client-id")
    ap.add_argument("--grant-id")
    ap.add_argument("--profile", choices=sorted(SCOPE_PROFILES),
                     help="scope this grant must EXACTLY match (default: the name's own profile, dot or duet)")
    ap.add_argument("--user", default="tnt@teamthurber.com")
    ap.add_argument("--peer", action="store_true",
                     help="label: also set this as the Worker's peer label (Duet<->Dot coordination)")
    ap.add_argument("--apply", action="store_true", help="label/unpeer: actually do it (default is a dry run)")
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

    if a.op == "peers":
        status, out = call(key, {"op": "list"}, PEERS_PATH)
        if status != 200:
            print(f"peers failed: HTTP {status} {out.get('error')}", file=sys.stderr)
            return 1
        print("worker peer labels:")
        for p in out["peers"]:
            print(f"  {p['label']}: client={p['client_id']}  user={p['actor']}  set={p['set_at']}")
        return 0

    if a.op == "unpeer":
        if not a.name:
            ap.error("unpeer needs a NAME (duet, dot, ...)")
        name = NAME_ALIASES.get(a.name, a.name)
        if not a.apply:
            print(f"DRY RUN — would remove Worker peer label '{name}'. Re-run with --apply.")
            return 0
        status, out = call(key, {"op": "remove", "label": name}, PEERS_PATH)
        if status != 200:
            print(f"unpeer failed: HTTP {status} {out.get('error')}", file=sys.stderr)
            return 1
        print("===== VERIFY =====")
        status, after = call(key, {"op": "list"}, PEERS_PATH)
        gone = status == 200 and all(p["label"] != name for p in after["peers"])
        print(f"OK  '{name}' removed from the Worker" if gone else "FAIL  label still listed")
        return 0 if gone else 1

    if not a.name:
        ap.error("label needs a NAME (duet, dot, ...)")
    if not a.client_id and not a.grant_id:
        ap.error("label needs --client-id or --grant-id (see `list`)")
    name = NAME_ALIASES.get(a.name, a.name)
    if name != a.name:
        print(f"'{a.name}' is an alias for '{name}'; labelling as '{name}'.")
    profile = a.profile or (name if name in ("dot", "duet") else None)
    if profile is None:
        ap.error(f"label {name} needs --profile ({', '.join(sorted(SCOPE_PROFILES))})")
    want = SCOPE_PROFILES[profile]
    g = find_grant(grants, a.client_id, a.grant_id, want)
    if g is None:
        print(f"no grant matches --client-id/--grant-id among {a.user}'s {len(grants)} grant(s); run `list` first", file=sys.stderr)
        return 1
    have = frozenset(g["scope"])
    print(f"grant {g['grant_id']}  client={g['client_id']}  scope={','.join(sorted(have))}")
    if have != want:
        extra = have - want
        missing = want - have
        print(f"FAIL  not the '{profile}' scope ('{profile}' gets exactly {sorted(want)}).", file=sys.stderr)
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
        also = " and set it as the Worker peer label" if a.peer else ""
        print(f"DRY RUN — scope OK. Would label client={g['client_id']} as '{name}' ({profile}){also}. Re-run with --apply.")
        return 0
    labels[g["client_id"]] = name
    save_labels(labels)
    print("===== VERIFY =====")
    after = load_labels()
    good = after.get(g["client_id"]) == name
    print(f"  {LABELS_PATH}: {json.dumps(after, sort_keys=True)}")
    print(f"OK  '{name}' -> {g['client_id']}" if good else "FAIL  label did not persist")
    if good and a.peer:
        status, out = call(key, {"op": "set", "label": name, "user": a.user, "client_id": g["client_id"]}, PEERS_PATH)
        if status != 200:
            print(f"FAIL  Worker peer label: HTTP {status} {out.get('error')}", file=sys.stderr)
            return 1
        good = any(p["label"] == name and p["client_id"] == g["client_id"] for p in out["peers"])
        print(f"OK  Worker peer label '{name}' -> {g['client_id']}" if good else "FAIL  Worker peer label not listed")
        print(f"Rollback: python3 remote-mcp/scripts/issue-client.py unpeer {name} --apply")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
