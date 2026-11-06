#!/usr/bin/env python3
"""lib/extract-doc-only-patch.py — pull ONE file's diff out of a larger patch.

Built for stage2-diagnose.sh's out-of-scope recovery path (.handoffs/SPEC.md
T4, 2026-10-21): when an isolated Stage-2 pass returns a patch that touches
more than docs/tracking/<date>-stage2-diagnose-pass.md, the whole patch is
refused (see the real 2026-10-02 case,
~/.herdr/isolated-worker/20261002T130002-28ed84/artifacts/changes.patch,
where the out-of-scope path was a stray
scripts/__pycache__/findings_to_okf.cpython-311.pyc next to an otherwise-fine
doc). Losing a good doc because of one unrelated byproduct file is wasteful,
but auto-applying ANY part of an untrusted, out-of-scope patch is exactly the
failure mode the scope check exists to prevent. The middle path: extract
just the target file's hunk as a PROPOSAL a human can review and apply by
hand -- never done automatically, never more than this one file.

Matches on the exact `diff --git a/<target> b/<target>` header line (no
regex/glob), so a target containing regex metacharacters cannot mismatch.
Handles the "new file" preamble (`new file mode`, `--- /dev/null`) same as
any other git patch, since it is copied verbatim.

Usage: extract-doc-only-patch.py <patch-file> <target-path>
  stdout: the target file's diff section (diff --git ... through the next
          `diff --git ` line or EOF), byte-identical to the source patch.
  exit 0 if the target was found and written, 1 if not found in the patch.
"""
import sys


def extract(patch_path: str, target: str) -> bytes:
    header = f"diff --git a/{target} b/{target}\n".encode()
    with open(patch_path, "rb") as f:
        data = f.read()
    lines = data.splitlines(keepends=True)
    out = []
    keep = False
    for line in lines:
        if line.startswith(b"diff --git "):
            keep = line == header
        if keep:
            out.append(line)
    return b"".join(out)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract-doc-only-patch.py <patch-file> <target-path>", file=sys.stderr)
        return 2
    section = extract(sys.argv[1], sys.argv[2])
    if not section:
        print(f"extract-doc-only-patch: {sys.argv[2]} not found in {sys.argv[1]}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(section)
    return 0


if __name__ == "__main__":
    sys.exit(main())
