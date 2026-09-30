#!/usr/bin/env python3
"""fake-judgments-server.py -- a loopback stand-in for the judgments eval
endpoints (DND-710): POST /api/v1/judgments/eval and
PUT /api/v1/judgments/thresholds.

Test fixture for ai/test/judgment-eval/self-test.sh. It is NOT the server (that
is gen_saas Athena.Judgments.Evals). Each request's answer comes from a
RESPONSES file: one spec (answered every time) or a JSON array (a queue; the
last spec keeps answering). A spec is either

  {"status": N, "body": {...}}      answered as is, or
  {"auto": "not_configured"}       200: every case in the request unscored
                                    not_configured, report scored 0 (what the
                                    real server answers with no key).

While each request is in flight it scans every other process's
/proc/<pid>/cmdline and /proc/<pid>/environ for the machine token and logs the
pids where it appears: the suite's proof the token never reaches argv or env.

POST /api/v1/judgments/slack_routing/context (DND-1048) answers from its own
CONTEXT_RESPONSES file (optional fifth argument), the same spec shapes, plus

  {"auto": "context"}              200: of the request's last 6 candidates,
                                    the owner's as owner entries, with the
                                    version, rules and owner id the real
                                    server returns (a stand-in for its
                                    selection).

Its default, when the file is absent, is {"auto": "context"}.

Usage: FAKE_OWNER_SLACK_USER_ID=U... fake-judgments-server.py PORT_FILE LOG_FILE RESPONSES_FILE TOKEN_FILE [CONTEXT_RESPONSES_FILE]
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG_FILE, RESPONSES_FILE, TOKEN_FILE = sys.argv[1:5]
CONTEXT_FILE = sys.argv[5] if len(sys.argv) > 5 else None
CONTEXT_PATH = "/api/v1/judgments/slack_routing/context"
# The owner id the real server reads from the owner's Slack app. It is a work
# value, so the suite passes a SYNTHETIC one, the same one its fixture private
# overlay gives judgment-eval (never the real id: this repo is public).
OWNER = os.environ.get("FAKE_OWNER_SLACK_USER_ID", "")
if not OWNER:
    sys.exit("fake-judgments-server: FAKE_OWNER_SLACK_USER_ID is unset. "
             "Fix: export a synthetic owner id (e.g. UFAKE00001) before starting it.")
with open(TOKEN_FILE, "rb") as fh:
    TOKEN = fh.read().strip()
ME = os.getpid()
RUN_ID = "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"


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


def next_spec(path, default):
    try:
        with open(path) as fh:
            spec = json.load(fh)
    except (OSError, TypeError, ValueError):
        return default
    if isinstance(spec, list):
        head = spec[0]
        if len(spec) > 1:
            with open(path + ".tmp", "w") as fh:
                json.dump(spec[1:], fh)
            os.rename(path + ".tmp", path)
        return head
    return spec


def auto_context(body):
    candidates = body.get("candidates", []) if isinstance(body, dict) else []
    window = candidates[-6:]
    entries = [{"from": "owner", "text": c.get("text")} for c in window if c.get("user") == OWNER]
    return {
        "context": entries,
        "counts": {"owner": len(entries), "athena": 0, "not_owner": len(window) - len(entries)},
        "question_set_version": "slack-routing-v2",
        "rules": {"window_s": 3600, "max_entries": 6, "max_text": 500},
        "owner_slack_user_id": OWNER,
    }


def not_configured(body):
    cases = body.get("cases", []) if isinstance(body, dict) else []
    results = [{"case_id": c.get("case_id"), "outcome": "unscored", "reason": "not_configured"} for c in cases]
    return {
        "data": {
            "eval_run_id": body.get("eval_run_id", RUN_ID),
            "use_case": body.get("use_case"),
            "question_set_version": "v1",
            "model": "jev-1.13.0",
            "results": results,
            "report": {"cases": len(cases), "scored": 0, "unscored": {"not_configured": len(cases)}, "labels": []},
        }
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.answer()

    def do_PUT(self):
        self.answer()

    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        auth = self.headers.get("Authorization") or ""
        entry = {
            "method": self.command,
            "path": self.path,
            "auth_ok": auth == "Bearer " + TOKEN.decode(),
            "body": body,
            "argv_leak": scan("cmdline"),
            "environ_leak": scan("environ"),
        }
        with open(LOG_FILE, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
        if self.path == CONTEXT_PATH:
            spec = next_spec(CONTEXT_FILE, {"auto": "context"})
        else:
            spec = next_spec(RESPONSES_FILE, {"auto": "not_configured"})
        if spec.get("auto") == "not_configured":
            status, payload = 200, not_configured(body or {})
        elif spec.get("auto") == "context":
            status, payload = 200, auto_context(body or {})
        else:
            status, payload = int(spec.get("status", 200)), spec.get("body", {})
        data = json.dumps(payload).encode()
        self.send_response(status)
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
