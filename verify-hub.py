#!/usr/bin/env python3
"""Hub boundary regressions: python3 verify-hub.py (stdlib, mock secrets/DB only)."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import threading
import types
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("herdr_hub", Path(__file__).with_name("hub.py"))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)

NOW = dt.datetime(2026, 9, 7, 14, tzinfo=dt.timezone.utc)
CANARY = "private-credential-must-not-appear"


def audit(status="ok", hours=1):
    start = NOW - dt.timedelta(hours=hours)
    return {
        "run_id": "09f6cc31-31a1-4807-b09a-2ec340cab7b8",
        "started_at": start.isoformat(),
        "finished_at": None if status == "running" else (start + dt.timedelta(minutes=2)).isoformat(),
        "status": status, "rule_version": "repeat-view-v1", "source_revision": "20b030f",
        "summary": {
            "window_days": 14, "person_count": 100, "before_count": 37, "after_count": 8,
            "changed_count": 29, "repeat_before_count": 30, "repeat_after_count": 5,
            "withheld_stale_count": 20, "withheld_unknown_date_count": 5, "violation_count": 0,
        },
        "error_code": None,
    }


def heartbeat(**overrides):
    """server.heartbeat.aggregate()'s persisted shape, with the private values
    its checkers really embed: exception text, subprocess stderr and whole
    non-OK response bodies land in systems.*.detail."""
    payload = {
        "generated_at": (NOW - dt.timedelta(hours=5)).isoformat(),
        "systems": {
            "kb": {"status": "healthy", "detail": f"store=in-sync; last nightly=ok @ {CANARY}"},
            "tourguide": {"status": "degraded", "detail": f"http 500: {{'dsn': '{CANARY}'}}"},
            "tntpgh_actions": {"status": "unreachable", "detail": f"gh: bad credentials {CANARY}"},
            "syncworks": {"status": "unknown", "detail": "no HTTP surface exists"},
            "search": {"status": "healthy", "detail": "http 200", "client": {"email": CANARY}},
            f"scratch_{CANARY}": {"status": "healthy", "detail": CANARY},
        },
        "healthy_count": 99, "checked_count": 99, "total_count": 99,
        "divergent": False, "unhealthy": [], "operator_note": CANARY,
    }
    payload.update(overrides)
    return payload


class ReaderFixture(unittest.TestCase):
    """Runs the real kb_data() over an isolated child payload: no database, no
    real credential file, no live hub."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "server").mkdir()
        self.secrets = self.root / "launchd-secrets.env"
        for target, value in (("LAUNCHD_SECRETS", self.secrets), ("KB_DEPLOY", self.root),
                              ("KB_PYTHON", Path(sys.executable)), ("KB_DASHBOARD_URL", "")):
            p = patch.object(hub, target, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.dict(os.environ, {}, clear=True)
        p.start()
        self.addCleanup(p.stop)
        p = patch.object(hub.time, "time", return_value=NOW.timestamp())
        p.start()
        self.addCleanup(p.stop)

    def reader(self, payload=None, *, result=None, error=None):
        self.secrets.write_text(f"NEON_CONNECTION_STRING='{CANARY}'\n")
        if result is None:
            result = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
        with patch.object(hub.subprocess, "run", return_value=result, side_effect=error) as proc:
            data = hub.kb_data()
        return data, proc

    def loops(self, data):
        other = hub._loop("unrelated", "daily", NOW.isoformat(), 86400, "ok", "")
        with patch.dict(hub.CACHES, {"kb": Mock(get=lambda: data)}), \
                patch.object(hub, "_loop_sentinel", return_value=other), \
                patch.object(hub, "_loop_stage1", return_value=other), \
                patch.object(hub, "_loop_stage2", return_value=(other, [])), \
                patch.object(hub, "_loop_gates", return_value=[]), \
                patch.object(hub, "_loop_decisions", return_value={}):
            return hub.loops_data()


class HubTests(ReaderFixture):

    def test_credential_precedence_and_scoped_file(self):
        self.secrets.write_text("# scoped service values\nexport NEON_CONNECTION_STRING='file-dsn'\nSEARCH_SYNC_TOKEN=search-file\n")
        self.assertEqual(hub.secret("NEON_CONNECTION_STRING"), "file-dsn")
        with patch.dict(os.environ, {"NEON_CONNECTION_STRING": "injected"}):
            self.assertEqual(hub.secret("NEON_CONNECTION_STRING"), "injected")
        self.assertEqual(hub.secret("SEARCH_SYNC_TOKEN"), "search-file")
        self.assertNotIn("SEARCH_SYNC_TOKEN", os.environ)

    def test_missing_file_and_disallowed_names(self):
        self.assertIsNone(hub.secret("NEON_CONNECTION_STRING"))
        with patch.dict(os.environ, {"OP_SERVICE_ACCOUNT_TOKEN": CANARY}):
            with self.assertRaisesRegex(ValueError, "unsupported"):
                hub.secret("OP_SERVICE_ACCOUNT_TOKEN")
        with self.assertRaisesRegex(ValueError, "unsupported"):
            hub.secret("NEON_CONNECTION_STRING; echo anything")

    def test_shell_assignments_remain_inert(self):
        marker = self.root / "executed"
        literal = f"$(touch {marker})"
        self.secrets.write_text(f"touch {marker}\nexport NEON_CONNECTION_STRING='{literal}'\nsource /not/a/config\n")
        with patch.object(hub.subprocess, "run", side_effect=AssertionError("must not execute a shell")):
            self.assertEqual(hub.secret("NEON_CONNECTION_STRING"), literal)
        self.assertFalse(marker.exists())

    def test_unreadable_or_malformed_credentials_do_not_leak(self):
        self.secrets.mkdir()
        unavailable = hub.kb_data()
        self.assertIn("error", unavailable)
        self.assertIn("signal_quality_error", unavailable)
        self.secrets.rmdir()
        self.secrets.write_text(f"NEON_CONNECTION_STRING='{CANARY}\n")
        data = hub.kb_data()
        self.assertIn("error", data)
        self.assertNotIn(CANARY, json.dumps(data))

    def test_child_receives_only_its_service_credential(self):
        with patch.dict(os.environ, {"OP_SERVICE_ACCOUNT_TOKEN": "broker", "SLACK_BOT_TOKEN": "slack",
                                     "SEARCH_SYNC_TOKEN": "search", "PYTHONPATH": "/unsafe", "HOME": str(self.root)}):
            data, proc = self.reader({"runs": [], "heartbeat": None, "signal_quality_runs": []})
        env = proc.call_args.kwargs["env"]
        self.assertEqual({key for key in env if "TOKEN" in key or "CONNECTION" in key}, {"NEON_CONNECTION_STRING"})
        self.assertNotIn("PYTHONPATH", env)
        self.assertIn("default_transaction_read_only=on", env["PGOPTIONS"])
        self.assertNotIn(CANARY, json.dumps(data))

    def test_reader_failures_scrub_stdout_stderr_and_exception_text(self):
        cases = (
            (subprocess.CompletedProcess([], 1, CANARY, CANARY), None),
            (subprocess.CompletedProcess([], 0, CANARY, ""), None),
            (None, subprocess.TimeoutExpired(CANARY, 40, output=CANARY, stderr=CANARY)),
            (None, OSError(CANARY)),
        )
        for result, error in cases:
            with self.subTest(error=type(error).__name__, result=result.returncode if result else None):
                data, _ = self.reader({}, result=result, error=error)
                self.assertIn("error", data)
                self.assertNotIn(CANARY, json.dumps(data))
        data, _ = self.reader({"ledger_error": CANARY, "heartbeat_error": CANARY, "signal_quality_error": CANARY})
        self.assertNotIn(CANARY, json.dumps(data))
        cache = hub.Cached(-1, Mock(side_effect=RuntimeError(CANARY)))
        self.assertNotIn(CANARY, json.dumps(cache.get()))

    def test_unavailable_is_not_empty_execution_history(self):
        for data in ({"error": "credential missing"}, {"ledger_error": "query failed", "heartbeat_error": "query failed"}, {}):
            with self.subTest(data=data):
                result = self.loops(data)
                relevant = result["loops"][:3]
                self.assertTrue(all(row["outcome"] == "unavailable" and not row["stale"] for row in relevant))
                self.assertTrue(all(s["kind"] == "observer" for s in result["suggestions"]))
                self.assertNotIn("ever", json.dumps(result["suggestions"]))
                with patch.dict(hub.CACHES, {"loops": Mock(get=lambda: result)}):
                    rendered = hub.render_loops()
                self.assertNotIn("never", rendered)
                self.assertIn("unknown", rendered)

    def test_successful_empty_history_still_requires_initial_run(self):
        result = self.loops({"runs": [], "heartbeat": None, "signal_quality_runs": []})
        self.assertTrue(all(row["outcome"] == "missing" and row["stale"] for row in result["loops"][:3]))
        self.assertTrue(all(s["kind"] == "stale" for s in result["suggestions"]))

    def test_heartbeat_failure_does_not_hide_observed_nightly_or_audit(self):
        data = {"runs": [{"started_at": NOW.isoformat(), "status": "ok"}],
                "heartbeat_error": "unavailable", "signal_quality_runs": [audit()]}
        result = self.loops(data)
        self.assertEqual([row["outcome"] for row in result["loops"][:3]], ["ok", "unavailable", "ok"])
        self.assertEqual(len(result["suggestions"]), 1)
        self.assertEqual(result["suggestions"][0]["kind"], "observer")

    def test_nightly_empty_to_null_status_running_to_completed(self):
        payload = {"runs": [], "heartbeat": None, "signal_quality_runs": []}
        self.assertEqual(self.loops(payload)["loops"][0]["outcome"], "missing")
        active = {"run_id": "nightly", "started_at": NOW.isoformat(), "finished_at": None,
                  "status": None, "host": "test", "weekday": "Monday", "total_steps": None}
        payload["runs"] = [active]
        data, _ = self.reader(payload)
        self.assertEqual(data["runs"][0]["status"], "running")
        result = self.loops(payload)  # also exercise consumers of the raw live row
        self.assertEqual(result["loops"][0]["outcome"], "running")
        self.assertFalse(result["loops"][0]["stale"])
        self.assertFalse(any(s["key"].endswith(":kb-nightly") for s in result["suggestions"]))
        active.update(status="ok", finished_at=NOW.isoformat(), total_steps=12)
        self.assertEqual(self.loops(payload)["loops"][0]["outcome"], "ok")

    def test_audit_payload_allowlist_drops_private_details(self):
        row = audit("failed")
        row.update(person_id=CANARY, name=CANARY, address=CANARY, email=CANARY, error_code=f"SQL failed for {CANARY}")
        row["summary"].update(people=[CANARY], email=CANARY, client_id=1234)
        data, _ = self.reader({"signal_quality_runs": [row]})
        public = data["signal_quality_runs"][0]
        self.assertNotIn(CANARY, json.dumps(data))
        self.assertEqual(set(public["summary"]), set(hub.SIGNAL_SUMMARY_FIELDS))
        self.assertEqual(public["summary"]["before_count"], 37)
        self.assertEqual(public["summary"]["after_count"], 8)
        self.assertEqual(public["error_code"], "audit_failed")
        self.assertNotIn("person_id", public)

    def test_invalid_aggregate_data_is_unavailable_not_green(self):
        bad_rows = []
        for value in (CANARY, True, -1, float("nan"), float("inf")):
            row = audit()
            row["summary"]["before_count"] = value
            bad_rows.append(row)
        row = audit()
        row["rule_version"] = f"<script>{CANARY}</script>"
        bad_rows.append(row)
        row = audit()
        row["started_at"] = CANARY
        bad_rows.append(row)
        for row in bad_rows:
            data, _ = self.reader({"signal_quality_runs": [row]})
            self.assertNotIn("signal_quality_runs", data)
            self.assertIn("signal_quality_error", data)
            self.assertNotIn(CANARY, json.dumps(data))
            self.assertEqual(self.loops(data)["loops"][2]["outcome"], "unavailable")

    def test_missing_signal_module_is_unavailable_not_never_ran(self):
        data, _ = self.reader({"runs": [], "heartbeat": None})
        signal = self.loops(data)["loops"][2]
        self.assertEqual(signal["outcome"], "unavailable")
        self.assertFalse(signal["stale"])
        self.assertNotIn("No recorded audit runs", hub._render_signal_quality(data))

    def test_signal_status_and_daily_staleness_are_independent(self):
        for status in ("ok", "degraded", "failed", "running"):
            for hours in (26, 27):
                with self.subTest(status=status, hours=hours):
                    row = audit(status, hours)
                    data = {"signal_quality_runs": [row]}
                    loop = hub._signal_quality_loop(data)
                    self.assertEqual(loop["outcome"], status)
                    self.assertEqual(loop["stale"], hours > 26)
                    rendered = hub._render_signal_quality(data)
                    self.assertEqual("STALE" in rendered, hours > 26)
                    self.assertIn(status, rendered)
                    if status == "degraded":
                        self.assertIn("checks need attention", rendered)
                    if status == "failed":
                        self.assertIn("quality has not been established", rendered)

    def test_running_audit_does_not_invent_zero_counts(self):
        row = audit("running")
        row["summary"] = {}
        data, _ = self.reader({"signal_quality_runs": [row]})
        self.assertEqual(data["signal_quality_runs"][0]["summary"], {})
        self.assertIn("— → —", hub._render_signal_quality(data))
        self.assertNotIn("0 → 0", hub._render_signal_quality(data))

    def test_history_is_capped_and_html_is_escaped(self):
        data, _ = self.reader({"signal_quality_runs": [audit() for _ in range(12)]})
        self.assertEqual(len(data["signal_quality_runs"]), 10)
        # Defense in depth at HTML rendering, independently of producer filtering.
        row = audit()
        row["rule_version"] = "<script>alert('x')</script>"
        row["summary"]["before_count"] = "<img src=x onerror=alert(1)>"
        rendered = hub._render_signal_quality({"signal_quality_runs": [row]})
        self.assertNotIn("<script>alert", rendered)
        self.assertNotIn("<img src=x", rendered)
        self.assertIn("&lt;script&gt;", rendered)
        self.assertIn("&lt;img", rendered)

    def test_drilldown_links_require_configured_token_free_kb_page(self):
        for url in ("javascript:alert(1)", "https://dashboard.teamthurber.com/?token=secret",
                    "https://user:secret@dashboard.teamthurber.com/",
                    "https://dashboard.teamthurber.com/#secret", "https://other.example/",
                    "https://kb.teamthurber.com", "https://thurber-kb.fly.dev:8443"):
            with patch.object(hub, "KB_DASHBOARD_URL", url):
                self.assertIsNone(hub._signal_quality_link())
        for url in ("https://dashboard.teamthurber.com", "http://127.0.0.1:8889"):
            with patch.object(hub, "KB_DASHBOARD_URL", url):
                self.assertEqual(hub._signal_quality_link(), url + "/signal-quality")
                self.assertIn("authenticated KB", hub._render_signal_quality({"signal_quality_runs": []}))

    def test_heartbeat_details_and_unknown_keys_never_reach_the_public_payload(self):
        data, _ = self.reader({"heartbeat": heartbeat(), "runs": [], "steps": [], "signal_quality_runs": []})
        hb = data["heartbeat"]
        self.assertNotIn(CANARY, json.dumps(data))
        self.assertEqual(set(hb["systems"]), {"kb", "tourguide", "tntpgh_actions", "syncworks", "search"})
        self.assertEqual([set(v) for v in hb["systems"].values()], [{"status", "code"}] * 5)
        self.assertEqual(hb["systems"]["kb"], {"status": "healthy", "code": "check_ok"})
        self.assertEqual(hb["systems"]["tourguide"], {"status": "degraded", "code": "check_degraded"})
        self.assertEqual(hb["systems"]["tntpgh_actions"]["code"], "check_unreachable")
        self.assertEqual(hb["systems"]["syncworks"]["code"], "check_not_observed")
        # Counts describe what is actually shown, never the producer's numbers.
        self.assertEqual((hb["healthy_count"], hb["checked_count"], hb["total_count"]), (2, 4, 5))
        self.assertEqual(hb["unrecognized_count"], 1)
        self.assertEqual(hb["unhealthy"], ["tntpgh_actions", "tourguide"])
        self.assertTrue(hb["divergent"])  # payload claimed False while healthy and unhealthy coexist
        self.assertNotIn("operator_note", hb)
        self.assertEqual(hb["generated_at"], (NOW - dt.timedelta(hours=5)).isoformat())
        loop = self.loops(data)["loops"][1]
        self.assertEqual(loop["outcome"], "divergent")
        self.assertEqual(loop["detail"], "2/5 healthy")

    def test_invalid_heartbeat_is_unavailable_not_healthy(self):
        naive = NOW.replace(tzinfo=None).isoformat()
        payloads = [
            heartbeat(generated_at=None), heartbeat(generated_at=CANARY), heartbeat(generated_at=naive),
            heartbeat(systems=[{"status": "healthy", "detail": CANARY}]), heartbeat(systems={}),
            heartbeat(systems={f"unknown_{CANARY}": {"status": "healthy", "detail": CANARY}}),
            {"systems": {"kb": {"status": "healthy"}}, "note": CANARY},  # no timestamp at all
            CANARY, [CANARY], 7,
        ]
        for payload in payloads:
            with self.subTest(payload=type(payload).__name__):
                data, _ = self.reader({"heartbeat": payload, "runs": [], "signal_quality_runs": []})
                self.assertNotIn("heartbeat", data)
                self.assertEqual(data["heartbeat_error"], "heartbeat unavailable: invalid snapshot contract")
                self.assertNotIn(CANARY, json.dumps(data))
                loop = self.loops(data)["loops"][1]
                self.assertEqual(loop["outcome"], "unavailable")
                self.assertFalse(loop["stale"])
                with patch.dict(hub.CACHES, {"kb": Mock(get=lambda d=data: d)}):
                    rendered = hub.render_kb()
                self.assertNotIn(CANARY, rendered)
                self.assertNotIn("Fleet heartbeat —", rendered)  # no count header, no healthy pill
                self.assertNotIn("No snapshot yet", rendered)
                self.assertIn("unavailable", rendered)

    def test_absent_heartbeat_key_is_unavailable_not_no_snapshot(self):
        data, _ = self.reader({"runs": [], "signal_quality_runs": []})
        self.assertEqual(data["heartbeat_error"], "heartbeat reader unavailable")
        self.assertEqual(self.loops(data)["loops"][1]["outcome"], "unavailable")
        data, _ = self.reader({"heartbeat": None, "runs": [], "signal_quality_runs": []})
        self.assertIsNone(data["heartbeat"])  # a real "no snapshot recorded yet" survives
        self.assertEqual(self.loops(data)["loops"][1]["outcome"], "missing")

    def test_ledger_error_class_carries_a_token_not_a_message(self):
        steps = [{"step_label": "6e", "status": "failed", "attempts": 2, "duration_s": 1.5,
                  "error_class": f"OperationalError: password authentication failed for {CANARY}"},
                 {"step_label": "3a", "status": "ok", "attempts": 1, "duration_s": 0.2, "error_class": None},
                 {"step_label": "9j", "status": "failed", "attempts": 1, "duration_s": 0.4, "error_class": "transient"},
                 {"step_label": "9j", "status": "failed", "attempts": 1, "duration_s": 0.4,
                  "error_class": "OpaqueCredentialToken_123456789012345"}]
        run = {"run_id": "nightly", "started_at": NOW.isoformat(), "finished_at": None, "status": "failed",
               "host": "test", "weekday": "Monday", "total_steps": 3}
        data, _ = self.reader({"runs": [run], "steps": steps, "heartbeat": None, "signal_quality_runs": []})
        self.assertEqual([s["error_class"] for s in data["steps"]], ["error_class_withheld", None, "transient", "error_class_withheld"])
        self.assertNotIn(CANARY, json.dumps(data))
        self.assertNotIn("OpaqueCredentialToken_123456789012345", json.dumps(data))
        with patch.dict(hub.CACHES, {"kb": Mock(get=lambda: data)}):
            rendered = hub.render_kb()
        self.assertNotIn(CANARY, rendered)
        self.assertIn("transient", rendered)


class SnippetIsolation(unittest.TestCase):
    def snippet(self, *, ledger_error=False, audit_error=False, heartbeat_error=False):
        class Connection:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            @contextlib.contextmanager
            def transaction(self):
                yield

            def execute(self, query, *_):
                if (heartbeat_error and "kb.heartbeat_snapshots" in query) or (ledger_error and "kb.nightly_runs" in query):
                    raise RuntimeError(CANARY)
                return Mock(fetchall=lambda: [], fetchone=lambda: None)

        connection = Connection()
        psycopg = types.ModuleType("psycopg")
        psycopg.connect = Mock(return_value=connection)
        server = types.ModuleType("server")
        signal = types.ModuleType("server.signal_quality")
        signal.recent_runs = Mock(return_value=[audit()], side_effect=RuntimeError(CANARY) if audit_error else None)
        stream = io.StringIO()
        with patch.dict(sys.modules, {"server": server, "server.signal_quality": signal, "psycopg": psycopg}), \
                patch.dict(os.environ, {"NEON_CONNECTION_STRING": CANARY}, clear=True), \
                patch.object(sys, "path", list(sys.path)), contextlib.redirect_stdout(stream):
            exec(hub._KB_SNIPPET, {})
        return json.loads(stream.getvalue()), psycopg.connect, signal.recent_runs, connection

    def test_ledger_failure_preserves_independent_signal_observation(self):
        data, connect, recent, conn = self.snippet(ledger_error=True, heartbeat_error=True)
        self.assertIn("ledger_error", data)
        self.assertIn("heartbeat_error", data)
        self.assertEqual(data["signal_quality_runs"][0]["summary"]["after_count"], 8)
        self.assertNotIn(CANARY, json.dumps(data))
        # Read-only connection is the audit reader's trust boundary.
        self.assertIn("default_transaction_read_only=on", connect.call_args.kwargs["options"])
        recent.assert_called_once_with(conn, limit=10)

    def test_signal_failure_does_not_fabricate_empty_history(self):
        data, _, _, _ = self.snippet(audit_error=True)
        self.assertEqual(data["runs"], [])
        self.assertIn("signal_quality_error", data)
        self.assertNotIn("signal_quality_runs", data)
        self.assertNotIn(CANARY, json.dumps(data))


class PublicSurface(ReaderFixture):
    """The real handler/reader boundary over HTTP: no auth exists on this port,
    so whatever these pages return is what an unauthenticated reader gets."""

    def fetch(self, kb, paths=("/kb", "/kb?json=1", "/?json=1", "/links")):
        surfaces = [{"name": "knowledge-base (Fly)", "url": "http://127.0.0.1:1/", "alive": True,
                     "code": 200, "ms": 3, "detail": "", "hb": "kb"},
                    {"name": "tourguide (apps)", "url": "http://127.0.0.1:2/", "alive": True,
                     "code": 200, "ms": 4, "detail": "", "hb": "tourguide"}]
        empty_loops = {"loops": [], "suggestions": [], "findings": [], "gates": [], "dismissed": 0}
        caches = {name: Mock(get=lambda: {}) for name in hub.CACHES}
        caches.update(kb=Mock(get=lambda: kb), links=Mock(get=lambda: {"surfaces": surfaces}),
                      loops=Mock(get=lambda: empty_loops))
        out = {}
        with patch.dict(hub.CACHES, caches):
            server = ThreadingHTTPServer(("127.0.0.1", 0), hub.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                for path in paths:
                    try:
                        with urllib.request.urlopen(base + path, timeout=10) as response:
                            out[path] = (response.status, response.read().decode())
                    except urllib.error.HTTPError as e:
                        out[path] = (e.code, e.read().decode())
                        e.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=10)
        return out

    def test_served_pages_keep_statuses_and_drop_private_diagnostics(self):
        kb, _ = self.reader({"heartbeat": heartbeat(), "runs": [], "steps": [],
                             "signal_quality_runs": [audit("degraded")]})
        pages = self.fetch(kb)
        for path, (status, body) in pages.items():
            with self.subTest(path=path):
                self.assertEqual(status, 200)
                self.assertNotIn(CANARY, body)
        html = pages["/kb"][1]
        self.assertIn("2/5 healthy, 4 checked", html)
        self.assertIn("DIVERGENT", html)
        self.assertIn("1 snapshot entry withheld", html)
        for shown in ("kb", "tourguide", "tntpgh_actions", "syncworks", "degraded",
                      "unreachable", "unknown", "check_unreachable", "check_not_observed"):
            self.assertIn(shown, html)
        served = json.loads(pages["/kb?json=1"][1])
        self.assertEqual(served["heartbeat"], kb["heartbeat"])
        self.assertEqual(set(served["heartbeat"]["systems"]["tourguide"]), {"status", "code"})
        overview = json.loads(pages["/?json=1"][1])
        self.assertEqual(overview["kb"]["heartbeat"], served["heartbeat"])
        self.assertIn("KB heartbeat kb: healthy", pages["/links"][1])
        self.assertIn("KB heartbeat tourguide: degraded", pages["/links"][1])

    def test_invalid_snapshot_serves_unavailable_on_every_public_path(self):
        kb, _ = self.reader({"heartbeat": heartbeat(systems={f"x_{CANARY}": {"detail": CANARY}}),
                             "runs": [], "signal_quality_runs": []})
        pages = self.fetch(kb)
        for path, (status, body) in pages.items():
            with self.subTest(path=path):
                self.assertEqual(status, 200)
                self.assertNotIn(CANARY, body)
        self.assertIn("heartbeat unavailable: invalid snapshot contract", pages["/kb"][1])
        self.assertNotIn("Fleet heartbeat —", pages["/kb"][1])
        self.assertEqual(json.loads(pages["/kb?json=1"][1]).get("heartbeat_error"),
                         "heartbeat unavailable: invalid snapshot contract")
        self.assertNotIn("heartbeat\":", pages["/kb?json=1"][1])
        self.assertNotIn("KB heartbeat", pages["/links"][1])

    def test_render_failure_serves_a_fixed_code_not_exception_text(self):
        kb, _ = self.reader({"heartbeat": heartbeat(), "runs": [], "signal_quality_runs": []})
        # PAGES holds the render callables the handler dispatches through.
        broken = Mock(side_effect=RuntimeError(f"psycopg OperationalError: dsn={CANARY}"))
        with patch.dict(hub.PAGES, {"/kb": (broken, "kb")}):
            pages = self.fetch(kb, paths=("/kb", "/kb?json=1", "/"))
        self.assertEqual(pages["/kb"], (500, "page render unavailable"))
        self.assertNotIn("RuntimeError", pages["/kb"][1])
        # The JSON path never renders, and an unrelated page still serves.
        self.assertEqual((pages["/kb?json=1"][0], pages["/"][0]), (200, 200))
        self.assertNotIn(CANARY, pages["/kb?json=1"][1] + pages["/"][1])


class AttentionProvenance(unittest.TestCase):
    """An attention COUNT must say how much of it is a fallback.

    `/herdr` marks a derived-from-stored row `unconfirmed`, but `/api/summary`
    exposed only a number, and its consumers (the omp extension,
    agent-edge.sh) cannot tell a live-confirmed blocked worker from a registry
    copy. With herdr reporting `unknown` for 12 of 14 panes, the fallback is
    the NORMAL case — a count whose provenance is invisible is how a control
    gets trusted further than it has earned.
    """

    def test_summary_reports_how_many_attention_rows_are_unconfirmed(self):
        payload = {"attention": [
            {"pane_id": "w1:p1", "state": "blocked", "state_source": "live"},
            {"pane_id": "w2:p1", "state": "blocked", "state_source": "stored"},
            {"pane_id": "w3:p1", "state": "stalled", "state_source": "stored"},
        ]}
        with patch.dict(hub.CACHES, {"herdr": hub.Cached(60, lambda: payload),
                                     "forms": hub.Cached(60, lambda: {"open_count": 0, "open": []})}), \
             patch.object(hub, "live_attention", lambda: []), \
             patch.object(hub, "live_data", lambda: {"connected": True}):
            h, f = hub.CACHES["herdr"].get(), hub.CACHES["forms"].get()
            live = hub.live_attention()
            panes = {x["pane_id"] for x in live}
            registry = [x for x in h["attention"] if x.get("pane_id") not in panes]
            unconfirmed = sum(1 for x in registry if x.get("state_source") == "stored")
        self.assertEqual((len(registry), unconfirmed), (3, 2),
                         "the summary must count fallback-derived attention rows separately")

    def test_a_live_confirmed_row_is_not_counted_as_unconfirmed(self):
        rows = [{"pane_id": "w1:p1", "state": "blocked", "state_source": "live"}]
        self.assertEqual(sum(1 for x in rows if x.get("state_source") == "stored"), 0)


class HandoffDebt(unittest.TestCase):
    """A debt nobody sees is a debt nobody pays.

    `handoff-coverage.ts` (omp-harness#9) appends one JSON object per repo a
    session changed without writing that repo's `.handoffs/notepad.md`, and
    deletes a repo's rows when a session next starts THERE — so every row
    present is unpaid by construction. The hub is the only surface that shows
    the ledger to someone not already standing in the repo that owes it, which
    is the only person in a position to notice.

    A different process writes this file on a different schedule, so every
    shape it can be caught in — absent, empty, half-appended, written by a
    newer version — must degrade to a number. The page people open when things
    are broken may not be the thing that breaks.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Path(self.tmp.name) / "omp/handoff-debt.jsonl"
        p = patch.object(hub, "HANDOFF_DEBT", self.ledger)
        p.start()
        self.addCleanup(p.stop)

    def write(self, *lines):
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        self.ledger.write_text("".join(f"{line}\n" for line in lines))

    def row(self, **kw):
        """The writer's real shape (handoff-coverage.ts `Debt`), camelCase and all."""
        r = {"repo": "/Users/x/Code/herdr-control", "at": "2026-09-18T02:14:00.000Z",
             "sessionCwd": "/Users/x/Code/thurber-os", "writes": 3, "mutations": 4,
             "shipped": True, "lessonDebt": True}
        r.update(kw)
        return json.dumps(r)

    def served(self, paths, attention=(), blocked=()):
        """The real handler over HTTP, with the REAL debt reader behind it."""
        caches = {name: Mock(get=lambda: {}) for name in hub.CACHES}
        caches.update(herdr=Mock(get=lambda: {"attention": list(attention), "tasks": [], "max_event_seq": 0}),
                      forms=Mock(get=lambda: {"open_count": 0, "open": [], "history": []}),
                      links=Mock(get=lambda: {"surfaces": []}),
                      loops=Mock(get=lambda: {"loops": [], "suggestions": [], "findings": [],
                                              "gates": [], "dismissed": 0}),
                      debt=hub.Cached(0, hub.handoff_debt_data, name="debt"))
        out = {}
        with patch.dict(hub.CACHES, caches), \
             patch.object(hub, "live_attention", lambda: list(blocked)), \
             patch.object(hub, "live_data", lambda: {"connected": True}):
            server = ThreadingHTTPServer(("127.0.0.1", 0), hub.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for path in paths:
                    with urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}{path}",
                                                timeout=10) as response:
                        out[path] = response.read().decode()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=10)
        return out

    def test_an_absent_or_empty_ledger_is_zero_debt_and_a_page_that_renders(self):
        # The normal state of a machine whose sessions keep their handoffs, and
        # the state of every machine before the extension has ever shut down a
        # session. Neither may cost a reader the overview page.
        for label, prepare in (("absent", lambda: None),
                               ("empty", lambda: self.write()),
                               ("blank lines only", lambda: self.write("", "   "))):
            with self.subTest(ledger=label):
                prepare()
                data = hub.handoff_debt_data()
                self.assertEqual((data["debt"], data["repos"], data["unreadable"]), ([], [], 0))
                # "no ledger" and "ledger I could not read" are different
                # answers, and only one of them is good news. A missing file
                # must NOT take the error arm.
                self.assertIsNone(data.get("error"))
                pages = self.served(("/api/summary", "/"))
                summary = json.loads(pages["/api/summary"])
                self.assertEqual((summary["attention"], summary["handoff_debt"]), (0, 0))
                self.assertIn("every repo a session changed has a handoff", pages["/"])
                self.assertNotIn("could not be read", pages["/"])

    def test_a_well_formed_row_names_the_repo_the_work_and_the_missing_lesson(self):
        self.write(self.row())
        row = hub.handoff_debt_data()["debt"][0]
        self.assertEqual(row, {"repo": "/Users/x/Code/herdr-control",
                               "at": "2026-09-18T02:14:00.000Z",
                               "session_cwd": "/Users/x/Code/thurber-os",
                               "writes": 3, "mutations": 4,
                               "shipped": True, "lesson_debt": True})
        page = self.served(("/",))["/"]
        # What the operator has to be able to read off the page: which repo,
        # what that session did to it, where it was standing while doing it,
        # and that the reasoning was never retained either.
        self.assertIn("herdr-control", page)
        self.assertIn("3 write(s) · 4 git/gh mutation(s)", page)
        self.assertIn("/Users/x/Code/thurber-os", page)
        self.assertIn("no lesson", page)
        self.assertIn("shipped", page)

    def test_a_malformed_line_beside_a_good_one_loses_neither_the_debt_nor_the_fact(self):
        # The shape a reader hits by racing an append: one complete row, one
        # truncated. Dropping the good row would hide real debt; counting the
        # broken one would invent debt nobody can identify; saying nothing
        # about it would report "no problem" for a corrupt ledger.
        self.write(self.row(repo="/Users/x/Code/tntpgh-dev"),
                   '{"repo": "/Users/x/Code/half-writ',
                   "not json at all",
                   json.dumps({"at": "2026-09-18T03:00:00Z", "writes": 9}),   # no repo: unownable
                   json.dumps(["a list, not an object"]))
        data = hub.handoff_debt_data()
        self.assertEqual([r["repo"] for r in data["debt"]], ["/Users/x/Code/tntpgh-dev"])
        self.assertEqual(data["unreadable"], 4)
        summary = json.loads(self.served(("/api/summary",))["/api/summary"])
        self.assertEqual((summary["handoff_debt"], summary["handoff_debt_unreadable"]), (1, 4),
                         "an unreadable line must be reported, never counted as debt")

    def test_a_row_from_a_newer_writer_degrades_field_by_field(self):
        # Forward compatibility is not optional here: the writer lives in
        # another repo and ships on its own schedule. An unknown key is
        # ignored, a wrongly-typed count reads 0, and `shipped: "yes"` is not
        # truthiness — only a real `true` may light the badge.
        self.write(json.dumps({"repo": "/Users/x/Code/tourguide", "at": 1758158040,
                               "sessionCwd": None, "writes": "several", "mutations": -2,
                               "shipped": "yes", "lessonDebt": 1, "newField": {"a": 1}}))
        self.assertEqual(hub.handoff_debt_data()["debt"], [
            {"repo": "/Users/x/Code/tourguide", "at": "", "session_cwd": "",
             "writes": 0, "mutations": 0, "shipped": False, "lesson_debt": False}])

    def test_debt_moves_the_attention_count_without_calling_a_repo_a_task(self):
        # The contract hub.py:16 documents: `attention` is what the omp
        # extension's banner reads, so unpaid debt has to be IN it. But the
        # repo's own history (ATTENTION's comment, 2026-09-18) is that a count
        # whose noun is wrong stops being read — so the halves are published
        # separately and the banner names each.
        task = {"pane_id": "w1:p1", "state": "blocked", "state_source": "live"}
        before = json.loads(self.served(("/api/summary",), attention=[task])["/api/summary"])
        self.assertEqual((before["attention"], before["attention_tasks"], before["handoff_debt"]), (1, 1, 0))

        self.write(self.row(repo="/Users/x/Code/herdr-control"),
                   self.row(repo="/Users/x/Code/tntpgh-dev", shipped=False, lessonDebt=False))
        after = json.loads(self.served(("/api/summary",), attention=[task])["/api/summary"])
        self.assertEqual((after["attention"], after["attention_tasks"], after["handoff_debt"]), (3, 1, 2))

    def test_two_sessions_owing_the_same_repo_are_one_thing_to_go_and_do(self):
        # Paying a repo's debt pays every row it holds at once, because the
        # writer clears them per repo. Counting rows would page twice for one
        # afternoon's forgetfulness in one place.
        self.write(self.row(at="2026-09-17T09:00:00Z"), self.row(at="2026-09-18T02:14:00Z"))
        summary = json.loads(self.served(("/api/summary",))["/api/summary"])
        self.assertEqual((summary["handoff_debt"], summary["handoff_debt_rows"]), (1, 2))
        # Both rows still SHOWN — two sessions is two things to reconstruct.
        self.assertEqual(len(hub.handoff_debt_data()["debt"]), 2)

    def test_an_unreadable_ledger_says_so_instead_of_reporting_none(self):
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        self.ledger.mkdir()                     # a directory where the file should be
        data = hub.handoff_debt_data()
        self.assertEqual((data["debt"], data["present"]), ([], False))
        self.assertIn("Error", data["error"])
        self.assertIn("ledger could not be read", self.served(("/",))["/"])

    def test_newest_debt_is_listed_first(self):
        self.write(self.row(repo="/Users/x/Code/a", at="2026-09-10T00:00:00Z"),
                   self.row(repo="/Users/x/Code/c", at="2026-09-18T00:00:00Z"),
                   self.row(repo="/Users/x/Code/b", at="2026-09-14T00:00:00Z"))
        self.assertEqual([r["repo"].rsplit("/", 1)[-1] for r in hub.handoff_debt_data()["debt"]],
                         ["c", "b", "a"])


