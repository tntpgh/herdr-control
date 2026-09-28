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
#   scripts/shadow-compare.sh --gate [--explained FILE]
#       Terrence's canary gate (hook-cutover decision q1, 2026-09-27): PASS
#       only when ALL hold over shadow-mode rows —
#         (a) at least 5 days since the first shadow row,
#         (b) at least 1,000 rows across at least 5 tasks,
#         (c) disagreement (SHADOW_LOOSER + SHADOW_TIGHTER) at most 2% of the
#             rows that could be compared (a herdr decision is on record),
#         (d) every SHADOW_LOOSER row explained by hand: a line
#             "<seq><TAB><explanation>" in FILE (default
#             $HERDR_RUN_STATE_DIR/shadow-explained.tsv).
#       Prints one PASS/FAIL line per criterion and the verdict; exit 0 PASS,
#       1 FAIL. Enforce-mode rows (hook-approval tasks) are not shadow data
#       and are excluded.
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
#     the same pane within 10 min whose recorded command matches the same way.
#   other tools: nearest approvals row / approval_escalated on the same pane
#     within 120 s whose panel names the same tool ("Allow tool: <name>").
#   An approval_escalated event with no recorded command (written before
#   herdr-select.sh recorded one) joins nothing: pane + time alone attributed a
#   neighbour's refusal to every read/grep/bash on that pane, which was most of
#   the 2026-09-27 gate's 41.7% "disagreement".
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
import os
if not os.path.exists(db):
    print(f"no registry at {db}")
    if "--gate" in args: print("GATE: FAIL (no shadow data)")
    sys.exit(1 if "--gate" in args else 0)
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row

def ts(s):
    try: return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception: return None
def collapse(s): return re.sub(r"\s+", " ", s or "").strip()
def strip_panel(s):
    s = collapse(s)
    # Same rows lib/scoped-policy.sh _sp_command_region skips: omp puts
    # "Origin: MCP server tool" / "Reason: Critical pattern detected" between
    # the header and Command: (PR #181 F3).
    return re.sub(r"^(Allow tool: \S+ (; )?)?(Origin: MCP server tool (; )?)?"
                  r"(Reason: Critical pattern detected (; )?)?(Command|run): ", "", s)
def panel_tool(s):
    """Tool named by an omp approval panel; a bare command is a shell prompt;
    anything else (e.g. an off-screen header) names no tool."""
    s = collapse(s)
    m = re.match(r"^Allow tool: ([^\s;]+)", s)
    if m: return m.group(1).lower()
    return None if s.startswith("[") or not s else "bash"
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
import os
shadow_db = os.path.join(os.path.dirname(db), "pretool-shadow.sqlite3")
if not os.path.exists(shadow_db):
    print(f"no shadow store at {shadow_db} — no worker has recorded a verdict yet")
    if "--gate" in args: print("GATE: FAIL (no shadow data)")
    sys.exit(1 if "--gate" in args else 0)
sconn = sqlite3.connect(f"file:{shadow_db}?mode=ro", uri=True)
sconn.row_factory = sqlite3.Row
ev_sql = "SELECT sequence, task_id, occurred_at, payload FROM pretool_verdicts WHERE occurred_at >= ?"
params = [since]
if task_f: ev_sql += " AND task_id = ?"; params.append(task_f)
shadow = []
for r in sconn.execute(ev_sql + " ORDER BY sequence", params):
    p = json.loads(r["payload"] or "{}")
    shadow.append(dict(p, seq=r["sequence"], task_id=r["task_id"], at=r["occurred_at"]))
if not shadow:
    print("no pretool_verdict rows" + (f" for task {task_f}" if task_f else "") + " — nothing to compare")
    if "--gate" in args: print("GATE: FAIL (no shadow data)")
    sys.exit(1 if "--gate" in args else 0)

appr_all = [dict(r, pane=r["pane_id"]) for r in conn.execute(
    "SELECT approval_id, task_id, pane_id, authority, choice_text, command, decided_at FROM approvals WHERE decided_at >= ?",
    (min(s["at"] for s in shadow),))]
esc_all = []
for r in conn.execute("SELECT sequence, task_id, occurred_at, payload FROM events WHERE type='approval_escalated' AND occurred_at >= ?",
                      (min(s["at"] for s in shadow),)):
    p = json.loads(r["payload"] or "{}")
    esc_all.append({"task_id": r["task_id"], "pane": p.get("pane", ""), "occurred_at": r["occurred_at"],
                    "verdict": p.get("verdict", ""), "reason": p.get("reason", ""), "seq": r["sequence"],
                    "command": p.get("command")})

