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
# The failed-candidate clause says "OTHER projects are dark", not "one of these
# may be mine", and the difference is load-bearing. `inbox_entry` makes the
# no-match-plus-unparseable-candidate case a HARD REFUSAL -- inbox-status exits
# 1 with empty stdout, which arrives here as a failed poll and the outage
# warning. So by the time a health clause can render at all, this project's own
# entry HAS been found and the unreadable ones provably belong to somebody
# else. The clause is still worth printing, because no session of theirs is
# going to notice their registry rotted; it just must not claim a doubt that
# has already been resolved.
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
# GLOBAL -- about the machine, not about any one project:
#   athena-inbox-last-poll     when did we last ATTEMPT
#   athena-inbox-poll.log      last 200 lines, fixed reason strings only
#
# PER-PROJECT, under athena-inbox-seen/<hash-of-repo-key>. -- the poll outcome
# is per repo, and this hook runs in every repo on the machine:
#   <hash>.success        when did THIS project last SUCCEED
#   <hash>.warn           when did we last say ITS poll is broken
#   <hash>.health-warn    when did we last say its poll found a fault
#   <hash>.seen           this project HAD channels once
#   <hash>.vanished-warn  when did we last say they had vanished
#
# The $HOME-level athena-inbox-last-{success,warn,health-warn} names remain as
# the DEGRADED fallback, used only when the project identity cannot be resolved
# -- which always logs a Fix: first, because sharing this state between projects
# is the defect the per-project keying exists to close.
#
# Merging any two of these breaks one of the answers, and they are namespaced
# separately from the athena-slack-* family: a shared marker once let a fresh
# CHECK silently suppress a POLL (walt_ui sabotage S14).
#
# EVERY WARNING HAS ITS OWN MARKER, per concern AND per project, for that same
# reason. "The poll is not working", "the poll works and found a fault
# downstream" and "this project's entry has vanished" have different owners and
# very different lifetimes: a benign health fault is a state the
# reader may live with for weeks, re-stamping on its own cadence, while an
# outage is urgent and new. Sharing one marker lets the chronic one rate-limit
# the urgent one into silence for a whole window.
#
# The attempt marker is stamped BEFORE the work, never after (S1/S4) -- an
# after-the-fact stamp turns every session into a retry storm. A failure MUST
# NEVER stamp the success marker (S17). A run that SUCCEEDED clears the outage
# marker whatever it found downstream, so the next outage gets its own warning
# (S21); a clean bill of health additionally clears the health marker.
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
DOCTOR_BIN="${REPO_DIR}/ai/skills/athena:inbox/bin/inbox-doctor"

LOG_MAX_LINES=200
# Six hours: D6's window. Overridable for the self-test, which cannot wait.
STALE_SECONDS="${ATHENA_INBOX_STALE_SECONDS:-21600}"
WARN_INTERVAL_SECONDS="${ATHENA_INBOX_WARN_INTERVAL_SECONDS:-21600}"
# Guarded like every other number read from outside this file. Unguarded, a
# non-numeric value made `[ "${age}" -ge "$2" ]` error, which marker_is_stale
# reports as NOT STALE -- so a typo in an environment variable silently
# SUPPRESSED the warning instead of failing loudly. That is the wrong failure
# direction for the one mechanism whose job is to break a silence.
case "${STALE_SECONDS}" in ''|*[!0-9]*) STALE_SECONDS=21600 ;; esac
case "${WARN_INTERVAL_SECONDS}" in ''|*[!0-9]*) WARN_INTERVAL_SECONDS=21600 ;; esac
# The ceiling on the wrapped command. Generous for a file scan, and far below
# any delay a person would tolerate at session start.
STATUS_TIMEOUT_SECONDS="${ATHENA_INBOX_STATUS_TIMEOUT_SECONDS:-10}"
case "${STATUS_TIMEOUT_SECONDS}" in ''|*[!0-9]*) STATUS_TIMEOUT_SECONDS=10 ;; esac
# The delivery-chain health line (DND-190) is ON by default; set
# ATHENA_INBOX_DOCTOR_LINE=0 to opt out (the doctor still runs when invoked by
# hand -- this only suppresses the unprompted SessionStart sentence). The
# doctor's own suite drives every fault case directly; a repo's unrelated hook
# tests set this to 0 so a fault in the doctor's minimal fixture cannot leak a
# line into a case asserting "no stdout".
DOCTOR_LINE_ENABLED=1
case "${ATHENA_INBOX_DOCTOR_LINE:-1}" in 0|off|no) DOCTOR_LINE_ENABLED=0 ;; esac

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
LOG_FILE="${MARKER_DIR}/athena-inbox-poll.log"