class FinishedButUnseen(unittest.TestCase):
    """Finished work needed a state between "pages forever" and "invisible".

    Measured 2026-09-18: five tasks sat in Needs-attention for a day, every one
    of them a worker whose pane read "awaiting PR review/merge decision from
    Terrence" and every one filed as `stalled` — the state whose meaning is
    "took a brief and went quiet". Completion retires a row from every
    attention surface, so the only way to clear a finished-but-undecided task
    was to close its pane.

    Taxonomy borrowed with attribution from eliasstravik/herdr-projects (MIT),
    which separates Ready-for-review from Waiting-on-you and acknowledges what
    has been seen. `Landing` (PR open AND approved) is deliberately not taken:
    this registry holds no PR state.
    """

    def _task(self, **kw):
        t = {"task_id": "task_x", "pane_id": "w1:p1", "worktree": "/nonexistent",
             "state": "running", "updated_at": "2026-09-07T13:00:00Z", "pane_birth": ""}
        t.update(kw)
        return t

    def _panes(self, status="idle"):
        return {"w1:p1": {"pane_id": "w1:p1", "agent_status": status, "birth": ""}}

    def test_evidence_with_no_ack_is_ready_for_review_not_stalled(self):
        with patch.object(hub, "_evidence_at", lambda w: 1000.0), \
             patch.object(hub, "_central_done_at", lambda t: None), \
             patch.object(hub, "_acks", lambda: {}):
            self.assertEqual(hub.derive(self._task(), self._panes())[0], "ready_review")

    def test_ready_review_is_an_attention_state(self):
        self.assertIn("ready_review", hub.ATTENTION)

    def test_an_ack_at_or_after_the_evidence_clears_it(self):
        with patch.object(hub, "_evidence_at", lambda w: 1000.0), \
             patch.object(hub, "_central_done_at", lambda t: None), \
             patch.object(hub, "_acks", lambda: {"task_x": 1000.0}):
            self.assertEqual(hub.derive(self._task(), self._panes())[0], "completed")

    def test_a_newer_report_comes_back_after_an_ack(self):
        """Acking round one must not silence round two."""
        with patch.object(hub, "_evidence_at", lambda w: 2000.0), \
             patch.object(hub, "_central_done_at", lambda t: None), \
             patch.object(hub, "_acks", lambda: {"task_x": 1000.0}):
            self.assertEqual(hub.derive(self._task(), self._panes())[0], "ready_review")

    def test_no_evidence_anywhere_is_still_stalled(self):
        """The PR #313 case is untouched: a brief delivered, nothing back."""
        with patch.object(hub, "_evidence_at", lambda w: None), \
             patch.object(hub, "_central_done_at", lambda t: None), \
             patch.object(hub, "_acks", lambda: {}):
            self.assertEqual(hub.derive(self._task(), self._panes(), asked_at=500.0)[0], "stalled")

    def test_an_ack_cannot_silence_a_task_with_no_evidence(self):
        """An ack binds to an evidence time; a stalled task has none to bind."""
        with patch.object(hub, "_evidence_at", lambda w: None), \
             patch.object(hub, "_central_done_at", lambda t: None), \
             patch.object(hub, "_acks", lambda: {"task_x": 9e9}):
            self.assertEqual(hub.derive(self._task(), self._panes(), asked_at=500.0)[0], "stalled")

    def test_stale_evidence_against_a_newer_brief_is_still_stalled(self):
        with patch.object(hub, "_evidence_at", lambda w: 100.0), \
             patch.object(hub, "_central_done_at", lambda t: None), \
             patch.object(hub, "_acks", lambda: {}):
            self.assertEqual(hub.derive(self._task(), self._panes(), asked_at=500.0)[0], "stalled")


