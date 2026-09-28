#!/usr/bin/env python3
"""cost-report.py — LLM spend visible without anyone running a query.

.handoffs/SPEC.md (2026-09-27): $2,666 across 166 omp sessions last week;
three thurber-os conductor sessions that ran to ~855k context cost $1,208.
A compaction cap (`compaction.thresholdTokens: 300000`) went live
2026-09-27T20:00Z — this script is how we learn whether it worked, and it
runs hourly from a LaunchAgent (see com.herdr-control.cost-report.plist.template,
not installed by this PR — thurber-os's launchd/agents.yaml needs the entry).

Reads `~/.omp/agent/sessions/<escaped-cwd>/<ISO-ts>_<uuid>.jsonl` — every
omp session transcript on this machine. **These files contain client PII.**
This script parses only `type`/`timestamp`/`cwd`/`model`/`usage` and never
prints, copies or reproduces message content; nothing it touches is written
anywhere but the aggregate JSON below. Sources, one line per assistant turn
or side call:
  {"type":"session","cwd",...}                         — once per file, sets cwd
  {"type":"message","timestamp","message":{"role":"assistant","usage":{...}}}
  {"type":"model_usage","timestamp","usage":{...}}      — side calls (titles, judges)
`usage` carries `input`/`output`/`cacheRead`/`cacheWrite`/`totalTokens` and a
`cost` dict with the same four keys plus `total`. Context size of a turn is
input + cacheRead + cacheWrite (SPEC.md), never totalTokens (that includes
output, which was never in the prompt).

Output: JSON written to the herdr state dir (default matches hub.py's STATE:
~/.local/state/herdr/cost-report.json) — window totals, by cost bucket, by
repo, top 10 sessions by cost, turns over the 300k context threshold, and the
same set for the prior window so week-over-week is visible without a second
run. `--print` renders a terminal table from the same data.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

HOME = Path.home()
SESSIONS_DIR = Path(os.environ.get("HERDR_SESSIONS_DIR", HOME / ".omp/agent/sessions"))
STATE = Path(os.environ.get("HERDR_STATE_ROOT", HOME / ".local/state/herdr"))
OUT_PATH = Path(os.environ.get("HERDR_COST_REPORT_PATH", STATE / "cost-report.json"))

# compaction.thresholdTokens, live 2026-09-27T20:00Z (SPEC.md). A turn above
# this is exactly the failure mode the cap exists to prevent; turns_over_300k
# splits at CAP_LIVE_AT so "backlog from before the fix" and "the fix didn't
# work" read as different numbers, not one blended count.
CONTEXT_ALERT_THRESHOLD = 300_000
CAP_LIVE_AT = "2026-09-27T20:00:00+00:00"

COST_BUCKETS = ("input", "output", "cacheRead", "cacheWrite")

HERDR_WORKTREES = HOME / ".herdr/worktrees"
CODE_WORKTREES = HOME / "Code/.worktrees"
CODE = HOME / "Code"

_GITDIR_RE = re.compile(r"gitdir:\s*(.+?)/\.git/worktrees/")


def _parse_ts(s) -> dt.datetime | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _repo_from_git_pointer(worktree_root: Path) -> str | None:
    """`~/Code/.worktrees/<name>` is a branch label, not the repo — e.g.
    `bri-invoice` is a worktree of `tnt-skills`. Its `.git` file is a real
    pointer (`gitdir: <repo>/.git/worktrees/<name>`); read once, never shell
    to `git` for a cwd that may no longer exist on disk."""
    try:
        text = (worktree_root / ".git").read_text()
    except OSError:
        return None
    m = _GITDIR_RE.search(text)
    if not m:
        return None
    name = Path(m.group(1)).name
    return name or None


def resolve_repo(cwd: str | None) -> str:
    """cwd -> repo name. `~/.herdr/worktrees/<repo>/...` names the repo
    directly; `~/Code/.worktrees/<name>/...` does not (see above) so its
    `.git` pointer is resolved, falling back to the worktree's own name if
    the directory was since removed; a plain `~/Code/<repo>` checkout is the
    repo itself; anything else is bucketed as `other` rather than guessed."""
    if not cwd:
        return "unknown"
    try:
        p = Path(cwd)
    except (TypeError, ValueError):
        return "unknown"

    try:
        rel = p.relative_to(HERDR_WORKTREES)
        return rel.parts[0] if rel.parts else "unknown"
    except ValueError:
        pass

    try:
        rel = p.relative_to(CODE_WORKTREES)
    except ValueError:
        rel = None
    if rel is not None and rel.parts:
        name = rel.parts[0]
        return _repo_from_git_pointer(CODE_WORKTREES / name) or name

    try:
        rel = p.relative_to(CODE)
    except ValueError:
        rel = None
    # Dot-directories under ~/Code (.worktrees, .hc-smoke.XXXX scratch) are not repos.
    if rel is not None and rel.parts and not rel.parts[0].startswith("."):
        return rel.parts[0]

    return "other"


def _empty_totals() -> dict:
    return {"cost": 0.0, "by_bucket": {b: 0.0 for b in COST_BUCKETS},
            "turns": 0, "over_300k": 0, "over_300k_since_cap": 0}


def _turn_usage(obj: dict) -> dict | None:
    """The two shapes that carry billed usage (SPEC.md): an assistant
    message, or a model_usage side call. Everything else (title, session,
    custom, compaction, ...) returns None and is skipped before its
    timestamp or usage is ever touched."""
    t = obj.get("type")
    if t == "message":
        msg = obj.get("message")
        if isinstance(msg, dict) and msg.get("role") == "assistant":
            return msg.get("usage")
        return None
    if t == "model_usage":
        return obj.get("usage")
    return None


def scan(sessions_dir: Path, window_start: dt.datetime, window_end: dt.datetime,
         prev_start: dt.datetime) -> dict:
    """One pass over every session file touched since `prev_start`, splitting
    each turn into the current window, the prior window (for week-over-week),
    or neither. File selection looks back over BOTH windows (2x the report
    window) rather than just the reporting window: a session's mtime is its
    LAST append, so one that ran entirely last week and was never resumed
    would be invisible to a naive "modified in the last 7 days" filter, and
    the prior-week total would silently read zero for every such session."""
    cap_live_at = _parse_ts(CAP_LIVE_AT)
    totals = _empty_totals()
    prev_totals = _empty_totals()
    by_repo: dict[str, float] = {}
    prev_by_repo: dict[str, float] = {}
    sessions: dict[str, dict] = {}
    unreadable = 0

    for path in sessions_dir.glob("*/*.jsonl"):
        try:
            mtime = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc)
        except OSError:
            unreadable += 1
            continue
        if mtime < prev_start:
            continue
        cwd = None
        session_id = None
        try:
            with path.open(errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(obj, dict):
                        continue
                    if obj.get("type") == "session":
                        c = obj.get("cwd")
                        if isinstance(c, str):
                            cwd = c
                        sid = obj.get("id")
                        if isinstance(sid, str):
                            session_id = sid
                        continue
                    usage = _turn_usage(obj)
                    if not isinstance(usage, dict):
                        continue
                    cost = usage.get("cost")
                    if not isinstance(cost, dict):
                        continue
                    turn_total = cost.get("total")
                    if not isinstance(turn_total, (int, float)):
                        continue
                    ts = _parse_ts(obj.get("timestamp"))
                    if ts is None:
                        continue
                    in_window = window_start <= ts < window_end
                    in_prev = prev_start <= ts < window_start
                    if not (in_window or in_prev):
                        continue
                    context = sum(v for k, v in usage.items()
                                  if k in ("input", "cacheRead", "cacheWrite")
                                  and isinstance(v, (int, float)))
                    target = totals if in_window else prev_totals
                    target["cost"] += turn_total
                    target["turns"] += 1
                    for b in COST_BUCKETS:
                        v = cost.get(b)
                        if isinstance(v, (int, float)):
                            target["by_bucket"][b] += v
                    if context > CONTEXT_ALERT_THRESHOLD:
                        target["over_300k"] += 1
                        if in_window and cap_live_at is not None and ts >= cap_live_at:
                            target["over_300k_since_cap"] += 1
                    repo = resolve_repo(cwd)
                    if in_window:
                        by_repo[repo] = by_repo.get(repo, 0.0) + turn_total
                        s = sessions.setdefault(session_id or path.name,
                                                 {"repo": repo, "cost": 0.0, "turns": 0, "max_context": 0})
                        s["cost"] += turn_total
                        s["turns"] += 1
                        s["max_context"] = max(s["max_context"], context)
                    else:
                        prev_by_repo[repo] = prev_by_repo.get(repo, 0.0) + turn_total
        except OSError:
            unreadable += 1
            continue

    top = sorted(sessions.items(), key=lambda kv: kv[1]["cost"], reverse=True)[:10]
    top_sessions = [{"id_prefix": sid[:8], "repo": v["repo"], "cost": round(v["cost"], 4),
                      "turns": v["turns"], "max_context": v["max_context"]} for sid, v in top]

    def _sorted_repo_costs(d: dict) -> dict:
        return {k: round(v, 4) for k, v in sorted(d.items(), key=lambda kv: kv[1], reverse=True)}

    return {
        "window": {"start": window_start.isoformat(), "end": window_end.isoformat()},
        "prev_window": {"start": prev_start.isoformat(), "end": window_start.isoformat()},
        "total_cost": round(totals["cost"], 4),
        "prev_total_cost": round(prev_totals["cost"], 4),
        "cost_by_bucket": {k: round(v, 4) for k, v in totals["by_bucket"].items()},
        "prev_cost_by_bucket": {k: round(v, 4) for k, v in prev_totals["by_bucket"].items()},
        "cost_by_repo": _sorted_repo_costs(by_repo),
        "prev_cost_by_repo": _sorted_repo_costs(prev_by_repo),
        "top_sessions": top_sessions,
        "session_count": len(sessions),
        "turns_over_300k": totals["over_300k"],
        "turns_over_300k_since_cap": totals["over_300k_since_cap"],
        "prev_turns_over_300k": prev_totals["over_300k"],
        "unreadable_files": unreadable,
        "context_alert_threshold": CONTEXT_ALERT_THRESHOLD,
        "cap_live_at": CAP_LIVE_AT,
    }


def build_report(sessions_dir: Path, out_path: Path | None, window_days: int = 7,
                  now: dt.datetime | None = None) -> dict:
    now = now or dt.datetime.now(dt.timezone.utc)
    window_end = now
    window_start = now - dt.timedelta(days=window_days)
    prev_start = window_start - dt.timedelta(days=window_days)
    report = scan(sessions_dir, window_start, window_end, prev_start)
    report["generated_at"] = now.isoformat()
    if out_path is not None:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = out_path.with_suffix(out_path.suffix + f".tmp{os.getpid()}")
        tmp.write_text(json.dumps(report, indent=1) + "\n")
        tmp.replace(out_path)  # atomic: a reader never sees a half-written file
    return report


def _pct(cur: float, prev: float) -> str:
    if not prev:
        return "no prior-week data"
    return f"{(cur - prev) / prev * 100:+.0f}% vs prior ${prev:,.2f}"


def render_table(report: dict) -> str:
    w = report["window"]
    lines = [f"session cost report — {w['start']} .. {w['end']}",
             f"total: ${report['total_cost']:,.2f} ({_pct(report['total_cost'], report['prev_total_cost'])})",
             "", "by bucket:"]
    for b, v in report["cost_by_bucket"].items():
        lines.append(f"  {b:<11} ${v:,.2f}")
    lines += ["", "by repo:"]
    for repo, v in report["cost_by_repo"].items():
        lines.append(f"  {repo:<28} ${v:,.2f}")
    lines += ["", f"turns over {report['context_alert_threshold']:,} context: {report['turns_over_300k']}"
              f" ({report['turns_over_300k_since_cap']} since cap {report['cap_live_at']})",
              "", "top sessions:",
              f"  {'id':<10}{'repo':<28}{'cost':>10}  {'turns':>6}  {'max_ctx':>10}"]
    for s in report["top_sessions"]:
        lines.append(f"  {s['id_prefix']:<10}{s['repo']:<28}{'$' + format(s['cost'], ',.2f'):>10}"
                      f"  {s['turns']:>6}  {s['max_context']:>10,}")
    if not report["top_sessions"]:
        lines.append("  (none in window)")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sessions-dir", type=Path, default=SESSIONS_DIR)
    ap.add_argument("--out", type=Path, default=OUT_PATH,
                     help="where to write the JSON report (default: %(default)s)")
    ap.add_argument("--no-write", action="store_true",
                     help="compute and optionally print, but do not write the state file")
    ap.add_argument("--window-days", type=int, default=7)
    ap.add_argument("--now", help="ISO timestamp override, for tests")
    ap.add_argument("--print", action="store_true", dest="do_print")
    args = ap.parse_args(argv)

    now = None
    if args.now:
        now = _parse_ts(args.now)
        if now is None:
            ap.error(f"--now: could not parse {args.now!r} as an ISO timestamp")

    report = build_report(args.sessions_dir, None if args.no_write else args.out,
                           args.window_days, now)
    if args.do_print:
        print(render_table(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
