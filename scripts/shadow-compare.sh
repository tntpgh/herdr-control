#!/usr/bin/env bash
# scripts/shadow-compare.sh — measure the shadow pre-tool verdicts against what
# the approval-menu path actually did, and the autonomy goal metric.
# Design: docs/design/pretool-approval.md. Read-only: opens the registry with
# SQLite's mode=ro and never writes.
#
# Usage:
#   scripts/shadow-compare.sh [--task <task_id>] [--since <ISO>] [--json]
#       Join pretool_verdict events with the approvals table and
#       approval_escalated events per task; print agreement/disagreement counts
#       and EVERY disagreement row.
#   scripts/shadow-compare.sh --autonomy [--days N]
#       The design goal's metric over tasks created in the last N days
#       (default 7): share of tasks that closed with zero human input, and
#       human / conductor prompts per task.
#
# Joins (a prompt_id is deliberately NOT used — it is the hash of panel text
# this design retires):
#   bash/shell: the approvals row for the same task (task_id, or the task's pane
#     inside its lifetime — the peer path records an empty task_id) whose
#     command's sha256 equals the event's command_sha256, else whose
#     whitespace-collapsed command (omp's "Allow tool: … Command:" panel prefix
#     stripped) equals the event's stored command; nearest decided_at after the
#     event, within 30 min. Failing that, the first approval_escalated event on
#     the same pane within 10 min.
#   other tools: nearest approvals row / approval_escalated on the same pane
#     within 120 s (only exec-tier tools such as eval ever reach a menu).
# Today's outcome classes: auto (peer/grant Approve), conductor, human, denied,
# refused (approval_escalated), none (no record: auto-approved by omp's tier,
# answered in the terminal by hand, or never answered).
set -uo pipefail
DB="${HERDR_RUN_STATE_DIR:-$HOME/.local/state/herdr/runs}/registry.sqlite3"
exec python3 - "$DB" "$@" <<'PY'
import hashlib, json, re, sqlite3, sys
from datetime import datetime, timedelta, timezone

db, args = sys.argv[1], sys.argv[2:]
def opt(name, default=None):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else default
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row

def ts(s):
    try: return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception: return None
def collapse(s): return re.sub(r"\s+", " ", s or "").strip()
def strip_panel(s):
    s = collapse(s)
    return re.sub(r"^(Allow tool: \S+ )?(Command|run): ", "", s)
def sha(s): return hashlib.sha256((s or "").encode()).hexdigest()

tasks = {r["task_id"]: dict(r) for r in conn.execute(
    "SELECT task_id, run_id, pane_id, state, created_at, updated_at, label FROM tasks")}

def rows_for_task(table_rows, task, key_time):
    """rows belonging to a task: same task_id, or its pane during its lifetime."""
    t = tasks.get(task) or {}
    lo, hi = ts(t.get("created_at") or ""), ts(t.get("updated_at") or "")
    out = []
    for r in table_rows:
        if r["task_id"] == task:
            out.append(r); continue
        if not r["task_id"] and t.get("pane_id") and r["pane"] == t["pane_id"]:
            at = ts(r[key_time])
            if at and lo and at >= lo and (not hi or at <= hi + timedelta(minutes=30)):
                out.append(r)
    return out

def outcome(a):
    ch = (a["choice_text"] or "").lower()
    if ch.startswith(("deny", "no")): return "denied"
    if a["authority"] in ("peer", "grant"): return "auto"
    return a["authority"] or "unknown"

# ------------------------------------------------------------------ autonomy
if "--autonomy" in args:
    days = int(opt("--days", "7"))
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    appr = [dict(r, pane=r["pane_id"]) for r in conn.execute(
        "SELECT task_id, pane_id, authority, choice_text, decided_at FROM approvals WHERE decided_at >= ?", (since,))]
    human_ev = [dict(r, pane=json.loads(r["payload"] or "{}").get("pane", "")) for r in conn.execute(
        "SELECT task_id, type, occurred_at, payload FROM events WHERE occurred_at >= ? AND ("
        "type IN ('attention_form_served','wake_fail_alerted') OR "
        "(type='approval_escalated' AND json_extract(payload,'$.verdict')='reserved'))", (since,))]
    sel = [t for t in tasks.values() if (t["created_at"] or "") >= since]
    per = []
    for t in sel:
        a = rows_for_task(appr, t["task_id"], "decided_at")
        h = rows_for_task(human_ev, t["task_id"], "occurred_at")
        per.append({"task": t["task_id"], "label": t["label"], "state": t["state"],
                    "human": sum(1 for r in a if r["authority"] == "human") + len(h),
                    "conductor": sum(1 for r in a if r["authority"] == "conductor"),
                    "auto": sum(1 for r in a if r["authority"] in ("peer", "grant"))})
    closed = [p for p in per if p["state"] == "completed"]
    zero = [p for p in closed if p["human"] == 0]
    n = len(per) or 1
    res = {"window_days": days, "since": since, "tasks": len(per), "completed": len(closed),
           "completed_zero_human": len(zero),
           "share_completed_zero_human": round(len(zero) / len(closed), 3) if closed else None,
           "share_all_tasks_completed_zero_human": round(len(zero) / n, 3),
           "human_prompts_per_task": round(sum(p["human"] for p in per) / n, 2),
           "conductor_prompts_per_task": round(sum(p["conductor"] for p in per) / n, 2),
           "auto_approvals_per_task": round(sum(p["auto"] for p in per) / n, 2)}
    if "--json" in args: print(json.dumps({"summary": res, "tasks": per}, indent=1)); sys.exit(0)
    for k, v in res.items(): print(f"{k}: {v}")
    print("\nper task (human / conductor / auto, state, label):")
    for p in sorted(per, key=lambda p: -p["human"]):
        print(f"  {p['human']:>3} / {p['conductor']:>3} / {p['auto']:>4}  {p['state']:<9} {p['label']}")
    sys.exit(0)