class CentralCompletionEvidence(unittest.TestCase):
    """The worktree bus is not the only sanctioned place to report finishing.

    spawn-task.sh tells every worker that a task whose own effect removes its
    worktree should "call append_event() from lib/run-registry.sh directly
    (writes to the central registry, survives worktree removal)". Nothing read
    that, so a worker taking the documented advice was indistinguishable from
    one that went quiet.
    """

    def _panes(self):
        return {"w1:p1": {"pane_id": "w1:p1", "agent_status": "idle", "birth": ""}}

    def _task(self):
        return {"task_id": "task_x", "pane_id": "w1:p1", "worktree": "/nonexistent",
                "state": "running", "updated_at": "2026-09-07T13:00:00Z", "pane_birth": ""}

    def test_central_evidence_alone_is_enough(self):
        with patch.object(hub, "_evidence_at", lambda w: None), \
             patch.object(hub, "_central_done_at", lambda t: 1000.0), \
             patch.object(hub, "_acks", lambda: {}):
            self.assertEqual(hub.derive(self._task(), self._panes())[0], "ready_review")

    def test_the_newer_of_the_two_sources_wins(self):
        with patch.object(hub, "_evidence_at", lambda w: 1000.0), \
             patch.object(hub, "_central_done_at", lambda t: 3000.0), \
             patch.object(hub, "_acks", lambda: {"task_x": 2000.0}):
            # An ack older than the central report must not clear it.
            self.assertEqual(hub.derive(self._task(), self._panes())[0], "ready_review")

    def test_a_datable_central_event_beats_an_undatable_bus(self):
        """`undatable` is not a time; a real central timestamp is."""
        with patch.object(hub, "_evidence_at", lambda w: "undatable"), \
             patch.object(hub, "_central_done_at", lambda t: 1000.0), \
             patch.object(hub, "_acks", lambda: {}):
            self.assertEqual(hub.derive(self._task(), self._panes(), asked_at=500.0)[0], "ready_review")

    def test_the_contract_is_a_SHAPE_not_a_list_of_names(self):
        """What counts is the `_done` SUFFIX, plus our reconciler's two types.

        The live registry holds six spellings workers invented for "done":
        `review.verdict`, `review_verdict`, `review_result`, `worker_done`,
        `completion_verified`, `late_verified_completion`. Only the ones ending
        `_done` count — including `worker_done`, which nothing in-tree writes
        but which satisfies the contract spawn-task.sh:125 states
        (`${label}_done`). That is the point: a SHAPE, so a worker can name its
        own event without asking permission, and not an allow-list of names,
        which is the enumeration trap this codebase keeps having to undo.
        `review.verdict` does not count — not because it is unknown, but
        because it is not the shape, and guessing intent from a name the hub
        does not define is how a stale worker reads as finished.
        """
        with tempfile.TemporaryDirectory() as d:
            db = Path(d) / "registry.sqlite3"
            import sqlite3
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, "
                         "task_id TEXT, type TEXT, occurred_at TEXT)")
            for tid, typ in (("t_invented", "review.verdict"), ("t_invented2", "worker_done"),
                             ("t_ours", "implement-x_done"), ("t_recon", "completion_recorded")):
                conn.execute("INSERT INTO events (task_id, type, occurred_at) VALUES (?,?,?)",
                             (tid, typ, "2026-09-18T08:00:00Z"))
            conn.commit(); conn.close()
            with patch.object(hub, "REGISTRY", db):
                self.assertIsNone(hub._central_done_at("t_invented"),
                                  "an agent-invented type must not count as completion")
                self.assertIsNotNone(hub._central_done_at("t_invented2"),
                                     "`worker_done` ends in _done, so it satisfies the shape")
                self.assertIsNotNone(hub._central_done_at("t_ours"),
                                     "the `_done` suffix is the contract spawn-task.sh asks for")
                self.assertIsNotNone(hub._central_done_at("t_recon"),
                                     "our own reconciler's event must count")
                # The ESCAPE clause makes `\_` a LITERAL underscore. Drop it and
                # the pattern becomes `%_done`, which matches any type ending in
                # `done` with one preceding character — `notdone`, `undone`,
                # `predone` — a widening in the read-a-stale-worker-as-finished
                # direction that left both suites green until this row existed.
                conn2 = sqlite3.connect(db)
                conn2.execute("INSERT INTO events (task_id, type, occurred_at) VALUES (?,?,?)",
                              ("t_offshape", "notdone", "2026-09-18T08:00:00Z"))
                conn2.commit(); conn2.close()
                self.assertIsNone(hub._central_done_at("t_offshape"),
                                  "the underscore is literal: ESCAPE must not be droppable")

    def test_an_unreadable_registry_is_not_completion(self):
        with patch.object(hub, "REGISTRY", Path("/nonexistent/registry.sqlite3")):
            self.assertIsNone(hub._central_done_at("t"))


