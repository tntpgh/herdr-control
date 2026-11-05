#!/usr/bin/env python3
"""fm-mcp publisher: serve Firstmate to Dot (ChatGPT) and Duet (Claude.ai)
through the Bebop Worker (bebop.teamthurber.com, also its sync URL;
herdr-mcp.teamthurber.com is its alias during the hostname cutover).

It replaces only the Mac half (publisher.py, which read the herdr hub and run
registry). The Worker owns OAuth/Access, the fm:* scopes, per-client grants,
rate limits, audit and the peer inbox.

Trust boundary. Everything this file sends crosses from the Mac to Cloudflare,
and everything it receives came from a phone app. So:

  * Reads go only through Firstmate's own CLIs: `fm-fleet-snapshot.sh --json`
    and `--contribution-input`, `fm-crew-state.sh <task id>`, and
    `fm-inbox.sh ready|receipts`. Nothing else in the Firstmate home is
    opened except `data/<task>/report.md` (single-link regular file, capped).
  * What leaves is an explicit allow-list mapping (build_snapshot): ids, titles,
    repos, branches, states, PR URLs, task kind/mode/yolo, hold reasons and the
    calls/options parsed from them, last-event lines, pane targets, harness
    names, the scout-report index and report bodies, Firstmate's posture, and a
    generated card. All free text is redacted (sync_client.redact) and capped.
    Never sent: note bodies, terminal captures, secondmate evidence, raw status
    lines, local paths, data/captain.md, learnings, secrets.
    `~/.config/fm-mcp/read-scope` (`full` | `counts`) and
    `~/.config/fm-mcp/read-deny` (task or report ids, or globs) narrow it
    further; a denied id is gone from tasks, decisions, reports and results.
  * The ONLY write into Firstmate is `fm-inbox.sh note`, for an owner note a
    remote app sent: a message, a task request, or a decision note. The note's
    first line says REMOTE and that it is never the captain's word (a decision
    note: never a release), its request id is tagged `remote-<client>:` (dot,
    duet, or unknown), and the remote text is fenced by a random nonce it
    cannot forge. Firstmate judges every note; nothing here starts a task or
    answers a hold. Firstmate's answer comes back through `fm-inbox.sh reply`.
  * Every remote pane message (`outbox`) and every remote task command
    (`commands`) is acked `refused`, never executed. Every task is synced with
    agent_live=false and no pane/agent id, and task_config is null.

Cost. A full fleet read costs seconds of CPU (one fm-crew-state.sh per task),
so it runs rarely; in between, a delta re-reads only what a stat fingerprint
says changed (the backlog and task inventory via `--contribution-input`, and
`fm-crew-state.sh <id>` for a changed task) and merges it onto the last full
read, every MIN_REBUILD_S at most, inside REBUILD_CPU_BUDGET (Publisher.refresh).
Each 15 s tick re-sends the cached snapshot. `--loop` keeps one process alive
(no interpreter start per tick). The launchd template runs it as a Background
process.

Usage:
  fm_publisher.py --dry-run   print the SyncBody it would send; no network, no writes
  fm_publisher.py --once      one tick
  fm_publisher.py --loop      tick every TICK_S seconds (the LaunchAgent)

State: ~/.local/state/fm-mcp/ (state.json, snapshot.json, status.json).
status.json is the read-only field a dashboard can show (last sync time/outcome).
"""
from __future__ import annotations

import copy
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import resource
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import NamedTuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import sync_client  # noqa: E402
from sanitize import clean, read_single_link_regular  # noqa: E402
from sync_client import redact  # noqa: E402


def _path(env: str, default: Path) -> Path:
    return Path(os.environ.get(env) or default).expanduser()


FM_HOME = _path("FM_MCP_FM_HOME", Path.home() / "Code/firstmate")
FM_BIN = _path("FM_MCP_FM_BIN", FM_HOME / "bin")
STATE_DIR = _path("FM_MCP_STATE_DIR", Path.home() / ".local/state/fm-mcp")
CONFIG_DIR = _path("FM_MCP_CONFIG_DIR", Path.home() / ".config/fm-mcp")
# herdr-mcp's own Mac-side records, shared with publisher.py: the CIMD client
# labels (client_id -> dot/duet, not a secret), the audit trail the Worker
# hands back, and the old publisher's audit cursor (read once, to continue it).
HERDR_MCP_DIR = _path("FM_MCP_HERDR_MCP_DIR", Path.home() / ".local/state/herdr/remote-mcp")
LAUNCHCTL = os.environ.get("FM_MCP_LAUNCHCTL", "/bin/launchctl")
OLD_LABEL = "com.herdr-control.remote-mcp"
USER_AGENT = "fm-mcp-publisher/1"

SCHEMA = 1  # the Worker's SNAPSHOT_SCHEMA
FLEET_SCHEMA = "fm-fleet-snapshot.v1"
READY_SCHEMA = "fm-primary-ready.v1"
NOTE_SCHEMA = "fm-inbox-note.v1"
RECEIPTS_SCHEMA = "fm-inbox-receipts.v1"
STATUS_SCHEMA = "fm-mcp-publisher-status.v1"

TICK_S = 15  # the Worker reports disconnected after 90 s without a sync
# Refreshes may use at most REBUILD_CPU_BUDGET of one core. A full read
# (`fm-fleet-snapshot.sh --json`, ~7 s of CPU, nearly all of it one
# fm-crew-state.sh per task) may use FULL_CPU_SHARE of that; deltas (the
# backlog and task inventory, plus fm-crew-state.sh for the few tasks whose
# meta/status changed) use the rest. The gap after each read is its own CPU /
# its share of the budget, so a busier or bigger fleet costs freshness, never
# more CPU.
MIN_REBUILD_S = 120  # floor between refreshes: the snapshot is at most ~2 min old
FULL_MIN_S = 900  # floor between full reads
STALE_TASK_S = 900  # an unchanged task's state is re-read once this old, when nothing else changed
MAX_OBSERVE_PER_DELTA = 2  # a burst of changed tasks spreads over deltas instead of one long gap
REBUILD_CPU_BUDGET = 0.006
FULL_CPU_SHARE = 1 / 3
CREW_STATE_TIMEOUT_S = 10  # fm-fleet-snapshot.sh's FM_SNAPSHOT_CREW_STATE_TIMEOUT default
READY_EVERY_S = 60
GUARD_EVERY_S = 60
SNAPSHOT_TIMEOUT_S = 12
CLI_TIMEOUT_S = 20

OWNER_LABELS = ("firstmate", "conductor")  # `conductor` is Dot's existing habit
CLIENT_APPS = {"dot": "ChatGPT app", "duet": "Claude.ai app"}
CLIENT_LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
EXCHANGE_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,100}$")
# The Worker's PROJECT_NAME and Firstmate's report-id shape, re-checked here:
# a note's meta came from a phone app, through the Worker.
PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
PR_URL_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}/pull/\d{1,9}$")
NOTE_KINDS = ("message", "task_request", "decision_note")
TASK_KINDS = ("scout", "ship")
POSTURES = ("present", "away", "quiet")
TEXT_CAP = 240
TITLE_CAP = 400
QUESTION_CAP = 2000
MAX_DECISIONS, MAX_CALLS, MAX_OPTIONS, MAX_REPORTS = 200, 20, 12, 500  # the Worker's SyncSchema caps
RESULT_MAX_CHARS = 64_000
RESULT_READ_CAP = 1_000_000
RESULT_BUDGET_BYTES = 1_000_000  # the Worker refuses bodies over 2 MB
MAX_RESULTS_PER_SYNC = 50
RESULT_RESEND_S = 12 * 3600
REPLY_MAX_CHARS = 64_000
MAX_REPLIES_PER_SYNC = 50
EXCHANGE_RETENTION_S = 30 * 86_400
ANNOUNCE_RETRY_S = 86_400
REFUSAL = "firstmate publisher executes no remote commands"
# Reply outcomes the Worker may still accept on a later sync (state.ts): the
# exchange is mid-lease, or a transaction collided. Anything else that is not
# accepted/duplicate is a durable refusal and is settled, not retried forever.
TRANSIENT_REPLY = ("ignored:queued", "ignored:delivering", "retry:", "rejected:event_conflict")

