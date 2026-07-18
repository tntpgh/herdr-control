#!/usr/bin/env python3
"""Minimal JSON-RPC client for the herdr Unix socket.

herdr's CLI exposes most of its API, but a few methods (notably `tab.move`,
which reorders tabs) have no CLI verb. This talks the socket protocol directly:
newline-delimited JSON, request `{"id","method","params"}` -> reply `{"id","result"|"error"}`.

The socket also pushes unsolicited event lines (e.g. `tab_moved`) interleaved
with replies, so we read line by line and return the first line whose `id`
matches our request — ignoring events.

    herdr-rpc.py <method> '<json-params>'
    herdr-rpc.py tab.move '{"tab_id":"w1:t3","insert_index":0}'

Prints the `result` object on success (exit 0); the `error` object to stderr on
failure (exit 1). Socket path from $HERDR_SOCK (default ~/.config/herdr/herdr.sock).
"""
import socket, os, json, sys

SOCK = os.path.expanduser(os.environ.get("HERDR_SOCK", "~/.config/herdr/herdr.sock"))


def rpc(method, params, rid="herdr-control"):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(float(os.environ.get("HERDR_RPC_TIMEOUT", "8")))
    s.connect(SOCK)
    s.sendall((json.dumps({"id": rid, "method": method, "params": params}) + "\n").encode())
    buf = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == rid:  # our reply, not an event
                    return msg
    finally:
        s.close()
    raise RuntimeError("herdr socket closed with no matching reply")


def main():
    if len(sys.argv) < 2:
        print("usage: herdr-rpc.py <method> [json-params]", file=sys.stderr)
        sys.exit(2)
    method = sys.argv[1]
    params = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else {}
    msg = rpc(method, params)
    if "error" in msg:
        print(json.dumps(msg["error"]), file=sys.stderr)
        sys.exit(1)
    print(json.dumps(msg.get("result", {})))


if __name__ == "__main__":
    main()