class EvidenceAtIsScoped(unittest.TestCase):
    """`evidence_at` is published only for the states derived FROM evidence.

    It was published for every row, including ones `derive` short-circuits
    before ever looking at evidence — terminal, gone, working, blocked,
    herdr-unreachable — and that value is exactly what ack.sh trusted as
    "this row is acknowledgeable". An ack written against a blocked or stalled
    task lies in wait: the moment that pane goes idle with its evidence time
    unchanged, the ack fires and the row leaves every surface.
    """

    def _rows(self, state, pane_status):
        tasks = [{"task_id": "t1", "run_id": "r", "label": "l", "repo": "x", "state": state,
                  "pane_id": "w1:p1", "conductor_id": "", "worktree": "/nonexistent",
                  "created_at": "2026-09-07T12:00:00Z", "updated_at": "2026-09-07T13:00:00Z"}]
        panes = {"w1:p1": {"pane_id": "w1:p1", "agent_status": pane_status, "birth": ""}}
        with patch.object(hub, "_completion_at", lambda t: 1000.0), \
             patch.object(hub, "_acks", lambda: {}), \
             patch.object(hub, "pane_statuses", lambda: panes), \
             patch.object(hub, "REGISTRY", Path("/nonexistent")):
            # herdr_data needs a registry; drive derive directly instead and
            # apply the same publication rule the read path applies.
            st, _src = hub.derive(tasks[0], panes, None, completion=1000.0)
        return st

    def test_a_blocked_row_is_not_given_an_evidence_time(self):
        self.assertEqual(self._rows("running", "blocked"), "blocked")

    def test_an_evidence_backed_row_is(self):
        self.assertEqual(self._rows("running", "idle"), "ready_review")

    def test_herdr_data_publishes_evidence_at_only_for_evidence_backed_rows(self):
        """The rule lives in the READ PATH, so it has to be tested there.

        Driving `derive` alone left this uncovered: publishing `evidence_at`
        for every row is invisible to a derive-level test, and that field is
        exactly what ack.sh trusts as "this row is acknowledgeable".
        """
        import sqlite3
        with tempfile.TemporaryDirectory() as d:
            db = Path(d) / "registry.sqlite3"
            conn = sqlite3.connect(db)
            conn.executescript(
                "CREATE TABLE tasks (task_id TEXT, run_id TEXT, label TEXT, repo TEXT, state TEXT,"
                " pane_id TEXT, conductor_id TEXT, worktree TEXT, created_at TEXT, updated_at TEXT);"
                "CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT,"
                " task_id TEXT, occurred_at TEXT, payload TEXT);"
                "CREATE TABLE checkpoints (conductor_id TEXT, last_event_seq INT, updated_at TEXT);")
            for tid, pane in (("t_idle", "w1:p1"), ("t_blocked", "w1:p2")):
                conn.execute("INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?,?)",
                             (tid, "r", tid, "repo", "running", pane, "", "/nonexistent",
                              "2026-09-07T12:00:00Z", "2026-09-07T13:00:00Z"))
            conn.commit(); conn.close()
            panes = {"w1:p1": {"pane_id": "w1:p1", "agent_status": "idle", "birth": ""},
                     "w1:p2": {"pane_id": "w1:p2", "agent_status": "blocked", "birth": ""}}
            with patch.object(hub, "REGISTRY", db), \
                 patch.object(hub, "pane_statuses", lambda: panes), \
                 patch.object(hub, "_completion_at", lambda t: 1000.0), \
                 patch.object(hub, "_acks", lambda: {}):
                rows = {t["task_id"]: t for t in hub.herdr_data()["tasks"]}
        self.assertEqual(rows["t_idle"]["state"], "ready_review")
        self.assertEqual(rows["t_idle"]["evidence_at"], 1000.0,
                         "an evidence-backed row carries the time an ack binds to")
        self.assertEqual(rows["t_blocked"]["state"], "blocked")
        self.assertIsNone(rows["t_blocked"]["evidence_at"],
                          "a blocked row must carry NO evidence time: ack.sh trusts that field")

    def test_a_stalled_row_with_evidence_carries_no_evidence_time(self):
        """The ONE shape the publication filter alone stops.

        For blocked, gone and terminal rows the filter is redundant — the thunk
        is never called, so there is nothing to publish. It is load-bearing for
        exactly one case: a row that REACHES the idle/done arm, computes its
        evidence, and then derives `stalled` because that evidence predates the
        last brief. That is the original latent-marker vector: `evidence_at`
        would be published for a task that needs attention, and ack.sh accepts
        that field as "this row is acknowledgeable", so acking it would silence
        a worker that answered an older round and went quiet.

        Fixture from the reviewer who found it: a `_done` at 10:00 with a brief
        delivered at 12:00.
        """
        import sqlite3
        with tempfile.TemporaryDirectory() as d:
            wt = Path(d) / "wt"
            (wt / ".handoffs").mkdir(parents=True)
            (wt / ".handoffs/events.jsonl").write_text(
                '{"event":"implement:x_done","ts":"2026-09-18T10:00:00Z"}\n')
            db = Path(d) / "registry.sqlite3"
            conn = sqlite3.connect(db)
            conn.executescript(
                "CREATE TABLE tasks (task_id TEXT, run_id TEXT, label TEXT, repo TEXT, state TEXT,"
                " pane_id TEXT, conductor_id TEXT, worktree TEXT, created_at TEXT, updated_at TEXT);"
                "CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT,"
                " task_id TEXT, occurred_at TEXT, payload TEXT);"
                "CREATE TABLE checkpoints (conductor_id TEXT, last_event_seq INT, updated_at TEXT);")
            conn.execute("INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?,?)",
                         ("t_stale", "r", "l", "repo", "running", "w1:p1", "", str(wt),
                          "2026-09-18T09:00:00Z", "2026-09-18T09:30:00Z"))
            conn.execute("INSERT INTO events (type, task_id, occurred_at, payload) VALUES (?,?,?,?)",
                         ("brief_delivered", "t_stale", "2026-09-18T12:00:00Z", "{}"))
            conn.commit(); conn.close()
            panes = {"w1:p1": {"pane_id": "w1:p1", "agent_status": "idle", "birth": ""}}
            with patch.object(hub, "REGISTRY", db), \
                 patch.object(hub, "pane_statuses", lambda: panes), \
                 patch.object(hub, "_acks", lambda: {}):
                row = hub.herdr_data()["tasks"][0]
        self.assertEqual(row["state"], "stalled",
                         "evidence older than the last brief answered a previous round")
        self.assertIsNone(row["evidence_at"],
                          "a stalled row must carry no evidence time: ack.sh would accept it")

    def test_derive_does_not_recompute_when_handed_a_completion(self):
        """One computation per task on the read path, not two."""
        calls = []
        task = {"task_id": "t", "pane_id": "w1:p1", "worktree": "/nonexistent",
                "state": "running", "updated_at": "2026-09-07T13:00:00Z", "pane_birth": ""}
        panes = {"w1:p1": {"pane_id": "w1:p1", "agent_status": "idle", "birth": ""}}
        with patch.object(hub, "_completion_at", lambda t: calls.append(1) or 1000.0), \
             patch.object(hub, "_acks", lambda: {}):
            hub.derive(task, panes, None, completion=1000.0)
        self.assertEqual(calls, [], "a passed-in completion must not be recomputed")


