#!/usr/bin/env python3
"""verify-ratings-hub.py — herdr-control half of closure #1 (ratings=hub_inline,
knowledge-base docs/tracking/2026-09-30-ratings-hub-publish-herdr-control-patch.md).

Covers:
  - POST /ratings/publish builds a form that renders every section as a
    pending ask, is idempotent against a nightly retry, and requires
    application/json (PR #436 review LOW).
  - An answer given LOCALLY (record_answer) or via the dashboard mirror
    (record_remote_answer) dispatches into KB's `server.ratings hub-answer`
    CLI, channel='hub' -- but ONLY for a ratings-keyed form, never for an
    ordinary decision.
  - A dispatch failure (nonzero exit OR a 200 exit carrying `errors`, PR #436
    review MEDIUM#2) is logged, never silently swallowed, and never raised
    into the caller that already durably recorded the local answer.
  - mirror_sync() excludes ratings forms from the dashboard mirror (PR #436
    review MEDIUM#3): the local-only promise is enforced in code, not prose.

    python3 verify-ratings-hub.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
STATE = Path(tempfile.mkdtemp())
(STATE / "forms").mkdir()
os.environ["HERDR_STATE_ROOT"] = str(STATE)
os.environ.pop("HERDR_DECISIONS_OWNERS", None)
sys.path.insert(0, str(HERE / "lib"))
spec = importlib.util.spec_from_file_location("hub_ratings_mod", HERE / "hub.py")
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)


class SyncThread:
    """hub._dispatch_ratings_answer fires its KB write off a background
    thread by design (PR #436 review LOW: never make the submit response
    wait on a Neon round trip). Tests need that write to have happened
    before they assert on it, so start() runs the target inline instead of
    actually threading."""
    def __init__(self, target, args=(), daemon=None):
        self._target, self._args = target, args

    def start(self):
        self._target(*self._args)


def make_form(fid, token="tok-" + "x" * 20, status="open", key=None, **extra):
    html_path = STATE / "forms" / f"{fid}.html"
    html_path.write_text(f"<html>{fid}</html>")
    if key:
        html_path.with_suffix(".key").write_text(key)
    row = {"id": fid, "title": fid, "status": status, "token": token, "url": "http://127.0.0.1:1/",
           "port": 1, "created_at": int(time.time() * 1000),
           "expires_at": int(time.time() * 1000) + 3_600_000,
           "form_path": str(html_path), **extra}
    (STATE / "forms" / f"{fid}.json").write_text(json.dumps(row))
    return row


def local(fid):
    return json.loads((STATE / "forms" / f"{fid}.json").read_text())


class PublishTests(unittest.TestCase):
    """POST /ratings/publish -> publish_ratings_form(): the pending-ask side."""

    def setUp(self):
        for p in sorted(STATE.glob("forms/*")):
            p.unlink()
        self.popen_calls = []
        patcher = patch.object(hub.subprocess, "Popen",
                               side_effect=lambda argv, **kw: self.popen_calls.append(argv))
        patcher.start()
        self.addCleanup(patcher.stop)
        hub.CACHES["forms"].invalidate()

    def _form_html(self, run_id):
        matches = sorted((STATE / "forms").glob(f"ratings-{run_id}-*.html"))
        self.assertEqual(len(matches), 1, f"expected exactly one form for {run_id}, got {matches}")
        return matches[0]

    def test_publish_renders_every_section_as_a_pending_ask(self):
        payload = {"run_id": "run1",
                   "sections": [{"slug": "kb-nightly", "title": "KB nightly", "summary": "3 new asks"},
                               {"slug": "no-summary", "title": "No summary section"}]}
        code, body = hub.publish_ratings_form(payload)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body), {"ok": True, "already_published": False})
        form = self._form_html("run1")
        html_text = form.read_text()
        self.assertIn('name="section:kb-nightly"', html_text)
        self.assertIn("KB nightly", html_text)
        self.assertIn("3 new asks", html_text)
        self.assertIn('name="section:no-summary"', html_text)
        self.assertEqual(form.with_suffix(".key").read_text(), "ratings:run1")
        self.assertEqual(len(self.popen_calls), 1)
        argv = self.popen_calls[0]
        self.assertEqual(argv[0], sys.executable)
        self.assertEqual(argv[1], str(hub.APP_ROOT / "formserve.py"))
        self.assertEqual(Path(argv[2]), form)
        self.assertIn("--timeout", argv)
        self.assertEqual(argv[argv.index("--timeout") + 1], "86400")
        self.assertIn("--no-open", argv)

    def test_publish_is_idempotent_against_a_nightly_retry(self):
        payload = {"run_id": "run2", "sections": [{"slug": "a", "title": "A"}]}
        code1, body1 = hub.publish_ratings_form(payload)
        self.assertEqual((code1, json.loads(body1)["already_published"]), (200, False))
        form = self._form_html("run2")
        # Simulate formserve having registered the form (the real Popen does this).
        make_form("regrun2", key="ratings:run2", form_path=str(form))
        hub.CACHES["forms"].invalidate()
        code2, body2 = hub.publish_ratings_form(payload)
        self.assertEqual(code2, 200)
        out2 = json.loads(body2)
        self.assertTrue(out2["already_published"])
        self.assertEqual(out2["id"], "regrun2")
        # No second form written, no second formserve spawned.
        self.assertEqual(len(list((STATE / "forms").glob("ratings-run2-*.html"))), 1)
        self.assertEqual(len(self.popen_calls), 1)

    def test_publish_rejects_missing_or_empty_payload(self):
        for bad in ({}, {"run_id": "r"}, {"run_id": "r", "sections": []},
                    {"run_id": "", "sections": [{"slug": "a"}]},
                    {"run_id": "r", "sections": [{"title": "no slug"}]}):
            with self.subTest(bad):
                code, body = hub.publish_ratings_form(bad)
                self.assertEqual(code, 400)
        self.assertEqual(self.popen_calls, [])

    def test_sections_are_not_required_a_partial_submit_is_allowed(self):
        # PR #214 review LOW F4: every section's copy says "skip any you
        # don't have an opinion on" (RATINGS_FORM), but `required` on the
        # radio group made a partial submit impossible even though KB
        # accepts partial batches.
        payload = {"run_id": "run-partial",
                   "sections": [{"slug": "a", "title": "A"}, {"slug": "b", "title": "B"}]}
        code, _ = hub.publish_ratings_form(payload)
        self.assertEqual(code, 200)
        html_text = self._form_html("run-partial").read_text()
        self.assertNotIn("required", html_text,
                          "a section's radio group must not be required: skipping it is allowed")

    def test_run_id_cannot_break_out_of_the_inline_script(self):
        # PR #214 review LOW F3: run_id goes into RATINGS_FORM's inline
        # <script> through json.dumps, which leaves a literal </script>
        # intact and lets a crafted run_id close the block early and run
        # markup/script in the hub's own origin.
        evil = "run</script><script>window.pwned=1</script>"
        payload = {"run_id": evil, "sections": [{"slug": "a", "title": "A"}]}
        code, _ = hub.publish_ratings_form(payload)
        self.assertEqual(code, 200)
        forms = sorted((STATE / "forms").glob("ratings-*.html"))
        self.assertEqual(len(forms), 1, f"expected exactly one published form, got {forms}")
        html_text = forms[0].read_text()
        self.assertNotIn("</script><script>window.pwned",
                          html_text, "run_id must not be able to close the inline <script> early")
        self.assertIn("\\u003c/script>\\u003cscript>window.pwned", html_text,
                       "run_id's < characters must be escaped inside the inline <script>")


class PublishHttpTests(unittest.TestCase):
    """The Content-Type gate lives in do_POST, not publish_ratings_form -- a
    real HTTP round trip is the only way to exercise it (PR #436 review LOW:
    forces a CORS preflight for any browser-origin caller)."""

    def setUp(self):
        import threading
        import urllib.error
        import urllib.request
        from http.server import ThreadingHTTPServer
        self.urllib_request, self.urllib_error = urllib.request, urllib.error
        patcher = patch.object(hub.subprocess, "Popen", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), hub.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        def _teardown():
            self.server.shutdown()
            self.server.server_close()
            self.thread.join(timeout=10)
        self.addCleanup(_teardown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def _post(self, path, body, ctype):
        req = self.urllib_request.Request(self.base + path, data=body,
                                          headers={"Content-Type": ctype}, method="POST")
        try:
            with self.urllib_request.urlopen(req, timeout=10) as r:
                return r.status, r.read().decode()
        except self.urllib_error.HTTPError as e:
            return e.code, e.read().decode()

    def test_non_json_content_type_is_rejected(self):
        status, body = self._post("/ratings/publish", b"run_id=x", "application/x-www-form-urlencoded")
        self.assertEqual(status, 400)
        self.assertIn("application/json", body)

    def test_json_publish_round_trips_to_a_pending_form(self):
        payload = json.dumps({"run_id": "http-run", "sections": [{"slug": "s", "title": "S"}]}).encode()
        status, body = self._post("/ratings/publish", payload, "application/json")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True, "already_published": False})
        self.assertTrue(list((STATE / "forms").glob("ratings-http-run-*.html")))


class AnswerDispatchTests(unittest.TestCase):
    """The one-click answer -> KB's `server.ratings hub-answer` CLI, channel='hub'."""

    def setUp(self):
        self.delivered = []
        patcher = patch.object(hub, "notify_owner", lambda row: self.delivered.append(row["id"]))
        patcher.start()
        self.addCleanup(patcher.stop)
        thread_patcher = patch.object(hub.threading, "Thread", SyncThread)
        thread_patcher.start()
        self.addCleanup(thread_patcher.stop)
        self.secret_patcher = patch.object(hub, "secret", return_value="postgres://dsn")
        self.secret_patcher.start()
        self.addCleanup(self.secret_patcher.stop)
        self.run_calls = []

    def _run(self, result):
        def fake_run(argv, **kw):
            self.run_calls.append((argv, kw.get("input")))
            return result
        return patch.object(hub.subprocess, "run", side_effect=fake_run)

    def test_local_answer_to_a_ratings_form_dispatches_channel_hub(self):
        make_form("r1", key="ratings:run-abc")
        result = subprocess.CompletedProcess([], 0, json.dumps({"recorded": ["kb-nightly"], "errors": []}), "")
        with self._run(result):
            code, body = hub.record_answer("r1", {
                "__formserve_token": local("r1")["token"],
                "ratings": {"kb-nightly": "acted_on", "other-section": "noise"},
            })
        self.assertEqual(code, 200)
        self.assertEqual(self.delivered, ["r1"])
        self.assertEqual(len(self.run_calls), 1)
        argv, stdin = self.run_calls[0]
        self.assertEqual(argv, [str(hub.KB_PYTHON), "-m", "server.ratings", "hub-answer"])
        sent = json.loads(stdin)
        self.assertEqual(sent["run_id"], "run-abc")
        self.assertEqual(sent["attempt_number"], 1)
        self.assertEqual({a["section_key"]: a["rating"] for a in sent["answers"]},
                         {"kb-nightly": "acted_on", "other-section": "noise"})

    def test_remote_dashboard_answer_to_a_ratings_form_also_dispatches(self):
        # Ratings forms are excluded from the mirror (§4), but defense in
        # depth (MEDIUM#3) means a stale mirror ack still must dispatch.
        row = make_form("r2", key="ratings:run-xyz")
        key = b"k" * 48
        nonce = hub._mirror_nonce(key, "r2", row["token"])
        answers = {"ratings": {"kb-nightly": "reviewed_no_action"}}
        sig = hub._mirror_mac(key, "answer", "r2", nonce, hub._mirror_canonical(answers), "tnt@teamthurber.com")
        pending = {"id": "r2", "nonce": nonce, "answers": answers,
                   "answered_by": "tnt@teamthurber.com", "answer_sig": sig}
        with patch.object(hub, "_decisions_owners", return_value={"tnt@teamthurber.com"}):
            result = subprocess.CompletedProcess([], 0, json.dumps({"recorded": ["kb-nightly"], "errors": []}), "")
            with self._run(result):
                outcome = hub.record_remote_answer("r2", pending, key)
        self.assertEqual(outcome, "delivered")
        self.assertEqual(len(self.run_calls), 1)
        sent = json.loads(self.run_calls[0][1])
        self.assertEqual(sent["run_id"], "run-xyz")

    def test_answer_to_an_ordinary_decision_never_dispatches_to_kb(self):
        make_form("d1")  # no ratings sidecar key
        with self._run(subprocess.CompletedProcess([], 0, "{}", "")):
            code, _ = hub.record_answer("d1", {
                "__formserve_token": local("d1")["token"], "decision": "accept"})
        self.assertEqual(code, 200)
        self.assertEqual(self.run_calls, [])

    def test_a_nonzero_exit_or_partial_errors_are_logged_not_swallowed(self):
        cases = [
            ("nonzero exit, no stdout", subprocess.CompletedProcess([], 1, "", "boom")),
            ("exit 0 but errors non-empty",
             subprocess.CompletedProcess([], 0, json.dumps({"recorded": [], "errors": ["bad section_key"]}), "")),
        ]
        for i, (why, result) in enumerate(cases):
            with self.subTest(why):
                fid = f"r3-{i}"
                make_form(fid, key="ratings:run-fail")
                self.run_calls.clear()
                with self._run(result):
                    with patch.object(hub.sys, "stderr") as mock_stderr:
                        code, _ = hub.record_answer(fid, {
                            "__formserve_token": local(fid)["token"],
                            "ratings": {"s": "acted_on"}})
                self.assertEqual(code, 200, "a failed KB dispatch must never fail the submit response")
                self.assertTrue(mock_stderr.write.called, f"{why}: failure must be logged")
                logged = "".join(c.args[0] for c in mock_stderr.write.call_args_list)
                self.assertIn("run-fail", logged)

    def test_missing_neon_dsn_is_logged_and_never_raises(self):
        make_form("r4", key="ratings:run-nodsn")
        self.secret_patcher.stop()
        with patch.object(hub, "secret", return_value=None):
            with patch.object(hub.subprocess, "run", side_effect=AssertionError("must not shell out without a DSN")):
                with patch.object(hub.sys, "stderr") as mock_stderr:
                    code, _ = hub.record_answer("r4", {
                        "__formserve_token": local("r4")["token"], "ratings": {"s": "acted_on"}})
        self.secret_patcher.start()
        self.assertEqual(code, 200)
        self.assertTrue(mock_stderr.write.called)

    def test_empty_ratings_answers_dispatch_nothing(self):
        make_form("r5", key="ratings:run-empty")
        with self._run(subprocess.CompletedProcess([], 0, "{}", "")):
            code, _ = hub.record_answer("r5", {"__formserve_token": local("r5")["token"]})
        self.assertEqual(code, 200)
        self.assertEqual(self.run_calls, [])


