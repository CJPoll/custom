#!/usr/bin/env python3
"""fake-scan-server.py -- one loopback stand-in for Notion's reads and the
Athena server's feedback POST, for `judgment-feedback scan-tickets`'s suite
(DND-1469). Test fixture only: never Notion, never the Athena server.

A failed read answers 400, a permanent failure NotionRead never retries, so
no real retry wait runs in this suite. The retried 429/5xx path is proven with
an injected wait in ai/lib/test/notion-read (DND-1649).

  POST /v1/data_sources/<id>/query      FIXTURE.rows (one page)
  GET  /v1/blocks/<page>/children[?..]  FIXTURE.blocks[page]: a list of block
                                        pages joined by cursors; a page id in
                                        FIXTURE.fail_blocks answers 400
  GET  /v1/pages/<page>                 a page whose DND id is
                                        FIXTURE.pages[page], or none when
                                        that is null (DND-1470: a
                                        Blocks target); a page id in
                                        FIXTURE.fail_pages answers 400
  POST /api/v1/judgments/feedback       an upsert per call_id, as the server
                                        keeps one row per (call, reporter):
                                        the first report is recorded, a later
                                        one replaced. A call in FIXTURE.refuse
                                        answers that spec; FIXTURE.post_status
                                        (when set) answers every POST with it.

Each request is logged to LOG_FILE as one JSON line: method, path, body and
which token it carried ("notion", "athena" or "bad"). Any other request
answers 404 and is logged "unexpected": true.

The port is printed on stdout once listening, so the suite blocks on that
line instead of polling.

Usage: fake-scan-server.py LOG_FILE FIXTURE
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOG_FILE, FIXTURE = sys.argv[1:3]
with open(FIXTURE) as fh:
    FX = json.load(fh)
STORED = {}


def cursor(n):
    return "c0000000-0000-0000-0000-%012d" % n


def feedback_id(call_id):
    return "f" + call_id[1:]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _who(self):
        auth = self.headers.get("Authorization") or ""
        if auth == "Bearer " + FX["notion_token"]:
            return "notion"
        if auth == "Bearer " + FX["athena_token"]:
            return "athena"
        return "bad"

    def _send(self, status, body, entry):
        with open(LOG_FILE, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _entry(self, body=None, unexpected=False):
        return {"method": self.command, "path": self.path, "body": body, "auth": self._who(),
                "unexpected": unexpected}

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            req = None
        entry = self._entry(req)
        if url.path.startswith("/v1/data_sources/") and url.path.endswith("/query"):
            return self._send(200, {"results": FX["rows"], "has_more": False, "next_cursor": None}, entry)
        if url.path == "/api/v1/judgments/feedback":
            if FX.get("post_status"):
                return self._send(FX["post_status"], {"error": "boom"}, entry)
            call = (req or {}).get("call_id", "")
            refusal = FX.get("refuse", {}).get(call)
            if refusal:
                return self._send(refusal["status"], refusal["body"], entry)
            replaced = call in STORED
            STORED[call] = req
            return self._send(200, {"status": "recorded", "feedback_id": feedback_id(call), "call_id": call,
                                    "replaced": replaced}, entry)
        entry["unexpected"] = True
        return self._send(404, {"object": "error"}, entry)

    def do_GET(self):
        url = urlparse(self.path)
        parts = url.path.split("/")
        entry = self._entry()
        if len(parts) >= 5 and parts[2] == "blocks" and parts[4] == "children":
            page = parts[3]
            if page in FX.get("fail_blocks", []):
                return self._send(400, {"object": "error"}, entry)
            pages = FX["blocks"].get(page, [[]])
            start = parse_qs(url.query).get("start_cursor", [None])[0]
            idx = int(start[-12:]) if start else 0
            more = idx + 1 < len(pages)
            return self._send(200, {"results": pages[idx], "has_more": more,
                                    "next_cursor": cursor(idx + 1) if more else None}, entry)
        if len(parts) == 4 and parts[2] == "pages" and parts[3] in FX.get("pages", {}):
            if parts[3] in FX.get("fail_pages", []):
                return self._send(400, {"object": "error"}, entry)
            number = FX["pages"][parts[3]]
            props = {"ID": {"unique_id": {"prefix": "DND", "number": number}}} if number is not None else {}
            return self._send(200, {"object": "page", "id": parts[3], "properties": props}, entry)
        entry["unexpected"] = True
        return self._send(404, {"object": "error"}, entry)

    def do_PATCH(self):
        entry = self._entry(unexpected=True)
        return self._send(405, {"object": "error"}, entry)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
sys.stdout.write("%d\n" % server.server_address[1])
sys.stdout.flush()
server.serve_forever()