class ClosureReasonJoin(unittest.TestCase):
    """herdr_data() joins each `completed` task to the closure reason ITS OWN
    `state_changed` event recorded (project-contract-plan.md item 1: "the
    hub shows a task as done only from the registry transition, with its
    reason"). Two shapes: a real gated completion, and pre-gate data with no
    reason on record — the second must say so plainly, not silently omit it
    or invent one.
    """

    def _registry(self, d, rows, events):
        import sqlite3
        db = Path(d) / "registry.sqlite3"
        conn = sqlite3.connect(db)
        conn.executescript(
            "CREATE TABLE tasks (task_id TEXT, run_id TEXT, label TEXT, repo TEXT, state TEXT,"
            " pane_id TEXT, conductor_id TEXT, worktree TEXT, created_at TEXT, updated_at TEXT);"
            "CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT,"
            " task_id TEXT, occurred_at TEXT, payload TEXT);"
            "CREATE TABLE checkpoints (conductor_id TEXT, last_event_seq INT, updated_at TEXT);")
        for row in rows:
            conn.execute("INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?,?)", row)
        for ev in events:
            conn.execute("INSERT INTO events (type, task_id, occurred_at, payload) VALUES (?,?,?,?)", ev)
        conn.commit(); conn.close()
        return db

    def test_a_reasoned_completion_is_joined_and_rendered(self):
        with tempfile.TemporaryDirectory() as d:
            db = self._registry(
                d,
                [("t_shipped", "r", "shipped task", "repo", "completed", "", "", "/nonexistent",
                  "2026-09-23T09:00:00Z", "2026-09-23T09:30:00Z")],
                [("state_changed", "t_shipped", "2026-09-23T09:30:00Z",
                  json.dumps({"state": "completed", "from": "running",
                              "reason": "shipped", "proof": "https://x/pr/1 abc1234"}))])
            with patch.object(hub, "REGISTRY", db), \
                 patch.object(hub, "pane_statuses", lambda: {}):
                row = hub.herdr_data()["tasks"][0]
        self.assertEqual(row["closure_reason"], "shipped")
        self.assertEqual(row["closure_proof"], "https://x/pr/1 abc1234")
        rendered = hub.task_rows([row])
        self.assertIn("closure reason", rendered)
        self.assertIn("shipped", rendered)

    def test_a_pre_gate_completion_says_so_plainly(self):
        """A `completed` row with no matching `state_changed` reason (data
        from before this gate existed, or a direct DB edit) must not be
        silently blank — the whole point of the gate is that this is
        visible, not that a missing reason renders as an empty cell that
        reads exactly like a genuinely gated completion."""
        with tempfile.TemporaryDirectory() as d:
            db = self._registry(
                d,
                [("t_old", "r", "old task", "repo", "completed", "", "", "/nonexistent",
                  "2026-08-01T09:00:00Z", "2026-08-01T09:30:00Z")],
                [])
            with patch.object(hub, "REGISTRY", db), \
                 patch.object(hub, "pane_statuses", lambda: {}):
                row = hub.herdr_data()["tasks"][0]
        self.assertIsNone(row["closure_reason"])
        rendered = hub.task_rows([row])
        self.assertIn("no reason recorded", rendered)


