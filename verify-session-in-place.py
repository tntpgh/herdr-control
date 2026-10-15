#!/usr/bin/env python3
import importlib.util
import contextlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("session_in_place", HERE / "session-in-place.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class InPlaceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.root = Path(self.td.name)
        self.repo = self.root / "repo"; self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "fixture@example.com"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Fixture"], check=True)
        (self.repo / ".gitignore").write_text("private/\n")
        (self.repo / "tracked").write_text("tracked\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "fixture"], check=True)
        (self.repo / "private").mkdir(); (self.repo / "private" / "credential").write_text("never-print-this")
        (self.repo / "untracked").write_text("keep")

    def tearDown(self): self.td.cleanup()

    def accept_dependencies(self, proc, pane):
        stack = contextlib.ExitStack()
        stack.enter_context(mock.patch.object(m, "process", return_value=proc))
        stack.enter_context(mock.patch.object(m, "pane_identity", return_value=pane))
        stack.enter_context(mock.patch.object(m, "pid_is_pane_foreground_or_ancestor", return_value=True))
        stack.enter_context(mock.patch.object(m, "git", side_effect=lambda _repo, *a: b"head\n" if a == ("rev-parse", "HEAD") else b""))
        stack.enter_context(mock.patch.object(m, "listed_paths", return_value=[]))
        stack.enter_context(mock.patch.object(m, "aggregate_paths", return_value=(m.sha_bytes(b""), 0)))
        stack.enter_context(mock.patch.object(m, "control_evidence", return_value={"control": "ok"}))
        stack.enter_context(mock.patch.object(m, "bundle_manifest", return_value={}))
        return stack

    def acceptance_baseline(self, session, repo="/repo"):
        return {"expected_runtime": {"binary_sha256": "bin", "native_sha256": "native"},
                "session_file": str(session), "session_size": 0, "session_prefix_sha256": m.sha_bytes(b""),
                "repo": repo, "pane": "p", "terminal": "t", "process": {"environment_names": ["HERDR_RUN_ID"]},
                "head": "head", "status_sha256": m.sha_bytes(b""), "submodules_sha256": m.sha_bytes(b""),
                "tracked_diff_sha256": m.sha_bytes(b""), "untracked_sha256": m.sha_bytes(b""),
                "ignored_sha256": m.sha_bytes(b""), "control": {"control": "ok"}, "bundle_manifest_sha256": "b"}

    def test_ignored_aggregate_is_stable_and_discloses_no_names(self):
        paths = m.listed_paths(self.repo, True)
        digest, count = m.aggregate_paths(self.repo, paths)
        self.assertEqual(len(digest), 64); self.assertGreaterEqual(count, 1)
        self.assertNotIn("private", digest); self.assertNotIn("never-print", digest)
        (self.repo / "private" / "credential").write_text("changed")
        self.assertNotEqual(digest, m.aggregate_paths(self.repo, m.listed_paths(self.repo, True))[0])

    def test_symlink_target_is_bound(self):
        (self.repo / "private" / "link").symlink_to("one")
        first = m.aggregate_paths(self.repo, m.listed_paths(self.repo, True))[0]
        (self.repo / "private" / "link").unlink(); (self.repo / "private" / "link").symlink_to("two")
        self.assertNotEqual(first, m.aggregate_paths(self.repo, m.listed_paths(self.repo, True))[0])

    def test_atomic_json_never_overwrites(self):
        path = self.root / "evidence" / "before.json"
        m.atomic_json(path, {"one": 1})
        with self.assertRaises(SystemExit): m.atomic_json(path, {"two": 2})
        self.assertEqual(json.loads(path.read_text()), {"one": 1})

    def test_resume_command_is_sha_bound_and_shell_quoted(self):
        ev = self.root / "ev"; ev.mkdir()
        session = self.root / "a session.jsonl"; session.write_text("x")
        (ev / "before.json").write_text(json.dumps({"session_file": str(session), "process": {"resume_args": ["--model", "opus"]}}))
        launcher = self.root / "launcher"; launcher.write_text("launcher")
        args = types.SimpleNamespace(before=str(ev), launcher=str(launcher), launcher_sha256=m.sha_file(launcher))
        with mock.patch("builtins.print") as p: m.resume_command(args)
        self.assertIn("'", p.call_args.args[0]); self.assertIn("--resume", p.call_args.args[0]); self.assertIn("--model opus", p.call_args.args[0])
        args.launcher_sha256 = "0" * 64
        with self.assertRaises(SystemExit): m.resume_command(args)

    def test_resume_args_fail_closed_without_copying_unknown_values(self):
        self.assertEqual(m.safe_resume_args("omp --model opus --resume old"), ["--model", "opus"])
        with self.assertRaises(SystemExit): m.safe_resume_args("omp --api-key secret-value")

    def test_process_resume_is_bound_to_session_path_or_id(self):
        session = Path("/tmp/2026-10-15T00-00-00Z_abc-123.jsonl")
        self.assertTrue(m.argv_resumes_session("omp --resume abc-123", session))
        self.assertTrue(m.argv_resumes_session(f"omp --resume {session}", session))
        self.assertFalse(m.argv_resumes_session("omp --resume another", session))

    def test_required_environment_names_cannot_disappear(self):
        self.assertTrue(m.required_env_present(["HERDR_RUN_ID"], ["HERDR_RUN_ID", "OMP_BOUND_RELEASE_ID"]))
        self.assertFalse(m.required_env_present(["HERDR_RUN_ID", "PI_NATIVES_DIR"], ["HERDR_RUN_ID"]))

    def test_health_must_postdate_after_verification(self):
        self.assertTrue(m.health_postdates_after(100, 101, 102))
        self.assertFalse(m.health_postdates_after(101, 100, 102))
        self.assertFalse(m.health_postdates_after(100, 101, 702))
        self.assertFalse(m.health_postdates_after(100, 103, 102))

    def test_pid_must_be_pane_foreground_or_ancestor(self):
        payload = {"result": {"process_info": {"pane_id": "p", "foreground_processes": [{"pid": 30}]}}}
        def fake_run(argv, check=True):
            if argv[:3] == ["herdr", "pane", "process-info"]:
                return json.dumps(payload).encode()
            parents = {30: 20, 20: 10, 10: 1}
            return (str(parents.get(int(argv[2]), 1)) + "\n").encode()
        with mock.patch.object(m, "run", side_effect=fake_run):
            self.assertTrue(m.pid_is_pane_foreground_or_ancestor(30, "p"))
            self.assertTrue(m.pid_is_pane_foreground_or_ancestor(20, "p"))
            self.assertFalse(m.pid_is_pane_foreground_or_ancestor(99, "p"))

    def test_shell_ready_rejects_agents_and_requires_prompt(self):
        shell = {"foreground_processes": [{"name": "zsh", "cmdline": "/bin/zsh"}]}
        self.assertTrue(m.shell_ready(shell, b"host repo % "))
        self.assertFalse(m.shell_ready({"foreground_processes": []}, b"host repo % "))
        self.assertFalse(m.shell_ready({"foreground_processes": []}, b"not a prompt"))
        self.assertFalse(m.shell_ready({"foreground_processes": [{"name": "omp"}]}, b"host repo % "))
        self.assertFalse(m.shell_ready({"foreground_processes": [{"name": "zsh"}, {"name": "python"}]}, b"host repo % "))

    def test_only_fresh_normal_dispose_exit_is_accepted(self):
        self.assertTrue(m.has_fresh_normal_session_exit(b'{"type":"custom","customType":"session_exit","data":{"kind":"normal","reason":"dispose"}}\n'))
        self.assertFalse(m.has_fresh_normal_session_exit(b'{"type":"session_exit","kind":"normal","reason":"dispose"}\n'))

    def test_idle_view_requires_bound_pid_and_empty_composer(self):
        info = {"foreground_processes": [{"pid": 77, "name": "omp"}]}
        self.assertTrue(m.omp_idle_visible(info, "╭──╮\n│  │\n╰──╯\n".encode(), 77))
        self.assertFalse(m.omp_idle_visible(info, "╭──╮\n│draft│\n╰──╯\n".encode(), 77))
        self.assertFalse(m.omp_idle_visible(info, "Allow tool:\n╭──╮\n│  │\n╰──╯\n".encode(), 77))
        self.assertFalse(m.omp_idle_visible(info, "╭──╮\n│  │\n╰──╯\n".encode(), 88))

    def test_graceful_exit_sends_exactly_one_ctrl_d_and_records_evidence(self):
        ev = self.root / "exit"; ev.mkdir(); session = self.root / "exit.jsonl"; session.write_text("prefix")
        baseline = self.acceptance_baseline(session, str(self.repo))
        proc = {"pid": 77, "birth": "birth", "argv": f"omp --resume {session}", "cwd": str(self.repo),
                "environment_names": [], "mapped_binary": "", "mapped_binary_sha256": "",
                "mapped_native": "", "mapped_native_sha256": ""}
        baseline["process"].update({"pid": 77, "birth": "birth", "argv_sha256": m.sha_bytes(proc["argv"].encode()),
                                    "resume_args": [], "mapped_binary": "", "mapped_binary_sha256": "",
                                    "mapped_native": "", "mapped_native_sha256": ""})
        (ev / "before.json").write_text(json.dumps(baseline))
        pane = {"pane": "p", "terminal": "t", "cwd": str(self.repo), "session_file": str(session)}
        calls = []
        def fake_run(argv, check=True):
            calls.append(argv)
            if argv[:3] == ["herdr", "agent", "send-keys"]:
                session.write_text('prefix\n{"type":"custom","customType":"session_exit","data":{"kind":"normal","reason":"dispose"}}\n')
                return b""
            if argv[:2] == ["ps", "-p"]: return b""
            return b""
        args = types.SimpleNamespace(before=str(ev), pid=77, pane="p", terminal="t", timeout=0.1)
        with mock.patch.object(m, "process", return_value=proc), mock.patch.object(m, "pane_identity", return_value=pane), \
             mock.patch.object(m, "pid_is_pane_foreground_or_ancestor", return_value=True), \
             mock.patch.object(m, "agent_is_idle", return_value=True), mock.patch.object(m, "omp_idle_visible", return_value=True), \
             mock.patch.object(m, "process_environment_values", return_value=[b"secret-value"]), \
             mock.patch.object(m, "pane_process_info", return_value={"pane_id": "p", "foreground_processes": [{"name": "zsh", "cmdline": "/bin/zsh"}]}), \
             mock.patch.object(m, "pane_read", return_value=b"host repo % "), mock.patch.object(m, "run", side_effect=fake_run):
            m.graceful_exit(args)
        self.assertEqual([c for c in calls if c[:3] == ["herdr", "agent", "send-keys"]],
                         [["herdr", "agent", "send-keys", "p", "ctrl+d"]])
        self.assertTrue((ev / "graceful-exit.json").is_file())

    def test_graceful_exit_rejects_drift_or_nonidle_before_any_key(self):
        ev = self.root / "reject-exit"; ev.mkdir(); session = self.root / "reject.jsonl"; session.write_text("prefix")
        proc = {"pid": 77, "birth": "birth", "argv": f"omp --resume {session}", "cwd": str(self.repo),
                "environment_names": [], "mapped_binary": "/omp", "mapped_binary_sha256": "bin",
                "mapped_native": "/native", "mapped_native_sha256": "native"}
        baseline = self.acceptance_baseline(session, str(self.repo)); baseline["process"].update(proc)
        baseline["process"].pop("argv"); baseline["process"]["argv_sha256"] = m.sha_bytes(f"omp --resume {session}".encode())
        baseline["process"]["resume_args"] = []
        (ev / "before.json").write_text(json.dumps(baseline))
        pane = {"pane": "p", "terminal": "t", "cwd": str(self.repo), "session_file": str(session)}
        args = types.SimpleNamespace(before=str(ev), pid=77, pane="p", terminal="t", timeout=1.0)
        drift = dict(proc); drift["argv"] = f"python --resume {session}"
        for current, idle in ((drift, True), (proc, False)):
            with mock.patch.object(m, "process", return_value=current), mock.patch.object(m, "pane_identity", return_value=pane), \
                 mock.patch.object(m, "pid_is_pane_foreground_or_ancestor", return_value=True), \
                 mock.patch.object(m, "agent_is_idle", return_value=idle), mock.patch.object(m, "omp_idle_visible", return_value=True), \
                 mock.patch.object(m, "pane_process_info", return_value={}), mock.patch.object(m, "pane_read", return_value=b""), \
                 mock.patch.object(m, "run") as run_call, \
                 self.assertRaises(SystemExit):
                m.graceful_exit(args)
            self.assertFalse(any(c.args[0][:3] == ["herdr", "agent", "send-keys"] for c in run_call.call_args_list))

    def test_graceful_exit_timeout_is_bounded(self):
        args = types.SimpleNamespace(before=str(self.root), pid=1, pane="p", terminal="t", timeout=float("inf"))
        (self.root / "before.json").write_text(json.dumps({"process": {"pid": 1, "birth": "b"}, "session_file": "/x", "repo": "/r"}))
        with mock.patch.object(m, "process", return_value={}), self.assertRaises(SystemExit): m.graceful_exit(args)

    def test_existing_exit_evidence_blocks_before_send(self):
        path = self.root / "graceful-exit.json"; path.write_text("existing")
        with mock.patch.object(m, "run") as run_call, self.assertRaises(SystemExit): m.reserve_json(path)
        run_call.assert_not_called()

    def test_attempt_reservation_is_exclusive_and_durable(self):
        path = self.root / "graceful-exit.json"
        first = m.reserve_json(path)
        with self.assertRaises(SystemExit): m.reserve_json(path)
        self.assertTrue(path.with_suffix(".attempt").is_file())
        os.close(first[0]); Path(first[1]).unlink()

    def test_capture_rejects_pid_not_bound_to_pane_before_reading_state(self):
        session = self.root / "capture.jsonl"; session.write_text("session")
        args = types.SimpleNamespace(repo=str(self.repo), session_file=str(session), control=str(self.root),
            hook=str(self.root / "hook"), bundle=str(self.root / "bundle"), pid=77, pane="p", terminal="t",
            target_binary=str(self.root / "omp"), target_native=str(self.root / "native"))
        proc = {"pid": 77, "birth": "birth", "argv": f"omp --resume {session}", "cwd": str(self.repo),
                "environment_names": [], "mapped_binary": "", "mapped_binary_sha256": "",
                "mapped_native": "", "mapped_native_sha256": ""}
        pane = {"pane": "p", "terminal": "t", "cwd": str(self.repo), "session_file": str(session)}
        with mock.patch.object(m, "process", return_value=proc), mock.patch.object(m, "pane_identity", return_value=pane), \
             mock.patch.object(m, "pid_is_pane_foreground_or_ancestor", return_value=False), \
             mock.patch.object(m, "git") as git_call, self.assertRaises(SystemExit):
            m.snapshot(args)
        git_call.assert_not_called()

    def test_capture_rejects_process_that_leaves_pane_during_hashing(self):
        session = self.root / "capture-race.jsonl"; session.write_text("session")
        args = types.SimpleNamespace(repo=str(self.repo), session_file=str(session), control=str(self.root),
            hook=str(self.root / "hook"), bundle=str(self.root / "bundle"), pid=77, pane="p", terminal="t",
            target_binary=str(self.root / "omp"), target_native=str(self.root / "native"))
        proc = {"pid": 77, "birth": "birth", "argv": f"omp --resume {session}", "cwd": str(self.repo),
                "environment_names": [], "mapped_binary": "", "mapped_binary_sha256": "",
                "mapped_native": "", "mapped_native_sha256": ""}
        pane = {"pane": "p", "terminal": "t", "cwd": str(self.repo), "session_file": str(session)}
        def fake_git(_repo, *argv):
            return b"head\n" if argv == ("rev-parse", "HEAD") else b""
        with mock.patch.object(m, "process", return_value=proc), mock.patch.object(m, "pane_identity", return_value=pane), \
             mock.patch.object(m, "pid_is_pane_foreground_or_ancestor", side_effect=[True, False]), \
             mock.patch.object(m, "bundle_manifest", return_value={}), mock.patch.object(m, "git", side_effect=fake_git), \
             mock.patch.object(m, "listed_paths", return_value=[]), \
             mock.patch.object(m, "aggregate_paths", return_value=(m.sha_bytes(b""), 0)), \
             mock.patch.object(m, "control_evidence", return_value={"control": "ok"}), \
             mock.patch.object(m, "sha_file", return_value="hash"), self.assertRaises(SystemExit):
            m.snapshot(args)

    def test_acceptance_is_new_process_bound_and_non_overwriting(self):
        ev = self.root / "ev"; ev.mkdir()
        session = self.root / "s_id.jsonl"; session.write_text("session")
        bundle = self.root / "bundle"; bundle.mkdir(); (bundle / "manifest.json").write_text("manifest")
        baseline = self.acceptance_baseline(session)
        baseline["bundle_manifest_sha256"] = m.sha_file(bundle / "manifest.json")
        (ev / "before.json").write_text(json.dumps(baseline))
        argv = f"omp --resume {session}"
        after = {"schema": 1, "kind": "omp-in-place-after", "checked_at_epoch": int(m.time.time()) - 1,
                 "process": {"pid": 9, "birth": "birth", "argv_sha256": m.sha_bytes(argv.encode()), "resume_args": []},
                 "pane": "p", "terminal": "t", "bundle_manifest_sha256": baseline["bundle_manifest_sha256"],
                 "binary_sha256": "bin", "native_sha256": "native", "before_sha256": m.sha_file(ev / "before.json")}
        (ev / "after.json").write_text(json.dumps(after))
        health = self.root / "health.json"; verifier = self.root / "restart.sh"; verifier.write_text("verifier")
        health.write_text(json.dumps({"schema": 1, "status": "HEALTHY", "deployed_revision": "a" * 40, "bundle_manifest_sha256": baseline["bundle_manifest_sha256"],
                                      "verifier_sha256": m.sha_file(verifier), "checked_at_epoch": int(m.time.time())}))
        args = types.SimpleNamespace(before=str(ev), pid=9, health=str(health), revision="a" * 40, verifier=str(verifier),
                                     bundle=str(bundle), control=str(self.root), hook=str(verifier))
        proc = {"birth": "birth", "cwd": "/repo", "argv": argv, "mapped_binary_sha256": "bin", "mapped_native_sha256": "native", "environment_names": ["HERDR_RUN_ID"]}
        pane = {"pane": "p", "terminal": "t", "cwd": "/repo", "session_file": str(session)}
        with self.accept_dependencies(proc, pane): m.accept(args)
        self.assertTrue((ev / "ACCEPTED.9.json").exists())
        with self.accept_dependencies(proc, pane), self.assertRaises(SystemExit): m.accept(args)

    def test_accept_rejects_unbound_verifier_and_changed_runtime(self):
        # The full happy-path fixture above proves the positive path; corrupting
        # either trust edge must fail before publication.
        ev = self.root / "negative"; ev.mkdir(); session = self.root / "n_id.jsonl"; session.write_text("s")
        bundle = self.root / "nbundle"; bundle.mkdir(); (bundle / "manifest.json").write_text("manifest")
        baseline = self.acceptance_baseline(session, "/r"); baseline["process"]["environment_names"] = []
        baseline["bundle_manifest_sha256"] = m.sha_file(bundle / "manifest.json")
        (ev / "before.json").write_text(json.dumps(baseline))
        argv = f"omp --resume {session}"
        after = {"schema": 1, "kind": "omp-in-place-after", "checked_at_epoch": int(m.time.time()) - 1,
                 "process": {"pid": 8, "birth": "b", "argv_sha256": m.sha_bytes(argv.encode()), "resume_args": []},
                 "pane": "p", "terminal": "t", "bundle_manifest_sha256": baseline["bundle_manifest_sha256"],
                 "binary_sha256": "bin", "native_sha256": "native", "before_sha256": m.sha_file(ev / "before.json")}
        (ev / "after.json").write_text(json.dumps(after)); verifier = self.root / "v"; verifier.write_text("v")
        health = self.root / "h"; health.write_text(json.dumps({"schema": 1, "status": "HEALTHY", "deployed_revision": "a"*40,
            "bundle_manifest_sha256": baseline["bundle_manifest_sha256"], "verifier_sha256": "wrong", "checked_at_epoch": int(m.time.time())}))
        args = types.SimpleNamespace(before=str(ev), pid=8, health=str(health), revision="a"*40, verifier=str(verifier),
                                     bundle=str(bundle), control=str(self.root), hook=str(verifier))
        with self.assertRaises(SystemExit): m.accept(args)
        h = json.loads(health.read_text()); h["verifier_sha256"] = m.sha_file(verifier); health.write_text(json.dumps(h))
        bad = {"birth": "b", "cwd": "/r", "argv": f"omp --resume {session}", "mapped_binary_sha256": "wrong", "mapped_native_sha256": "native", "environment_names": []}
        pane = {"pane": "p", "terminal": "t", "cwd": "/r", "session_file": str(session)}
        with self.accept_dependencies(bad, pane), self.assertRaises(SystemExit): m.accept(args)

    def test_accept_rejects_substituted_pane_and_same_birth_argv_drift(self):
        ev = self.root / "tamper"; ev.mkdir(); session = self.root / "t_id.jsonl"; session.write_text("s")
        bundle = self.root / "tbundle"; bundle.mkdir(); (bundle / "manifest.json").write_text("manifest")
        baseline = self.acceptance_baseline(session, "/r"); baseline["process"]["environment_names"] = []
        baseline["bundle_manifest_sha256"] = m.sha_file(bundle / "manifest.json")
        (ev / "before.json").write_text(json.dumps(baseline))
        original_argv = f"omp --model original --resume {session}"
        after = {"schema": 1, "kind": "omp-in-place-after", "checked_at_epoch": int(m.time.time()) - 1,
                 "pane": "other", "terminal": "other-terminal",
                 "process": {"pid": 8, "birth": "b", "argv_sha256": m.sha_bytes(original_argv.encode()),
                             "resume_args": ["--model", "original"]},
                 "bundle_manifest_sha256": baseline["bundle_manifest_sha256"], "binary_sha256": "bin", "native_sha256": "native",
                 "before_sha256": m.sha_file(ev / "before.json")}
        (ev / "after.json").write_text(json.dumps(after)); verifier = self.root / "tv"; verifier.write_text("v")
        health = self.root / "th"; health.write_text(json.dumps({"schema": 1, "status": "HEALTHY", "deployed_revision": "a"*40,
            "bundle_manifest_sha256": baseline["bundle_manifest_sha256"], "verifier_sha256": m.sha_file(verifier), "checked_at_epoch": int(m.time.time())}))
        args = types.SimpleNamespace(before=str(ev), pid=8, health=str(health), revision="a"*40, verifier=str(verifier),
                                     bundle=str(bundle), control=str(self.root), hook=str(verifier))
        current = {"birth": "b", "cwd": "/r", "argv": original_argv, "mapped_binary_sha256": "bin",
                   "mapped_native_sha256": "native", "environment_names": []}
        pane = {"pane": "p", "terminal": "t", "cwd": "/r", "session_file": str(session)}
        with self.accept_dependencies(current, pane), self.assertRaises(SystemExit):
            m.accept(args)
        after["pane"], after["terminal"] = "p", "t"
        (ev / "after.json").write_text(json.dumps(after))
        current["argv"] = f"omp --model drifted --resume {session}"
        with self.accept_dependencies(current, pane), self.assertRaises(SystemExit):
            m.accept(args)
        current["argv"] = original_argv
        with self.accept_dependencies(current, pane), mock.patch.object(m, "git", return_value=b"changed\n"), self.assertRaises(SystemExit):
            m.accept(args)


if __name__ == "__main__": unittest.main()
