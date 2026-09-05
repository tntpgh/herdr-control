#!/usr/bin/env python3
"""isolated-model-relay.py — the ONLY thing an isolated worker can talk to.

Runs as a sidecar container that sits on the worker's internal network (alias
`model-relay`) and on a per-task egress network. It accepts exactly one kind
of request from the worker — `POST /v1/pi/stream` for one pre-approved
provider-qualified model, authenticated with a per-task bearer — and forwards
it to a FIXED upstream `omp auth-gateway` using the gateway's master bearer,
which the worker never sees.

Why a relay at all (see /tmp/herdr-gateway-research.txt, v18.1.10 sources):
the shipped gateway bearer is service-wide — it also grants /v1/usage,
/v1/models, /v1/credentials/check and every routable model. Nothing in the
CLI scopes it per task or per model, so the scoping has to live here.

Contract with isolated-worker.py:
  * Configuration is ONE JSON object read from stdin at startup. Secrets never
    appear in argv, environment, or any log line this program writes.
  * Prints `relay ready port=<n>` on stdout once the listener is bound; prints
    a single `{"event":"relay_summary",...}` JSON line on SIGTERM/SIGINT.
  * Stdlib only; no third-party imports; runs as an unprivileged UID with a
    read-only root filesystem.

What is enforced per request:
  * path == /v1/pi/stream and method == POST; everything else is 404/405
    (no /v1/models, /v1/usage, /healthz passthrough, no CONNECT, no redirects).
  * Authorization: Bearer <task token>, constant-time compare; after
    MAX_AUTH_FAILURES bad tokens the relay locks itself (503 for everything).
  * Content-Length required and <= max_body_bytes; no chunked request bodies.
  * body.modelId == the one approved model (exact string); the compatibility
    `model` field is rejected so the gateway's alternate model resolution is
    unreachable; `stream` must be absent or true (we only speak SSE).
  * options is re-built from an allow-list: transport/provider overrides,
    `headers`, `metadata`, `requestMetadata`, `initiatorOverride`,
    `serviceTier`, websocket/format switches, guardrail ids are DROPPED.
  * Upstream Authorization is replaced with the master bearer; client-supplied
    attribution headers are replaced with fixed task attribution.
  * max_concurrent in-flight, max_requests per task lifetime, per-request
    deadline, upstream idle timeout, total lifetime — all finite.
  * The SSE body is forwarded byte-for-byte as it arrives (chunked), never
    buffered whole, never rewritten; upstream errors are relayed with their
    status and bounded body.
"""
import hmac
import http.client
import json
import os
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTE = "/v1/pi/stream"
MAX_AUTH_FAILURES = 20
ERROR_BODY_CAP = 64 * 1024
CHUNK = 64 * 1024

# SimpleStreamOptions keys a worker may legitimately tune. Compared against
# pi-native-server.ts ALLOWED_OPTION_KEYS (v18.1.10); everything the gateway
# would accept but that changes transport, billing tier, provider routing,
# outbound headers or attribution is deliberately absent.
ALLOWED_OPTIONS = frozenset(
    {
        "temperature",
        "topP",
        "topK",
        "minP",
        "presencePenalty",
        "frequencyPenalty",
        "repetitionPenalty",
        "stopSequences",
        "maxTokens",
        "cacheRetention",
        "promptCacheKey",
        "sessionId",
        "reasoning",
        "disableReasoning",
        "hideThinkingSummary",
        "thinkingBudgets",
        "toolChoice",
        "loopGuard",
        "acceptEmptyResponse",
    }
)

REQUIRED_CONFIG = {
    "listen_port": int,
    "task_token": str,
    "upstream_url": str,
    "upstream_token": str,
    "model_id": str,
    "max_body_bytes": int,
    "max_concurrent": int,
    "max_requests": int,
    "request_deadline_s": (int, float),
    "idle_timeout_s": (int, float),
    "lifetime_s": (int, float),
    "attribution_id": str,
}


