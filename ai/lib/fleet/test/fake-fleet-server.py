#!/usr/bin/env python3
"""fake-fleet-server.py -- a loopback stand-in for POST /api/v1/fleet/reports.

Test fixture for the fleet-report suites (DND-433). It is NOT the server: the
real one is DND-431. It answers the way the contract says the real one does
(ai/contracts/athena-events.md -> Fleet registry and session control):
202 on success, 422 {"error","fix"} on a refusal, 404 {"error":"not_found"},
401 {"error":"unauthorized","fix"}, with the answer chosen per request by the
test through a JSON "responses" file.

While each request is IN FLIGHT (the client is still waiting), it scans every
other process's /proc/<pid>/cmdline and /proc/<pid>/environ for the machine
token and logs the pids where it appears. That is how the suite proves the
token never reaches argv (or the environment) of fleet-report or curl.

Usage: fake-fleet-server.py PORT_FILE LOG_FILE RESPONSES_FILE TOKEN_FILE
The token is read from a FILE, never argv, so this process's own cmdline does
not carry it either.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG_FILE, RESPONSES_FILE, TOKEN_FILE = sys.argv[1:5]
with open(TOKEN_FILE, "rb") as fh:
    TOKEN = fh.read().strip()
ME = os.getpid()


def scan(name):
    hits = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == ME:
            continue
        try:
            with open(f"/proc/{pid}/{name}", "rb") as fh:
                if TOKEN in fh.read():
                    hits.append(int(pid))
        except OSError:
            pass
    return hits


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw.decode("utf-8", "replace")
        auth = self.headers.get("Authorization") or ""
        entry = {
            "path": self.path,
            "auth_ok": auth == "Bearer " + TOKEN.decode(),
            "auth_present": bool(auth),
            "content_type": self.headers.get("Content-Type"),
            "body": body,
            "argv_leak": scan("cmdline"),
            "environ_leak": scan("environ"),
        }
        try:
            with open(RESPONSES_FILE) as fh:
                spec = json.load(fh)
        except (OSError, ValueError):
            spec = {"status": 202, "body": {"ok": True}}
        with open(LOG_FILE, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
        time.sleep(float(spec.get("delay_s", 0)))
        status = int(spec.get("status", 202))
        payload = spec.get("raw_body")
        if payload is None:
            payload = json.dumps(spec.get("body", {}))
            ctype = "application/json"
        else:
            ctype = "text/html"
        data = payload.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(PORT_FILE + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
