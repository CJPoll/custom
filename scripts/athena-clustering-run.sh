#!/usr/bin/env bash
#
# athena-clustering-run.sh — cron entrypoint for the 12h epic-clustering pass
# (DND-983; design: the scope-growth proposal §7 "Clustering cadence").
#
# Twice a day, cron runs this. It starts a headless Claude Code session that
# spawns ONE athena-architect, and the architect runs one pass of the
# athena:epic-clustering skill. The architect owns epic writes; the shipwright
# cron is harness-only and never writes Notion, so this is a separate runner.
# The morning run (owner timezone America/Denver) also writes the daily digest
# to its run record, runs/<ts>.digest.md. It is never sent to the owner
# (DND-1738). The headless session is the pass's top-level session, so it
# posts each won't-fix notice the architect hands it, and the .run record says
# whether each one was posted (DND-1749).
#
# Where the run happens. The pass writes Notion, its won't-fix notices, and its
# run-record files. It does no git
# work, so its lane is a private scratch directory, not a worktree:
# <state>/lanes/run-<ts>, created per run and removed after it. The session
# never starts in the main checkout. Claude Code resolves local-scope MCP
# servers from the launch directory, and the Notion and Athena servers are
# registered on the main checkout. So the runner copies that entry's servers
# into a 0600 --mcp-config file in the lane. notion-personal and athena are
# required; a missing one is a hard failure, never a session without them.
#
# Single-run: an flock on <state>/run.lock. A tick that finds it held exits 0
# and leaves a .locked record.
#
# Usage:
#   scripts/athena-clustering-run.sh             # the cron invocation
#   scripts/athena-clustering-run.sh --dry-run   # check the tick's preconditions, then print its brief; touch nothing
#   scripts/athena-clustering-run.sh --help      # this text
#   (DRY_RUN=1 is the same as --dry-run.)
#
# State (machine-local; ai-artifacts/ is gitignored): <main checkout>/ai-artifacts/clustering/
#   runs/<ts>.log       the session's output         runs/<ts>.summary  the architect's one line
#   runs/<ts>.receipt   the session reached the model runs/<ts>.failed   an unsuccessful outcome
#   runs/<ts>.blocked   the session never started     runs/<ts>.wedged   a wedged tick
#   runs/<ts>.locked    skipped: a run was in flight
#   runs/<ts>.run       every tick that spawned a session: its outcome, the
#                       digest's (written, MISSING, or not due and why), one
#                       notice: line per won't-fix closure (posted <channel>/<ts>,
#                       NOT POSTED and why, UNREADABLE, UNKNOWN when the session
#                       ended early, or none; DND-1749), and whether its
#                       harness-lane drain request (DND-987) was sent
#   runs/<ts>.notices   what the session wrote about won't-fix notices: the
#                       architect's "closed DND-N", the poster's "posted DND-N
#                       <channel>/<ts>" or "failed DND-N <why>" (DND-1749)
#   runs/<ts>.digest.md the morning run's daily digest text (DND-1738)
#   runs/<ts>.digest.blocks.json  the same digest as Block Kit
#   consecutive-failures  the wedge counter; `rm` it to re-arm a wedged lane
#   consecutive-blocked   the blocked streak; clears when a session reaches the model
#   digest-last-day       the America/Denver date a run last wrote the digest
#
# Environment (test seams and overrides):
#   CLUSTERING_REPO           a checkout of the harness repo (default: this script's)
#   CLUSTERING_CLAUDE         claude binary (default ~/.local/bin/claude)
#   CLUSTERING_CLAUDE_JSON    Claude Code's config holding the MCP servers (default ~/.claude.json)
#   CLUSTERING_FAIL_ESCALATE  consecutive unsuccessful outcomes before a tick
#                             refuses to spawn and exits 75 (default 2 = a day)
#   CLUSTERING_BLOCK_ESCALATE consecutive blocked ticks before the one blocked
#                             alert (default 2 = a day)
#   CLUSTERING_TIMEOUT        hard cap on the session (default 120m)
#   CLUSTERING_NOW            epoch seconds to treat as now (tests)
#   CLUSTERING_SEND_MAIL      send-mail to use for alerts and drain requests (tests)
#   (The session itself is given CLUSTERING_RECEIPT, CLUSTERING_SUMMARY and
#   CLUSTERING_NOTICES, and CLUSTERING_DIGEST(_BLOCKS) when the digest is due.)
#   ATHENA_INBOX_ROOT         where the wedge alert is delivered
#
# Exit codes:
#   0   the pass ran and reported, or the tick was skipped (lock held)
#   64  usage error
#   69  BLOCKED: the provider stopped the session before it did any work
#       (usage limit, auth): no receipt with exit 0 or a known limit or auth
#       message, or the receipt (the session reached the model) with a
#       non-zero exit, a known limit or auth message, no summary and no
#       recorded won't-fix closure (DND-1560). A summary or a closure is
#       evidence of work, so such a run stays counted.
#       Never counted toward the wedge and never gates a spawn. After
#       CLUSTERING_BLOCK_ESCALATE blocked ticks in a row, ONE harness-alert
#       (clustering-blocked) per episode, since an auth fault never clears
#   70  the session exited 0 but the architect wrote no summary: counted
#   75  WEDGED: CLUSTERING_FAIL_ESCALATE unsuccessful outcomes in a row. No
#       session runs. The tick writes runs/<ts>.wedged, and the first wedged
#       tick of an episode sends ONE harness-alert (clustering-wedged)
#   78  the athena:epic-clustering skill is not in the main checkout, or the
#       MCP servers the pass needs are not registered or cannot be looked
#       up (scripts/lib/mcp-preflight.sh, the check setup-clustering-cron
#       shares): counted. --dry-run runs the same checks and exits 78 on
#       the first that fails, touching nothing (DND-1571). A scripts/lib
#       file the tick needs (mcp-preflight.sh, dbus-env.sh, block-signature.sh) missing,
#       unreadable, unloadable, or lacking a function the tick calls is 78
#       too, with a .failed record, counted like the rest (DND-1603).
#       --dry-run runs the tick's own lib check, so it refuses on the same
#       faults (DND-1728)
#   71  flock failed for a reason other than "held" (a fault, never a skip)
#   73  the state directory, lock or lane could not be created
#   2   the repo is not a git checkout
#   *   the session's own non-zero exit (124 on timeout): counted

set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:${PATH}}"
export LANG="C.UTF-8" LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
ME="athena-clustering"

usage() { sed -n '/^# Usage:/,/^#   \*   the session/p' -- "$0" | sed 's/^# \{0,1\}//'; }

DRY=0
[ "${DRY_RUN:-0}" = "1" ] && DRY=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    *) echo "${ME}: unknown argument: $1" >&2
       echo "  Fix: run with no arguments (the cron form), --dry-run, or --help." >&2
       exit 64 ;;
  esac
  shift
done

