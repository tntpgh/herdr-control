#!/usr/bin/env python3
"""verify-prompt-occurrence.py — fixture-only regression suite for
lib/prompt-occurrence.py (docs/plans/dot-herdr-recovery-slices.md §2).

Every case uses a fresh temporary SQLite file carrying only the subset of
lib/run-registry.sh's schema this module reads/writes (the `events` table).
No live pane, herdr socket or real registry is touched.
"""
import importlib.util
import hashlib
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("prompt_occurrence", ROOT / "lib" / "prompt-occurrence.py")
po = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(po)  # type: ignore[union-attr]


def _fresh_db() -> str:
    fd = tempfile.NamedTemporaryFile(prefix="prompt-occ-", suffix=".sqlite3", delete=False)
    fd.close()
    conn = sqlite3.connect(fd.name)
    conn.executescript(
        """
        CREATE TABLE events (
          sequence    INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id    TEXT NOT NULL UNIQUE,
          run_id      TEXT NOT NULL,
          task_id     TEXT NOT NULL DEFAULT '',
          type        TEXT NOT NULL,
          occurred_at TEXT NOT NULL,
          payload     TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX events_by_task ON events(task_id, sequence);
        """
    )
    conn.commit()
    conn.close()
    return fd.name


IDENT = dict(run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1",
             native_session="s1", tool_call_id="c1")


class OccurrenceIdentity(unittest.TestCase):
    def test_distinct_call_ids_are_distinct_occurrences(self):
        """Concurrent identical commands with distinct call IDs stay distinct."""
        db = _fresh_db()
        a = po.record_seen(db, **{**IDENT, "tool_call_id": "c1"}, tool="bash",
                            tool_input={"command": "git status"}, source="tool_call")
        b = po.record_seen(db, **{**IDENT, "tool_call_id": "c2"}, tool="bash",
                            tool_input={"command": "git status"}, source="tool_call")
        self.assertNotEqual(a["occ_key"], b["occ_key"])
        folded = po.fold_task(db, "r1", "t1")
        self.assertEqual(len(folded), 2)

    def test_session_or_birth_reuse_distinguishes_identity(self):
        """A recycled pane (new birth) or a new native session must not
        resolve onto an old occurrence's key even with the same call id."""
        db = _fresh_db()
        same_call = {**IDENT, "tool_call_id": "c1"}
        a = po.record_seen(db, **same_call, tool="bash", tool_input={"command": "x"}, source="s")
        b = po.record_seen(db, **{**same_call, "pane_birth": "b2"}, tool="bash",
                            tool_input={"command": "x"}, source="s")
        c = po.record_seen(db, **{**same_call, "native_session": "s2"}, tool="bash",
                            tool_input={"command": "x"}, source="s")
        self.assertEqual(len({a["occ_key"], b["occ_key"], c["occ_key"]}), 3)

    def test_duplicate_seen_is_idempotent(self):
        """Input-cache eviction / duplicate events: repeated identical `seen`
        calls for the same occurrence must not create extra rows or disturb
        first-seen time."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "git status"},
                        source="tool_call", now=1000.0)
        out = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "git status"},
                              source="tool_approval_requested", now=2000.0)
        self.assertEqual(out["written"], "duplicate")
        folded = po.fold_task(db, "r1", "t1")
        rec = next(iter(folded.values()))
        self.assertEqual(rec["first_seen_at"], po._now_iso(1000.0))

    def test_late_enrichment_keeps_same_occurrence(self):
        """Missing input followed by verified enrichment remains ONE
        occurrence (input-cache deletion before the approval event fires)."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input=None, source="tool_approval_requested")
        out = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "git status"},
                              source="tool_call_cache")
        self.assertEqual(out["written"], "enriched")
        folded = po.fold_task(db, "r1", "t1")
        self.assertEqual(len(folded), 1)
        rec = next(iter(folded.values()))
        self.assertEqual(rec["input_digest"], po.input_digest("bash", {"command": "git status"}))
        self.assertFalse(rec["mismatch"])

    def test_changed_input_under_reused_id_is_mismatch(self):
        """Changed tool/input under the SAME call id is a mismatch, never a
        silent overwrite of the recorded occurrence."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "git status"}, source="s")
        out = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "rm -rf /"}, source="s")
        self.assertEqual(out["written"], "mismatch")
        folded = po.fold_task(db, "r1", "t1")
        rec = next(iter(folded.values()))
        self.assertTrue(rec["mismatch"])
        self.assertEqual(rec["display"], "correlation_mismatch")
        self.assertEqual(rec["input_digest"], po.input_digest("bash", {"command": "git status"}))  # original retained

    def test_changed_input_after_real_enrichment_is_mismatch_not_silent(self):
        """M2 (Main review): seen(no input) -> enriched(A) -> B must be a
        mismatch against A, never silently absorbed as another enrichment."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input=None, source="s")
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "git status"}, source="s")
        out = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "rm -rf /"}, source="s")
        self.assertEqual(out["written"], "mismatch")
        rec = po.occurrence_state(db, **IDENT)
        self.assertTrue(rec["mismatch"])
        self.assertEqual(rec["input_digest"], po.input_digest("bash", {"command": "git status"}))

    def test_no_raw_input_is_persisted(self):
        """M4 (Main review): the raw tool input (a command that may carry
        secrets) is never written to the durable events table — only its
        digest."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "op read op://vault/item"}, source="s")
        conn = sqlite3.connect(db)
        try:
            raw = "\n".join(r[0] for r in conn.execute("SELECT payload FROM events;").fetchall())
        finally:
            conn.close()
        self.assertNotIn("op://vault/item", raw)

    def test_identity_not_verified_when_session_or_birth_missing(self):
        """M1 (Main review): a missing native_session/pane_birth is unknown
        identity, never silently equal to another occurrence's missing
        value."""
        db = _fresh_db()
        po.record_seen(db, **{**IDENT, "pane_birth": "", "native_session": ""}, tool="bash",
                       tool_input={"command": "x"}, source="s")
        rec = po.occurrence_state(db, **{**IDENT, "pane_birth": "", "native_session": ""})
        self.assertFalse(rec["identity_verified"])
        db2 = _fresh_db()
        po.record_seen(db2, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        rec2 = po.occurrence_state(db2, **IDENT)
        self.assertTrue(rec2["identity_verified"])


    def test_deny_choice_through_authorized_is_never_approval(self):
        """H1 (Main review): a Deny recorded through record_authorized's
        `choice` must resolve as declined, never as approved."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="deny")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:declined")
        self.assertNotEqual(rec["authorization"], "approved")

    def test_completion_without_any_approval_is_withdrawn_not_completed(self):
        """H2 (Main review): a completion event for an occurrence that was
        never approved (no decision event exists anywhere in the stream)
        must never show as a clean resolved:completed."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_completed(db, **IDENT, is_error=False)
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:withdrawn")
        self.assertEqual(rec["unresolved_reason"], "completed_without_approval")

    def test_completion_for_never_seen_key_is_unknown(self):
        """H2 (Main review): a resolution event with no prior `seen` row for
        its occurrence key is not a real occurrence — stays unknown, never
        a fabricated completion."""
        db = _fresh_db()
        po.record_completed(db, **IDENT, is_error=False)
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "unknown")
        self.assertEqual(rec["unresolved_reason"], "resolution_without_seen")


class ScreenCorrelation(unittest.TestCase):
    def test_read_failed_unreadable_and_parsed_are_distinct(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_screen(db, **IDENT, display="read_failed")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["display"], "read_failed")
        po.record_screen(db, **IDENT, display="pending_unreadable")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["display"], "pending_unreadable")
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="abc123")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["display"], "pending_parseable")
        self.assertEqual(rec["screen_prompt_id"], "abc123")

    def test_resolved_occurrence_ignores_late_screen_read(self):
        """A late request/screen read cannot reopen a resolved occurrence."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        po.record_completed(db, **IDENT, is_error=False)
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="zzz")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:completed")
        self.assertEqual(rec["display"], "unknown")  # never flipped by the late read

    def test_unknown_display_never_shown_as_idle(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["display"], "unknown")
        self.assertEqual(rec["lifecycle"], "requested")


