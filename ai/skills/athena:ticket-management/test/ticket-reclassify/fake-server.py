#!/usr/bin/env python3
"""fake-server.py -- one loopback stand-in for Notion's reads and the Athena
classification endpoint, for the ticket-reclassify suite (DND-1056). Test
fixture only: never Notion, never the Athena server.

  POST /v1/data_sources/<id>/query          FIXTURE.data_sources[id]
  GET  /v1/blocks/<page>/children[?...]      FIXTURE.blocks[page]: a list of
                                             block pages, joined by cursors
  GET  /v1/pages/<page>                      FIXTURE.pages[page]
  POST /api/v1/judgments/ticket_classification
                                             FIXTURE.answers[ticket.ref]

Every request is logged to LOG_FILE as "METHOD PATH AUTH_OK|AUTH_BAD", so the
suite can assert that only reads reached Notion and that each side got its own
token. Any other request answers 404 (and is logged).

Usage: fake-server.py PORT_FILE LOG_FILE FIXTURE
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT_FILE, LOG_FILE, FIXTURE = sys.argv[1:4]
with open(FIXTURE) as fh:
    FX = json.load(fh)


def cursor(n):
    return "c0000000-0000-0000-0000-%012d" % n


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _log(self, token):
        auth = self.headers.get("Authorization") == "Bearer " + token
        with open(LOG_FILE, "a") as fh:
            fh.write("%s %s %s\n" % (self.command, self.path, "AUTH_OK" if auth else "AUTH_BAD"))

    def _send(self, status, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(length) or b"{}")
        if url.path.startswith("/v1/data_sources/"):
            self._log(FX["notion_token"])
            rows = FX["data_sources"].get(url.path.split("/")[3])
            if rows is None:
                return self._send(404, {"object": "error"})
            return self._send(200, {"results": rows, "has_more": False, "next_cursor": None})
        if url.path == "/api/v1/judgments/ticket_classification":
            self._log(FX["athena_token"])
            answer = FX["answers"].get(req.get("ticket", {}).get("ref", ""))
            if answer is None:
                return self._send(500, {"error": "no_fixture"})
            return self._send(200, answer.encode())
        self._log("")
        return self._send(404, {"object": "error"})

    def do_GET(self):
        self._log(FX["notion_token"])
        url = urlparse(self.path)
        parts = url.path.split("/")
        if len(parts) >= 5 and parts[2] == "blocks" and parts[4] == "children":
            pages = FX["blocks"].get(parts[3])
            if pages is None:
                return self._send(404, {"object": "error"})
            start = parse_qs(url.query).get("start_cursor", [None])[0]
            idx = int(start[-12:]) if start else 0
            more = idx + 1 < len(pages)
            return self._send(200, {"results": pages[idx], "has_more": more,
                                    "next_cursor": cursor(idx + 1) if more else None})
        if len(parts) == 4 and parts[2] == "pages":
            page = FX["pages"].get(parts[3])
            if page is None:
                return self._send(404, {"object": "error"})
            return self._send(200, page)
        return self._send(404, {"object": "error"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
