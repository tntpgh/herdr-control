#!/usr/bin/env python3
"""verify-owner-lease-reap-cli.py — offline synthetic proofs for
owner-lease-reap.py (the DRY-RUN-ONLY reap CLI, S4(c)) and the structural
REAP_APPLY guards in it plus lib/owner_lease_reap.py.

Real subprocess, real temp SQLite, a fake `herdr` binary placed on PATH
inside a tmp/ directory -- no live hub, registry or panes.

  python3 verify-owner-lease-reap-cli.py
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_lease as ol  # noqa: E402

CLI = HERE / "owner-lease-reap.py"
FAILS: list[str] = []
TOTAL = [0]
S = lambda t: hashlib.sha256(t.encode()).hexdigest()  # noqa: E731


def case(name, cond) -> None:
    TOTAL[0] += 1
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def fake_herdr(bindir: Path, script: str) -> None:
    bindir.mkdir(parents=True, exist_ok=True)
    p = bindir / "herdr"
    p.write_text(script)
    p.chmod(0o700)


def make_db(base: Path, label="kb", acquired_before_s=100.0) -> Path:
    db = base / "lease.sqlite3"
    conn = ol.connect(str(db))
    ol.migrate(conn)
    ol.register_owner(conn, label, "tntpgh/knowledge-base")
    now = time.time()
    ol.claim_initial(conn, label, "w1:p1", "term_abc123", 3600, S("sess-a"), now=now - acquired_before_s)
    conn.close()
    os.chmod(db, 0o600)
    return db


def counts(db: Path):
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        return tuple(c.execute(q).fetchone()[0] for q in (
            "SELECT COUNT(*) FROM owner_leases WHERE released_at IS NULL",
            "SELECT COUNT(*) FROM owner_events"))
    finally:
        c.close()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(env_over: dict, bindir: Path | None = None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
    e["PATH"] = f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}" if bindir is not None else os.environ.get("PATH", "")
    e.update(env_over)
    r = subprocess.run([sys.executable, str(CLI)], capture_output=True, text=True, env=e, timeout=30)
    return r.returncode, r.stdout.strip()


PANE_LIST_GOOD = ('{"result":{"panes":[{"pane_id":"w9:p9","terminal_id":"term_other",'
                   '"agent_session":{"value":"/s/other.jsonl"}}]}}')


def main() -> int:
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    db = make_db(base)

    # ---- flags off: the store is never even opened ----
    rc, out = run({})
    case("CLI: no flag -> exit 4 refused:flags_off", (rc, out) == (4, "refused:flags_off"))

    rc, out = run({"HERDR_OWNER_LEASE_REAP": "1"})
    case("CLI: flag on, DB unset -> exit 4 refused:flags_off", (rc, out) == (4, "refused:flags_off"))

    rc, out = run({"HERDR_OWNER_LEASE_DB": str(db)})
    case("CLI: DB set, flag unset -> exit 4 refused:flags_off", (rc, out) == (4, "refused:flags_off"))

    # ---- DB present but not private (world-readable) -> refused before any read ----
    world_db = base / "world.sqlite3"
    wconn = ol.connect(str(world_db))
    ol.migrate(wconn)
    wconn.close()
    os.chmod(world_db, 0o644)
    log1 = base / "log1.jsonl"
    rc, out = run({"HERDR_OWNER_LEASE_REAP": "1", "HERDR_OWNER_LEASE_DB": str(world_db),
                   "HERDR_OWNER_LEASE_REAP_LOG": str(log1)})
    case("CLI: DB not private -> exit 4 refused:lease_*", rc == 4 and out.startswith("refused:lease_"))
    case("CLI: DB not private -> no log written", not log1.exists())

    # ---- DB missing -> refused, never created ----
    missing_db = base / "missing.sqlite3"
    rc, out = run({"HERDR_OWNER_LEASE_REAP": "1", "HERDR_OWNER_LEASE_DB": str(missing_db),
                   "HERDR_OWNER_LEASE_REAP_LOG": str(log1)})
    case("CLI: DB missing -> exit 4 refused:lease_db_missing", (rc, out) == (4, "refused:lease_db_missing"))
    case("CLI: DB missing -> never created", not missing_db.exists())

    BASE_ENV = {"HERDR_OWNER_LEASE_REAP": "1", "HERDR_OWNER_LEASE_DB": str(db)}

    def probe_case(name, script, expect_reason):
        bindir = base / f"bin-{name}"
        fake_herdr(bindir, script)
        logp = base / f"log-{name}.jsonl"
        before_sha, before_counts = sha256_file(db), counts(db)
        rc, out = run({**BASE_ENV, "HERDR_OWNER_LEASE_REAP_LOG": str(logp)}, bindir=bindir)
        case(f"CLI probe {name}: exit 0, reap-dry skip {expect_reason}",
             rc == 0 and out == f"reap-dry skip {expect_reason}")
        case(f"CLI probe {name}: DB untouched (sha256 + live-row/event counts)",
             sha256_file(db) == before_sha and counts(db) == before_counts)
        case(f"CLI probe {name}: log file mode 0600", stat.S_IMODE(logp.stat().st_mode) == 0o600)
        return logp

    probe_case("exit1", "#!/bin/sh\nexit 1\n", "probe_unavailable")
    probe_case("sleep6", "#!/bin/sh\nsleep 6\n", "probe_unavailable")
    probe_case("silent", "#!/bin/sh\nexit 0\n", "probe_unavailable")
    probe_case("garbage", "#!/bin/sh\necho 'not json'\n", "malformed_snapshot")

    # ---- good pane list, the holder's pane genuinely gone -> would_reap 1 ----
    bindir = base / "bin-good"
    fake_herdr(bindir, f"#!/bin/sh\necho '{PANE_LIST_GOOD}'\n")
    logp = base / "log-good.jsonl"
    before_sha, before_counts = sha256_file(db), counts(db)
    rc, out = run({**BASE_ENV, "HERDR_OWNER_LEASE_REAP_LOG": str(logp)}, bindir=bindir)
    case("CLI probe good: exit 0, would=1 held=0 labels=['kb']",
         rc == 0 and out == "reap-dry ok would=1 held=0 labels=['kb']")
    case("CLI probe good: DB untouched -- dry-run on a read-only connection",
         sha256_file(db) == before_sha and counts(db) == before_counts)
    case("CLI probe good: log file mode 0600", stat.S_IMODE(logp.stat().st_mode) == 0o600)
    report = json.loads(logp.read_text().strip().splitlines()[-1])
    case("CLI probe good: report carries captured_at/probe_rc/would_reap/dry_run",
         "captured_at" in report and report.get("probe_rc") == 0
         and len(report.get("would_reap", [])) == 1 and report.get("dry_run") is True)

    # ---- REAP_APPLY structurally does not exist: no code path, no flag.
    # Prose that documents its ABSENCE (both module docstrings do) is
    # expected and not a hit -- REVIEW.md §3 found the same in
    # owner_lease_reap.py's own docstring and called it expected. So the
    # search runs over each file's CODE with its docstrings stripped (ast),
    # not the raw text. ----
    import ast

    def code_without_docstrings(path: Path) -> str:
        tree = ast.parse(path.read_text())
        doc_lines = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body:
                first = node.body[0]
                if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
                    doc_lines.update(range(first.lineno, first.end_lineno + 1))
        return "\n".join(l for i, l in enumerate(path.read_text().splitlines(), 1) if i not in doc_lines)

    for f in (HERE / "lib" / "owner_lease_reap.py", CLI):
        code = code_without_docstrings(f)
        case(f"GUARD: no dry_run=False in {f.name}'s code (docstrings excluded)", "dry_run=False" not in code)
        case(f"GUARD: no REAP_APPLY in {f.name}'s code (docstrings excluded)", "REAP_APPLY" not in code)

    # Repo-wide: the same scope REVIEW.md §3 grepped (owner_*.py, hub.py,
    # owner-*.py, remote-mcp/*.py) must never READ a REAP_APPLY-named env var.
    import glob as _glob
    code_files = sorted(set(_glob.glob(str(HERE / "lib" / "owner_*.py")) + [str(HERE / "hub.py")]
                             + _glob.glob(str(HERE / "owner-*.py")) + _glob.glob(str(HERE / "remote-mcp" / "*.py"))))
    offenders = [f for f in code_files if "REAP_APPLY" in code_without_docstrings(Path(f))]
    case("GUARD: no REAP_APPLY env read anywhere in owner_*/hub/owner-*/remote-mcp code", offenders == [])

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing of {TOTAL[0]}")
    if FAILS:
        for f in FAILS:
            print(f"  - {f}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
