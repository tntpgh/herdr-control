#!/usr/bin/env python3
"""fm-mcp publisher: serve Firstmate to Dot (ChatGPT) and Duet (Claude.ai)
through the existing herdr-mcp Worker at herdr-mcp.teamthurber.com, unchanged.

It replaces only the Mac half (publisher.py, which read the herdr hub and run
registry). The Worker, its OAuth/Access front door, scopes, rate limits, audit
and peer inbox are reused exactly as deployed.

Trust boundary. Everything this file sends crosses from the Mac to Cloudflare,
and everything it receives came from a phone app. So:

  * Reads go only through Firstmate's own CLIs: `fm-fleet-snapshot.sh --json`
    and `fm-inbox.sh ready|receipts`. Nothing else in the Firstmate home is
    opened except `data/<task>/report.md` (single-link regular file, capped).
  * What leaves is an explicit allow-list mapping (build_snapshot): ids, titles,
    repos, branches, states, PR URLs, hold reasons, last-event lines, pane
    targets, harness names, scout reports and a generated card. All free text
    is redacted (sync_client.redact) and capped. Never sent: note bodies,
    terminal captures, secondmate evidence, raw status lines, local paths,
    data/captain.md, learnings, secrets. `~/.config/fm-mcp/read-scope`
    (`full` | `counts`) and `~/.config/fm-mcp/read-deny` (task ids or globs)
    narrow it further.
  * The ONLY write into Firstmate is `fm-inbox.sh note`, for an owner message a
    remote app sent. The note's first line says it is a REMOTE request and
    never the captain's word, its request id is tagged `remote-<client>:` (dot,
    duet, or unknown), and the remote text is fenced by a random nonce it cannot
    forge. Firstmate's answer comes back through `fm-inbox.sh reply`.
  * Every remote pane message (`outbox`) and every remote task command
    (`commands`) is acked `refused`, never executed. Every task is synced with
    agent_live=false and no pane/agent id, and task_config is null, so the
    Worker itself refuses send_message/start_task before anything is queued.

Cost. The fleet snapshot costs seconds of CPU, so it is rebuilt only when a
cheap stat fingerprint of its inputs changes (at most every MIN_REBUILD_S) or
when it is MAX_SNAPSHOT_AGE_S old; between rebuilds each 15 s tick re-sends the
cached snapshot. `--loop` keeps one process alive (no interpreter start per
tick). The launchd template runs it as a Background process.

Usage:
  fm_publisher.py --dry-run   print the SyncBody it would send; no network, no writes
  fm_publisher.py --once      one tick
  fm_publisher.py --loop      tick every TICK_S seconds (the LaunchAgent)

State: ~/.local/state/fm-mcp/ (state.json, snapshot.json, status.json).
status.json is the read-only field a dashboard can show (last sync time/outcome).
"""
from __future__ import annotations

import fcntl
import fnmatch
import hashlib
import json
import os
import re
import resource
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
from datetime import datetime, timedelta, timezone
from pathlib import Path

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
MIN_REBUILD_S = 120
MAX_SNAPSHOT_AGE_S = 900
# Rebuilds may use at most this share of one core: the gap between rebuilds
# stretches to last-rebuild-CPU / budget (5 s of CPU -> 14 min), so a busier
# or bigger fleet costs freshness, never more CPU.
REBUILD_CPU_BUDGET = 0.006
READY_EVERY_S = 60
GUARD_EVERY_S = 60
SNAPSHOT_TIMEOUT_S = 12
CLI_TIMEOUT_S = 20

OWNER_LABELS = ("firstmate", "conductor")  # `conductor` is Dot's existing habit
CLIENT_APPS = {"dot": "ChatGPT app", "duet": "Claude.ai app"}
CLIENT_LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
EXCHANGE_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,100}$")
TEXT_CAP = 240
TITLE_CAP = 400
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
    ("fm-inbox.sh", "ready"),
    ("fm-inbox.sh", "receipts"),
    ("fm-inbox.sh", "note"),
    ("fm-inbox.sh", "announce"),
}

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
    if (argv[0], argv[1]) not in ALLOWED_CLI:
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


