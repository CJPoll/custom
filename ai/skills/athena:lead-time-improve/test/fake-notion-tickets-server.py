#!/usr/bin/env python3
"""A fake DND Tickets for scripts/unmeasurable's suite (DND-1806). Never prod.

Usage: fake-notion-tickets-server.py <port-file> <log-file> <tickets-json> <token-file>

<tickets-json> is re-read on every request, so a test flips a ticket's state
by rewriting it: {"<number>": {"id": <uuid>, "status": <name>, "path": <name|null>},
"fail": <http status or absent>}. Every request is logged as one JSON line:
{"method", "path", "body"}. Only the three calls the tool may make are
answered; anything else is 400, so a widened write shows up as a failure.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, LOG, TICKETS, TOKEN_FILE = sys.argv[1:5]
TOKEN = open(TOKEN_FILE).read().strip()
UUID = r"[0-9a-f-]{36}"


def tickets():
    with open(TICKETS) as f:
        return json.load(f)


def save(doc):
    with open(TICKETS, "w") as f:
        json.dump(doc, f)


def page(number, t):
    return {
        "object": "page",
        "id": t["id"],
        "properties": {
            "ID": {"type": "unique_id", "unique_id": {"prefix": "DND", "number": int(number)}},
            "Status": {"type": "status", "status": {"name": t["status"]}},
            "Path": {"type": "select", "select": ({"name": t["path"]} if t.get("path") else None)},
        },
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": method, "path": self.path, "body": body}) + "\n")
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.answer(401, {"message": "bad token"})
        doc = tickets()
        if doc.get("fail"):
            return self.answer(int(doc["fail"]), {"message": "injected failure"})
        if method == "POST" and re.fullmatch(r"/v1/data_sources/" + UUID + r"/query", self.path):
            number = str(body["filter"]["unique_id"]["equals"])
            t = doc.get(number)
            return self.answer(200, {"results": [page(number, t)] if t else [], "has_more": False})
        m = re.fullmatch(r"/v1/pages/(" + UUID + ")", self.path)
        if method == "PATCH" and m:
            if body != {"properties": {"Path": {"select": {"name": "Promoted"}}}}:
                return self.answer(400, {"message": "unexpected page PATCH body"})
            for number, t in doc.items():
                if isinstance(t, dict) and t.get("id") == m.group(1):
                    t["path"] = "Promoted"
                    save(doc)
                    return self.answer(200, page(number, t))
            return self.answer(404, {"message": "no such page"})
        if method == "PATCH" and re.fullmatch(r"/v1/blocks/" + UUID + r"/children", self.path):
            return self.answer(200, {"results": body.get("children", [])})
        return self.answer(400, {"message": "not a call this tool may make"})

    def do_POST(self):
        self.handle_any("POST")

    def do_PATCH(self):
        self.handle_any("PATCH")

    def do_GET(self):
        self.handle_any("GET")


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
import os  # noqa: E402

os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