# PER-PROJECT state, which is what all of this state actually is.
#
# The poll outcome is per-repo; the marker family used to live one-per-$HOME,
# and this hook runs with the "" matcher -- in EVERY repo on the machine. That
# made one project's session move another project's markers: a healthy sibling
# refreshing the success marker kept a broken project's outage warning six
# hours away forever, and one project's health warning rate-limited another's.
# Both are reachable today; this machine's registry holds several entries.
#
# So the success marker, both warn markers and the seen marker are keyed by the
# project. The ATTEMPT marker and the reason log stay global on purpose: they
# answer "did this machine attempt, and why did it stop", which is not a
# question about any one project.
#
# The identity is the contract's own key, from the skill's PUBLIC surface
# (`inbox-status --repo-key`), never recomputed here -- a second implementation
# of the identity rule is a second thing free to drift from the contract, and
# `--repo-key` exists so that the answer is available even on the path where
# the status document does not (a refusal prints nothing). It is hashed because
# a marker filename must not be a filesystem path, and because the filename
# would otherwise disclose which projects this machine has registered.
SEEN_DIR="${MARKER_DIR}/athena-inbox-seen"
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

# `${1%/*}` rather than `dirname`: the attempt marker must be stampable by a run
# that can do nothing else, and the F-7 fixture proves that by stripping PATH to
# a handful of binaries. A marker writer that reaches for one more external
# command is a marker writer that stops working exactly when it matters most.
stamp()   { [ "${DRY_RUN}" -eq 1 ] && return 0; [ -n "$1" ] || return 0; mkdir -p -- "${1%/*}" 2>/dev/null && : > "$1" 2>/dev/null; return 0; }
unstamp() { [ "${DRY_RUN}" -eq 1 ] && return 0; [ -n "$1" ] || return 0; rm -f -- "$1" 2>/dev/null; return 0; }