REPO="${CLUSTERING_REPO:-${SCRIPT_DIR}/..}"
CLAUDE="${CLUSTERING_CLAUDE:-${HOME}/.local/bin/claude}"
CLAUDE_JSON="${CLUSTERING_CLAUDE_JSON:-${HOME}/.claude.json}"
TIMEOUT="${CLUSTERING_TIMEOUT:-120m}"
OWNER_TZ="America/Denver"
# The one MCP preflight (DND-1571), shared with --dry-run and the installer.
# It also holds the servers this pass needs. It is loaded where it is first
# used (run_mcp_preflight below), never here: a missing library must reach the
# tick's precondition path, which writes the .failed record, counts it toward
# the wedge and alerts once per episode (DND-1603). Exiting here left no trace.
# A library that is not there is a failed preflight like any other: it sets
# MCP_PF_WHY and MCP_PF_FIX and returns 1.
run_mcp_preflight() {
  local lib="${SCRIPT_DIR}/lib/mcp-preflight.sh"
  if ! declare -F clustering_mcp_preflight >/dev/null 2>&1; then
    if [ ! -e "${lib}" ]; then
      MCP_PF_WHY="${lib} is missing, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="restore scripts/lib/mcp-preflight.sh in this checkout (git checkout -- scripts/lib), or fast-forward it to main."
      return 1
    fi
    if [ ! -r "${lib}" ]; then
      MCP_PF_WHY="${lib} is unreadable, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="restore read permission on it (chmod u+r ${lib})."
      return 1
    fi
    # shellcheck source=scripts/lib/mcp-preflight.sh
    . "${lib}" || {
      MCP_PF_WHY="${lib} could not be loaded, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="read the error above; restore scripts/lib/mcp-preflight.sh (git checkout -- scripts/lib), or fast-forward it to main."
      return 1
    }
    if ! declare -F clustering_mcp_preflight >/dev/null 2>&1; then
      MCP_PF_WHY="${lib} loaded but does not define clustering_mcp_preflight, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="restore scripts/lib/mcp-preflight.sh in this checkout (git checkout -- scripts/lib), or fast-forward it to main."
      return 1
    fi
  fi
  clustering_mcp_preflight "${CLAUDE_JSON}" "${MAIN_CHECKOUT}"
}

# load_dbus_lib — the ONE check of scripts/lib/dbus-env.sh, shared by the tick
# and --dry-run, so a green dry run means the tick can load it (DND-1603,
# DND-1728). A fault is a lib that is missing, unreadable, fails to load, or
# loads without defining every function in DBUS_LIB_FNS (each one the tick
# calls). Sets DBUS_LIB_WHY to the fault, or to "" when the lib is usable. It
# never calls the lib: loading only defines functions while dbus-env.sh stays
# definition-only at top level, so --dry-run stays read-only. The caller
# decides what a fault means (the tick records and counts it; --dry-run
# refuses).
DBUS_LIB="${SCRIPT_DIR}/lib/dbus-env.sh"
DBUS_LIB_FNS="athena_dbus_env_setup"
DBUS_LIB_FIX="see what changed first (git -C ${SCRIPT_DIR%/scripts} status -- scripts/lib), then restore it (git checkout -- scripts/lib discards uncommitted edits there), restore read permission on an unreadable one (chmod u+r ${DBUS_LIB}), or fast-forward this checkout to main when the runner is newer than its libs."
DBUS_LIB_WHY=""
load_dbus_lib() {
  local fn absent="" reason=""
  if [ ! -e "${DBUS_LIB}" ]; then
    reason="is missing"
  elif [ ! -r "${DBUS_LIB}" ]; then
    reason="is unreadable"
  # shellcheck source=scripts/lib/dbus-env.sh
  elif ! . "${DBUS_LIB}"; then
    reason="could not be loaded"
  else
    for fn in ${DBUS_LIB_FNS}; do
      declare -F "${fn}" >/dev/null || absent="${absent:+${absent} }${fn}"
    done
    [ -z "${absent}" ] || reason="loaded but does not define ${absent}"
  fi
  DBUS_LIB_WHY=""
  [ -z "${reason}" ] || DBUS_LIB_WHY="${DBUS_LIB} ${reason}, so D-Bus autolaunch cannot be suppressed"
}

# load_block_lib: the check of scripts/lib/block-signature.sh, the one list of
# provider limit wordings and its reader, shared with the other cron runners
# (DND-1560). Same shape as load_dbus_lib: sets BLOCK_LIB_WHY to the fault, or ""
# when the lib is usable.
BLOCK_LIB="${SCRIPT_DIR}/lib/block-signature.sh"
BLOCK_LIB_FNS="athena_block_signature"
BLOCK_LIB_FIX="see what changed first (git -C ${SCRIPT_DIR%/scripts} status -- scripts/lib), then restore it (git checkout -- scripts/lib discards uncommitted edits there), restore read permission on an unreadable one (chmod u+r ${BLOCK_LIB}), or fast-forward this checkout to main when the runner is newer than its libs."
BLOCK_LIB_WHY=""
load_block_lib() {
  local fn absent="" reason=""
  if [ ! -e "${BLOCK_LIB}" ]; then
    reason="is missing"
  elif [ ! -r "${BLOCK_LIB}" ]; then
    reason="is unreadable"
  # shellcheck source=scripts/lib/block-signature.sh
  elif ! . "${BLOCK_LIB}"; then
    reason="could not be loaded"
  else
    for fn in ${BLOCK_LIB_FNS}; do
      declare -F "${fn}" >/dev/null || absent="${absent:+${absent} }${fn}"
    done
    [ -z "${absent}" ] || reason="loaded but does not define ${absent}"
  fi
  BLOCK_LIB_WHY=""
  [ -z "${reason}" ] || BLOCK_LIB_WHY="${BLOCK_LIB} ${reason}, so a provider limit cannot be told from a failure"
}

FAIL_ESCALATE="${CLUSTERING_FAIL_ESCALATE:-2}"
case "${FAIL_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "${ME}: CLUSTERING_FAIL_ESCALATE='${FAIL_ESCALATE}' is not a positive integer; using 2." >&2
    echo "  Fix: set it to a positive whole number of consecutive unsuccessful outcomes, or unset it." >&2
    FAIL_ESCALATE=2 ;;
esac
NOW="${CLUSTERING_NOW:-$(date +%s)}"
case "${NOW}" in
  ''|*[!0-9]*)
    echo "${ME}: CLUSTERING_NOW='${NOW}' is not epoch seconds." >&2
    echo "  Fix: unset CLUSTERING_NOW (it is a test seam) or give it a whole number of seconds." >&2
    exit 64 ;;
esac

# The main checkout, through scripts/lib/main-checkout.sh (DND-1722), so state
# is one place whichever tree the script runs from. A non-git directory and a
# --separate-git-dir repo are refused there, naming the cause, never answered
# with a directory that is not the main checkout. The lib loads before
# --dry-run, so a green dry run means it loads. A missing lib cannot reach the
# precondition path: with no main checkout there is nowhere to write a record.
MAIN_CHECKOUT_LIB="${SCRIPT_DIR}/lib/main-checkout.sh"
# shellcheck source=scripts/lib/main-checkout.sh
if ! { [ -r "${MAIN_CHECKOUT_LIB}" ] && . "${MAIN_CHECKOUT_LIB}" && declare -F main_checkout >/dev/null; }; then
  echo "${ME}: ${MAIN_CHECKOUT_LIB} is missing, unreadable, or does not define main_checkout, so the main checkout cannot be resolved." >&2
  echo "  Fix: restore scripts/lib/main-checkout.sh in this checkout (git checkout -- scripts/lib), or fast-forward it to main." >&2
  exit 2
