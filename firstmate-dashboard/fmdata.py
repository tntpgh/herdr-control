"""fmdata — read a Firstmate home through its own CLIs, never its files' internals.

Everything here is a read: `fm-tasks-axi.sh list|show`, `fm-crew-state.sh`,
`fm-inbox.sh receipts`, plus `state/<id>.meta` and `state/<id>.status`. The
one write the dashboard makes (an inbox note) lives in server.py, behind the
same CLI the captain would type.

Output of the CLIs is TOON-style text (`tasks[N]{a,b}:` tables, `key: value`
records). The parsers are header-driven so a field added upstream is ignored
rather than misread.
"""
from __future__ import annotations

import concurrent.futures
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

CMD_TIMEOUT_S = 15
# Crew states (fm-crew-state.sh's vocabulary) that want a human or firstmate.
ATTENTION_STATES = ("blocked", "failed", "parked")
PR_URL = re.compile(r"https://[^\s\"'<>()]+/(?:pull|merge_requests)/\d+")
# A path a hold reason names, relative to the home: "data/<id>/report.md".
REPORT_REF = re.compile(r"(?<![\w/.-])data/[A-Za-z0-9._/-]+\.(?:md|txt|json|log)\b")
_TABLE_HEAD = re.compile(r"^(\w+)\[(\d+)\]\{([^}]*)\}:\s*$")
_CELL = re.compile(r'\s*("(?:[^"\\]|\\.)*"|[^,]*?)\s*(,|$)')
_TRUNC = re.compile(r"\n\.\.\. \(truncated.*$", re.S)


class CommandError(RuntimeError):
    pass


def _unquote(tok: str) -> str:
    if len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"':
        try:
            return json.loads(tok)
        except ValueError:
            return tok[1:-1]
    return tok


def _blank(v: str) -> str:
    return "" if v in ("-", "none") else v


def parse_table(text: str, name: str = "tasks") -> list[dict]:
    """Rows of the `name[N]{fields}:` table in a TOON document."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = _TABLE_HEAD.match(line)
        if not m or m.group(1) != name:
            continue
        fields = [f.strip() for f in m.group(3).split(",")]
        rows = []
        for row in lines[i + 1:]:
            if not row.startswith("  "):
                break
            cells, pos = [], 0
            while True:
                c = _CELL.match(row, pos)
                cells.append(_unquote(c.group(1)))
                if c.group(2) != ",":
                    break
                pos = c.end()
            if len(cells) != len(fields):
                raise CommandError(f"{name}: row has {len(cells)} cells for {len(fields)} fields: {row[:80]!r}")
            rows.append(dict(zip(fields, cells)))
        if len(rows) != int(m.group(2)):
            raise CommandError(f"{name}: header says {m.group(2)} rows, read {len(rows)}")
        return rows
    return []


def parse_record(text: str) -> dict:
    """`key: value` lines of a `show` record (indented under `task:`)."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s+([a-z_]+): (.*)$", line)
        if m:
            out[m.group(1)] = _blank(_unquote(m.group(2)))
    return out


def untruncate(title: str) -> tuple[str, bool]:
    cut = _TRUNC.sub("", title)
    return cut, cut != title


def parse_meta(path: Path) -> dict:
    meta = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            k, sep, v = line.partition("=")
            if sep:
                meta[k.strip()] = v.strip()
    except OSError:
        pass
    return meta


def parse_crew_state(line: str) -> dict:
    """`state: X · source: Y · detail` -> {state, source, detail}."""
    parts = [p.strip() for p in line.strip().split(" · ")]
    out = {"state": "unknown", "source": "none", "detail": ""}
    rest = []
    for p in parts:
        if p.startswith("state: "):
            out["state"] = p[7:]
        elif p.startswith("source: "):
            out["source"] = p[8:]
        else:
            rest.append(p)
    out["detail"] = " · ".join(rest)
    return out