# The complete set of Firstmate commands this publisher may run.
ALLOWED_CLI = {
    ("fm-fleet-snapshot.sh", "--json"),
    ("fm-fleet-snapshot.sh", "--contribution-input"),
    ("fm-inbox.sh", "ready"),
    ("fm-inbox.sh", "receipts"),
    ("fm-inbox.sh", "note"),
    ("fm-inbox.sh", "announce"),
}
# ...plus these, with exactly one argument: a Firstmate task id.
PER_TASK_CLI = ("fm-crew-state.sh",)

CREW_TO_WORKER = {"working": "running", "parked": "parked", "paused": "paused",
                  "blocked": "blocked", "failed": "error", "unknown": "unknown"}


def log(msg: str) -> None:
    print(f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} fm-mcp-publisher: {msg}", flush=True)


def z(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def txt(v, cap: int = TEXT_CAP) -> str | None:
    """Free text on its way off the Mac: redacted, then capped."""
    if v is None:
        return None
    s = redact(str(v)).strip()
    return s[:cap] if s else None


def day_iso(v) -> str | None:
    if isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        return f"{v}T00:00:00Z"
    if isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", v):
        return v
    return None


# ── configuration (the publisher's own, never the Firstmate home's) ────────────
def _config_lines(name: str) -> list[str] | None:
    try:
        raw = (CONFIG_DIR / name).read_text()
    except OSError:
        return None
    return [ln.strip() for ln in raw.splitlines() if ln.strip() and not ln.strip().startswith("#")]


def read_scope() -> str:
    """`full` when unset (captain call 4: full, redacted, deny-listed); any value
    other than full/counts fails closed to `counts`."""
    lines = _config_lines("read-scope")
    if lines is None or not lines:
        return "full"
    return lines[0] if lines[0] in ("full", "counts") else "counts"


def read_deny() -> list[str]:
    return _config_lines("read-deny") or []


def denied(task_id: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(task_id, p) for p in patterns)


# ── Firstmate CLIs ─────────────────────────────────────────────────────────────
def child_env(extra: dict | None = None) -> dict:
    # The ingest key authenticates this process to the Worker; no Firstmate
    # command needs it, so it never reaches one.
    env = {k: v for k, v in os.environ.items() if k != "HERDR_MCP_INGEST_KEY"}
    env.update(FM_HOME=str(FM_HOME), FM_CREW_STATE_NO_FORGE="1")
    env["PATH"] = ":".join(dict.fromkeys(["/opt/homebrew/bin", "/usr/local/bin", *env.get("PATH", "/usr/bin:/bin").split(":")]))
    env.update(extra or {})
    return env


def run_cli(argv: list[str], stdin: str | None = None, timeout: float = CLI_TIMEOUT_S,
            extra_env: dict | None = None) -> subprocess.CompletedProcess:
    allowed = (argv[0], argv[1]) in ALLOWED_CLI or (
        argv[0] in PER_TASK_CLI and len(argv) == 2 and bool(ID_RE.match(argv[1])))
    if not allowed:
        raise PermissionError(f"not an allowed Firstmate command: {argv[:2]}")
    return subprocess.run([str(FM_BIN / argv[0]), *argv[1:]], input=stdin, capture_output=True, text=True,
                          timeout=timeout, env=child_env(extra_env), cwd=str(FM_HOME) if FM_HOME.is_dir() else None)


def _json_out(proc: subprocess.CompletedProcess, schema: str) -> dict:
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        raise ValueError(f"no output (rc {proc.returncode})")
    doc = json.loads(lines[-1] if schema != FLEET_SCHEMA else proc.stdout)
    if not isinstance(doc, dict) or doc.get("schema") != schema:
        raise ValueError(f"unexpected schema {doc.get('schema') if isinstance(doc, dict) else type(doc).__name__!r}")
    return doc


def read_fleet(cache_dir: Path) -> dict:
    proc = run_cli(["fm-fleet-snapshot.sh", "--json"], timeout=SNAPSHOT_TIMEOUT_S,
                   extra_env={"FM_SNAPSHOT_CACHE_DIR": str(cache_dir)})
    if proc.returncode != 0:
        raise ValueError(f"fm-fleet-snapshot.sh exited {proc.returncode}")
    return _json_out(proc, FLEET_SCHEMA)


def read_contribution_input() -> dict:
    """The backlog and task inventory without observing any worker: the same
    backlog parse `--json` embeds, plus one {id, kind, pr} per state/<id>.meta."""
    proc = run_cli(["fm-fleet-snapshot.sh", "--contribution-input"], timeout=SNAPSHOT_TIMEOUT_S)
    if proc.returncode != 0:
        raise ValueError(f"fm-fleet-snapshot.sh --contribution-input exited {proc.returncode}")
    doc = json.loads(proc.stdout)
    if not (isinstance(doc, dict) and isinstance(doc.get("backlog"), dict) and isinstance(doc.get("tasks"), list)):
        raise ValueError("unexpected --contribution-input shape")
    return doc


CREW_SEP = " · "


def read_crew_state(task_id: str, observed_at: str) -> dict:
    """One task's current state from `fm-crew-state.sh <id>`, parsed and
    bounded as fm-fleet-snapshot.sh's crew_state_json does: a failed, slow or
    unparseable read is state unknown, source none."""
    raw = ""
    try:
        proc = run_cli(["fm-crew-state.sh", task_id], timeout=CREW_STATE_TIMEOUT_S)
        raw = (proc.stdout.splitlines() or [""])[0]
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"fm-crew-state.sh {task_id} unreadable ({exc}); state unknown")
    state, source, detail = "unknown", "none", ""
    if raw.startswith("state: ") and f"{CREW_SEP}source: " in raw:
        state, rest = raw[len("state: "):].split(f"{CREW_SEP}source: ", 1)
        source, _, detail = rest.partition(CREW_SEP)
    return {"state": state, "source": source, "detail": detail, "raw": raw,
            "observed_at": observed_at, "freshness": "fresh"}


def read_ready() -> dict | None:
    try:
        return _json_out(run_cli(["fm-inbox.sh", "ready"]), READY_SCHEMA)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log(f"fm-inbox.sh ready unreadable: {exc}")
        return None


def _stamp(p: Path) -> tuple[str, int | None]:
    """(`mtime_ns|size`, mtime_ns), or ("-", None) when p is unreadable."""
    try:
        st = p.stat()
        return f"{st.st_mtime_ns}|{st.st_size}", st.st_mtime_ns
    except OSError:
        return "-", None


def _stat_line(p: Path) -> str:
    return f"{p}|{_stamp(p)[0]}\n"


def config_fingerprint() -> str:
    """The publisher's own scope/deny config; a change rebuilds at once."""
    return hashlib.sha256("".join(_stat_line(CONFIG_DIR / n) for n in ("read-scope", "read-deny")).encode()).hexdigest()


class Inputs(NamedTuple):
    fp: str  # digest of everything below plus the UTC day (hold buckets turn on dates)
    stamps: dict  # task id -> its meta/status stat stamp
    status_mtime: dict  # task id -> state/<id>.status mtime
    reports: list  # ids with a regular data/<id>/report.md under a real directory


def scan_inputs(day: str) -> Inputs:
    """One stat pass over everything the fleet snapshot reads that a file
    change can signal: the backlog, task metadata and status logs, and scout
    reports. No file is opened."""
    h = hashlib.sha256(f"day|{day}\n".encode())
    h.update(_stat_line(FM_HOME / "data/backlog.md").encode())
    state = FM_HOME / "state"
    try:
        names = sorted(e.name for e in os.scandir(state) if e.name.endswith((".meta", ".status")))
    except OSError:
        names = []
    parts: dict[str, dict[str, str]] = {}
    status_mtime: dict[str, float] = {}
    for n in names:
        stamp, mtime_ns = _stamp(state / n)
        h.update(f"{state / n}|{stamp}\n".encode())
        tid, ext = n.rsplit(".", 1)
        parts.setdefault(tid, {})[ext] = stamp
        if ext == "status" and mtime_ns is not None:
            status_mtime[tid] = mtime_ns / 1e9
    try:
        dirs = sorted(e.name for e in os.scandir(FM_HOME / "data") if e.is_dir(follow_symlinks=False))
    except OSError:
        dirs = []
    reports = []
    for n in dirs:
        p = FM_HOME / "data" / n / "report.md"
        h.update(_stat_line(p).encode())
        try:
            if stat.S_ISREG(p.lstat().st_mode):
                reports.append(n)
        except OSError:
            pass
    stamps = {tid: f"{v.get('meta', '-')}/{v.get('status', '-')}" for tid, v in parts.items() if "meta" in v}
    return Inputs(h.hexdigest(), stamps, status_mtime, reports)