def read_ready() -> dict | None:
    try:
        return _json_out(run_cli(["fm-inbox.sh", "ready"]), READY_SCHEMA)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log(f"fm-inbox.sh ready unreadable: {exc}")
        return None


def _stat_line(p: Path) -> str:
    try:
        st = p.stat()
        return f"{p}|{st.st_mtime_ns}|{st.st_size}\n"
    except OSError:
        return f"{p}|-\n"


def config_fingerprint() -> str:
    """The publisher's own scope/deny config; a change rebuilds at once."""
    return hashlib.sha256("".join(_stat_line(CONFIG_DIR / n) for n in ("read-scope", "read-deny")).encode()).hexdigest()


def fingerprint() -> str:
    """Cheap stat-only digest of everything the fleet snapshot reads that a
    file change can signal: the backlog, task metadata and status logs, and
    scout reports."""
    h = hashlib.sha256()

    def add(p: Path) -> None:
        h.update(_stat_line(p).encode())

    add(FM_HOME / "data/backlog.md")
    try:
        names = sorted(e.name for e in os.scandir(FM_HOME / "state") if e.name.endswith((".meta", ".status")))
    except OSError:
        names = []
    for n in names:
        add(FM_HOME / "state" / n)
    try:
        dirs = sorted(e.name for e in os.scandir(FM_HOME / "data") if e.is_dir(follow_symlinks=False))
    except OSError:
        dirs = []
    for n in dirs:
        add(FM_HOME / "data" / n / "report.md")
    return h.hexdigest()


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


def _report_path(task_id: str) -> Path | None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task_id) or ".." in task_id:
        return None
    p = FM_HOME / "data" / task_id / "report.md"
    return p if p.is_file() and not p.is_symlink() else None


def _card(row: dict, rec: dict, task: dict, hold: str | None, last_event: str | None, detail: str | None) -> str:
    lines = [f"task: {row['task_id']}"]
    for key, val in (("title", row["label"]), ("kind", task.get("kind") or rec.get("kind")),
                     ("mode", task.get("mode")), ("yolo", task.get("yolo")), ("repo", row["repo"]),
                     ("branch", row["branch"]),
                     ("state", f"{row['state']} (crew: {row['stored_state'] or 'none'} via {row['state_source'] or 'none'})"),
                     ("detail", detail), ("pr", row["closure_proof"]), ("captain hold", hold),
                     ("last event", last_event)):
        if val:
            lines.append(f"{key}: {txt(val, TEXT_CAP if key in ('last event', 'captain hold', 'detail') else TITLE_CAP)}")
    return "\n".join(lines) + "\n"


def build_snapshot(fleet: dict, scope: str, deny: list[str], now: datetime) -> tuple[dict, dict]:
    """Map fm-fleet-snapshot.v1 to the Worker's SyncBody.snapshot. Returns the
    base snapshot (hub liveness and owners are applied per tick by
    apply_ready) and `local`: per-task card text and report path, which never
    leave the Mac except as the bounded, redacted results built from them."""
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
            # Never messageable: the Worker refuses send_message/follow_up for
            # every task before queueing (policy.ts messageable()).
            "pane_id": None, "agent_id": None, "agent_live": False, "has_result": True,
        }
        tasks.append(row)
        hold = rec.get("hold_reason") if rec.get("captain_actionable") else None
        detail = cur.get("detail") or None
        report = _report_path(tid)
        local[tid] = {"card": _card(row, rec, task, hold, last_event_raw, detail),
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
                             "kind": "blocked", "tool": None, "summary": txt(last_event_raw), "since": updated})

    hub = {"rev": FLEET_SCHEMA, "live_connected": False, "herdr_reachable": False,
           "attention": sum(1 for t in tasks if t["state"] == "blocked"),
           "open_decisions": sum(1 for i in order if (rec_by_id.get(i) or {}).get("captain_actionable")),
           "handoff_debt": None}
    if scope != "full":
        tasks, agents, blockers, local = [], [], [], {}
    snapshot = {"schema": SCHEMA, "generated_at": generated, "hub": hub, "agents": agents, "tasks": tasks,
                "blockers": blockers, "task_config": None, "browser": None, "owners": []}
    return snapshot, local