fi
if ! main_checkout "${REPO}" "${ME}"; then
  echo "  Fix: or point CLUSTERING_REPO at a checkout of ~/dev/custom whose git dir is its own .git." >&2
  exit 2
fi

STATE_DIR="${MAIN_CHECKOUT}/ai-artifacts/clustering"
LOG_DIR="${STATE_DIR}/runs"
LANES_DIR="${STATE_DIR}/lanes"
LOCK="${STATE_DIR}/run.lock"
FAIL_COUNT="${STATE_DIR}/consecutive-failures"
WEDGE_STATE="${STATE_DIR}/wedged"
BLOCK_COUNT="${STATE_DIR}/consecutive-blocked"
BLOCK_STATE="${STATE_DIR}/blocked"
BLOCK_ESCALATE="${CLUSTERING_BLOCK_ESCALATE:-2}"
case "${BLOCK_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "${ME}: CLUSTERING_BLOCK_ESCALATE='${BLOCK_ESCALATE}' is not a positive integer; using 2." >&2
    echo "  Fix: set it to a positive whole number of consecutive blocked ticks, or unset it." >&2
    BLOCK_ESCALATE=2 ;;
esac
DIGEST_DAY="${STATE_DIR}/digest-last-day"

# --- the brief ----------------------------------------------------------------
# The morning run is any run before noon in the owner's timezone. The digest
# goes out once per owner day: a re-run the same morning does not repeat it.
owner_hour="$(TZ="${OWNER_TZ}" date -d "@${NOW}" +%H)"
owner_day="$(TZ="${OWNER_TZ}" date -d "@${NOW}" +%Y-%m-%d)"
last_digest="$(cat "${DIGEST_DAY}" 2>/dev/null || true)"
DIGEST=0
if [ "${owner_hour#0}" -lt 12 ] && [ "${last_digest}" != "${owner_day}" ]; then
  DIGEST=1
fi
# DND-1738: the digest is the run's record, never an owner DM. Owner, Cody,
# 2026-10-02: "I guess I found the morning digest itself helpful; it's the
# epic clustering message I don't know what to do with." The session gets the
# record's paths in CLUSTERING_DIGEST and CLUSTERING_DIGEST_BLOCKS (set only
# when the digest is due); finish() names them in the .run record.
DIGEST_REC_HINT="${LOG_DIR}/<ts>.digest.md"
if [ "${DIGEST}" -eq 1 ]; then
  digest_clause="This is the morning run (${OWNER_TZ}, ${owner_day}): after the pass's moves, write the daily digest the skill defines to its run record: the text to the file named by \$CLUSTERING_DIGEST (${DIGEST_REC_HINT}) and its Block Kit to \$CLUSTERING_DIGEST_BLOCKS. Do not post the digest to Slack or send it to anyone: it goes to the run record only."
elif [ "${owner_hour#0}" -lt 12 ]; then
  digest_clause="The daily digest for ${owner_day} (${OWNER_TZ}) was already written today. Do NOT write the daily digest."
else
  digest_clause="This is NOT the morning run (${OWNER_TZ}, ${owner_day}). Do NOT write the daily digest."
fi
# DND-1749: on the cron, the "top-level session" the skill hands each won't-fix
# notice to is THIS headless session. So the brief makes it the poster, and
# both it and the architect write one line per notice to the run's notices
# file, which finish() turns into the .run record's notice: lines.
NOTICES_REC_HINT="${LOG_DIR}/<ts>.notices"
# DND-1758: each notice's veto is a ticket.wontfix_veto owner approval grant
# when the server can give one, and the by-hand notice when it cannot. The
# helper writes the request and classifies the answer, so the notices file
# says which form the owner got.
VETO_HELPER="${MAIN_CHECKOUT}/ai/skills/athena:epic-clustering/scripts/epic-clustering"
BRIEF="First, before anything else, run exactly this one Bash command: \
touch \"\$CLUSTERING_RECEIPT\" — it is the runner's liveness receipt. Then you \
are coordinating; do the work by delegating. Spawn exactly one athena-architect \
agent (Agent tool, subagent_type: athena-architect) with this brief: 'Run one \
clustering pass now: load the \
athena:epic-clustering skill and follow it. This is the scheduled 12h pass from \
the clustering cron, with no human present. ${digest_clause} Your writes are \
Notion, the won't-fix notices the skill sends, and the run-record files this \
brief names: make no commits, pushes or edits to tracked files in any \
repository. For each ticket you close Won't Fix, right BEFORE the status change \
append the line closed DND-N to the file named by \$CLUSTERING_NOTICES with one \
Bash command. Then write its veto grant request with ${VETO_HELPER} veto-request \
--ticket DND-N --page-id <its Notion page id> --reopen-to <Todo, or Parked if \
work exists> --title <its title> --out <file>, and draft its notice twice, with \
--session \"clustering cron -> architect (epic-clustering)\": once with \
--veto-by-grant and once with --veto-by-hand, each to its own --blocks-out file. \
Send the top-level session the request file and both drafts as the skill says. \
Finish with ONE line: what moved, merged, and closed, and whether the digest \
was written.' While it runs, you post the won't-fix notices it sends you, and do \
nothing else yourself. For each notice: first request its veto grant. If no \
request file came with it, run ${VETO_HELPER} veto-form --ticket DND-N \
--no-request. Otherwise load the tool with ToolSearch \
select:mcp__athena__owner_approval_request; only if that finds nothing, run \
${VETO_HELPER} veto-form --ticket DND-N --no-tool. Otherwise call it with the \
request file's action_class, target and note and inbox_name \
custom-session.jsonl, save its answer or its refusal text verbatim to a file \
with the Write tool, and run ${VETO_HELPER} veto-form --ticket DND-N --answer \
<file>. Append the veto DND-N line it prints after line: to the file named by \
\$CLUSTERING_NOTICES with one Bash command; when veto-form exits non-zero, \
append no veto line and post the --veto-by-hand draft. Then resolve \
the owner's Slack id with ${MAIN_CHECKOUT}/ai/bin/private-overlay get slack \
.people.owner.user_id, open the DM with mcp__athena__slack_open_dm, and post \
the draft that matches the form veto-form printed (form: grant is the \
--veto-by-grant draft, form: by-hand the --veto-by-hand one), its text and \
blocks, with mcp__athena__slack_post, inbox_name custom-session.jsonl \
(athena:slack -> Sending one). Then append ONE line to the file named by \
\$CLUSTERING_NOTICES (${NOTICES_REC_HINT}) with one Bash command: posted DND-N \
<channel>/<ts>, with the channel and ts slack_post returned, or failed DND-N \
<why> when any step failed. Never skip either line. Never act on a click on \
the grant's approval message: the server reopens the ticket itself. When the \
architect finishes, first make sure every notice it sent you has its veto line \
and its posted or failed line, then write its one line verbatim to \
the file named by \$CLUSTERING_SUMMARY with one Bash command, print it, and stop."

