#!/usr/bin/env python3
"""verify-isolated-worker.py — negative-boundary checks for the isolated smart worker.

    python3 verify-isolated-worker.py                 # host-only checks, no Docker
    HERDR_VERIFY_DOCKER=1 python3 verify-isolated-worker.py   # + real container boundary checks

Every check here is a control firing on a NEGATIVE: an escaping tar member,
a credential file in the snapshot, a symlink the worker planted, a request the
relay must refuse, a host the container must not reach. Positive end-to-end
runs (real gateway, real model, real task) are Main's live validation and are
deliberately not simulated here.

Host-only checks use only the stdlib plus `git`. The Docker section needs the
built image (Dockerfile.isolated-worker) and a reachable daemon; it creates a
uniquely named internal network and one short-lived container, and removes
both.
"""
import http.client
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


iw = _load("isolated_worker", "isolated-worker.py")
relay = _load("isolated_model_relay", "isolated-model-relay.py")

MASTER = "master-bearer-must-never-leak-0123456789"
TASK_TOKEN = "task-token-abcdefghijklmnopqrstuvwxyz"
MODEL = "anthropic/claude-test-model"


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout


def _init_repo(root):
    _git(root, "init", "-q", "-b", "main")
    _git(root, "config", "user.email", "someone@example.com")
    _git(root, "config", "user.name", "t")


# --- argument and URL policy --------------------------------------------------------

class ArgPolicy(unittest.TestCase):
    BASE = ["--repo", ".", "--ref", "HEAD", "--brief", "b.md", "--gateway-url", "http://host.docker.internal:4000",
            "--gateway-token-file", "t", "--timeout", "600"]

    def test_model_must_be_provider_qualified(self):
        for bad in ("fable", "anthropic", "openai/gpt", "anthropic/", "anthropic/../x", "claude-opus"):
            with self.assertRaises(SystemExit, msg=bad):
                iw.parse_args(self.BASE + ["--model", bad])
        a = iw.parse_args(self.BASE + ["--model", "openai-codex/gpt-6-astra"])
        self.assertEqual(a.model, "openai-codex/gpt-6-astra")

    def test_root_uid_refused(self):
        with self.assertRaises(SystemExit):
            iw.parse_args(self.BASE + ["--model", "anthropic/x", "--container-uid", "0"])

    def test_timeout_bounds(self):
        for t in ("10", "99999"):
            with self.assertRaises(SystemExit):
                iw.parse_args(self.BASE[:-1] + [t, "--model", "anthropic/x"])

    def test_gateway_url_rejects_loopback_and_v1(self):
        for bad in ("http://127.0.0.1:4000", "http://localhost:4000", "https://[::1]:4000",
                    "http://host.docker.internal:4000/v1", "ftp://host.docker.internal", "http://user:pw@" + "gw.example.com:4000",
                    "http://host.docker.internal:4000/?x=1"):
            with self.assertRaises(iw.Fail, msg=bad):
                iw.validate_gateway_url(bad)
        self.assertEqual(iw.validate_gateway_url("http://host.docker.internal:4000/"), "http://host.docker.internal:4000")

    def test_probe_url_maps_host_gateway_to_loopback(self):
        self.assertEqual(iw.probe_url_for("http://host.docker.internal:4000", None), "http://127.0.0.1:4000")
        self.assertEqual(iw.probe_url_for("http://gw.example:4000", None), "http://gw.example:4000")
        self.assertEqual(iw.probe_url_for("http://host.docker.internal:4000", "http://10.0.0.5:4000/"), "http://10.0.0.5:4000")


# --- snapshot export ----------------------------------------------------------------

