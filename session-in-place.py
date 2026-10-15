#!/usr/bin/env python3
"""Evidence helper for serial, in-place OMP session migration.

This tool never signals a process and never writes to a pane.  It captures and
compares identity/integrity evidence, prints a shell-quoted resume command for
an external conductor, and records a process-bound acceptance without replacing
the recovery bundle's historical LIVE_ACCEPTED_AT.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import time


def die(message: str) -> "None":
    raise SystemExit(f"session-in-place: {message}")


def run(argv: list[str], *, check: bool = True) -> bytes:
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        die(f"command failed ({argv[0]} exit {p.returncode})")
    return p.stdout


def sha_file(path: Path, limit: int | None = None) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        left = limit
        while True:
            chunk = f.read(1024 * 1024 if left is None else min(left, 1024 * 1024))
            if not chunk:
                break
            h.update(chunk)
            if left is not None:
                left -= len(chunk)
                if left == 0:
                    break
    return h.hexdigest()


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def git(repo: Path, *args: str) -> bytes:
    return run(["git", "-C", str(repo), *args])


def listed_paths(repo: Path, ignored: bool) -> list[bytes]:
    args = ["ls-files", "--others", "--exclude-standard", "-z"]
    if ignored:
        args.insert(2, "--ignored")
    return sorted({p for p in git(repo, *args).split(b"\0") if p})


def aggregate_paths(repo: Path, roots: list[bytes]) -> tuple[str, int]:
    """Hash relative path, type, contents/target; disclose only digest+count."""
    entries: set[bytes] = set()
    for raw in roots:
        root = repo / os.fsdecode(raw)
        entries.add(raw)
        if root.is_dir() and not root.is_symlink():
            for base, dirs, files in os.walk(root, followlinks=False):
                dirs.sort(); files.sort()
                rel_base = Path(base).relative_to(repo)
                for name in dirs + files:
                    entries.add(os.fsencode(str(rel_base / name)))
    h = hashlib.sha256()
    for raw in sorted(entries):
        path = repo / os.fsdecode(raw)
        st = path.lstat()
        if stat.S_ISLNK(st.st_mode):
            kind, value = b"link", os.fsencode(os.readlink(path))
        elif stat.S_ISREG(st.st_mode):
            kind, value = b"file", sha_file(path).encode()
        elif stat.S_ISDIR(st.st_mode):
            kind, value = b"dir", b""
        else:
            kind, value = b"other", str(stat.S_IFMT(st.st_mode)).encode()
        h.update(raw + b"\0" + kind + b"\0" + value + b"\0")
    return h.hexdigest(), len(entries)


def tree_digest(root: Path) -> str:
    roots = [os.fsencode(str(p.relative_to(root))) for p in root.iterdir()]
    return aggregate_paths(root, roots)[0]


def process(pid: int) -> dict[str, str | int | list[str]]:
    ps = os.environ.get("HERDR_PS", "ps")
    lsof = os.environ.get("HERDR_LSOF", "lsof")
    birth = run([ps, "-p", str(pid), "-o", "lstart="]).decode().strip()
    argv = run([ps, "-p", str(pid), "-o", "command="]).decode().strip()
    cwd_lines = run([lsof, "-a", "-p", str(pid), "-d", "cwd", "-Fn"]).decode().splitlines()
    cwd = next((x[1:] for x in cwd_lines if x.startswith("n")), "")
    if not birth or not argv or not cwd:
        die(f"pid {pid} identity is not observable")
    env_text = run([ps, "eww", "-p", str(pid), "-o", "command="]).decode(errors="replace")
    names = sorted(set(re.findall(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=", env_text)))
    prefixes = ("HERDR_", "PI_", "OMP_", "OP_", "AWS_", "AZURE_", "GOOGLE_", "GITHUB_", "GH_", "OPENAI_", "ANTHROPIC_")
    names = [n for n in names if n.startswith(prefixes) or n in {"SHELL", "TMPDIR"}]
    txt = [x[1:] for x in run([lsof, "-a", "-p", str(pid), "-d", "txt", "-Fn"]).decode().splitlines() if x.startswith("n")]
    binary = next((Path(x) for x in txt if x.endswith("/bin/omp") or x.endswith("/payload/omp")), None)
    native = next((Path(x) for x in txt if x.endswith("pi_natives.darwin-arm64.node")), None)
    return {"pid": pid, "birth": birth, "argv": argv, "cwd": cwd, "environment_names": names,
            "mapped_binary": str(binary or ""), "mapped_binary_sha256": sha_file(binary) if binary and binary.is_file() else "",
            "mapped_native": str(native or ""), "mapped_native_sha256": sha_file(native) if native and native.is_file() else ""}


def pane_identity(pane: str) -> dict[str, str]:
    herdr = os.environ.get("HERDR_BIN", "herdr")
    data = json.loads(run([herdr, "pane", "list"]).decode())
    rows = data.get("result", {}).get("panes", data.get("panes", []))
    row = next((r for r in rows if r.get("pane_id") == pane), None)
    if not row: die(f"pane {pane} is not observable")
    session = row.get("agent_session") or {}
    return {"pane": pane, "terminal": row.get("terminal_id") or "", "cwd": row.get("cwd") or "",
            "session_file": session.get("value") if session.get("kind") == "path" else ""}


def pid_is_pane_foreground_or_ancestor(pid: int, pane: str) -> bool:
    """Bind a supplied PID to Herdr's current foreground process tree."""
    herdr = os.environ.get("HERDR_BIN", "herdr")
    ps = os.environ.get("HERDR_PS", "ps")
    data = json.loads(run([herdr, "pane", "process-info", "--pane", pane]).decode())
    info = data.get("result", {}).get("process_info", {})
    if info.get("pane_id") != pane:
        return False
    foreground = info.get("foreground_processes")
    if not isinstance(foreground, list) or not foreground:
        return False
    for row in foreground:
        current = row.get("pid") if isinstance(row, dict) else None
        seen: set[int] = set()
        while isinstance(current, int) and 1 < current <= 2147483647 and current not in seen:
            if current == pid:
                return True
            seen.add(current)
            parent = run([ps, "-p", str(current), "-o", "ppid="], check=False).decode().strip()
            if not parent.isdigit():
                break
            current = int(parent)
    return False