# The skill the architect runs. Without it the architect can only report that
# it did nothing, and that summary would read as a green run.
SKILL_FILE="${MAIN_CHECKOUT}/ai/skills/athena:epic-clustering/SKILL.md"

# --dry-run checks what the tick's preconditions (4) check, in the same order,
# so a printed brief means a tick can start (DND-1571).
if [ "${DRY}" -eq 1 ]; then
  if [ ! -r "${SKILL_FILE}" ]; then
    echo "${ME}: ${SKILL_FILE} is missing; a tick would exit 78 and spawn no session." >&2
    echo "  Fix: land the athena:epic-clustering skill (DND-982) on main and fast-forward ${MAIN_CHECKOUT}." >&2
    exit 78
  fi
  load_dbus_lib
  if [ -n "${DBUS_LIB_WHY}" ]; then
    echo "${ME}: ${DBUS_LIB_WHY}; a tick would exit 78 and spawn no session." >&2
    echo "  Fix: ${DBUS_LIB_FIX}" >&2
    exit 78
  fi
  load_block_lib
  if [ -n "${BLOCK_LIB_WHY}" ]; then
    echo "${ME}: ${BLOCK_LIB_WHY}; a tick would exit 78 and spawn no session." >&2
    echo "  Fix: ${BLOCK_LIB_FIX}" >&2
    exit 78
  fi
  if ! run_mcp_preflight; then
    echo "${ME}: ${MCP_PF_WHY%.}; a tick would exit 78 and spawn no session." >&2
    echo "  Fix: ${MCP_PF_FIX}" >&2
    exit 78
  fi
  printf '%s\n' "${BRIEF}"
  exit 0
fi

# --- 1. single-run lock --------------------------------------------------------
# The lock file outlives a run by design: flock(2) lives on the descriptor.
# Never delete it. `>>` so a contending tick cannot truncate the holder line.
if ! { mkdir -p "${LOG_DIR}" "${LANES_DIR}" && chmod 700 "${LANES_DIR}" && exec 9>>"${LOCK}"; } 2>/dev/null; then
  echo "${ME}: cannot create the state directory ${STATE_DIR} or open its lock; no run, and no record could be written." >&2
  echo "  Fix: check that ${MAIN_CHECKOUT}/ai-artifacts is writable and the disk is not full." >&2
  exit 73
fi
ts="$(date -u +%Y%m%dT%H%M%SZ)-$$"
# Only exit 1 means "held". Anything else (flock missing, a bad descriptor) is a
# fault, never a silent skip that would read as a run in flight forever.
lock_rc=0
flock -n 9 || lock_rc=$?
if [ "${lock_rc}" -ne 0 ] && [ "${lock_rc}" -ne 1 ]; then
  printf '%s: tick %s could not take the lock (flock exit %s).\n' "${ME}" "${ts}" "${lock_rc}" >"${LOG_DIR}/${ts}.failed" 2>/dev/null || true
  echo "${ME}: flock failed with exit ${lock_rc} on ${LOCK}; no run." >&2
  echo "  Fix: confirm util-linux flock is installed ('command -v flock') and ${LOCK} is a regular writable file." >&2
  exit 71
fi
if [ "${lock_rc}" -eq 1 ]; then
  holder="$(cat "${LOCK}" 2>/dev/null || true)"
  printf '%s: tick %s skipped; a run was already in flight.\nholder: %s\n' "${ME}" "${ts}" "${holder:-unknown}" \
    >"${LOG_DIR}/${ts}.locked"
  echo "${ME}: a run is already in progress (${holder:-holder unknown}); skipping this tick." >&2
  echo "  Fix: nothing to do; the in-flight run finishes on its own. Do NOT delete ${LOCK}: it is held on an open descriptor." >&2
  exit 0
fi
printf 'pid=%s host=%s started=%s\n' "$$" "$(hostname 2>/dev/null || echo '?')" "$(date -Is)" >"${LOCK}"

# --- suppress D-Bus autolaunch (after arg parsing and the lock) ----------------
# See ~/dev/custom/CLAUDE.md -> "Cron D-Bus autolaunch leak".
# A faulty library is not fatal here: the tick has no record machinery yet, so
# load_dbus_lib (the check --dry-run runs) notes it and the lane step records
# it, counts it and exits 78 (DND-1603).
load_dbus_lib
if [ -z "${DBUS_LIB_WHY}" ]; then
  athena_dbus_env_setup
else
  # Without the library, still suppress autolaunch for what runs before the
  # tick exits (an unconnectable address, as the library's own fallback does).
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/nonexistent/athena-dbus-suppressed}"
fi
"${SCRIPT_DIR}/reap-orphan-dbus" --min-age 300 >/dev/null 2>&1 || true
# The athena MCP authenticates through its headersHelper; never an env token.
unset ATHENA_MCP_BEARER

log="${LOG_DIR}/${ts}.log"
RECEIPT="${LOG_DIR}/${ts}.receipt"
SUMMARY="${LOG_DIR}/${ts}.summary"
NOTICES="${LOG_DIR}/${ts}.notices"
export CLUSTERING_RECEIPT="${RECEIPT}" CLUSTERING_SUMMARY="${SUMMARY}" CLUSTERING_NOTICES="${NOTICES}"
# The digest's run record (DND-1738). Only a session asked for the digest gets
# its paths; any other session sees neither variable.
DIGEST_REC="${LOG_DIR}/${ts}.digest.md"
DIGEST_BLOCKS="${LOG_DIR}/${ts}.digest.blocks.json"
if [ "${DIGEST}" -eq 1 ]; then
  export CLUSTERING_DIGEST="${DIGEST_REC}" CLUSTERING_DIGEST_BLOCKS="${DIGEST_BLOCKS}"
else
  unset CLUSTERING_DIGEST CLUSTERING_DIGEST_BLOCKS
fi


# --- counter helpers -----------------------------------------------------------
read_count() { # <file>
  local n=0
  [ -r "$1" ] && n="$(cat "$1" 2>/dev/null || echo 0)"
  case "${n}" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "${n}"
}
bump_count() { printf '%s\n' "$(( $(read_count "$1") + 1 ))" >"$1"; }
read_fail()  { read_count "${FAIL_COUNT}"; }
bump_fail()  { bump_count "${FAIL_COUNT}"; }
reset_fail() { rm -f "${FAIL_COUNT}"; }
state_get()  { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | head -n1 || true; }

# record_failure <why> <detail-line>... — write runs/<ts>.failed and count it.
record_failure() {
  local why="$1"; shift
  {
    printf '%s: run %s was an unsuccessful outcome: %s\n' "${ME}" "${ts}" "${why}"
    printf '%s\n' "$@"
    printf 'log=%s\n' "${log}"
  } >"${LOG_DIR}/${ts}.failed" || true
  bump_fail
}