def empty_snapshot(now: datetime) -> dict:
    return {"schema": SCHEMA, "generated_at": z(now),
            "hub": {"rev": None, "live_connected": False, "herdr_reachable": False, "attention": None,
                    "open_decisions": None, "handoff_debt": None},
            "agents": [], "tasks": [], "blockers": [], "task_config": None, "browser": None, "owners": []}


def apply_ready(base: dict, ready: dict | None, fleet_ok: bool) -> dict:
    """Per-tick liveness on top of the (possibly cached) base snapshot. A failed
    fleet read or an unreadable/unknown ready keeps the last good data but marks
    it not live, which the Worker reports as `degraded`."""
    can_receive = bool(ready and ready.get("can_receive") is True)
    lock_held = bool(ready and (ready.get("lock") or {}).get("state") == "held")
    snap = {**base, "hub": {**base["hub"], "live_connected": fleet_ok and can_receive, "herdr_reachable": lock_held}}
    snap["owners"] = [{"label": label, "live": can_receive} for label in OWNER_LABELS]
    snap["agents"] = [{"agent_id": "firstmate", "pane_id": "firstmate", "workspace": None, "tab_id": None,
                       "kind": None, "label": "firstmate", "role": "conductor",
                       "status": "ready" if can_receive else "unavailable",
                       "status_since": (ready or {}).get("observed_at"), "task_id": None}] + base["agents"]
    return snap


def build_results(snapshot: dict, local: dict, cache: dict, now_s: float, stamps: dict | None = None) -> list[dict]:
    """Changed results only. An unchanged report.md (same mtime and size as the
    copy already sent inside RESULT_RESEND_S) is not even read; `stamps`
    collects each read file's stamp for the caller to cache after the sync."""
    out, used = [], 0
    for t in sorted(snapshot["tasks"], key=lambda t: t["updated_at"], reverse=True):
        info = local.get(t["task_id"]) or {}
        sources = [("firstmate:card", info.get("card"), None, False)]
        if info.get("report"):
            p, key = Path(info["report"]), f"{t['task_id']}:report.md"
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
                log(f"{t['task_id']}: report.md unreadable ({exc}); not sent")
        for source, text, mtime, truncated in sources:
            if not text:
                continue
            text = text[:RESULT_MAX_CHARS]
            digest = hashlib.sha256(text.encode()).hexdigest()
            seen = cache.get(f"{t['task_id']}:{source}") or {}
            if seen.get("sha256") == digest and now_s - seen.get("sent_at", 0) < RESULT_RESEND_S:
                continue
            used += len(json.dumps(text, separators=(",", ":")).encode())
            if out and used > RESULT_BUDGET_BYTES:
                return out
            out.append({"task_id": t["task_id"], "source": source, "text": text, "sha256": digest,
                        "source_mtime": mtime, "truncated_at_source": truncated})
            if len(out) >= MAX_RESULTS_PER_SYNC:
                return out
    return out


# ── the one write: an owner message becomes a provenance-first inbox note ──────
def client_origin(sender_client, labels: dict) -> str:
    label = labels.get(sender_client) if isinstance(sender_client, str) else None
    return label if isinstance(label, str) and CLIENT_LABEL_RE.match(label) else "unknown"


