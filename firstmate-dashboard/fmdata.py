"""fmdata — read a Firstmate home through its own CLIs, never its files' internals.

Everything here is a read: `fm-tasks-axi.sh list|show`, `fm-crew-state.sh`,
`fm-inbox.sh receipts`, plus `state/<id>.meta` and `state/<id>.status`. The
one write the dashboard makes (an inbox note) lives in server.py, behind the
same CLI the captain would type.

The two per-task reads are cached, since re-running them every refresh cost
about half a core: a crew's `fm-crew-state.sh` reading until its state files
change or it is CREW_MAX_AGE_S old (each crew row says when it was read), and
a `show` while `data/backlog.md` and the task's list row are unchanged.

Evolution-loop signals are the one read that leaves the machine: the alert
issues named in `state/evolution-loop.seen` are looked up with `gh issue view`
at most once per SIGNAL_REFRESH_S, so a closed alert drops off the bounty
board instead of staying "open" forever.

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
import shutil
import subprocess
import threading
import time
from pathlib import Path

CMD_TIMEOUT_S = 15
# fm-crew-state.sh is most of a snapshot's CPU (~0.3 s per crew). A crew is
# re-read when its state/<id>.meta or .status changes (every event a crew
# reports lands there), else its cached reading is reused; one cached reading
# at least CREW_MAX_AGE_S old is re-read per refresh, so a change only a
# pane or a no-mistakes run shows is picked up within max(CREW_MAX_AGE_S,
# crews x refresh interval).
CREW_MAX_AGE_S = 60
CREW_ROTATE = 1
# Crew states (fm-crew-state.sh's vocabulary) that want a human or firstmate.
ATTENTION_STATES = ("blocked", "failed", "parked")
PR_URL = re.compile(r"https://[^\s\"'<>()]+/(?:pull|merge_requests)/\d+")
# A path a hold reason names, relative to the home: "data/<id>/report.md".
REPORT_REF = re.compile(r"(?<![\w/.-])data/[A-Za-z0-9._/-]+\.(?:md|txt|json|log)\b")
# A task's own report: what the Reports view lists and serves.
REPORT_FILE = re.compile(r"data/([A-Za-z0-9][A-Za-z0-9._-]*)/report\.md")
_TABLE_HEAD = re.compile(r"^(\w+)\[(\d+)\]\{([^}]*)\}:\s*$")
_CELL = re.compile(r'\s*("(?:[^"\\]|\\.)*"|[^,]*?)\s*(,|$)')
_TRUNC = re.compile(r"\n\.\.\. \(truncated.*$", re.S)
# tasks-axi `links`: `pr:<url>` / `report:<data path>`, space/comma separated.
_LINK = re.compile(r"(?:^|[\s,;])(pr|report):(\S+?)(?=$|[\s,;])")
# The evolution loop's seen-set (state/evolution-loop.seen, written by its
# custom check): `issue:<repo>:<number>:<updatedAt>` per alert-issue update.
SIGNALS_SEEN = "evolution-loop.seen"
_SIGNAL_ISSUE = re.compile(r"^issue:([A-Za-z0-9._-]+):(\d+):(\S+)$")
_GH_SLUG = re.compile(r"github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$")
SIGNAL_REFRESH_S = 600
SIGNAL_MAX = 12
# Bounty statuses, in board order (prototype/board/fixtures/bounties.json).
BOUNTY_STATUSES = ("open", "in_progress", "awaiting_evidence", "verified")
# What closes a backlog item, by Firstmate task kind.
EVIDENCE = {
    "ship": "A merged PR recorded on the backlog row.",
    "scout": "A report recorded on the backlog row (data/<id>/report.md).",
    "captain": "Your resolution recorded on the backlog row.",
    "review": "A review report or merged PR recorded on the backlog row.",
    "secondmate": "The secondmate's landed work recorded on the backlog row.",
}
EVIDENCE_DEFAULT = "A merged PR or report recorded on the backlog row."


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


def parse_links(value: str) -> dict:
    """tasks-axi `links` -> {"pr": [...], "report": [...]}."""
    out: dict[str, list[str]] = {"pr": [], "report": []}
    for kind, ref in _LINK.findall(value or ""):
        if ref not in out[kind]:
            out[kind].append(ref)
    return out


def github_slug(remote_url: str) -> str:
    m = _GH_SLUG.search((remote_url or "").strip())
    return m.group(1) if m else ""


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


def _stamp(path: Path) -> tuple[int, int, int] | None:
    """A file's (inode, size, mtime_ns): any rewrite or append changes it."""
    try:
        s = path.stat()
    except OSError:
        return None
    return (s.st_ino, s.st_size, s.st_mtime_ns)


