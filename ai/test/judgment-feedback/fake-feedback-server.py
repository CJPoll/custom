#!/usr/bin/env python3
"""fake-feedback-server.py -- a loopback stand-in for the Athena server's
receiver feedback surfaces (DND-1462), for ai/bin/judgment-feedback's suite
(DND-1466). Test fixture; never prod.

    POST /api/v1/judgments/feedback       answered from SPEC_DIR/post.json
    GET  /api/v1/judgments/feedback?...   the Nth GET is answered from
                                          SPEC_DIR/get-N.json (1-based)

A spec file is {"status": N, "body": {...}}, or {"status": N, "raw": "..."}
for a body that is not JSON. A missing spec is a 599, so a test that forgot
one fails loudly. Any other method or path is logged "unexpected": true and
answered 405.

Each request is logged as one JSON line: method, path, query, body, whether
the bearer token matched, and the pids whose /proc/<pid>/cmdline or
/proc/<pid>/environ held the token while the request was in flight (the
proof the token never reaches argv or the environment).

The port is printed on stdout once listening, so the suite blocks on that
line instead of polling.

Usage: fake-feedback-server.py LOG_FILE SPEC_DIR TOKEN_FILE
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOG_FILE, SPEC_DIR, TOKEN_FILE = sys.argv[1:4]
with open(TOKEN_FILE, "rb") as fh:
    TOKEN = fh.read().strip()
ME = os.getpid()
GETS = {"n": 0}
ROUTE = "/api/v1/judgments/feedback"


def scan(name):
    hits = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == ME:
            continue
        try:
            with open(f"/proc/{pid}/{name}", "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if TOKEN and TOKEN in data:
            hits.append(int(pid))
    return hits


def spec(name):
    try:
        with open(os.path.join(SPEC_DIR, name)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"status": 599, "body": {"error": "no spec " + name}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.answer()

    def do_POST(self):
        self.answer()

    def do_PATCH(self):
        self.answer()

    def do_PUT(self):
        self.answer()

    def do_DELETE(self):
        self.answer()

    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = None
        parts = urlsplit(self.path)
        unexpected = parts.path != ROUTE or self.command not in ("GET", "POST")
        if unexpected:
            answer = {"status": 405, "body": {"error": "unexpected"}}
        elif self.command == "POST":
            answer = spec("post.json")
        else:
            GETS["n"] += 1
            answer = spec("get-%d.json" % GETS["n"])
        auth = self.headers.get("Authorization") or ""
        entry = {
            "unexpected": unexpected,
            "method": self.command,
            "path": parts.path,
            "query": {k: v[0] for k, v in parse_qs(parts.query).items()},
            "auth_ok": bool(TOKEN) and auth == "Bearer " + TOKEN.decode(),
            "body": body,
            "argv_leak": scan("cmdline"),
            "environ_leak": scan("environ"),
        }
        with open(LOG_FILE, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
        if "raw" in answer:
            data = str(answer["raw"]).encode()
        else:
            data = json.dumps(answer.get("body", {})).encode()
        self.send_response(int(answer.get("status", 200)))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
sys.stdout.write("%d\n" % server.server_address[1])
sys.stdout.flush()
server.serve_forever()