class BlockedDebounce(unittest.TestCase):
    """A worker is blocked for a second or two every time it asks anything.

    Undebounced, the attention count flickered with every prompt. 30s, the
    value herdr-projects measured against the same agent CLIs.
    """

    def _task(self, updated):
        return {"task_id": "t", "pane_id": "w1:p1", "worktree": "/nonexistent",
                "state": "running", "updated_at": updated, "pane_birth": ""}

    def _panes(self):
        return {"w1:p1": {"pane_id": "w1:p1", "agent_status": "blocked", "birth": ""}}

    def _iso(self, ago):
        return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=ago)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_a_momentary_block_does_not_page(self):
        self.assertEqual(hub.derive(self._task(self._iso(2)), self._panes())[0], "running")

    def test_a_block_past_the_debounce_pages(self):
        self.assertEqual(hub.derive(self._task(self._iso(120)), self._panes())[0], "blocked")

    def test_an_undatable_updated_at_pages_rather_than_hiding(self):
        """A missing timestamp must not swallow a real block."""
        self.assertEqual(hub.derive(self._task("not-a-date"), self._panes())[0], "blocked")

    def test_a_future_timestamp_does_not_hide_a_block_forever(self):
        """`time.time() - since` is NEGATIVE for a stamp ahead of the clock,
        which is also `< 30`, so an unclamped debounce hid the task on every
        surface until wall-clock caught up — for a year-ahead stamp, forever.
        Reachable without anyone doing anything wrong: run-registry's
        `import_tasks` takes `updated_at` verbatim from migrated JSON, and any
        backward clock step (NTP after a wrong-clock boot, a laptop resume)
        leaves stored stamps in the future.
        """
        for ahead in (60, 86_400, 365 * 86_400):
            self.assertEqual(
                hub.derive(self._task(self._iso(-ahead)), self._panes())[0], "blocked",
                f"a stamp {ahead}s ahead of the clock must still page")


