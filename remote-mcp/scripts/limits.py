#!/usr/bin/env python3
"""Show or change how many messages herdr-mcp accepts (per user, all clients).

    python3 remote-mcp/scripts/limits.py show
    python3 remote-mcp/scripts/limits.py set --per-hour 120 --per-minute 10 --for 4h --reason "release day" [--apply]
    python3 remote-mcp/scripts/limits.py set --per-hour 60 --per-minute 8 --until-reset --reason "new normal" [--apply]
    python3 remote-mcp/scripts/limits.py reset [--apply]

Defaults are 5/minute and 30/hour. `--for` makes a temporary boost that lapses
back to the defaults on its own (up to 7d); `--until-reset` keeps it until
`reset`. The Worker refuses anything above its ceiling (30/minute, 300/hour);
raising the ceiling is a code change. set/reset are dry runs unless --apply.
Takes effect on the next send_message; no redeploy. Every call is audited
(admin_limits_get / _set / _reset). Signed like grants.py.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grants import call, ingest_key  # noqa: E402

PATH = "/admin/limits"


def minutes(spec: str) -> int:
    m = re.fullmatch(r"(\d+)\s*([mhd])", spec.strip())
    if not m:
        raise argparse.ArgumentTypeError("use e.g. 90m, 4h, 2d")
    return int(m[1]) * {"m": 1, "h": 60, "d": 1440}[m[2]]


def show(out: dict) -> None:
    lim = out["limits"]
    until = f" until {lim['until']}" if lim["until"] else (" until reset" if lim["source"] == "override" else "")
    why = f" ({lim['reason']})" if lim.get("reason") else ""
    print(f"  in force: {lim['per_minute']}/minute, {lim['per_hour']}/hour  [{lim['source']}{until}]{why}")
    print(f"  defaults: {out['defaults']['per_minute']}/minute, {out['defaults']['per_hour']}/hour;"
          f"  ceiling: {out['max']['per_minute']}/minute, {out['max']['per_hour']}/hour")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=["show", "set", "reset"])
    ap.add_argument("--per-hour", type=int)
    ap.add_argument("--per-minute", type=int)
    span = ap.add_mutually_exclusive_group()
    span.add_argument("--for", dest="span", type=minutes, help="temporary: 90m, 4h, 2d (max 7d)")
    span.add_argument("--until-reset", action="store_true")
    ap.add_argument("--reason", default="")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    if a.op == "set" and (a.per_hour is None or a.per_minute is None or not a.reason.strip()
                          or (a.span is None and not a.until_reset)):
        ap.error("set needs --per-hour, --per-minute, --reason, and --for or --until-reset")
    key = ingest_key()
    if not key:
        print("HERDR_MCP_INGEST_KEY not found (env or ~/.config/op/launchd-secrets.env)", file=sys.stderr)
        return 2
    status, out = call(key, {"op": "get"}, PATH)
    if status != 200:
        print(f"get failed: HTTP {status} {out.get('error')}", file=sys.stderr)
        return 1
    print("now:")
    show(out)
    if a.op == "show":
        return 0
    body = {"op": "reset"} if a.op == "reset" else {
        "op": "set", "per_minute": a.per_minute, "per_hour": a.per_hour,
        "minutes": None if a.until_reset else a.span, "reason": a.reason.strip()}
    if not a.apply:
        print(f"DRY RUN — would send {body}. Re-run with --apply.")
        return 0
    status, out = call(key, body, PATH)
    if status != 200:
        print(f"{a.op} failed: HTTP {status} {out.get('error')} {out.get('max', '')}", file=sys.stderr)
        return 1
    print("===== VERIFY =====")
    status, after = call(key, {"op": "get"}, PATH)
    show(after)
    want = (out["limits"]["per_minute"], out["limits"]["per_hour"])
    good = status == 200 and (after["limits"]["per_minute"], after["limits"]["per_hour"]) == want
    print("OK  in force" if good else "FAIL  read-back differs")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