class Home:
    """One Firstmate home. `root` holds bin/ (the code), `home` holds state/
    and data/ (FM_HOME); they are the same directory in the usual layout."""

    def __init__(self, home: Path, root: Path | None = None, gh: str | None = None):
        self.home = Path(home).resolve()
        self.root = Path(root).resolve() if root else self.home
        self.state = self.home / "state"
        self.data = self.home / "data"
        self.gh = gh if gh is not None else (shutil.which("gh") or "")
        # Done rows never change title, and a repo's GitHub remote rarely
        # does: read each once instead of on every 10s refresh.
        self._done_titles: dict[str, str] = {}
        self._slugs: dict[str, str] = {}
        self._issues: dict[tuple[str, str], dict] = {}
        # task id -> {"stamp", "at", "cs"}: the last crew-state reading.
        self._crew: dict[str, dict] = {}
        # task id -> (key, record): a `show` is reused while the backlog file
        # and the task's list row are unchanged.
        self._shows: dict[str, tuple[tuple, dict]] = {}
        self._lock = threading.Lock()

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
        out = self.run("fm-tasks-axi.sh", "list", "--fields", "held,hold_kind,hold_reason,closed,created,links,blocked_by")
        return parse_table(out)

    def show(self, task_id: str) -> dict:
        return parse_record(self.run("fm-tasks-axi.sh", "show", task_id, "--full"))

    def crew_state(self, task_id: str) -> dict:
        out = self.run("fm-crew-state.sh", task_id)
        line = next((ln for ln in out.splitlines() if ln.startswith("state: ")), "")
        return parse_crew_state(line) if line else {"state": "unknown", "source": "none", "detail": out.strip()[:200]}

    def receipts(self) -> dict:
        return json.loads(self.run("fm-inbox.sh", "receipts") or "{}")

    def repo_slug(self, repo: str) -> str:
        """`owner/name` of projects/<repo>'s GitHub origin, or "" if none."""
        with self._lock:
            if repo in self._slugs:
                return self._slugs[repo]
        slug, path = "", self.home / "projects" / repo
        if repo and path.is_dir():
            try:
                p = subprocess.run(["git", "-C", str(path), "remote", "get-url", "origin"],
                                   capture_output=True, text=True, timeout=5)
                slug = github_slug(p.stdout) if p.returncode == 0 else ""
            except (OSError, subprocess.TimeoutExpired):
                pass
        with self._lock:
            self._slugs[repo] = slug
        return slug

    def signal_keys(self) -> list[tuple[str, str, str]]:
        """(repo, issue number, latest updatedAt) per alert issue in the
        evolution loop's seen-set, most recently updated first."""
        try:
            text = (self.state / SIGNALS_SEEN).read_text(errors="replace")
        except OSError:
            return []
        latest: dict[tuple[str, str], str] = {}
        for ln in text.splitlines():
            m = _SIGNAL_ISSUE.match(ln.strip())
            if m and m.group(3) > latest.get((m.group(1), m.group(2)), ""):
                latest[(m.group(1), m.group(2))] = m.group(3)
        keys = sorted(latest, key=lambda k: latest[k], reverse=True)[:SIGNAL_MAX]
        return [(repo, n, latest[(repo, n)]) for repo, n in keys]

    def issue(self, repo: str, number: str, updated: str) -> dict:
        """One alert issue's state, from cache unless it is older than
        SIGNAL_REFRESH_S or the loop saw a newer update. A failed lookup is
        cached too, so a missing `gh` is not retried every refresh."""
        now = time.time()
        with self._lock:
            hit = self._issues.get((repo, number))
        if hit and hit["updated"] == updated and now - hit["checked"] < SIGNAL_REFRESH_S:
            return hit
        rec = {"repo": repo, "number": number, "updated": updated, "checked": now,
               "state": "unknown", "title": "", "url": "", "error": ""}
        slug = self.repo_slug(repo)
        if slug:
            rec["url"] = f"https://github.com/{slug}/issues/{number}"
        if not slug:
            rec["error"] = f"no projects/{repo} checkout with a GitHub origin"
        elif not self.gh:
            rec["error"] = "gh is not installed"
        else:
            try:
                p = subprocess.run([self.gh, "issue", "view", number, "-R", slug, "--json", "state,title,url"],
                                   capture_output=True, text=True, timeout=CMD_TIMEOUT_S)
                if p.returncode == 0:
                    d = json.loads(p.stdout)
                    rec["state"] = str(d.get("state") or "unknown").lower()
                    rec["title"] = str(d.get("title") or "")
                    if str(d.get("url") or "").startswith("https://"):
                        rec["url"] = d["url"]
                else:
                    rec["error"] = f"gh issue view: exit {p.returncode}: {(p.stderr or '').strip()[:160]}"
            except (OSError, subprocess.TimeoutExpired, ValueError) as e:
                rec["error"] = f"gh issue view: {type(e).__name__}"
        with self._lock:
            self._issues[(repo, number)] = rec
        return rec

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

    def reports(self) -> list[dict]:
        """Every data/<id>/report.md that resolves inside data/, newest first."""
        out = []
        for p in self.data.glob("*/report.md"):
            rel = f"data/{p.parent.name}/report.md"
            if not REPORT_FILE.fullmatch(rel) or self.report_file(rel) is None:
                continue
            try:
                st = p.stat()
            except OSError:
                continue
            out.append({"path": rel, "id": p.parent.name, "mtime": st.st_mtime, "updated": _iso(st.st_mtime), "size": st.st_size})
        return sorted(out, key=lambda r: r["mtime"], reverse=True)

    # ── the joined snapshot ───────────────────────────────────────────────
    def snapshot(self, fresh: bool = False) -> dict:
        """`fresh` re-runs every `show` (an answer's decision binding must not
        rest on a cached record); crew readings are cached either way."""
        errors: list[str] = []
        try:
            rows = self.tasks()
        except CommandError as e:
            return {"ok": False, "errors": [str(e)], "generated": _iso(dt.datetime.now().timestamp()),
                    "home": str(self.home), "decisions": [], "in_flight": [], "queued": [], "done": [],
                    "bounties": [], "counts": {}, "fingerprint": ""}
        for r in rows:
            r["title"], r["title_truncated"] = untruncate(r.get("title", ""))
            for k in ("hold_reason", "hold_kind", "closed", "created", "held", "blocked_by"):
                r[k] = _blank(r.get(k, ""))
            r["links"] = parse_links(r.get("links", ""))
            if r.get("state") == "done" and r["id"] in self._done_titles:
                r["title"], r["title_truncated"] = self._done_titles[r["id"]], False

        holds = [r for r in rows if r.get("held") == "yes" and r.get("hold_kind") == "captain" and r.get("state") != "done"]
        hold_ids = {r["id"] for r in holds}
        live = [r for r in rows if r.get("state") == "in_flight"]
        metas = {r["id"]: parse_meta(self.state / f"{r['id']}.meta") for r in live}
        now = time.time()
        backlog = _stamp(self.data / "backlog.md")  # None for a non-markdown backlog: never cached
        show_keys = {r["id"]: (backlog, json.dumps(r, sort_keys=True))
                     for r in rows if r["id"] in hold_ids or r["title_truncated"]}
        # Stamped before the reads, so a write during one is re-read next refresh.
        stamps = {r["id"]: (_stamp(self.state / f"{r['id']}.meta"), _stamp(self.state / f"{r['id']}.status"))
                  for r in live if metas[r["id"]]}
        with self._lock:
            full = {tid: rec for tid, (key, rec) in self._shows.items()
                    if backlog and not fresh and show_keys.get(tid) == key}
            crew = {tid: e for tid, e in self._crew.items() if tid in stamps}
        reread = [tid for tid in stamps if tid not in crew or crew[tid]["stamp"] != stamps[tid]]
        stale = sorted((crew[tid]["at"], tid) for tid in stamps
                       if tid in crew and tid not in reread and now - crew[tid]["at"] >= CREW_MAX_AGE_S)
        reread += [tid for _, tid in stale[:CREW_ROTATE]]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            shows = {tid: pool.submit(self.show, tid) for tid in show_keys if tid not in full}
            states = {tid: pool.submit(self.crew_state, tid) for tid in reread}
            receipts_f = pool.submit(self.receipts)
            issues_f = [pool.submit(self.issue, *k) for k in self.signal_keys()]

        for tid, f in states.items():
            try:
                crew[tid] = {"stamp": stamps[tid], "at": now, "cs": f.result()}
            except CommandError as e:  # not cached: retried next refresh
                crew[tid] = {"stamp": None, "at": now, "cs": {"state": "unknown", "source": "none", "detail": str(e)}}
        with self._lock:
            self._crew = {tid: e for tid, e in crew.items() if e["stamp"] is not None}

        for tid, f in shows.items():
            try:
                full[tid] = f.result()
            except CommandError as e:  # not cached: retried next refresh
                errors.append(str(e))
        with self._lock:
            self._shows = {tid: (key, full[tid]) for tid, key in show_keys.items() if backlog and tid in full}
        for r in rows:
            if r["id"] in full and full[r["id"]].get("title"):
                r["title"], r["title_truncated"] = full[r["id"]]["title"], False
                if r.get("state") == "done":
                    self._done_titles[r["id"]] = r["title"]

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
            if r["id"] in crew:
                e = crew[r["id"]]
                cs = {**e["cs"], "observed_at": _iso(e["at"])}
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
                   "blocked_by": r.get("blocked_by", ""), "created": r.get("created", "")}
                  for r in rows if r.get("state") == "queued" and r["id"] not in hold_ids]
        done = sorted(({"id": r["id"], "title": r["title"], "repo": _blank(r.get("repo", "")), "kind": r.get("kind", ""),
                        "closed": r.get("closed", ""), "links": r["links"],
                        "report_files": [p for p in r["links"]["report"] if self.report_file(p)]}
                       for r in rows if r.get("state") == "done"), key=lambda d: d["closed"], reverse=True)
        issues = [f.result() for f in issues_f]
        board = bounties(decisions, queued, in_flight, done, issues)

        counts = {"open_decisions": len(decisions), "attention_tasks": sum(1 for t in in_flight if t["attention"]),
                  "in_flight": len(in_flight), "queued": len(queued), "done_recent": len(done)}
        fp_src = json.dumps([[d["id"], d["digest"], len(d["answers"])] for d in decisions]
                            + [[t["id"], t["crew"]["state"], t["last_event"]] for t in in_flight]
                            + [[q["id"]] for q in queued] + [[d["id"]] for d in done]
                            + [[b["id"], b["status"]] for b in board])
        return {"ok": True, "errors": errors, "generated": _iso(dt.datetime.now().timestamp()), "home": str(self.home),
                "decisions": decisions, "in_flight": in_flight, "queued": queued, "done": done, "bounties": board,
                "counts": counts, "fingerprint": hashlib.sha256(fp_src.encode()).hexdigest()[:16]}


