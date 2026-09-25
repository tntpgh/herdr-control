#!/usr/bin/env bash
# lib/task-manifest.sh — the capability manifest a task is approved for ONCE,
# at spawn, instead of once per tool call.
#
# Provides: manifest_from_spec <SPEC.md>   -> canonical JSON on stdout, "" when
#                                             the spec has no manifest block;
#                                             exit 2 + stderr reason when the
#                                             block is present but invalid.
#           manifest_sha <json>            -> sha256 of the canonical JSON
#
# The block lives in the task's SPEC.md, fenced as ```herdr-manifest:
#
#     ```herdr-manifest
#     net_read: [teamthurber.com, www.teamthurber.com]
#     writes: [tmp/**, GEO-AUDIT-REPORT-*.md]
#     net_write: none
#     git: commit-only
#     ```
#
# WHO APPROVES IT, AND WHEN: the conductor that runs spawn-task.sh. Writing the
# brief and spawning the worker is one decision, recorded once as a
# `manifest_approved` event carrying the manifest's sha256 and the spawning
# conductor's id/pane. The manifest can only grant what that conductor could
# already approve call-by-call under the reviewed-operational grant
# (docs/approval-policy.md rule 1) — local writes in the worktree and GETs to
# named hosts — so it is a pre-review of the conductor's own authority, never
# an extension of it. The human-reserved list (lib/command-policy.sh
# conductor_reserved_reason) is checked BEFORE the manifest and nothing here
# can name anything on it.
#
# Validated strictly and FAIL CLOSED: an unknown key, a malformed host, a glob
# that escapes the worktree or targets git/handoff/secret files, or any
# `net_write` other than `none` refuses the spawn instead of silently granting
# less (or more) than the brief's author thought they wrote. The only values:
#   net_read   list of exact hostnames (lowercase, dotted; no wildcards, no
#              ports, no IP literals). A GET to one of them may clear.
#   writes     list of worktree-relative globs (`*` within a path segment,
#              `**` across segments). An output FILE of an in-scope GET must
#              match one. Never absolute, never `~`, never a `..` segment,
#              never `.git`, `.handoffs`, or `.env*`.
#   net_write  `none` — the only accepted value. Remote mutation is
#              human-only (approval-policy.md rule 1); a manifest cannot grant it.
#   git        `none` | `commit-only` | `push-own-branch` (default). A CEILING
#              on the peer ownership grant (_cp_grant_action), never a grant
#              beyond it: commit-only refuses a peer-pressed push/PR-create,
#              none refuses peer-pressed git add/commit/push too.
#
# The canonical JSON (sorted keys, defaults filled in) is what the registry
# stores and what the policy reads — never the worker-writable identity.json
# copy, which is informational only: a worker that edits its own identity.json
# changes nothing the approver consults.
set -uo pipefail

manifest_from_spec() {                  # <spec-path>
  local spec="$1"
  [ -r "$spec" ] || { printf 'task-manifest: cannot read %s\n' "$spec" >&2; return 2; }
  python3 - "$spec" <<'PY'
import json, re, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
blocks = re.findall(r"^```herdr-manifest[ \t]*\n(.*?)^```[ \t]*$", text, re.S | re.M)
if not blocks:
    sys.exit(0)
def die(msg):
    print(f"task-manifest: {msg}", file=sys.stderr)
    sys.exit(2)
if len(blocks) > 1:
    die("more than one herdr-manifest block — exactly one is allowed")

HOST = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
GLOB_SEG = re.compile(r"^[A-Za-z0-9._*+@=,-]+$")
FORBIDDEN_SEG = re.compile(r"^(\.git|\.handoffs|\.env.*)$", re.I)

def parse_list(key, raw):
    raw = raw.strip()
    if not (raw.startswith("[") and raw.endswith("]")):
        die(f"{key}: expected a [bracketed, list]")
    items = [s.strip().strip("'\"") for s in raw[1:-1].split(",")]
    return [s for s in items if s]

out = {"net_read": [], "writes": [], "net_write": "none", "git": "push-own-branch"}
seen = set()
for n, line in enumerate(blocks[0].splitlines(), 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    m = re.match(r"^([a-z_]+)[ \t]*:[ \t]*(.*)$", line.strip())
    if not m:
        die(f"line {n}: expected `key: value`")
    key, val = m.group(1), m.group(2).strip()
    if key in seen:
        die(f"duplicate key {key}")
    seen.add(key)
    if key == "net_read":
        hosts = parse_list(key, val)
        for h in hosts:
            if not HOST.match(h) or re.match(r"^[0-9.]+$", h):
                die(f"net_read: {h!r} is not an exact lowercase hostname")
        out[key] = sorted(set(hosts))
    elif key == "writes":
        globs = parse_list(key, val)
        for g in globs:
            if g.startswith(("/", "~")) or "\\" in g:
                die(f"writes: {g!r} must be worktree-relative")
            for seg in g.split("/"):
                if seg in ("", ".", "..") or not GLOB_SEG.match(seg):
                    die(f"writes: {g!r} has an invalid path segment {seg!r}")
                if FORBIDDEN_SEG.match(seg):
                    die(f"writes: {g!r} targets {seg} — never grantable")
        out[key] = sorted(set(globs))
    elif key == "net_write":
        if val != "none":
            die("net_write: only `none` is accepted — remote mutation is human-only and a manifest cannot grant it")
    elif key == "git":
        if val not in ("none", "commit-only", "push-own-branch"):
            die("git: expected none | commit-only | push-own-branch")
        out[key] = val
    else:
        die(f"unknown key {key!r} (known: net_read, writes, net_write, git)")
print(json.dumps(out, sort_keys=True, separators=(",", ":")))
PY
}

manifest_sha() {                        # <json>
  printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
}
