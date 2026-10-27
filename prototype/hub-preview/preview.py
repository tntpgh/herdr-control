#!/usr/bin/env python3
"""Staged preview of the hub look, over synthetic data, on a spare loopback port.

    python3 prototype/hub-preview/preview.py                 # new look, 127.0.0.1:8611
    python3 prototype/hub-preview/preview.py --baseline      # the hub as of BASELINE_REV, 127.0.0.1:8612
    python3 prototype/hub-preview/preview.py --herdr-down    # same, with herdr's subscription simulated down
    python3 prototype/hub-preview/preview.py --snapshot DIR  # render every page to DIR and exit (check.py)

Read-only by construction:
- every state/secret/checkout path env var points into a fresh temp dir BEFORE
  hub.py is imported, so REGISTRY / FORMS_DIR / ledgers resolve there;
- hub.main() is never called: no herdr watcher, attention/mirror/ratings
  loops, deploy-drift priming (the git fetches) or stall watchdog;
- every cache and live reader is replaced by prototype/hub-preview/fixtures.py;
- every POST answers 403 and records nothing;
- refuses port 8600 and any port already in use.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE_REV = "c37ee61"  # last commit that touched hub.py before the hub_ui change
LIVE_HUB_PORT = 8600
PAGES = ["/", "/?repo=demo-app", "/herdr", "/herdr?repo=demo-infra", "/projects", "/owners", "/decisions",
         "/decisions/pv-1", "/loops", "/timeline", "/timeline?repo=demo-infra", "/search", "/kb", "/links",
         "/?json=1", "/herdr?json=1", "/projects?json=1", "/owners?json=1", "/loops?json=1", "/decisions?json=1",
         "/timeline?json=1", "/api/summary", "/api/projects", "/api/owners", "/api/panes", "/api/blocked",
         "/api/timeline", "/healthz", "/nope"]
POSTS = [("/decisions/pv-1/submit", "application/json", b'{"decision":"approve","__formserve_token":"x"}'),
         ("/loops/decide", "application/x-www-form-urlencoded", b"key=s1"),
         ("/ratings/publish", "application/json", b"{}")]


def isolate(tmp: Path) -> None:
    for key, sub in {"HERDR_STATE_ROOT": "state", "HERDR_RUN_REGISTRY": "state/runs/registry.sqlite3",
                     "HERDR_ACK_FILE": "state/runs/acked.json", "HERDR_HANDOFF_DEBT": "state/handoff-debt.jsonl",
                     "HERDR_COST_REPORT_PATH": "state/cost-report.json", "HERDR_HUB_SECRETS_ENV": "no-secrets.env",
                     "KB_DEPLOY": "kb-deploy", "KB_PYTHON": "no-python", "HERDR_TOURGUIDE_DIR": "tourguide",
                     "THURBER_OS": "thurber-os", "HERDR_CONTROL_DIR": "herdr-control",
                     "ENGINEERING_LEDGER_DIR": "ledger"}.items():
        os.environ[key] = str(tmp / sub)
    for key in ("NEON_CONNECTION_STRING", "SEARCH_SYNC_TOKEN", "DECISIONS_MIRROR_KEY"):
        os.environ.pop(key, None)
    os.environ["CONSENSUS_SEARCH_URL"] = "https://example.invalid"
    os.environ["KB_DASHBOARD_URL"] = "https://example.invalid"


def load_hub(baseline: bool, tmp: Path):
    if baseline:
        src = subprocess.run(["git", "-C", str(ROOT), "show", f"{BASELINE_REV}:hub.py"],
                             capture_output=True, text=True, check=True).stdout
        path = tmp / "hub_baseline.py"
        path.write_text(src)
        sys.path.insert(0, str(ROOT / "lib"))  # the copy's own lib/ insert points into tmp
    else:
        path = ROOT / "hub.py"
    spec = importlib.util.spec_from_file_location("hub_under_preview", path)
    hub = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hub)
    return hub


def port_free(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) != 0


def make_server(hub, port: int) -> ThreadingHTTPServer:
    class PreviewHandler(hub.Handler):
        def do_POST(self):  # noqa: N802
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                self.rfile.read(min(n, 1 << 20))
            self._send(403, "text/plain", b"preview is read-only: nothing was recorded or sent")
    return ThreadingHTTPServer(("127.0.0.1", port), PreviewHandler)


def snapshot(server: ThreadingHTTPServer, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    index = {}

    def fetch(req):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, r.headers.get("Content-Type"), r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Content-Type"), e.read()
    for i, p in enumerate(PAGES):
        status, ctype, body = fetch(base + p)
        name = f"{i:02d}.{'json' if 'json' in (ctype or '') else 'html' if 'html' in (ctype or '') else 'txt'}"
        (out / name).write_bytes(body)
        index[p] = {"status": status, "ctype": ctype, "file": name}
    for p, ctype, body in POSTS:
        status, _, resp = fetch(urllib.request.Request(base + p, data=body, method="POST", headers={"Content-Type": ctype}))
        index["POST " + p] = {"status": status, "body": resp.decode(errors="replace")[:200]}
    (out / "index.json").write_text(json.dumps(index, indent=1))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", action="store_true", help=f"serve hub.py as of {BASELINE_REV}")
    ap.add_argument("--port", type=int, help="default 8611 (new) / 8612 (baseline)")
    ap.add_argument("--herdr-down", action="store_true")
    ap.add_argument("--registry-error", action="store_true")
    ap.add_argument("--now", type=float, help="fixture clock (epoch s); default: now")
    ap.add_argument("--snapshot", type=Path, help="render every page into this dir, then exit")
    a = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="hub-preview-"))
    isolate(tmp)
    sys.path.insert(0, str(HERE))
    import fixtures  # noqa: E402
    hub = load_hub(a.baseline, tmp)
    if not str(hub.REGISTRY).startswith(str(tmp)) or not str(hub.FORMS_DIR).startswith(str(tmp)):
        raise SystemExit(f"refusing: hub state paths escaped the sandbox ({hub.REGISTRY}, {hub.FORMS_DIR})")
    fixtures.install(hub, a.now or time.time(), tmp, herdr_down=a.herdr_down, registry_error=a.registry_error)
    if a.snapshot:
        server = make_server(hub, 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        snapshot(server, a.snapshot)
        server.shutdown()
        print(f"snapshot: {len(PAGES)} pages + {len(POSTS)} POSTs -> {a.snapshot}")
        return 0
    port = a.port or (8612 if a.baseline else 8611)
    if port == LIVE_HUB_PORT or not port_free(port):
        raise SystemExit(f"refusing port {port}: it is the live hub's port or already in use")
    server = make_server(hub, port)
    print(f"hub preview ({'baseline ' + BASELINE_REV if a.baseline else 'new look'}, synthetic data, POST refused) "
          f"on http://127.0.0.1:{port}/  state sandbox: {tmp}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