class RelayConfig:
    __slots__ = tuple(REQUIRED_CONFIG) + ("scheme", "host", "port", "path_prefix")

    def __init__(self, raw):
        if not isinstance(raw, dict):
            raise ValueError("relay config must be a JSON object")
        for key, typ in REQUIRED_CONFIG.items():
            if key not in raw:
                raise ValueError(f"relay config missing {key}")
            value = raw[key]
            if isinstance(value, bool) or not isinstance(value, typ):
                raise ValueError(f"relay config {key} has wrong type")
            setattr(self, key, value)
        if not (0 < self.listen_port < 65536):
            raise ValueError("listen_port out of range")
        if len(self.task_token) < 16 or not self.upstream_token:
            raise ValueError("tokens too short/empty")
        if "/" not in self.model_id or self.model_id != self.model_id.strip():
            raise ValueError("model_id must be provider-qualified")
        for key in ("max_body_bytes", "max_concurrent", "max_requests"):
            if getattr(self, key) <= 0:
                raise ValueError(f"{key} must be positive")
        for key in ("request_deadline_s", "idle_timeout_s", "lifetime_s"):
            if getattr(self, key) <= 0:
                raise ValueError(f"{key} must be positive")
        u = urllib.parse.urlsplit(self.upstream_url)
        if u.scheme not in ("http", "https") or not u.hostname or u.query or u.fragment:
            raise ValueError("upstream_url must be http(s)://host[:port][/prefix] without query/fragment")
        self.scheme = u.scheme
        self.host = u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.path_prefix = u.path.rstrip("/")


class RelayState:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.inflight = 0
        self.served = 0          # forwarded to upstream
        self.rejected = 0        # refused before upstream
        self.auth_failures = 0
        self.upstream_errors = 0
        self.bytes_in = 0
        self.bytes_out = 0
        self.locked_down = False
        self.started = time.monotonic()

    def summary(self):
        return {
            "event": "relay_summary",
            "served": self.served,
            "rejected": self.rejected,
            "auth_failures": self.auth_failures,
            "upstream_errors": self.upstream_errors,
            "bytes_in": self.bytes_in,
            "bytes_out": self.bytes_out,
            "locked_down": self.locked_down,
            "uptime_s": round(time.monotonic() - self.started, 1),
        }