class Lifecycle(unittest.TestCase):
    def test_approval_is_not_completion(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "approved_awaiting_completion")
        self.assertNotEqual(rec["lifecycle"], "resolved")

    def test_unrecognized_choice_never_folds_as_approved(self):
        """H1 residual (Main review, dc6a55d): record_authorized's `choice`
        must be an explicit allowlist, not 'everything that is not a deny'.
        A blank choice, or a value nobody recognizes, must leave the
        occurrence exactly where it was -- never approved by default."""
        for choice in ("", "   ", "maybe", "later", "unknown-value"):
            db = _fresh_db()
            po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
            po.record_authorized(db, **IDENT, decided_by="conductor", choice=choice)
            rec = po.occurrence_state(db, **IDENT)
            self.assertEqual(rec["lifecycle"], "requested", f"choice={choice!r} must not authorize")
            self.assertNotEqual(rec["authorization"], "approved", f"choice={choice!r} must not authorize")

    def test_matching_completion_resolves(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        po.record_completed(db, **IDENT, is_error=False)
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:completed")

    def test_decline_resolves_without_execution(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_declined(db, **IDENT, reason="human denied")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:declined")

    def test_withdrawn_when_execution_ends_without_decision(self):
        """Aborted/unexecuted calls may emit an error completion without ever
        reaching tool_approval_resolved — that is a withdrawal, not a deny
        and not a silent success."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_withdrawn(db, **IDENT, reason="aborted before decision")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:withdrawn")

    def test_unverified_identity_never_authorizes_or_completes(self):
        """M1 (Main review, dc6a55d): identity_verified was computed but
        nothing enforced it. An occurrence recorded with a blank pane_birth
        or native_session must never read as approved_awaiting_completion
        or resolved:completed -- the fold itself refuses, so no consumer
        can forget to check the flag."""
        unverified = dict(IDENT, pane_birth="", native_session="")
        db = _fresh_db()
        po.record_seen(db, **unverified, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **unverified, decided_by="conductor", choice="approve")
        rec = po.occurrence_state(db, **unverified)
        self.assertFalse(rec["identity_verified"])
        self.assertEqual(rec["lifecycle"], "unknown")
        self.assertEqual(rec["authorization"], "none")
        self.assertEqual(rec["unresolved_reason"], "identity_unverified")
        # ... and the same holds once a (claimed) completion follows.
        po.record_completed(db, **unverified, is_error=False)
        rec2 = po.occurrence_state(db, **unverified)
        self.assertNotEqual(rec2["lifecycle"], "resolved:completed")

    def test_out_of_order_completion_then_late_authorized_is_sticky(self):
        """Out-of-order completion: tool_execution_end can race ahead of a
        delayed tool_approval_resolved. Once resolved, a later authorized
        event must not move it backward to approved_awaiting_completion."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_completed(db, **IDENT, is_error=False)
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        rec = po.occurrence_state(db, **IDENT)
        self.assertEqual(rec["lifecycle"], "resolved:completed")

    def test_unrelated_acknowledgements_do_not_resolve(self):
        """Disappearance, task status, idle Main, review, wake delivery and
        answered inbox are not evidence of completion — this module simply
        never receives events for them, so an occurrence with none of the
        three resolving event types stays open indefinitely."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        rec = po.occurrence_state(db, **IDENT)
        self.assertNotIn("resolved", rec["lifecycle"])


class RestartAndCrashSafety(unittest.TestCase):
    def test_crash_after_approval_is_recoverable_from_durable_events_alone(self):
        """A crash after record_authorized but before record_completed must
        leave a durable, re-foldable approved_awaiting_completion state —
        never invented completion, never lost evidence."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        # Simulate a fresh process: a brand-new connection, no in-memory state.
        rec = po.fold_task(db, "r1", "t1")[po.occurrence_key(**IDENT)]
        self.assertEqual(rec["lifecycle"], "approved_awaiting_completion")
        # The crash never fabricates a completion on its own:
        self.assertNotIn("resolved", rec["lifecycle"])

    def test_restart_replays_identical_fold(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        po.record_completed(db, **IDENT, is_error=False)
        first = po.fold_task(db, "r1", "t1")
        second = po.fold_task(db, "r1", "t1")
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))

    def test_concurrent_writers_only_one_wins_seen(self):
        """Two processes racing record_seen for the identical occurrence: the
        UNIQUE(event_id) constraint means exactly one insert lands."""
        db = _fresh_db()
        first = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="a")
        second = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="b")
        self.assertEqual(first["written"], "seen")
        self.assertEqual(second["written"], "duplicate")
        self.assertEqual(po.fold_task(db, "r1", "t1")[first["occ_key"]]["source"], "a")


