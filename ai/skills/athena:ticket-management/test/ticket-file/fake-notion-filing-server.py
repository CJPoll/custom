#!/usr/bin/env python3
"""fake-notion-filing-server.py -- a STATEFUL loopback stand-in for the
Notion requests scripts/ticket-file makes (DND-1669). Test fixture for
e2e_test.rb beside it; never prod.

  POST  /v1/pages                    stores the page and its children, answers
                                     the page with ID DND-<number>
  PATCH /v1/blocks/<id>/children     appends to the stored page
  GET   /v1/blocks/<id>/children?... answers the stored blocks, 100 a page,
                                     following start_cursor

Spec files in SPEC_DIR change one answer: create.json, append.json or
read.json ({"status": N, "body": {...}}) answers that request with it instead
(an append or create is then NOT stored); mangle.json ({"from": S, "to": T})
replaces S with T in every block text read back (Notion storing something
other than what was sent); number.json ({"number": N}) is the next ID.
ANY other method or path is logged "unexpected": true and answered 405.

While each request is in flight it scans every other process's
/proc/<pid>/cmdline and /proc/<pid>/environ for the token and logs the pids
where it appears: the proof no token reaches argv or env.

Usage: fake-notion-filing-server.py PORT_FILE LOG_FILE SPEC_DIR TOKEN_FILE
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG_FILE, SPEC_DIR, TOKEN_FILE = sys.argv[1:5]
with open(TOKEN_FILE, "rb") as fh:
    TOKEN = fh.read().strip()
ME = os.getpid()
PAGE_ID = "b0000000-0000-4000-8000-000000001669"
PAGES = {}

APPEND = re.compile(r"\A/v1/blocks/([0-9a-f-]{36})/children\Z")
READ = re.compile(r"\A/v1/blocks/([0-9a-f-]{36})/children\?page_size=(\d+)(?:&start_cursor=([0-9a-f-]{36}))?\Z")


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
        return None


def stored(block):
    kind = block.get("type")
    items = block.get(kind, {}).get("rich_text", [])
    text = [{"type": "text", "plain_text": i.get("text", {}).get("content", "")} for i in items]
    return {"object": "block", "type": kind, kind: {"rich_text": text}}


def read_view(block):
    m = spec("mangle.json")
    if not m:
        return block
    kind = block["type"]
    items = [dict(i, plain_text=i["plain_text"].replace(m["from"], m["to"])) for i in block[kind]["rich_text"]]
    return {"object": "block", "type": kind, kind: {"rich_text": items}}


def cursor(index):
    return "c0000000-0000-4000-8000-%012d" % index


def route(method, path, body):
    if method == "POST" and path == "/v1/pages":
        s = spec("create.json")
        if s:
            return s
        num = (spec("number.json") or {}).get("number", 1669)
        PAGES[PAGE_ID] = [stored(b) for b in (body or {}).get("children", [])]
        return {"status": 200, "body": {"object": "page", "id": PAGE_ID, "url": "https://example.invalid/p/" + PAGE_ID.replace("-", ""),
                                         "properties": {"ID": {"type": "unique_id", "unique_id": {"prefix": "DND", "number": num}}}}}
    m = APPEND.match(path)
    if method == "PATCH" and m and m.group(1) in PAGES:
        s = spec("append.json")
        if s:
            return s
        PAGES[m.group(1)].extend(stored(b) for b in (body or {}).get("children", []))
        return {"status": 200, "body": {"object": "list", "results": []}}
    r = READ.match(path)
    if method == "GET" and r and r.group(1) in PAGES:
        s = spec("read.json")
        if s:
            return s
        size = int(r.group(2))
        start = int(r.group(3)[-12:]) if r.group(3) else 0
        blocks = PAGES[r.group(1)]
        page = [read_view(b) for b in blocks[start:start + size]]
        more = start + size < len(blocks)
        return {"status": 200, "body": {"object": "list", "results": page, "has_more": more,
                                         "next_cursor": cursor(start + size) if more else None}}
    return None


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
        answer = route(self.command, self.path, body)
        auth = self.headers.get("Authorization") or ""
        entry = {
            "unexpected": answer is None,
            "method": self.command,
            "path": self.path,
            "auth_ok": auth == "Bearer " + TOKEN.decode(),
            "notion_version": self.headers.get("Notion-Version"),
            "body": body,
            "argv_leak": scan("cmdline"),
            "environ_leak": scan("environ"),
        }
        with open(LOG_FILE, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
        if answer is None:
            answer = {"status": 405, "body": {"message": "unexpected"}}
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
