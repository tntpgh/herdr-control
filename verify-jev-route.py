#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "scripts" / "jev_route.py"
ROUTE = ROOT / "scripts" / "route-task.sh"
SPAWN = ROOT / "spawn-task.sh"

class Handler(BaseHTTPRequestHandler):
    response = {}
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(self.response).encode())
    def log_message(self, *_args):
        pass

def _brief_file(text):
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
    handle.write(text)
    handle.close()
    return handle.name

def run(response, brief="Implement parser", argv=None):
    Handler.response = response
    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env.update(TYPESAFE_API_KEY="test-key-not-a-secret", TYPESAFE_API_URL=f"http://127.0.0.1:{server.server_port}")
    if argv is None:
        path = _brief_file(brief)
        argv = [sys.executable, str(SCRIPT), "--brief", path]
    result = subprocess.run(argv, text=True, capture_output=True, env=env)
    server.shutdown()
    return result

def run_missing_key():
    env = os.environ.copy()
    env.pop("TYPESAFE_API_KEY", None)
    path = _brief_file("Implement parser")
    return subprocess.run([sys.executable, str(SCRIPT), "--brief", path], text=True, capture_output=True, env=env)

def response(role="implementer", confidence=0.9, risk=0.1, model="jev-test"):
    return {"model": model, "answers": {
        "role": {"type": "choice", "choice": role, "confidence": confidence},
        "risk_high": {"type": "noul", "noul": risk},
    }}

def response_with_extra_model(model):
    return response(model=model)

def run_route_task(response_body, brief="Implement parser"):
    path = _brief_file(brief)
    return run(response_body, argv=["bash", str(ROUTE), "--provider", "jev", "--brief", path])

def run_spawn_task(response_body, brief="Implement parser"):
    path = _brief_file(brief)
    return run(response_body, argv=["bash", str(SPAWN), "--route", "jev", "--brief", path, "--dry-run", str(ROOT), "tmp/jev-route-proof", "auto", "omp"])


def check(name, result, expected_zero):
    good = (result.returncode == 0) == expected_zero
    if good:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: rc={result.returncode} stderr={result.stderr.strip()}")
    return good

def check_no_leak(name, result, needle):
    good = result.returncode == 0 and needle not in result.stdout and needle not in result.stderr
    if good:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: leaked={needle in result.stdout or needle in result.stderr} rc={result.returncode} stdout={result.stdout.strip()} stderr={result.stderr.strip()}")
    return good
def main():
    checks = [
        ("valid response routes", run(response()), True),
        ("route-task --provider jev uses --brief file", run_route_task(response()), True),
        ("spawn-task --route jev --dry-run routes before worktree creation", run_spawn_task(response()), True),
        ("malformed response fails closed", run({"answers": {}}), False),
        ("low confidence fails closed", run(response(confidence=0.4)), False),
        ("high risk fails closed", run(response(risk=0.9)), False),
        ("approval decision is not a role", run(response(role="approve")), False),
        ("JEV underreported high-risk brief fails closed", run(response(risk=0.1), "Rotate stored credentials"), False),
        ("JEV underreported API key brief fails closed", run(response(risk=0.1), "Rotate the API key"), False),
        ("JEV underreported Slack/client brief fails closed", run(response(risk=0.1), "Send a Slack update to the client"), False),
        ("JEV underreported wire transfer brief fails closed", run(response(risk=0.1), "Issue a wire transfer"), False),
        ("JEV underreported remove customer brief fails closed", run(response(risk=0.1), "Remove customer records"), False),
        ("JEV underreported zero-width/live brief fails closed", run(response(risk=0.1), "Rotate se\u200bcret and ship to live"), False),
        ("JEV underreported percent-encoded brief fails closed", run(response(risk=0.1), "Rotate API%20key"), False),
        ("missing key fails closed", run_missing_key(), False),
    ]
    passed = sum(check(name, result, expected) for name, result, expected in checks)
    leak_key = "Bearer fake-key-never-print"
    leak_check = check_no_leak("provider model metadata cannot echo bearer key", run(response_with_extra_model(leak_key)), leak_key)
    passed += 1 if leak_check else 0
    total = len(checks) + 1
    print(f"{passed} passed, {total - passed} failed")
    return 0 if passed == total else 1

if __name__ == "__main__":
    raise SystemExit(main())