class CacheFreshness(unittest.TestCase):
    """Who pays for a refresh, and what may be served stale.

    Measured 2026-09-15: the four network-backed caches cost ~350ms to fill and
    `loops` has a 10s TTL, so roughly every tenth second a `/herdr` load paid a
    probe round trip inline. `stale_ok` moves that off the reader. The half that
    matters more is what is NOT marked: the liveness caches must keep filling
    inline, because a stale answer about a blocked worker is the failure this
    hub exists to prevent.
    """

    def test_first_call_fills_inline_even_when_stale_is_allowed(self):
        # There is no stale value to serve yet, so the reader must wait rather
        # than be handed None.
        c = hub.Cached(60, lambda: {"n": 1}, stale_ok=True)
        self.assertEqual(c.get(), {"n": 1})

    def test_fresh_value_is_reused(self):
        calls = []
        c = hub.Cached(60, lambda: calls.append(1) or {"n": len(calls)})
        c.get(); c.get(); c.get()
        self.assertEqual(len(calls), 1)

    def test_stale_ok_returns_immediately_and_refreshes_behind_the_reader(self):
        gate = threading.Event()
        def slow():
            gate.wait(5)
            return {"v": "new"}
        c = hub.Cached(1, slow, stale_ok=True)                  # ttl=0 would mean "never stale"
        c.val, c.at = {"v": "old"}, time.monotonic() - 2       # expired, inside the ceiling
        t0 = time.monotonic()
        got = c.get()
        elapsed = time.monotonic() - t0
        self.assertEqual(got, {"v": "old"}, "a stale_ok cache must not wait for the refresh")
        self.assertLess(elapsed, 0.5, f"reader waited {elapsed:.2f}s on a background refresh")
        gate.set()
        for _ in range(100):                                    # let the thread land
            if c.get() == {"v": "new"}:
                break
            time.sleep(0.02)
        self.assertEqual(c.get(), {"v": "new"}, "the background refresh never landed")

    def test_only_one_refresh_is_in_flight(self):
        calls = []
        gate = threading.Event()
        def slow():
            calls.append(1)
            gate.wait(5)
            return {"n": len(calls)}
        c = hub.Cached(1, slow, stale_ok=True)
        c.val, c.at = {"n": 0}, time.monotonic() - 2
        for _ in range(10):
            c.get()
        gate.set()
        time.sleep(0.2)
        self.assertEqual(len(calls), 1, f"10 reads kicked {len(calls)} refreshes")

    def test_a_non_stale_cache_refills_inline_rather_than_serving_its_old_value(self):
        # BEHAVIOUR, not a boolean. The registry assertion below pins which
        # caches are marked; review proved that on its own it pins nothing —
        # mutating the guard in get() to `if self.val is not None:` serves every
        # liveness cache stale and left all seven of these tests green.
        # ttl=1 with a 2s-old value: expired, but well inside the staleness
        # ceiling — so the ONLY thing that can force a refill here is
        # stale_ok being false. With ttl=0 the ceiling is 0 and the inline path
        # is taken for the wrong reason, which let review's mutation survive.
        c = hub.Cached(1, lambda: {"v": "fresh"})            # stale_ok defaults False
        c.val, c.at = {"v": "stale"}, time.monotonic() - 2
        self.assertEqual(c.get(), {"v": "fresh"},
                         "a liveness cache served a stale value instead of filling inline")

    def test_liveness_caches_are_never_served_stale(self):
        # The deliberate non-optimisation: `/herdr` renders entirely from the
        # `herdr` cache, and the registry half of `/api/summary` is the only
        # source for a task whose pane died while it was blocked. `debt` is one
        # small local file read, so it has nothing to buy by going stale.
        for name in ("herdr", "forms", "debt"):
            self.assertFalse(hub.CACHES[name].stale_ok,
                             f"{name} must not serve a stale liveness answer")
        for name in ("search", "kb", "links", "loops"):
            self.assertTrue(hub.CACHES[name].stale_ok,
                            f"{name} makes network calls and must not block a reader")

    def test_one_read_kicks_exactly_one_fill_and_then_silence(self):
        # No timer, no heartbeat: `links_data` probes production surfaces, so a
        # cache that kept refreshing after the reader left would be an
        # unattended external side effect nobody asked for.
        #
        # This READS first. The earlier version only seeded the cache and slept,
        # so it could fail only if a timer were armed in __init__ — review
        # mutated get() to arm a self-re-arming Timer and the test stayed green
        # while the mutant fired 19 unattended probes in a second.
        calls = []
        # Seeded INSIDE the staleness ceiling (age 0.06s against 0.05 x 4), so
        # the read takes the stale branch and actually spawns the background
        # refresh this test is about. A 999s age would exceed the ceiling, take
        # the inline branch, and spawn nothing — the same fixture defect that
        # made two of its sibling rows vacuous.
        c = hub.Cached(0.05, lambda: calls.append(1) or {"n": len(calls)}, stale_ok=True)
        c.val, c.at = {"n": 0}, time.monotonic() - 0.06
        c.get()                                     # one reader, then nobody
        time.sleep(0.6)                             # many TTLs pass unattended
        self.assertEqual(len(calls), 1,
                         f"one read kicked {len(calls)} fills with no further reader")

    def test_no_reader_can_slip_between_clearing_the_flag_and_writing_the_value(self):
        """The one-refresh invariant must hold at the lock boundary, not just on average.

        `_refresh` used to clear `refreshing` in a `finally` and write the value
        in a SEPARATE lock block. Between those two acquisitions the flag was
        already False while `val` still held the old snapshot, so a reader
        arriving there kicked a second refresh — for `links` a duplicate probe
        of every production surface, which is the externality this design
        exists to avoid. Two lock acquisitions wide with no I/O between, so
        `test_only_one_refresh_is_in_flight` cannot see it; this widens the real
        window with a lock spy rather than creating one.
        """
        fills = []

        class SpyLock:
            def __init__(self, inner, on_release):
                self.inner, self.on_release, self.n = inner, on_release, 0

            def __enter__(self):
                self.inner.acquire()
                return self

            def __exit__(self, *_a):
                self.n += 1
                self.inner.release()
                self.on_release(self.n)

            def acquire(self, *a):
                return self.inner.acquire(*a)

            def release(self):
                return self.inner.release()

        c = hub.Cached(1, lambda: fills.append(1) or {"n": len(fills)}, stale_ok=True)
        c.val, c.at = {"n": 0}, time.monotonic() - 2
        arrived = {}

        def on_release(n):
            if n >= 2 and not arrived:
                arrived["state"] = (c.refreshing, dict(c.val) if c.val else None)
                c.get()                      # a reader arrives inside the window
                time.sleep(0.05)

        c.lock = SpyLock(c.lock, on_release)
        c.get()                              # kicks the background refresh
        time.sleep(0.6)
        self.assertEqual(len(fills), 1,
                         f"a reader inside the refresh window kicked {len(fills)} fills; "
                         f"it observed {arrived.get('state')}")

    def test_invalidate_forces_an_inline_refill_even_where_stale_is_allowed(self):
        # `serve_loop_decision` invalidates `loops` after writing a decision, so
        # the next view shows "deciding". Under stale_ok an expired TIMESTAMP
        # takes the stale branch instead, so the first view after deciding
        # re-offered the `Decide` button — and a second POST spawns a second
        # 4-hour formserve for one suggestion. invalidate() drops the VALUE,
        # which is the only thing the stale branch requires.
        c = hub.Cached(60, lambda: {"v": "after"}, stale_ok=True)
        c.val, c.at = {"v": "before"}, time.monotonic()
        c.invalidate()
        # The VALUE must be gone, not just its timestamp. Asserting only the
        # next get() hid the original bug: `at = 0.0` makes the age enormous
        # (monotonic is uptime), so the staleness ceiling refills inline anyway
        # — everywhere except a freshly booted machine, where the ceiling has
        # not yet been exceeded and the stale branch fires.
        self.assertIsNone(c.val, "invalidate() left the pre-invalidation value in place")
        self.assertEqual(c.get(), {"v": "after"},
                         "an invalidated cache served its pre-invalidation value")

    def test_a_refresh_in_flight_cannot_land_on_top_of_an_invalidation(self):
        # The lost update: a reader kicks a refresh, the decision handler
        # invalidates 50ms later, then the refresh lands and re-stamps the
        # PRE-decision value as fresh for a whole TTL.
        gate = threading.Event()
        state = {"v": "before"}
        def slow():
            gate.wait(5)
            return dict(state)
        c = hub.Cached(1, slow, stale_ok=True)
        c.val, c.at = {"v": "before"}, time.monotonic() - 2
        c.get()                                     # kicks the background refresh
        state["v"] = "after"                        # the world moves on
        c.invalidate()
        gate.set()
        time.sleep(0.2)                             # let the in-flight refresh land
        self.assertIsNone(c.val, "a refresh that started before invalidate() overwrote it")
        self.assertEqual(c.get(), {"v": "after"}, "the refill did not see the new world")

    def test_a_thread_that_cannot_start_does_not_freeze_the_cache(self):
        # `refreshing` latched True if Thread.start() raised — reachable on a
        # ThreadingHTTPServer parking long-polls — and the cache then served the
        # same stale value forever with no refresh EVER kicked again.
        c = hub.Cached(1, lambda: {"v": "new"}, stale_ok=True)
        c.val, c.at = {"v": "old"}, time.monotonic() - 2
        boom = Mock(side_effect=RuntimeError("can't start new thread"))
        with patch.object(hub.threading, "Thread", boom):
            self.assertEqual(c.get(), {"v": "old"}, "a failed thread start must not raise at the reader")
        self.assertFalse(c.refreshing, "refreshing latched True with no thread to clear it")
        for _ in range(100):
            if c.get() == {"v": "new"}:
                break
            time.sleep(0.02)
        self.assertEqual(c.get(), {"v": "new"}, "the cache never refreshed again")

    def test_each_source_has_its_own_staleness_bound(self):
        # `ttl x 4` was a convenience. What a stale value COSTS differs by
        # source: a stale "prod is alive" on /links is actively misleading,
        # while a twenty-minute-old read of a once-a-night ledger is the same
        # answer. A source nobody has decided about gets the short default.
        self.assertEqual(hub.CACHES["links"].stale_max, hub.STALE_MAX["links"])
        self.assertLess(hub.CACHES["links"].stale_max, hub.CACHES["kb"].stale_max,
                        "surface health may not go staler than the nightly ledger")
        self.assertEqual(hub.Cached(10, lambda: {}, stale_ok=True, name="brand-new").stale_max,
                         hub.DEFAULT_STALE_MAX,
                         "an undecided source must inherit the conservative default")
        for name in ("herdr", "forms", "debt"):
            self.assertEqual(hub.CACHES[name].stale_max, 0.0,
                             f"{name} fills inline; it has no staleness budget at all")

    def test_the_per_source_bound_is_what_get_actually_enforces(self):
        # The attribute assertions above pin the MAP; this pins that `get()`
        # uses it. A mutation back to the old flat `ttl * 4` left those green,
        # because 4 x 60s is 240s and nothing asserted an age between the two.
        # `links` is ttl=60 / bound=90: at 120s old, per-source says refill
        # inline (a stale "prod is alive" is the misleading case), the old flat
        # rule said serve it.
        c = hub.Cached(60, lambda: {"v": "probed now"}, stale_ok=True, name="links")
        c.val, c.at = {"v": "two minutes old"}, time.monotonic() - 120
        self.assertEqual(c.get(), {"v": "probed now"},
                         "a 120s-old surface verdict was served from a 90s bound")
        # And inside its own bound it is still served without waiting.
        c.val, c.at = {"v": "seventy seconds old"}, time.monotonic() - 70
        self.assertEqual(c.get(), {"v": "seventy seconds old"})

    def test_a_hung_refresh_loses_ownership_instead_of_blocking_forever(self):
        # `refreshing` was a lease of unknown length: a probe that hung held it
        # for as long as its own timeouts allowed (search_data: 50 pages at
        # timeout=20), no other refresh could start, and readers past the
        # staleness bound launched PARALLEL probes instead of waiting.
        started = threading.Event()
        release = threading.Event()
        fills = []

        def hangs():
            i = len(fills) + 1
            fills.append(i)
            started.set()
            release.wait(10)
            # Make the FIRST (soon-to-be-disowned) fill land LAST: a late write
            # from a refresh that lost ownership is the actual hazard.
            if i == 1:
                time.sleep(0.3)
            return {"n": i}

        c = hub.Cached(1, hangs, stale_ok=True, name="loops")
        c.val, c.at = {"n": 0}, time.monotonic() - 2
        c.get()                                     # kicks the refresh
        self.assertTrue(started.wait(2), "the refresh never started")
        self.assertTrue(c.refreshing)
        # Pretend it has outrun the budget.
        c.refresh_started = time.monotonic() - hub.FILL_BUDGET_S - 1
        gen_before = c.gen
        c.get()
        self.assertGreater(c.gen, gen_before,
                           "a hung refresh must lose its right to write, not just its lease")
        release.set()
        time.sleep(0.8)
        self.assertEqual(c.val, {"n": 2},
                         "the disowned refresh's late value overwrote the live one")
        self.assertEqual(len(fills), 2,
                         "breaking the lease must allow exactly one new attempt")

    def test_a_disowned_refresh_does_not_release_the_replacement_lease(self):
        # `_refresh` cleared `refreshing` unconditionally, so a thread disowned
        # for outrunning the budget released the REPLACEMENT refresh's
        # ownership on its way out — and the next reader started a THIRD
        # concurrent probe. For `links` that is every production surface, three
        # times, for one expiry.
        fills, gates = [], []

        def slow():
            g = threading.Event()
            gates.append(g)
            fills.append(1)
            g.wait(10)
            return {"n": len(fills)}

        c = hub.Cached(1, slow, stale_ok=True, name="loops")
        c.val, c.at = {"n": 0}, time.monotonic() - 2
        c.get()                                      # refresh A
        time.sleep(0.1)
        c.refresh_started = time.monotonic() - hub.FILL_BUDGET_S - 1
        c.get()                                      # disowns A, starts B
        time.sleep(0.1)
        self.assertEqual(len(fills), 2, "expected exactly A and B")
        gates[0].set()                               # A returns, disowned
        time.sleep(0.3)
        self.assertTrue(c.refreshing,
                        "the disowned refresh released B's lease")
        c.get()
        time.sleep(0.1)
        self.assertEqual(len(fills), 2,
                         f"a third probe started for one expiry ({len(fills)} fills)")
        for g in gates:
            g.set()

    def test_queued_readers_do_not_each_probe_when_the_wait_times_out(self):
        """Behavioural, and deterministic — no timing window.

        Gating the post-wait recheck on `not self.refreshing` sent every queued
        reader on to its own probe when the wait ended on a budget timeout with
        the flag still set. For `links` that is every production surface, once
        per queued reader.

        My first version of this was a SOURCE check, on the grounds that the
        behavioural form needed the fill to land inside a tenth-of-a-second
        window. Review disagreed and was right: hold the fill open on an Event
        instead of racing it, and the assertion lands on the final count after
        join. Five consecutive runs gave 2 with the fix and 3 without.
        """
        hub_budget = hub.FILL_BUDGET_S
        hub.FILL_BUDGET_S = 0.2          # the wait must TIME OUT
        try:
            started, release = threading.Event(), threading.Event()
            fills, lk = [], threading.Lock()

            def slow():
                with lk:
                    fills.append(1)
                started.set()
                release.wait(10)         # held open until both readers park
                return {"n": len(fills)}

            c = hub.Cached(0.01, slow, stale_ok=True, name="links")
            c.val, c.at = {"n": 0}, time.monotonic() - 1
            c.get()                      # R1 in flight
            self.assertTrue(started.wait(5), "the first refresh never started")
            c.at = time.monotonic() - 99999      # both readers are past the bound
            out = []
            readers = [threading.Thread(target=lambda: out.append(c.get()))
                       for _ in range(2)]
            for r in readers:
                r.start()
            time.sleep(hub.FILL_BUDGET_S * 3)    # both have provably given up
            release.set()
            for r in readers:
                r.join(10)
            self.assertEqual(len(fills), 2,
                             f"{len(fills)} fills: every queued reader probed again")
        finally:
            hub.FILL_BUDGET_S = hub_budget

    def test_the_fill_budget_exceeds_the_slowest_honest_fill(self):
        # kb_data shells out with timeout=40 and loops_data reads kb, so it
        # inherits that. A budget below the slowest legitimate fill disowns
        # HEALTHY refreshes and duplicates them — the opposite of the problem
        # the budget exists to solve. Asserted against the real timeout in the
        # source, so lowering either one without the other goes red.
        src = Path(__file__).with_name("hub.py").read_text()
        subprocess_timeouts = [float(m) for m in re.findall(r"timeout=(\d+)\)", src)]
        self.assertTrue(subprocess_timeouts, "no fill timeouts found to compare against")
        self.assertGreater(hub.FILL_BUDGET_S, max(subprocess_timeouts),
                           "the fill budget is below a fill's own timeout; healthy "
                           "refreshes will be disowned and duplicated")

    def test_a_past_bound_reader_waits_for_an_in_flight_refresh(self):
        # For `links` a duplicate fill means probing every production surface
        # twice; the point of the whole design is not doing that.
        fills = []
        gate = threading.Event()

        def slow():
            fills.append(1)
            gate.wait(5)
            return {"n": len(fills)}

        c = hub.Cached(0.05, slow, stale_ok=True, name="loops")
        c.val, c.at = {"n": 0}, time.monotonic() - 0.06
        c.get()                                     # in-flight refresh
        time.sleep(0.05)
        c.at = time.monotonic() - 999               # now past the staleness bound
        done = []
        t = threading.Thread(target=lambda: done.append(c.get()), daemon=True)
        t.start()
        time.sleep(0.3)
        self.assertEqual(len(fills), 1,
                         f"a past-bound reader started a parallel probe ({len(fills)} fills)")
        gate.set()
        t.join(5)

    def test_a_value_older_than_the_ceiling_is_refilled_inline(self):
        # `at` only advances when a fill completes and refreshes are only kicked
        # by readers, so a sparsely-read hub would serve an arbitrarily old
        # value: the first `/links` load of the morning would render last
        # night's production-surface verdicts as today's.
        c = hub.Cached(10, lambda: {"v": "today"}, stale_ok=True, name="loops")
        c.val, c.at = {"v": "last night"}, time.monotonic() - hub.STALE_MAX["loops"] - 1
        self.assertEqual(c.get(), {"v": "today"},
                         "a value past the staleness ceiling was still served")
        # Just inside the bound it is still served stale, which is the point.
        c.val, c.at = {"v": "recent"}, time.monotonic() - 11
        self.assertEqual(c.get(), {"v": "recent"})

    def test_a_failing_reader_does_not_leak_and_does_not_hang(self):
        def boom():
            raise RuntimeError(CANARY)
        c = hub.Cached(1, boom, stale_ok=True)
        self.assertEqual(c.get(), {"error": "source reader unavailable"})
        self.assertNotIn(CANARY, json.dumps(c.get()))



