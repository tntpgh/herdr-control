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


if __name__ == "__main__":
    unittest.main(verbosity=2)