def _iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Home:
    """One Firstmate home. `root` holds bin/ (the code), `home` holds state/
    and data/ (FM_HOME); they are the same directory in the usual layout."""

    def __init__(self, home: Path, root: Path | None = None):
        self.home = Path(home).resolve()
        self.root = Path(root).resolve() if root else self.home
        self.state = self.home / "state"
        self.data = self.home / "data"

    def env(self) -> dict:
        env = dict(os.environ)
        env["FM_HOME"] = str(self.home)
        # Keep crew-state local: its forge fallback is a 5s network read per
        # crew, and the dashboard never needs a merged/unmerged verdict.
        env["FM_CREW_STATE_NO_FORGE"] = "1"
        return env

    def run(self, tool: str, *args: str, stdin: str | None = None) -> str:
        cmd = [str(self.root / "bin" / tool), *args]
        try:
            p = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                               timeout=CMD_TIMEOUT_S, env=self.env(), cwd=str(self.home))
        except (OSError, subprocess.TimeoutExpired) as e:
            raise CommandError(f"{tool} {' '.join(args[:2])}: {type(e).__name__}: {e}") from e
        if p.returncode != 0:
            raise CommandError(f"{tool} {' '.join(args[:2])}: exit {p.returncode}: {(p.stderr or p.stdout).strip()[:300]}")
        return p.stdout

    # ── individual reads ──────────────────────────────────────────────────
    def tasks(self) -> list[dict]:
        out = self.run("fm-tasks-axi.sh", "list", "--fields", "held,hold_kind,hold_reason,closed,created")
        return parse_table(out)

    def show(self, task_id: str) -> dict:
        return parse_record(self.run("fm-tasks-axi.sh", "show", task_id, "--full"))

    def crew_state(self, task_id: str) -> dict:
        out = self.run("fm-crew-state.sh", task_id)
        line = next((ln for ln in out.splitlines() if ln.startswith("state: ")), "")
        return parse_crew_state(line) if line else {"state": "unknown", "source": "none", "detail": out.strip()[:200]}

    def receipts(self) -> dict:
        return json.loads(self.run("fm-inbox.sh", "receipts") or "{}")

    def status_tail(self, task_id: str) -> tuple[str, float | None, list[str]]:
        """(last event line, its mtime, PR URLs newest first) from state/<id>.status."""
        p = self.state / f"{task_id}.status"
        try:
            text = p.read_text(errors="replace")
            mtime = p.stat().st_mtime
        except OSError:
            return "", None, []
        lines = [ln for ln in text.splitlines() if ln.strip()]
        prs: list[str] = []
        for ln in reversed(lines):
            for url in PR_URL.findall(ln):
                if url not in prs:
                    prs.append(url)
        return (lines[-1] if lines else ""), mtime, prs

    def report_refs(self, *texts: str) -> list[str]:
        refs: list[str] = []
        for t in texts:
            for r in REPORT_REF.findall(t or ""):
                if r not in refs:
                    refs.append(r)
        return refs

    def report_file(self, rel: str) -> Path | None:
        """A referenced report, only if it resolves inside data/ to a file."""
        try:
            p = (self.home / rel).resolve()
            p.relative_to(self.data.resolve())
        except (OSError, ValueError):
            return None
        return p if p.is_file() else None

    # ── the joined snapshot ───────────────────────────────────────────────
    def snapshot(self) -> dict:
        errors: list[str] = []
        try:
            rows = self.tasks()
        except CommandError as e:
            return {"ok": False, "errors": [str(e)], "generated": _iso(dt.datetime.now().timestamp()),
                    "home": str(self.home), "decisions": [], "in_flight": [], "queued": [], "done": [],
                    "counts": {}, "fingerprint": ""}
        for r in rows:
            r["title"], r["title_truncated"] = untruncate(r.get("title", ""))
            for k in ("hold_reason", "hold_kind", "closed", "created", "held"):
                r[k] = _blank(r.get(k, ""))

        holds = [r for r in rows if r.get("held") == "yes" and r.get("hold_kind") == "captain" and r.get("state") != "done"]
        hold_ids = {r["id"] for r in holds}
        live = [r for r in rows if r.get("state") == "in_flight"]
        metas = {r["id"]: parse_meta(self.state / f"{r['id']}.meta") for r in live}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            shows = {r["id"]: pool.submit(self.show, r["id"])
                     for r in rows if r["id"] in hold_ids or (r["title_truncated"] and r.get("state") != "done")}
            states = {r["id"]: pool.submit(self.crew_state, r["id"]) for r in live if metas[r["id"]]}
            receipts_f = pool.submit(self.receipts)

        full = {}
        for tid, f in shows.items():
            try:
                full[tid] = f.result()
            except CommandError as e:
                errors.append(str(e))
        for r in rows:
            if r["id"] in full and full[r["id"]].get("title"):
                r["title"], r["title_truncated"] = full[r["id"]]["title"], False

        try:
            receipts = receipts_f.result()
        except (CommandError, ValueError) as e:
            receipts = {}
            errors.append(f"inbox receipts: {e}")
        answers = _answers_by_decision(receipts)

        decisions = []
        for r in holds:
            rec = full.get(r["id"], {})
            reason = rec.get("hold_reason") or r.get("hold_reason", "")
            body = rec.get("body", "")
            decisions.append({
                "id": r["id"], "title": r["title"], "repo": _blank(r.get("repo", "")), "kind": r.get("kind", ""),
                "reason": reason, "created": r.get("created", ""),
                "origin": _origin(body), "reports": self.report_refs(reason, body),
                "digest": decision_digest(r["id"], r["title"], reason),
                "answers": answers.get(r["id"], []),
            })

        in_flight = []
        for r in live:
            meta = metas[r["id"]]
            if r["id"] in states:
                try:
                    cs = states[r["id"]].result()
                except CommandError as e:
                    cs = {"state": "unknown", "source": "none", "detail": str(e)}
            else:
                cs = {"state": "unknown", "source": "none", "detail": "no state/<id>.meta"}
            last, mtime, prs = self.status_tail(r["id"])
            if meta.get("pr") and meta["pr"] not in prs:
                prs.insert(0, meta["pr"])
            in_flight.append({
                "id": r["id"], "title": r["title"], "repo": _blank(r.get("repo", "")), "kind": r.get("kind", ""),
                "mode": meta.get("mode", ""), "window": meta.get("window", ""), "pane_id": meta.get("herdr_pane_id"),
                "branch": meta.get("branch"), "worktree": meta.get("worktree"), "harness": meta.get("harness", ""),
                "crew": cs, "last_event": last, "updated_at": _iso(mtime), "prs": prs,
                "attention": cs["state"] in ATTENTION_STATES,
            })

        queued = [{"id": r["id"], "title": r["title"], "repo": _blank(r.get("repo", "")), "kind": r.get("kind", ""),
                   "held": r.get("held") == "yes", "hold_kind": r.get("hold_kind", ""), "hold_reason": r.get("hold_reason", ""),
                   "created": r.get("created", "")}
                  for r in rows if r.get("state") == "queued" and r["id"] not in hold_ids]
        done = sorted(({"id": r["id"], "title": r["title"], "repo": _blank(r.get("repo", "")), "kind": r.get("kind", ""),
                        "closed": r.get("closed", ""), "prs": self.status_tail(r["id"])[2]}
                       for r in rows if r.get("state") == "done"), key=lambda d: d["closed"], reverse=True)

        counts = {"open_decisions": len(decisions), "attention_tasks": sum(1 for t in in_flight if t["attention"]),
                  "in_flight": len(in_flight), "queued": len(queued), "done_recent": len(done)}
        fp_src = json.dumps([[d["id"], d["digest"], len(d["answers"])] for d in decisions]
                            + [[t["id"], t["crew"]["state"], t["last_event"]] for t in in_flight]
                            + [[q["id"]] for q in queued] + [[d["id"]] for d in done])
        return {"ok": True, "errors": errors, "generated": _iso(dt.datetime.now().timestamp()), "home": str(self.home),
                "decisions": decisions, "in_flight": in_flight, "queued": queued, "done": done, "counts": counts,
                "fingerprint": hashlib.sha256(fp_src.encode()).hexdigest()[:16]}


