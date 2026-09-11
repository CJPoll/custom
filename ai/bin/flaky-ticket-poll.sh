#!/bin/sh
# flaky-ticket-poll.sh — SessionStart poll for the flaky-test lane.
#
# On SessionStart it queries the walt_ui "Tickets" Notion DB for QUEUED,
# flaky-labelled tickets ASSIGNED TO THIS MACHINE'S OWNER, dedups against a
# seen-file, and — if there are undispatched ones AND no athena-admiral is
# currently running — emits a SessionStart `additionalContext` payload stating
# that fact. Silent otherwise. Fails soft (never noisy on transient errors or
# missing config).
#
# OUTPUT CONTRACT (per the hooks docs): on exit 0 this prints a single JSON
# object
#   {"hookSpecificOutput":{"hookEventName":"SessionStart",
#                          "additionalContext":"<factual text>"}}
# SessionStart additionalContext is injected into the session before the first
# prompt. The injected text is FACTUAL STATE ONLY — never an imperative/out-of-
# band command (imperative phrasing trips prompt-injection defenses and gets
# surfaced to the user instead of used as context). The ACTION to take on this
# state (spawn a singleton athena-admiral, etc.) lives in CLAUDE.md, which loads
# without a script; the detailed brief is flaky-coordinator-spawn.txt.
#
# MECHANISM: a hook is a shell script and CANNOT spawn an agent. It only reports
# state; the model decides what to do per the CLAUDE.md policy.
#
# SINGLETON: the user runs a single Claude instance in the main worktree, so no
# flock is needed. An athena-admiral, when spawned, touches ~/.claude/flaky-
# coordinator.lock and removes it when it finishes draining (see the recipe).
# This poll only READS that marker: while it is fresh, an athena-admiral is assumed
# to be draining and its own scope query will pick up any new ticket, so we emit
# nothing. A marker older than LOCK_STALE_MIN is treated as crashed and ignored.
#
# Usage:
#   flaky-ticket-poll.sh            # live: emit additionalContext + mark seen
#   flaky-ticket-poll.sh --dry-run  # print the JSON that WOULD be emitted;
#                                    # writes nothing to the seen-file and is
#                                    # NOT suppressed by the running-marker.
set -u

# --- config ---------------------------------------------------------------
SEEN="${HOME}/.claude/flaky-ticket-poll.seen"
TOKEN_FILE="${HOME}/.claude/notion-amby-token"   # notion-work (amby workspace) token
LOCK="${HOME}/.claude/flaky-coordinator.lock"
LOCK_STALE_MIN=720                               # 12h: self-heal a crashed run
DB="f00eab4f-26e1-4a97-8a2b-fd6a4a15323e"        # "Tickets" database
REPO_MATCH="walt_ui"                             # live-mode cwd guard token

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# --- live-mode cwd guard (skip in dry-run) --------------------------------
# SessionStart delivers JSON on stdin including "cwd". Only act when the session
# is in the walt_ui repo, so a user-level hook does not fire the walt_ui lane in
# unrelated projects. If stdin is a terminal (manual run) we skip the read.
if [ "$DRY_RUN" -eq 0 ] && [ ! -t 0 ]; then
  INPUT="$(cat 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)"
  if [ -n "$CWD" ]; then
    case "$CWD" in
      *"$REPO_MATCH"*) : ;;      # in the walt_ui repo — proceed
      *) exit 0 ;;               # some other project — stay quiet
    esac
  fi
fi

# --- identity (mirrors .claude/hooks/lib/agent-messages-identity.sh) -------
IDENTITY="${AGENT_MESSAGES_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f "$HOME/.claude/agent-messages-identity" ]; then
  IDENTITY="$(head -n1 "$HOME/.claude/agent-messages-identity" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$IDENTITY" ] && [ -f "${CLAUDE_PROJECT_DIR:-.}/.claude/agent-messages/identity" ]; then
  IDENTITY="$(head -n1 "${CLAUDE_PROJECT_DIR:-.}/.claude/agent-messages/identity" 2>/dev/null | tr -d '[:space:]')"
fi
[ -n "$IDENTITY" ] || exit 0

# --- roster: identity -> owner name + owner notion_person_id --------------
ROSTER=""
for cand in \
  "${CLAUDE_PROJECT_DIR:-}/.claude/agent-messages/roster.json" \
  "${HOME}/dev/walt_ui/.claude/agent-messages/roster.json"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { ROSTER="$cand"; break; }
done
[ -n "$ROSTER" ] || exit 0

