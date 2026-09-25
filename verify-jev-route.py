#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "scripts" / "jev_route.py"

class Handler(BaseHTTPRequestHandler):
    response = {}
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(self.response).encode())
    def log_message(self, *_args):
        pass

def run(response, brief="Implement parser"):
    Handler.response = response
    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env.update(TYPESAFE_API_KEY="test-key-not-a-secret", TYPESAFE_API_URL=f"http://127.0.0.1:{server.server_port}")
    result = subprocess.run([sys.executable, str(SCRIPT)], input=brief, text=True, capture_output=True, env=env)
    server.shutdown()
    return result

def run_missing_key():
    env = os.environ.copy()
    env.pop("TYPESAFE_API_KEY", None)
    return subprocess.run([sys.executable, str(SCRIPT)], input="Implement parser", text=True, capture_output=True, env=env)

def response(role="implementer", confidence=0.9, risk=0.1, model="jev-test"):
    return {"model": model, "answers": {
        "role": {"type": "choice", "choice": role, "confidence": confidence},
        "risk_high": {"type": "noul", "noul": risk},
    }}

def check(name, result, expected_zero):
    good = (result.returncode == 0) == expected_zero
    if good:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: rc={result.returncode} stderr={result.stderr.strip()}")
    return good
def main():
    checks = [
        ("valid response routes", run(response()), True),
        ("malformed response fails closed", run({"answers": {}}), False),
        ("low confidence fails closed", run(response(confidence=0.4)), False),
        ("high risk fails closed", run(response(risk=0.9)), False),
        ("approval decision is not a role", run(response(role="approve")), False),
        ("JEV underreported high-risk brief fails closed", run(response(risk=0.1), "Rotate stored credentials"), False),
        ("missing key fails closed", run_missing_key(), False),
    ]
    passed = sum(check(name, result, expected) for name, result, expected in checks)
    print(f"{passed} passed, {len(checks) - passed} failed")
    return 0 if passed == len(checks) else 1

if __name__ == "__main__":
    raise SystemExit(main())