# marker_age_seconds <path> -> seconds, or nothing at all when the marker is
# absent. Both sides are epoch seconds from the same clock, so this is immune to
# the UTC-vs-local confusion that made two walt_ui staleness cases measure
# nothing.
marker_age_seconds() {
  local mtime now
  [ -n "$1" ] && [ -e "$1" ] || return 1
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

# THE ATTEMPT MARKER, FIRST -- before anything that can fail, which now
# includes the identity resolution below (it runs an external command under a
# timeout). A marker stamped after the work answers "when did we last succeed",
# which is a different question and already has its own file; and a run killed
# mid-resolution must still leave a record that this machine attempted, which
# is the only question this global marker exists to answer.
stamp "${POLL_MARKER}"

# --- the project identity, and the markers keyed by it ----------------------

PROJECT_HASH=""
if [ ! -x "${STATUS_BIN}" ]; then
  : # reported below, where the missing command actually stops the poll
elif ! command -v sha256sum >/dev/null 2>&1; then
  log_reason "sha256sum is not on PATH, so this project's markers cannot be named and its inbox state would be shared with every other project on this machine. Fix: install coreutils' sha256sum and start a new session."
else
  # --repo-key touches no registry, so a non-zero status here is one of two
  # things, and BOTH are logged rather than silently falling back (the fallback
  # is shared state): either the inbox-status beside this hook PREDATES the
  # option (hook/skill version skew, reachable because settings.json wires one
  # tree's hook path while STATUS_BIN resolves from that tree), or it supports
  # --repo-key but COULD NOT TELL the repo identity (git missing, the cwd gone,
  # or realpath failing). What is NOT logged is an exit 0 with an empty key:
  # that is a genuine non-git cwd, the ordinary case, and it stays silent.
  PROJECT_KEY="$(timeout "${STATUS_TIMEOUT_SECONDS}" "${STATUS_BIN}" --repo-key 2>/dev/null)"
  REPO_KEY_RC=$?
  if [ "${REPO_KEY_RC}" -eq 124 ] || [ "${REPO_KEY_RC}" -eq 137 ]; then
    # An EXPIRY, handled apart from the other non-zero exits above. --repo-key
    # CAN exit non-zero (version skew, or it could-not-tell the identity), but a
    # 124/137 is specifically the `timeout` wrapping it firing -- which is the
    # whole reason that wrapper is here (an inbox root on a slow or stale mount).
    # Diagnosing it as skew or a git failure would send the reader chasing a
    # transient condition, so it gets its own reason string.
    log_reason "inbox-status --repo-key did not finish within ${STATUS_TIMEOUT_SECONDS}s, so this project's markers cannot be named and its inbox state would be shared with every other project on this machine. Fix: something under \${ATHENA_INBOX_ROOT:-~/.local/share/athena} or this repo's .git is slow to stat — check for a stale network mount, or raise ATHENA_INBOX_STATUS_TIMEOUT_SECONDS."
    PROJECT_KEY=""
  elif [ "${REPO_KEY_RC}" -eq 0 ]; then
    PROJECT_KEY="${PROJECT_KEY%$'\n'}"
    if [ -n "${PROJECT_KEY}" ]; then
      PROJECT_HASH="$(printf '%s' "${PROJECT_KEY}" | sha256sum 2>/dev/null | cut -c1-32)"
      case "${PROJECT_HASH}" in
        ''|*[!0-9a-f]*)
          # sha256sum present but failing, or cut missing. A THIRD route to an
          # empty hash, and it must log like the other two: the fallback it
          # drops into is the shared marker family, which is the defect the
          # per-project keying exists to close.
          log_reason "this project's identity could not be hashed, so its markers cannot be named and its inbox state would be shared with every other project on this machine. Fix: check that sha256sum and cut behave normally on this machine."
          PROJECT_HASH=""
          ;;
      esac
    fi
    # An EMPTY key is a cwd in no git repository. Nothing here could ever have
    # had channels, so there is nothing to remember and nothing to report --
    # the ordinary case for most directories on this machine.
  else
    log_reason "inbox-status could not name this project's repo identity, so its markers cannot be named and its inbox state would be shared with every other project on this machine. Fix: either the inbox-status beside this hook predates --repo-key (check that ai/skills/athena:inbox and ai/hooks come from the same checkout), or git/realpath could not run in this session (check that git is on PATH and the cwd still exists)."
  fi
fi

if [ -n "${PROJECT_HASH}" ]; then
  SUCCESS_MARKER="${SEEN_DIR}/${PROJECT_HASH}.success"
  WARN_MARKER="${SEEN_DIR}/${PROJECT_HASH}.warn"
  HEALTH_WARN_MARKER="${SEEN_DIR}/${PROJECT_HASH}.health-warn"
  # A THIRD downstream concern with its OWN rate limit: "inbox-doctor found the
  # delivery chain unhealthy" is neither "the poll is broken" (WARN_MARKER) nor
  # "a declared channel has never received" (HEALTH_WARN_MARKER). A client the
  # supervisor stopped, a config override that names no live instance, a cron
  # entry that fell out -- those are chain faults the doctor sees and the count
  # cannot, and merging their marker with either of the others lets one chronic
  # concern rate-limit the other into silence for a whole window (walt_ui S14).
  DOCTOR_WARN_MARKER="${SEEN_DIR}/${PROJECT_HASH}.doctor-warn"
  SEEN_MARKER="${SEEN_DIR}/${PROJECT_HASH}.seen"
