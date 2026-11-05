"""The Mac side of the herdr-mcp Worker's /ingest/sync contract, shared by
both publishers: publisher.py (herdr hub + run registry) and fm_publisher.py
(Firstmate's CLIs). One copy of the redaction rules, the credential loader,
the HMAC signature and the POST, so the two can never drift apart on what
leaves the Mac or how it is signed.

Moved out of publisher.py unchanged; publisher.py re-exports every name, so
`from publisher import URL, ingest_key, sign` (scripts/grants.py) keeps working.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import time
import urllib.request
from pathlib import Path

URL = os.environ.get("HERDR_MCP_URL", "https://herdr-mcp.teamthurber.com").rstrip("/")
LAUNCHD_SECRETS = Path.home() / ".config/op/launchd-secrets.env"

# ceiling: pattern redaction catches common credential shapes, not every
# secret or every piece of client data. Upgrade path: route text through the
# fleet secret-scan patterns (git-hooks/secret-scan-pre-commit.sh) once they
# are exposed as a library.
REDACTIONS = [
    # An unterminated block (a file cut mid-key) is redacted to the end.
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S), "[REDACTED:private-key]"),
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}"), "[REDACTED:api-key]"),
    (re.compile(r"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"), "[REDACTED:api-key]"),
    (re.compile(r"\bAIza[0-9A-Za-z_\-]{30,}"), "[REDACTED:google-api-key]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "[REDACTED:github-token]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "[REDACTED:github-token]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}"), "[REDACTED:slack-token]"),
    (re.compile(r"\bxapp-[A-Za-z0-9\-]{10,}"), "[REDACTED:slack-token]"),
    (re.compile(r"\bA[KS]IA[0-9A-Z]{16}\b"), "[REDACTED:aws-key]"),
    (re.compile(r"\bops_[A-Za-z0-9_\-]{20,}"), "[REDACTED:op-token]"),
    (re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), "[REDACTED:jwt]"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._\-~+/=]{16,}"), r"\1 [REDACTED]"),
    (re.compile(r"(?i)\b([a-z][a-z0-9+.\-]*://)[^\s:/@]+:[^\s@/]+@"), r"\1[REDACTED]@"),
    (re.compile(r"https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]+"), "[REDACTED:slack-webhook]"),
    # Signed-URL and query-string secrets (Azure SAS sig=, ?token=, &api_key=).
    (re.compile(r"(?i)([?&](?:sig|signature|token|access_token|api[_\-]?key|key|secret)=)[^&\s\"'#]{8,}"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\b(x-api-key|api-key|x-auth-token)\s*:\s*\S{8,}"), r"\1: [REDACTED]"),
    # "password": "…" / 'api_key': '…' (JSON, YAML flow, Python dicts).
    (re.compile(r"(?i)([\"'][a-z0-9_.\-]*(?:secret|token|password|passwd|passphrase|pwd|api[_\-]?key|private[_\-]?key|"
                r"access[_\-]?key|auth|credential)[a-z0-9_.\-]*[\"']\s*:\s*)([\"'])[^\"']{4,}\2"), r'\1"[REDACTED]"'),
    # NAME=value / name: value for names that only ever hold secrets.
    (re.compile(r"(?i)\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|PWD|CREDENTIALS?|API_?KEY|PRIVATE_?KEY|"
                r"ACCESS_?KEY|DSN)[A-Z0-9_]*)\s*[=:]\s*(['\"]?)[^\s'\"]{6,}\2"), r"\1=[REDACTED]"),
    # Names with KEY/AUTH in them, any case (HERDR_MCP_INGEST_KEY, ingest_key,
    # twilio_auth) with `=`; UPPER_CASE ones with `:` too, so prose like
    # "primary key: task_id" survives.
    (re.compile(r"(?i)\b([a-z][a-z0-9_]*_(?:key|auth)[a-z0-9_]*|[A-Z][A-Z0-9_]*(?:KEY|AUTH)[A-Z0-9_]*)\s*=\s*(['\"]?)[^\s'\"]{6,}\2"),
     r"\1=[REDACTED]"),
    (re.compile(r"\b([A-Z][A-Z0-9_]*(?:KEY|AUTH)[A-Z0-9_]*)\s*:\s*(['\"]?)[^\s'\"]{6,}\2"), r"\1=[REDACTED]"),
    # Local filesystem paths under real roots (any prefix, file:// too, spaces inside a segment) and worktrees.
    (re.compile(r"(?:file://)?(?:~|(?<![\w.\-])/(?:Users|home|private|var|tmp|opt|Volumes))/[^\s\"'<>()\[\]]*"
                r"(?: [^\s/]+/[^\s\"'<>()\[\]]*)*"), "[path]"),
    (re.compile(r"\S*\.(?:treehouse|herdr/worktrees)/\S*"), "[path]"),
]


def redact(text: str) -> str:
    for pat, repl in REDACTIONS:
        text = pat.sub(repl, text)
    return text


# ── secret: the same literal-assignment format hub.py reads ────────────────────
def ingest_key() -> str | None:
    v = os.environ.get("HERDR_MCP_INGEST_KEY")
    if v:
        return v
    try:
        lines = LAUNCHD_SECRETS.read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        key, _, val = line.strip().removeprefix("export ").partition("=")
        if key.strip() == "HERDR_MCP_INGEST_KEY":
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
                val = val[1:-1]
            return val or None
    return None


def sign(key: str, ts: str, nonce: str, body: bytes) -> str:
    msg = f"{ts}.{nonce}.{hashlib.sha256(body).hexdigest()}".encode()
    return hmac.new(key.encode(), msg, hashlib.sha256).hexdigest()


# ── talking to the Worker ──────────────────────────────────────────────────────
def post_sync(key: str, body: dict, user_agent: str = "herdr-mcp-publisher/1") -> dict:
    raw = json.dumps(body, separators=(",", ":")).encode()
    ts, nonce = str(int(time.time())), secrets.token_hex(16)
    req = urllib.request.Request(f"{URL}/ingest/sync", data=raw, method="POST", headers={
        "content-type": "application/json", "x-herdr-ts": ts, "x-herdr-nonce": nonce,
        "x-herdr-sig": sign(key, ts, nonce, raw), "user-agent": user_agent,
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)