# ------------------------------------------------------------------ compare
task_f, since = opt("--task"), opt("--since", "")
ev_sql = "SELECT sequence, task_id, occurred_at, payload FROM events WHERE type='pretool_verdict' AND occurred_at >= ?"
params = [since]
if task_f: ev_sql += " AND task_id = ?"; params.append(task_f)
shadow = []
for r in conn.execute(ev_sql + " ORDER BY sequence", params):
    p = json.loads(r["payload"] or "{}")
    shadow.append(dict(p, seq=r["sequence"], task_id=r["task_id"], at=r["occurred_at"]))
if not shadow:
    print("no pretool_verdict events" + (f" for task {task_f}" if task_f else "") + " — nothing to compare"); sys.exit(0)

appr_all = [dict(r, pane=r["pane_id"]) for r in conn.execute(
    "SELECT approval_id, task_id, pane_id, authority, choice_text, command, decided_at FROM approvals WHERE decided_at >= ?",
    (min(s["at"] for s in shadow),))]
esc_all = []
for r in conn.execute("SELECT sequence, task_id, occurred_at, payload FROM events WHERE type='approval_escalated' AND occurred_at >= ?",
                      (min(s["at"] for s in shadow),)):
    p = json.loads(r["payload"] or "{}")
    esc_all.append({"task_id": r["task_id"], "pane": p.get("pane", ""), "occurred_at": r["occurred_at"],
                    "verdict": p.get("verdict", ""), "reason": p.get("reason", ""), "seq": r["sequence"]})

used_a, used_e = set(), set()
results = []
by_task = {}
for s in shadow:
    t = s["task_id"]
    if t not in by_task:
        by_task[t] = (rows_for_task(appr_all, t, "decided_at"), rows_for_task(esc_all, t, "occurred_at"))
    appr, esc = by_task[t]
    at = ts(s["at"]); today, via, match = "none", "", None
    is_shell = s.get("tool", "").lower() in ("bash", "shell")
    window = timedelta(minutes=30) if is_shell else timedelta(seconds=120)
    cands = [a for a in appr if a["approval_id"] not in used_a and ts(a["decided_at"]) and at
             and at - timedelta(seconds=2) <= ts(a["decided_at"]) <= at + window
             and (not s.get("pane") or a["pane"] in ("", s.get("pane")))]
    if is_shell:
        cands = [a for a in cands if sha(a["command"]) == s.get("command_sha256")
                 or strip_panel(a["command"]) == collapse(s.get("command"))]
    if cands:
        match = min(cands, key=lambda a: a["decided_at"]); used_a.add(match["approval_id"])
        today, via = outcome(match), f"approvals:{match['approval_id']}"
    else:
        ew = timedelta(minutes=10) if is_shell else timedelta(seconds=120)
        ec = [e for e in esc if e["seq"] not in used_e and ts(e["occurred_at"]) and at
              and at <= ts(e["occurred_at"]) <= at + ew and e["pane"] in ("", s.get("pane"))]
        if ec:
            e = min(ec, key=lambda e: e["occurred_at"]); used_e.add(e["seq"])
            today, via = "refused", f"approval_escalated:{e['seq']}({e['verdict']})"
    sv = s.get("verdict", "")
    if today == "none": kind = "no-record"
    elif (sv == "allow") == (today == "auto"): kind = "agree"
    elif sv == "allow": kind = "SHADOW_LOOSER"
    else: kind = "SHADOW_TIGHTER"
    results.append(dict(s, today=today, via=via, kind=kind))

if "--json" in args:
    print(json.dumps(results, indent=1)); sys.exit(0)

print(f"pretool_verdict events: {len(results)}  (registry {db}, read-only)")
tot = {}
for r in results: tot[r["kind"]] = tot.get(r["kind"], 0) + 1
print("overall: " + "  ".join(f"{k}={v}" for k, v in sorted(tot.items())))
print("\nper task: agree / SHADOW_LOOSER / SHADOW_TIGHTER / no-record   (shadow verdicts)")
for t in sorted({r["task_id"] for r in results}):
    rs = [r for r in results if r["task_id"] == t]
    c = lambda k: sum(1 for r in rs if r["kind"] == k)
    vs = {}
    for r in rs: vs[r["verdict"]] = vs.get(r["verdict"], 0) + 1
    print(f"  {t}  {(tasks.get(t) or {}).get('label','?')}: {c('agree')} / {c('SHADOW_LOOSER')} / {c('SHADOW_TIGHTER')} / {c('no-record')}"
          f"   ({', '.join(f'{k}={v}' for k, v in sorted(vs.items()))})")
dis = [r for r in results if r["kind"] in ("SHADOW_LOOSER", "SHADOW_TIGHTER")]
print(f"\ndisagreements: {len(dis)}")
for r in dis:
    what = r.get("command") or r.get("tool")
    print(f"  [{r['kind']}] seq={r['seq']} {r['at']} task={r['task_id']} tool={r['tool']} shadow={r['verdict']}/{r.get('policy')} "
          f"today={r['today']} via={r['via']}\n      {what[:300]}\n      shadow reason: {(r.get('reason') or '')[:200]}")
nr = [r for r in results if r["kind"] == "no-record" and r["verdict"] != "allow"]
print(f"\nno-record rows the shadow would NOT allow (today ran with no herdr decision on record): {len(nr)}")
for r in nr[:200]:
    print(f"  seq={r['seq']} task={r['task_id']} tool={r['tool']} shadow={r['verdict']}/{r.get('policy')}: {(r.get('command') or r.get('reason') or '')[:200]}")
PY