OWNER_LINE="$(IDENTITY="$IDENTITY" python3 -c '
import sys,json,os
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
a=d.get("agents",{}).get(os.environ["IDENTITY"])
if not a: sys.exit(0)
pid=a.get("notion_person_id"); name=a.get("owner")
if pid and name: print("%s\t%s" % (pid, name))
' "$ROSTER" 2>/dev/null)"
[ -n "$OWNER_LINE" ] || exit 0
OWNER_ID="$(printf '%s' "$OWNER_LINE" | cut -f1)"
OWNER_NAME="$(printf '%s' "$OWNER_LINE" | cut -f2)"

# --- token ----------------------------------------------------------------
TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)" || exit 0
[ -n "$TOKEN" ] || exit 0
touch "$SEEN" 2>/dev/null || exit 0

# --- query: flaky-tests label + assigned to owner + queued (Todo/Backlog) --
RESP="$(curl -s --max-time 30 -X POST \
  "https://api.notion.com/v1/databases/${DB}/query" \
  -H "Authorization: Bearer $TOKEN" -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "{\"filter\":{\"and\":[
        {\"property\":\"Labels\",\"multi_select\":{\"contains\":\"flaky-tests\"}},
        {\"property\":\"Assignee\",\"people\":{\"contains\":\"${OWNER_ID}\"}},
        {\"or\":[{\"property\":\"Status\",\"status\":{\"equals\":\"Todo\"}},
                 {\"property\":\"Status\",\"status\":{\"equals\":\"Backlog\"}}]}
      ]},\"page_size\":50}" 2>/dev/null)" || exit 0

# --- decide + emit (all logic in python for one consistent code path) ------
printf '%s' "$RESP" | \
  SEEN="$SEEN" LOCK="$LOCK" LOCK_STALE_MIN="$LOCK_STALE_MIN" DRY_RUN="$DRY_RUN" \
  OWNER_NAME="$OWNER_NAME" \
  python3 -c '
import sys, json, os, time

seen_path = os.environ["SEEN"]
lock_path = os.environ["LOCK"]
stale_sec = int(os.environ["LOCK_STALE_MIN"]) * 60
dry       = os.environ["DRY_RUN"] == "1"
owner     = os.environ["OWNER_NAME"]

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
results = d.get("results")
if results is None:
    sys.exit(0)

seen = set(open(seen_path).read().split()) if os.path.exists(seen_path) else set()

undispatched = []
for p in results:
    pid = p["id"]
    if pid in seen:
        continue
    t = p["properties"]["Title"]["title"]
    title = t[0]["plain_text"] if t else "(untitled)"
    num = p["properties"].get("ID", {}).get("unique_id", {})
    pt = "PT-%s" % num["number"] if num.get("number") else "?"
    undispatched.append((pid, pt, title))

if not undispatched:
    sys.exit(0)

# Is an athena-admiral currently running? (marker fresh?) Suppress in live mode.
lock_fresh = False
if os.path.exists(lock_path):
    try:
        lock_fresh = (time.time() - os.path.getmtime(lock_path)) < stale_sec
    except OSError:
        lock_fresh = False

if lock_fresh and not dry:
    # An athena-admiral is draining; its own scope query will pick these up.
    # Do NOT mark seen — so we re-detect if the marker later clears.
    sys.exit(0)

n = len(undispatched)
ids = ", ".join(pt for _, pt, _ in undispatched)
titles = "; ".join("%s %s" % (pt, title[:70]) for _, pt, title in undispatched)

# FACTUAL STATE ONLY — no imperative. The action lives in CLAUDE.md.
text = (
    "Flaky-test lane state (from the SessionStart poll): "
    "%d flaky-test ticket(s) assigned to %s are queued in the walt_ui Tickets DB "
    "(label flaky-tests, status Todo/Backlog): %s. "
    "No flaky-test athena-admiral is currently running "
    "(no fresh ~/.claude/flaky-coordinator.lock marker). "
    "Details: %s. "
    "The flaky-test lane policy for this state is recorded in CLAUDE.md."
    % (n, owner, ids, titles)
)

out = {"hookSpecificOutput": {"hookEventName": "SessionStart",
                              "additionalContext": text}}

if dry:
    note = "[DRY-RUN] no seen-file write; running-marker "
    note += ("PRESENT (a live run would be suppressed)\n" if lock_fresh
             else "absent\n")
    sys.stderr.write(note)
    sys.stdout.write("[DRY-RUN] would emit this SessionStart additionalContext JSON:\n")
    sys.stdout.write(json.dumps(out, indent=2) + "\n")
    sys.exit(0)

# Live: mark these dispatched, then emit the additionalContext JSON.
with open(seen_path, "a") as f:
    for pid, _, _ in undispatched:
        f.write(pid + "\n")
sys.stdout.write(json.dumps(out) + "\n")
'