# ── snapshot (the egress allow-list) ───────────────────────────────────────────
def worker_state(rec: dict | None, crew: str | None) -> str:
    """Report §4.3: chosen so the Worker's own attention/terminal filters work."""
    if rec and rec.get("state") == "done":
        return "completed"
    if rec and rec.get("captain_actionable"):
        return "blocked"
    if crew == "done":
        return "ready_review"
    if crew in CREW_TO_WORKER:
        return CREW_TO_WORKER[crew]
    if rec and rec.get("state") == "queued":
        return "queued"
    return "unknown"


def _report_path(report_id: str) -> Path | None:
    """data/<id>/report.md for a Firstmate id, never a path the fleet doc
    names, and never through a symlinked data/<id> directory."""
    if not ID_RE.match(report_id) or ".." in report_id:
        return None
    data = FM_HOME / "data"
    p = data / report_id / "report.md"
    try:
        if p.resolve(strict=True) != data.resolve(strict=True) / report_id / "report.md":
            return None
    except OSError:
        return None
    return p if p.is_file() and not p.is_symlink() else None


def _report_row(report_id: str, kind, task_ids: set[str], titles: dict) -> tuple[dict, Path] | None:
    """One report-index row. The title is the report's first `# ` heading,
    read (2 KB) only when the file's stamp changed: `titles` caches
    {id: {stamp, title}} across rebuilds."""
    p = _report_path(report_id)
    if p is None:
        return None
    try:
        st = p.lstat()
        stamp, seen = f"{st.st_mtime_ns}:{st.st_size}", titles.get(report_id) or {}
        if seen.get("stamp") == stamp:
            title = seen.get("title")
        else:
            raw = read_single_link_regular(p, 2048)
            lines = raw.decode("utf-8", "replace").splitlines()
            if len(raw) >= 2048:  # the last line may be cut mid-token, past what redaction can recognise
                lines = lines[:-1]
            title = txt(next((ln[2:] for ln in lines if ln.startswith("# ")), None), TITLE_CAP)
            titles[report_id] = {"stamp": stamp, "title": title}
    except OSError:
        return None
    return ({"report_id": report_id, "kind": txt(kind or "report", 40) or "report", "title": title,
             "task_id": report_id if report_id in task_ids else None,
             "updated_at": z(datetime.fromtimestamp(st.st_mtime, timezone.utc))}, p)


# A captain hold's free text, as Firstmate writes it: "(1) question: (a) x
# [rec] / (b) y; (2) ..." (or C1/C2), "rec X" for a call's recommendation,
# "Rec: ..." after the last call for the hold's. The parse is a convenience;
# `question` (the whole redacted hold) is the authority.
CALL_PAREN_RE = re.compile(r"\((\d{1,2})\)\s*")
CALL_C_RE = re.compile(r"\bC(\d{1,2})\b[:.)]?\s*")
OPTION_RE = re.compile(r"\(([a-h])\)\s*")
REC_MARK_RE = re.compile(r"\s*[\[(]rec(?:ommended)?\b[^\])]*[\])]", re.I)
REC_TEXT_RE = re.compile(r"\brec(?:ommend(?:ed|ation)?)?\b:?\s+([^;)\]]{1,80})", re.I)
HOLD_REC_RE = re.compile(r"(?:^|[.;]\s+)Rec(?:ommendation)?:\s*(.+)$", re.S)
REPORT_REF_RE = re.compile(r"\bdata/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/report\.md\b")
HOLD_ORIGIN_RE = re.compile(r"^Captain hold origin:\s*([A-Za-z0-9][A-Za-z0-9._-]{0,127})\s*$")


def _cap(s: str, n: int) -> str:
    return s.strip(" \t\n;,/:")[:n]


def parse_calls(question: str) -> tuple[list[dict], str | None]:
    """Split a redacted hold into calls and options. Returns (calls, the
    hold's own recommendation or, for a single call, that call's)."""
    hold_rec = HOLD_REC_RE.search(question)
    body = question[:hold_rec.start()] if hold_rec else question
    marks = list(CALL_PAREN_RE.finditer(body)) or list(CALL_C_RE.finditer(body))
    calls = []
    for i, m in enumerate(marks[:MAX_CALLS]):
        seg = body[m.end():marks[i + 1].start() if i + 1 < len(marks) else len(body)]
        opts = list(OPTION_RE.finditer(seg))
        options = []
        for j, o in enumerate(opts[:MAX_OPTIONS]):
            raw = seg[o.end():opts[j + 1].start() if j + 1 < len(opts) else len(seg)]
            options.append({"key": o.group(1), "text": _cap(REC_MARK_RE.sub("", raw), TEXT_CAP),
                            "recommended": bool(REC_MARK_RE.search(raw))})
        stem = seg[:opts[0].start()] if opts else seg
        picked = [o["key"] for o in options if o["recommended"]]
        said = REC_TEXT_RE.search(stem)
        rec = picked[0] if len(picked) == 1 else (_cap(said.group(1), TEXT_CAP) if said else None)
        calls.append({"call": m.group(1), "text": _cap(stem, TITLE_CAP) or f"call {m.group(1)}", "options": options,
                      "recommendation": rec or None})
    overall = _cap(hold_rec.group(1), TITLE_CAP) if hold_rec else None
    if overall is None and len(calls) == 1:
        overall = calls[0]["recommendation"]
    return calls, overall or None


def _decision(rec: dict, title: str, gen_dt: datetime, reports: set[str]) -> dict:
    raw = str(rec.get("hold_reason") or "")
    question = redact(raw).strip()[:QUESTION_CAP] or "(no hold reason recorded)"
    calls, overall = parse_calls(question)
    origin = next((m.group(1) for ln in rec.get("body_lines") or [] if isinstance(ln, str)
                   for m in [HOLD_ORIGIN_RE.match(ln.strip())] if m), None)
    # The report it points at, only if that report is itself published.
    refs = [m.group(1) for m in REPORT_REF_RE.finditer(raw)] + ([origin] if origin else [])
    report_id = next((r for r in refs if r in reports), None)
    since = day_iso(rec.get("hold_set")) or day_iso(rec.get("since"))
    age = None
    if since:
        age = max(0, (gen_dt - datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)).days)
    return {"task_id": rec["id"], "title": title, "repo": txt(rec.get("repo"), 200), "question": question,
            "calls": calls, "recommendation": overall, "bucket": txt(rec.get("hold_bucket"), 40), "since": since,
            "age_days": age, "origin": origin if origin in reports else None, "report_id": report_id}


def _card(row: dict, rec: dict, task: dict, hold: str | None, last_event: str | None, detail: str | None,
          observed: str | None) -> str:
    lines = [f"task: {row['task_id']}"]
    for key, val in (("title", row["label"]), ("kind", task.get("kind") or rec.get("kind")),
                     ("mode", task.get("mode")), ("yolo", task.get("yolo")), ("repo", row["repo"]),
                     ("branch", row["branch"]),
                     ("state", f"{row['state']} (crew: {row['stored_state'] or 'none'} via {row['state_source'] or 'none'})"),
                     ("detail", detail), ("state observed", observed), ("pr", row["closure_proof"]),
                     ("captain hold", hold), ("last event", last_event)):
        if val:
            lines.append(f"{key}: {txt(val, TEXT_CAP if key in ('last event', 'captain hold', 'detail') else TITLE_CAP)}")
    return "\n".join(lines) + "\n"