def log(msg, **fields):
    rec = {"ts": round(time.time(), 3), "msg": msg}
    rec.update(fields)
    sys.stdout.write(json.dumps(rec, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def sanitize_options(raw):
    if not isinstance(raw, dict):
        return {}
    return {k: v for k, v in raw.items() if k in ALLOWED_OPTIONS and v is not None}


def validate_request(body, cfg):
    """Return (sanitized_body_bytes, None) or (None, (status, type, message))."""
    if not isinstance(body, dict):
        return None, (400, "invalid_request_error", "body must be a JSON object")
    if "model" in body:
        return None, (400, "invalid_request_error", "`model` is not accepted; send `modelId`")
    model_id = body.get("modelId")
    if not isinstance(model_id, str) or not model_id:
        return None, (400, "invalid_request_error", "missing `modelId`")
    if not hmac.compare_digest(model_id.encode(), cfg.model_id.encode()):
        return None, (403, "permission_error", "model not approved for this task")
    context = body.get("context")
    if not isinstance(context, dict) or not isinstance(context.get("messages"), list):
        return None, (400, "invalid_request_error", "`context.messages` must be an array")
    if "systemPrompt" in context and not isinstance(context["systemPrompt"], list):
        return None, (400, "invalid_request_error", "`context.systemPrompt` must be an array")
    if "tools" in context and not isinstance(context["tools"], list):
        return None, (400, "invalid_request_error", "`context.tools` must be an array")
    stream = body.get("stream", True)
    if stream is not True:
        return None, (400, "invalid_request_error", "only streaming requests are relayed")
    out = {
        "modelId": cfg.model_id,
        "context": context,
        "options": sanitize_options(body.get("options")),
        "stream": True,
    }
    return json.dumps(out, separators=(",", ":")).encode(), None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 60  # socket idle timeout for the client side (slowloris bound)
    server_version = "herdr-model-relay"
    sys_version = ""

    # BaseHTTPRequestHandler logs to stderr with client addresses; route
    # through the JSON logger and never include headers or bodies.
    def log_message(self, fmt, *args):  # noqa: D401 - stdlib hook
        return

    def _state(self):
        return self.server.relay_state

    def _cfg(self):
        return self.server.relay_state.cfg

    def _reply_json(self, status, etype, message, extra_headers=None):
        payload = json.dumps({"error": {"type": etype, "message": message}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def _reject(self, status, etype, message, reason):
        st = self._state()
        with st.lock:
            st.rejected += 1
        log("reject", status=status, reason=reason, path=self.path, method=self.command)
        self._reply_json(status, etype, message)

    def _drain_body(self):
        # Discard a bounded request body so the rejection reply is not
        # interleaved with unread bytes; anything larger is simply closed.
        n = self.headers.get("Content-Length")
        try:
            n = int(n) if n is not None else 0
        except ValueError:
            n = 0
        if 0 < n <= self._cfg().max_body_bytes:
            self.rfile.read(n)

    def do_GET(self):
        self._reject(404, "not_found", "no such route", "route")

    def do_HEAD(self):
        self._reject(404, "not_found", "no such route", "route")

    def do_PUT(self):
        self._drain_body()
        self._reject(404, "not_found", "no such route", "route")

    def do_DELETE(self):
        self._reject(404, "not_found", "no such route", "route")

    def do_OPTIONS(self):
        self._reject(404, "not_found", "no such route", "route")

    def do_CONNECT(self):
        self._reject(405, "method_not_allowed", "CONNECT is not supported", "connect")

    def do_PATCH(self):
        self._drain_body()
        self._reject(404, "not_found", "no such route", "route")

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        parts = header.split(None, 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return False
        presented = parts[1].strip().encode()
        return hmac.compare_digest(presented, self._cfg().task_token.encode())

    def do_POST(self):
        st = self._state()
        cfg = self._cfg()
        if st.locked_down:
            self._reject(503, "unavailable", "relay locked down", "locked_down")
            return
        if urllib.parse.urlsplit(self.path).path != ROUTE:
            self._drain_body()
            self._reject(404, "not_found", "no such route", "route")
            return
        if not self._authorized():
            self._drain_body()
            with st.lock:
                st.auth_failures += 1
                if st.auth_failures >= MAX_AUTH_FAILURES:
                    st.locked_down = True
            self._reject(401, "authentication_error", "unauthorized", "auth")
            if st.locked_down:
                log("locked_down", auth_failures=st.auth_failures)
            return
        if self.headers.get("Transfer-Encoding"):
            self._reject(411, "invalid_request_error", "Content-Length required", "chunked_request")
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._reject(411, "invalid_request_error", "Content-Length required", "no_length")
            return
        if length <= 0 or length > cfg.max_body_bytes:
            self._reject(413, "invalid_request_error", "request body too large", "body_size")
            return
        # Admission: quota + concurrency, decided atomically.
        with st.lock:
            if st.served >= cfg.max_requests:
                admitted = False
                reason = "quota"
            elif st.inflight >= cfg.max_concurrent:
                admitted = False
                reason = "concurrency"
            else:
                admitted = True
                st.inflight += 1
                st.served += 1
        if not admitted:
            self._drain_body()
            self._reject(429, "rate_limit_error", f"relay {reason} exhausted", reason)
            return
        started = time.monotonic()
        status = 0
        out_bytes = 0
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                self._reply_json(400, "invalid_request_error", "short body")
                return
            with st.lock:
                st.bytes_in += length
            try:
                body = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self._reply_json(400, "invalid_request_error", "body is not valid JSON")
                return
            forward, err = validate_request(body, cfg)
            if err:
                log("reject", status=err[0], reason=err[1], path=self.path, method="POST")
                self._reply_json(*err)
                return
            status, out_bytes = self._forward(forward, cfg, st, started)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            log("client_gone", elapsed_s=round(time.monotonic() - started, 3))
        finally:
            with st.lock:
                st.inflight -= 1
                st.bytes_out += out_bytes
            log(
                "request",
                status=status,
                elapsed_s=round(time.monotonic() - started, 3),
                bytes_in=length,
                bytes_out=out_bytes,
                served=st.served,
            )

    def _forward(self, forward, cfg, st, started):
        """POST to the fixed upstream and stream its body back. Returns (status, bytes_out)."""
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Content-Length": str(len(forward)),
            "Authorization": "Bearer " + cfg.upstream_token,
            "x-omp-app": "herdr-isolated-worker",
            "x-omp-hostname": cfg.attribution_id,
            "x-omp-install-id": cfg.attribution_id,
            "Connection": "close",
        }
        if cfg.scheme == "https":
            conn = http.client.HTTPSConnection(
                cfg.host, cfg.port, timeout=cfg.idle_timeout_s, context=ssl.create_default_context()
            )
        else:
            conn = http.client.HTTPConnection(cfg.host, cfg.port, timeout=cfg.idle_timeout_s)
        deadline = started + cfg.request_deadline_s
        sent = 0
        try:
            try:
                conn.request("POST", cfg.path_prefix + ROUTE, body=forward, headers=headers)
                resp = conn.getresponse()
            except (OSError, http.client.HTTPException) as e:
                with st.lock:
                    st.upstream_errors += 1
                log("upstream_unreachable", error=type(e).__name__)
                self._reply_json(502, "upstream_error", "model gateway unreachable")
                return 502, 0
            if resp.status != 200:
                with st.lock:
                    st.upstream_errors += 1
                body = resp.read(ERROR_BODY_CAP + 1)
                if len(body) > ERROR_BODY_CAP:
                    body = json.dumps({"error": {"type": "upstream_error", "message": "upstream error too large"}}).encode()
                ctype = resp.getheader("Content-Type", "application/json")
                self.send_response(resp.status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True
                return resp.status, len(body)
            self.send_response(200)
            self.send_header("Content-Type", resp.getheader("Content-Type", "text/event-stream; charset=utf-8"))
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            rid = resp.getheader("x-request-id")
            if rid:
                self.send_header("x-request-id", rid)
            self.end_headers()
            self.wfile.flush()
            while True:
                if time.monotonic() > deadline:
                    log("deadline", elapsed_s=round(time.monotonic() - started, 1))
                    break
                try:
                    chunk = resp.read1(CHUNK)
                except socket.timeout:
                    log("upstream_idle_timeout")
                    break
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                sent += len(chunk)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            self.close_connection = True
            return 200, sent
        finally:
            conn.close()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16


def make_server(cfg, bind_host="0.0.0.0"):
    server = Server((bind_host, cfg.listen_port), Handler)
    server.relay_state = RelayState(cfg)
    return server


def load_config(stream):
    line = stream.readline()
    if not line:
        raise ValueError("no config on stdin")
    return RelayConfig(json.loads(line))


def main():
    try:
        cfg = load_config(sys.stdin)
    except (ValueError, json.JSONDecodeError) as e:
        sys.stderr.write(f"relay: bad config: {e}\n")
        return 2
    try:
        sys.stdin.close()
    except OSError:
        pass
    server = make_server(cfg)
    st = server.relay_state
    stopping = threading.Event()

    def stop(_signum=None, _frame=None):
        if not stopping.is_set():
            stopping.set()
            threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    lifetime = threading.Timer(cfg.lifetime_s, lambda: (log("lifetime_expired"), stop()))
    lifetime.daemon = True
    lifetime.start()
    sys.stdout.write(f"relay ready port={cfg.listen_port}\n")
    sys.stdout.flush()
    log(
        "config",
        model=cfg.model_id,
        upstream_host=cfg.host,
        upstream_port=cfg.port,
        max_body_bytes=cfg.max_body_bytes,
        max_concurrent=cfg.max_concurrent,
        max_requests=cfg.max_requests,
        request_deadline_s=cfg.request_deadline_s,
        idle_timeout_s=cfg.idle_timeout_s,
        lifetime_s=cfg.lifetime_s,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        sys.stdout.write(json.dumps(st.summary(), separators=(",", ":")) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
