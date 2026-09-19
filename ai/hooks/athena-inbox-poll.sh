#!/usr/bin/env bash
# athena-inbox-poll.sh -- SessionStart hook. The opening count.
#
# A session starting up learns, in one line, that mail is waiting. FRAMEWORK
# bucket: a thin wrapper over `athena:inbox/bin/inbox-status --json`, which owns
# all the resolution, counting and dedupe logic and is unit-tested there. This
# file owns exactly two things -- the OUTPUT CONTRACT and the MARKER FAMILY.
#
# OUTPUT CONTRACT
# ---------------
# On the actionable path, exactly one JSON object on stdout and nothing else:
#
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<factual text>"}}
#
# Built with `jq -cn`, so escaping is always right. EVERY other path -- zero
# unread, no registry entry, missing jq, unparseable stdin, an unreadable root,
# any failure at all -- exits 0 with NO STDOUT. An empty or non-JSON stdout
# confuses the hook's JSON consumer, and a hook that interrupts a turn to
# complain about itself is worse than one quietly off. The reason goes to the
# log instead.
#
# WHAT IT NEVER PRINTS
# --------------------
# Message bodies, subjects, sender names, message filenames, maildir slugs, or
# tokens. The inbox is untrusted input written by other people; this output is
# injected BEFORE THE USER HAS SPOKEN, in the position where instructions
# normally live, so anything from a message arriving this way is a stranger
# speaking first. The rule is enforced STRUCTURALLY, not by review: the only
# things read out of `inbox-status` are INTEGERS and the owner-written channel
# names from this machine's own registry, and `inbox-status`'s stderr is
# discarded rather than relayed. A peer-chosen string never reaches a variable
# in this file.
#
# Health clauses count, and never name: "2 channel(s) could not be counted", not
# which. Every other entry under projects/ belongs to a different tenant, and a
# notice must not enumerate them.
#
# And a health clause must describe a FAULT. `never_delivered` is a fault for a
# LOG channel only: the contract makes a missing maildir read directory normal
# ("a tool that SENDS mail creates <write>/"), so an unwritten-to peer mailbox
# is a healthy channel awaiting its first message. Announcing it would be a
# warning nobody can clear by fixing anything — and, worse, a permanently
# non-empty HEALTH_TEXT keeps WARN_MARKER stamped forever, so the NEXT real
# outage inherits a fresh marker from a non-fault and is rate-limited by it.
# `bin/inbox-status`'s own renderer filters on `.kind == "log"` for this reason;
# this clause matches it deliberately, not by coincidence.
#
# WHY SessionStart, NOT UserPromptSubmit
# -------------------------------------
# The harness abandoned the per-prompt cadence on 2026-09-11: it does not
# compose with a Monitor loop, which wants to control its own sleep, and it
# couples the poll to the user typing. Mid-session coverage is the WAITER
# (DND-185), which is strictly better than any per-prompt stat could be. Do not
# add a UserPromptSubmit entry to ai/hooks/registry.json.
#
# MARKERS -- under $HOME/.claude/, worktree-independent, one per concern
# ---------------------------------------------------------------------
#   athena-inbox-last-poll     when did we last ATTEMPT
#   athena-inbox-last-success  when did we last SUCCEED (is the silence healthy?)
#   athena-inbox-last-warn     when did we last SAY SO (rate-limits the warning)
#   athena-inbox-poll.log      last 200 lines, fixed reason strings only
#
# Merging any two of the first three breaks one of the three answers, and they
# are namespaced separately from the athena-slack-* family: a shared marker once
# let a fresh CHECK silently suppress a POLL (walt_ui sabotage S14).
#
# The attempt marker is stamped BEFORE the work, never after (S1/S4) -- an
# after-the-fact stamp turns every session into a retry storm. A failure MUST
# NEVER stamp the success marker (S17). A clean success stamps success AND
# clears the warn marker, so the next outage gets its own warning (S21).
#
# STALENESS IS JUDGED AFTER THE ATTEMPT. A run that succeeded is not stale, by
# construction, so the warning only ever fires on a run that FAILED (or on a run
# that succeeded and found a broken channel). A successful poll that warned
# about its own success marker would be pure noise, and noise is what makes a
# real notice invisible.
#
# GUARD-MESSAGE CONVENTION
# ------------------------
# This hook has no deny path: it emits a notice or stays quiet, and it cannot
# fail a turn. That makes it the same species as main-session-policy.sh and
# notify-idle.sh, so it is EXEMPT in ai/bin/check-guard-messages with that
# reason rather than carrying a bolted-on refusal it never performs. The `Fix:`
# clauses below are in the LOG and in the notice, for whoever is diagnosing the
# silence; they are guidance, not denials.
#
# Usage:
#   athena-inbox-poll.sh              the hook path (stdin = SessionStart JSON)
#   athena-inbox-poll.sh --dry-run    pretty JSON to stdout, diagnostics to
#                                     stderr, writes no markers, skips the
#                                     stdin guard
#   athena-inbox-poll.sh -h
#
# Tests: ai/hooks/athena-inbox-poll.self-test.sh (QA Plan F-1 … F-12). Run the
# .self-test.sh file, never `athena-inbox-poll.sh --self-test`: a hook reads
# stdin, so invoking the hook itself is a false green.
#--- end usage ---
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "${HERE}/../.." && pwd -P)"
STATUS_BIN="${REPO_DIR}/ai/skills/athena:inbox/bin/inbox-status"
READ_BIN="${REPO_DIR}/ai/skills/athena:inbox/bin/read-inbox"