class SnapshotExport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "repo")
        os.makedirs(self.repo)
        _init_repo(self.repo)

    def tearDown(self):
        self.tmp.cleanup()

    def _write(self, rel, data, mode=None):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        if mode:
            os.chmod(path, mode)

    def test_credential_and_harness_surfaces_are_omitted(self):
        self._write("src/app.py", b"print('hi')\n")
        self._write("AGENTS.md", b"# rules\n")
        self._write("run.sh", b"#!/bin/sh\necho ok\n", 0o755)
        self._write(".env", b"SECRET=1\n")
        self._write(".env.example", b"SECRET=\n")
        self._write(".envrc", b"export X=1\n")
        self._write("deploy.pem", b"-----BEGIN " + b"RSA PRIVATE KEY-----\nabc\n-----END " + b"RSA PRIVATE KEY-----\n")
        self._write("notes/key.txt", b"-----BEGIN " + b"OPENSSH PRIVATE KEY-----\nxyz\n")
        self._write(".omp/settings.json", b"{}\n")
        self._write(".claude/settings.json", b"{}\n")
        self._write(".githooks/pre-commit", b"#!/bin/sh\nrm -rf /\n", 0o755)
        self._write(".mcp.json", b"{}\n")
        # git itself refuses to track any path with a `.git` component, so a
        # nested `.git/config` can never reach the export; the exporter's
        # harness-dir rule for `.git` is a defense against a hostile tree
        # object, which a real commit here cannot produce. Not fixtured.
        self._write("vendor/lib/lib.js", b"x\n")
        os.symlink("/etc/passwd", os.path.join(self.repo, "escape"))
        os.symlink("src/app.py", os.path.join(self.repo, "inside-link"))
        self._write("untracked.txt", b"never\n")
        _git(self.repo, "add", "-f", "src", "AGENTS.md", "run.sh", ".env", ".env.example", ".envrc", "deploy.pem",
             "notes", ".omp", ".claude", ".githooks", ".mcp.json", "vendor", "escape", "inside-link")
        _git(self.repo, "commit", "-q", "-m", "c1")
        commit = _git(self.repo, "rev-parse", "HEAD").strip()
        dest = os.path.join(self.tmp.name, "staging")
        os.makedirs(dest)
        manifest = iw.export_snapshot(self.repo, commit, dest, 10 * 1024 * 1024, 100 * 1024 * 1024)

        included = {f["path"] for f in manifest["files"]}
        self.assertEqual(included, {"src/app.py", "AGENTS.md", "run.sh", "vendor/lib/lib.js"})
        excluded = {e["path"]: e["reason"] for e in manifest["excluded"]}
        self.assertEqual(excluded[".env"], "env-file")
        self.assertEqual(excluded[".env.example"], "env-file")
        self.assertEqual(excluded[".envrc"], "env-file")
        self.assertEqual(excluded["deploy.pem"], "private-key-suffix")
        self.assertEqual(excluded["notes/key.txt"], "private-key-content")
        self.assertEqual(excluded[".omp/settings.json"], "harness-dir:.omp")
        self.assertEqual(excluded[".claude/settings.json"], "harness-dir:.claude")
        self.assertEqual(excluded[".githooks/pre-commit"], "harness-dir:.githooks")
        self.assertEqual(excluded[".mcp.json"], "harness-file")
        self.assertEqual(excluded["escape"], "symlink")
        self.assertEqual(excluded["inside-link"], "symlink")
        self.assertNotIn("untracked.txt", included)

        for rel in (".env", "deploy.pem", "escape", "inside-link", ".omp", ".githooks", "untracked.txt"):
            self.assertFalse(os.path.lexists(os.path.join(dest, rel)), rel)
        self.assertTrue(os.path.isfile(os.path.join(dest, "src/app.py")))
        self.assertTrue(os.access(os.path.join(dest, "run.sh"), os.X_OK))
        self.assertEqual(manifest["commit"], commit)
        self.assertEqual(manifest["file_count"], 4)

    def test_submodules_are_listed_not_exported(self):
        self._write("a.txt", b"a\n")
        _git(self.repo, "add", "a.txt")
        _git(self.repo, "commit", "-q", "-m", "c1")
        # Fake a gitlink without needing a real submodule clone.
        sha = _git(self.repo, "rev-parse", "HEAD").strip()
        _git(self.repo, "update-index", "--add", "--cacheinfo", f"160000,{sha},sub")
        _git(self.repo, "commit", "-q", "-m", "c2")
        commit = _git(self.repo, "rev-parse", "HEAD").strip()
        dest = os.path.join(self.tmp.name, "staging")
        os.makedirs(dest)
        manifest = iw.export_snapshot(self.repo, commit, dest, 1 << 20, 1 << 24)
        self.assertEqual(manifest["submodules"], ["sub"])
        self.assertEqual({f["path"] for f in manifest["files"]}, {"a.txt"})

    def test_oversize_file_fails_closed(self):
        self._write("big.bin", b"\0" * 2048)
        _git(self.repo, "add", "big.bin")
        _git(self.repo, "commit", "-q", "-m", "c1")
        commit = _git(self.repo, "rev-parse", "HEAD").strip()
        dest = os.path.join(self.tmp.name, "staging")
        os.makedirs(dest)
        with self.assertRaises(iw.Fail):
            iw.export_snapshot(self.repo, commit, dest, 1024, 1 << 20)


