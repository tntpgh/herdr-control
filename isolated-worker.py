#!/usr/bin/env python3
"""isolated-worker.py — run ONE finite omp task inside an OS-isolated Docker worker.

    python3 isolated-worker.py --repo PATH --ref COMMIT_OR_BRANCH --brief FILE \
        --model anthropic/<id>|openai-codex/<id> \
        --gateway-url http://host.docker.internal:4000 \
        --gateway-token-file ~/.omp/agent/auth-gateway.token \
        --timeout 1800 [--dry-run]

The caller is a trusted conductor. This script owns exactly the isolation
runtime: it exports a git ref into a task-owned staging directory, builds a
per-task Docker network that cannot reach the host, starts a model-only relay
sidecar (isolated-model-relay.py) and then the actual `omp -p` worker with
tools auto-approved — allowed ONLY because the container, not the approval
prompt, is the execution boundary. When the worker exits (or the deadline
kills it) the transcript, stderr, relay log, a patch of what changed in the
snapshot, and the worker's /herdr/out/RESULT.md are collected as UNTRUSTED
artifacts and summarised in result.json. Nothing is ever copied back into the
source repository; the conductor reviews and imports.

Exit codes: 0 completed (model finished + RESULT.md present; artifacts still
need review), 1 internal failure, 2 usage, 3 preflight failed (no fallback to
host execution, ever), 4 worker failed/timed out/model did not finish,
5 evidence missing, 130 interrupted (own resources cleaned up).

Trust boundaries, in one place:
  * Worker network: `--internal` bridge with gateway_mode_ipv4=isolated and
    IPv6 off. Docker `--internal` alone leaves a host-reachable gateway IP —
    the isolated gateway mode is what removes it. Only the worker and the
    relay are on it. The relay additionally joins a per-task egress bridge
    with net.ipv4.ip_forward=0 so it can never route for the worker.
  * Credentials: the gateway master bearer is read on the host and handed to
    the relay over stdin only. The worker receives one fresh per-task token
    (HERDR_WORKER_MODEL_TOKEN via --env-file, never argv) that the relay
    accepts for exactly one modelId on exactly one route.
  * Filesystem: the worker sees a fresh export of the ref (no .git, no
    untracked files, no .env*/keys/harness config), read-only operator rules,
    brief and models.yml, a tmpfs home, and one writable output directory.
    No host home, auth DB, sockets, Downloads, or checkout is mounted.
  * Process: unprivileged UID, cap-drop ALL, no-new-privileges, read-only
    root, private IPC/cgroupns, pids/cpu/memory/nofile limits, host-side hard
    deadline that kills only this task's containers.
  * Output: patches, RESULT.md and transcripts are data. Nothing the worker
    produced is executed on the host, and symlinks it creates are never
    followed. The image is pinned by ID at run time (`--pull never`).
"""
import argparse
import datetime as _dt
import difflib
import hashlib
import http.client
import io
import json
import os
import re
import secrets
import shutil
import signal
import ssl
import stat
import subprocess
import sys
import tarfile
import threading
import time
import urllib.parse

SCHEMA = "herdr-isolated-worker/1"
OMP_VERSION = "18.1.10"
DEFAULT_IMAGE = f"herdr-isolated-worker:{OMP_VERSION}"
IMAGE_LABEL = "dev.herdr.isolated-worker"
IMAGE_LABEL_VALUE = f"omp-{OMP_VERSION}"
RELAY_ALIAS = "model-relay"
RELAY_PORT = 8402
MODEL_RE = re.compile(r"^(anthropic|openai-codex)/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0", "[::1]"}
HOST_GATEWAY_NAME = "host.docker.internal"
DEFAULT_TOOLS = "read,bash,edit,write,grep,glob,todo"
HERE = os.path.dirname(os.path.abspath(__file__))
RELAY_SCRIPT = os.path.join(HERE, "isolated-model-relay.py")

EXIT_OK, EXIT_FAILURE, EXIT_USAGE, EXIT_PREFLIGHT, EXIT_WORKER, EXIT_EVIDENCE, EXIT_INTERRUPTED = 0, 1, 2, 3, 4, 5, 130

# --- snapshot policy ---------------------------------------------------------
# Directories that are harness configuration / execution surfaces rather than
# project code: agent settings, extensions, hooks, MCP definitions, git hooks.
EXCLUDED_DIRS = frozenset(
    {".git", ".omp", ".claude", ".codex", ".omc", ".omx", ".cursor", ".gemini", ".aider", ".githooks", ".husky"}
)
# Credential-shaped file names. Snapshot omission is a filter, not a proof: the
# manifest lists what was included and the conductor is expected to have
# reviewed the source scope before dispatch.
EXCLUDED_FILE_NAMES = frozenset(
    {
        ".netrc", ".npmrc", ".pypirc", ".git-credentials",
        "credentials.json", "service-account.json", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    }
)
# MCP server definitions spawn commands when a harness loads them.
HARNESS_FILE_NAMES = frozenset({".mcp.json", "mcp.json"})
EXCLUDED_FILE_SUFFIXES = (".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx", ".ppk", ".asc", ".gpg")
PRIVATE_KEY_MARK = b"PRIVATE KEY-----"
SNIFF_BYTES = 4096

# --- change export policy ----------------------------------------------------
TEXT_DIFF_CAP = 4 * 1024 * 1024        # per file; larger files are exported whole, not diffed
EXPORT_TOTAL_CAP = 512 * 1024 * 1024   # copies of changed files beyond this are listed only
RESULT_MD_CAP = 1024 * 1024
LOG_CAP = 256 * 1024 * 1024