LOG_MAX_LINES=200
# Six hours: D6's window. Overridable for the self-test, which cannot wait.
STALE_SECONDS="${ATHENA_INBOX_STALE_SECONDS:-21600}"
WARN_INTERVAL_SECONDS="${ATHENA_INBOX_WARN_INTERVAL_SECONDS:-21600}"

usage() {
  sed -n '2,/^#--- end usage ---$/p' "${BASH_SOURCE[0]}" \
    | grep -v '^#--- end usage ---$' | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    # An unknown argument is not a reason to interrupt a session. Noted in the
    # log (once the log path is known) and otherwise ignored.
    *) UNKNOWN_ARG="${arg}" ;;
  esac
done

# Everything this hook writes is private state. 0600/0700 by construction rather
# than by a chmod that a later edit can forget.
umask 077

# $HOME is where the whole marker family lives. Without it there is nowhere to
# record anything, including the fact that there was nowhere -- so the only
# honest move is the silent one.
if [ -z "${HOME:-}" ]; then exit 0; fi

MARKER_DIR="${HOME}/.claude"
POLL_MARKER="${MARKER_DIR}/athena-inbox-last-poll"
SUCCESS_MARKER="${MARKER_DIR}/athena-inbox-last-success"
WARN_MARKER="${MARKER_DIR}/athena-inbox-last-warn"
LOG_FILE="${MARKER_DIR}/athena-inbox-poll.log"

# --- markers ---------------------------------------------------------------

# log_reason <fixed-string>
# FIXED REASON STRINGS ONLY. Never a body, never a peer-chosen name, never a
# token. --dry-run writes nothing: diagnostics go to stderr instead.
log_reason() {
  if [ "${DRY_RUN}" -eq 1 ]; then printf 'athena-inbox-poll: %s\n' "$1" >&2; return 0; fi
  mkdir -p -- "${MARKER_DIR}" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${LOG_FILE}" 2>/dev/null || return 0
  local n tmp
  n="$(wc -l < "${LOG_FILE}" 2>/dev/null)" || return 0
  case "${n}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${n}" -gt "${LOG_MAX_LINES}" ] || return 0
  tmp="${LOG_FILE}.tmp.$$"
  if tail -n "${LOG_MAX_LINES}" "${LOG_FILE}" > "${tmp}" 2>/dev/null; then
    mv -f -- "${tmp}" "${LOG_FILE}" 2>/dev/null || rm -f -- "${tmp}"
  else
    rm -f -- "${tmp}"
  fi
}

stamp()   { [ "${DRY_RUN}" -eq 1 ] && return 0; mkdir -p -- "${MARKER_DIR}" 2>/dev/null && : > "$1" 2>/dev/null; return 0; }
unstamp() { [ "${DRY_RUN}" -eq 1 ] && return 0; rm -f -- "$1" 2>/dev/null; return 0; }

