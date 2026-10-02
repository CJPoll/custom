#!/usr/bin/env python3
"""fake-notion-server.py -- a loopback stand-in for the three Notion READS
ai/bin/triage-corpus makes (DND-714). Test fixture only, never Notion.

  POST /v1/data_sources/<projects>/query   the DND Projects rows
  POST /v1/data_sources/<tickets>/query    two pages, joined by a cursor
  GET  /v1/blocks/<page>/children          a page's blocks; the page id
                                           ending "0403" always answers 403;
                                           page 3 says has_more (truncated);
                                           LOG_FILE.all_401 present: every
                                           block read answers 401

Every request is logged as "METHOD PATH AUTH_OK" to LOG_FILE, so the suite can
assert that only reads were made and that the token was sent.

Usage: fake-notion-server.py PORT_FILE LOG_FILE TOKEN_FILE
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG_FILE, TOKEN_FILE = sys.argv[1:4]
with open(TOKEN_FILE) as fh:
    TOKEN = fh.read().strip()

PROJECTS = "3e2349da-87fb-809a-a93e-000b167fd855"
TICKETS = "219349da-87fb-8063-8f36-000b362fbd60"
E_HARNESS = "e0000000-0000-0000-0000-000000000001"
E_WALT = "e0000000-0000-0000-0000-000000000002"


def page(n):
    return "a0000000-0000-0000-0000-00000000%04d" % n


def ticket(n, epic, area, rel=None):
    rel = rel or {}
    props = {
        "ID": {"unique_id": {"prefix": "DND", "number": n}},
        "Name": {"title": [{"plain_text": "Ticket %d title" % n}]},
        "Status": {"status": {"name": "Todo"}},
        "Area": {"select": {"name": area}},
        "Severity": {"select": None},
        "Epic": {"relation": [{"id": epic}] if epic else [], "has_more": False},
        "Depends On": {"relation": [{"id": page(x)} for x in rel.get("depends", [])], "has_more": False},
        "Blocks": {"relation": [], "has_more": False},
        "Found while": {"relation": [], "has_more": False},
    }
    # DND-1055: Kind, Security and the page's created_time (ticket-corpus).
    props["Kind"] = {"select": {"name": "Bug"}}
    props["Security"] = {"select": {"name": "none"}}
    # DND-1057: Path (ticket-corpus ticket_blocking labels).
    props["Path"] = {"select": {"name": "Off"}}
    return {"id": page(n), "created_time": "2026-09-28T01:00:00.000Z", "properties": props}


REPO_APPS = ["gen_saas / Athena", "gen_saas/apps/athena", "~/dev/custom", "walt_ui",
             "gen_saas/apps/dnd", "gen_saas/apps/lms"]


def project_rows():
    # LOG_FILE.drop_walt present: omit the walt_ui row (a stale REPO_APPS map).
    drop = os.path.exists(LOG_FILE + ".drop_walt")
    rows = []
    for app in REPO_APPS:
        if drop and app == "walt_ui":
            continue
        epics = [E_HARNESS] if app == "~/dev/custom" else ([E_WALT] if app == "walt_ui" else [])
        rows.append({"properties": {"Repo / App": {"select": {"name": app}},
                                    "Epics": {"relation": [{"id": e} for e in epics], "has_more": False}}})
    return rows


PAGE1 = [ticket(1, E_HARNESS, "Harness"), ticket(2, E_HARNESS, "Harness")]
PAGE2 = [ticket(3, E_HARNESS, "Product", {"depends": [1]}), ticket(403, E_HARNESS, "Harness"),
         {"id": page(9999), "properties": {"ID": {"unique_id": {"prefix": "X", "number": 1}}}}]
BLOCKS = {
    page(1): ["Base defect in the widget."],
    page(2): ["Duplicate of DND-1.", "Same widget defect."],
    page(3): ["Needs the widget fix."],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _log(self):
        auth = self.headers.get("Authorization") == "Bearer " + TOKEN
        with open(LOG_FILE, "a") as fh:
            fh.write("%s %s %s\n" % (self.command, self.path, "AUTH_OK" if auth else "AUTH_BAD"))

    def _send(self, status, doc, extra=None):
        body = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self._log()
        length = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/v1/data_sources/%s/query" % PROJECTS:
            return self._send(200, {"results": project_rows(), "has_more": False})
        if self.path == "/v1/data_sources/%s/query" % TICKETS:
            if req.get("start_cursor") == "c2":
                return self._send(200, {"results": PAGE2, "has_more": False, "next_cursor": None})
            return self._send(200, {"results": PAGE1, "has_more": True, "next_cursor": "c2"})
        return self._send(404, {"object": "error"})

    def do_GET(self):
        self._log()
        pid = self.path.split("/")[3] if self.path.startswith("/v1/blocks/") else ""
        if os.path.exists(LOG_FILE + ".all_401"):
            return self._send(401, {"object": "error"})
        # A permanent failure, never retried, so no real retry wait runs in the
        # suite. The retried 429/5xx path is proven with an injected wait in
        # ai/lib/test/notion-read (DND-1649).
        if pid.endswith("0403"):
            return self._send(403, {"object": "error"})
        texts = BLOCKS.get(pid, [])
        results = [{"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": t}]}} for t in texts]
        # page 3's body has a second page of blocks (the fetch reads only one).
        return self._send(200, {"results": results, "has_more": pid == page(3)})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