class CliEntryPoint(unittest.TestCase):
    def test_cli_seen_then_fold_round_trips(self):
        db = _fresh_db()
        import io
        import contextlib

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            po.main(["seen", "--db", db, "--run", "r1", "--task", "t1", "--pane", "p1",
                     "--birth", "b1", "--session", "s1", "--call-id", "c1", "--tool", "bash",
                     "--input-json", json.dumps({"command": "git status"}), "--source", "cli"])
        out = json.loads(buf.getvalue())
        self.assertEqual(out["written"], "seen")

        buf2 = io.StringIO()
        with contextlib.redirect_stdout(buf2):
            po.main(["fold", "--db", db, "--run", "r1", "--task", "t1"])
        folded = json.loads(buf2.getvalue())
        self.assertEqual(len(folded), 1)

    def test_cli_malformed_input_json_errors_not_empty_dict(self):
        """M3 (Main review): malformed --input-json must error, never
        silently coerce to {} (which would lock in a false "known empty
        input" digest)."""
        import io
        import contextlib

        db = _fresh_db()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = po.main(["seen", "--db", db, "--run", "r", "--task", "t", "--pane", "p",
                          "--birth", "b", "--session", "s", "--call-id", "c", "--tool", "bash",
                          "--input-json", "not json", "--source", "x"])
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue())
        self.assertIn("error", out)

    def test_cli_never_raises_on_bad_input(self):
        import io
        import contextlib

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = po.main(["seen", "--db", "/nonexistent/dir/does-not-exist.sqlite3", "--run", "r",
                          "--task", "t", "--pane", "p", "--birth", "b", "--session", "s",
                          "--call-id", "c", "--tool", "bash",
                          "--input-json", json.dumps({"command": "x"}), "--source", "x"])
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue())
        self.assertIn("error", out)


def _fresh_db_with_approvals() -> str:
    """Same `events`-only fixture as `_fresh_db`, plus the `approvals` table
    lib/run-registry.sh's approval_decided()/approval_confirmed() write
    (herdr-select.sh calls approval_decided BEFORE every keystroke, then
    approval_confirmed after) -- the signal issue #309's correlation reads."""
    db = _fresh_db()
    conn = sqlite3.connect(db)
    conn.executescript(
        """
        CREATE TABLE approvals (
          approval_id    TEXT PRIMARY KEY,
          run_id         TEXT NOT NULL DEFAULT '',
          task_id        TEXT NOT NULL DEFAULT '',
          pane_id        TEXT NOT NULL DEFAULT '',
          prompt_id      TEXT NOT NULL DEFAULT '',
          choice         TEXT NOT NULL DEFAULT '',
          decided_by     TEXT NOT NULL DEFAULT '',
          authority      TEXT NOT NULL DEFAULT '',
          decided_at     TEXT NOT NULL,
          confirmed_at   TEXT,
          outcome        TEXT
        );
        CREATE INDEX approvals_by_pane ON approvals(pane_id, decided_at DESC);
        """
    )
    conn.commit()
    conn.close()
    return db


def _insert_approval(db: str, *, run_id: str, task_id: str, pane_id: str, prompt_id: str,
                      choice: str, decided_by: str, authority: str, at: float,
                      confirmed: bool = True, outcome: str = "pressed") -> None:
    conn = sqlite3.connect(db)
    conn.execute(
        "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, prompt_id, choice, "
        "decided_by, authority, decided_at, confirmed_at, outcome) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (f"appr-{at}-{prompt_id}", run_id, task_id, pane_id, prompt_id, choice, decided_by, authority,
         po._now_iso(at), po._now_iso(at) if confirmed else None, outcome),
    )
    conn.commit()
    conn.close()


class AuthorizedActorCorrelation(unittest.TestCase):
    """#309: agent-hooks/omp-herdr-control.ts can't see who pressed an
    omp-resolved approval, so it hands record_authorized() an honest
    'unverified'/'unverified_or_abort' sentinel instead of guessing "human".
    record_authorized() correlates that sentinel against the `approvals`
    table herdr-select.sh/peer-answer.sh write BEFORE the keystroke, bound to
    THIS occurrence's own on-screen prompt id and choice (review finding,
    2026-10-17), and upgrades to the real actor only when a fresh, identity-
    matching, actually-delivered row exists."""

    def test_peer_press_correlates_to_peer(self):
        db = _fresh_db_with_approvals()
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="PID-A", now=999.0)
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="PID-A", choice="1",
                          decided_by="peer-answer", authority="peer", at=1000.0)
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve", now=1000.5)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "peer-answer")

    def test_conductor_press_correlates_to_conductor(self):
        db = _fresh_db_with_approvals()
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="PID-B", now=1999.0)
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="PID-B", choice="1",
                          decided_by="conductor:w7:p2", authority="conductor", at=2000.0)
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve", now=2000.2)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "conductor:w7:p2")

    def test_unverified_never_becomes_human_without_a_row(self):
        db = _fresh_db_with_approvals()  # table exists, no row at all
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve", now=3000.0)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "unverified")
        self.assertNotEqual(rec["decided_by"], "human")

    def test_unverified_never_becomes_human_with_no_approvals_table(self):
        db = _fresh_db()  # registry predates the approvals table entirely
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="PID-C", now=2999.0)
        out = po.record_authorized(db, **IDENT, decided_by="unverified_or_abort", choice="deny", now=3000.0)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "unverified_or_abort")

    def test_stale_approval_row_outside_window_is_not_used(self):
        db = _fresh_db_with_approvals()
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="PID-D", now=999.0)
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="PID-D", choice="1",
                          decided_by="peer-answer", authority="peer", at=1000.0)
        # 30s later: outside the 20s correlation window -- a different,
        # unrelated prompt in the same pane must not borrow this actor.
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve", now=1030.0)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "unverified")

    def test_explicit_decided_by_is_never_overridden_by_correlation(self):
        """The bound/deferred path (herdr-select.sh authorize-bound /
        authorized --decided-by "$decision_actor") already asserts the real,
        verified actor directly -- correlation must only ever apply to the
        'unverified' sentinel, never second-guess an explicit value."""
        db = _fresh_db_with_approvals()
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="PID-E", now=999.0)
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="PID-E", choice="1",
                          decided_by="some-other-actor", authority="peer", at=1000.0)
        out = po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve", now=1000.1)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "conductor")

    def test_unrelated_prompt_or_choice_in_window_stays_unverified(self):
        """Review concern 1: an approvals row for a DIFFERENT prompt, or for
        the SAME prompt but the opposite choice, must never be borrowed for
        this occurrence even though it is fresh and in the same pane -- e.g.
        peer-answer.sh denies prompt A, then a human typing directly presses
        Approve on unrelated prompt B seconds later in the same pane."""
        db = _fresh_db_with_approvals()
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="OWN-PROMPT", now=999.0)
        # Different prompt entirely, same choice.
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="OTHER-PROMPT", choice="1",
                          decided_by="peer-answer", authority="peer", at=1000.0)
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve", now=1000.2)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "unverified")
        # Same prompt this time, but the recorded choice was a Deny -- must
        # not be credited for an Approve.
        other = {**IDENT, "tool_call_id": "c2"}
        po.record_screen(db, **other, display="pending_parseable", screen_prompt_id="OWN-PROMPT", now=1099.0)
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="OWN-PROMPT", choice="2",
                          decided_by="peer-answer", authority="peer", at=1100.0)
        out2 = po.record_authorized(db, **other, decided_by="unverified", choice="approve", now=1100.2)
        rec2 = po.fold_task(db, "r1", "t1")[out2["occ_key"]]
        self.assertEqual(rec2["decided_by"], "unverified")

    def test_lost_race_row_not_borrowed(self):
        """Review concern 2: herdr-select.sh's bound exact-request path
        writes an `approvals` row with outcome='lost-race' when NO keystroke
        was ever sent (another claimant won the race,
        herdr-select.sh:349-356) -- that computed-but-undelivered decision
        must never be credited to a real, separate approval in the pane."""
        db = _fresh_db_with_approvals()
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="PID-F", now=999.0)
        _insert_approval(db, run_id="r1", task_id="t1", pane_id="p1", prompt_id="PID-F", choice="1",
                          decided_by="peer-answer", authority="peer", at=1000.0,
                          confirmed=True, outcome="lost-race")
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve", now=1000.2)
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "unverified")


