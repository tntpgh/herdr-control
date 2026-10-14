#!/usr/bin/env python3
"""verify-prompt-occurrence.py — fixture-only regression suite for
lib/prompt-occurrence.py (docs/plans/dot-herdr-recovery-slices.md §2).

Every case uses a fresh temporary SQLite file carrying only the subset of
lib/run-registry.sh's schema this module reads/writes (the `events` table).
No live pane, herdr socket or real registry is touched.
"""
import importlib.util
import json
import sqlite3
import sys
import tempfile
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


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