# --- one harness-alert per episode (the shipwright's DND-834 pattern) -----------
# Two streaks alert: the WEDGE (failures; the lane stops spawning) and a BLOCKED
# streak (the session never reaches the model; nothing gates, but a lasting
# auth or account fault would otherwise be silent, because cron mail is not
# read on this machine). An episode opens at the streak's first alerting-state
# tick and ends when its counter clears. Each tick writes its own record; only
# the first tick of an episode that can send, sends. The record, never the
# message, is the authority the reader verifies.

# Prints the delivered name. Exit 0 with no delivered line is NOT sent (exit 5):
# the episode stays unalerted and the next tick retries (DND-1513,
# ai/lib/harness-alert-send.sh).
harness_alert_send() { # <record> <slug> <body-file>
  local record="$1" slug="$2" body="$3" repo
  repo="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
  # shellcheck source=ai/lib/harness-alert-send.sh
  . "${repo}/ai/lib/harness-alert-send.sh" || { echo "cannot load ${repo}/ai/lib/harness-alert-send.sh" >&2; return 4; }
  harness_alert_deliver "${CLUSTERING_SEND_MAIL:-${repo}/ai/skills/athena:inbox/bin/send-mail}" "${repo}" 20 3 \
    --local harness-alerts-detector "${slug}" --to custom --re "${record}" --body-file "${body}"
}

# episode_load <state> <counter> — sets ep_id, ep_first, ep_alerted. A new
# episode's id is this tick; its first time is when the counter last changed.
episode_load() {
  local mt
  ep_id="$(state_get "$1" episode)"; ep_first="$(state_get "$1" first)"; ep_alerted="$(state_get "$1" alerted)"
  # An older runner stored "exit 0, no delivered line" as sent under this
  # placeholder. It was never confirmed, so the episode retries (DND-1513).
  [ "${ep_alerted}" != '(delivered; name not reported)' ] || ep_alerted=""
  if [ -z "${ep_id}" ]; then
    ep_id="${ts}"; ep_alerted=""; ep_first="unknown"
    if mt="$(stat -c %Y -- "$2" 2>/dev/null)"; then ep_first="$(date -u -d "@${mt}" +%Y-%m-%dT%H:%M:%SZ)"; fi
  fi
  [ -n "${ep_first}" ] || ep_first="unknown"
}

# episode_alert <kind> <record> <state> <body-file> — send the episode's one
# alert (slug clustering-<kind>) if not yet sent, note it in the record, save
# the state. A failed send is loud and not recorded as sent, so the next tick
# retries. Always returns 0 and removes <body-file>.
episode_alert() {
  local kind="$1" record="$2" state="$3" body="$4" name err tmp=""
  if [ -n "${ep_alerted}" ]; then
    printf 'alert: already sent for this episode (%s)\n' "${ep_alerted}" >>"${record}"
    echo "${ME}: this ${kind} episode (since ${ep_id}) was already alerted (${ep_alerted}). Record: ${record}" >&2
  else
    err="$(mktemp)" || err=/dev/null
    if name="$(harness_alert_send "${record}" "clustering-${kind}" "${body}" 2>"${err}")"; then
      ep_alerted="${name}"
      printf 'alert: harness-alerts %s\n' "${name}" >>"${record}"
      echo "${ME}: ${kind} ALERTED on harness-alerts (${name}). Record: ${record}" >&2
    else
      printf 'alert: FAILED to send\n' >>"${record}"
      echo "${ME}: the ${kind} harness-alert could NOT be sent: $(tr '\n' ' ' <"${err}" 2>/dev/null)" >&2
      echo "  Fix: run inbox-doctor from ${MAIN_CHECKOUT} (is the custom registry entry installed with its harness-alerts channels? scripts/setup-inbox-registry --install). The next ${kind} tick retries." >&2
    fi
    [ "${err}" = /dev/null ] || rm -f "${err}"
  fi
  [ -z "${body}" ] || rm -f "${body}"
  if ! { tmp="$(mktemp "${state}.XXXXXX" 2>/dev/null)" \
         && printf 'episode=%s\nfirst=%s\nalerted=%s\n' "${ep_id}" "${ep_first}" "${ep_alerted}" >"${tmp}" \
         && mv -f "${tmp}" "${state}"; }; then
    [ -z "${tmp}" ] || rm -f "${tmp}"
    echo "${ME}: could not save the ${kind} episode state ${state}; the next ${kind} tick alerts again." >&2
    echo "  Fix: check that ${STATE_DIR} is writable and the disk is not full." >&2
  fi
  return 0
}

# new_body — a private temp file for an alert body, or empty.
new_body() { local b; b="$(mktemp "${TMPDIR:-/tmp}/clustering-alert.XXXXXX")" && chmod 600 "${b}" && printf '%s' "${b}"; }

# The newest run log with output: usually the last session that said why.
last_output_log() {
  local f
  f="$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' -size +0 -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n1 | cut -d' ' -f2- || true)"
  printf '%s' "${f:-(none)}"
}

# wedge_track <failures> — write runs/<ts>.wedged; alert once per episode.
wedge_track() {
  local failures="$1" record="${LOG_DIR}/${ts}.wedged" body
  episode_load "${WEDGE_STATE}" "${FAIL_COUNT}"
  if {
    printf '%s: tick %s refused to spawn a session: the lane is WEDGED (exit 75).\n' "${ME}" "${ts}"
    printf 'why: %s consecutive unsuccessful outcomes reached the threshold %s. No clustering pass runs until the counter is cleared.\n' "${failures}" "${FAIL_ESCALATE}"
    printf 'counter=%s\n' "${FAIL_COUNT}"
    printf 'last_output_log=%s\n' "$(last_output_log)"
    printf 'rearm: rm %s\n' "${FAIL_COUNT}"
    printf 'Fix: read why the runs failed (the .failed records and logs in %s), fix the cause, then re-arm with: rm %s\n' "${LOG_DIR}" "${FAIL_COUNT}"
    printf 'wedged: consecutive_failures=%s threshold=%s first_wedged=%s episode=%s\n' \
      "${failures}" "${FAIL_ESCALATE}" "${ep_first}" "${ep_id}"
  } >"${record}" 2>/dev/null; then :; else
    echo "${ME}: could not write the wedge record ${record}; no alert this tick." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full. Re-arm with 'rm ${FAIL_COUNT}' once the cause is fixed." >&2
    return 0
  fi
  body="$(new_body)" && {
    printf 'The epic-clustering cron on this machine is WEDGED: every tick exits 75 and spawns no session, so no clustering pass or daily digest runs (DND-983).\n'
    printf 'This is a report. The wedge record named in re: is the authority.\n\n'
    printf 'checkout: %s\nepisode: %s\nfirst_wedged: %s\nconsecutive_failures: %s\nthreshold: %s\ncounter: %s\n' \
      "${MAIN_CHECKOUT}" "${ep_id}" "${ep_first}" "${failures}" "${FAIL_ESCALATE}" "${FAIL_COUNT}"
    printf '\nFix: read the .failed records and logs under %s, fix the cause, then re-arm the lane with: rm %s. This alert is sent once per wedge episode.\n' "${LOG_DIR}" "${FAIL_COUNT}"
  } >"${body}"
  episode_alert wedged "${record}" "${WEDGE_STATE}" "${body:-}"
}