def build_snapshot(fleet: dict, scope: str, deny: list[str], now: datetime,
                   titles: dict | None = None) -> tuple[dict, dict, dict]:
    """Map fm-fleet-snapshot.v1 to the Worker's SyncBody.snapshot. Returns the
    base snapshot (hub liveness, owners and posture are applied per tick by
    apply_ready); `local`: per-id card text and report path (tasks and
    published reports), which never leave the Mac except as the bounded,
    redacted results built from them; and the report-title cache, given back
    as `titles` next rebuild so an unchanged report is not reopened."""
    generated = day_iso(fleet.get("generated")) or z(now)
    gen_dt = datetime.strptime(generated, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    records = [r for r in ((fleet.get("backlog") or {}).get("records") or [])
               if isinstance(r, dict) and r.get("structured") and isinstance(r.get("id"), str)]
    rec_by_id = {r["id"]: r for r in records}
    task_by_id = {t["id"]: t for t in fleet.get("tasks") or [] if isinstance(t, dict) and isinstance(t.get("id"), str)}
    order = list(dict.fromkeys([r["id"] for r in records] + sorted(task_by_id)))
    order = [i for i in order if not denied(i, deny)]

    tasks, agents, blockers, local = [], [], [], {}
    for tid in order:
        rec, task = rec_by_id.get(tid) or {}, task_by_id.get(tid) or {}
        cur = task.get("current_state") or {}
        crew = cur.get("state") if task else None
        state = worker_state(rec or None, crew)
        hints = task.get("hints") or {}
        last_event_raw = hints.get("last_event_text") or None
        age = (((task.get("paths") or {}).get("status_log") or {}).get("last_event") or {}).get("age_seconds")
        completion = (rec.get("completion") or {}) if rec else {}
        created = day_iso(rec.get("since")) or generated
        if isinstance(age, int) and age >= 0:
            updated = z(gen_dt - timedelta(seconds=age))
        else:
            updated = day_iso(completion.get("date")) or created
        pr = (task.get("pr") or {}).get("url") or rec.get("pr_url")
        yolo = task.get("yolo")
        row = {
            "task_id": tid, "run_id": str(task.get("spawn_gen") or ""),
            "label": txt(rec.get("title") or tid, TITLE_CAP) or tid,
            "project": txt(task.get("project") or rec.get("repo") or "", 200) or "",
            "repo": txt(rec.get("repo") or task.get("project") or "", 200) or "",
            "branch": txt(task.get("branch") or "", 200) or "",
            "state": state, "stored_state": crew, "state_source": cur.get("source") if task else "backlog",
            "created_at": created, "updated_at": updated,
            "completed_at": (day_iso(completion.get("date")) or updated) if state in ("completed", "ready_review") else None,
            "closure_reason": txt(completion.get("verb") or "done", 40) if state == "completed" else None,
            "closure_proof": txt(pr, TITLE_CAP),
            "pr_url": pr if isinstance(pr, str) and PR_URL_RE.match(pr) else None,
            "kind": txt(task.get("kind") or rec.get("kind"), 40), "mode": txt(task.get("mode"), 40),
            "yolo": {"on": True, "off": False}.get(yolo) if isinstance(yolo, str) else (yolo if isinstance(yolo, bool) else None),
            # Never messageable: the Worker has no tool that reaches a pane.
            "pane_id": None, "agent_id": None, "agent_live": False, "has_result": True,
        }
        tasks.append(row)
        hold = rec.get("hold_reason") if rec.get("captain_actionable") else None
        detail = cur.get("detail") or None
        report = _report_path(tid)
        local[tid] = {"card": _card(row, rec, task, hold, last_event_raw, detail, day_iso(cur.get("observed_at"))),
                      "report": str(report) if report else None, "updated_at": updated}

        endpoint = task.get("endpoint") or {}
        if endpoint.get("target") and endpoint.get("exists") is not False and state != "completed":
            agents.append({
                "agent_id": f"fm:{tid}", "pane_id": txt(endpoint["target"], 120) or "", "workspace": None,
                "tab_id": None, "kind": txt(task.get("harness"), 40), "label": tid, "role": "worker",
                "status": crew or "unknown", "status_since": None, "task_id": tid,
            })
        if rec.get("captain_actionable"):
            blockers.append({"task_id": tid, "label": row["label"], "pane_id": None, "agent_id": None,
                             "kind": "input_required", "tool": "captain", "summary": txt(hold),
                             "since": day_iso(rec.get("hold_set")) or created})
        elif state != "completed" and (crew == "blocked" or hints.get("pending_decision")):
            blockers.append({"task_id": tid, "label": row["label"], "pane_id": None, "agent_id": None,
                             "kind": "blocked", "tool": None, "summary": txt(last_event_raw or detail), "since": updated})

    open_count = sum(1 for i in order if (rec_by_id.get(i) or {}).get("captain_actionable"))
    hub = {"rev": FLEET_SCHEMA, "live_connected": False, "herdr_reachable": False,
           "attention": sum(1 for t in tasks if t["state"] == "blocked"),
           "open_decisions": open_count, "handoff_debt": None}
    snapshot = {"schema": SCHEMA, "generated_at": generated, "hub": hub, "agents": [], "tasks": [],
                "blockers": [], "task_config": None, "browser": None, "owners": [],
                "firstmate": None, "decisions": [], "reports": []}
    if scope != "full":
        return snapshot, {}, {}

    # The scout/ship report index: ids from the fleet doc, files from
    # data/<id>/report.md only (never the path the doc names), deny-listed ids
    # dropped. Its bodies go out as results under (report_id, "report.md").
    task_ids = {t["task_id"] for t in tasks}
    prev, kept, rows = titles or {}, {}, {}
    for sr in fleet.get("scout_reports") or []:
        rid = sr.get("id") if isinstance(sr, dict) else None
        if not isinstance(rid, str) or denied(rid, deny) or rid in rows:
            continue
        if rid in prev:
            kept[rid] = prev[rid]
        got = _report_row(rid, sr.get("kind"), task_ids, kept)
        if got is not None:
            rows[rid] = got
    reports = sorted((row for row, _ in rows.values()), key=lambda r: r["updated_at"] or "", reverse=True)[:MAX_REPORTS]
    for r in reports:
        if r["report_id"] not in local:
            local[r["report_id"]] = {"card": None, "report": str(rows[r["report_id"]][1]), "updated_at": r["updated_at"]}
    published = {r["report_id"] for r in reports}
    labels = {t["task_id"]: t["label"] for t in tasks}
    decisions = [_decision(rec_by_id[i], labels.get(i) or i, gen_dt, published)
                 for i in order if (rec_by_id.get(i) or {}).get("captain_actionable")][:MAX_DECISIONS]
    snapshot.update(agents=agents, tasks=tasks, blockers=blockers, decisions=decisions, reports=reports)
    return snapshot, local, {rid: kept[rid] for rid in published if rid in kept}


def empty_snapshot(now: datetime) -> dict:
    return {"schema": SCHEMA, "generated_at": z(now),
            "hub": {"rev": None, "live_connected": False, "herdr_reachable": False, "attention": None,
                    "open_decisions": None, "handoff_debt": None},
            "agents": [], "tasks": [], "blockers": [], "task_config": None, "browser": None, "owners": [],
            "firstmate": None, "decisions": [], "reports": []}


# ── incremental refresh: a delta merged onto the last full read ────────────────
def trim_fleet(fleet: dict, now: datetime) -> dict:
    """The parts of a full fm-fleet-snapshot.v1 doc build_snapshot reads, kept
    as the base every later delta is merged onto."""
    return {"schema": FLEET_SCHEMA, "generated": day_iso(fleet.get("generated")) or z(now),
            "backlog": fleet.get("backlog") or {},
            "tasks": sorted((t for t in fleet.get("tasks") or [] if isinstance(t, dict) and isinstance(t.get("id"), str)),
                            key=lambda t: t["id"]),
            "scout_reports": fleet.get("scout_reports") or []}


def _last_event(task: dict) -> dict:
    return ((task.get("paths") or {}).get("status_log") or {}).get("last_event") or {}


def reage(raw: dict, now: datetime) -> dict:
    """A copy of `raw` dated `now`. Every carried event age grows by the time
    since raw's own date, so an unchanged task keeps its updated_at."""
    out = copy.deepcopy(raw)
    then = datetime.strptime(raw["generated"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    shift = max(0, int((now.replace(microsecond=0) - then).total_seconds()))
    for t in out["tasks"]:
        ev = _last_event(t)
        if type(ev.get("age_seconds")) is int:
            ev["age_seconds"] += shift
    out["generated"] = z(now)
    return out


def observed_epoch(task: dict | None) -> float | None:
    at = day_iso(((task or {}).get("current_state") or {}).get("observed_at"))
    return datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp() if at else None


def observe_task(row: dict | None, task_id: str, inv: dict, crew: dict | None, now: datetime,
                 status_mtime: float | None) -> dict:
    """A task row after a delta: the inventory's kind/PR and, when `crew` was
    read, its fresh current state over the last full read's row (a task new
    since then starts bare, state unknown until its first read). The full
    read's status-stream fold is not re-run, so its open-decision hint is kept
    only until the crew state has provably moved past it (the rule
    fm-fleet-snapshot.sh itself applies), and a status-log `parked` (which only
    a needs-decision line produces) opens one. The event text waits for the
    next full read; the status log's mtime stands in for the event time."""
    new = copy.deepcopy(row) if row else {"id": task_id, "pr": {"url": None}, "hints": {}, "paths": {}, "endpoint": {},
                                          "current_state": {"state": "unknown", "source": "none",
                                                            "detail": "new task, not yet observed", "raw": ""}}
    new["kind"] = inv.get("kind") or new.get("kind") or "ship"
    if isinstance(inv.get("pr"), dict):  # the meta's PR: set it, or drop a meta-sourced one the meta no longer has
        url = inv["pr"].get("url")
        if isinstance(url, str) and url:
            new["pr"] = {**(new.get("pr") or {}), "url": url, "source": "meta"}
        elif (new.get("pr") or {}).get("source") == "meta":
            new["pr"] = {**new["pr"], "url": None, "source": "absent"}
    if crew is None:
        return new
    new["current_state"] = crew
    state, source = crew["state"], crew["source"]
    pending = bool((new.get("hints") or {}).get("pending_decision"))
    if (source in ("run-step", "pane") and state not in ("parked", "blocked")) or state in ("done", "failed"):
        pending = False
    elif state == "parked" and source == "status-log":
        pending = True
    new["hints"] = {**(new.get("hints") or {}), "pending_decision": pending, "last_event_text": None}
    if status_mtime is not None:
        paths = new.setdefault("paths", {})
        paths["status_log"] = {**(paths.get("status_log") or {}),
                               "last_event": {"age_seconds": max(0, int(now.timestamp() - status_mtime))}}
    return new


def scout_rows(report_ids: list[str], tasks: list[dict], backlog: dict) -> list[dict]:
    """fm-fleet-snapshot.sh's scout_reports for the ids on disk: kind from the
    task, else its backlog row, else scout."""
    kinds = {r["id"]: r.get("kind") for r in backlog.get("records") or []
             if isinstance(r, dict) and r.get("structured") and isinstance(r.get("id"), str)}
    kinds.update({t["id"]: t.get("kind") for t in tasks if t.get("kind")})
    return [{"id": i, "kind": kinds.get(i) or "scout"} for i in report_ids]


def apply_ready(base: dict, ready: dict | None, fleet_ok: bool) -> dict:
    """Per-tick liveness on top of the (possibly cached) base snapshot. A failed
    fleet read or an unreadable/unknown ready keeps the last good data but marks
    it not live, which the Worker reports as `degraded`."""
    can_receive = bool(ready and ready.get("can_receive") is True)
    lock_held = bool(ready and (ready.get("lock") or {}).get("state") == "held")
    snap = {**base, "hub": {**base["hub"], "live_connected": fleet_ok and can_receive, "herdr_reachable": lock_held}}
    snap["owners"] = [{"label": label, "live": can_receive} for label in OWNER_LABELS]
    posture = ((ready or {}).get("posture") or {}).get("state")
    snap["firstmate"] = {"posture": posture if posture in POSTURES else "unknown", "can_receive": can_receive,
                         "observed_at": day_iso((ready or {}).get("observed_at"))}
    snap["agents"] = [{"agent_id": "firstmate", "pane_id": "firstmate", "workspace": None, "tab_id": None,
                       "kind": None, "label": "firstmate", "role": "conductor",
                       "status": "ready" if can_receive else "unavailable",
                       "status_since": (ready or {}).get("observed_at"), "task_id": None}] + base["agents"]
    return snap


def build_results(local: dict, cache: dict, now_s: float, stamps: dict | None = None) -> list[dict]:
    """Changed results only, newest first, for every task card and published
    report in `local` (build_snapshot put only published ids there). An
    unchanged report.md (same mtime and size as the copy already sent inside
    RESULT_RESEND_S) is not even read; `stamps` collects each read file's stamp
    for the caller to cache after the sync."""
    out, used = [], 0
    for doc_id, info in sorted(local.items(), key=lambda kv: kv[1].get("updated_at") or "", reverse=True):
        sources = [("firstmate:card", info.get("card"), None, False)]
        if info.get("report"):
            p, key = Path(info["report"]), f"{doc_id}:report.md"
            try:
                st = p.lstat()
                stamp, seen = f"{st.st_mtime_ns}:{st.st_size}", cache.get(key) or {}
                if seen.get("stamp") != stamp or now_s - seen.get("sent_at", 0) >= RESULT_RESEND_S:
                    raw = read_single_link_regular(p, RESULT_READ_CAP)
                    full = redact(raw.decode("utf-8", "replace"))  # redact the whole read, THEN cut
                    sources.append(("report.md", full, z(datetime.fromtimestamp(st.st_mtime, timezone.utc)),
                                    len(raw) >= RESULT_READ_CAP or len(full) > RESULT_MAX_CHARS))
                    if stamps is not None:
                        stamps[key] = stamp
            except OSError as exc:
                log(f"{doc_id}: report.md unreadable ({exc}); not sent")
        for source, text, mtime, truncated in sources:
            if not text:
                continue
            text = text[:RESULT_MAX_CHARS]
            digest = hashlib.sha256(text.encode()).hexdigest()
            seen = cache.get(f"{doc_id}:{source}") or {}
            if seen.get("sha256") == digest and now_s - seen.get("sent_at", 0) < RESULT_RESEND_S:
                continue
            used += len(json.dumps(text, separators=(",", ":")).encode())
            if out and used > RESULT_BUDGET_BYTES:
                return out
            out.append({"task_id": doc_id, "source": source, "text": text, "sha256": digest,
                        "source_mtime": mtime, "truncated_at_source": truncated})
            if len(out) >= MAX_RESULTS_PER_SYNC:
                return out
    return out


# ── the one write: an owner note becomes a provenance-first inbox note ────────
def client_origin(item: dict, labels: dict) -> str:
    """The Worker's label for the verified client (policy.ts CLIENT_GRANTS),
    else the Mac's own client-labels.json, else unknown."""
    label = item.get("sender_label")
    if label in CLIENT_APPS:
        return label
    client = item.get("sender_client")
    label = labels.get(client) if isinstance(client, str) else None
    return label if isinstance(label, str) and CLIENT_LABEL_RE.match(label) else "unknown"


def read_client_labels() -> dict:
    try:
        doc = json.loads((HERDR_MCP_DIR / "client-labels.json").read_text())
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def note_problem(item: dict) -> str | None:
    """Re-check a note's kind and meta on the Mac; the Worker checked them too,
    but they came from a phone app. None when the note may be written."""
    kind, meta = item.get("kind", "message"), item.get("meta") or {}
    if kind not in NOTE_KINDS or not isinstance(meta, dict):
        return "deliver_failed:bad_kind"
    if kind == "task_request" and not (isinstance(meta.get("project"), str) and PROJECT_RE.match(meta["project"])
                                       and meta.get("task_kind") in TASK_KINDS):
        return "deliver_failed:bad_meta"
    if kind == "decision_note" and not (isinstance(meta.get("task_id"), str) and ID_RE.match(meta["task_id"])):
        return "deliver_failed:bad_meta"
    return None


def note_body(exchange_id: str, origin: str, body: str, kind: str = "message", meta: dict | None = None,
              open_decisions: set[str] | None = None) -> str:
    """First line fits fm-inbox.sh's 100-character wake summary, so the wake
    itself says REMOTE and what kind of note it is. The remote text is folded
    to one line by clean() and fenced by a nonce it cannot know, so it can
    neither start a line of its own nor close the fence. Kind and meta were
    re-checked by note_problem() and are shape-safe."""
    app = CLIENT_APPS.get(origin, "unrecognized client")
    meta = meta or {}
    nonce = secrets.token_hex(12)
    if kind == "task_request":
        head = (f"REMOTE task request via {origin} ({app}) - NOT the captain's word; never an approval\n"
                f"requested: a {meta['task_kind']} task in project {meta['project']} - nothing was started; "
                f"you decide whether to take it (intake, yolo off)\n")
    elif kind == "decision_note":
        tid = meta["task_id"]
        state = "open" if open_decisions is None or tid in open_decisions else "NOT open on this Mac now"
        head = (f"REMOTE decision note via {origin} ({app}) - NOT the captain's answer; never a release\n"
                f"about hold: {tid} ({state}) - the hold stays until the captain answers it himself\n")
    else:
        head = f"REMOTE request via {origin} ({app}) - NOT the captain's word; never an approval\n"
    return (head +
            f"remote-origin: {origin}   exchange: {exchange_id}   sender: allowlisted account via client {origin}\n"
            f"--BEGIN-UNTRUSTED-BODY-{nonce}--\n"
            f"{clean(body) or '(empty)'}\n"
            f"--END-UNTRUSTED-BODY-{nonce}--\n"
            f"Answer with bin/fm-inbox.sh reply <this note id> - the app is waiting for it.\n")


def deliver_owner(item: dict, st: dict, labels: dict, now_s: float, open_decisions: set[str] | None = None) -> dict | None:
    """One leased owner note -> an owner ack, or None (no ack this tick; the
    Worker's lease expires and re-leases it, which replays the same note)."""
    eid = item.get("exchange_id")
    if not isinstance(eid, str):
        return None
    if not EXCHANGE_ID_RE.match(eid):
        return {"exchange_id": eid, "outcome": "blocked", "reason": "deliver_failed:bad_exchange_id"}
    if item.get("owner_label") not in OWNER_LABELS:
        return {"exchange_id": eid, "outcome": "blocked", "reason": "owner_not_registered"}
    problem = note_problem(item)
    if problem:
        log(f"owner note {eid}: refused on the Mac ({problem})")
        return {"exchange_id": eid, "outcome": "blocked", "reason": problem}
    exchanges = st.setdefault("exchanges", {})
    ex = exchanges.get(eid)
    if ex and ex.get("announced"):
        return {"exchange_id": eid, "outcome": "delivered"}  # the ack was lost
    origin = ex["origin"] if ex else client_origin(item, labels)
    request_id = ex["request_id"] if ex else f"remote-{origin}:{eid}"
    kind = item.get("kind", "message")
    try:
        proc = run_cli(["fm-inbox.sh", "note", "--request-id", request_id, "--json", "-"],
                       stdin=note_body(eid, origin, str(item.get("body") or ""), kind, item.get("meta"), open_decisions))
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"owner note {eid}: fm-inbox.sh note failed to run ({exc})")
        return {"exchange_id": eid, "outcome": "blocked", "reason": "deliver_failed:exec"}
    try:
        doc = _json_out(proc, NOTE_SCHEMA)
    except ValueError:
        doc = None
    if proc.returncode not in (0, 3) or doc is None or not isinstance(doc.get("id"), str):
        return {"exchange_id": eid, "outcome": "blocked", "reason": f"deliver_failed:{proc.returncode}"}
    announced = proc.returncode == 0 and (doc.get("announced") is True or doc.get("acknowledged") is True)
    exchanges[eid] = {**(ex or {}), "label": item["owner_label"], "origin": origin, "request_id": request_id,
                      "kind": kind, "note_id": doc["id"], "announced": announced,
                      "created": (ex or {}).get("created", now_s)}
    if not announced:
        log(f"owner note {eid}: note {doc['id']} saved but Firstmate not woken; announce retried")
        return None
    log(f"owner note {eid} ({kind}): note {doc['id']} ({doc.get('outcome')}) from {origin}")
    return {"exchange_id": eid, "outcome": "delivered"}


def retry_announces(st: dict, now_s: float) -> None:
    for eid, ex in (st.get("exchanges") or {}).items():
        if ex.get("note_id") and not ex.get("announced") and now_s - ex.get("created", now_s) < ANNOUNCE_RETRY_S:
            try:
                proc = run_cli(["fm-inbox.sh", "announce", "--json", ex["note_id"]])
            except (OSError, subprocess.SubprocessError) as exc:
                log(f"announce {ex['note_id']} failed to run ({exc})")
                continue
            if proc.returncode == 0:
                ex["announced"] = True
                log(f"owner message {eid}: note {ex['note_id']} announced on retry")


def collect_replies(st: dict) -> tuple[list[dict], list[dict]]:
    """Firstmate's replies to remote notes -> owner_replies rows. Replies to any
    other note (the captain's own) are read only to move past them, never sent."""
    by_note = {ex["note_id"]: eid for eid, ex in (st.get("exchanges") or {}).items()
               if ex.get("note_id") and ex.get("announced") and not ex.get("settled")}
    if not by_note:
        return [], []
    try:
        doc = _json_out(run_cli(["fm-inbox.sh", "receipts", "--after", st.get("reply_cursor") or "", "--all-replies"]),
                        RECEIPTS_SCHEMA)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log(f"fm-inbox.sh receipts unreadable ({exc}); replies wait")
        return [], []
    replies = sorted((r for r in doc.get("replies") or [] if isinstance(r, dict) and isinstance(r.get("cursor"), str)),
                     key=lambda r: r["cursor"])
    rows = []
    for r in replies:
        eid = by_note.get(r.get("id"))
        if eid is None or len(rows) >= MAX_REPLIES_PER_SYNC:
            continue
        body = (redact(str(r.get("body") or "")) or "(empty reply)")[:REPLY_MAX_CHARS]
        rows.append({"exchange_id": eid, "owner_label": st["exchanges"][eid]["label"], "body": body,
                     "responded_at": day_iso(r.get("at")) or z(datetime.now(timezone.utc)),
                     "artifact_revision": hashlib.sha256(body.encode()).hexdigest(), "session": "firstmate-inbox"})
    return rows, replies


def settle_replies(st: dict, rows: list[dict], replies: list[dict], response: dict) -> None:
    """Report §4.4 step 6: accepted/duplicate settles; a transient outcome is
    re-sent next tick; any other outcome is a durable refusal and settles too
    (publisher.py's H1 rule). The cursor then moves past every reply that is
    not ours or is settled, and stops at the first one still owed."""
    outcomes = {}
    for r in response.get("owner_reply_results") or []:
        if isinstance(r, dict) and all(isinstance(r.get(k), str) for k in ("exchange_id", "owner_label", "outcome")):
            outcomes[(r["owner_label"], r["exchange_id"])] = r["outcome"]
    exchanges = st.get("exchanges") or {}
    for row in rows:
        outcome = outcomes.get((row["owner_label"], row["exchange_id"]))
        if not outcome or outcome.startswith(TRANSIENT_REPLY):
            continue
        exchanges[row["exchange_id"]]["settled"] = outcome
        if outcome not in ("accepted", "duplicate"):
            log(f"reply for {row['exchange_id']} refused by the Worker ({outcome}); not retried")
    owed = {ex["note_id"] for ex in exchanges.values() if ex.get("note_id") and ex.get("announced") and not ex.get("settled")}
    for r in replies:
        if r.get("id") in owed:
            break
        st["reply_cursor"] = r["cursor"]


def refusals(response: dict) -> tuple[list[dict], list[dict]]:
    acks = [{"message_id": m["message_id"], "outcome": "refused", "detail": REFUSAL}
            for m in response.get("outbox") or [] if isinstance(m, dict) and isinstance(m.get("message_id"), str)]
    cmd_acks = [{"command_id": c["command_id"], "outcome": "refused", "detail": REFUSAL}
                for c in response.get("commands") or [] if isinstance(c, dict) and isinstance(c.get("command_id"), str)]
    return acks, cmd_acks


# ── state on disk ──────────────────────────────────────────────────────────────
def _write_json(path: Path, doc) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    os.replace(tmp, path)


def _read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def load_state() -> dict:
    st = _read_json(STATE_DIR / "state.json")
    if not isinstance(st, dict):
        st = {}
    if "audit_cursor" not in st:  # continue the old publisher's audit trail, never replay it
        old = _read_json(HERDR_MCP_DIR / "state.json")
        cursor = old.get("audit_cursor") if isinstance(old, dict) else None
        st["audit_cursor"] = cursor if isinstance(cursor, int) and cursor >= 0 else 0
    return st


def save_state(st: dict) -> None:
    _write_json(STATE_DIR / "state.json", st)


def append_audit(rows: list) -> None:
    if not rows:
        return
    path = HERDR_MCP_DIR / "audit.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")


STALE_AFTER_S = 90  # the Worker's own disconnected threshold, so a reader need not hardcode it


def write_status(doc: dict) -> None:
    _write_json(STATE_DIR / "status.json", {"schema": STATUS_SCHEMA, "stale_after_s": STALE_AFTER_S, **doc})


def read_status(path: Path | None = None) -> dict | None:
    """The dashboard's read: one small file, no subprocess, no network."""
    doc = _read_json(path or STATE_DIR / "status.json")
    return doc if isinstance(doc, dict) and doc.get("schema") == STATUS_SCHEMA else None


def old_publisher_loaded() -> bool:
    try:
        proc = subprocess.run([LAUNCHCTL, "print", f"gui/{os.getuid()}/{OLD_LABEL}"],
                              capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False  # no launchctl (not macOS): nothing can be loaded
    return proc.returncode == 0


# ── one tick ───────────────────────────────────────────────────────────────────
class Publisher:
    """Holds the cached snapshot and the cadence timers between ticks."""

    def __init__(self) -> None:
        self.base: dict | None = None
        self.local: dict = {}
        self.titles: dict = {}
        self.raw: dict | None = None  # the last full read with every delta since merged in
        self.observed: dict[str, str | None] = {}  # task id -> its input stamp when its state was last read
        self.fleet_ok = False
        self.built_at = 0.0
        self.full_at = 0.0  # the last successful full read
        self.full_try_at = 0.0  # the last full read attempted
        self.fp: str | None = None
        self.cfp: str | None = None
        self.rebuild_cpu_s = 0.0
        self.full_cpu_s = 0.0
        self.delta_cpu_s = 0.0
        self.ready: dict | None = None
        self.ready_at = 0.0
        self.guard_at = 0.0
        self.guard_loaded = False
        self.last_sync_at: str | None = None
        self.stamps: dict[str, str] = {}
        cached = _read_json(STATE_DIR / "snapshot.json")
        if isinstance(cached, dict) and isinstance(cached.get("base"), dict):
            self.base, self.local = cached["base"], cached.get("local") or {}
            self.titles = cached.get("titles") or {}
            raw = cached.get("raw")
            self.raw = raw if isinstance(raw, dict) and isinstance(raw.get("tasks"), list) else None
            self.observed = cached.get("observed") or {}
            self.built_at, self.fp = float(cached.get("built_at") or 0), cached.get("fingerprint")
            self.full_at = float(cached.get("full_at") or 0)
            self.full_try_at = float(cached.get("full_try_at") or 0)
            self.cfp = cached.get("config_fingerprint")
            self.rebuild_cpu_s = float(cached.get("rebuild_cpu_s") or 0)
            self.full_cpu_s = float(cached.get("full_cpu_s") or 0)
            self.delta_cpu_s = float(cached.get("delta_cpu_s") or 0)
            self.fleet_ok = bool(cached.get("fleet_ok"))
        prev = read_status()
        self.last_sync_at = prev.get("last_sync_at") if prev else None

    def refresh(self, now: datetime, persist: bool, cache_dir: Path) -> str | None:
        """Refresh the base snapshot inside the CPU budget. Returns the kind
        run, or None:
          full     fm-fleet-snapshot.sh --json, every task observed. Runs when
                   there is no full read yet, else at most every FULL_MIN_S and
                   never sooner than its CPU / its share of the budget.
          delta    the inputs' stat fingerprint changed: the backlog and task
                   inventory re-read, fm-crew-state.sh for up to
                   MAX_OBSERVE_PER_DELTA changed tasks (else for one task whose
                   state is STALE_TASK_S old); every other task carried over.
          confirm  nothing changed and nothing is stale: no command runs; the
                   snapshot is re-dated (each task card still says when its
                   state was observed).
          config   read-scope/read-deny changed: applied to the cached read at
                   once, no command and no wait (narrowing what leaves the Mac
                   must not wait); with no read yet, a full read runs instead.
        A delta/confirm runs every MIN_REBUILD_S, never sooner than the last
        one's CPU / the deltas' share."""
        wall = time.time()
        inputs, cfp = scan_inputs(now.strftime("%Y-%m-%d")), config_fingerprint()
        full_gap = max(FULL_MIN_S, self.full_cpu_s / (REBUILD_CPU_BUDGET * FULL_CPU_SHARE))
        delta_gap = max(MIN_REBUILD_S, self.delta_cpu_s / (REBUILD_CPU_BUDGET * (1 - FULL_CPU_SHARE)))
        if self.raw is not None and cfp != self.cfp:
            # Narrowing what leaves the Mac never waits for, or needs, a read.
            self.base, self.local, self.titles = build_snapshot(self.raw, read_scope(), read_deny(), now, self.titles)
            self.cfp = cfp
            if persist:
                self.save()
            return "config"
        if self.raw is None:
            kind = "full" if self.base is None or cfp != self.cfp or wall - self.built_at >= MIN_REBUILD_S else None
        elif wall - max(self.full_at, self.full_try_at) >= full_gap:  # a failed full read waits a gap too
            kind = "full"
        elif wall - self.built_at >= delta_gap:
            kind = "delta"
        else:
            kind = None
        if kind is None:
            return None
        scope, deny = read_scope(), read_deny()
        cpu0 = _cpu_s()
        try:
            if kind == "full":
                self.full_try_at = wall
                raw = trim_fleet(read_fleet(cache_dir), now)
                observed = {t["id"]: inputs.stamps.get(t["id"]) for t in raw["tasks"]}
            else:
                raw, observed, kind = self.delta(now, inputs)
            self.base, self.local, self.titles = build_snapshot(raw, scope, deny, now, self.titles)
            self.raw, self.observed, self.fp = raw, observed, inputs.fp
            if kind == "full":
                self.full_at = wall
            if kind != "confirm":  # a confirm ran no command, so it cannot clear a failed read
                self.fleet_ok = True
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
            # self.fp and self.full_at stay put, so the read is retried.
            log(f"fleet {kind} read failed ({exc}); re-sending the last good snapshot as not live")
            self.fleet_ok = False
            if self.base is None or cfp != self.cfp:  # no read yet: nothing to narrow but an empty snapshot
                self.base, self.local = empty_snapshot(now), {}
        cost = _cpu_s() - cpu0
        if kind == "full":
            self.full_cpu_s = cost
        else:
            self.delta_cpu_s = cost
        self.rebuild_cpu_s = cost
        self.built_at, self.cfp = wall, cfp
        if kind != "confirm":
            self.ready_at = 0.0  # read liveness alongside a read
        if persist:
            self.save()
        return kind

    def save(self) -> None:
        _write_json(STATE_DIR / "snapshot.json", {
            "base": self.base, "local": self.local, "titles": self.titles, "raw": self.raw,
            "observed": self.observed, "built_at": self.built_at, "full_at": self.full_at,
            "full_try_at": self.full_try_at, "fingerprint": self.fp, "config_fingerprint": self.cfp,
            "rebuild_cpu_s": self.rebuild_cpu_s, "full_cpu_s": self.full_cpu_s, "delta_cpu_s": self.delta_cpu_s,
            "fleet_ok": self.fleet_ok})

    def delta(self, now: datetime, inputs: Inputs) -> tuple[dict, dict, str]:
        """self.raw brought up to `now` reading only what changed (see refresh)."""
        raw = reage(self.raw, now)
        old = {t["id"]: t for t in raw["tasks"]}
        kind = "confirm"
        if inputs.fp != self.fp:
            ci = read_contribution_input()
            inv = {t["id"]: t for t in ci["tasks"]
                   if isinstance(t, dict) and isinstance(t.get("id"), str) and ID_RE.match(t["id"])}
            raw["backlog"], kind = ci["backlog"], "delta"
        else:  # same fingerprint, same state/*.meta set
            inv = {tid: {} for tid in old}

        def readable(tid: str) -> bool:
            # A secondmate's state is the full read's: fm-fleet-snapshot.sh
            # never probes a remote endpoint, and a new one may be remote.
            row = old.get(tid) or {}
            return not row.get("remote") and (inv[tid].get("kind") or row.get("kind")) != "secondmate"

        changed = sorted((tid for tid in inv if readable(tid) and
                          (tid not in old or self.observed.get(tid) != inputs.stamps.get(tid))),
                         key=lambda tid: (tid in old, observed_epoch(old.get(tid)) or 0.0, tid))
        observe = changed[:MAX_OBSERVE_PER_DELTA]
        if not observe:
            stale = sorted((at or 0.0, tid) for tid in inv if tid in old and readable(tid)
                           for at in [observed_epoch(old[tid])] if at is None or now.timestamp() - at >= STALE_TASK_S)
            observe = [stale[0][1]] if stale else []
        tasks, observed = [], {}
        for tid in sorted(inv):
            if tid in observe:
                crew = read_crew_state(tid, raw["generated"])
                tasks.append(observe_task(old.get(tid), tid, inv[tid], crew, now, inputs.status_mtime.get(tid)))
                observed[tid], kind = inputs.stamps.get(tid), "delta"
            else:
                tasks.append(observe_task(old.get(tid), tid, inv[tid], None, now, None))
                observed[tid] = self.observed.get(tid)
        raw["tasks"] = tasks
        if inputs.fp != self.fp:
            raw["scout_reports"] = scout_rows(inputs.reports, tasks, raw["backlog"])
        return raw, observed, kind

    def body(self, now: datetime, st: dict, persist: bool, cache_dir: Path) -> tuple[dict, str | None]:
        mono = time.monotonic()
        refreshed = self.refresh(now, persist, cache_dir)
        if mono - self.ready_at >= READY_EVERY_S or self.ready_at == 0.0:
            self.ready, self.ready_at = read_ready(), mono
        snapshot = apply_ready(self.base, self.ready, self.fleet_ok)
        self.stamps = {}
        results = build_results(self.local, st.get("results") or {}, now.timestamp(), self.stamps)
        return {"snapshot": snapshot, "results": results, "acks": st.get("pending_acks") or [],
                "command_acks": st.get("pending_command_acks") or [],
                "owner_acks": st.get("pending_owner_acks") or [], "owner_replies": [],
                "audit_cursor": st.get("audit_cursor", 0), "lease": True}, refreshed

    def guard(self, mono: float) -> bool:
        if mono - self.guard_at >= GUARD_EVERY_S or self.guard_at == 0.0:
            self.guard_loaded, self.guard_at = old_publisher_loaded(), mono
        return self.guard_loaded

    def tick(self) -> int:
        t0, ru0 = time.perf_counter(), _cpu_s()
        now = datetime.now(timezone.utc)
        status = {"updated_at": z(now), "last_sync_at": self.last_sync_at, "scope": read_scope()}

        def finish(rc: int, outcome: str, detail: str = "", **extra) -> int:
            status.update(ok=rc == 0, outcome=outcome, detail=detail, tick_ms=round((time.perf_counter() - t0) * 1000, 1),
                          tick_cpu_ms=round((_cpu_s() - ru0) * 1000, 1), **extra)
            write_status(status)
            return rc

        if self.guard(time.monotonic()):
            log(f"{OLD_LABEL} is loaded; two publishers would overwrite each other's snapshot. Not syncing.")
            return finish(2, "refused_old_publisher_loaded", f"launchctl bootout gui/{os.getuid()}/{OLD_LABEL} first")
        key = sync_client.ingest_key()
        if not key:
            log("HERDR_MCP_INGEST_KEY not set (env or ~/.config/op/launchd-secrets.env); nothing sent")
            return finish(1, "no_ingest_key")

        st = load_state()
        body, refreshed = self.body(now, st, True, STATE_DIR / "snapshot-cache")
        snap = body["snapshot"]
        retry_announces(st, now.timestamp())
        rows, replies = collect_replies(st)
        body["owner_replies"] = rows
        sync_ms = 0.0
        try:
            s0 = time.perf_counter()
            response = sync_client.post_sync(key, body, USER_AGENT)
            sync_ms += (time.perf_counter() - s0) * 1000
        except (urllib.error.URLError, OSError, ValueError) as exc:
            log(f"sync failed: {exc}")
            return finish(1, "sync_failed", str(exc)[:200], snapshot_generated_at=snap["generated_at"])
        self.last_sync_at = z(datetime.now(timezone.utc))
        status["last_sync_at"] = self.last_sync_at

        cache = st.setdefault("results", {})
        for r in body["results"]:
            cache[f"{r['task_id']}:{r['source']}"] = {"sha256": r["sha256"], "sent_at": now.timestamp()}
        for rkey, stamp in self.stamps.items():  # read this tick: sent, or unchanged by content
            if rkey in cache:
                cache[rkey]["stamp"] = stamp
        keep = set(self.local)  # every published task card and report
        st["results"] = {k: v for k, v in (st.get("results") or {}).items() if k.split(":", 1)[0] in keep}
        settle_replies(st, rows, replies, response)
        st["pending_acks"], st["pending_command_acks"], st["pending_owner_acks"] = [], [], []
        append_audit(response.get("audit") or [])
        st["audit_cursor"] = response.get("audit_cursor", st.get("audit_cursor", 0))
        cutoff = now.timestamp() - EXCHANGE_RETENTION_S
        st["exchanges"] = {k: v for k, v in (st.get("exchanges") or {}).items() if v.get("created", 0) >= cutoff}

        acks, cmd_acks = refusals(response)
        for a in acks:
            log(f"message {a['message_id']}: refused ({REFUSAL})")
        for a in cmd_acks:
            log(f"command {a['command_id']}: refused ({REFUSAL})")
        labels = read_client_labels() if response.get("owner_outbox") else {}
        open_decisions = {d["task_id"] for d in snap.get("decisions") or []}
        owner_acks = []
        st["pending_acks"], st["pending_command_acks"] = acks, cmd_acks
        for item in response.get("owner_outbox") or []:
            if not isinstance(item, dict):
                continue
            a = deliver_owner(item, st, labels, now.timestamp(), open_decisions)
            if a is not None:
                owner_acks.append(a)
            st["pending_owner_acks"] = owner_acks
            save_state(st)  # each outcome is durable the moment it is known
        save_state(st)

        if acks or cmd_acks or owner_acks:
            try:
                s0 = time.perf_counter()
                response = sync_client.post_sync(key, {**body, "results": [], "owner_replies": [], "acks": acks,
                                                       "command_acks": cmd_acks, "owner_acks": owner_acks,
                                                       "audit_cursor": st["audit_cursor"], "lease": False}, USER_AGENT)
                sync_ms += (time.perf_counter() - s0) * 1000
                st["pending_acks"], st["pending_command_acks"], st["pending_owner_acks"] = [], [], []
                append_audit(response.get("audit") or [])
                st["audit_cursor"] = response.get("audit_cursor", st["audit_cursor"])
                save_state(st)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                log(f"ack sync failed, acks re-sent next tick: {exc}")
        pending = sum(1 for ex in st["exchanges"].values() if ex.get("announced") and not ex.get("settled"))
        return finish(0, "synced" if snap["hub"]["live_connected"] else "synced_degraded",
                      sync_ms=round(sync_ms, 1), snapshot_generated_at=snap["generated_at"],
                      snapshot_rebuilt=refreshed is not None, refresh=refreshed,
                      rebuild_cpu_ms=round(self.rebuild_cpu_s * 1000, 1),
                      full_cpu_ms=round(self.full_cpu_s * 1000, 1), delta_cpu_ms=round(self.delta_cpu_s * 1000, 1),
                      full_read_at=z(datetime.fromtimestamp(self.full_at, timezone.utc)) if self.full_at else None,
                      live_connected=snap["hub"]["live_connected"], tasks=len(snap["tasks"]),
                      results=len(body["results"]), awaiting_reply=pending)


def _cpu_s() -> float:
    a, b = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
    return a.ru_utime + a.ru_stime + b.ru_utime + b.ru_stime


def dry_run() -> int:
    """The SyncBody the next tick would send: no network, no Firstmate writes,
    no state written (the snapshot cache goes to a throwaway directory)."""
    pub = Publisher()
    pub.base, pub.raw = None, None  # always a fresh full read
    with tempfile.TemporaryDirectory(prefix="fm-mcp-dry-") as tmp:
        body, _ = pub.body(datetime.now(timezone.utc), load_state() | {"results": {}}, False, Path(tmp))
    json.dump(body, sys.stdout, indent=1)
    print()
    return 0


def _lock():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fh = open(STATE_DIR / "publisher.lock", "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    return fh


def main(argv: list[str]) -> int:
    os.umask(0o077)  # state carries exchange ids and reply text
    if "--dry-run" in argv:
        return dry_run()
    if not {"--once", "--loop"} & set(argv):
        print(__doc__.split("Usage:")[1].split("State:")[0].rstrip(), file=sys.stderr)
        return 64
    lock = _lock()
    if lock is None:
        log("another fm-mcp publisher holds the lock; exiting")
        return 2
    pub = Publisher()
    if "--once" in argv:
        return pub.tick()
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    last = None
    while not stop:
        started = time.monotonic()
        try:
            rc = pub.tick()
        except Exception as exc:  # noqa: BLE001 - one bad tick never kills the agent
            log(f"tick crashed: {type(exc).__name__}: {exc}")
            rc = 1
        if rc != last:
            log(f"tick rc {rc}")
            last = rc
        while not stop and time.monotonic() - started < TICK_S:
            time.sleep(min(1.0, TICK_S - (time.monotonic() - started)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