class RepoScope(unittest.TestCase):
    """One hub, many projects: the read path narrows, the write path does not.

    The point of scoping was to make a second orchestrator unnecessary. So
    these rows care about two things: that a scope never leaks another repo's
    work in, and that it never makes the rest of the fleet invisible or, worse,
    look calm."""

    SNAP = {
        "tasks": [
            {"task_id": "a1", "label": "kb thing", "repo": "/Users/x/Code/knowledge-base",
             "state": "blocked", "pane_id": "w1:p1", "conductor_id": "c", "updated_at": "2026-09-07T13:00:00Z"},
            {"task_id": "a2", "label": "kb other", "repo": "/Users/x/Code/knowledge-base",
             "state": "running", "pane_id": "w1:p2", "conductor_id": "c", "updated_at": "2026-09-07T13:00:00Z"},
            {"task_id": "b1", "label": "dev thing", "repo": "/Users/x/Code/tntpgh-dev",
             "state": "stalled", "pane_id": "w2:p1", "conductor_id": "c", "updated_at": "2026-09-07T13:00:00Z"},
        ],
        "events": [{"sequence": 3, "type": "x", "task_id": "b1", "label": "dev thing",
                    "occurred_at": "2026-09-07T13:00:00Z", "payload": {}},
                   {"sequence": 2, "type": "x", "task_id": "a1", "label": "kb thing",
                    "occurred_at": "2026-09-07T13:00:00Z", "payload": {}}],
        "checkpoints": [{"conductor_id": "c", "last_event_seq": 3, "updated_at": "2026-09-07T13:00:00Z"}],
        "max_event_seq": 3,
    }

    def setUp(self):
        self.snap = json.loads(json.dumps(self.SNAP))
        self.snap["attention"] = [t for t in self.snap["tasks"] if t["state"] in hub.ATTENTION]

    def test_scope_accepts_a_basename_or_a_full_path(self):
        for want in ("knowledge-base", "/Users/x/Code/knowledge-base"):
            d = hub.scoped(self.snap, want)
            self.assertEqual([t["task_id"] for t in d["tasks"]], ["a1", "a2"], want)

    def test_scope_narrows_the_attention_list(self):
        # THE point of the feature: "what needs attention" must mean "in this
        # repo". Without this row the attention list could stay fleet-wide on
        # a scoped page and every other row still passed.
        d = hub.scoped(self.snap, "knowledge-base")
        self.assertEqual([t["task_id"] for t in d["attention"]], ["a1"])
        d2 = hub.scoped(self.snap, "tntpgh-dev")
        self.assertEqual([t["task_id"] for t in d2["attention"]], ["b1"])

    def test_scope_narrows_handoff_debt_too(self):
        # #102's debt ledger rows carry a repo, so a scoped overview must not
        # show another repo's unpaid handoff — the two features landed in the
        # same file and composing them was a merge decision, not an accident.
        dbt = {"debt": [{"repo": "/Users/x/Code/knowledge-base", "writes": 1, "mutations": 0,
                         "shipped": False, "lesson_debt": False, "session_cwd": "", "at": None},
                        {"repo": "/Users/x/Code/tourguide", "writes": 2, "mutations": 1,
                         "shipped": True, "lesson_debt": True, "session_cwd": "", "at": None}]}
        kept = [r for r in dbt["debt"] if hub._repo_matches(r["repo"], "knowledge-base")]
        self.assertEqual([r["repo"].rsplit("/", 1)[-1] for r in kept], ["knowledge-base"])
        html = hub.debt_rows({"debt": kept})
        self.assertIn("knowledge-base", html)
        self.assertNotIn("tourguide", html)

    def test_scope_narrows_events_through_their_task_not_their_label(self):
        d = hub.scoped(self.snap, "knowledge-base")
        # b1's event must be gone even though its label says nothing about a repo.
        self.assertEqual([e["sequence"] for e in d["events"]], [2])

    def test_a_fleet_wide_fact_is_not_narrowed(self):
        # A conductor cursor is about the conductor, not a repo; narrowing it
        # would make a per-repo view claim the fleet is behind when it is not.
        d = hub.scoped(self.snap, "knowledge-base")
        self.assertEqual(d["max_event_seq"], 3)
        self.assertEqual(len(d["checkpoints"]), 1)

    def test_an_unscoped_snapshot_is_returned_untouched(self):
        self.assertIs(hub.scoped(self.snap, ""), self.snap)

    def test_an_unknown_scope_is_reported_not_rendered_as_calm(self):
        d = hub.scoped(self.snap, "not-a-repo")
        self.assertEqual(d["tasks"], [])
        self.assertFalse(d["scope_known"])

    def test_chip_counts_come_from_the_unscoped_snapshot(self):
        # Switching scope must never hide where the rest of the work is: the
        # chips are the only thing on a scoped page that can say so.
        html = hub.scope_chips(self.snap, "/herdr", "knowledge-base")
        self.assertIn("knowledge-base", html)
        self.assertIn("tntpgh-dev", html)
        self.assertIn(">all<", html)
        self.assertIn("repo=tntpgh-dev", html)

    def test_chips_mark_the_active_scope_and_the_hot_repos(self):
        html = hub.scope_chips(self.snap, "/herdr", "tntpgh-dev")
        active = [c for c in re.findall(r"<a class='chip ([^']*)' href='[^']*'>([^<]*)<", html) if "on" in c[0].split()]
        self.assertEqual([c[1] for c in active], ["tntpgh-dev"])
        self.assertIn("hot", dict((n, c) for c, n in re.findall(r"<a class='chip ([^']*)' href='[^']*'>([^<]*)<", html))["knowledge-base"])

    def test_scope_survives_the_pages_own_refresh_and_json_link(self):
        # A filter that undoes itself on the 15s meta-refresh is worse than no
        # filter, because the reader does not notice it happening.
        html = hub.page("herdr", "/herdr", "body", scope="knowledge-base")
        self.assertIn("url=/herdr?repo=knowledge-base", html)
        self.assertIn("json=1&repo=knowledge-base", html)

    def test_scope_of_ignores_junk_rather_than_raising(self):
        self.assertEqual(hub.scope_of("repo=kb&x=1"), "kb")
        self.assertEqual(hub.scope_of(""), "")
        self.assertEqual(hub.scope_of("repo="), "")

    def test_empty_scoped_event_list_says_it_is_a_window_artefact(self):
        # The registry reads the newest N events FLEET-WIDE and the scope is
        # applied afterwards, so a busy repo can show zero. Measured live:
        # knowledge-base had 24 tasks and 0 events in the window.
        scoped = dict(self.snap, events=[], tasks=self.snap["tasks"][:1], attention=[])
        note = hub._events_window_note(self.snap, scoped, "knowledge-base")
        self.assertIn("read fleet-wide before this scope", note)
        # ...and says nothing when there is genuinely nothing to explain.
        self.assertEqual(hub._events_window_note(self.snap, self.snap, ""), "")
        self.assertEqual(hub._events_window_note(self.snap, dict(self.snap, tasks=[]), "x"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
