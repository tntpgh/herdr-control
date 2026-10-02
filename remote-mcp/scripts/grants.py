#!/usr/bin/env python3
"""List or revoke herdr-mcp OAuth grants (connections) from the Mac.

    python3 remote-mcp/scripts/grants.py list   [--user EMAIL]
    python3 remote-mcp/scripts/grants.py revoke GRANT_ID [--user EMAIL] [--apply]

A grant is one connected client (e.g. Zero's ChatGPT plugin) for one user.
Revoking it deletes its tokens at once and cancels any message it still has
queued, without touching ALLOWED_EMAILS, so your other connections keep
working. revoke is a dry run unless --apply is given.

Signed with the publisher's HERDR_MCP_INGEST_KEY (same lookup as
publisher.py); the Worker audits every call (tool admin_list / admin_revoke).
"""
from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from publisher import URL, ingest_key, sign  # noqa: E402


def call(key: str, body: dict, path: str = "/admin/grants") -> tuple[int, dict]:
    """One signed POST to a Mac-only admin route (also used by limits.py)."""
    raw = json.dumps(body, separators=(",", ":")).encode()
    ts, nonce = str(int(time.time())), secrets.token_hex(16)
    req = urllib.request.Request(f"{URL}{path}", data=raw, method="POST", headers={
        "content-type": "application/json", "x-herdr-ts": ts, "x-herdr-nonce": nonce,
        "x-herdr-sig": sign(key, ts, nonce, raw), "user-agent": "herdr-mcp-admin/1",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except ValueError:
            return e.code, {"error": e.reason}


def show(grants: list[dict]) -> None:
    if not grants:
        print("  (no grants)")
    for g in grants:
        print(f"  {g['grant_id']}  client={g['client_id']}  scope={','.join(g['scope'])}"
              f"  created={g['created_at']}  expires={g['expires_at'] or 'never'}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=["list", "revoke"])
    ap.add_argument("grant_id", nargs="?")
    ap.add_argument("--user", default="tnt@teamthurber.com")
    ap.add_argument("--apply", action="store_true", help="revoke: actually revoke (default is a dry run)")
    a = ap.parse_args(argv)
    key = ingest_key()
    if not key:
        print("HERDR_MCP_INGEST_KEY not found (env or ~/.config/op/launchd-secrets.env)", file=sys.stderr)
        return 2
    status, listed = call(key, {"op": "list", "user": a.user})
    if status != 200:
        print(f"list failed: HTTP {status} {listed.get('error')}", file=sys.stderr)
        return 1
    print(f"grants for {a.user} on {URL}:")
    show(listed["grants"])
    if a.op == "list":
        return 0
    if not a.grant_id:
        ap.error("revoke needs a GRANT_ID (from `list`)")
    if a.grant_id not in {g["grant_id"] for g in listed["grants"]}:
        print(f"no such grant: {a.grant_id}", file=sys.stderr)
        return 1
    if not a.apply:
        print(f"DRY RUN — would revoke {a.grant_id}. Re-run with --apply.")
        return 0
    status, out = call(key, {"op": "revoke", "user": a.user, "grant_id": a.grant_id})
    if status != 200:
        print(f"revoke failed: HTTP {status} {out.get('error')}", file=sys.stderr)
        return 1
    print(f"revoked {out['revoked']}")
    print("===== VERIFY =====")
    status, after = call(key, {"op": "list", "user": a.user})
    gone = status == 200 and a.grant_id not in {g["grant_id"] for g in after["grants"]}
    show(after.get("grants", []))
    print("OK  grant is gone" if gone else "FAIL  grant still listed (KV listing can lag ~60 s; re-run list)")
    return 0 if gone else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