else
  # Degraded, and said so above. The $HOME-level names are the old shared ones:
  # worse than per-project, but still better than no rate limit at all, and
  # every route here has left a Fix: in the log.
  SUCCESS_MARKER="${MARKER_DIR}/athena-inbox-last-success"
  WARN_MARKER="${MARKER_DIR}/athena-inbox-last-warn"
  HEALTH_WARN_MARKER="${MARKER_DIR}/athena-inbox-last-health-warn"
  DOCTOR_WARN_MARKER="${MARKER_DIR}/athena-inbox-last-doctor-warn"
  SEEN_MARKER=""
fi
# The vanished-entry warning is a DIFFERENT CONCERN from the outage warning
# even now that both are per-project, so it keeps its own rate limit.
SEEN_WARN_MARKER="${SEEN_MARKER:+${SEEN_MARKER%.seen}.vanished-warn}"

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
#
# BOUNDED, for the same reason the stdin read is. This hook has two blocking
# inputs and had a ceiling on only one of them: inbox-status scans channel files
# with no timeout, so a very large .jsonl or an inbox root on a stale or slow
# mount would block SessionStart for as long as it took. An expiry is just
# another failed poll, which the path below already handles correctly -- the
# success marker stays unstamped and the staleness warning can eventually fire.
STATUS_JSON="$(timeout "${STATUS_TIMEOUT_SECONDS}" "${STATUS_BIN}" --json 2>/dev/null)"; STATUS_RC=$?

# A non-zero rc with a WELL-FORMED document is a partial success: inbox-status
# emits the counts it could produce and signals per-channel failure by status.
# Those counts are real mail and are reported; the failure becomes a health
# clause. Only an unusable document is a failed poll.
POLL_OK=0
if [ -n "${STATUS_JSON}" ] \
   && printf '%s' "${STATUS_JSON}" | jq -e 'type == "object" and (.channels | type == "array")' >/dev/null 2>&1; then
  POLL_OK=1
fi

# A THIRD STATE, and the one that matters most on this machine.
#
# `{"channels":[]}` is the answer for a project that never opted in -- and this
# hook is registered with the "" matcher, so it runs in EVERY repo on the
# machine, while the marker family lives under $HOME and is shared by all of
# them. Counting that answer as a successful poll made the outage warning
# STRUCTURALLY UNREACHABLE: one session in any unrelated repo refreshed
# SUCCESS_MARKER and cleared the warn markers, so the six-hour staleness test
# could never come due no matter how broken the opted-in project's poll was.
#
# It is not a failure either -- not opting in is not a fault, and warning about
# it in every repo is exactly the noise that makes a real notice invisible. So
# it is NEITHER: nothing stamped, nothing cleared, nothing printed, one line in
# the log. The opted-in project's markers are then only ever moved by that
# project's own sessions, which is what makes them mean anything.
OPTED_IN=1
if [ "${POLL_OK}" -eq 1 ] \
   && printf '%s' "${STATUS_JSON}" | jq -e '(.channels | length) == 0' >/dev/null 2>&1; then
  OPTED_IN=0
fi

if [ "${POLL_OK}" -eq 1 ] && [ "${OPTED_IN}" -eq 1 ]; then
  stamp "${SUCCESS_MARKER}"
  # This project HAS channels. Remembered so that their later disappearance can
  # be told apart from never having had any.
  stamp "${SEEN_MARKER}"
elif [ "${POLL_OK}" -eq 0 ]; then
  # NEVER the success marker here (S17).
  log_reason "inbox-status produced no usable status document (exit ${STATUS_RC}), so this session has no count. Fix: run ai/skills/athena:inbox/bin/inbox-status --json from this project to see the refusal it printed."
else
  log_reason "no registry entry declares a channel for this project, so there is nothing to poll here; the marker family was left untouched."
fi

# --- what to say -----------------------------------------------------------