class MirrorExclusionTests(unittest.TestCase):
    """§4: ratings forms are never published to kb.hub_forms."""

    def test_mirror_sync_skips_ratings_forms_but_keeps_ordinary_ones(self):
        make_form("ratings-form", key="ratings:run-m", hub_servable=True)
        make_form("decision-form", hub_servable=True)
        hub.CACHES["forms"].invalidate()
        published = {}

        def fake_run(argv, **kw):
            published.update(json.loads(kw["input"]))
            return subprocess.CompletedProcess([], 0, json.dumps({"pending": [], "published": 1}), "")

        (STATE / "server").mkdir(exist_ok=True)
        (STATE / "server" / "hub_forms.py").touch()
        with patch.object(hub, "KB_DEPLOY", STATE), \
             patch.object(hub, "KB_PYTHON", Path(sys.executable)), \
             patch.object(hub, "secret",
                          side_effect=lambda name: "postgres://dsn" if name == "NEON_CONNECTION_STRING"
                          else "m" * 32), \
             patch.object(hub.subprocess, "run", side_effect=fake_run):
            hub.mirror_sync()
        ids = {o["id"] for o in published.get("open", [])}
        self.assertNotIn("ratings-form", ids, "a ratings form must never reach the dashboard mirror")
        self.assertIn("decision-form", ids)
        self.assertIsNone(hub.MIRROR_STATE["last_error"])