def safe_resume_args(argv: str) -> list[str]:
    try:
        parts = shlex.split(argv)
    except ValueError:
        die("process argv is not safely parseable")
    allowed_values = {"--model", "--thinking", "--approval-mode", "--append-system-prompt", "--tools"}
    out: list[str] = []
    i = 1
    while i < len(parts):
        flag = parts[i]
        if flag == "--resume":
            if i + 1 >= len(parts): die("process --resume has no value")
            i += 2; continue
        if flag not in allowed_values or i + 1 >= len(parts):
            die(f"process argv contains unsupported migration option: {flag}")
        value = parts[i + 1]
        if flag == "--append-system-prompt":
            p = Path(value).resolve()
            allowed = (Path.home() / ".cache/herdr-control/canonical-rules").resolve()
            if allowed not in p.parents or p.suffix != ".md": die("system-prompt path is outside canonical rules cache")
        elif flag == "--tools" and not re.fullmatch(r"[a-z,-]+", value): die("unsafe tools value")
        elif flag in {"--model", "--thinking", "--approval-mode"} and not re.fullmatch(r"[A-Za-z0-9_./,:-]+", value): die(f"unsafe {flag} value")
        out += [flag, value]; i += 2
    return out


def argv_resumes_session(argv: str, session: Path) -> bool:
    try: parts = shlex.split(argv)
    except ValueError: return False
    if "--resume" not in parts: return False
    i = parts.index("--resume")
    if i + 1 >= len(parts): return False
    value = parts[i + 1]
    session_id = session.stem.rsplit("_", 1)[-1]
    return value in {str(session), session_id}


def required_env_present(required: list[str], current: list[str]) -> bool:
    return set(required).issubset(current)


def health_postdates_after(after_epoch: object, health_epoch: object, now: int) -> bool:
    return isinstance(after_epoch, int) and isinstance(health_epoch, int) \
        and after_epoch <= health_epoch <= now and now - health_epoch <= 600


def control_evidence(control: Path, hook: Path) -> dict[str, str]:
    return {
        "hook_sha256": sha_file(hook),
        "config_sha256": sha_file(control / "config.sh"),
        "overlay_sha256": sha_file(control / "agent-hooks/omp-worker-overlay.yml"),
        "authority_tree_sha256": tree_digest(control / "lib"),
    }


def bundle_manifest(bundle: Path) -> dict:
    manifest = bundle / "manifest.json"
    sums = bundle / "SHA256SUMS"
    if not manifest.is_file() or not sums.is_file():
        die("recovery bundle is incomplete")
    subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=bundle,
                   stdout=subprocess.DEVNULL, check=True)
    return json.loads(manifest.read_text())