class Fail(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def now_iso():
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_bytes_capped(path, cap):
    with open(path, "rb") as f:
        data = f.read(cap + 1)
    return data[:cap], len(data) > cap


# --- argument parsing ----------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(prog="isolated-worker.py", description=__doc__.split("\n\n")[0])
    p.add_argument("--repo", required=True, help="git repository (or worktree) to export from")
    p.add_argument("--ref", required=True, help="commit or branch to export (resolved with rev-parse)")
    p.add_argument("--brief", required=True, help="task brief file, mounted read-only into the worker")
    p.add_argument("--model", required=True, help="provider-qualified model: anthropic/<id> or openai-codex/<id>")
    p.add_argument("--gateway-url", required=True, help="omp auth-gateway base URL as seen FROM THE RELAY CONTAINER, no /v1 (e.g. http://host.docker.internal:4000)")
    p.add_argument("--gateway-token-file", required=True, help="file holding the gateway master bearer; read on the host, given only to the relay")
    p.add_argument("--timeout", type=int, required=True, help="hard deadline in seconds for the worker (60..14400)")
    p.add_argument("--dry-run", action="store_true", help="print the concrete plan; create no Docker resources")
    p.add_argument("--image", default=DEFAULT_IMAGE, help=f"local image tag to run (default {DEFAULT_IMAGE}); never pulled")
    p.add_argument("--image-id", default=None, help="require this exact image ID (sha256:...) for --image")
    p.add_argument("--operator-rules", default=None, help="operator AGENTS.md to append (default: first AGENTS.md in an ancestor of the repo's main root)")
    p.add_argument("--no-operator-rules", action="store_true", help="explicitly run without an operator rules file")
    p.add_argument("--work-root", default=os.environ.get("HERDR_ISOLATED_ROOT", os.path.expanduser("~/.herdr/isolated-worker")), help="parent directory for per-task state")
    p.add_argument("--task-id", default=None, help="override the generated task id (used in resource names)")
    p.add_argument("--gateway-probe-url", default=None, help="URL to probe the gateway from the HOST during preflight (default: --gateway-url with host.docker.internal mapped to 127.0.0.1)")
    p.add_argument("--worker-tools", default=DEFAULT_TOOLS, help=f"omp --tools list for the worker (default {DEFAULT_TOOLS})")
    p.add_argument("--thinking", default=None, help="omp --thinking level for the worker (optional)")
    p.add_argument("--container-uid", type=int, default=os.getuid(), help="UID the worker/relay run as (default: host uid, so bind mounts stay writable)")
    p.add_argument("--container-gid", type=int, default=os.getgid(), help="GID the worker/relay run as (default: host gid)")
    p.add_argument("--cpus", default="2", help="worker CPU limit (docker --cpus)")
    p.add_argument("--memory", default="4g", help="worker memory limit (docker --memory; swap pinned equal)")
    p.add_argument("--pids-limit", type=int, default=512)
    p.add_argument("--tmp-size", default="1g", help="worker /tmp tmpfs size")
    p.add_argument("--home-size", default="512m", help="worker /home/worker tmpfs size")
    p.add_argument("--max-requests", type=int, default=400, help="relay: max model requests for the task")
    p.add_argument("--max-concurrent", type=int, default=4, help="relay: max in-flight model requests")
    p.add_argument("--max-body-mb", type=int, default=24, help="relay: max request body in MiB")
    p.add_argument("--request-deadline", type=int, default=900, help="relay: per-request wall clock seconds")
    p.add_argument("--max-file-mb", type=int, default=64, help="snapshot: refuse tracked files larger than this")
    p.add_argument("--max-snapshot-gb", type=float, default=2.0, help="snapshot: refuse exports larger than this")
    p.add_argument("--no-workspace-git", action="store_true", help="do not git-init a baseline commit inside the worker's /workspace")
    a = p.parse_args(argv)
    if not MODEL_RE.match(a.model):
        p.error("--model must be provider-qualified: anthropic/<id> or openai-codex/<id>")
    if not (60 <= a.timeout <= 14400):
        p.error("--timeout must be between 60 and 14400 seconds")
    for name in ("max_requests", "max_concurrent", "max_body_mb", "request_deadline", "pids_limit", "max_file_mb"):
        if getattr(a, name) <= 0:
            p.error(f"--{name.replace('_', '-')} must be positive")
    if a.max_snapshot_gb <= 0:
        p.error("--max-snapshot-gb must be positive")
    if a.container_uid == 0 or a.container_gid == 0:
        p.error("refusing to run the worker as root")
    if a.task_id is not None and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,40}", a.task_id):
        p.error("--task-id must be [A-Za-z0-9_.-], max 41 chars")
    tools = [t for t in a.worker_tools.split(",") if t]
    if not tools or any(not re.fullmatch(r"[a-z_]+", t) for t in tools):
        p.error("--worker-tools must be a comma-separated list of omp tool names")
    a.worker_tools = ",".join(tools)
    return a


# --- validation helpers --------------------------------------------------------

def validate_gateway_url(url):
    """Return normalised base URL (no trailing slash) or raise Fail. Loopback is
    rejected because the relay dials it from inside a container."""
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https"):
        raise Fail(EXIT_USAGE, f"--gateway-url must be http(s), got {url!r}")
    if not u.hostname or u.query or u.fragment or u.username or u.password:
        raise Fail(EXIT_USAGE, "--gateway-url must be scheme://host[:port][/prefix] with no credentials/query/fragment")
    if u.hostname.lower() in LOOPBACK_HOSTS or u.hostname.startswith("127."):
        raise Fail(EXIT_USAGE, f"--gateway-url host {u.hostname!r} is loopback, unreachable from the relay container; use {HOST_GATEWAY_NAME}")
    path = u.path.rstrip("/")
    if path.endswith("/v1"):
        raise Fail(EXIT_USAGE, "--gateway-url must not end in /v1 (the native client appends /v1/pi/stream)")
    return urllib.parse.urlunsplit((u.scheme, u.netloc, path, "", ""))


def probe_url_for(gateway_url, override):
    if override:
        return override.rstrip("/")
    u = urllib.parse.urlsplit(gateway_url)
    if u.hostname == HOST_GATEWAY_NAME:
        netloc = "127.0.0.1" + (f":{u.port}" if u.port else "")
        return urllib.parse.urlunsplit((u.scheme, netloc, u.path, "", ""))
    return gateway_url