class UpgradeAuthorizedActor(unittest.TestCase):
    """#309 r2: herdr-select.sh's own `approval_confirmed("pressed", ...)`
    write races omp's immediate correlation attempt -- if the hook's
    correlate query runs first (before `confirmed_at` is set), it locks the
    occurrence at the honest "unverified" sentinel forever (first-write-wins).
    herdr-select.sh calls `upgrade-actor` right after confirming the press to
    repair exactly that case; `upgrade_authorized_actor()` must only ever
    replace an unverified sentinel, never invent or downgrade a real value."""

    def test_real_ordering_upgrades_unverified_to_the_actual_actor(self):
        """The actual production ordering: the hook's correlation write
        lands with 'unverified' BEFORE herdr-select.sh's approval_confirmed
        (and thus its own upgrade call) ever happens -- then the upgrade
        call, once it does happen, replaces the sentinel with the real,
        just-confirmed actor."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="RACE-PID")
        out = po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve")
        rec = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec["decided_by"], "unverified")  # locked in first, as the race produces
        up = po.upgrade_authorized_actor(db, run_id="r1", task_id="t1",
                                          screen_prompt_id="RACE-PID", choice="approve",
                                          decided_by="peer-answer")
        self.assertEqual(up["written"], "upgraded")
        rec2 = po.fold_task(db, "r1", "t1")[out["occ_key"]]
        self.assertEqual(rec2["decided_by"], "peer-answer")

    def test_upgrade_never_downgrades_an_already_real_value(self):
        """The bound path (or a prior successful upgrade) already recorded
        the real, verified actor directly -- a later upgrade call must never
        second-guess it, matching the existing
        test_explicit_decided_by_is_never_overridden_by_correlation
        guarantee for the sentinel-correlation path."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="REAL-PID")
        po.record_authorized(db, **IDENT, decided_by="conductor", choice="approve")
        up = po.upgrade_authorized_actor(db, run_id="r1", task_id="t1",
                                          screen_prompt_id="REAL-PID", choice="approve",
                                          decided_by="peer-answer")
        self.assertEqual(up["written"], "no-op")
        rec = po.fold_task(db, "r1", "t1")[po.occurrence_key(**IDENT)]
        self.assertEqual(rec["decided_by"], "conductor")

    def test_upgrade_choice_mismatch_leaves_sentinel_in_place(self):
        """The occurrence's stored choice was Deny; an upgrade call claiming
        an Approve for the same screen_prompt_id must never apply -- the
        confirmed press it describes is not this occurrence's decision."""
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="MISMATCH-PID")
        po.record_authorized(db, **IDENT, decided_by="unverified_or_abort", choice="deny")
        up = po.upgrade_authorized_actor(db, run_id="r1", task_id="t1",
                                          screen_prompt_id="MISMATCH-PID", choice="approve",
                                          decided_by="peer-answer")
        self.assertEqual(up["written"], "no-op")
        rec = po.fold_task(db, "r1", "t1")[po.occurrence_key(**IDENT)]
        self.assertEqual(rec["decided_by"], "unverified_or_abort")

    def test_upgrade_with_no_matching_screen_id_is_a_no_op(self):
        db = _fresh_db()
        po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_authorized(db, **IDENT, decided_by="unverified", choice="approve")
        up = po.upgrade_authorized_actor(db, run_id="r1", task_id="t1",
                                          screen_prompt_id="NEVER-PAINTED", choice="approve",
                                          decided_by="peer-answer")
        self.assertEqual(up["written"], "no-op")
        self.assertEqual(up["reason"], "not-found")

    def test_upgrade_ambiguous_across_two_occurrences_is_a_no_op(self):
        """Two distinct occurrences somehow share one screen_prompt_id
        (a content collision) -- refuse to guess which one the confirmed
        press belongs to, same refusal shape as resolve_exact_pending's own
        screen-correlated branch for the analogous ambiguity."""
        db = _fresh_db()
        a = {**IDENT, "tool_call_id": "a"}
        b = {**IDENT, "tool_call_id": "b"}
        po.record_seen(db, **a, tool="bash", tool_input={"command": "x"}, source="s")
        po.record_seen(db, **b, tool="bash", tool_input={"command": "y"}, source="s")
        po.record_screen(db, **a, display="pending_parseable", screen_prompt_id="SHARED-PID")
        po.record_screen(db, **b, display="pending_parseable", screen_prompt_id="SHARED-PID")
        po.record_authorized(db, **a, decided_by="unverified", choice="approve")
        up = po.upgrade_authorized_actor(db, run_id="r1", task_id="t1",
                                          screen_prompt_id="SHARED-PID", choice="approve",
                                          decided_by="peer-answer")
        self.assertEqual(up["written"], "no-op")
        self.assertEqual(up["reason"], "ambiguous")


def _isolated_db() -> tuple[str, Path]:
    """A registry in its own directory (proposals live beside the db) plus a
    real worktree directory, both realpath'd."""
    import os

    base = Path(os.path.realpath(tempfile.mkdtemp(prefix="occ-proposal-")))
    db = _fresh_db()
    moved = base / "registry.sqlite3"
    Path(db).rename(moved)
    wt = base / "wt"
    (wt / ".handoffs").mkdir(parents=True)
    return str(moved), wt


# A multi-line write longer than any approval panel shows (the panel elides
# after a few rows); each line distinct so truncation anywhere is visible.
LONG_CONTENT = "".join(f"| row {i:03d} | value {i * 7} | note: keep {i} |\n" for i in range(120))


