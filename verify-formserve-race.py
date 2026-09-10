#!/usr/bin/env python3
"""verify-formserve-race.py — a human's decision reaches the agent exactly once,
from whichever surface recorded it.

Two-model review, 2026-09-09: the claim-once primitive protected the RECORD but
not the outcome the agent saw. Three defects, each a case here:

  1. formserve's port sent 200 before claiming, so a submit that LOST the race
     to the hub was still printed and delivered to the waiting agent as the
     human's answer - a contradictory decision, with the record correct.
  2. When only the hub answered, the port process waited out its whole timeout
     and then reported "still unanswered" over a recorded human decision.
  3. The hub's expiry was presentation-only: record_answer() never read
     expires_at, so a form whose original server had died hours ago was still
     answerable via the hub copy.

Real formserve subprocesses on real loopback ports, real hub functions against
a temporary HERDR_STATE_ROOT. Delivery is captured by pointing --deliver at a
stub herdr-deliver.sh that records what it was asked to deliver.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

passed = failed = 0


def check(label: str, got, want) -> None:
    global passed, failed
    if got == want:
        passed += 1; print(f"  ok    {label}")
    else:
        failed += 1; print(f"  FAIL  {label} (expected {want!r}, got {got!r})")


def post(url: str, payload: dict) -> tuple[int, str]:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def token_of(record: Path) -> str:
    return json.loads(record.read_text())["token"]


with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    state = root / "state"; (state / "forms").mkdir(parents=True)
    env = {**os.environ, "HERDR_STATE_ROOT": str(state), "HOME": str(root)}
    # A herdr-deliver.sh stub next to a COPY of formserve.py, so --deliver is
    # observable without a live herdr. formserve resolves HERE from its own path.
    work = root / "hc"; work.mkdir()
    shutil.copy(HERE / "formserve.py", work / "formserve.py")
    shutil.copytree(HERE / "lib", work / "lib")
    (work / "preview.sh").write_text("#!/bin/bash\nexit 0\n")
    delivered = root / "delivered.jsonl"
    # formserve passes the answer TEXT as the second argument (no stdin); a stub
    # that read stdin would block forever on the inherited pipe.
    (work / "herdr-deliver.sh").write_text(
        "#!/bin/bash\n" f"printf '%s\\n' \"$2\" >> '{delivered}'\n" "exit 0\n")
    for f in ("preview.sh", "herdr-deliver.sh"):
        os.chmod(work / f, 0o755)
    form = root / "q.html"
    form.write_text("<html><body><h1>merge or hold?</h1><form><input name='pick' value='merge'></form></body></html>")

    def start_port(timeout: int = 60, deliver: str = "w9:p9") -> tuple[subprocess.Popen, Path, str]:
        p = subprocess.Popen([sys.executable, str(work / "formserve.py"), str(form), "--timeout", str(timeout),
                              "--deliver", deliver, "--no-open"],
                             cwd=str(work), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        rec = None
        for _ in range(100):
            time.sleep(0.1)
            recs = sorted((state / "forms").glob("*.json"), key=lambda x: x.stat().st_mtime)
            if recs and recs[-1].stat().st_mtime > time.time() - 5:
                rec = recs[-1]
                try:
                    url = json.loads(rec.read_text())["url"]; break
                except (json.JSONDecodeError, KeyError):
                    continue
        assert rec is not None, "formserve never registered"
        return p, rec, url

    # ---- hub functions against the same state root ------------------------
    os.environ["HERDR_STATE_ROOT"] = str(state)
    import importlib.util
    spec = importlib.util.spec_from_file_location("hub", HERE / "hub.py")
    hub = importlib.util.module_from_spec(spec); spec.loader.exec_module(hub)
    hub.notify_owner = lambda row: None           # no live herdr in a test

    print("== hub answers first: the port's later submit LOSES, and nothing is delivered ==")
    p, rec, url = start_port()
    tok = token_of(rec)
    code, body = hub.record_answer(rec.stem, {"pick": "merge", "__formserve_token": tok})
    check("hub records the first answer (200)", code, 200)
    code2, body2 = post(url + "submit", {"pick": "hold", "__formserve_token": tok})
    check("port submit after the hub -> 409, not 200", code2, 409)
    check("409 body names the canonical answer", json.loads(body2).get("answers"), {"pick": "merge"})
    out, err = p.communicate(timeout=30)
    check("port process exits 0 having noticed the hub answer", p.returncode, 0)
    check("port prints the HUB's answer, not the loser", json.loads(out or "{}"), {"pick": "merge"})
    check("delivered payload is the winner", "merge" in (delivered.read_text() if delivered.exists() else ""), True)
    check("the losing 'hold' was never delivered", "hold" in (delivered.read_text() if delivered.exists() else ""), False)
    check("record unchanged", json.loads(rec.read_text())["answers"], {"pick": "merge"})
    if delivered.exists(): delivered.unlink()

    print("== port answers first: the hub's later submit LOSES ==")
    p, rec, url = start_port()
    tok = token_of(rec)
    code, body = post(url + "submit", {"pick": "hold", "__formserve_token": tok})
    check("port submit wins (200)", code, 200)
    out, err = p.communicate(timeout=30)
    check("port delivers its own winning answer", json.loads(out or "{}"), {"pick": "hold"})
    code2, body2 = hub.record_answer(rec.stem, {"pick": "merge", "__formserve_token": tok})
    check("hub submit after the port -> 409", code2, 409)
    check("record holds the port's answer", json.loads(rec.read_text())["answers"], {"pick": "hold"})
    if delivered.exists(): delivered.unlink()

    print("== hub enforces the deadline under the lock ==")
    p, rec, url = start_port(timeout=2)
    tok = token_of(rec)
    out, err = p.communicate(timeout=30)
    check("port expired with no answer (exit 1)", p.returncode, 1)
    check("record is expired, not answered", json.loads(rec.read_text())["status"], "expired")
    code, body = hub.record_answer(rec.stem, {"pick": "merge", "__formserve_token": tok})
    check("hub refuses to answer an expired form", code in (409, 410), True)
    # and an OPEN record whose expires_at has passed (original server died)
    stale = state / "forms" / "stale.json"
    stale.write_text(json.dumps({"id": "stale", "status": "open", "token": "t", "expires_at": 1,
                                 "title": "old", "form_path": str(form), "url": url}))
    code, body = hub.record_answer("stale", {"pick": "merge", "__formserve_token": "t"})
    check("open-but-past-deadline record -> 410", code, 410)
    check("and it was not answered", json.loads(stale.read_text())["status"], "open")

print()
print(f"passed={passed} failed={failed}")
sys.exit(1 if failed else 0)