def _mentions(text: str, url: str, repo: str, number: str) -> bool:
    """`text` names this issue by URL or `repo#n` (not `repo#n0`)."""
    refs = [re.escape(url)] if url else []
    refs.append(re.escape(f"{repo}#{number}"))
    return re.search(f"(?:{'|'.join(refs)})(?!\\d)", text) is not None


def bounties(decisions: list[dict], queued: list[dict], in_flight: list[dict], done: list[dict],
             issues: list[dict]) -> list[dict]:
    """Big Shot's board: Firstmate work outside the crew rooms, and the
    evidence that closes it. A card reads `verified` only when the backlog
    row records a merged PR (`pr:` link, written at landing cleanup) or a
    report file that exists; nothing else, however done it looks, counts.

    Sources: captain holds, queued backlog rows, crews that report done
    before Firstmate records a delivery, closed rows (captain-kind rows are
    answered calls, not deliveries, so they are left out, as Firstmate's
    own Recently Landed does), and the evolution loop's alert issues."""
    out: list[dict] = []

    def add(bid, source, objective, owner, kind, status, note, evidence, proof=None, href=""):
        out.append({"id": bid, "source": source, "objective": objective, "owner": owner or "(no repo)",
                    "kind": kind, "status": status, "note": note, "evidence": evidence, "proof": proof, "href": href})

    for d in decisions:
        if d["answers"]:
            picked = any(a["acknowledged"] for a in d["answers"])
            status, note = "in_progress", ("Your answer reached Firstmate; it records the resolution next."
                                           if picked else "Your answer is in Firstmate's inbox, not yet picked up.")
        else:
            status, note = "open", "Held for the captain; nothing moves until it is answered."
        add(d["id"], "captain hold", d["title"], d["repo"], d["kind"], status, note,
            "The resolution recorded on the backlog row.", href=f"#d-{d['id']}")
    for q in queued:
        if q["held"]:
            note = f"Held ({q['hold_kind'] or 'hold'}): {q['hold_reason']}"
        elif q["blocked_by"]:
            note = f"Starts after {q['blocked_by']}."
        else:
            note = "Ready; no crew on it yet."
        add(q["id"], "backlog", q["title"], q["repo"], q["kind"], "open", note,
            EVIDENCE.get(q["kind"], EVIDENCE_DEFAULT))
    for t in in_flight:
        if t["crew"]["state"] == "done":
            add(t["id"], "backlog", t["title"], t["repo"], t["kind"], "awaiting_evidence",
                "Crew reports done; Firstmate has not recorded a merged PR or report on the row yet.",
                EVIDENCE.get(t["kind"], EVIDENCE_DEFAULT), href=f"#t-{t['id']}")
    for d in done:
        if d["kind"] == "captain":
            continue
        if d["links"]["pr"]:
            proof = {"kind": "pr", "ref": d["links"]["pr"][0]}
        elif d["report_files"]:
            proof = {"kind": "report", "ref": d["report_files"][0]}
        else:
            proof = None
        add(d["id"], "backlog", _strip_proof(d["title"], proof), d["repo"], d["kind"],
            "verified" if proof else "awaiting_evidence",
            f"Closed {d['closed']}." if proof else f"Closed {d['closed']} with no merged PR or report on record.",
            EVIDENCE.get(d["kind"], EVIDENCE_DEFAULT), proof)
    for i in issues:
        if i["state"] == "closed":
            continue  # the alert cleared; the row that fixed it carries its own evidence
        ref = f"{i['repo']}#{i['number']}"
        live = next((t for t in in_flight if _mentions(t["title"] + " " + " ".join(t["prs"]), i["url"], i["repo"], i["number"])), None)
        fixed = next((d for d in done if d["links"]["pr"]
                      and _mentions(d["title"] + " " + " ".join(d["links"]["pr"]), i["url"], i["repo"], i["number"])), None)
        if live:
            status, note = "in_progress", f"Crew {live['id']} is on it."
        elif fixed:
            status, note = "awaiting_evidence", f"{fixed['id']} landed a fix; the alert issue is still open."
        else:
            status, note = "open", "No crew on it yet."
        if i["error"]:
            note += f" Issue state not re-checked: {i['error']}."
        add(f"signal-{i['repo']}-{i['number']}", "evolution loop", i["title"] or f"Alert issue {ref}", i["repo"], "",
            status, note, "The alert issue closed after a merged fix.",
            {"kind": "issue", "ref": i["url"]} if i["url"] else None)
    order = {s: n for n, s in enumerate(BOUNTY_STATUSES)}
    out.sort(key=lambda b: order[b["status"]])
    return out


