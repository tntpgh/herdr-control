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
  chrome-relay.py --ensure     launchd tick: start it in the background if it is
                               not running, then close omp-profile Chromes that
                               had no CDP client on two ticks in a row. Never
                               opens a window otherwise.
  chrome-relay.py --status [--json]
                               report; --json is what remote-mcp/publisher.py
                               syncs to Zero (no paths, URLs or account names)
  chrome-relay.py --pause HOURS | --resume
                               stop / restart --ensure (you quit Chrome on purpose)

Exit 0 = real Chrome running, no extension disabled or missing, and the relay
is not "no-extension" (relay "down" just means no omp session has started it).
Extension state is "unknown" when run from launchd (see extensions()).
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
STATE = HOME / ".local/state/herdr"
IDLE_FILE = STATE / "chrome-relay-idle.json"   # strays seen idle last tick
PAUSE_FILE = STATE / "chrome-relay.pause"      # epoch seconds the pause ends
PROFILE = os.environ.get("CHROME_PROFILE", "Profile 1")
RELAY_PORT = int(os.environ.get("OMP_RELAY_PORT", "9224"))
MIN_STRAY_AGE_S = 120  # never touch a browser omp may still be connecting to
# Chrome Web Store IDs are fixed; the relay's unpacked ID depends on its path,
# so it is matched by path instead.
STORE_IDS = {"1password": "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "chatgpt": "hehggadaopoacecdllhhajmbjkdcmajg"}
UDD_FLAG = r"(?:^| )--user-data-dir="


def chrome_kind(args: str) -> str | None:
    """real | omp | None (another data dir). `ps` joins argv with spaces and the
    default data dir has spaces in it, so match known prefixes, never split."""
    if not re.search(UDD_FLAG, args):
        return "real"
    if re.search(UDD_FLAG + rf"{re.escape(str(UDD))}/?(?: |$)", args):
        return "real"
    if re.search(UDD_FLAG + re.escape(f"{OMP_PROFILES}/"), args):
        return "omp"
    return None


def etime_s(etime: str) -> int:
    """ps etime `[[dd-]hh:]mm:ss` -> seconds."""
    days, _, hms = etime.strip().rpartition("-")
    parts = [int(p) for p in hms.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return (int(days) if days else 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def omp_cdp_port(args: str, started_at: float) -> int | None:
    m = re.search(r"--remote-debugging-port=(\d+)", args)
    if m and m.group(1) != "0":
        return int(m.group(1))
    # Port 0: Chrome writes the chosen one into the profile. omp profile names
    # have no spaces, so the dir ends at the next space. The profile dir is
    # persistent, so a file older than this process is a previous run's.
    m = re.search(UDD_FLAG + rf"({re.escape(str(OMP_PROFILES))}/\S+)", args)
    try:
        f = Path(m.group(1)) / "DevToolsActivePort" if m else None
        if f is None or f.stat().st_mtime < started_at - 1:
            return None
        return int(f.read_text().split()[0])
    except (OSError, IndexError, ValueError):
        return None


def chrome_mains() -> list[dict]:
    """This user's main Chrome processes (helpers live under Frameworks/)."""
    out = subprocess.run(["ps", "-x", "-U", str(os.getuid()), "-o", "pid=,etime=,lstart=,args="],
                         capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        # pid, etime, then lstart is always 5 tokens ("Thu Oct  1 22:19:57 2026").
        f = line.split(None, 7)
        if len(f) < 8:
            continue
        args = f[7]
        if args == BIN or args.startswith(BIN + " "):
            rows.append({"pid": int(f[0]), "age_s": etime_s(f[1]), "lstart": " ".join(f[2:7]), "args": args})
    return rows


def singleton_pid() -> int | None:
    """Chrome's own lock on the default data dir: SingletonLock -> 'host-<pid>'.
    Catches a real Chrome that `ps` matching missed (other bundle path)."""
    try:
        pid = int(os.readlink(UDD / "SingletonLock").rsplit("-", 1)[1])
        comm = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout
        return pid if comm.strip().endswith("/Google Chrome") else None  # a stale lock's pid may be reused
    except (OSError, IndexError, ValueError):
        return None


def classify() -> tuple[int | None, list[dict]]:
    real, strays, now = None, [], time.time()
    for p in chrome_mains():
        kind = chrome_kind(p["args"])
        if kind == "real":
            real = p["pid"]
        elif kind == "omp":
            strays.append({"pid": p["pid"], "age_s": p["age_s"], "lstart": p["lstart"],
                           "cdp_port": omp_cdp_port(p["args"], now - p["age_s"])})
    for s in strays:
        s["cdp_clients"] = cdp_clients(s["pid"], s["cdp_port"])
    return real or singleton_pid(), strays


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


def extensions(relay: str) -> dict[str, str]:
    """enabled | disabled | missing | unknown, from the profile's preference
    files. Under launchd those files are unreadable (macOS app-data protection:
    PermissionError, measured 2026-10-02; the Terminal has Full Disk Access,
    the LaunchAgent's python does not), so states are "unknown" there, except
    omp_relay, which a connected relay proves enabled."""
    settings: dict = {}
    readable = False
    for name in ("Preferences", "Secure Preferences"):
        try:
            doc = json.loads((UDD / PROFILE / name).read_text())
        except (OSError, ValueError):
            continue
        readable = True
        for ext_id, v in (doc.get("extensions", {}).get("settings") or {}).items():
            settings.setdefault(ext_id, {}).update(v)

    def state(v: dict | None) -> str:
        if not readable:
            return "unknown"
        if not v:
            return "missing"
        disabled = v.get("disable_reasons") or v.get("state") == 0
        return "disabled" if disabled else "enabled"

    relay_ext = next((v for v in settings.values()
                      if v.get("path") and Path(v["path"]).expanduser() == RELAY_EXT_DIR), None)
    out = {"omp_relay": state(relay_ext), **{k: state(settings.get(i)) for k, i in STORE_IDS.items()}}
    if relay == "connected":
        out["omp_relay"] = "enabled"
    return out


def ext_ok(ext: dict[str, str]) -> bool:
    """No evidence of a lost extension (unknown is not evidence)."""
    return all(v in ("enabled", "unknown") for v in ext.values())


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
    """SIGTERM an omp-profile Chrome only when it is older than MIN_STRAY_AGE_S
    and had a known CDP port with no client on this tick AND the previous one
    (same pid and start time, so pid reuse cannot match)."""
    try:
        before = json.loads(IDLE_FILE.read_text())
    except (OSError, ValueError):
        before = {}
    idle_now = {}
    for s in strays:
        idle = s["cdp_port"] is not None and not s["cdp_clients"] and s["age_s"] >= MIN_STRAY_AGE_S
        if not idle:
            continue
        key = str(s["pid"])
        if before.get(key) != s["lstart"]:
            idle_now[key] = s["lstart"]
            print(f"stray omp Chrome pid={key} idle; closing next tick if still idle")
            continue
        try:
            os.kill(s["pid"], signal.SIGTERM)
            print(f"stray omp Chrome pid={key} closed (no CDP client on two ticks)")
        except ProcessLookupError:
            pass
    STATE.mkdir(parents=True, exist_ok=True)
    IDLE_FILE.write_text(json.dumps(idle_now))


def paused_until() -> float | None:
    try:
        until = float(PAUSE_FILE.read_text())
    except (OSError, ValueError):
        return None
    return until if until > time.time() else None


def report(real: int | None, strays: list[dict]) -> dict:
    relay = relay_state()
    ext = extensions(relay)
    return {
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "real_chrome_running": real is not None,
        "real_chrome_pid": real,
        "relay": relay,
        "extensions": ext,
        "stray_omp_chromes": len(strays),
        "healthy": real is not None and relay != "no-extension" and ext_ok(ext),
    }


def main(argv: list[str]) -> int:
    if argv[:1] == ["--pause"] and len(argv) == 2:
        STATE.mkdir(parents=True, exist_ok=True)
        until = time.time() + float(argv[1]) * 3600
        PAUSE_FILE.write_text(str(until))
        print(f"--ensure paused until {datetime.fromtimestamp(until).isoformat(timespec='minutes')}")
        return 0
    if argv == ["--resume"]:
        PAUSE_FILE.unlink(missing_ok=True)
        print("--ensure resumed")
        return 0
    unknown = set(argv) - {"--ensure", "--status", "--json"}
    if unknown or ("--ensure" in argv and "--status" in argv):
        print(__doc__, file=sys.stderr)
        return 2
    if not (UDD / PROFILE).is_dir():
        print(f"no Chrome profile dir: {UDD / PROFILE}", file=sys.stderr)
        return 2

    real, strays = classify()
    if "--ensure" in argv:
        if (until := paused_until()) is not None:
            print(f"paused until {datetime.fromtimestamp(until).isoformat(timespec='minutes')}; nothing done")
            return 0
        if real is None:  # real Chrome first, so a stray never was the only one
            real = launch(background=True)
            print(f"real Chrome was not running; launched pid={real}")
        close_idle(strays)
        real, strays = classify()
    elif "--status" not in argv:
        real = launch(background=False)  # opens a window, launching if needed

    r = report(real, strays)
    # --ensure's exit is launchd's "last exit code", which audit_launchd.py
    # alarms on: fail it for a dead Chrome or a lost extension, never for the
    # relay socket, which is still handshaking for a few seconds after launch.
    ok = r["healthy"] if "--ensure" not in argv else (r["real_chrome_running"] and ext_ok(r["extensions"]))
    if "--json" in argv:
        print(json.dumps(r))
    elif "--ensure" not in argv or not ok:
        print(f"real Chrome: {'pid=' + str(real) if real else 'NOT running'} profile='{PROFILE}'")
        print(f"relay: {r['relay']} (:{RELAY_PORT})")
        print("extensions: " + ", ".join(f"{k}={v}" for k, v in r["extensions"].items()))
        if (until := paused_until()) is not None:
            print(f"--ensure paused until {datetime.fromtimestamp(until).isoformat(timespec='minutes')}")
        for s in strays:
            print(f"stray omp Chrome pid={s['pid']} age={s['age_s']}s cdp={s['cdp_port']} "
                  f"clients={s['cdp_clients'] or 'none'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