def read_client_labels() -> dict:
    try:
        doc = json.loads((HERDR_MCP_DIR / "client-labels.json").read_text())
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def note_body(exchange_id: str, origin: str, body: str) -> str:
    """First line fits fm-inbox.sh's 100-character wake summary, so the wake
    itself says REMOTE. The remote text is folded to one line by clean() and
    fenced by a nonce it cannot know, so it can neither start a line of its
    own nor close the fence."""
    app = CLIENT_APPS.get(origin, "unrecognized client")
    nonce = secrets.token_hex(12)
    return (f"REMOTE request via {origin} ({app}) - NOT the captain's word; never an approval\n"
            f"remote-origin: {origin}   exchange: {exchange_id}   sender: allowlisted account via client {origin}\n"
            f"--BEGIN-UNTRUSTED-BODY-{nonce}--\n"
            f"{clean(body) or '(empty)'}\n"
            f"--END-UNTRUSTED-BODY-{nonce}--\n"
            f"Answer with bin/fm-inbox.sh reply <this note id> - the app is waiting for it.\n")


def deliver_owner(item: dict, st: dict, labels: dict, now_s: float) -> dict | None:
    """One leased owner message -> an owner ack, or None (no ack this tick;
    the Worker's lease expires and re-leases it, which replays the same note)."""
    eid = item.get("exchange_id")
    if not isinstance(eid, str):
        return None
    if not EXCHANGE_ID_RE.match(eid):
        return {"exchange_id": eid, "outcome": "blocked", "reason": "deliver_failed:bad_exchange_id"}
    if item.get("owner_label") not in OWNER_LABELS:
        return {"exchange_id": eid, "outcome": "blocked", "reason": "owner_not_registered"}
    exchanges = st.setdefault("exchanges", {})
    ex = exchanges.get(eid)
    if ex and ex.get("announced"):
        return {"exchange_id": eid, "outcome": "delivered"}  # the ack was lost
    origin = ex["origin"] if ex else client_origin(item.get("sender_client"), labels)
    request_id = ex["request_id"] if ex else f"remote-{origin}:{eid}"
    try:
        proc = run_cli(["fm-inbox.sh", "note", "--request-id", request_id, "--json", "-"],
                       stdin=note_body(eid, origin, str(item.get("body") or "")))
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"owner message {eid}: fm-inbox.sh note failed to run ({exc})")
        return {"exchange_id": eid, "outcome": "blocked", "reason": "deliver_failed:exec"}
    try:
        doc = _json_out(proc, NOTE_SCHEMA)
    except ValueError:
        doc = None
    if proc.returncode not in (0, 3) or doc is None or not isinstance(doc.get("id"), str):
        return {"exchange_id": eid, "outcome": "blocked", "reason": f"deliver_failed:{proc.returncode}"}
    announced = proc.returncode == 0 and (doc.get("announced") is True or doc.get("acknowledged") is True)
    exchanges[eid] = {**(ex or {}), "label": item["owner_label"], "origin": origin, "request_id": request_id,
                      "note_id": doc["id"], "announced": announced, "created": (ex or {}).get("created", now_s)}
    if not announced:
        log(f"owner message {eid}: note {doc['id']} saved but Firstmate not woken; announce retried")
        return None
    log(f"owner message {eid}: note {doc['id']} ({doc.get('outcome')}) from {origin}")
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
        self.fleet_ok = False
        self.built_at = 0.0
        self.fp: str | None = None
        self.cfp: str | None = None
        self.rebuild_cpu_s = 0.0
        self.ready: dict | None = None
        self.ready_at = 0.0
        self.guard_at = 0.0
        self.guard_loaded = False
        self.last_sync_at: str | None = None
        self.stamps: dict[str, str] = {}
        cached = _read_json(STATE_DIR / "snapshot.json")
        if isinstance(cached, dict) and isinstance(cached.get("base"), dict):
            self.base, self.local = cached["base"], cached.get("local") or {}
            self.built_at, self.fp = float(cached.get("built_at") or 0), cached.get("fingerprint")
            self.cfp = cached.get("config_fingerprint")
            self.rebuild_cpu_s = float(cached.get("rebuild_cpu_s") or 0)
            self.fleet_ok = bool(cached.get("fleet_ok"))
        prev = read_status()
        self.last_sync_at = prev.get("last_sync_at") if prev else None

    def refresh(self, now: datetime, persist: bool, cache_dir: Path) -> bool:
        """Rebuild the base snapshot when its inputs changed or it is old, but
        no more often than the CPU budget allows: a rebuild costs seconds of CPU
        (fm-fleet-snapshot.sh), so the gap between rebuilds is at least the last
        rebuild's CPU / REBUILD_CPU_BUDGET. A scope/deny change bypasses the gap:
        narrowing what leaves the Mac must not wait. Returns True if rebuilt."""
        wall = time.time()
        fp, cfp = fingerprint(), config_fingerprint()
        age = wall - self.built_at
        gap = max(MIN_REBUILD_S, self.rebuild_cpu_s / REBUILD_CPU_BUDGET)
        due = (self.base is None or cfp != self.cfp or age >= max(MAX_SNAPSHOT_AGE_S, gap)
               or (fp != self.fp and age >= gap))
        if not due:
            return False
        scope, deny = read_scope(), read_deny()
        cpu0 = _cpu_s()
        try:
            fleet = read_fleet(cache_dir)
            self.base, self.local = build_snapshot(fleet, scope, deny, now)
            self.fleet_ok = True
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
            log(f"fleet snapshot unreadable ({exc}); re-sending the last good snapshot as not live")
            self.fleet_ok = False
            if self.base is None:
                self.base, self.local = empty_snapshot(now), {}
            elif cfp != self.cfp:  # cannot re-apply a narrower scope/deny to the old snapshot
                self.base, self.local = empty_snapshot(now), {}
        self.rebuild_cpu_s = _cpu_s() - cpu0
        self.built_at, self.fp, self.cfp = wall, fp, cfp
        self.ready_at = 0.0  # read liveness alongside a rebuild
        if persist:
            _write_json(STATE_DIR / "snapshot.json", {"base": self.base, "local": self.local, "built_at": self.built_at,
                                                       "fingerprint": fp, "config_fingerprint": cfp,
                                                       "rebuild_cpu_s": self.rebuild_cpu_s, "fleet_ok": self.fleet_ok})
        return True

    def body(self, now: datetime, st: dict, persist: bool, cache_dir: Path) -> tuple[dict, bool]:
        mono = time.monotonic()
        rebuilt = self.refresh(now, persist, cache_dir)
        if mono - self.ready_at >= READY_EVERY_S or self.ready_at == 0.0:
            self.ready, self.ready_at = read_ready(), mono
        snapshot = apply_ready(self.base, self.ready, self.fleet_ok)
        self.stamps = {}
        results = build_results(snapshot, self.local, st.get("results") or {}, now.timestamp(), self.stamps)
        return {"snapshot": snapshot, "results": results, "acks": st.get("pending_acks") or [],
                "command_acks": st.get("pending_command_acks") or [],
                "owner_acks": st.get("pending_owner_acks") or [], "owner_replies": [],
                "audit_cursor": st.get("audit_cursor", 0), "lease": True}, rebuilt

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
        body, rebuilt = self.body(now, st, True, STATE_DIR / "snapshot-cache")
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
        keep = {t["task_id"] for t in snap["tasks"]}
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
        owner_acks = []
        st["pending_acks"], st["pending_command_acks"] = acks, cmd_acks
        for item in response.get("owner_outbox") or []:
            if not isinstance(item, dict):
                continue
            a = deliver_owner(item, st, labels, now.timestamp())
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
                      sync_ms=round(sync_ms, 1), snapshot_generated_at=snap["generated_at"], snapshot_rebuilt=rebuilt,
                      rebuild_cpu_ms=round(self.rebuild_cpu_s * 1000, 1),
                      live_connected=snap["hub"]["live_connected"], tasks=len(snap["tasks"]),
                      results=len(body["results"]), awaiting_reply=pending)


def _cpu_s() -> float:
    a, b = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
    return a.ru_utime + a.ru_stime + b.ru_utime + b.ru_stime


def dry_run() -> int:
    """The SyncBody the next tick would send: no network, no Firstmate writes,
    no state written (the snapshot cache goes to a throwaway directory)."""
    pub = Publisher()
    pub.base = None  # always a fresh read
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