class CompletePayloadProposal(unittest.TestCase):
    """herdr-control #277: a write/edit approval binds to the complete,
    registry-hashed input, never to the clipped panel."""

    def _occ(self, db, wt, *, ident=None, tool="write", tool_input=None, screen="P1", now=None):
        ident = ident or IDENT
        if tool_input is None:
            tool_input = {"path": str(wt / ".handoffs" / "plan.md"), "content": LONG_CONTENT}
        out = po.record_seen(db, **ident, tool=tool, tool_input=tool_input, source="tool_approval_requested",
                             cwd=str(wt), dispatched_at_ms=None if now is None else int(now * 1000) - 50,
                             now=now)
        po.record_screen(db, **ident, display="pending_parseable", screen_prompt_id=screen, now=now)
        return out

    def _check(self, db, wt, *, run="r1", task="t1", pane="p1", screen="P1", **kw):
        return po.proposal_check(db, run_id=run, task_id=task, pane_id=pane, pane_birth=kw.pop("birth", "b1"),
                                 screen_prompt_id=screen, worktree=str(wt), **kw)

    def test_full_multiline_write_is_available_exactly(self):
        db, wt = _isolated_db()
        out = self._occ(db, wt)
        self.assertEqual(out["proposal"], "written")
        got = self._check(db, wt, tool="write")
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["body"], LONG_CONTENT)
        self.assertGreater(got["body_bytes"], 4000)
        self.assertEqual(got["payload_sha256"], po.payload_sha256(
            "write", {"path": str(wt / ".handoffs" / "plan.md"), "content": LONG_CONTENT}))
        self.assertEqual(got["targets"], [str(wt / ".handoffs" / "plan.md")])
        self.assertTrue(got["review_text"].startswith(f"Allow tool: write Path: {wt}/.handoffs/plan.md Content: | row 000"))
        self.assertTrue(got["review_text"].endswith("| row 119 | value 833 | note: keep 119 |"))
        mode = (Path(db).parent / "proposals").stat().st_mode & 0o777
        self.assertEqual(mode, 0o700)

    def test_exact_omp_request_binding_survives_registry_and_proposal_replay(self):
        db, wt = _isolated_db()
        request_id = "req-277"
        core_digest = "sha256:" + "a" * 64
        protocol = "omp.tool-approval-binding.v1"
        inp = {"path": str(wt / ".handoffs" / "bound.md"), "content": "complete\npayload\n"}
        core_json = json.dumps(inp, sort_keys=True, separators=(",", ":"))
        core_digest = "sha256:" + hashlib.sha256(core_json.encode()).hexdigest()
        po.record_seen(db, **IDENT, tool="write", tool_input=inp, source="tool_approval_requested",
                       cwd=str(wt), approval_request_id=request_id, core_arguments_digest=core_digest,
                       binding_protocol=protocol, core_arguments_json=core_json)
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="BOUND")
        got = self._check(db, wt, screen="BOUND")
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["approval_request_id"], request_id)
        self.assertEqual(got["core_arguments_digest"], core_digest)
        self.assertEqual(got["binding_protocol"], protocol)
        folded = po.fold_task(db, "r1", "t1")[got["occ_key"]]
        self.assertEqual((folded["approval_request_id"], folded["core_arguments_digest"]),
                         (request_id, core_digest))
        self.assertEqual(folded["binding_protocol"], protocol)

    def test_bound_proposal_rejects_canonical_digest_or_effective_argument_mismatch(self):
        db, wt = _isolated_db()
        inp = {"path": str(wt / "bound.md"), "content": "reviewed"}
        core_json = json.dumps({**inp, "content": "different effective input"},
                               sort_keys=True, separators=(",", ":"))
        digest = "sha256:" + hashlib.sha256(core_json.encode()).hexdigest()
        po.record_seen(db, **IDENT, tool="write", tool_input=inp, source="tool_approval_requested",
                       cwd=str(wt), approval_request_id="req-mismatch", core_arguments_digest=digest,
                       binding_protocol="omp.tool-approval-binding.v1", core_arguments_json=core_json)
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="BOUND-MISMATCH")
        got = self._check(db, wt, screen="BOUND-MISMATCH")
        self.assertFalse(got["ok"])
        self.assertIn("differs from OMP effective arguments", got["reason"])

    def test_bound_lookup_mismatch_negatives_each_with_positive_control(self):
        """herdr-control Finding 1 fix: proposal_check's bound_lookup branch
        (the path herdr-select.sh now routes automated write/edit approvals
        through) refuses every mismatch, each proven against the same
        identity's own positive control."""
        db, wt = _isolated_db()
        inp = {"path": str(wt / ".handoffs" / "exact.md"), "content": "exact routing payload"}
        core_json = json.dumps(inp, sort_keys=True, separators=(",", ":"))
        digest = "sha256:" + hashlib.sha256(core_json.encode()).hexdigest()
        po.record_seen(db, **IDENT, tool="write", tool_input=inp, source="tool_approval_requested",
                       cwd=str(wt), approval_request_id="req-exact", core_arguments_digest=digest,
                       binding_protocol="omp.tool-approval-binding.v1", core_arguments_json=core_json)

        def bound_check(**over):
            kw = dict(approval_request_id="req-exact", expect_arguments_digest=digest, expect_tool_call_id="c1")
            kw.update(over)
            return po.proposal_check(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1",
                                     screen_prompt_id="", worktree=str(wt), **kw)

        digest_mismatch = bound_check(expect_arguments_digest="sha256:" + "f" * 64)
        self.assertFalse(digest_mismatch["ok"])
        self.assertIn("digest", digest_mismatch["reason"])
        call_mismatch = bound_check(expect_tool_call_id="wrong-call")
        self.assertFalse(call_mismatch["ok"])
        self.assertIn("call id", call_mismatch["reason"])
        unknown = bound_check(approval_request_id="req-never-issued")
        self.assertFalse(unknown["ok"])
        self.assertIn("no recorded occurrence", unknown["reason"])
        self.assertTrue(bound_check()["ok"])  # positive control: the real identity still resolves
        # Replay: once resolved, the same exact request id must never re-authorize.
        po.record_authorized(db, **IDENT, decided_by="peer", choice="approve")
        self.assertIn("not awaiting approval", bound_check()["reason"])

    def test_new_file_absolute_and_relative_paths_resolve(self):
        db, wt = _isolated_db()
        self._occ(db, wt, tool_input={"path": str(wt / "brand-new.md"), "content": "x\ny\n"})
        self.assertTrue(self._check(db, wt)["ok"])
        ident2 = {**IDENT, "tool_call_id": "c2"}
        self._occ(db, wt, ident=ident2, tool_input={"path": ".handoffs/new.md", "content": "z"}, screen="P2")
        got = self._check(db, wt, screen="P2")
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["targets"], [str(wt / ".handoffs" / "new.md")])

    def test_multifile_multiline_edit(self):
        db, wt = _isolated_db()
        (wt / "a.txt").write_text("1\n")
        (wt / "b.txt").write_text("2\n")
        body = "[a.txt#1A2B]\n" + "".join(f"PUT >{i}:\n+line {i}\n" for i in range(1, 80)) + "[b.txt#3C4D]\nCUT 1\n"
        self._occ(db, wt, tool="edit", tool_input={"input": body})
        got = self._check(db, wt, tool="edit")
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["body"], body)
        self.assertEqual(got["targets"], [str(wt / "a.txt"), str(wt / "b.txt")])

    def test_hard_linked_target_is_refused_at_check_and_recheck(self):
        """Mirrors the dispatch guard: a write through a hard link also changes
        the file's other names, including one outside the worktree."""
        import os
        db, wt = _isolated_db()
        target = wt / ".handoffs" / "plan.md"
        target.write_text("old\n")
        outside = wt.parent / "outside-name.md"
        os.link(target, outside)
        self._occ(db, wt)
        got = self._check(db, wt)
        self.assertFalse(got["ok"])
        self.assertIn("hard link", got["reason"])
        outside.unlink()
        self.assertTrue(self._check(db, wt)["ok"])
        os.link(target, outside)  # linked after review: the recheck refuses
        self.assertIn("hard link", self._check(db, wt)["reason"])

    def test_dotdot_component_is_refused(self):
        """Review r1 L1: normpath collapses `link/..` textually while the
        kernel follows the link first."""
        db, wt = _isolated_db()
        (wt / "sub").mkdir()
        (wt / "in-link").symlink_to(wt / "sub")
        self._occ(db, wt, tool_input={"path": "in-link/../.handoffs/x.md", "content": "x"})
        got = self._check(db, wt)
        self.assertFalse(got["ok"])
        self.assertIn("'..' component", got["reason"])

    def test_audit_text_carries_no_raw_body(self):
        db, wt = _isolated_db()
        self._occ(db, wt)
        got = self._check(db, wt)
        self.assertEqual(got["audit_text"], f"Allow tool: write Path: {wt}/.handoffs/plan.md "
                                            f"[complete payload sha256 {got['payload_sha256']}, {got['body_bytes']} bytes]")

    def test_stale_unresolved_proposals_are_swept(self):
        """Review r1 L2: a proposal whose resolution was never recorded does
        not keep raw content on disk forever."""
        import os
        db, wt = _isolated_db()
        out = self._occ(db, wt)
        old = po.proposal_path(db, out["occ_key"])
        stale = time.time() - po.PROPOSAL_MAX_AGE_S - 60
        os.utime(old, (stale, stale))
        self._occ(db, wt, ident={**IDENT, "tool_call_id": "c2"}, screen="P2",
                  tool_input={"path": str(wt / "n.md"), "content": "n"})
        self.assertFalse(old.exists())
        self.assertFalse(self._check(db, wt)["ok"])
        self.assertTrue(self._check(db, wt, screen="P2")["ok"])
        # A temp file a killed writer left behind is swept by the same rule.
        orphan = old.parent / ".occ_x.123.tmp"
        orphan.write_text("raw")
        os.utime(orphan, (stale, stale))
        self._occ(db, wt, ident={**IDENT, "tool_call_id": "c3"}, screen="P3",
                  tool_input={"path": str(wt / "m.md"), "content": "m"})
        self.assertFalse(orphan.exists())

    def test_missing_malformed_truncated_and_wrong_version_fail_closed(self):
        db, wt = _isolated_db()
        out = self._occ(db, wt)
        path = po.proposal_path(db, out["occ_key"])
        original = path.read_text()

        doc = json.loads(original)
        doc["input"]["content"] = LONG_CONTENT[:2000]          # truncated payload
        path.write_text(json.dumps(doc))
        self.assertIn("does not hash", self._check(db, wt)["reason"])

        path.write_text(original[:-40])                         # truncated file
        self.assertIn("malformed", self._check(db, wt)["reason"])

        doc = json.loads(original)
        doc["version"] = 2
        path.write_text(json.dumps(doc))
        self.assertIn("version-1", self._check(db, wt)["reason"])

        path.unlink()                                           # missing
        self.assertIn("missing", self._check(db, wt)["reason"])

    def test_no_recorded_input_is_refused(self):
        db, wt = _isolated_db()
        po.record_seen(db, **IDENT, tool="write", tool_input=None, source="tool_approval_requested", cwd=str(wt))
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="P1")
        self.assertIn("no complete payload", self._check(db, wt)["reason"])

    def test_review_hash_binding_and_change_after_review(self):
        db, wt = _isolated_db()
        self._occ(db, wt)
        reviewed = self._check(db, wt)["payload_sha256"]
        self.assertTrue(self._check(db, wt, expect_sha=reviewed)["ok"])
        self.assertIn("changed since review", self._check(db, wt, expect_sha="0" * 64)["reason"])
        # The same occurrence re-fires with different input: a mismatch, never approvable.
        po.record_seen(db, **IDENT, tool="write", tool_input={"path": str(wt / "x"), "content": "evil"},
                       source="tool_approval_requested", cwd=str(wt))
        self.assertFalse(self._check(db, wt, expect_sha=reviewed)["ok"])
        self.assertIn("mismatch", self._check(db, wt)["reason"])

    def test_enrichment_writes_proposal_and_screen_change_is_stale(self):
        db, wt = _isolated_db()
        po.record_seen(db, **IDENT, tool="write", tool_input=None, source="tool_call", cwd=str(wt))
        out = po.record_seen(db, **IDENT, tool="write",
                             tool_input={"path": str(wt / "e.md"), "content": "late\n"},
                             source="tool_approval_requested", cwd=str(wt))
        self.assertEqual((out["written"], out["proposal"]), ("enriched", "written"))
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="P1")
        self.assertTrue(self._check(db, wt)["ok"])
        # A repaint with a new prompt id is a different screen: the reviewed id no longer matches.
        po.record_screen(db, **IDENT, display="pending_parseable", screen_prompt_id="P9")
        self.assertIn("no recorded occurrence", self._check(db, wt, screen="P1")["reason"])

    def test_resolution_retires_and_deletes_the_proposal(self):
        for resolve in ("completed", "declined", "withdrawn", "deny"):
            db, wt = _isolated_db()
            out = self._occ(db, wt)
            if resolve == "completed":
                po.record_authorized(db, **IDENT, decided_by="peer", choice="approve")
                po.record_completed(db, **IDENT)
            elif resolve == "deny":
                po.record_authorized(db, **IDENT, decided_by="human", choice="deny")
            else:
                getattr(po, f"record_{resolve}")(db, **IDENT)
            self.assertFalse(po.proposal_path(db, out["occ_key"]).exists(), resolve)
            self.assertFalse(self._check(db, wt)["ok"], resolve)

    def test_approved_but_not_executed_is_not_reapprovable(self):
        db, wt = _isolated_db()
        self._occ(db, wt)
        po.record_authorized(db, **IDENT, decided_by="peer", choice="approve")
        self.assertIn("approved_awaiting_completion", self._check(db, wt)["reason"])

    def test_path_escapes_and_symlinks_are_refused(self):
        import os

        db, wt = _isolated_db()
        outside = wt.parent / "outside"
        outside.mkdir()
        (wt / "link-out").symlink_to(outside)
        (wt / "file-link").symlink_to(wt / "a-real-file")
        (wt / ".git").mkdir()
        cases = {
            "../outside/x.md": "'..' component",
            str(outside / "x.md"): "outside the worker worktree",
            "link-out/x.md": "outside the worker worktree",
            "file-link": "is a symlink",
            ".git/hooks/pre-commit": "inside .git",
            "~/x.md": "not a plain filesystem path",
            "file:///etc/passwd": "not a plain filesystem path",
            ".": "outside the worker worktree",
        }
        for i, (target, why) in enumerate(cases.items()):
            ident = {**IDENT, "tool_call_id": f"esc{i}"}
            self._occ(db, wt, ident=ident, tool_input={"path": target, "content": "x"}, screen=f"E{i}")
            got = self._check(db, wt, screen=f"E{i}")
            self.assertFalse(got["ok"], target)
            self.assertIn(why, got["reason"], target)
        # An edit MV destination escaping the worktree is refused too.
        ident = {**IDENT, "tool_call_id": "mv"}
        self._occ(db, wt, ident=ident, tool="edit", tool_input={"input": f"[a.txt#1A2B]\nMV {outside}/evil.txt\n"},
                  screen="MV")
        self.assertIn("outside the worker worktree", self._check(db, wt, screen="MV")["reason"])
        ident = {**IDENT, "tool_call_id": "mv2"}
        self._occ(db, wt, ident=ident, tool="edit", tool_input={"input": "[a.txt#1A2B]\nMV ../../evil.txt\n"},
                  screen="MV2")
        self.assertIn("'..' component", self._check(db, wt, screen="MV2")["reason"])
        self.assertTrue(os.path.isdir(outside))

    def test_target_swapped_for_symlink_after_review_fails_recheck(self):
        db, wt = _isolated_db()
        target = wt / ".handoffs" / "plan.md"
        self._occ(db, wt)
        first = self._check(db, wt)
        self.assertTrue(first["ok"])
        outside = wt.parent / "secret.txt"
        outside.write_text("s")
        target.symlink_to(outside)
        again = self._check(db, wt, expect_sha=first["payload_sha256"])
        self.assertFalse(again["ok"])
        self.assertIn("symlink", again["reason"])

    def test_concurrent_tasks_and_cross_task_substitution(self):
        db, wt = _isolated_db()
        a = {**IDENT}
        b = {**IDENT, "task_id": "t2", "pane_id": "p2", "tool_call_id": "c1"}
        out_a = self._occ(db, wt, ident=a, tool_input={"path": str(wt / "a.md"), "content": "A\n"}, screen="PA")
        out_b = self._occ(db, wt, ident=b, tool_input={"path": str(wt / "b.md"), "content": "B\n"}, screen="PB")
        self.assertEqual(self._check(db, wt, screen="PA")["body"], "A\n")
        self.assertEqual(self._check(db, wt, task="t2", pane="p2", screen="PB")["body"], "B\n")
        # Task 2's prompt id is invisible to task 1's fold, and vice versa.
        self.assertIn("no recorded occurrence", self._check(db, wt, screen="PB")["reason"])
        self.assertIn("no recorded occurrence", self._check(db, wt, task="t2", pane="p2", screen="PA")["reason"])
        # Task 2's proposal file copied over task 1's: identity and hash both differ.
        po.proposal_path(db, out_a["occ_key"]).write_text(po.proposal_path(db, out_b["occ_key"]).read_text())
        got = self._check(db, wt, screen="PA")
        self.assertFalse(got["ok"])
        self.assertIn("identity differs", got["reason"])

    def test_two_occurrences_claiming_one_screen_are_ambiguous(self):
        db, wt = _isolated_db()
        self._occ(db, wt, ident={**IDENT, "tool_call_id": "x1"}, screen="SAME")
        self._occ(db, wt, ident={**IDENT, "tool_call_id": "x2"}, screen="SAME")
        self.assertIn("more than one", self._check(db, wt, screen="SAME")["reason"])

    def test_restart_new_session_or_pane_lifetime_never_matches(self):
        import subprocess

        db, wt = _isolated_db()
        self._occ(db, wt)
        # Restart between proposal and review: a fresh process re-derives it from disk alone.
        cli = subprocess.run([sys.executable, str(ROOT / "lib" / "prompt-occurrence.py"), "proposal",
                              "--db", db, "--run", "r1", "--task", "t1", "--pane", "p1", "--birth", "b1",
                              "--prompt-id", "P1", "--worktree", str(wt), "--tool", "write"],
                             capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(cli.stdout)["ok"])
        # The pane was recycled: the occurrence's pane lifetime is not the task's current one.
        self.assertIn("different pane lifetime", self._check(db, wt, birth="b2")["reason"])
        # omp restarted: the new session's prompt is a new occurrence with its own proposal.
        restarted = {**IDENT, "native_session": "s2"}
        self._occ(db, wt, ident=restarted, tool_input={"path": str(wt / "n.md"), "content": "new"}, screen="P2")
        self.assertEqual(self._check(db, wt, screen="P2")["body"], "new")
        # Unproven identity (no session recorded) is never approvable.
        self._occ(db, wt, ident={**IDENT, "native_session": "", "tool_call_id": "u"}, screen="PU")
        self.assertIn("unverified", self._check(db, wt, screen="PU")["reason"])

    def test_oversized_payload_writes_no_proposal(self):
        db, wt = _isolated_db()
        out = self._occ(db, wt, tool_input={"path": str(wt / "big"), "content": "x" * (po.PROPOSAL_MAX_BYTES + 1)})
        self.assertEqual(out["proposal"], "too_large")
        self.assertIn("missing", self._check(db, wt)["reason"])

    def test_bash_input_never_produces_a_proposal_file(self):
        db, wt = _isolated_db()
        out = po.record_seen(db, **IDENT, tool="bash", tool_input={"command": "echo hi"}, source="s", cwd=str(wt))
        self.assertNotIn("proposal", out)
        self.assertFalse((Path(db).parent / "proposals").exists())

    def test_lifecycle_timestamps_are_recorded_in_order(self):
        db, wt = _isolated_db()
        self._occ(db, wt, now=1000.000)
        checked = self._check(db, wt)["checked_at_ms"]
        po.record_authorized(db, **IDENT, decided_by="peer", choice="approve", now=1000.400)
        po.record_started(db, **IDENT, now=1000.410)
        po.record_completed(db, **IDENT, now=1000.900)
        conn = sqlite3.connect(db)
        rows = {t: json.loads(p) for t, p in conn.execute("SELECT type, payload FROM events WHERE type LIKE 'prompt_occ_%'")}
        conn.close()
        seen = rows["prompt_occ_seen"]
        self.assertEqual(seen["dispatched_at_ms"], 999_950)
        self.assertEqual(seen["at_ms"], 1_000_000)
        self.assertEqual(rows["prompt_occ_authorized"]["at_ms"], 1_000_400)
        self.assertEqual(rows["prompt_occ_started"]["at_ms"], 1_000_410)
        self.assertEqual(rows["prompt_occ_completed"]["at_ms"], 1_000_900)
        self.assertIsInstance(checked, int)
        # Execution start is evidence only: lifecycle still waits for completion semantics.
        self.assertEqual(po.fold_task(db, "r1", "t1")[seen["occ_key"]]["lifecycle"], "resolved:completed")

    def test_cli_show_prints_the_complete_payload_and_hash(self):
        import contextlib
        import io

        db, wt = _isolated_db()
        self._occ(db, wt)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            po.main(["proposal", "--db", db, "--run", "r1", "--task", "t1", "--pane", "p1", "--birth", "b1",
                     "--prompt-id", "P1", "--worktree", str(wt), "--show"])
        text = buf.getvalue()
        self.assertIn(LONG_CONTENT, text)
        self.assertIn("payload_sha256: " + self._check(db, wt)["payload_sha256"], text)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            po.main(["proposal", "--db", db, "--run", "r1", "--task", "t1", "--pane", "p1",
                     "--prompt-id", "NOPE", "--worktree", str(wt), "--show"])
        self.assertTrue(buf.getvalue().startswith("REFUSED:"))
        self.assertNotIn("row 000", buf.getvalue())