# marker_age_seconds <path> -> seconds, or nothing at all when the marker is
# absent. Both sides are epoch seconds from the same clock, so this is immune to
# the UTC-vs-local confusion that made two walt_ui staleness cases measure
# nothing.
marker_age_seconds() {
  local mtime now
  [ -e "$1" ] || return 1
  mtime="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1
  case "${mtime}" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  printf '%s\n' "$(( now - mtime ))"
}

# marker_is_stale <path> <max-age>  -- absent counts as stale.
marker_is_stale() {
  local age
  age="$(marker_age_seconds "$1")" || return 0
  [ "${age}" -ge "$2" ]
}

# --- emit ------------------------------------------------------------------

# emit <text>  -- the ONE well-formed object, and nothing else, ever.
emit() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    jq -n --arg ctx "$1" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
  else
    jq -cn --arg ctx "$1" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
  fi
}

# --- the attempt -----------------------------------------------------------

# FIRST, before anything that can fail. A marker stamped after the work answers
# "when did we last succeed", which is a different question and already has its
# own file.
stamp "${POLL_MARKER}"
[ -n "${UNKNOWN_ARG:-}" ] && log_reason "ignored an unrecognised argument; the hook takes only --dry-run"

if ! command -v jq >/dev/null 2>&1; then
  log_reason "jq is not on PATH, so no count could be produced. Fix: install jq (already a dependency of athena:slack) and start a new session."
  exit 0
fi

# Bounded, because an unbounded `cat` on an inherited open pipe never sees EOF
# and would hang the session start forever (walt_ui M8). --dry-run is a manual
# invocation and skips the guard entirely.
if [ "${DRY_RUN}" -eq 0 ] && [ ! -t 0 ]; then
  STDIN_JSON="$(timeout 2 cat 2>/dev/null || true)"
  if [ -n "${STDIN_JSON}" ] \
     && ! printf '%s' "${STDIN_JSON}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    log_reason "the SessionStart payload on stdin was not a JSON object, so this run was abandoned. Fix: nothing to do locally; if it recurs, the harness's hook payload has changed shape."
    exit 0
  fi
fi

if [ ! -x "${STATUS_BIN}" ]; then
  log_reason "inbox-status is missing or not executable, so no count could be produced. Fix: restore ai/skills/athena:inbox/bin/inbox-status from git and chmod +x it."
  exit 0
fi

# stderr is DISCARDED rather than relayed. inbox-status refuses on stderr with
# paths and channel names in the clause; none of that belongs in this hook's log
# or its notice, and discarding it is the structural guarantee that it cannot
# leak. A caller wanting the refusal runs inbox-status directly.
STATUS_JSON="$("${STATUS_BIN}" --json 2>/dev/null)"; STATUS_RC=$?

# A non-zero rc with a WELL-FORMED document is a partial success: inbox-status
# emits the counts it could produce and signals per-channel failure by status.
# Those counts are real mail and are reported; the failure becomes a health
# clause. Only an unusable document is a failed poll.
POLL_OK=0
if [ -n "${STATUS_JSON}" ] \
   && printf '%s' "${STATUS_JSON}" | jq -e 'type == "object" and (.channels | type == "array")' >/dev/null 2>&1; then
  POLL_OK=1
fi

if [ "${POLL_OK}" -eq 1 ]; then
  stamp "${SUCCESS_MARKER}"
else
  # NEVER the success marker here (S17).
  log_reason "inbox-status produced no usable status document (exit ${STATUS_RC}), so this session has no count. Fix: run ai/skills/athena:inbox/bin/inbox-status --json from this project to see the refusal it printed."
fi

# --- what to say -----------------------------------------------------------