def snapshot(args: argparse.Namespace) -> dict:
    repo, session = Path(args.repo).resolve(), Path(args.session_file).resolve()
    control, hook, bundle = Path(args.control).resolve(), Path(args.hook).resolve(), Path(args.bundle).resolve()
    before = process(args.pid)
    pane_before = pane_identity(args.pane)
    if Path(str(before["cwd"])).resolve() != repo:
        die("process cwd does not match requested repository")
    if pane_before != {"pane": args.pane, "terminal": args.terminal, "cwd": str(repo), "session_file": str(session)}:
        die("pane/terminal/cwd/session binding mismatch")
    bundle_manifest(bundle)
    target_binary, target_native = Path(args.target_binary).resolve(), Path(args.target_native).resolve()
    ignored, ignored_count = aggregate_paths(repo, listed_paths(repo, True))
    untracked, untracked_count = aggregate_paths(repo, listed_paths(repo, False))
    session_size = session.stat().st_size
    public_process = dict(before)
    public_process["argv_sha256"] = sha_bytes(str(public_process.pop("argv")).encode())
    public_process["resume_args"] = safe_resume_args(str(before["argv"]))
    result = {
        "schema": 1, "kind": "omp-in-place-before", "created_at_epoch": int(time.time()),
        "pane": args.pane, "terminal": args.terminal, "process": public_process,
        "session_file": str(session), "session_size": session_size,
        "session_prefix_sha256": sha_file(session), "repo": str(repo),
        "head": git(repo, "rev-parse", "HEAD").decode().strip(),
        "status_sha256": sha_bytes(git(repo, "status", "--porcelain=v2", "--branch")),
        "submodules_sha256": sha_bytes(git(repo, "submodule", "status", "--recursive")),
        "tracked_diff_sha256": sha_bytes(git(repo, "diff", "--binary", "HEAD")),
        "untracked_sha256": untracked, "untracked_entries": untracked_count,
        "ignored_sha256": ignored, "ignored_entries": ignored_count,
        "control": control_evidence(control, hook),
        "bundle_manifest_sha256": sha_file(bundle / "manifest.json"),
        "expected_runtime": {"binary_sha256": sha_file(target_binary), "native_sha256": sha_file(target_native)},
        "secrets_policy": "environment names only; ignored paths and contents represented only by aggregate hashes",
    }
    after = process(args.pid)
    pane_after = pane_identity(args.pane)
    repeat = {
        "head": git(repo, "rev-parse", "HEAD").decode().strip(),
        "status_sha256": sha_bytes(git(repo, "status", "--porcelain=v2", "--branch")),
        "submodules_sha256": sha_bytes(git(repo, "submodule", "status", "--recursive")),
        "tracked_diff_sha256": sha_bytes(git(repo, "diff", "--binary", "HEAD")),
        "untracked_sha256": aggregate_paths(repo, listed_paths(repo, False))[0],
        "ignored_sha256": aggregate_paths(repo, listed_paths(repo, True))[0],
        "control": control_evidence(control, hook),
    }
    if before != after or pane_before != pane_after or sha_file(session, session_size) != result["session_prefix_sha256"] \
       or any(result[k] != v for k, v in repeat.items()):
        die("process or transcript changed during capture")
    return result


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if path.exists():
        die(f"refusing to overwrite {path}")
    fd, tmp = tempfile.mkstemp(prefix=".evidence.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, sort_keys=True, indent=2); f.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def capture(args: argparse.Namespace) -> None:
    out = Path(args.out).resolve()
    atomic_json(out / "before.json", snapshot(args))
    print(f"session-in-place: private baseline captured at {out}")


def verify_after(args: argparse.Namespace) -> None:
    before_path = Path(args.before).resolve() / "before.json"
    before = json.loads(before_path.read_text())
    repo, session = Path(before["repo"]), Path(before["session_file"])
    current = process(args.pid)
    failures: list[str] = []
    if current["pid"] == before["process"]["pid"] or current["birth"] == before["process"]["birth"]: failures.append("old process identity")
    if current["cwd"] != before["process"]["cwd"]: failures.append("cwd")
    if not required_env_present(before["process"]["environment_names"], current["environment_names"]): failures.append("environment names")
    if not argv_resumes_session(str(current["argv"]), session): failures.append("process/session")
    pane_now = pane_identity(args.pane)
    if pane_now != {"pane": args.pane, "terminal": args.terminal, "cwd": str(repo), "session_file": str(session)}: failures.append("pane/terminal/session")
    if not pid_is_pane_foreground_or_ancestor(args.pid, args.pane): failures.append("pane/process ancestry")
    if session.stat().st_size <= before["session_size"] or sha_file(session, before["session_size"]) != before["session_prefix_sha256"]:
        failures.append("transcript prefix")
    checks = {
        "head": git(repo, "rev-parse", "HEAD").decode().strip(),
        "status_sha256": sha_bytes(git(repo, "status", "--porcelain=v2", "--branch")),
        "submodules_sha256": sha_bytes(git(repo, "submodule", "status", "--recursive")),
        "tracked_diff_sha256": sha_bytes(git(repo, "diff", "--binary", "HEAD")),
        "untracked_sha256": aggregate_paths(repo, listed_paths(repo, False))[0],
        "ignored_sha256": aggregate_paths(repo, listed_paths(repo, True))[0],
    }
    for key, value in checks.items():
        if before[key] != value: failures.append(key)
    bundle = Path(args.bundle).resolve(); bundle_manifest(bundle)
    binary, native = Path(args.binary).resolve(), Path(args.native).resolve()
    if sha_file(bundle / "manifest.json") != before["bundle_manifest_sha256"]: failures.append("bundle")
    if sha_file(binary) != before["expected_runtime"]["binary_sha256"]: failures.append("binary")
    if sha_file(native) != before["expected_runtime"]["native_sha256"]: failures.append("native")
    if current["mapped_binary_sha256"] != before["expected_runtime"]["binary_sha256"]: failures.append("running binary")
    if current["mapped_native_sha256"] != before["expected_runtime"]["native_sha256"]: failures.append("running native")
    if control_evidence(Path(args.control).resolve(), Path(args.hook).resolve()) != before["control"]:
        failures.append("control")
    if failures: die("after verification mismatch: " + ", ".join(failures))
    public_current = dict(current)
    public_current["argv_sha256"] = sha_bytes(str(public_current.pop("argv")).encode())
    public_current["resume_args"] = safe_resume_args(str(current["argv"]))
    record = {"schema": 1, "kind": "omp-in-place-after", "checked_at_epoch": int(time.time()),
              "process": public_current, "pane": args.pane, "terminal": args.terminal,
              "before_sha256": sha_file(before_path), "bundle_manifest_sha256": sha_file(bundle / "manifest.json"),
              "binary_sha256": sha_file(binary), "native_sha256": sha_file(native)}
    atomic_json(before_path.parent / "after.json", record)
    print(f"session-in-place: new process {args.pid} verified against private baseline")


def resume_command(args: argparse.Namespace) -> None:
    before = json.loads((Path(args.before).resolve() / "before.json").read_text())
    launcher = Path(args.launcher).resolve()
    if sha_file(launcher) != args.launcher_sha256:
        die("launcher SHA-256 mismatch")
    command = [str(launcher), *before["process"]["resume_args"], "--resume", before["session_file"]]
    print(" ".join(shlex.quote(x) for x in command))


def accept(args: argparse.Namespace) -> None:
    evidence = Path(args.before).resolve(); before, after = evidence / "before.json", evidence / "after.json"
    health = Path(args.health).resolve()
    if not before.is_file() or not after.is_file() or not health.is_file(): die("before/after/health evidence required")
    baseline = json.loads(before.read_text())
    a = json.loads(after.read_text()); h = json.loads(health.read_text())
    now = int(time.time())
    verifier = Path(args.verifier).resolve()
    if len(args.revision) != 40 or re.search(r"[^0-9a-f]", args.revision): die("revision must be a full lowercase SHA")
    if h.get("schema") != 1 or h.get("verifier_sha256") != sha_file(verifier): die("health evidence verifier binding mismatch")
    if h.get("status") != "HEALTHY" or h.get("deployed_revision") != args.revision: die("health evidence is not bound to revision")
    if h.get("bundle_manifest_sha256") != a["bundle_manifest_sha256"]: die("health evidence is not bound to bundle")
    if a.get("before_sha256") != sha_file(before): die("after evidence is not bound to current baseline")
    if a.get("schema") != 1 or a.get("kind") != "omp-in-place-after": die("after evidence schema mismatch")
    if a.get("pane") != baseline.get("pane") or a.get("terminal") != baseline.get("terminal"):
        die("after evidence pane binding mismatch")
    if a.get("binary_sha256") != baseline["expected_runtime"]["binary_sha256"] or a.get("native_sha256") != baseline["expected_runtime"]["native_sha256"]:
        die("after evidence runtime binding mismatch")
    if not health_postdates_after(a.get("checked_at_epoch"), h.get("checked_at_epoch"), now) \
       or health.stat().st_mtime_ns < after.stat().st_mtime_ns:
        die("health evidence is stale or predates after verification")
    current = process(args.pid)
    session = Path(baseline["session_file"])
    pane_now = pane_identity(baseline["pane"])
    expected_pane = {"pane": baseline["pane"], "terminal": baseline["terminal"], "cwd": baseline["repo"], "session_file": str(session)}
    current_argv = str(current["argv"])
    repo = Path(baseline["repo"])
    session_ok = session.stat().st_size > baseline["session_size"] and sha_file(session, baseline["session_size"]) == baseline["session_prefix_sha256"]
    repo_checks = {
        "head": git(repo, "rev-parse", "HEAD").decode().strip(),
        "status_sha256": sha_bytes(git(repo, "status", "--porcelain=v2", "--branch")),
        "submodules_sha256": sha_bytes(git(repo, "submodule", "status", "--recursive")),
        "tracked_diff_sha256": sha_bytes(git(repo, "diff", "--binary", "HEAD")),
        "untracked_sha256": aggregate_paths(repo, listed_paths(repo, False))[0],
        "ignored_sha256": aggregate_paths(repo, listed_paths(repo, True))[0],
    }
    repo_ok = all(baseline.get(key) == value for key, value in repo_checks.items())
    bundle = Path(args.bundle).resolve(); bundle_manifest(bundle)
    bundle_ok = sha_file(bundle / "manifest.json") == baseline["bundle_manifest_sha256"] == a["bundle_manifest_sha256"]
    control_ok = control_evidence(Path(args.control).resolve(), Path(args.hook).resolve()) == baseline["control"]
    if a["process"]["pid"] != args.pid or current["birth"] != a["process"]["birth"] \
       or current["cwd"] != baseline["repo"] or not argv_resumes_session(current_argv, session) \
       or sha_bytes(current_argv.encode()) != a["process"].get("argv_sha256") \
       or safe_resume_args(current_argv) != a["process"].get("resume_args") \
       or current["mapped_binary_sha256"] != baseline["expected_runtime"]["binary_sha256"] \
       or current["mapped_native_sha256"] != baseline["expected_runtime"]["native_sha256"] \
       or not required_env_present(baseline["process"]["environment_names"], current["environment_names"]) \
       or pane_now != expected_pane or not pid_is_pane_foreground_or_ancestor(args.pid, baseline["pane"]) \
       or not session_ok or not repo_ok or not bundle_ok or not control_ok:
        die("new process identity changed")
    record = {"schema": 1, "accepted_at_epoch": now, "pid": args.pid, "pid_birth": a["process"]["birth"],
              "pane": baseline["pane"], "terminal": baseline["terminal"], "before_sha256": sha_file(before),
              "after_sha256": sha_file(after), "health_sha256": sha_file(health),
              "bundle_manifest_sha256": a["bundle_manifest_sha256"], "deployed_revision": args.revision}
    atomic_json(evidence / f"ACCEPTED.{args.pid}.json", record)
    print(f"session-in-place: acceptance recorded for pid {args.pid}")


def common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--pid", type=int, required=True); p.add_argument("--pane", required=True); p.add_argument("--terminal", required=True)


def main() -> None:
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="command", required=True)
    c = sub.add_parser("capture"); common(c)
    for name in ("session_file", "repo", "out", "bundle", "control", "hook", "target_binary", "target_native"): c.add_argument("--" + name.replace("_", "-"), required=True)
    c.add_argument("--environment-reviewed", action="store_true", required=True)
    c.set_defaults(func=capture)
    v = sub.add_parser("verify-after"); common(v)
    for name in ("before", "bundle", "binary", "native", "control", "hook"): v.add_argument("--" + name, required=True)
    v.set_defaults(func=verify_after)
    r = sub.add_parser("resume-command"); r.add_argument("--before", required=True); r.add_argument("--launcher", required=True); r.add_argument("--launcher-sha256", required=True); r.set_defaults(func=resume_command)
    a = sub.add_parser("accept"); a.add_argument("--before", required=True); a.add_argument("--pid", type=int, required=True); a.add_argument("--health", required=True); a.add_argument("--revision", required=True); a.add_argument("--verifier", required=True)
    for name in ("bundle", "control", "hook"): a.add_argument("--" + name, required=True)
    a.set_defaults(func=accept)
    args = ap.parse_args(); args.func(args)


if __name__ == "__main__": main()