def decision_digest(task_id: str, title: str, reason: str) -> str:
    """Binds an answer to the exact decision text the captain was shown."""
    return hashlib.sha256(json.dumps([task_id, title, reason]).encode()).hexdigest()[:16]


def request_id(decision_id: str, digest: str, text: str) -> str:
    """fm-inbox.sh's idempotency key: same answer to the same decision text is
    one note however many times the form is resubmitted."""
    safe = re.sub(r"[^A-Za-z0-9._:-]", "_", decision_id)[:80]
    return f"dash-{safe}-{digest[:8]}-{hashlib.sha256(text.encode()).hexdigest()[:12]}"


def _origin(body: str) -> str:
    m = re.search(r"^Captain hold origin: (.+)$", body or "", re.M) or re.search(r"^Origin: (.+)$", body or "", re.M)
    return m.group(1).strip() if m else ""


def _answers_by_decision(receipts: dict) -> dict[str, list[dict]]:
    """Inbox notes this dashboard sent, keyed by decision id (from request_id)."""
    replies = {r.get("id") or r.get("note_id"): r for r in receipts.get("replies", []) or [] if isinstance(r, dict)}
    out: dict[str, list[dict]] = {}
    for bucket, acked in (("pending", False), ("handled", True)):
        for n in receipts.get(bucket, []) or []:
            rid = str(n.get("request_id") or "")
            m = re.match(r"^dash-(.+)-[0-9a-f]{8}-[0-9a-f]{12}$", rid)
            if not m:
                continue
            reply = n.get("reply") or replies.get(n.get("id"))
            out.setdefault(m.group(1), []).append({
                "note": n.get("id"), "at": n.get("at"), "acknowledged": bool(n.get("acknowledged", acked)),
                "reply": reply.get("body") if isinstance(reply, dict) else reply,
            })
    return out
