#!/usr/bin/env python3
"""chrome-relay.py — keep Terrence's REAL Chrome up for omp and Zero.

The real Chrome is the default user-data-dir, profile "Profile 1". It carries
the three extensions the fleet depends on:

  omp_relay  OMP Browser Relay (unpacked from ~/.omp/browser-relay/extension);
             omp's `browser.open({app: {relay: true}})` drives tabs through it
  1password  1Password
  chatgpt    ChatGPT (Zero operates through it)

The trap this exists for (2026-10-02): `browser.open({app: {path: ".../Google
Chrome"}})` makes omp launch the SAME app bundle with an empty profile under
~/.omp/browser-profiles/ (no account, no extensions, --no-startup-window), and
that process outlives the session. When the real Chrome is not running, a Dock
click opens a window in THAT instance: "signed out, extensions gone".
`open -na` with no --user-data-dir always lands on the default data dir, so it
cannot be captured by a stray.

  chrome-relay.py              open a window in the real Chrome (launch if needed)
  chrome-relay.py --ensure     launchd tick: launch it in the background only if
                               not running; close omp-profile Chromes nobody is
                               attached to. Never opens a window otherwise.
  chrome-relay.py --status [--json]
                               report; --json is what remote-mcp/publisher.py
                               syncs to Zero (no paths, URLs or account names)

Exit 0 = real Chrome running, all three extensions enabled, and the relay is
not "no-extension" (relay "down" just means no omp session has started it).
--ensure ignores the relay: it is still handshaking right after a launch.
Env: CHROME_PROFILE (default "Profile 1"), OMP_RELAY_PORT (default 9224).
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

APP = "/Applications/Google Chrome.app"
BIN = f"{APP}/Contents/MacOS/Google Chrome"
HOME = Path.home()
UDD = HOME / "Library/Application Support/Google/Chrome"
OMP_PROFILES = HOME / ".omp/browser-profiles"
RELAY_EXT_DIR = HOME / ".omp/browser-relay/extension"
PROFILE = os.environ.get("CHROME_PROFILE", "Profile 1")
RELAY_PORT = int(os.environ.get("OMP_RELAY_PORT", "9224"))
# Chrome Web Store IDs are fixed; the relay's unpacked ID depends on its path,
# so it is matched by path instead.
STORE_IDS = {"1password": "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "chatgpt": "hehggadaopoacecdllhhajmbjkdcmajg"}


def chrome_kind(args: str) -> str | None:
    """real | omp | None (another data dir). `ps` joins argv with spaces and the
    default data dir has spaces in it, so match known prefixes, never split."""
    if "--user-data-dir=" not in args:
        return "real"
    if re.search(rf"--user-data-dir={re.escape(str(UDD))}/?(?: |$)", args):
        return "real"
    if f"--user-data-dir={OMP_PROFILES}/" in args:
        return "omp"
    return None


def omp_cdp_port(args: str) -> int | None:
    m = re.search(r"--remote-debugging-port=(\d+)", args)
    if m and m.group(1) != "0":
        return int(m.group(1))
    # Port 0: Chrome writes the chosen one into the profile. omp profile names
    # have no spaces, so the dir ends at the next space.
    m = re.search(rf"--user-data-dir=({re.escape(str(OMP_PROFILES))}/\S+)", args)
    try:
        return int((Path(m.group(1)) / "DevToolsActivePort").read_text().split()[0]) if m else None
    except (OSError, IndexError, ValueError):
        return None


def chrome_mains() -> list[tuple[int, str]]:
    """Main Chrome processes; helpers live under Frameworks/, a different path."""
    out = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        pid, _, args = line.strip().partition(" ")
        if args == BIN or args.startswith(BIN + " "):
            rows.append((int(pid), args))
    return rows


def classify() -> tuple[int | None, list[dict]]:
    real, strays = None, []
    for pid, args in chrome_mains():
        kind = chrome_kind(args)
        if kind == "real":
            real = pid
        elif kind == "omp":
            strays.append({"pid": pid, "cdp_port": omp_cdp_port(args)})
    for s in strays:
        s["cdp_clients"] = cdp_clients(s["pid"], s["cdp_port"])
    return real, strays


def cdp_clients(pid: int, port: int | None) -> list[int]:
    """PIDs holding an established connection to this Chrome's CDP port."""
    if not port:
        return []
    out = subprocess.run(["lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:ESTABLISHED"],
                         capture_output=True, text=True).stdout
    return sorted({int(p) for p in out.split()} - {pid})