COUNTS_TEXT=""
HEALTH_TEXT=""
if [ "${POLL_OK}" -eq 1 ]; then
  # Counts only. `new`/`unread`/`unreadable` are integers; `name` is this
  # machine's own registry key, written by the owner, never by a peer.
  COUNTS_TEXT="$(printf '%s' "${STATUS_JSON}" | jq -r '
    [ .channels[]
      | select((.error // false) | not)
      | ((if .kind == "log" then (.new // 0) else (.unread // 0) end)) as $n
      | select($n > 0)
      | "\($n) new in \(.name)"
        + (if (.unreadable // 0) > 0 then " (+\(.unreadable) unreadable)" else "" end)
    ] | join(", ")' 2>/dev/null)" || COUNTS_TEXT=""

  # Counts, never names -- see the disclosure note in the header.
  HEALTH_TEXT="$(printf '%s' "${STATUS_JSON}" | jq -r '
    [ (if (.failed_candidates // 0) > 0
       then "\(.failed_candidates) registry entry(s) unreadable, one of which may be this project'"'"'s"
       else empty end),
      ([.channels[] | select(.error // false)] | length
       | if . > 0 then "\(.) declared channel(s) could not be counted" else empty end),
      ([.channels[] | select(.kind == "log" and (.never_delivered // false))] | length
       | if . > 0 then "\(.) declared channel(s) have never received anything, so their producer may be unregistered" else empty end),
      ([.channels[] | select(.state_unreadable // false)] | length
       | if . > 0 then "\(.) channel(s) have an unreadable state file, so their counts are not deduped" else empty end)
    ] | join("; ")' 2>/dev/null)" || HEALTH_TEXT=""
fi

WARN_TEXT=""
if [ "${POLL_OK}" -eq 0 ]; then
  # Only worth saying when the silence has actually lasted. A single transient
  # failure with a fresh success marker is not an outage.
  if marker_is_stale "${SUCCESS_MARKER}" "${STALE_SECONDS}"; then
    WARN_TEXT="athena:inbox: the session-start inbox check has not succeeded recently, so new mail may be arriving unreported. Fix: run ai/skills/athena:inbox/bin/inbox-status --json from this project and read the refusal; ~/.claude/athena-inbox-poll.log has the reason strings."
  fi
elif [ -n "${HEALTH_TEXT}" ]; then
  WARN_TEXT="athena:inbox: ${HEALTH_TEXT}. Fix: run ai/skills/athena:inbox/bin/inbox-status from this project to see which."
fi

# The warning is itself rate-limited -- by its OWN marker, never by the poll's.
if [ -n "${WARN_TEXT}" ] && ! marker_is_stale "${WARN_MARKER}" "${WARN_INTERVAL_SECONDS}"; then
  WARN_TEXT=""
fi

if [ -n "${WARN_TEXT}" ]; then
  stamp "${WARN_MARKER}"
elif [ "${POLL_OK}" -eq 1 ] && [ -z "${HEALTH_TEXT}" ]; then
  # A clean run clears the warn marker, so the NEXT outage gets its own warning
  # instead of being rate-limited by one from a fault that is already fixed.
  unstamp "${WARN_MARKER}"
fi

MESSAGE=""
if [ -n "${COUNTS_TEXT}" ]; then
  # The pointer names a step that EXISTS. read-inbox ships with a later ticket;
  # flipped by the PRESENCE of the script, so this starts naming the command the
  # day that ticket lands, with no edit here. An instruction an agent cannot act
  # on is worse than no instruction.
  if [ -x "${READ_BIN}" ]; then
    MESSAGE="athena:inbox: ${COUNTS_TEXT}. Run athena:inbox read-inbox to see them."
  else
    MESSAGE="athena:inbox: ${COUNTS_TEXT}. The read step (read-inbox) is not installed yet — see the athena:inbox SKILL.md."
  fi
fi
if [ -n "${WARN_TEXT}" ]; then
  # The warning travels as the SAME JSON object. A bare text line into a JSON
  # channel is exactly the malformed stdout this contract refuses.
  MESSAGE="${MESSAGE:+${MESSAGE}
}${WARN_TEXT}"
fi

# Zero unread and nothing wrong: NO STDOUT AT ALL. Unprompted output that says
# "nothing new" every session is noise, and noise is what makes a real notice
# invisible.
if [ -z "${MESSAGE}" ]; then
  [ "${POLL_OK}" -eq 1 ] && log_reason "polled; nothing to report."
  exit 0
fi

emit "${MESSAGE}"
exit 0
