# Where herdr state lives: SQLite, JSONL, or a plain JSON map

Date: 2026-09-09. Written because the question ("shouldn't this be a database?")
has now been asked twice, and `docs/control-plane-design.md:224` still lists
"unify the events file into the registry" as unbuilt — with no record of whether
it *should* be built.

Verdict up front: **the split we have is already the right one.** The registry
is SQLite, the bus is JSONL, and one small keyed map stays JSON. What was
actually broken was not the format but the *write* — see §4.

## 1. Measured inventory (2026-09-09)

| surface | store | size now | writers | access pattern |
|---|---|---|---|---|
| herdr run registry (`~/.local/state/herdr/runs/registry.sqlite3`) | **SQLite, WAL** | 1.2 MB, `tasks=31`, `events=1240` | every conductor + hook on the machine | relational queries, per-task state transitions, dedup per conductor |
| worker→conductor bus (`<worktree>/.handoffs/events.jsonl`) | JSONL | 6 files, 44 lines total | **one worker per worktree** | `>>` append; `grep -E` / `tail -1` |
| KB→thurber-os gate evidence (`<repo>/.handoffs/gate-evidence.jsonl`) | JSONL | 34 + 2 lines | one session at a time | append; human + `wake-on-evidence.sh` grep |
| notepad sync cursors (`~/.omp/agent/notepad-mnemopi-sync-cursors.json`) | JSON map | 9 KB, 57 keys | **every concurrent omp session** | read-all, update one key, write-all |
| omp's own `agent.db` / `history.db` / `models.db` / `mnemopi.db` | SQLite, WAL | 1.4–6.0 MB, 21/8/1/33 tables | omp | not ours to decide |

## 2. Why the registry is SQLite and must stay

It answers relational questions across runs — "which tasks of this conductor are
still running", "has this event already been reported to this conductor",
"rebaseline this pane fingerprint" — with concurrent writers from hooks that
fire on unrelated sessions. That is a database workload, it already uses WAL
plus a busy timeout (`HERDR_REGISTRY_BUSY_MS`), and `verify-run-registry.sh`
(66 checks) pins the behaviour.

## 3. Why the bus is NOT going into it

Four properties that a table cannot reproduce, each load-bearing:

1. **The append is the entire API.** A worker signals completion with
   `echo '{"event":"...","commit":"..."}' >> .handoffs/events.jsonl`. That works
   from any agent CLI (`HERDR_AGENT_CMD`: omp · claude · codex · aider), inside
   a sandbox, with no `sqlite3` binary, no schema knowledge, no db path, and no
   lock to contend for. A single-line append under `PIPE_BUF` is atomic on
   POSIX, and there is exactly **one worker per worktree**, so there is no
   multi-writer problem to solve.
2. **It is worktree-scoped on purpose.** `git worktree remove` deletes the bus
   with the branch (`SKILL.md:110`). A row in a machine-global registry would
   outlive the work it described and need its own reaping.
3. **It is the independent witness.** Reconciliation compares the registry's
   idea of a task against the *worktree's own* record. Both living in one file
   would delete the corroboration — a task marked lost could no longer be
   contradicted by evidence the worker itself wrote.
4. **It survives the registry.** Wipe `~/.local/state/herdr`, and every finished
   worker's completion event is still on disk next to its branch.

The cost of keeping it: readers must handle a half-written or malformed line.
They already do — `lib/reconcile.sh` parses line-by-line precisely so one bad
line cannot abort the file.

## 4. The cursor map: the format was fine, the write was not

`notepad-mnemopi-sync-cursors.json` is the one surface where "should this be a
DB?" had teeth, because it is a genuine read-modify-write with concurrent
writers (7 omp sessions were live that day). It was doing:

```python
data = json.load(open(f))      # read all
data[key] = ...                # update one
open(f, "w")                   # TRUNCATE, then refill
```

Two failure modes, both silent, both reproduced:

```
old (no lock)        CORRUPT: Extra data: line 1 column 44   -> reader's catch{} discards ALL 57 cursors
new (flock+rename)   parses OK, kept 20/20 cursors
```

and a crash between truncate and refill leaves a **0-byte** file, which the
TypeScript reader turns into `cursors = {}` — every notepad silently re-flagged
as never synced.

SQLite would fix both. So does `flock` + write-temp + `fsync` + `os.replace`,
in nine lines, with no schema, no second reader implementation, and no
migration of 57 rows — and it keeps the file greppable by hand. That is what
shipped (`~/.omp/agent/scripts/mnemopi-mark-notepad-synced.sh`), verified by
killing the writer mid-write: the real index stayed intact and byte-identical.

**Revisit the DB choice for that file if** it ever needs cross-machine access,
per-key concurrent writes at rate, or a query beyond "load the whole map" —
today's reader loads all 57 keys anyway, so a table would buy nothing.

## 4b. The same bug, one level worse: decision records

`formserve.py` and `hub.py` both answer the SAME decision file, and both did
read → check `status == "open"` → `write_text(...)`. The comment said "first
writer wins"; measured against the pre-fix code, 10 simultaneous two-surface
races produced:

```
winners=20  losers=0            <- both surfaces "won" every race; the slower one
                                   overwrote the recorded answer AND answered_via
UNPARSEABLE decision records: 1 <- interleaved truncating writes
expiry guard OVERWROTE a human's answer -> status=expired
```

That last one is an inverted guard, not a race: `status != "open" and
fields.status != "expired"` let an expiry sweep stamp `expired` over a real
answer — reporting a decision the human made as if it never came, which is the
exact failure `~/Code/AGENTS.md` names ("expiry means still-unanswered, never
declined").

Fixed with the same nine lines, factored into `lib/record_store.py`
(`claim_and_update`: re-read under `flock`, verify claimable, write via
rename). `verify-record-store.py` pins it — 12 checks including 10 real
two-process races — and a live double-POST against a running formserve records
exactly one answer.

## 5. Rule of thumb this leaves behind

- **Relational, queried, machine-global, many writers → SQLite** (WAL + busy
  timeout).
- **Append-only, one writer, scoped to a directory's lifetime, consumed by
  grep → JSONL.**
- **Small keyed map read whole → JSON, but the write MUST be lock + atomic
  rename.** A truncating `open(w)` on shared state is the bug, not the format.