def same_prompt(cmd, s, is_shell):
    """Does a recorded panel/command belong to this shadow row's tool call?"""
    if not collapse(cmd): return False
    if is_shell:
        return sha(cmd) == s.get("command_sha256") or strip_panel(cmd) == collapse(s.get("command"))
    return panel_tool(cmd) == s.get("tool", "").lower()

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
             and (not s.get("pane") or a["pane"] in ("", s.get("pane")))
             and same_prompt(a["command"], s, is_shell)]
    if cands:
        match = min(cands, key=lambda a: a["decided_at"]); used_a.add(match["approval_id"])
        today, via = outcome(match), f"approvals:{match['approval_id']}"
    else:
        ew = timedelta(minutes=10) if is_shell else timedelta(seconds=120)
        ec = [e for e in esc if e["seq"] not in used_e and ts(e["occurred_at"]) and at
              and at <= ts(e["occurred_at"]) <= at + ew and e["pane"] in ("", s.get("pane"))
              and same_prompt(e["command"], s, is_shell)]
        if ec:
            e = min(ec, key=lambda e: e["occurred_at"]); used_e.add(e["seq"])
            today, via = "refused", f"approval_escalated:{e['seq']}({e['verdict']})"
    sv = s.get("verdict", "")
    if today == "none": kind = "no-record"
    elif (sv == "allow") == (today == "auto"): kind = "agree"
    elif sv == "allow": kind = "SHADOW_LOOSER"
    else: kind = "SHADOW_TIGHTER"
    results.append(dict(s, today=today, via=via, kind=kind))

if "--gate" in args:
    rows = [r for r in results if r.get("mode", "shadow") == "shadow"]
    explained_path = opt("--explained", os.path.join(os.path.dirname(db), "shadow-explained.tsv"))
    explained = {}
    if os.path.exists(explained_path):
        for line in open(explained_path, encoding="utf-8", errors="replace"):
            seq, _, why = line.rstrip("\n").partition("\t")
            if seq.strip().isdigit() and why.strip():
                explained[int(seq)] = why.strip()
    first = min((ts(r["at"]) for r in rows if ts(r["at"])), default=None)
    days = (datetime.now(timezone.utc) - first).total_seconds() / 86400 if first else 0.0
    n_tasks = len({r["task_id"] for r in rows})
    compared = [r for r in rows if r["kind"] in ("agree", "SHADOW_LOOSER", "SHADOW_TIGHTER")]
    n_dis = sum(1 for r in compared if r["kind"] != "agree")
    rate = n_dis / len(compared) if compared else None
    loose = [r for r in rows if r["kind"] == "SHADOW_LOOSER"]
    unexplained = [r for r in loose if r["seq"] not in explained]
    # An escalation with no recorded command (written before herdr-select.sh
    # recorded one, or an unreadable panel) can join nothing, so every refusal
    # it stands for is silently absent from (c)/(d). Until those age out of the
    # window the gate cannot have compared refusals at all (PR #181 F2).
    uncompared = [e for e in esc_all if not collapse(e.get("command"))]
    checks = [
        ("a", days >= 5, f"shadow data spans {days:.1f} days (need >= 5)"),
        ("b", len(rows) >= 1000 and n_tasks >= 5, f"{len(rows)} rows across {n_tasks} tasks (need >= 1000 across >= 5)"),
        ("c", rate is not None and rate <= 0.02,
         f"disagreement {n_dis}/{len(compared)} compared rows = " + (f"{rate:.2%}" if rate is not None else "n/a (nothing comparable)") + " (need <= 2%)"),
        ("d", not unexplained, f"{len(loose)} SHADOW_LOOSER rows, {len(unexplained)} unexplained (need 0; explain in {explained_path})"),
        ("e", not uncompared, f"{len(uncompared)} approval_escalated events in the window record no command — "
                              "those refusals cannot be compared (need 0; they age out of the window)"),
    ]
    for key, passed, text in checks:
        print(f"{'PASS' if passed else 'FAIL'}  ({key}) {text}")
    for r in unexplained[:50]:
        print(f"      unexplained seq={r['seq']} task={r['task_id']} tool={r['tool']}: {(r.get('command') or r.get('reason') or '')[:160]}")
    verdict = all(p for _, p, _ in checks)
    print(f"GATE: {'PASS' if verdict else 'FAIL'}")
    sys.exit(0 if verdict else 1)

if "--json" in args:
    print(json.dumps(results, indent=1)); sys.exit(0)

print(f"pretool_verdict rows: {len(results)}  (store {shadow_db}, registry {db}; both read-only)")
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
