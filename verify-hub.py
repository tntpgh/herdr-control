#!/usr/bin/env python3
"""Hub boundary regressions: python3 verify-hub.py (stdlib, mock secrets/DB only)."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
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
        # source for a task whose pane died while it was blocked.
        for name in ("herdr", "forms"):
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

    def test_a_value_older_than_the_ceiling_is_refilled_inline(self):
        # `at` only advances when a fill completes and refreshes are only kicked
        # by readers, so a sparsely-read hub would serve an arbitrarily old
        # value: the first `/links` load of the morning would render last
        # night's production-surface verdicts as today's.
        c = hub.Cached(10, lambda: {"v": "today"}, stale_ok=True)
        c.val, c.at = {"v": "last night"}, time.monotonic() - 10 * hub.STALE_CEILING - 1
        self.assertEqual(c.get(), {"v": "today"},
                         "a value past the staleness ceiling was still served")
        # Just inside the ceiling it is still served stale, which is the point.
        c.val, c.at = {"v": "recent"}, time.monotonic() - 11
        self.assertEqual(c.get(), {"v": "recent"})

    def test_a_failing_reader_does_not_leak_and_does_not_hang(self):
        def boom():
            raise RuntimeError(CANARY)
        c = hub.Cached(1, boom, stale_ok=True)
        self.assertEqual(c.get(), {"error": "source reader unavailable"})
        self.assertNotIn(CANARY, json.dumps(c.get()))



if __name__ == "__main__":
    unittest.main(verbosity=2)
