#!/usr/bin/env python3
"""fake-triage-server.py -- ONE loopback stand-in for both services the
finding-triage script talks to (DND-713). Test fixture for
ai/skills/athena:ticket-management/test/self-test.sh; never prod.

  Notion (reads only):
    POST /v1/data_sources/<id>/query      answered from SPEC_DIR/query-<id>.json
    GET  /v1/blocks/<id>/children?...     answered from SPEC_DIR/blocks.json
  Athena:
    POST /api/v1/judgments/finding_triage answered from SPEC_DIR/triage.json
    POST /api/v1/judgments/ticket_classification
                                          answered from SPEC_DIR/classify.json
                                          (ticket-classify, DND-1054)

A spec file is {"status": N, "body": {...}}, or {"status": N, "raw": "..."}
to answer a body that is not JSON. A missing spec is a 599, so a
test that forgot one fails loudly. ANY other method or path is logged with
"unexpected": true and answered 405: the suite asserts none happened (there
is no code path to a Notion write).

While each request is in flight it scans every other process's
/proc/<pid>/cmdline and /proc/<pid>/environ for BOTH tokens and logs the pids
where one appears: the proof no token reaches argv or env.

Usage: fake-triage-server.py PORT_FILE LOG_FILE SPEC_DIR ATHENA_TOKEN_FILE NOTION_TOKEN_FILE
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG_FILE, SPEC_DIR, ATHENA_TOKEN_FILE, NOTION_TOKEN_FILE = sys.argv[1:6]
TOKENS = {}
for name, path in (("athena", ATHENA_TOKEN_FILE), ("notion", NOTION_TOKEN_FILE)):
    with open(path, "rb") as fh:
        TOKENS[name] = fh.read().strip()
ME = os.getpid()

QUERY = re.compile(r"\A/v1/data_sources/([0-9a-f-]{36})/query\Z")
BLOCKS = re.compile(r"\A/v1/blocks/[0-9a-f-]{36}/children\?page_size=\d+\Z")


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
        for token in TOKENS.values():
            if token and token in data:
                hits.append(int(pid))
    return hits


def spec(name):
    try:
        with open(os.path.join(SPEC_DIR, name)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"status": 599, "body": {"error": "no spec " + name}}


def route(method, path):
    m = QUERY.match(path)
    if method == "POST" and m:
        return "notion", spec("query-" + m.group(1) + ".json")
    if method == "GET" and BLOCKS.match(path):
        return "notion", spec("blocks.json")
    if method == "POST" and path == "/api/v1/judgments/finding_triage":
        return "athena", spec("triage.json")
    if method == "POST" and path == "/api/v1/judgments/ticket_classification":
        return "athena", spec("classify.json")
    return None, {"status": 405, "body": {"error": "unexpected"}}


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
        service, answer = route(self.command, self.path)
        auth = self.headers.get("Authorization") or ""
        expected = TOKENS.get(service, b"").decode()
        entry = {
            "service": service,
            "unexpected": service is None,
            "method": self.command,
            "path": self.path,
            "auth_ok": bool(expected) and auth == "Bearer " + expected,
            "notion_version": self.headers.get("Notion-Version"),
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
with open(PORT_FILE + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