class TarFilter(unittest.TestCase):
    """The tar filter is exercised directly with members git would never emit
    but a hostile archive could."""

    def _tar(self, members):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tf:
            for name, kind, payload in members:
                info = tarfile.TarInfo(name)
                if kind == "file":
                    info.size = len(payload)
                    tf.addfile(info, io.BytesIO(payload))
                elif kind == "sym":
                    info.type = tarfile.SYMTYPE
                    info.linkname = payload
                    tf.addfile(info)
                elif kind == "hard":
                    info.type = tarfile.LNKTYPE
                    info.linkname = payload
                    tf.addfile(info)
                elif kind == "dir":
                    info.type = tarfile.DIRTYPE
                    tf.addfile(info)
        buf.seek(0)
        return buf

    def test_escaping_and_link_members_never_touch_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "dest")
            os.makedirs(dest)
            stream = self._tar([
                ("../evil.txt", "file", b"x"),
                ("/abs.txt", "file", b"x"),
                ("a/../../up.txt", "file", b"x"),
                ("link", "sym", "/etc/passwd"),
                ("hard", "hard", "ok.txt"),
                ("dir/", "dir", b""),
                ("ok.txt", "file", b"fine\n"),
                ("dir/nested.txt", "file", b"n\n"),
            ])
            manifest = {"files": [], "excluded": []}
            iw.extract_tar(stream, dest, manifest, 1 << 20, 1 << 24)
            reasons = {e["path"]: e["reason"] for e in manifest["excluded"]}
            self.assertEqual(reasons["../evil.txt"], "unsafe-path")
            self.assertEqual(reasons["/abs.txt"], "unsafe-path")
            self.assertEqual(reasons["a/../../up.txt"], "unsafe-path")
            self.assertEqual(reasons["link"], "symlink")
            self.assertEqual(reasons["hard"], "hardlink")
            self.assertEqual({f["path"] for f in manifest["files"]}, {"ok.txt", "dir/nested.txt"})
            self.assertFalse(os.path.lexists(os.path.join(tmp, "evil.txt")))
            self.assertFalse(os.path.lexists(os.path.join(tmp, "up.txt")))
            self.assertFalse(os.path.lexists(os.path.join(dest, "link")))
            self.assertEqual(sorted(os.listdir(dest)), ["dir", "ok.txt"])


# --- change export --------------------------------------------------------------------

