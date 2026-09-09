#!/usr/bin/env python3
"""verify-record-store.py — a decision may be answered exactly once.

Both surfaces that can answer a formserve decision (the form's own port and the
hub service) used read → check status → truncating write, which cannot deliver
the "first writer wins" its own comment promised. These cases pin the behaviour
that replaced it, and each one FAILS against that previous implementation —
they are regressions, not decoration.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from record_store import NotClaimable, claim_and_update, write_atomic  # noqa: E402

passed = failed = 0


def check(label: str, got, want) -> None:
    global passed, failed
    if got == want:
        passed += 1
        print(f"  ok    {label}")
    else:
        failed += 1
        print(f"  FAIL  {label} (expected {want!r}, got {got!r})")


def new_form(d: Path, form_id: str = "f1") -> Path:
    p = d / f"{form_id}.json"
    write_atomic(p, {"id": form_id, "status": "open", "title": "merge or hold?"})
    return p


# Two REAL processes, as in production (the hub service and a formserve port
# are separate interpreters — an in-process thread race would not exercise the
# advisory lock across processes at all). They synchronise on a wall-clock
# start so both hit the record in the same instant.
RACER = """
import json, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[4])
from record_store import NotClaimable, claim_and_update
path, via, start = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
while time.time() < start:
    pass
try:
    claim_and_update(path, lambda r: {**r, "status": "answered",
                                      "answers": {"pick": via}, "answered_via": via})
    print("won")
except NotClaimable as e:
    print("lost:" + str(e.state))
"""


with tempfile.TemporaryDirectory() as td:
    d = Path(td)

    print("== a second answer cannot overwrite the first ==")
    p = new_form(d)
    claim_and_update(p, lambda r: {**r, "status": "answered", "answers": {"pick": "merge"},
                                   "answered_via": "port"})
    try:
        claim_and_update(p, lambda r: {**r, "status": "answered", "answers": {"pick": "hold"},
                                       "answered_via": "hub"})
        check("second write refused", "accepted", "NotClaimable")
    except NotClaimable as e:
        check("second write refused", e.state, "answered")
    row = json.loads(p.read_text())
    check("the first answer survived", row["answers"]["pick"], "merge")
    check("answered_via is not rewritten", row["answered_via"], "port")

    print("== two surfaces racing: exactly one wins ==")
    # Repeated, because a race that passes once may just have been serialised
    # by luck — the pre-fix implementation loses this on some runs, not all.
    won = lost = 0
    for i in range(10):
        p = new_form(d, f"race{i}")
        start = time.time() + 0.25
        procs = [subprocess.Popen([sys.executable, "-c", RACER, str(p), via, str(start),
                                   str(HERE / "lib")], stdout=subprocess.PIPE, text=True)
                 for via in ("port", "hub")]
        outs = [x.communicate()[0].strip() for x in procs]
        won += sum(1 for o in outs if o == "won")
        lost += sum(1 for o in outs if o.startswith("lost"))
        row = json.loads(p.read_text())
        if row["answers"]["pick"] != row["answered_via"]:
            failed += 1
            print(f"  FAIL  round {i}: answer {row['answers']['pick']} recorded as "
                  f"{row['answered_via']} — a surface overwrote the other's answer")
    check("10 races: exactly one winner each", (won, lost), (10, 10))
    check("every record still parses and is self-consistent", failed, 0)

    print("== expiry may stamp an OPEN form, never an answered one ==")
    # The old guard read `status != "open" and fields.status != "expired"`, which
    # let an expiry sweep overwrite a REAL answer with "expired" — reporting a
    # human's decision as if it never came.
    p = new_form(d, "exp")
    claim_and_update(p, lambda r: {**r, "status": "expired"})
    check("open form expires", json.loads(p.read_text())["status"], "expired")

    p = new_form(d, "exp2")
    claim_and_update(p, lambda r: {**r, "status": "answered", "answers": {"pick": "merge"},
                                   "answered_via": "port"})
    try:
        claim_and_update(p, lambda r: {**r, "status": "expired"})
        check("expiry refused on an answered form", "accepted", "NotClaimable")
    except NotClaimable as e:
        check("expiry refused on an answered form", e.state, "answered")
    check("the answer is still the answer", json.loads(p.read_text())["status"], "answered")

    print("== a killed writer never leaves a half-written decision ==")
    p = new_form(d, "crash")
    before = p.read_text()
    code = (
        "import sys, os, signal, fcntl, tempfile;"
        f"p={str(p)!r};"
        "lock=open(p+'.lock','a+');fcntl.flock(lock, fcntl.LOCK_EX);"
        "fd,tmp=tempfile.mkstemp(dir=os.path.dirname(p), prefix='.crash.', suffix='.tmp');"
        "os.write(fd, b'{\"partial\":');"
        "os.kill(os.getpid(), signal.SIGKILL)"
    )
    subprocess.run([sys.executable, "-c", code], capture_output=True)
    check("record byte-identical after SIGKILL mid-write", p.read_text(), before)
    check("still parses", json.loads(p.read_text())["status"], "open")
    check("and it is still claimable afterwards",
          claim_and_update(p, lambda r: {**r, "status": "answered"})["status"], "answered")

    print("== a corrupt record is reported, not silently reset ==")
    p = d / "corrupt.json"
    p.write_text("{not json")
    try:
        claim_and_update(p, lambda r: r)
        check("corrupt record raises", "silent", "JSONDecodeError")
    except json.JSONDecodeError:
        check("corrupt record raises", "JSONDecodeError", "JSONDecodeError")

print("\n-----")
print(f"passed={passed} failed={failed}")
print("PASS" if failed == 0 else "FAIL")
sys.exit(1 if failed else 0)