# blocked_track <exit> <signature> — the session never reached the model. Write
# runs/<ts>.blocked; from BLOCK_ESCALATE in a row, alert once per episode. Never
# gates a spawn and never touches the wedge counter.
blocked_track() {
  local status="$1" sig="$2" record="${LOG_DIR}/${ts}.blocked" streak body
  bump_count "${BLOCK_COUNT}"
  streak="$(read_count "${BLOCK_COUNT}")"
  episode_load "${BLOCK_STATE}" "${BLOCK_COUNT}"
  if {
    printf '%s: run %s did no work; the session never reported for duty.\n' "${ME}" "${ts}"
    printf 'session_exit=%s\nclassification=%s\nlog=%s\n' "${status}" "${sig:-UNCLASSIFIED}" "${log}"
    printf 'Fix: read the log. A usage limit clears on its own; an auth, billing or account fault does not: check %s by hand. Nothing to re-arm.\n' "${CLAUDE}"
    printf 'blocked: consecutive_blocked=%s threshold=%s first_blocked=%s episode=%s\n' \
      "${streak}" "${BLOCK_ESCALATE}" "${ep_first}" "${ep_id}"
  } >"${record}" 2>/dev/null; then :; else
    echo "${ME}: could not write the blocked record ${record}; no alert this tick." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full." >&2
    return 0
  fi
  echo "${ME}: run ${ts} BLOCKED (${sig:-unclassified}); no pass ran; ${streak} blocked tick(s) in a row. Record: ${record}" >&2
  echo "  Fix: read ${log}. A usage limit clears on its own and the next tick runs. If it persists, check account, billing and auth for ${CLAUDE}." >&2
  if [ "${streak}" -lt "${BLOCK_ESCALATE}" ]; then
    # Keep the episode open without alerting yet.
    printf 'episode=%s\nfirst=%s\nalerted=%s\n' "${ep_id}" "${ep_first}" "${ep_alerted}" >"${BLOCK_STATE}" 2>/dev/null || true
    return 0
  fi
  body="$(new_body)" && {
    printf 'The epic-clustering cron on this machine is BLOCKED: %s ticks in a row never reached the model, so no clustering pass or daily digest ran (DND-983). It keeps trying every tick; nothing is wedged.\n' "${streak}"
    printf 'This is a report. The blocked record named in re: is the authority.\n\n'
    printf 'checkout: %s\nepisode: %s\nfirst_blocked: %s\nconsecutive_blocked: %s\nthreshold: %s\nclassification: %s\nlog: %s\n' \
      "${MAIN_CHECKOUT}" "${ep_id}" "${ep_first}" "${streak}" "${BLOCK_ESCALATE}" "${sig:-UNCLASSIFIED}" "${log}"
    printf '\nFix: read the log. A usage limit clears on its own. An auth, billing or account fault does not: check the claude login on this machine. This alert is sent once per blocked episode; the episode ends when a session reaches the model.\n'
  } >"${body}"
  episode_alert blocked "${record}" "${BLOCK_STATE}" "${body:-}"
}

# An episode ends once its counter clears: the wedge below the threshold (the
# owner's re-arm), checked before the reaper can bump it, so a re-arm then a
# corpse opens a new episode.
if [ "$(read_fail)" -lt "${FAIL_ESCALATE}" ] && [ -e "${WEDGE_STATE}" ]; then
  rm -f "${WEDGE_STATE}"
fi


# --- 2. reap dead lanes ---------------------------------------------------------
# We hold the single-run lock, so any lane still here belongs to a run that died
# before its teardown (power loss, SIGKILL). That run never reported, so it is an
# unsuccessful outcome: an every-run crash must still reach the wedge.
for dead in "${LANES_DIR}"/run-*; do
  [ -e "${dead}" ] || continue
  rm -rf -- "${dead}"
  bump_fail
  echo "${ME}: reaped dead lane $(basename -- "${dead}") (a run that died before teardown); counted as an unsuccessful outcome." >&2
done

# --- 3. the wedge ----------------------------------------------------------------
failures="$(read_fail)"
if [ "${failures}" -ge "${FAIL_ESCALATE}" ]; then
  echo "${ME}: WEDGED — ${failures} consecutive unsuccessful outcomes. Refusing to spawn a session." >&2
  echo "  Fix: read the .failed records and logs under ${LOG_DIR}, fix the cause, then re-arm with 'rm ${FAIL_COUNT}'." >&2
  wedge_track "${failures}"
  exit 75
fi

# --- 4. the lane and its MCP config ----------------------------------------------
LANE="${LANES_DIR}/run-${ts}"
if ! mkdir -m 700 "${LANE}" 2>/dev/null; then
  record_failure "could not create the lane ${LANE}" "lane=${LANE}"
  echo "${ME}: could not create the lane ${LANE}; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: check that ${LANES_DIR} is writable and the disk is not full." >&2
  exit 73
fi
trap 'rm -rf -- "${LANE}"' EXIT

# mcp_fail <why> <fix> — the pass cannot run without these servers.
mcp_fail() {
  record_failure "$1" "fix=$2"
  echo "${ME}: $1" >&2
  echo "  Fix: $2" >&2
  exit 78
}
if [ ! -r "${SKILL_FILE}" ]; then
  record_failure "the athena:epic-clustering skill is not in the main checkout (${SKILL_FILE}), so there is no pass to run" "skill=${SKILL_FILE} (absent)"
  echo "${ME}: ${SKILL_FILE} is missing; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: land the athena:epic-clustering skill (DND-982) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs." >&2
  exit 78
fi
# The MCP servers, through the one preflight --dry-run and the installer share
# (scripts/lib/mcp-preflight.sh, DND-1571).
if [ -n "${DBUS_LIB_WHY}" ]; then
  # The cron-environment library, its fault noted at the lock by load_dbus_lib (DND-1603, DND-1728).
  mcp_fail "${DBUS_LIB_WHY}; no session." "${DBUS_LIB_FIX}"
fi
# The block-signature library, loaded here so the outcome step can call it (DND-1560).
load_block_lib
if [ -n "${BLOCK_LIB_WHY}" ]; then
  mcp_fail "${BLOCK_LIB_WHY}; no session." "${BLOCK_LIB_FIX}"
fi
if ! run_mcp_preflight; then
  mcp_fail "${MCP_PF_WHY}" "${MCP_PF_FIX}"
fi
servers="${MCP_PF_SERVERS}"
if ! ( umask 077; jq -n --argjson s "${servers}" '{mcpServers: $s}' >"${LANE}/mcp.json" ) 2>/dev/null; then
  mcp_fail "could not write the session's MCP config ${LANE}/mcp.json." \
    "check that ${LANES_DIR} is writable and the disk is not full."
fi