def _strip_proof(title: str, proof: dict | None) -> str:
    """Firstmate appends the landed PR URL (or report path) to a closed row's
    title; the card shows it as proof, so drop it from the objective."""
    if proof:
        title = title.replace(proof["ref"], "").strip()
    return title


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
    """Inbox notes this dashboard sent, keyed by decision id (from request_id).
    `digest8` is the start of the decision digest the answer was bound to, so
    the page can tell an answer to the text shown now from one to an earlier text."""
    replies = {r.get("id") or r.get("note_id"): r for r in receipts.get("replies", []) or [] if isinstance(r, dict)}
    out: dict[str, list[dict]] = {}
    for bucket, acked in (("pending", False), ("handled", True)):
        for n in receipts.get(bucket, []) or []:
            rid = str(n.get("request_id") or "")
            m = re.match(r"^dash-(.+)-([0-9a-f]{8})-[0-9a-f]{12}$", rid)
            if not m:
                continue
            reply = n.get("reply") or replies.get(n.get("id"))
            out.setdefault(m.group(1), []).append({
                "note": n.get("id"), "at": n.get("at"), "acknowledged": bool(n.get("acknowledged", acked)),
                "reply": reply.get("body") if isinstance(reply, dict) else reply, "digest8": m.group(2),
            })
    return out
