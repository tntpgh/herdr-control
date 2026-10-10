"""Versioned task-delegation admission. No credentials are passed to workers.

The existing ingest key authenticates server-derived OAuth provenance. This
delegates the selected task mode; it is never a human exact-command approval.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import json
import re
import time

PROTOCOL = 1
DOMAIN = b"herdr-task-authorization-v1\n"
MAX_TTL_MS = 15 * 60 * 1000
CLOCK_SKEW_MS = 30 * 1000
MAX_CLAIMS_BYTES = 32768
MODE_FIELDS = ("job_class", "secrets", "git", "writes", "net_read")
CLAIM_FIELDS = {"version", "source", "command_id", "op", "remote_task_id",
                "requester_actor", "requester_client", "scope", "repo", "mode",
                "effective_scope", "payload_sha256", "issued_at", "expires_at"}
_VERIFIED = object()


class AuthorizationError(ValueError):
    pass


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def payload_sha256(payload: dict) -> str:
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()


def _unique_pairs(pairs: list[tuple]) -> dict:
    out = {}
    for key, value in pairs:
        if key in out:
            raise AuthorizationError("duplicate authorization field")
        out[key] = value
    return out


def _parse(claims: str) -> dict:
    try:
        data = json.loads(claims, object_pairs_hook=_unique_pairs)
        if not isinstance(data, dict) or set(data) != CLAIM_FIELDS or canonical_json(data) != claims:
            raise AuthorizationError("authorization schema or canonical encoding mismatch")
        return data
    except (TypeError, ValueError, UnicodeError) as exc:
        raise AuthorizationError("invalid authorization claims") from exc


def _check(data: dict, cmd: dict, allowlist: dict, now_ms: int) -> None:
    if type(data["version"]) is not int or data["version"] != PROTOCOL or data["source"] != "oauth_task_delegation":
        raise AuthorizationError("unsupported authorization protocol or source")
    for name in ("command_id", "remote_task_id", "requester_actor", "requester_client", "repo"):
        value = data[name]
        if not isinstance(value, str) or not value or len(value) > 256 or any(ord(c) < 32 for c in value):
            raise AuthorizationError(f"invalid authorization {name}")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", data["command_id"]):
        raise AuthorizationError("invalid authorization command_id")
    if not re.fullmatch(r"rtask_\d{8}T\d{6}Z_[0-9a-f]{8}", data["remote_task_id"]):
        raise AuthorizationError("remote_task_id has an unexpected shape")
    issued, expires = data["issued_at"], data["expires_at"]
    if type(issued) is not int or type(expires) is not int or not 0 < issued < expires or expires - issued > MAX_TTL_MS:
        raise AuthorizationError("invalid authorization validity window")
    if issued > now_ms + CLOCK_SKEW_MS or expires <= now_ms:
        raise AuthorizationError("authorization expired or issued in the future")
    if data["op"] not in ("start", "resume") or any(data[k] != cmd.get(k) for k in ("command_id", "op", "remote_task_id")):
        raise AuthorizationError("authorization command/task binding mismatch")
    payload = cmd.get("payload")
    if not isinstance(payload, dict) or data["payload_sha256"] != payload_sha256(payload):
        raise AuthorizationError("authorization payload binding mismatch")
    if data["repo"] != payload.get("repo") or data["repo"] not in allowlist.get("repos", []):
        raise AuthorizationError("repo is not allow-listed or authorization binding changed")
    mode = data["mode"]
    if mode not in ("research", "implement") or mode not in allowlist.get("modes", {}):
        raise AuthorizationError("unknown mode in authorization")
    # Protocol 1 always binds the explicit wire mode for start and resume.
    if mode != payload.get("mode"):
        raise AuthorizationError("authorization mode binding mismatch")
    required_scope = "herdr:task.start" if mode == "research" else "herdr:task.implement"
    if data["scope"] != required_scope:
        raise AuthorizationError("authorization entitlement does not match mode")
    local = allowlist["modes"][mode]
    if not isinstance(data["effective_scope"], dict) or set(data["effective_scope"]) != set(MODE_FIELDS):
        raise AuthorizationError("invalid effective scope")
    if data["effective_scope"] != {k: local.get(k) for k in MODE_FIELDS}:
        raise AuthorizationError("authorization effective scope differs from local allowlist")


@dataclass(frozen=True)
class VerifiedAuthorization:
    claims: str
    signature: str
    _seal: object

    @property
    def parsed(self) -> dict:
        return _parse(self.claims)

    def matches(self, cmd: dict, allowlist: dict, now_ms: int | None = None) -> bool:
        if self._seal is not _VERIFIED or cmd.get("authorization") != {"claims": self.claims, "signature": self.signature}:
            raise AuthorizationError("missing verified authorization or envelope changed")
        try:
            _check(self.parsed, cmd, allowlist, int(time.time() * 1000) if now_ms is None else now_ms)
        except (TypeError, ValueError, KeyError, UnicodeError) as exc:
            raise AuthorizationError(str(exc)) from exc
        return True


def verify_command(cmd: dict, key: str, allowlist: dict, now_ms: int | None = None) -> VerifiedAuthorization:
    envelope = cmd.get("authorization")
    if not isinstance(envelope, dict) or set(envelope) != {"claims", "signature"}:
        raise AuthorizationError("missing versioned task authorization")
    claims, signature = envelope["claims"], envelope["signature"]
    if not isinstance(key, str) or len(key) < 32:
        raise AuthorizationError("authorization verification key unavailable")
    if not isinstance(claims, str) or not isinstance(signature, str) or not re.fullmatch(r"[0-9a-f]{64}", signature):
        raise AuthorizationError("invalid authorization envelope")
    try:
        raw = claims.encode("utf-8")
        if len(raw) > MAX_CLAIMS_BYTES:
            raise AuthorizationError("authorization claims too large")
        expected = hmac.new(key.encode("utf-8"), DOMAIN + raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise AuthorizationError("authorization signature mismatch")
        verified = VerifiedAuthorization(claims, signature, _VERIFIED)
        verified.matches(cmd, allowlist, now_ms)
        return verified
    except (TypeError, KeyError, UnicodeError) as exc:
        raise AuthorizationError("invalid authorization data") from exc