class ChangeExport(unittest.TestCase):
    def test_patch_is_data_and_symlinks_are_not_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = os.path.join(tmp, "baseline")
            stage = os.path.join(tmp, "staging")
            for root in (base, stage):
                os.makedirs(os.path.join(root, "src"))
                with open(os.path.join(root, "src", "keep.txt"), "w") as f:
                    f.write("same\n")
                with open(os.path.join(root, "src", "mod.txt"), "w") as f:
                    f.write("line1\nline2\n")
                with open(os.path.join(root, "gone.txt"), "w") as f:
                    f.write("bye")
            with open(os.path.join(stage, "src", "mod.txt"), "w") as f:
                f.write("line1\nchanged\n")
            with open(os.path.join(stage, "new.txt"), "w") as f:
                f.write("hello")  # no trailing newline
            with open(os.path.join(stage, "blob.bin"), "wb") as f:
                f.write(b"\0\1\2")
            os.remove(os.path.join(stage, "gone.txt"))
            os.symlink("/etc/passwd", os.path.join(stage, "steal"))
            os.symlink("/", os.path.join(stage, "rootdir"))
            os.makedirs(os.path.join(stage, ".git", "hooks"))
            with open(os.path.join(stage, ".git", "hooks", "pre-commit"), "w") as f:
                f.write("#!/bin/sh\nrm -rf /\n")

            export = os.path.join(tmp, "changed-files")
            patch = os.path.join(tmp, "changes.patch")
            changes = os.path.join(tmp, "changes.json")
            summary = iw.collect_changes(base, stage, export, patch, changes)

            self.assertEqual(summary["counts"], {"added": 2, "modified": 1, "deleted": 1, "symlinks": 2})
            self.assertEqual({s["path"] for s in summary["symlinks_created"]}, {"steal", "rootdir"})
            self.assertEqual(summary["binary"], ["blob.bin"])
            text = open(patch, "rb").read().decode()
            self.assertIn("--- a/src/mod.txt\n+++ b/src/mod.txt\n", text)
            self.assertIn("-line2\n+changed\n", text)
            self.assertIn("--- /dev/null\n+++ b/new.txt\n", text)
            self.assertIn("+hello\n\\ No newline at end of file\n", text)
            self.assertIn("--- a/gone.txt\n+++ /dev/null\n", text)
            self.assertIn("Binary files differ", text)
            self.assertNotIn("root:", text)          # /etc/passwd never read through the symlink
            self.assertNotIn(".git/hooks", text)     # worker-created git metadata is not exported
            self.assertTrue(os.path.isfile(os.path.join(export, "new.txt")))
            self.assertTrue(os.path.isfile(os.path.join(export, "src", "mod.txt")))
            self.assertFalse(os.path.lexists(os.path.join(export, "steal")))
            self.assertFalse(os.path.lexists(os.path.join(export, "rootdir")))
            self.assertFalse(os.path.lexists(os.path.join(export, ".git")))


# --- transcript and operator rules -----------------------------------------------------

class Transcript(unittest.TestCase):
    def _write(self, tmp, events):
        path = os.path.join(tmp, "t.jsonl")
        with open(path, "w") as f:
            f.write('{"session":"header-without-type"}\n')
            for ev in events:
                f.write(json.dumps(ev) + "\n")
            f.write("not json\n")
        return path

    def test_error_turn_is_not_completion_even_with_agent_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, [
                {"type": "message_end", "message": {"role": "assistant", "stopReason": "error", "errorMessage": "boom", "content": []}},
                {"type": "agent_end", "messages": []},
            ])
            info = iw.analyse_transcript(path)
            self.assertFalse(info["model_completed"])
            self.assertEqual(info["error_message"], "boom")
            self.assertEqual(info["unparsed_lines"], 1)

    def test_stop_without_agent_end_is_not_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, [
                {"type": "message_end", "message": {"role": "assistant", "stopReason": "stop", "content": [{"type": "text", "text": "done"}]}},
            ])
            self.assertFalse(iw.analyse_transcript(path)["model_completed"])

    def test_clean_stop_is_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, [
                {"type": "message_end", "message": {"role": "assistant", "stopReason": "toolUse", "content": []}},
                {"type": "message_end", "message": {"role": "assistant", "stopReason": "stop", "content": [{"type": "text", "text": "done"}]}},
                {"type": "agent_end", "messages": []},
            ])
            info = iw.analyse_transcript(path)
            self.assertTrue(info["model_completed"])
            self.assertEqual(info["final_text_excerpt"], "done")


