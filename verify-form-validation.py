#!/usr/bin/env python3
"""verify-form-validation.py — a form's required fields are enforced server-side
on BOTH submit paths, not just assumed from the page's own script.

Incident, 2026-10-18: pilot form 20261018T071004-8741's radio was named
`pilot`, the copied template's script sent `choice`, and the saved answer was
{choice:null, confirmed:false, notes:""} — the row still flipped to
`answered`. Nothing validated that a field the HTML declared `required`
actually showed up in the payload. This suite drives the exact incident
payload, plus its neighbours, against a real formserve subprocess AND
hub.record_answer() against the same registry row, and asserts both reject it
before the status flips to `answered`.

Isolated: temp HERDR_STATE_ROOT, ephemeral port, never the live hub at :8600
and never ~/.local/state/herdr/forms.
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


def post(url: str, payload: dict) -> tuple[int, dict | str]:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read().decode()
    except urllib.error.HTTPError as e:
        code, body = e.code, e.read().decode()
    else:
        return r.status, _maybe_json(body)
    return code, _maybe_json(body)


def _maybe_json(body: str):
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body


PILOT_FORM = (
    "<html><body><h1>pilot rollout</h1>"
    "<form id='f'>"
    "<input type='radio' name='pilot' value='approve_as_written' required>"
    "<input type='radio' name='pilot' value='approve_narrower'>"
    "<input type='radio' name='pilot' value='hold'>"
    "<input type='checkbox' name='confirmed'>"
    "<textarea name='notes'></textarea>"
    "<button type='submit' form='f'>Send</button>"
    "</form>"
    "<script>document.getElementById('f').addEventListener('submit',function(e){"
    "e.preventDefault();var fd=new FormData(e.target);"
    "window.submitAnswers({pilot:fd.get('pilot'),confirmed:fd.get('confirmed')==='on',"
    "notes:(fd.get('notes')||'').trim()});});</script>"
    "</body></html>")

NO_REQUIRED_FORM = (
    "<html><body><h1>optional notes</h1>"
    "<form id='f'><textarea name='notes'></textarea>"
    "<button type='submit' form='f'>Send</button></form>"
    "<script>document.getElementById('f').addEventListener('submit',function(e){"
    "e.preventDefault();var fd=new FormData(e.target);"
    "window.submitAnswers({notes:(fd.get('notes')||'').trim()});});</script>"
    "</body></html>")


def token_of(record: Path) -> str:
    return json.loads(record.read_text())["token"]


def status_of(record: Path) -> str:
    return json.loads(record.read_text())["status"]


with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    state = root / "state"; (state / "forms").mkdir(parents=True)
    env = {**os.environ, "HERDR_STATE_ROOT": str(state), "HOME": str(root)}
    work = root / "hc"; work.mkdir()
    shutil.copy(HERE / "formserve.py", work / "formserve.py")
    shutil.copytree(HERE / "lib", work / "lib")
    (work / "preview.sh").write_text("#!/bin/bash\nexit 0\n")
    os.chmod(work / "preview.sh", 0o755)

    os.environ["HERDR_STATE_ROOT"] = str(state)
    import importlib.util
    spec = importlib.util.spec_from_file_location("hub", HERE / "hub.py")
    hub = importlib.util.module_from_spec(spec); spec.loader.exec_module(hub)
    hub.notify_owner = lambda row: None           # no live herdr in a test

    def start_port(html: str, timeout: int = 60) -> tuple[subprocess.Popen, Path, str]:
        form = root / f"form-{time.time_ns()}.html"
        form.write_text(html)
        p = subprocess.Popen([sys.executable, str(work / "formserve.py"), str(form),
                              "--timeout", str(timeout), "--no-open"],
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

    print("== schema derivation: required radio group carries its enum ==")
    pilot_form = root / "pilot-schema.html"; pilot_form.write_text(PILOT_FORM)
    from form_schema import parse_schema
    schema = parse_schema(PILOT_FORM)
    check("pilot is required", "pilot" in schema, True)
    check("pilot enum matches the radio values",
          schema.get("pilot", {}).get("enum"),
          ["approve_as_written", "approve_narrower", "hold"])
    check("confirmed (not required) is absent from the schema", "confirmed" in schema, False)

    print("== formserve /submit: each valid pilot value saves and reads back exactly ==")
    for value in ("approve_as_written", "approve_narrower", "hold"):
        p, rec, url = start_port(PILOT_FORM)
        tok = token_of(rec)
        payload = {"pilot": value, "confirmed": True, "notes": "fine"}
        code, body = post(url + "submit", {**payload, "__formserve_token": tok})
        check(f"pilot={value}: 200", code, 200)
        check(f"pilot={value}: response echoes persisted answers", body.get("answers"), payload)
        out, err = p.communicate(timeout=30)
        check(f"pilot={value}: registry row reads back exactly", json.loads(rec.read_text())["answers"], payload)
        check(f"pilot={value}: status answered", status_of(rec), "answered")

    print("== formserve /submit: each invalid shape is 400 and the row stays open ==")
    bad_payloads = {
        "missing pilot": {"confirmed": True, "notes": ""},
        "pilot:null": {"pilot": None, "confirmed": True, "notes": ""},
        "pilot: empty string": {"pilot": "", "confirmed": True, "notes": ""},
        "pilot: bogus value": {"pilot": "bogus", "confirmed": True, "notes": ""},
        "the 2026-10-18 incident payload": {"choice": None, "confirmed": False, "notes": ""},
    }
    for label, payload in bad_payloads.items():
        p, rec, url = start_port(PILOT_FORM, timeout=5)
        tok = token_of(rec)
        code, body = post(url + "submit", {**payload, "__formserve_token": tok})
        check(f"{label}: 400", code, 400)
        check(f"{label}: body is {{ok:false,error:...}}", isinstance(body, dict) and body.get("ok") is False, True)
        check(f"{label}: error names the field", "pilot" in str(body.get("error", "")), True)
        check(f"{label}: row stays open", status_of(rec), "open")
        p.terminate()
        try:
            p.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(timeout=10)

    print("== formserve /submit: {cancelled:true} is accepted without validation ==")
    p, rec, url = start_port(PILOT_FORM)
    tok = token_of(rec)
    code, body = post(url + "submit", {"cancelled": True, "__formserve_token": tok})
    check("cancelled: 200", code, 200)
    out, err = p.communicate(timeout=30)
    check("cancelled: row recorded as cancelled, not answered", status_of(rec), "cancelled")

    print("== formserve /submit: a form with no required fields behaves exactly as today ==")
    p, rec, url = start_port(NO_REQUIRED_FORM)
    tok = token_of(rec)
    code, body = post(url + "submit", {"notes": "whatever", "__formserve_token": tok})
    check("no-required-fields form: 200", code, 200)
    out, err = p.communicate(timeout=30)
    check("no-required-fields form: answered", status_of(rec), "answered")

    print("== hub.record_answer: same contract, same registry row ==")
    for value in ("approve_as_written", "approve_narrower", "hold"):
        p, rec, url = start_port(PILOT_FORM)
        tok = token_of(rec)
        p.terminate(); p.communicate(timeout=10)   # kill the port; only the hub answers now
        payload = {"pilot": value, "confirmed": True, "notes": "fine"}
        code, body = hub.record_answer(rec.stem, {**payload, "__formserve_token": tok})
        check(f"hub pilot={value}: 200", code, 200)
        check(f"hub pilot={value}: response echoes persisted answers", json.loads(body).get("answers"), payload)
        check(f"hub pilot={value}: registry row reads back exactly", json.loads(rec.read_text())["answers"], payload)

    for label, payload in bad_payloads.items():
        p, rec, url = start_port(PILOT_FORM)
        tok = token_of(rec)
        p.terminate(); p.communicate(timeout=10)
        code, body = hub.record_answer(rec.stem, {**payload, "__formserve_token": tok})
        check(f"hub {label}: 400", code, 400)
        parsed = json.loads(body)
        check(f"hub {label}: body is {{ok:false,error:...}}", parsed.get("ok") is False, True)
        check(f"hub {label}: error names the field", "pilot" in str(parsed.get("error", "")), True)
        check(f"hub {label}: row stays open", status_of(rec), "open")

    p, rec, url = start_port(PILOT_FORM)
    tok = token_of(rec)
    p.terminate(); p.communicate(timeout=10)
    code, body = hub.record_answer(rec.stem, {"cancelled": True, "__formserve_token": tok})
    check("hub cancelled: 200", code, 200)
    check("hub cancelled: row recorded as cancelled, not answered", status_of(rec), "cancelled")

    p, rec, url = start_port(NO_REQUIRED_FORM)
    tok = token_of(rec)
    p.terminate(); p.communicate(timeout=10)
    code, body = hub.record_answer(rec.stem, {"notes": "whatever", "__formserve_token": tok})
    check("hub no-required-fields form: 200", code, 200)
    check("hub no-required-fields form: answered", status_of(rec), "answered")

    print("== real negative: validate_answers itself catches the incident shape ==")
    from form_schema import validate_answers, parse_schema as _ps
    sch = _ps(PILOT_FORM)
    err = validate_answers(sch, {"choice": None, "confirmed": False, "notes": ""})
    check("validate_answers rejects the incident payload", err is not None and "pilot" in err, True)
    check("validate_answers accepts a valid payload", validate_answers(sch, {"pilot": "hold"}), None)

print()
print(f"passed={passed} failed={failed}")
sys.exit(1 if failed else 0)