class ExactPendingResolution(unittest.TestCase):
    """herdr-control security review Finding 1: the automated write/edit
    approval gate must resolve the occurrence to authorize by its OWN OMP
    v1 request id (resolve_exact_pending), never by matching the painted
    screen's prompt id."""

    def _bound(self, db, *, ident, path, content, screen=""):
        inp = {"path": path, "content": content}
        core_json = json.dumps(inp, sort_keys=True, separators=(",", ":"))
        digest = "sha256:" + hashlib.sha256(core_json.encode()).hexdigest()
        po.record_seen(db, **ident, tool="write", tool_input=inp, source="tool_approval_requested",
                       cwd="/repo", approval_request_id=f"req-{ident['tool_call_id']}",
                       core_arguments_digest=digest, binding_protocol="omp.tool-approval-binding.v1",
                       core_arguments_json=core_json)
        if screen:
            po.record_screen(db, **ident, display="pending_parseable", screen_prompt_id=screen)

    def test_resolves_the_sole_pending_bound_occurrence(self):
        db, wt = _isolated_db()
        self._bound(db, ident=IDENT, path=str(wt / "x.md"), content="x")
        got = po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1", tool="write")
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["approval_request_id"], "req-c1")

    def test_refuses_when_no_bound_occurrence_is_pending(self):
        """An ordinary (unbound) write/edit occurrence must never resolve
        here -- it stays human-only, same as before this fix."""
        db, wt = _isolated_db()
        po.record_seen(db, **IDENT, tool="write", tool_input={"path": str(wt / "x.md"), "content": "x"},
                       source="tool_approval_requested", cwd=str(wt))
        got = po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1", tool="write")
        self.assertFalse(got["ok"])
        self.assertIn("no bound write/edit occurrence", got["reason"])

    def test_two_pending_bound_occurrences_are_ambiguous_finding_1(self):
        """Finding 1 regression: X never recorded its own screen_prompt_id
        (its own notify.sh invocation silently failed), Y's own screen id
        is the one actually painted. Automated approval must refuse rather
        than guess which one owns the screen -- it must NEVER credit Y's
        approval against X's still-live panel."""
        db, wt = _isolated_db()
        x = {**IDENT, "tool_call_id": "x"}
        y = {**IDENT, "tool_call_id": "y"}
        self._bound(db, ident=x, path=str(wt / "x.md"), content="X payload")   # no screen write at all
        self._bound(db, ident=y, path=str(wt / "y.md"), content="Y payload", screen="PAINTED")
        got = po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1",
                                       tool="write", screen_prompt_id="PAINTED")
        self.assertFalse(got["ok"])
        self.assertIn("ambiguous", got["reason"])
        # Positive control: with only Y pending, the same call resolves Y cleanly.
        po.record_withdrawn(db, **x, reason="test")
        got2 = po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1",
                                        tool="write", screen_prompt_id="PAINTED")
        self.assertTrue(got2["ok"], got2)
        self.assertEqual(got2["approval_request_id"], "req-y")

    def test_screen_cross_check_disagreement_refuses(self):
        """The one bound pending occurrence (X) is found by its own request
        id, but a DIFFERENT occurrence's screen write claims the painted
        prompt id -- the cross-check must refuse rather than trust either
        side silently."""
        db, wt = _isolated_db()
        x = {**IDENT, "tool_call_id": "x"}
        other = {**IDENT, "task_id": "t1", "tool_call_id": "other"}
        self._bound(db, ident=x, path=str(wt / "x.md"), content="X payload")
        po.record_seen(db, **other, tool="bash", tool_input={"command": "ls"}, source="s", cwd=str(wt))
        po.record_screen(db, **other, display="pending_parseable", screen_prompt_id="PAINTED")
        got = po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1",
                                       tool="write", screen_prompt_id="PAINTED")
        self.assertFalse(got["ok"])
        self.assertIn("disagrees", got["reason"])

    def test_screen_cross_check_agreement_or_absence_resolves(self):
        db, wt = _isolated_db()
        self._bound(db, ident=IDENT, path=str(wt / "x.md"), content="x", screen="OWN-ID")
        # No screen id supplied at all: resolution proceeds on request id alone.
        self.assertTrue(po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1",
                                                 pane_birth="b1", tool="write")["ok"])
        # The occurrence's own recorded screen id agrees with what is passed.
        self.assertTrue(po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1", pane_birth="b1",
                                                 tool="write", screen_prompt_id="OWN-ID")["ok"])

    def test_scoped_by_pane_and_tool(self):
        db, wt = _isolated_db()
        other_pane = {**IDENT, "pane_id": "p9", "tool_call_id": "p9call"}
        self._bound(db, ident=other_pane, path=str(wt / "x.md"), content="x")
        self.assertFalse(po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1",
                                                  pane_birth="b1", tool="write")["ok"])
        bash_call = {**IDENT, "tool_call_id": "bashcall"}
        po.record_seen(db, **bash_call, tool="bash", tool_input={"command": "ls"}, source="s", cwd=str(wt))
        self.assertFalse(po.resolve_exact_pending(db, run_id="r1", task_id="t1", pane_id="p1",
                                                  pane_birth="b1", tool="write")["ok"])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