def http_get(url, bearer=None, timeout=8.0):
    """Single GET without redirect following. Returns (status, body_bytes)."""
    u = urllib.parse.urlsplit(url)
    port = u.port or (443 if u.scheme == "https" else 80)
    if u.scheme == "https":
        conn = http.client.HTTPSConnection(u.hostname, port, timeout=timeout, context=ssl.create_default_context())
    else:
        conn = http.client.HTTPConnection(u.hostname, port, timeout=timeout)
    headers = {"Accept": "application/json"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    try:
        conn.request("GET", u.path or "/", headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.read(1 << 20)
    finally:
        conn.close()


def read_token_file(path, log):
    try:
        st = os.stat(path)
    except OSError as e:
        raise Fail(EXIT_PREFLIGHT, f"gateway token file unreadable: {e}")
    if st.st_mode & 0o077:
        log(f"warning: {path} is group/world accessible (mode {stat.filemode(st.st_mode)})")
    with open(path, "r", encoding="utf-8") as f:
        token = f.read().strip()
    if not token or "\n" in token or len(token) < 16:
        raise Fail(EXIT_PREFLIGHT, "gateway token file is empty or malformed")
    return token


def git(repo, *args, timeout=120):
    try:
        return subprocess.run(
            ["git", "-C", repo, *args], check=True, capture_output=True, text=True, timeout=timeout,
            env=neutral_git_env(),
        ).stdout
    except subprocess.CalledProcessError as e:
        raise Fail(EXIT_PREFLIGHT, f"git {' '.join(args)} failed: {e.stderr.strip()}")
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Fail(EXIT_PREFLIGHT, f"git {' '.join(args)} failed: {e}")


def neutral_git_env():
    # The conductor's own repo is trusted, but keep git's behaviour boring:
    # no pager, no prompts, no terminal.
    env = dict(os.environ)
    env.update({"GIT_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"})
    return env


def main_repo_root(repo):
    """Canonical project root, worktree-aware (mirrors lib/repo-root.sh)."""
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    if os.path.basename(common) == ".git":
        return os.path.dirname(common)
    return common


def derive_operator_rules(main_root, home=None):
    """First AGENTS.md found walking UP from the main repo root's parent, stopping
    at the home directory (inclusive). Returns the path or None."""
    home = os.path.abspath(home or os.path.expanduser("~"))
    cur = os.path.dirname(os.path.abspath(main_root))
    while True:
        candidate = os.path.join(cur, "AGENTS.md")
        if os.path.isfile(candidate):
            return candidate
        if cur == home or os.path.dirname(cur) == cur:
            return None
        cur = os.path.dirname(cur)


# --- snapshot export -------------------------------------------------------------

def _excluded_reason(name):
    parts = name.split("/")
    for part in parts[:-1]:
        if part in EXCLUDED_DIRS:
            return f"harness-dir:{part}"
    base = parts[-1]
    if base in EXCLUDED_DIRS:
        return f"harness-dir:{base}"
    if base in HARNESS_FILE_NAMES:
        return "harness-file"
    if base.startswith(".env"):
        return "env-file"
    if base in EXCLUDED_FILE_NAMES or base.startswith("id_rsa") or base.startswith("id_ed25519"):
        return "credential-file"
    lower = base.lower()
    if lower.endswith(EXCLUDED_FILE_SUFFIXES):
        return "private-key-suffix"
    return None


def _safe_member_path(name):
    """Return a normalised relative path or None when the member could escape."""
    if not name or "\x00" in name or name.startswith("/") or name.startswith("\\"):
        return None
    norm = os.path.normpath(name)
    if norm in (".", "") or norm.startswith("../") or norm == ".." or os.path.isabs(norm):
        return None
    if any(p in ("", ".", "..") for p in norm.split("/")):
        return None
    return norm


def extract_tar(stream, dest, manifest, max_file_bytes, max_total_bytes):
    """Extract regular files/dirs from a tar stream into dest with our own
    filter; never tarfile.extractall. Symlinks, hard links, devices and
    escaping paths are skipped and recorded."""
    total = 0
    with tarfile.open(fileobj=stream, mode="r|") as tf:
        for m in tf:
            rel = _safe_member_path(m.name)
            if rel is None:
                manifest["excluded"].append({"path": m.name, "reason": "unsafe-path"})
                continue
            reason = _excluded_reason(rel)
            if reason:
                if not m.isdir():
                    manifest["excluded"].append({"path": rel, "reason": reason})
                continue
            target = os.path.join(dest, rel)
            if m.isdir():
                os.makedirs(target, mode=0o755, exist_ok=True)
                continue
            if m.issym() or m.islnk():
                manifest["excluded"].append({"path": rel, "reason": "symlink" if m.issym() else "hardlink"})
                continue
            if not m.isreg():
                manifest["excluded"].append({"path": rel, "reason": "special-file"})
                continue
            if m.size > max_file_bytes:
                raise Fail(EXIT_PREFLIGHT, f"tracked file {rel} is {m.size} bytes, over the --max-file-mb cap")
            total += m.size
            if total > max_total_bytes:
                raise Fail(EXIT_PREFLIGHT, "snapshot exceeds --max-snapshot-gb")
            src = tf.extractfile(m)
            if src is None:
                manifest["excluded"].append({"path": rel, "reason": "unreadable"})
                continue
            head = src.read(SNIFF_BYTES)
            if PRIVATE_KEY_MARK in head:
                manifest["excluded"].append({"path": rel, "reason": "private-key-content"})
                continue
            os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
            mode = 0o755 if (m.mode & 0o111) else 0o644
            h = hashlib.sha256()
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
            with os.fdopen(fd, "wb") as out:
                out.write(head)
                h.update(head)
                for block in iter(lambda: src.read(1 << 20), b""):
                    out.write(block)
                    h.update(block)
            manifest["files"].append({"path": rel, "size": m.size, "mode": oct(mode), "sha256": h.hexdigest()})
    manifest["total_bytes"] = total
    return manifest


def export_snapshot(repo, commit, dest, max_file_bytes, max_total_bytes):
    manifest = {"schema": SCHEMA + "/manifest", "commit": commit, "files": [], "excluded": [], "submodules": []}
    listing = git(repo, "ls-tree", "-r", "-z", commit)
    for entry in listing.split("\0"):
        if entry.startswith("160000 "):
            manifest["submodules"].append(entry.split("\t", 1)[1])
    proc = subprocess.Popen(
        ["git", "-C", repo, "archive", "--format=tar", commit],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=neutral_git_env(),
    )
    try:
        extract_tar(proc.stdout, dest, manifest, max_file_bytes, max_total_bytes)
    finally:
        proc.stdout.close()
        err = proc.stderr.read().decode(errors="replace")
        rc = proc.wait(timeout=60)
    if rc != 0:
        raise Fail(EXIT_PREFLIGHT, f"git archive failed ({rc}): {err.strip()}")
    manifest["file_count"] = len(manifest["files"])
    manifest["excluded_count"] = len(manifest["excluded"])
    return manifest


# --- change collection ---------------------------------------------------------------

def _is_text(data):
    return b"\0" not in data[:8192]


def _unified(old, new, path, kind):
    old_lines = old.decode("utf-8", "surrogateescape").splitlines(keepends=True)
    new_lines = new.decode("utf-8", "surrogateescape").splitlines(keepends=True)
    fromfile = "/dev/null" if kind == "added" else "a/" + path
    tofile = "/dev/null" if kind == "deleted" else "b/" + path
    out = []
    for line in difflib.unified_diff(old_lines, new_lines, fromfile=fromfile, tofile=tofile, n=3):
        if not line.endswith("\n"):
            line += "\n\\ No newline at end of file\n"
        out.append(line)
    return "".join(out).encode("utf-8", "surrogateescape")


def _walk_tree(root, skip_top=()):
    """{relpath: lstat} for every non-directory entry plus symlinked directories.
    Symlinks are recorded, never followed or descended."""
    found = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
            dirnames[:] = [d for d in dirnames if d not in skip_top]
        keep = []
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                found[os.path.join(rel_dir, d)] = os.lstat(full)
            else:
                keep.append(d)
        dirnames[:] = keep
        for name in filenames:
            found[os.path.join(rel_dir, name)] = os.lstat(os.path.join(dirpath, name))
    return found


def collect_changes(baseline, staging, export_dir, patch_path, changes_path):
    """Diff baseline vs staging without executing anything from staging.
    Writes a git-apply-compatible patch for text changes, copies changed
    regular files under export_dir, and writes changes.json."""
    before = _walk_tree(baseline)
    after = _walk_tree(staging, skip_top=(".git",))
    added, modified, deleted, symlinks, binaries, skipped = [], [], [], [], [], []
    exported_bytes = 0
    os.makedirs(export_dir, exist_ok=True)
    with open(patch_path, "wb") as patch:
        for rel in sorted(set(before) | set(after)):
            b_st = before.get(rel)
            a_st = after.get(rel)
            if a_st is not None and stat.S_ISLNK(a_st.st_mode):
                symlinks.append({"path": rel, "target": os.readlink(os.path.join(staging, rel))})
                continue
            if a_st is not None and not stat.S_ISREG(a_st.st_mode):
                skipped.append({"path": rel, "reason": "special-file"})
                continue
            if b_st is None:
                kind = "added"
            elif a_st is None:
                kind = "deleted"
            else:
                if a_st.st_size == b_st.st_size and sha256_file(os.path.join(staging, rel)) == sha256_file(os.path.join(baseline, rel)):
                    if (a_st.st_mode & 0o111) != (b_st.st_mode & 0o111):
                        modified.append({"path": rel, "mode_only": True})
                    continue
                kind = "modified"
            old = b"" if b_st is None else open(os.path.join(baseline, rel), "rb").read()
            new = b"" if a_st is None else open(os.path.join(staging, rel), "rb").read()
            entry = {"path": rel, "size": len(new)}
            {"added": added, "deleted": deleted, "modified": modified}[kind].append(entry)
            text = _is_text(old) and _is_text(new) and max(len(old), len(new)) <= TEXT_DIFF_CAP
            patch.write(f"diff --git a/{rel} b/{rel}\n".encode("utf-8", "surrogateescape"))
            if kind == "added":
                patch.write(b"new file mode 100644\n")
            elif kind == "deleted":
                patch.write(b"deleted file mode 100644\n")
            if text:
                patch.write(_unified(old, new, rel, kind))
            else:
                patch.write(f"Binary files differ ({len(old)} -> {len(new)} bytes)\n".encode())
                binaries.append(rel)
            if kind != "deleted":
                if exported_bytes + len(new) <= EXPORT_TOTAL_CAP:
                    dest = os.path.join(export_dir, rel)
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    with open(dest, "wb") as f:
                        f.write(new)
                    exported_bytes += len(new)
                else:
                    entry["export_skipped"] = "total-cap"
    summary = {
        "added": added, "modified": modified, "deleted": deleted, "symlinks_created": symlinks,
        "binary": binaries, "skipped": skipped, "exported_bytes": exported_bytes,
        "counts": {"added": len(added), "modified": len(modified), "deleted": len(deleted), "symlinks": len(symlinks)},
    }
    with open(changes_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    return summary


# --- transcript ---------------------------------------------------------------------

def analyse_transcript(path):
    """Parse the `--mode json` event stream. In JSON mode omp exits 0 even when
    the last assistant turn errored (print-mode.ts only hard-exits in text
    mode), so model completion is read from the events, not the exit code."""
    info = {"events": 0, "event_counts": {}, "agent_end": False, "last_stop_reason": None,
            "error_message": None, "final_text_excerpt": None, "unparsed_lines": 0}
    if not os.path.exists(path):
        return info
    with open(path, "rb") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except ValueError:
                info["unparsed_lines"] += 1
                continue
            if not isinstance(ev, dict):
                continue
            t = ev.get("type")
            if not isinstance(t, str):
                continue
            info["events"] += 1
            info["event_counts"][t] = info["event_counts"].get(t, 0) + 1
            if t == "agent_end":
                info["agent_end"] = True
            if t == "message_end":
                msg = ev.get("message") or {}
                if msg.get("role") == "assistant":
                    info["last_stop_reason"] = msg.get("stopReason")
                    info["error_message"] = msg.get("errorMessage")
                    text = "".join(c.get("text", "") for c in msg.get("content", []) if isinstance(c, dict) and c.get("type") == "text")
                    info["final_text_excerpt"] = text[:4000] if text else None
    info["model_completed"] = bool(info["agent_end"] and info["last_stop_reason"] == "stop")
    return info


# --- runtime ---------------------------------------------------------------------------

class Runtime:
    """Owns every Docker resource for one task so cleanup is exact."""

    def __init__(self, task_id, task_dir, log):
        self.task_id = task_id
        self.task_dir = task_dir
        self.log = log
        self.prefix = f"herdr-iw-{task_id}"
        self.net_task = f"{self.prefix}-net-task"
        self.net_egress = f"{self.prefix}-net-egress"
        self.relay_name = f"{self.prefix}-relay"
        self.worker_name = f"{self.prefix}-worker"
        self.created = []           # ("network"|"container", name) in creation order
        self.relay_proc = None
        self.relay_out = None
        self.worker_proc = None
        self.interrupted = False
        self.docker_log = open(os.path.join(task_dir, "logs", "docker.log"), "a", encoding="utf-8")

    def docker(self, *args, check=True, timeout=120):
        argv = ["docker", *args]
        self.docker_log.write(f"{now_iso()} $ {' '.join(argv)}\n")
        self.docker_log.flush()
        try:
            r = subprocess.run(argv, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as e:
            self.docker_log.write(f"  !! {e}\n")
            raise Fail(EXIT_FAILURE, f"docker {args[0]} failed: {e}")
        out = r.stdout.decode(errors="replace")
        err = r.stderr.decode(errors="replace")
        if err.strip():
            self.docker_log.write("  stderr: " + err.strip().replace("\n", "\n          ") + "\n")
        self.docker_log.write(f"  exit {r.returncode}\n")
        self.docker_log.flush()
        if check and r.returncode != 0:
            raise Fail(EXIT_FAILURE, f"docker {' '.join(args[:2])} failed ({r.returncode}): {err.strip()[:800]}")
        return r.returncode, out, err

    # -- resources --
    def create_networks(self):
        self.docker(
            "network", "create", "--driver", "bridge", "--internal", "--ipv6=false",
            "--opt", "com.docker.network.bridge.gateway_mode_ipv4=isolated",
            "--label", f"{IMAGE_LABEL}.task={self.task_id}", self.net_task,
        )
        self.created.append(("network", self.net_task))
        self.docker(
            "network", "create", "--driver", "bridge", "--ipv6=false",
            "--label", f"{IMAGE_LABEL}.task={self.task_id}", self.net_egress,
        )
        self.created.append(("network", self.net_egress))

    def start_relay(self, argv, config, log_path):
        self.docker(*argv)
        self.created.append(("container", self.relay_name))
        self.docker("network", "connect", self.net_egress, self.relay_name)
        self.relay_out = open(log_path, "ab", buffering=0)
        self.relay_proc = subprocess.Popen(
            ["docker", "start", "--attach", "--interactive", self.relay_name],
            stdin=subprocess.PIPE, stdout=self.relay_out, stderr=self.relay_out,
        )
        self.docker_log.write(f"{now_iso()} $ docker start --attach --interactive {self.relay_name}  (config via stdin, redacted)\n")
        self.docker_log.flush()
        try:
            self.relay_proc.stdin.write((json.dumps(config, separators=(",", ":")) + "\n").encode())
            self.relay_proc.stdin.flush()
            self.relay_proc.stdin.close()
        except OSError as e:
            raise Fail(EXIT_FAILURE, f"could not hand config to relay: {e}")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.relay_proc.poll() is not None:
                tail = read_bytes_capped(log_path, 4000)[0].decode(errors="replace")
                raise Fail(EXIT_FAILURE, f"relay exited early ({self.relay_proc.returncode}):\n{tail}")
            with open(log_path, "rb") as f:
                if b"relay ready port=" in f.read(65536):
                    return
            time.sleep(0.2)
        raise Fail(EXIT_FAILURE, "relay did not report ready within 30s")

    def run_worker(self, argv, stdout_path, stderr_path, deadline_s):
        self.docker(*argv)
        self.created.append(("container", self.worker_name))
        self.docker_log.write(f"{now_iso()} $ docker start --attach {self.worker_name}\n")
        self.docker_log.flush()
        self.worker_proc = subprocess.Popen(
            ["docker", "start", "--attach", self.worker_name],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        pumps = [
            threading.Thread(target=_pump, args=(self.worker_proc.stdout, stdout_path, LOG_CAP), daemon=True),
            threading.Thread(target=_pump, args=(self.worker_proc.stderr, stderr_path, LOG_CAP), daemon=True),
        ]
        for t in pumps:
            t.start()
        started = time.monotonic()
        killed = False
        while True:
            remaining = deadline_s - (time.monotonic() - started)
            if self.interrupted:
                self.log("interrupted: killing worker container")
                self.docker("kill", self.worker_name, check=False, timeout=30)
                killed = True
                break
            if remaining <= 0:
                self.log(f"deadline {deadline_s}s reached: killing worker container")
                self.docker("kill", self.worker_name, check=False, timeout=30)
                killed = True
                break
            try:
                self.worker_proc.wait(timeout=min(remaining, 1.0))
                break
            except subprocess.TimeoutExpired:
                continue
        try:
            self.worker_proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.worker_proc.kill()
        for t in pumps:
            t.join(timeout=10)
        _, out, _ = self.docker(
            "inspect", "-f", "{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}} {{.State.FinishedAt}}",
            self.worker_name, check=False,
        )
        parts = out.split()
        status = parts[0] if parts else "unknown"
        state = {
            "container_status": status,
            "docker_start_rc": self.worker_proc.returncode,
            "exit_code": int(parts[1]) if len(parts) > 1 and parts[1].lstrip("-").isdigit() else None,
            "oom_killed": (parts[2] == "true") if len(parts) > 2 else None,
            "finished_at": parts[3] if len(parts) > 3 else None,
            "killed_by_deadline": killed and not self.interrupted,
            "interrupted": self.interrupted,
            "wall_s": round(time.monotonic() - started, 1),
        }
        if status == "created":
            # `docker start` itself failed (mount/platform/runtime error); the
            # container never ran, so its exit code is meaningless.
            tail = read_bytes_capped(stderr_path, 2000)[0].decode(errors="replace")
            raise Fail(EXIT_FAILURE, f"worker container never started (docker start rc={self.worker_proc.returncode}): {tail.strip()[:800]}")
        return state

    def stop_relay(self, log_path):
        if self.relay_proc is None:
            return None
        self.docker("stop", "-t", "5", self.relay_name, check=False, timeout=40)
        try:
            self.relay_proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.relay_proc.kill()
        summary = None
        try:
            with open(log_path, "rb") as f:
                for raw in f:
                    if raw.startswith(b'{"event":"relay_summary"'):
                        summary = json.loads(raw)
        except (OSError, ValueError):
            pass
        return summary

    def cleanup(self):
        """Remove only what this task created, in reverse order; never raises."""
        report = {"removed": [], "failed": [], "remaining": []}

        def safe(*args, timeout):
            try:
                return self.docker(*args, check=False, timeout=timeout)
            except Fail as e:
                return 1, "", str(e)

        for kind, name in reversed(self.created):
            if kind == "container":
                rc, _, err = safe("rm", "-f", name, timeout=60)
            else:
                rc, _, err = safe("network", "rm", name, timeout=60)
            (report["removed"] if rc == 0 else report["failed"]).append(name)
            if rc != 0:
                self.log(f"cleanup: could not remove {kind} {name}: {err.strip()[:200]}")
        for proc in (self.relay_proc, self.worker_proc):
            if proc is not None and proc.poll() is None:
                proc.kill()
        if self.relay_out is not None:
            self.relay_out.close()
        for kind, name in self.created:
            rc, _, _ = safe("network" if kind == "network" else "container", "inspect", name, timeout=30)
            if rc == 0:
                report["remaining"].append(name)
        report["ok"] = not report["remaining"]
        self.docker_log.close()
        return report


def _pump(pipe, path, cap):
    written = 0
    truncated = False
    with open(path, "ab", buffering=0) as out:
        while True:
            block = pipe.read(65536)
            if not block:
                break
            if written < cap:
                out.write(block[: cap - written])
                written += len(block)
            elif not truncated:
                out.write(b"\n[herdr: output truncated at cap]\n")
                truncated = True


# --- plan construction -----------------------------------------------------------------

def build_plan(a, task_id, task_dir, commit, main_root, operator_rules, image_id):
    uid, gid = a.container_uid, a.container_gid
    d = lambda *p: os.path.join(task_dir, *p)  # noqa: E731
    prefix = f"herdr-iw-{task_id}"
    max_time = max(60, a.timeout - 60)
    omp_args = [
        "-p", "--mode", "json", "--model", a.model, "--approval-mode", "yolo",
        "--no-extensions", "--no-skills", "--no-lsp", "--no-session", "--no-title",
        "--tools", a.worker_tools, "--max-time", str(max_time), "--cwd", "/workspace",
        "--append-system-prompt", "/herdr/operator/worker-rules.md",
    ]
    if a.thinking:
        omp_args += ["--thinking", a.thinking]
    omp_args += [
        "Complete the task brief that follows. Work only inside /workspace; when finished write /herdr/out/RESULT.md.",
        "@/herdr/brief/brief.md",
    ]
    common = [
        "--platform", "linux/arm64", "--pull", "never", "--user", f"{uid}:{gid}",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges=true", "--read-only",
        "--ipc", "private", "--cgroupns", "private",
        "--mount", f"type=bind,src={d('config', 'passwd')},dst=/etc/passwd,readonly",
        "--mount", f"type=bind,src={d('config', 'group')},dst=/etc/group,readonly",
        "--label", f"{IMAGE_LABEL}.task={task_id}",
    ]
    worker_create = [
        "create", "--name", f"{prefix}-worker", "--init", "--network", f"{prefix}-net-task",
        *common,
        "--pids-limit", str(a.pids_limit), "--cpus", a.cpus, "--memory", a.memory, "--memory-swap", a.memory,
        "--ulimit", "nofile=4096:4096",
        "--tmpfs", f"/tmp:rw,nosuid,nodev,size={a.tmp_size},mode=1777",
        "--tmpfs", f"/home/worker:rw,nosuid,nodev,size={a.home_size},uid={uid},gid={gid},mode=0700",
        "--env-file", d("secrets", "worker.env"),
        "--env", "HOME=/home/worker", "--env", "OMP_SKIP_SETUP=1", "--env", "TERM=dumb", "--env", "LANG=C.UTF-8",
        "--env", "HERDR_ISOLATED_WORKER=1", "--env", f"HERDR_TASK_ID={task_id}", "--env", f"HERDR_SOURCE_COMMIT={commit}",
        "--env", f"HERDR_WORKER_GIT_INIT={'0' if a.no_workspace_git else '1'}",
        "--workdir", "/workspace",
        "--mount", f"type=bind,src={d('staging')},dst=/workspace",
        "--mount", f"type=bind,src={d('out')},dst=/herdr/out",
        "--mount", f"type=bind,src={d('brief')},dst=/herdr/brief,readonly",
        "--mount", f"type=bind,src={d('operator')},dst=/herdr/operator,readonly",
        "--mount", f"type=bind,src={d('config', 'omp')},dst=/herdr/config,readonly",
        image_id, *omp_args,
    ]
    relay_create = [
        "create", "--name", f"{prefix}-relay", "--interactive", "--network", f"{prefix}-net-task",
        "--network-alias", RELAY_ALIAS, *common,
        "--pids-limit", "64", "--cpus", "0.5", "--memory", "256m", "--memory-swap", "256m",
        "--sysctl", "net.ipv4.ip_forward=0",
        "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777",
        "--env", "HOME=/tmp", "--env", "PYTHONDONTWRITEBYTECODE=1", "--env", "PYTHONUNBUFFERED=1",
        "--mount", f"type=bind,src={RELAY_SCRIPT},dst=/herdr/relay/relay.py,readonly",
        "--entrypoint", "/usr/bin/python3", image_id, "/herdr/relay/relay.py",
    ]
    relay_policy = {
        "listen_port": RELAY_PORT,
        "model_id": a.model,
        "max_body_bytes": a.max_body_mb * 1024 * 1024,
        "max_concurrent": a.max_concurrent,
        "max_requests": a.max_requests,
        "request_deadline_s": a.request_deadline,
        "idle_timeout_s": 180,
        "lifetime_s": a.timeout + 120,
        "attribution_id": f"herdr-iw-{task_id}",
        "upstream_url": a.gateway_url,
        "allowed_route": "POST /v1/pi/stream",
    }
    return {
        "schema": SCHEMA + "/plan",
        "task_id": task_id,
        "task_dir": task_dir,
        "image": {"ref": a.image, "id": image_id, "label": f"{IMAGE_LABEL}={IMAGE_LABEL_VALUE}"},
        "source": {"repo": os.path.abspath(a.repo), "main_root": main_root, "ref": a.ref, "commit": commit,
                   "operator_rules": operator_rules, "brief": os.path.abspath(a.brief)},
        "networks": {
            "task": {"name": f"{prefix}-net-task", "flags": "--internal --ipv6=false --opt com.docker.network.bridge.gateway_mode_ipv4=isolated", "members": ["worker", "relay"]},
            "egress": {"name": f"{prefix}-net-egress", "flags": "--ipv6=false", "members": ["relay"]},
        },
        "worker": {"container": f"{prefix}-worker", "docker_create": worker_create, "model": a.model, "tools": a.worker_tools,
                   "max_time_s": max_time, "hard_deadline_s": a.timeout, "uid": uid, "gid": gid,
                   "env_names": ["HERDR_WORKER_MODEL_TOKEN (from --env-file, value redacted)", "HOME", "OMP_SKIP_SETUP", "TERM", "LANG", "HERDR_ISOLATED_WORKER", "HERDR_TASK_ID", "HERDR_SOURCE_COMMIT", "HERDR_WORKER_GIT_INIT"]},
        "relay": {"container": f"{prefix}-relay", "alias": RELAY_ALIAS, "docker_create": relay_create,
                  "policy": relay_policy, "secrets": "task token + gateway master bearer handed over stdin only"},
        "models_yml": models_yml(),
    }


def models_yml():
    base = f"http://{RELAY_ALIAS}:{RELAY_PORT}"
    return (
        "# generated by isolated-worker.py — worker-only model routing\n"
        "providers:\n"
        f"  anthropic:\n    baseUrl: {base}\n    apiKey: HERDR_WORKER_MODEL_TOKEN\n    transport: pi-native\n"
        f"  openai-codex:\n    baseUrl: {base}\n    apiKey: HERDR_WORKER_MODEL_TOKEN\n    transport: pi-native\n"
    )


def worker_rules_text(repo, commit, model, operator_rules_path, operator_text, git_baseline):
    git_note = (
        "- /workspace is a git repository whose single commit on `main` is the baseline snapshot; use `git status`/`git diff` to review your own changes. There is no remote and nothing you commit leaves the container."
        if git_baseline else
        "- /workspace has no .git; git commands will not work on it. Keep track of your edits yourself."
    )
    lines = [
        "# herdr isolated worker — task restrictions (generated, authoritative)",
        "",
        f"- You are omp {OMP_VERSION} running in an isolated container for one finite task. Model: `{model}`.",
        f"- /workspace is an export of `{repo}` at commit `{commit}` with untracked files, .git, .env*, key files and agent/harness config deliberately omitted.",
        git_note,
        "- Writable: /workspace and /herdr/out. Everything else is read-only; /tmp and $HOME are small tmpfs scratch.",
        "- There is NO network except the model relay. Package installs, web fetches, host services, Docker, ssh and DNS for external names all fail by design — do not retry them or work around it.",
        "- No credentials exist here. Do not search for them.",
        "- Tools are auto-approved because the container is the boundary; that is not permission to do anything destructive to the snapshot beyond the task.",
        "- Nothing you do is merged, deployed or committed anywhere real. Your changes in /workspace are exported as a patch for a human to review and import. You have no merge, deploy, or external-communication authority.",
        "- FINAL DELIVERABLE (required): write /herdr/out/RESULT.md before you finish. Include: what you changed (files), what you verified and the exact output that proves it, what is incomplete or blocked, and anything the reviewer must decide. The run counts as FAILED without this file.",
        "- Verify with real commands inside the container where possible (tests, builds, scripts that need no network). Never claim a check you did not run.",
        "",
    ]
    if operator_text is not None:
        lines += [f"# Operator rules (canonical source: {operator_rules_path})", "", operator_text.rstrip(), ""]
    else:
        lines += ["# Operator rules", "", "(none supplied for this task)", ""]
    return "\n".join(lines)


def passwd_files(uid, gid):
    passwd = f"root:x:0:0:root:/root:/usr/sbin/nologin\nworker:x:{uid}:{gid}:herdr worker:/home/worker:/bin/bash\n"
    group = f"root:x:0:\nworker:x:{gid}:\n"
    return passwd, group


def make_task_dir(work_root, task_id):
    os.makedirs(work_root, mode=0o700, exist_ok=True)
    os.chmod(work_root, 0o700)
    task_dir = os.path.join(work_root, task_id)
    if os.path.exists(task_dir):
        raise Fail(EXIT_USAGE, f"task dir already exists: {task_dir}")
    os.makedirs(task_dir, mode=0o700)
    for sub in ("staging", "baseline", "out", "brief", "operator", "config/omp", "secrets", "logs", "artifacts"):
        os.makedirs(os.path.join(task_dir, sub), mode=0o700)
    os.chmod(os.path.join(task_dir, "secrets"), 0o700)
    return task_dir


def loosen_for_container(path):
    # ceiling: bind mounts through OrbStack/virtiofs do not remap ownership,
    # so a container UID that differs from the host user cannot write the
    # snapshot. The task dir's parent is 0700 and holds nothing but this
    # task's disposable copy, so a+rwX on the writable subtrees is the
    # boring fix; upgrade path is a Docker volume populated via `docker cp`.
    for dirpath, dirnames, filenames in os.walk(path):
        os.chmod(dirpath, 0o777)
        for name in filenames:
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            if stat.S_ISREG(st.st_mode):
                os.chmod(full, 0o777 if st.st_mode & 0o111 else 0o666)


def readable_for_container(path):
    for dirpath, dirnames, filenames in os.walk(path):
        os.chmod(dirpath, 0o755)
        for name in filenames:
            os.chmod(os.path.join(dirpath, name), 0o644)


# --- main flow -------------------------------------------------------------------------

def preflight(a, log):
    """Everything that can fail before any Docker resource exists."""
    if not os.path.isfile(a.brief) or os.path.getsize(a.brief) == 0:
        raise Fail(EXIT_PREFLIGHT, f"brief missing or empty: {a.brief}")
    if not os.path.isfile(RELAY_SCRIPT):
        raise Fail(EXIT_PREFLIGHT, f"relay script missing next to this file: {RELAY_SCRIPT}")
    if not os.path.isdir(a.repo):
        raise Fail(EXIT_PREFLIGHT, f"--repo is not a directory: {a.repo}")
    gateway_url = validate_gateway_url(a.gateway_url)
    a.gateway_url = gateway_url
    commit = git(a.repo, "rev-parse", "--verify", "--end-of-options", a.ref + "^{commit}").strip()
    main_root = main_repo_root(a.repo)
    if a.no_operator_rules:
        operator_rules = None
    else:
        operator_rules = os.path.abspath(a.operator_rules) if a.operator_rules else derive_operator_rules(main_root)
        if operator_rules is None or not os.path.isfile(operator_rules):
            raise Fail(EXIT_PREFLIGHT, f"no operator AGENTS.md found in an ancestor of {main_root}; pass --operator-rules or --no-operator-rules")
    master_token = read_token_file(a.gateway_token_file, log)

    rc, out, err = _run(["docker", "version", "--format", "{{.Server.Version}}"], timeout=30)
    if rc != 0:
        raise Fail(EXIT_PREFLIGHT, f"docker daemon unreachable: {err.strip()[:300]}")
    log(f"docker server {out.strip()}")
    rc, out, err = _run(["docker", "image", "inspect", "--format", "{{.Id}} {{index .Config.Labels \"" + IMAGE_LABEL + "\"}} {{.Architecture}}", a.image], timeout=30)
    if rc != 0:
        raise Fail(EXIT_PREFLIGHT, f"image {a.image} is not present locally (never pulled automatically): build it with Dockerfile.isolated-worker")
    parts = out.split()
    image_id = parts[0]
    label = parts[1] if len(parts) > 1 else ""
    arch = parts[2] if len(parts) > 2 else ""
    if label != IMAGE_LABEL_VALUE:
        raise Fail(EXIT_PREFLIGHT, f"image {a.image} lacks label {IMAGE_LABEL}={IMAGE_LABEL_VALUE} (got {label!r}); refusing an unverified image")
    if arch != "arm64":
        raise Fail(EXIT_PREFLIGHT, f"image {a.image} architecture is {arch!r}, expected arm64")
    if a.image_id and a.image_id != image_id:
        raise Fail(EXIT_PREFLIGHT, f"image ID mismatch: {image_id} != required {a.image_id}")

    probe = probe_url_for(gateway_url, a.gateway_probe_url)
    try:
        status, body = http_get(probe + "/healthz")
    except OSError as e:
        raise Fail(EXIT_PREFLIGHT, f"gateway healthz unreachable at {probe}: {e}")
    if status != 200:
        raise Fail(EXIT_PREFLIGHT, f"gateway healthz at {probe} returned {status}")
    try:
        status, body = http_get(probe + "/v1/models", bearer=master_token)
    except OSError as e:
        raise Fail(EXIT_PREFLIGHT, f"gateway /v1/models unreachable at {probe}: {e}")
    if status == 401:
        raise Fail(EXIT_PREFLIGHT, "gateway rejected the master bearer from --gateway-token-file")
    if status != 200:
        raise Fail(EXIT_PREFLIGHT, f"gateway /v1/models returned {status}")
    try:
        ids = {m.get("id") for m in json.loads(body).get("data", [])}
    except (ValueError, AttributeError):
        raise Fail(EXIT_PREFLIGHT, "gateway /v1/models returned an unparseable body")
    if a.model not in ids:
        raise Fail(EXIT_PREFLIGHT, f"model {a.model} is not routable through the gateway (it lists {len(ids)} models)")
    log(f"gateway ok at {probe}; model {a.model} routable")
    return {"commit": commit, "main_root": main_root, "operator_rules": operator_rules,
            "image_id": image_id, "master_token": master_token, "probe": probe}


def _run(argv, timeout):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def write_task_inputs(a, task_dir, pre, task_id, task_token):
    d = lambda *p: os.path.join(task_dir, *p)  # noqa: E731
    shutil.copyfile(a.brief, d("brief", "brief.md"))
    operator_text = None
    if pre["operator_rules"]:
        with open(pre["operator_rules"], "r", encoding="utf-8", errors="replace") as f:
            operator_text = f.read()
    with open(d("operator", "worker-rules.md"), "w", encoding="utf-8") as f:
        f.write(worker_rules_text(os.path.abspath(a.repo), pre["commit"], a.model, pre["operator_rules"], operator_text, not a.no_workspace_git))
    with open(d("config", "omp", "models.yml"), "w", encoding="utf-8") as f:
        f.write(models_yml())
    passwd, group = passwd_files(a.container_uid, a.container_gid)
    with open(d("config", "passwd"), "w", encoding="utf-8") as f:
        f.write(passwd)
    with open(d("config", "group"), "w", encoding="utf-8") as f:
        f.write(group)
    env_path = d("secrets", "worker.env")
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(f"HERDR_WORKER_MODEL_TOKEN={task_token}\n")
    for sub in ("brief", "operator", "config"):
        readable_for_container(d(sub))
    os.chmod(env_path, 0o600)


def write_result(task_dir, result):
    path = os.path.join(task_dir, "result.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, sort_keys=True)
    return path


def main(argv=None):
    a = parse_args(sys.argv[1:] if argv is None else argv)
    task_id = a.task_id or (_dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3))
    log_lines = []

    def log(msg):
        line = f"[isolated-worker {task_id}] {msg}"
        log_lines.append(f"{now_iso()} {msg}")
        sys.stderr.write(line + "\n")
        sys.stderr.flush()

    try:
        pre = preflight(a, log)
    except Fail as e:
        log(f"preflight failed: {e}")
        print(json.dumps({"schema": SCHEMA, "task_id": task_id, "status": "preflight_failed", "error": str(e), "exit_code": e.code}))
        return e.code
    except Exception as e:  # noqa: BLE001 - preflight must never fall through to a traceback-only exit
        log(f"preflight failed: {type(e).__name__}: {e}")
        print(json.dumps({"schema": SCHEMA, "task_id": task_id, "status": "preflight_failed", "error": f"{type(e).__name__}: {e}", "exit_code": EXIT_PREFLIGHT}))
        return EXIT_PREFLIGHT

    task_dir = os.path.join(os.path.abspath(a.work_root), task_id)
    plan = build_plan(a, task_id, task_dir, pre["commit"], pre["main_root"], pre["operator_rules"], pre["image_id"])
    if a.dry_run:
        plan["status"] = "dry_run"
        plan["note"] = "no Docker resources were created; secrets omitted; models.yml shows the env-var NAME only"
        print(json.dumps(plan, indent=2))
        return EXIT_OK

    try:
        task_dir = make_task_dir(os.path.abspath(a.work_root), task_id)
    except (Fail, OSError) as e:
        log(f"cannot create task dir: {e}")
        print(json.dumps({"schema": SCHEMA, "task_id": task_id, "status": "preflight_failed", "error": str(e), "exit_code": EXIT_PREFLIGHT}))
        return EXIT_PREFLIGHT
    plan["task_dir"] = task_dir
    with open(os.path.join(task_dir, "plan.json"), "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2)
    task_token = secrets.token_urlsafe(32)
    result = {
        "schema": SCHEMA, "task_id": task_id, "task_dir": task_dir, "created_at": now_iso(),
        "status": "starting", "model_completed": False, "artifact_verified": False,
        "artifact_review": "pending_conductor_review", "exit_code": EXIT_FAILURE,
        "source": plan["source"], "worker": {"container": plan["worker"]["container"], "model": a.model, "tools": a.worker_tools, "image_id": pre["image_id"]},
        "relay": {"container": plan["relay"]["container"], "policy": plan["relay"]["policy"]},
        "artifacts": {}, "errors": [],
    }
    rt = None
    code = EXIT_FAILURE

    def on_signal(signum, _frame):
        log(f"received signal {signum}; cleaning up own resources")
        if rt is not None:
            rt.interrupted = True
        else:
            raise KeyboardInterrupt

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    try:
        log(f"exporting {a.ref} ({pre['commit'][:12]}) into {task_dir}/staging")
        manifest = export_snapshot(a.repo, pre["commit"], os.path.join(task_dir, "staging"), a.max_file_mb * 1024 * 1024, int(a.max_snapshot_gb * (1 << 30)))
        manifest["repo"] = os.path.abspath(a.repo)
        manifest["ref"] = a.ref
        manifest_path = os.path.join(task_dir, "manifest.json")
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)
        result["artifacts"]["manifest"] = manifest_path
        log(f"snapshot: {manifest['file_count']} files, {manifest['total_bytes']} bytes, {manifest['excluded_count']} excluded, {len(manifest['submodules'])} submodules omitted")
        shutil.copytree(os.path.join(task_dir, "staging"), os.path.join(task_dir, "baseline"), symlinks=True, dirs_exist_ok=True)
        write_task_inputs(a, task_dir, pre, task_id, task_token)
        loosen_for_container(os.path.join(task_dir, "staging"))
        loosen_for_container(os.path.join(task_dir, "out"))

        rt = Runtime(task_id, task_dir, log)
        relay_log = os.path.join(task_dir, "logs", "relay.log")
        transcript = os.path.join(task_dir, "logs", "worker.stdout.jsonl")
        worker_err = os.path.join(task_dir, "logs", "worker.stderr.log")
        result["artifacts"].update({"relay_log": relay_log, "transcript": transcript, "worker_stderr": worker_err,
                                    "docker_log": os.path.join(task_dir, "logs", "docker.log"), "plan": os.path.join(task_dir, "plan.json")})
        log("creating per-task networks")
        rt.create_networks()
        relay_config = dict(plan["relay"]["policy"])
        relay_config.pop("allowed_route")
        relay_config["task_token"] = task_token
        relay_config["upstream_token"] = pre["master_token"]
        log("starting model relay")
        rt.start_relay(plan["relay"]["docker_create"], relay_config, relay_log)
        log(f"starting worker (deadline {a.timeout}s, omp --max-time {plan['worker']['max_time_s']}s)")
        result["status"] = "running"
        write_result(task_dir, result)
        state = rt.run_worker(plan["worker"]["docker_create"], transcript, worker_err, a.timeout)
        result["worker"].update(state)
        log(f"worker exited: code={state['exit_code']} oom={state['oom_killed']} killed_by_deadline={state['killed_by_deadline']} wall={state['wall_s']}s")
        result["relay"]["summary"] = rt.stop_relay(relay_log)

        # -- evidence (all untrusted data) --
        tinfo = analyse_transcript(transcript)
        result["transcript"] = tinfo
        result["model_completed"] = tinfo["model_completed"]
        result_md = os.path.join(task_dir, "out", "RESULT.md")
        if os.path.isfile(result_md) and not os.path.islink(result_md) and os.path.getsize(result_md) > 0:
            data, truncated = read_bytes_capped(result_md, RESULT_MD_CAP)
            result["artifacts"]["result_md"] = result_md
            result["result_md"] = {"bytes": len(data), "truncated": truncated, "sha256": hashlib.sha256(data).hexdigest()}
        else:
            result["result_md"] = None
        patch_path = os.path.join(task_dir, "artifacts", "changes.patch")
        changes_path = os.path.join(task_dir, "artifacts", "changes.json")
        changes = collect_changes(os.path.join(task_dir, "baseline"), os.path.join(task_dir, "staging"),
                                  os.path.join(task_dir, "artifacts", "changed-files"), patch_path, changes_path)
        result["artifacts"].update({"patch": patch_path, "changes": changes_path, "changed_files_dir": os.path.join(task_dir, "artifacts", "changed-files")})
        result["changes"] = changes["counts"]
        result["changes"]["patch_bytes"] = os.path.getsize(patch_path)
        log(f"changes: {changes['counts']}")

        if rt.interrupted:
            result["status"], code = "interrupted", EXIT_INTERRUPTED
        elif state["killed_by_deadline"]:
            result["status"], code = "timeout", EXIT_WORKER
        elif state["oom_killed"]:
            result["status"], code = "oom_killed", EXIT_WORKER
        elif state["exit_code"] != 0:
            result["status"], code = "worker_failed", EXIT_WORKER
        elif not tinfo["model_completed"]:
            result["status"], code = "model_failed", EXIT_WORKER
            if tinfo["error_message"]:
                result["errors"].append(f"assistant: {tinfo['error_message'][:500]}")
        elif result["result_md"] is None:
            result["status"], code = "evidence_failed", EXIT_EVIDENCE
            result["errors"].append("worker did not write /herdr/out/RESULT.md")
        else:
            result["status"], code = "completed", EXIT_OK
    except Fail as e:
        result["status"] = "failed" if rt is not None else "preflight_failed"
        result["errors"].append(str(e))
        code = e.code
        log(f"failed: {e}")
    except KeyboardInterrupt:
        result["status"], code = "interrupted", EXIT_INTERRUPTED
        result["errors"].append("interrupted before containers started")
    except Exception as e:  # noqa: BLE001 - last-resort: record, clean up, exit nonzero
        result["status"], code = "internal_error", EXIT_FAILURE
        result["errors"].append(f"{type(e).__name__}: {e}")
        log(f"internal error: {type(e).__name__}: {e}")
    finally:
        if rt is not None:
            result["cleanup"] = rt.cleanup()
            if not result["cleanup"]["ok"]:
                result["errors"].append(f"cleanup left resources: {result['cleanup']['remaining']}")
                if code == EXIT_OK:
                    code = EXIT_FAILURE
            log(f"cleanup: removed={result['cleanup']['removed']} remaining={result['cleanup']['remaining']}")
        shutil.rmtree(os.path.join(task_dir, "secrets"), ignore_errors=True)
        result["finished_at"] = now_iso()
        result["exit_code"] = code
        with open(os.path.join(task_dir, "logs", "orchestrator.log"), "w", encoding="utf-8") as f:
            f.write("\n".join(log_lines) + "\n")
        result["artifacts"]["result_json"] = write_result(task_dir, result)
    print(json.dumps(result, indent=2, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