COUNTS_TEXT=""
HEALTH_TEXT=""
# How many registry entries could not be parsed. Kept as its own integer
# because it is the one health clause inbox-status cannot elaborate on, so it
# selects a different Fix: sentence below.
HEALTH_CANDIDATES=0
# Counts of never-delivered channels by producer kind (set below when the poll
# succeeded), initialised here so they are defined under `set -u` on every path.
NEVER_PLATFORM=0
NEVER_SLACK=0
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
        # The caveat rides the NUMBER, not the warning. state_unreadable means
        # the channel was re-read from offset 0 with empty seen-sets, so this
        # count includes messages already acked. Leaving that in HEALTH_TEXT
        # meant the rate limit on the warning laundered the figure: for up to a
        # whole window the notice read "12 new" as plain fact. inbox-status
        # attaches its own per-channel Fix: unconditionally, for this reason.
        + (if (.state_unreadable // false) then " (not deduped — includes already-read messages)" else "" end)
    ] | join(", ")' 2>/dev/null)" || COUNTS_TEXT=""

  # Counts, never names -- see the disclosure note in the header.
  HEALTH_TEXT="$(printf '%s' "${STATUS_JSON}" | jq -r '
    [ (if (.failed_candidates // 0) > 0
       then "\(.failed_candidates) other registry entry(s) could not be parsed, so those projects are dark"
       else empty end),
      ([.channels[] | select(.error // false)] | length
       | if . > 0 then "\(.) declared channel(s) could not be counted" else empty end),
      ([.channels[] | select(.kind == "log" and (.never_delivered // false))] | length
       | if . > 0 then "\(.) declared channel(s) have never received anything, so their producer may be unregistered" else empty end),
      ([.channels[] | select(.state_unreadable // false)] | length
       | if . > 0 then "\(.) channel(s) have an unreadable state file, so their counts are not deduped" else empty end)
    ] | join("; ")' 2>/dev/null)" || HEALTH_TEXT=""

  HEALTH_CANDIDATES="$(printf '%s' "${STATUS_JSON}" | jq -r '.failed_candidates // 0' 2>/dev/null)"
  case "${HEALTH_CANDIDATES}" in ''|*[!0-9]*) HEALTH_CANDIDATES=0 ;; esac

  # Which PRODUCER kinds are among the never-delivered channels. This hook is
  # counts-only for tenant privacy, so it cannot name the channel -- but the
  # registration a reader must do differs by producer (a platform lane wants an
  # athena-events routing rule; a slack channel wants a client-side instance),
  # and a Fix that names only the slack path sends a platform-lane operator to
  # the wrong file. It cannot say WHICH channel, so when both kinds are dark it
  # names BOTH paths rather than guessing one. `.producer` rides the count doc
  # (channel config, not peer content).
  NEVER_PLATFORM="$(printf '%s' "${STATUS_JSON}" | jq -r \
    '[.channels[] | select(.kind=="log" and (.never_delivered // false) and ((.producer // "slack")=="platform"))] | length' 2>/dev/null)"
  case "${NEVER_PLATFORM}" in ''|*[!0-9]*) NEVER_PLATFORM=0 ;; esac
  NEVER_SLACK="$(printf '%s' "${STATUS_JSON}" | jq -r \
    '[.channels[] | select(.kind=="log" and (.never_delivered // false) and ((.producer // "slack")!="platform"))] | length' 2>/dev/null)"
  case "${NEVER_SLACK}" in ''|*[!0-9]*) NEVER_SLACK=0 ;; esac
fi

# TWO CONCERNS, TWO MARKERS. "The poll is not working" and "the poll works and
# found something wrong downstream" are different faults with different owners
# and very different lifetimes: a benign health fault (a declared log channel
# whose producer was never registered) is a state the reader may live with for
# weeks, re-stamping on its own cadence, while an OUTAGE is urgent and new. One
# shared marker lets the chronic one rate-limit the urgent one into silence for
# a whole window -- the exact cross-concern suppression this file's header
# argues against (walt_ui S14), reached from the other side.
WARN_TEXT=""
WARN_TEXT_MARKER=""
if [ "${POLL_OK}" -eq 1 ] && [ "${OPTED_IN}" -eq 0 ] \
   && [ -n "${SEEN_MARKER}" ] && [ -e "${SEEN_MARKER}" ]; then
  # THE VANISHED ENTRY. This project declared channels on some earlier session
  # and declares none now. The registry lives outside git, untracked, so its
  # loss leaves no diff and no undo -- and every other signal here is silent by
  # design, which is exactly what makes this the one worth interrupting for.
  # The Fix names all THREE repairs, because the hook genuinely cannot tell
  # them apart: an entry that is gone, an entry whose `repo` no longer matches,
  # and an entry that is present with an EMPTY `channels` object all produce the
  # same `{"channels":[]}`. Naming only the first two would send the reader
  # looking for a missing file that is sitting right there.
  WARN_TEXT="athena:inbox: this project had inbox channels on an earlier session and declares none now, so its mail is going unread. Fix: its registry entry under \${ATHENA_INBOX_ROOT:-~/.local/share/athena}/projects/ is missing, no longer names this repo, or declares an empty \"channels\" — restore it, or, if the project was retired deliberately, delete ${SEEN_MARKER} to stop this notice."
  WARN_TEXT_MARKER="${SEEN_WARN_MARKER}"
elif [ "${POLL_OK}" -eq 0 ]; then
  # Only worth saying when the silence has actually lasted. A single transient
  # failure with a fresh success marker is not an outage.
  if marker_is_stale "${SUCCESS_MARKER}" "${STALE_SECONDS}"; then
    WARN_TEXT="athena:inbox: the session-start inbox check has not succeeded recently, so new mail may be arriving unreported. Fix: run ai/skills/athena:inbox/bin/inbox-status --json from this project and read the refusal; ~/.claude/athena-inbox-poll.log has the reason strings."
    WARN_TEXT_MARKER="${WARN_MARKER}"
  fi
elif [ "${OPTED_IN}" -eq 1 ] && [ -n "${HEALTH_TEXT}" ]; then
  # The Fix: must answer the question it promises. inbox-status CAN name the
  # channel behind every clause here except one: it is counts-only for tenant
  # privacy, so it can say how many registry entries failed to parse but never
  # which -- naming them would enumerate other tenants. Pointing at it anyway
  # would send an agent to re-run a command that returns the same number, which
  # is the "instruction an agent cannot act on" this file refuses elsewhere.
  if [ "${HEALTH_CANDIDATES}" -gt 0 ]; then
    WARN_TEXT="athena:inbox: ${HEALTH_TEXT}. Fix: check that every file under \${ATHENA_INBOX_ROOT:-~/.local/share/athena}/projects/ is valid JSON — one that is not is dropped from the candidate set, which makes ITS project look like it never opted in. inbox-status cannot say which, by design. For the channel-level clauses, run ai/skills/athena:inbox/bin/inbox-status from this project."
  else
    # Names the CORRECTIVE ACTION, not only the diagnostic. The contract
    # requires a never-delivered channel to be reported "with a Fix: clause
    # naming producer registration"; pointing only at inbox-status discharged
    # that by one indirection, which is a hop an agent reading a pre-prompt
    # line should not have to take. The registration differs by producer, and
    # this hook cannot name the channel (counts-only), so it names the path(s)
    # the dark channels actually need — both, when both kinds are dark.
    if [ "${NEVER_PLATFORM}" -gt 0 ] && [ "${NEVER_SLACK}" -eq 0 ]; then
      WARN_TEXT="athena:inbox: ${HEALTH_TEXT}. Fix: a platform lane nothing has ever been delivered to usually means no server-side producer is registered — add an athena-events routing rule that writes state-change events to its inbox file (see ai/contracts/athena-events.md). Run ai/skills/athena:inbox/bin/inbox-status from this project to see which channel."
    elif [ "${NEVER_PLATFORM}" -gt 0 ]; then
      WARN_TEXT="athena:inbox: ${HEALTH_TEXT}. Fix: a channel nothing has ever been delivered to usually means its producer was never registered — for a slack channel, map this inbox filename to a server-side agent instance in ~/.config/athena-inbox-client/config.json; for a platform lane, add an athena-events routing rule (see ai/contracts/athena-events.md). Run ai/skills/athena:inbox/bin/inbox-status from this project to see which channel is which."
    else
      WARN_TEXT="athena:inbox: ${HEALTH_TEXT}. Fix: a channel nothing has ever been delivered to usually means its producer was never registered — map this inbox filename to a server-side agent instance in ~/.config/athena-inbox-client/config.json. Run ai/skills/athena:inbox/bin/inbox-status from this project to see which channel."
    fi
  fi
  WARN_TEXT_MARKER="${HEALTH_WARN_MARKER}"
fi

# Each warning is rate-limited by the marker for ITS OWN concern, never by the
# poll's and never by the other's.
if [ -n "${WARN_TEXT}" ] && ! marker_is_stale "${WARN_TEXT_MARKER}" "${WARN_INTERVAL_SECONDS}"; then
  WARN_TEXT=""
fi

if [ -n "${WARN_TEXT}" ]; then
  stamp "${WARN_TEXT_MARKER}"
fi

# A run that SUCCEEDED clears the outage marker whatever it found downstream: a
# health fault is not evidence that the poll is broken, and leaving the outage
# marker stamped through a chronic health fault is how the next real outage gets
# rate-limited by a fault that is already over.
# ...and only a poll that actually polled something. A non-opted-in repo clears
# nothing, for the same reason it stamps nothing.
if [ "${POLL_OK}" -eq 1 ] && [ "${OPTED_IN}" -eq 1 ]; then
  unstamp "${WARN_MARKER}"
  # The vanished-entry marker gets the same S21 discipline as the other two.
  # Without it, an entry restored and then clobbered AGAIN inside the window is
  # silenced by a warning about the fault that was already repaired -- and this
  # is the one failure with no diff and no undo, so silencing it is the most
  # expensive place to skip the rule.
  unstamp "${SEEN_WARN_MARKER}"
  # ...and a clean bill of health clears the health marker, so the next health
  # fault gets its own warning rather than inheriting this one's rate limit.
  [ -z "${HEALTH_TEXT}" ] && unstamp "${HEALTH_WARN_MARKER}"
fi

# --- the delivery-chain health line ----------------------------------------
#
# inbox-doctor (DND-190) is the one tool that LOOKS at every link -- the client,
# its config, its cron, the server override -- rather than just counting what
# arrived. When it reports anything worse than `ok`, this hook folds ONE fixed
# sentence into the SAME JSON object (never a bare text line into a JSON channel
# -- walt_ui M7), rate-limited by its OWN marker.
#
# ONLY ON THE OPTED-IN PATH. The doctor's machine-global findings (a stopped
# client, a broken override) are real, but nagging about them in every repo on
# the machine is the noise that makes a real notice invisible -- the same reason
# the count line is gated. A repo that never opted in stays silent.
#
# COUNTS ONLY, NO NAMES. The sentence is fixed; it carries no channel name, no
# message body, no token, and no server hostname. The doctor's own --json is
# read for exactly one boolean (`summary.healthy`) and one severity, both
# integers -- a peer-chosen string never reaches this file. `na` findings are
# NOT "worse than ok": a check that could not run is not a fault to announce.
# Bounded by its OWN copy of the status timeout -- so on the actionable path
# SessionStart can spend up to two of these budgets back to back (the status
# read, then the doctor), still bounded and far under any human-noticed delay.
#
# --no-server IS LOAD-BEARING, not a tidiness flag. Without it, a machine that
# has enabled the server check (ATHENA_INBOX_DOCTOR_API_* set) would fire an
# authenticated curl on EVERY session start -- the exact unprompted network
# coupling this facility must not have -- and a slow server would eat the whole
# timeout budget. With it the SessionStart path is guaranteed local-only (file
# stats, a crontab read, one ruby); the server picture is for the owner running
# the doctor by hand.
#
# A DOCTOR THAT COULD NOT RUN IS LOGGED, NOT SILENT (missing-looks-empty). A
# killed or garbled run leaves DOCTOR_JSON unusable; that is a different fact
# from "healthy", and it goes to the reason log so a silence has a trail --
# never to the pre-prompt notice, which stays counts-only.
DOCTOR_TEXT=""
DOCTOR_HEALTHY=""
if [ "${DOCTOR_LINE_ENABLED}" -eq 1 ] && [ "${POLL_OK}" -eq 1 ] && [ "${OPTED_IN}" -eq 1 ] && [ -x "${DOCTOR_BIN}" ]; then
  DOCTOR_JSON="$(timeout "${STATUS_TIMEOUT_SECONDS}" "${DOCTOR_BIN}" --json --no-server 2>/dev/null)"
  if [ -n "${DOCTOR_JSON}" ] \
     && printf '%s' "${DOCTOR_JSON}" | jq -e 'type == "object" and (.summary | type == "object") and (.summary.healthy | type == "boolean")' >/dev/null 2>&1; then
    if printf '%s' "${DOCTOR_JSON}" | jq -e '.summary.healthy == false' >/dev/null 2>&1; then
      # The reason is fixed and chosen from the WORST state only -- a fail reads
      # differently from a warn, and neither names the link (that is the
      # doctor's job when the reader runs it).
      if printf '%s' "${DOCTOR_JSON}" | jq -e '.summary.fail > 0' >/dev/null 2>&1; then
        DOCTOR_TEXT="athena:inbox: the delivery chain is unhealthy: a link is broken — run inbox-doctor."
      else
        DOCTOR_TEXT="athena:inbox: the delivery chain is unhealthy: a link needs attention — run inbox-doctor."
      fi
    else
      DOCTOR_HEALTHY=1
    fi
  else
    log_reason "inbox-doctor produced no usable --json (timed out or errored), so the delivery-chain health line was skipped this session. Fix: run ai/skills/athena:inbox/bin/inbox-doctor from this project to see why."
  fi
fi

# Rate-limited by ITS OWN marker, never the poll's and never the count's.
if [ -n "${DOCTOR_TEXT}" ] && ! marker_is_stale "${DOCTOR_WARN_MARKER}" "${WARN_INTERVAL_SECONDS}"; then
  DOCTOR_TEXT=""
fi
[ -n "${DOCTOR_TEXT}" ] && stamp "${DOCTOR_WARN_MARKER}"
# S21 discipline: a chain that came back healthy clears its own marker, so the
# next unhealthy period earns a fresh warning rather than inheriting this one's
# rate limit. Cleared only on a genuine healthy verdict, never on a rate-limited
# suppression (DOCTOR_TEXT empty because throttled is not the same as healthy).
[ -n "${DOCTOR_HEALTHY}" ] && unstamp "${DOCTOR_WARN_MARKER}"

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
if [ -n "${DOCTOR_TEXT}" ]; then
  # Same JSON object, its own line -- and its own rate-limit marker, stamped
  # above, so it neither suppresses nor is suppressed by the count's or the
  # poll's markers.
  MESSAGE="${MESSAGE:+${MESSAGE}
}${DOCTOR_TEXT}"
fi

# Zero unread and nothing wrong: NO STDOUT AT ALL. Unprompted output that says
# "nothing new" every session is noise, and noise is what makes a real notice
# invisible.
if [ -z "${MESSAGE}" ]; then
  # Only a run that actually polled something says so. A non-opted-in repo has
  # already logged its own one line, and two lines per session in every repo on
  # the machine is how a 200-line reason log becomes useless.
  [ "${POLL_OK}" -eq 1 ] && [ "${OPTED_IN}" -eq 1 ] && log_reason "polled; nothing to report."
  exit 0
fi

emit "${MESSAGE}"
exit 0