class PortAnswerDispatchTests(unittest.TestCase):
    """PR #214 review MEDIUM F1: `record_answer` and `record_remote_answer`
    dispatch inline because THIS HUB recorded the answer. An answer that
    lands on formserve's own port (answered_via=port) never goes through
    either -- formserve.py writes straight to the registry and never imports
    this module -- so without the reconciler it is recorded locally but
    never reaches kb.section_ratings, and nothing logs it."""

    def setUp(self):
        for p in sorted(STATE.glob("forms/*")):
            p.unlink()
        self.run_calls = []
        self.secret_patcher = patch.object(hub, "secret", return_value="postgres://dsn")
        self.secret_patcher.start()
        self.addCleanup(self.secret_patcher.stop)

    def _run(self, result):
        def fake_run(argv, **kw):
            self.run_calls.append((argv, kw.get("input")))
            return result
        return patch.object(hub.subprocess, "run", side_effect=fake_run)

    def test_port_answered_ratings_form_is_dispatched_and_marked(self):
        make_form("p1", key="ratings:run-port", status="answered", answered_via="port",
                  answers={"ratings": {"kb-nightly": "acted_on"}})
        result = subprocess.CompletedProcess([], 0, json.dumps({"recorded": ["kb-nightly"], "errors": []}), "")
        with self._run(result):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), 1)
        argv, stdin = self.run_calls[0]
        self.assertEqual(argv, [str(hub.KB_PYTHON), "-m", "server.ratings", "hub-answer"])
        sent = json.loads(stdin)
        self.assertEqual(sent["run_id"], "run-port")
        self.assertEqual({a["section_key"]: a["rating"] for a in sent["answers"]},
                         {"kb-nightly": "acted_on"})
        self.assertIsNotNone(local("p1").get("ratings_dispatched_at"),
                              "a successful dispatch must be marked so it is never re-sent")

    def test_already_dispatched_port_answer_is_never_resent(self):
        make_form("p2", key="ratings:run-done", status="answered", answered_via="port",
                  answers={"ratings": {"s": "noise"}}, ratings_dispatched_at=123)
        with self._run(subprocess.CompletedProcess([], 0, "{}", "")):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(self.run_calls, [])

    def test_failed_dispatch_is_logged_and_left_unmarked_for_retry(self):
        make_form("p3", key="ratings:run-retry", status="answered", answered_via="port",
                  answers={"ratings": {"s": "acted_on"}})
        with self._run(subprocess.CompletedProcess([], 1, "", "boom")):
            with patch.object(hub.sys, "stderr") as mock_stderr:
                hub._reconcile_port_ratings_answers()
        self.assertTrue(mock_stderr.write.called, "a failed dispatch must be logged")
        logged = "".join(c.args[0] for c in mock_stderr.write.call_args_list)
        self.assertIn("run-retry", logged)
        self.assertIsNone(local("p3").get("ratings_dispatched_at"),
                           "a failed dispatch must stay unmarked so the next cycle retries it")

    def test_hub_or_dashboard_answered_rows_are_never_touched(self):
        # Those paths already dispatched inline at answer time (above); the
        # reconciler exists only for the port path.
        make_form("p4", key="ratings:run-hub", status="answered", answered_via="hub",
                  answers={"ratings": {"s": "acted_on"}})
        with self._run(subprocess.CompletedProcess([], 0, "{}", "")):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(self.run_calls, [])

    def test_open_forms_and_non_ratings_port_answers_are_ignored(self):
        make_form("p5", status="open")
        make_form("p6", status="answered", answered_via="port")  # no ratings sidecar key
        with self._run(subprocess.CompletedProcess([], 0, "{}", "")):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(self.run_calls, [])

    def test_partial_error_response_is_final_and_dispatched_exactly_once(self):
        # PR #214 review R2-1: a batch where ONE section errors must not keep
        # resending the whole batch -- a resend of a section KB already
        # recorded would insert another correction row every cycle.
        make_form("p7", key="ratings:run-partial", status="answered", answered_via="port",
                  answers={"ratings": {"good": "acted_on", "bad": "noise"}})
        result = subprocess.CompletedProcess(
            [], 1, json.dumps({"recorded": [{"section_key": "good", "rating_id": 1, "corrected": False}],
                              "errors": [{"section_key": "bad", "error": "unknown section_key 'bad'"}]}), "")
        with self._run(result):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), 1)
        self.assertIsNotNone(local("p7").get("ratings_dispatched_at"),
                             "a parseable KB response is final even with a per-section error")
        with self._run(result):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), 1, "a dispatched row must never be resent")

    def test_correction_window_closed_error_is_terminal_not_retried(self):
        # KB's 24h correction window closing is a settled fact, not a
        # transport hiccup -- retrying it can never succeed.
        make_form("p8", key="ratings:run-closed", status="answered", answered_via="port",
                  answers={"ratings": {"s": "acted_on"}})
        result = subprocess.CompletedProcess(
            [], 1, json.dumps({"recorded": [],
                              "errors": [{"section_key": "s",
                                         "error": "correction window closed (24h) — rating is settled"}]}), "")
        with self._run(result):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), 1)
        self.assertIsNotNone(local("p8").get("ratings_dispatched_at"),
                             "a closed correction window is terminal, not retryable")
        with self._run(result):
            hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), 1, "a closed-window row must never be retried")

    def test_transport_failure_retries_bounded_then_gives_up(self):
        # PR #214 review R2-1: an unreachable KB (no DSN, dead subprocess,
        # unparseable stdout) must stop retrying eventually, and giving up
        # must be visible, not a silently dropped rating.
        make_form("p9", key="ratings:run-giveup", status="answered", answered_via="port",
                  answers={"ratings": {"s": "acted_on"}})
        hub.RATINGS_RECONCILE_STATE["gave_up"].clear()
        self.addCleanup(hub.RATINGS_RECONCILE_STATE["gave_up"].clear)
        clock = [1_000_000.0]

        def fake_time():
            clock[0] += 100_000  # always clears any backoff window (max 3600s)
            return clock[0]

        with self._run(subprocess.CompletedProcess([], 1, "", "boom")):
            with patch.object(hub.time, "time", side_effect=fake_time):
                for _ in range(hub.RATINGS_DISPATCH_MAX_ATTEMPTS):
                    hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), hub.RATINGS_DISPATCH_MAX_ATTEMPTS)
        row = local("p9")
        self.assertIsNotNone(row.get("ratings_dispatch_gave_up_at"),
                             f"must give up after {hub.RATINGS_DISPATCH_MAX_ATTEMPTS} attempts")
        self.assertIn("run-giveup", hub.RATINGS_RECONCILE_STATE["gave_up"],
                      "a given-up row must be surfaced on the hub")
        with self._run(subprocess.CompletedProcess([], 1, "", "boom")):
            with patch.object(hub.time, "time", side_effect=fake_time):
                hub._reconcile_port_ratings_answers()
        self.assertEqual(len(self.run_calls), hub.RATINGS_DISPATCH_MAX_ATTEMPTS,
                         "a given-up row must never be retried again")


if __name__ == "__main__":
    unittest.main(verbosity=2)