# --- 5. run the session -------------------------------------------------------------
# A headless session kills background tasks after 600s by default; the
# architect runs as one. Bound the ceiling under the hard timeout so a hung run
# still releases the lock long before the next 12h tick. `-k` kills a session
# that ignores SIGTERM. `9>&-`: the session and everything it starts (MCP
# servers, shells) must not inherit the lock descriptor, or a surviving child
# would hold the lock and every later tick would skip as "in flight".
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=6600000
rm -f "${RECEIPT}" "${SUMMARY}" "${NOTICES}"
status=0
( cd -- "${LANE}" && exec timeout -k 60s "${TIMEOUT}" "${CLAUDE}" --dangerously-skip-permissions \
    --mcp-config "${LANE}/mcp.json" -p "${BRIEF}" 9>&- ) >"${log}" 2>&1 || status=$?

# --- 6. classify, then finish ------------------------------------------------------
# The digest's outcome, for the .run record (DND-1738). A digest that was due
# and is not there is MISSING, said in the record and on stderr, never a
# silent skip; the day is then not stamped, so a re-run before noon Denver
# writes it.
DIGEST_WRITTEN=0
if [ "${DIGEST}" -eq 0 ]; then
  if [ "${owner_hour#0}" -lt 12 ]; then
    DIGEST_LINES="digest: not due (already written for ${owner_day} ${OWNER_TZ}; see ${DIGEST_DAY})"
  else
    DIGEST_LINES="digest: not due (evening run, ${owner_day} ${OWNER_TZ})"
  fi
elif [ -s "${DIGEST_REC}" ]; then
  DIGEST_WRITTEN=1
  DIGEST_LINES="digest: written ${DIGEST_REC}"
  if [ -s "${DIGEST_BLOCKS}" ]; then
    DIGEST_LINES="${DIGEST_LINES}"$'\n'"digest_blocks: ${DIGEST_BLOCKS}"
  else
    DIGEST_LINES="${DIGEST_LINES}"$'\n'"digest_blocks: MISSING ${DIGEST_BLOCKS}"
    echo "${ME}: run ${ts}: the digest text was written but its Block Kit is MISSING (${DIGEST_BLOCKS} absent or empty)." >&2
    echo "  Fix: read ${log}; the architect should pass --blocks-out \"\$CLUSTERING_DIGEST_BLOCKS\" (athena:epic-clustering -> The daily digest). The text record stands." >&2
  fi
else
  DIGEST_LINES="digest: MISSING ${DIGEST_REC} (due this morning; no digest file was written; see this run's outcome)"
  echo "${ME}: run ${ts}: the daily digest was due but is MISSING (${DIGEST_REC} absent or empty); ${DIGEST_DAY} not stamped." >&2
  echo "  Fix: read ${log}. If the session failed or was blocked, that is the cause; otherwise the architect should write the digest to \$CLUSTERING_DIGEST (athena:epic-clustering -> The daily digest). A re-run before noon ${OWNER_TZ} writes it." >&2
fi
# notice_lines <notices-file> — the .run record's notice: lines (DND-1749).
# The architect writes "closed DND-N" per won't-fix closure; the top-level
# session writes "posted DND-N <channel>/<ts>" or "failed DND-N <why>" per
# notice. Each closure gets ONE line: posted, or NOT POSTED with the session's
# why, or NOT POSTED because nothing was recorded. A line that parses as none
# of these is UNREADABLE, never dropped. No closure at all is "none", naming
# the file, so an empty result says which file it read.
notice_lines() {
  local f="$1" none
  none="notice: none (no won't-fix closure recorded in ${f})"
  if [ ! -s "${f}" ]; then
    printf '%s\n' "${none}"
    return 0
  fi
  awk -v f="${f}" -v none="${none}" '
    function add(id) { if (!(id in seen)) { seen[id] = 1; order[++n] = id } }
    function okid(s) { return s ~ /^DND-[0-9]+$/ }
    function okuuid(s) { return s ~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/ }
    function setveto(id, v) {
      if (!(id in veto) || veto[id] == v) veto[id] = v
      else if (veto[id] !~ /^CONFLICT /) veto[id] = "CONFLICT " veto[id] " | " v
      else veto[id] = veto[id] " | " v
    }
    { sub(/\r$/, "") }
    NF == 0 { next }
    $1 == "closed" && NF == 2 && okid($2) { add($2); next }
    $1 == "posted" && NF == 3 && okid($2) && $3 ~ /^[A-Z0-9]+\/[0-9]+\.[0-9]+$/ { post[$2] = $3; add($2); next }
    $1 == "failed" && NF >= 3 && okid($2) {
      why = $0; sub(/^[ \t]*failed[ \t]+[^ \t]+[ \t]+/, "", why); fail[$2] = why; add($2); next
    }
    # DND-1758: which veto the notice offers. A grant names its id (a
    # canonical lowercase UUID) and the approval message; a by-hand fallback
    # names its reason (epic-clustering veto-form prints the line).
    # Two different veto lines for one ticket are a CONFLICT, never "the last
    # one wins": the record cannot say which form the owner got.
    $1 == "veto" && NF == 5 && okid($2) && $3 == "grant" && okuuid($4) && $5 ~ /^[A-Z0-9]+\/[0-9]+\.[0-9]+$/ {
      setveto($2, "grant " $4 " " $5); add($2); next
    }
    $1 == "veto" && NF == 4 && okid($2) && $3 == "by-hand" \
      && $4 ~ /^(no_tool|class_unsupported|request_unbuilt|malformed_result|refused:[a-z_]+)$/ {
      setveto($2, "by-hand " $4); add($2); next
    }
    { bad[++nb] = sprintf("notice: UNREADABLE %s line %d: %s", f, NR, $0) }
    END {
      for (i = 1; i <= n; i++) {
        id = order[i]
        v = (id in veto) ? veto[id] : sprintf("UNSTATED (no veto line in %s)", f)
        if (id in post)      printf "notice: posted %s %s veto=%s\n", post[id], id, v
        else if (id in fail) printf "notice: NOT POSTED %s %s; veto=%s\n", id, fail[id], v
        else                 printf "notice: NOT POSTED %s (no post recorded in %s); veto=%s\n", id, f, v
      }
      for (i = 1; i <= nb; i++) print bad[i]
      if (n == 0 && nb == 0) print none
    }' "${f}"
}
# notice_summary <outcome> — sets NOTICE_LINES for the .run record and says on
# stderr, with a Fix:, when a notice is not shown posted. A session that
# reached the model but did not finish ok may have closed a ticket before it
# recorded the closure, so its empty file is UNKNOWN, never "none".
notice_summary() {
  local outcome="$1" problems
  NOTICE_LINES="$(notice_lines "${NOTICES}")" \
    || NOTICE_LINES="notice: UNREADABLE ${NOTICES} (could not be read; see this run's log)"
  if [ "${outcome}" != ok ] && [ -e "${RECEIPT}" ] && [ ! -s "${NOTICES}" ]; then
    NOTICE_LINES="notice: UNKNOWN (the session reached the model and ended ${outcome}; a won't-fix closure may be unrecorded in ${NOTICES})"
  fi
  problems="$(grep -e '^notice: NOT POSTED ' -e '^notice: UNREADABLE ' -e '^notice: UNKNOWN ' <<<"${NOTICE_LINES}" || true)"
  if [ -n "${problems}" ]; then
    echo "${ME}: run ${ts}: a won't-fix notice is not shown posted, so the owner may not know of the closure:" >&2
    sed 's/^/  /' <<<"${problems}" >&2
    echo "  Fix: read ${log} and ${NOTICES}; check Notion for tickets this run set to Won't Fix, and post each one's notice to the owner by hand (athena:epic-clustering -> Won't-fix notices), or reopen the ticket." >&2
  fi
  # DND-1758: a veto the record cannot state, a conflicting one, a request the
  # architect never built, or a grant request the server refused for a reason
  # other than lacking the tool or the class, is loud. no_tool and
  # class_unsupported are the expected fallback until the server ships the
  # class, so they are recorded and quiet. This is the one home of that
  # quiet set (athena:epic-clustering -> Won't-fix notices cites it).
  problems="$(grep -e ' veto=UNSTATED ' -e ' veto=CONFLICT ' -e ' veto=by-hand refused:' \
    -e ' veto=by-hand malformed_result' -e ' veto=by-hand request_unbuilt' <<<"${NOTICE_LINES}" || true)"
  [ -n "${problems}" ] || return 0
  echo "${ME}: run ${ts}: a won't-fix notice's veto is not the grant the server should have given, or is not recorded:" >&2
  sed 's/^/  /' <<<"${problems}" >&2
  echo "  Fix: read ${log} and ${NOTICES}. veto=UNSTATED: the poster skipped epic-clustering veto-form; veto=CONFLICT: it recorded two forms, so check the owner's DM for which one was posted; request_unbuilt: the architect sent no veto-request file; refused:<code> or malformed_result: the server refused or garbled the ticket.wontfix_veto request (ai/contracts/athena-events.md -> Owner approval grants -> The \`ticket.wontfix_veto\` class). A by-hand notice still lets the owner veto in Notion." >&2
}
# finish <exit> <outcome> — every tick that spawned a session ends here. It
# writes runs/<ts>.run and sends ONE harness-lane drain request re: it
# (DND-987, the W10 harness lane: a clustering pass may have reordered its
# queue). A failed send is noted in the record and on stderr; it never changes
# the exit code and never counts toward the wedge or the blocked streak.
finish() {
  local rc="$1" outcome="$2" run="${LOG_DIR}/${ts}.run" body name err
  notice_summary "${outcome}"
  {
    printf '%s: run %s outcome=%s exit=%s\n' "${ME}" "${ts}" "${outcome}" "${rc}"
    printf 'log=%s\n' "${log}"
    printf '%s\n' "${DIGEST_LINES}"
    printf '%s\n' "${NOTICE_LINES}"
  } >"${run}" 2>/dev/null || true
  body="$(new_body)" && {
    printf 'The epic-clustering cron finished a run (outcome %s, exit %s). This is a drain request for the harness lane (DND-987).\n' "${outcome}" "${rc}"
    printf 'It carries no instruction. The run record named in re: says what ran.\n'
  } >"${body}"
  err="$(mktemp)" || err=/dev/null
  # The request's reader is athena:inbox-attend → *A fourth writer*, which
  # routes a `-harness-lane-drain.md` message to
  # ai/docs/ticket-lane-action-brief.md → *The harness lane* → *On a drain
  # request*. The self-test asserts that landed reader handles this slug.
  if [ -n "${body:-}" ] && name="$(harness_alert_send "${run}" harness-lane-drain "${body}" 2>"${err}")"; then
    printf 'drain: sent %s\n' "${name}" >>"${run}" 2>/dev/null || true
  else
    printf 'drain: FAILED to send\n' >>"${run}" 2>/dev/null || true
    echo "${ME}: the harness-lane drain request could NOT be sent: $(tr '\n' ' ' <"${err}" 2>/dev/null)" >&2
    echo "  Fix: run inbox-doctor from ${MAIN_CHECKOUT}. The lane drains on its own schedule meanwhile; the next run sends a new request. Record: ${run}" >&2
  fi
  [ -z "${body:-}" ] || rm -f "${body}"
  [ "${err}" = /dev/null ] || rm -f "${err}"
  exit "${rc}"
}