def relay_state() -> str:
    """omp's own probe: /json/version is 200 once the extension is attached,
    503 while the relay runs without it; unreachable = no omp relay running."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{RELAY_PORT}/json/version", timeout=2):
            return "connected"
    except urllib.error.HTTPError as e:
        return "no-extension" if e.code == 503 else f"http-{e.code}"
    except (urllib.error.URLError, OSError):
        return "down"


def extensions() -> dict[str, str]:
    """enabled | disabled | missing, from the profile's own preference files."""
    settings: dict = {}
    for name in ("Preferences", "Secure Preferences"):
        try:
            doc = json.loads((UDD / PROFILE / name).read_text())
        except (OSError, ValueError):
            continue
        for ext_id, v in (doc.get("extensions", {}).get("settings") or {}).items():
            settings.setdefault(ext_id, {}).update(v)

    def state(v: dict | None) -> str:
        if not v:
            return "missing"
        disabled = v.get("disable_reasons") or v.get("state") == 0
        return "disabled" if disabled else "enabled"

    relay = next((v for v in settings.values()
                  if v.get("path") and Path(v["path"]).expanduser() == RELAY_EXT_DIR), None)
    return {"omp_relay": state(relay), **{k: state(settings.get(i)) for k, i in STORE_IDS.items()}}


def launch(background: bool) -> int | None:
    subprocess.run(["open", "-gna" if background else "-na", APP, "--args", f"--profile-directory={PROFILE}"],
                   check=True)
    for _ in range(30):
        real, _ = classify()
        if real:
            return real
        time.sleep(0.5)
    return None


def close_idle(strays: list[dict]) -> None:
    for s in strays:
        # Unknown port = cannot prove nobody is driving it, so it stays.
        if s["cdp_port"] is None or s["cdp_clients"]:
            print(f"stray omp Chrome pid={s['pid']} kept: cdp={s['cdp_port']} clients={s['cdp_clients'] or 'unknown'}")
            continue
        try:
            os.kill(s["pid"], signal.SIGTERM)
            print(f"stray omp Chrome pid={s['pid']} closed (no CDP client)")
        except ProcessLookupError:
            pass


def report(real: int | None, strays: list[dict]) -> dict:
    ext = extensions()
    relay = relay_state()
    return {
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "real_chrome_running": real is not None,
        "real_chrome_pid": real,
        "relay": relay,
        "extensions": ext,
        "stray_omp_chromes": len(strays),
        "healthy": real is not None and relay != "no-extension" and all(v == "enabled" for v in ext.values()),
    }


def main(argv: list[str]) -> int:
    unknown = set(argv) - {"--ensure", "--status", "--json"}
    if unknown or ("--ensure" in argv and "--status" in argv):
        print(__doc__, file=sys.stderr)
        return 2
    if not (UDD / PROFILE).is_dir():
        print(f"no Chrome profile dir: {UDD / PROFILE}", file=sys.stderr)
        return 2

    real, strays = classify()
    if "--ensure" in argv:
        close_idle(strays)
        if real is None:
            real = launch(background=True)
            print(f"real Chrome was not running; launched pid={real}")
        real, strays = classify()
    elif "--status" not in argv:
        real = launch(background=False)  # opens a window, launching if needed

    r = report(real, strays)
    # --ensure's exit is launchd's "last exit code", which audit_launchd.py
    # alarms on: fail it for a dead Chrome or a lost extension, never for the
    # relay socket, which is still handshaking for a few seconds after launch.
    ok = r["healthy"] if "--ensure" not in argv else (
        r["real_chrome_running"] and all(v == "enabled" for v in r["extensions"].values()))
    if "--json" in argv:
        print(json.dumps(r))
    elif "--ensure" not in argv or not ok:
        print(f"real Chrome: {'pid=' + str(real) if real else 'NOT running'} profile='{PROFILE}'")
        print(f"relay: {r['relay']} (:{RELAY_PORT})")
        print("extensions: " + ", ".join(f"{k}={v}" for k, v in r["extensions"].items()))
        for s in strays:
            print(f"stray omp Chrome pid={s['pid']} cdp={s['cdp_port']} clients={s['cdp_clients'] or 'none'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