class OperatorRules(unittest.TestCase):
    def test_nearest_ancestor_agents_md_wins_and_home_is_the_ceiling(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = os.path.join(tmp, "home")
            code = os.path.join(home, "Code")
            proj = os.path.join(code, "proj")
            os.makedirs(proj)
            with open(os.path.join(tmp, "AGENTS.md"), "w") as f:
                f.write("above home — must not be used\n")
            self.assertIsNone(iw.derive_operator_rules(proj, home=home))
            with open(os.path.join(code, "AGENTS.md"), "w") as f:
                f.write("operator\n")
            self.assertEqual(iw.derive_operator_rules(proj, home=home), os.path.join(code, "AGENTS.md"))

    def test_worktree_resolves_to_main_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = os.path.join(tmp, "Code", "proj")
            os.makedirs(main)
            _init_repo(main)
            with open(os.path.join(main, "f"), "w") as f:
                f.write("x")
            _git(main, "add", "f")
            _git(main, "commit", "-q", "-m", "c")
            wt = os.path.join(tmp, "worktrees", "proj-feature")
            _git(main, "worktree", "add", "-q", wt, "-b", "feature")
            self.assertEqual(os.path.realpath(iw.main_repo_root(wt)), os.path.realpath(main))


# --- relay ---------------------------------------------------------------------------------

class FakeUpstream(BaseHTTPRequestHandler):
    seen = []
    mode = "sse"       # or "401"
    slow = 0.0

    def log_message(self, *a):
        return

    def do_GET(self):
        FakeUpstream.seen.append(("GET", self.path, dict(self.headers), b""))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        FakeUpstream.seen.append(("POST", self.path, dict(self.headers), body))
        if FakeUpstream.mode == "401":
            payload = json.dumps({"error": {"type": "authentication_error", "message": "bad gateway bearer"}}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("x-request-id", "req-123")
        self.send_header("Connection", "close")
        self.end_headers()
        for i in range(3):
            self.wfile.write(f'data: {{"type":"text_delta","delta":"chunk{i}"}}\n\n'.encode())
            self.wfile.flush()
            time.sleep(FakeUpstream.slow)
        self.wfile.write(b'data: {"type":"done","reason":"stop"}\n\ndata: [DONE]\n\n')
        self.wfile.flush()


def _start_upstream():
    server = HTTPServer(("127.0.0.1", 0), FakeUpstream)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _start_relay(upstream_port, **overrides):
    cfg = {
        "listen_port": _free_port(), "task_token": TASK_TOKEN, "upstream_url": f"http://127.0.0.1:{upstream_port}",
        "upstream_token": MASTER, "model_id": MODEL, "max_body_bytes": 4096, "max_concurrent": 2,
        "max_requests": 50, "request_deadline_s": 10, "idle_timeout_s": 5, "lifetime_s": 60, "attribution_id": "herdr-iw-test",
    }
    cfg.update(overrides)
    server = relay.make_server(relay.RelayConfig(cfg), bind_host="127.0.0.1")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, cfg["listen_port"]


def _post(port, path="/v1/pi/stream", body=None, token=TASK_TOKEN, raw=None, headers=None, method="POST"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    hdrs = {"Content-Type": "application/json"}
    if token is not None:
        hdrs["Authorization"] = "Bearer " + token
    if headers:
        hdrs.update(headers)
    payload = raw if raw is not None else json.dumps(body).encode() if body is not None else None
    conn.request(method, path, body=payload, headers=hdrs)
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, dict(resp.getheaders()), data


def _good_body(**extra):
    body = {"modelId": MODEL, "context": {"messages": [{"role": "user", "content": "hi"}]}, "options": {"maxTokens": 5}, "stream": True}
    body.update(extra)
    return body


class RelayBoundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = _start_upstream()
        cls.relay, cls.port = _start_relay(cls.upstream.server_address[1])

    @classmethod
    def tearDownClass(cls):
        cls.relay.shutdown()
        cls.upstream.shutdown()

    def setUp(self):
        FakeUpstream.seen.clear()
        FakeUpstream.mode = "sse"
        FakeUpstream.slow = 0.0

    def test_only_the_stream_route_exists(self):
        for method, path in (("GET", "/v1/models"), ("GET", "/v1/usage"), ("GET", "/healthz"), ("GET", "/v1/credentials/check"),
                             ("POST", "/v1/messages"), ("POST", "/v1/chat/completions"), ("POST", "/v1/responses"),
                             ("POST", "/v1/pi/stream/../models"), ("PUT", "/v1/pi/stream"), ("OPTIONS", "/v1/pi/stream")):
            status, _, _ = _post(self.port, path=path, body=_good_body() if method != "GET" else None, method=method)
            self.assertIn(status, (404, 405), f"{method} {path} -> {status}")
        self.assertEqual(FakeUpstream.seen, [])

    def test_connect_is_refused(self):
        status, _, _ = _post(self.port, path="example.com:443", method="CONNECT", body=None)
        self.assertEqual(status, 405)

    def test_bad_or_missing_token_is_401_and_never_forwarded(self):
        for tok in (None, "", "wrong", MASTER):
            status, _, _ = _post(self.port, body=_good_body(), token=tok)
            self.assertEqual(status, 401, repr(tok))
        self.assertEqual(FakeUpstream.seen, [])

    def test_model_and_shape_policy(self):
        cases = [
            (_good_body(modelId="anthropic/other-model"), 403),
            (_good_body(modelId="openai-codex/gpt-6-astra"), 403),
            ({"model": {"id": MODEL}, "context": {"messages": []}}, 400),
            (_good_body(model=MODEL), 400),
            (_good_body(stream=False), 400),
            ({"modelId": MODEL, "context": {"messages": "nope"}}, 400),
            ({"modelId": MODEL, "context": {"messages": [], "tools": {}}}, 400),
            ([1, 2], 400),
        ]
        for body, expected in cases:
            status, _, _ = _post(self.port, body=body)
            self.assertEqual(status, expected, json.dumps(body)[:80])
        status, _, _ = _post(self.port, raw=b"{not json")
        self.assertEqual(status, 400)
        self.assertEqual(FakeUpstream.seen, [])

    def test_body_limits(self):
        big = _good_body()
        big["context"]["messages"][0]["content"] = "x" * 5000
        status, _, _ = _post(self.port, body=big)
        self.assertEqual(status, 413)
        status, _, _ = _post(self.port, raw=b"", headers={"Content-Length": "0"})
        self.assertEqual(status, 413)
        status, _, _ = _post(self.port, raw=b"5\r\n{\"a\":\r\n0\r\n\r\n", headers={"Transfer-Encoding": "chunked"})
        self.assertEqual(status, 411)
        self.assertEqual(FakeUpstream.seen, [])

    def test_forwarded_request_is_rewritten_and_sse_is_streamed_verbatim(self):
        body = _good_body()
        body["options"].update({
            "headers": {"anthropic-beta": "evil", "Authorization": "Bearer nope"},
            "metadata": {"user_id": "spoof"}, "requestMetadata": {"x": 1}, "initiatorOverride": "agent",
            "serviceTier": "priority", "preferWebsockets": True, "statefulResponses": True,
            "temperature": 0.2, "reasoning": "high",
        })
        FakeUpstream.slow = 0.05
        status, headers, data = _post(self.port, body=body, headers={
            "x-omp-install-id": "worker-spoof", "x-omp-hostname": "spoof", "anthropic-beta": "spoof",
            "x-forwarded-for": "1.2.3.4", "session_id": "spoof",
        })
        self.assertEqual(status, 200)
        self.assertTrue(headers.get("Content-Type", "").startswith("text/event-stream"))
        self.assertEqual(headers.get("x-request-id"), "req-123")
        self.assertEqual(
            data,
            b'data: {"type":"text_delta","delta":"chunk0"}\n\n'
            b'data: {"type":"text_delta","delta":"chunk1"}\n\n'
            b'data: {"type":"text_delta","delta":"chunk2"}\n\n'
            b'data: {"type":"done","reason":"stop"}\n\ndata: [DONE]\n\n',
        )
        self.assertEqual(len(FakeUpstream.seen), 1)
        method, path, up_headers, up_body = FakeUpstream.seen[0]
        self.assertEqual((method, path), ("POST", "/v1/pi/stream"))
        lower = {k.lower(): v for k, v in up_headers.items()}
        self.assertEqual(lower["authorization"], "Bearer " + MASTER)
        self.assertEqual(lower["x-omp-app"], "herdr-isolated-worker")
        self.assertEqual(lower["x-omp-install-id"], "herdr-iw-test")
        for leaked in ("anthropic-beta", "x-forwarded-for", "session_id"):
            self.assertNotIn(leaked, lower)
        sent = json.loads(up_body)
        self.assertEqual(sent["modelId"], MODEL)
        self.assertIs(sent["stream"], True)
        self.assertEqual(sent["options"], {"maxTokens": 5, "temperature": 0.2, "reasoning": "high"})
        self.assertNotIn(TASK_TOKEN.encode(), up_body)

    def test_upstream_error_is_relayed_without_master_token(self):
        FakeUpstream.mode = "401"
        status, _, data = _post(self.port, body=_good_body())
        self.assertEqual(status, 401)
        self.assertIn(b"bad gateway bearer", data)
        self.assertNotIn(MASTER.encode(), data)

    def test_upstream_prefix_is_fixed_by_config_not_request(self):
        relay_server, port = _start_relay(self.upstream.server_address[1], upstream_url=f"http://127.0.0.1:{self.upstream.server_address[1]}/gw")
        try:
            status, _, _ = _post(port, body=_good_body())
            self.assertEqual(status, 200)
            self.assertEqual(FakeUpstream.seen[-1][1], "/gw/v1/pi/stream")
        finally:
            relay_server.shutdown()


class RelayLimits(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = _start_upstream()

    @classmethod
    def tearDownClass(cls):
        cls.upstream.shutdown()

    def setUp(self):
        FakeUpstream.seen.clear()
        FakeUpstream.mode = "sse"
        FakeUpstream.slow = 0.0

    def test_quota_is_finite(self):
        server, port = _start_relay(self.upstream.server_address[1], max_requests=1)
        try:
            self.assertEqual(_post(port, body=_good_body())[0], 200)
            self.assertEqual(_post(port, body=_good_body())[0], 429)
            self.assertEqual(len(FakeUpstream.seen), 1)
        finally:
            server.shutdown()

    def test_concurrency_is_bounded(self):
        server, port = _start_relay(self.upstream.server_address[1], max_concurrent=1)
        FakeUpstream.slow = 0.4
        results = []
        try:
            t = threading.Thread(target=lambda: results.append(_post(port, body=_good_body())[0]))
            t.start()
            time.sleep(0.3)
            self.assertEqual(_post(port, body=_good_body())[0], 429)
            t.join(5)
            self.assertEqual(results, [200])
        finally:
            server.shutdown()

    def test_lockdown_after_repeated_auth_failures(self):
        server, port = _start_relay(self.upstream.server_address[1])
        try:
            for _ in range(relay.MAX_AUTH_FAILURES):
                self.assertEqual(_post(port, body=_good_body(), token="guess")[0], 401)
            self.assertEqual(_post(port, body=_good_body())[0], 503)   # even the right token is refused now
            self.assertEqual(FakeUpstream.seen, [])
        finally:
            server.shutdown()

    def test_config_rejects_bad_shapes(self):
        base = {
            "listen_port": 1, "task_token": TASK_TOKEN, "upstream_url": "http://127.0.0.1:1", "upstream_token": MASTER,
            "model_id": MODEL, "max_body_bytes": 1, "max_concurrent": 1, "max_requests": 1,
            "request_deadline_s": 1, "idle_timeout_s": 1, "lifetime_s": 1, "attribution_id": "x",
        }
        relay.RelayConfig(dict(base))
        for key, value in (("task_token", "short"), ("model_id", "noslash"), ("upstream_url", "http://h/?q=1"),
                           ("upstream_url", "socks5://h"), ("max_requests", 0), ("listen_port", "80"), ("max_concurrent", True)):
            bad = dict(base)
            bad[key] = value
            with self.assertRaises(ValueError, msg=f"{key}={value!r}"):
                relay.RelayConfig(bad)
        with self.assertRaises(ValueError):
            relay.RelayConfig({k: v for k, v in base.items() if k != "upstream_token"})


# --- real container boundary (opt-in) --------------------------------------------------------

@unittest.skipUnless(os.environ.get("HERDR_VERIFY_DOCKER") == "1", "set HERDR_VERIFY_DOCKER=1 to run container boundary checks")
class DockerBoundary(unittest.TestCase):
    IMAGE = os.environ.get("HERDR_VERIFY_IMAGE", iw.DEFAULT_IMAGE)
    PROBE = r"""
set +e
r() { printf '%s=%s\n' "$1" "$2"; }
curl -sS -m 5 -o /dev/null http://host.docker.internal:4000/healthz 2>/dev/null; r host_gateway $?
curl -sS -m 5 -o /dev/null https://example.com/ 2>/dev/null;                  r internet $?
getent hosts example.com >/dev/null 2>&1;                                       r external_dns $?
test -e /var/run/docker.sock;                                                   r docker_sock $?
test -e /workspace/.git;                                                        r workspace_git $?
touch /usr/local/bin/x 2>/dev/null;                                             r rootfs_write $?
awk 'NR>1 && $2=="00000000" {found=1} END {exit found?0:1}' /proc/net/route;    r default_route $?
r uid "$(id -u)"
r omp "$(/usr/local/bin/omp --version 2>/dev/null | head -1)"
r caps "$(awk '/CapEff/ {print $2}' /proc/self/status)"
"""

    def _docker(self, *args, check=True):
        r = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=180)
        if check and r.returncode != 0:
            raise AssertionError(f"docker {' '.join(args[:3])} failed: {r.stderr.strip()}")
        return r

    def test_worker_container_cannot_reach_host_or_internet(self):
        r = self._docker("image", "inspect", "--format", '{{index .Config.Labels "' + iw.IMAGE_LABEL + '"}}', self.IMAGE)
        self.assertEqual(r.stdout.strip(), iw.IMAGE_LABEL_VALUE, "image label missing: build Dockerfile.isolated-worker first")
        net = f"herdr-iw-verify-{os.getpid()}"
        self._docker("network", "create", "--driver", "bridge", "--internal", "--ipv6=false",
                     "--opt", "com.docker.network.bridge.gateway_mode_ipv4=isolated", net)
        try:
            r = self._docker(
                "run", "--rm", "--pull", "never", "--platform", "linux/arm64", "--network", net,
                "--user", "1000:1000", "--cap-drop", "ALL", "--security-opt", "no-new-privileges=true", "--read-only",
                "--tmpfs", "/tmp:rw,nosuid,nodev,size=16m", "--tmpfs", "/home/worker:rw,nosuid,nodev,size=16m,uid=1000,gid=1000",
                "--pids-limit", "64", "--memory", "256m", "--memory-swap", "256m",
                "--entrypoint", "/bin/sh", self.IMAGE, "-c", self.PROBE, check=False,
            )
            facts = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
            self.assertNotEqual(facts.get("host_gateway"), "0", "worker reached the host gateway port")
            self.assertNotEqual(facts.get("internet"), "0", "worker reached the internet")
            self.assertNotEqual(facts.get("external_dns"), "0", "worker resolved an external name")
            self.assertEqual(facts.get("docker_sock"), "1", "docker socket visible in worker")
            self.assertEqual(facts.get("workspace_git"), "1")
            self.assertEqual(facts.get("rootfs_write"), "1", "root filesystem writable")
            self.assertEqual(facts.get("default_route"), "1", "isolated gateway mode did not remove the default route")
            self.assertEqual(facts.get("uid"), "1000")
            self.assertEqual(facts.get("caps"), "0000000000000000", "effective capabilities not empty")
            self.assertTrue(facts.get("omp", "").endswith(iw.OMP_VERSION), facts.get("omp"))
        finally:
            self._docker("network", "rm", net, check=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