# A session with no receipt never reached the model. Exit 0, or a known block
# signature on a non-zero exit, is BLOCKED: never counted toward the wedge (a
# usage limit clears on its own), but BLOCK_ESCALATE in a row send one alert
# (an auth or account fault does not clear). Anything else with no receipt is a
# failure (a missing binary or a crash must still wedge).
# The wordings live in scripts/lib/block-signature.sh (DND-1560).
if [ ! -e "${RECEIPT}" ]; then
  sig="$(athena_block_signature "${log}")"
  if [ "${status}" -eq 0 ] || [ -n "${sig}" ]; then
    blocked_track "${status}" "${sig}"
    finish 69 blocked
  fi
  record_failure "the session exited ${status} and never reported for duty (no receipt)" "session_exit=${status}"
  echo "${ME}: run ${ts} exited ${status} and never reported for duty. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log}; check that ${CLAUDE} runs by hand ('${CLAUDE} --version'). If the log shows a provider limit, add its wording to ATHENA_BLOCK_PATTERNS in ${BLOCK_LIB}." >&2
  finish "${status}" failed
fi
# A limit that lands AFTER the receipt (DND-1560): the session reached the
# model, did no work (no summary, no recorded won't-fix closure) and exited
# non-zero with a known limit or auth message. The provider stopped it, so it
# is BLOCKED and never counted: a limit clears on its own, and a wedge needs a
# manual re-arm. A summary or a closure is evidence of work, so a run that has
# either keeps its failure (a closure may be unrecorded; notice_summary says so).
if [ "${status}" -ne 0 ] && [ ! -s "${SUMMARY}" ] && [ ! -s "${NOTICES}" ]; then
  sig="$(athena_block_signature "${log}")"
  if [ -n "${sig}" ]; then
    blocked_track "${status}" "${sig}"
    finish 69 blocked
  fi
fi
# The session reached the model: any blocked streak and its episode end here.
rm -f "${BLOCK_COUNT}" "${BLOCK_STATE}"
if [ "${status}" -ne 0 ]; then
  record_failure "the session exited ${status}" "session_exit=${status}"
  echo "${ME}: run ${ts} exited ${status}. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log} for why the pass failed (124 is the ${TIMEOUT} timeout). ${FAIL_ESCALATE} in a row wedge the lane." >&2
  finish "${status}" failed
fi
if [ ! -s "${SUMMARY}" ]; then
  record_failure "the session exited 0 but wrote no summary, so the pass cannot be shown to have run" "session_exit=0" "summary=${SUMMARY} (absent or empty)"
  echo "${ME}: run ${ts} exited 0 with no summary; counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log}; the architect should finish with one line that the session writes to \$CLUSTERING_SUMMARY." >&2
  finish 70 failed
fi

reset_fail
if [ "${DIGEST_WRITTEN}" -eq 1 ]; then
  printf '%s\n' "${owner_day}" >"${DIGEST_DAY}"
fi
echo "${ME}: run ${ts} ok: $(head -n1 "${SUMMARY}")" >&2
finish 0 ok
