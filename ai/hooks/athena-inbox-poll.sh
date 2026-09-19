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
#   athena-inbox-last-poll     when did we last ATTEMPT
#   athena-inbox-last-success  when did we last SUCCEED (is the silence healthy?)
#   athena-inbox-last-warn     when did we last say THE POLL IS BROKEN
#   athena-inbox-last-health-warn  when did we last say THE POLL FOUND A FAULT
#   athena-inbox-poll.log      last 200 lines, fixed reason strings only
#   athena-inbox-seen/<hash>   this project HAD channels once (per-project)
#   athena-inbox-seen/<hash>.warn  when we last said they had vanished
#
# Merging any two of these breaks one of the answers, and they are namespaced
# separately from the athena-slack-* family: a shared marker once let a fresh
# CHECK silently suppress a POLL (walt_ui sabotage S14).
#
# THE TWO WARNINGS HAVE SEPARATE MARKERS for that same reason. "The poll is not
# working" and "the poll works and found a fault downstream" have different
# owners and very different lifetimes: a benign health fault is a state the
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

LOG_MAX_LINES=200
# Six hours: D6's window. Overridable for the self-test, which cannot wait.
STALE_SECONDS="${ATHENA_INBOX_STALE_SECONDS:-21600}"
WARN_INTERVAL_SECONDS="${ATHENA_INBOX_WARN_INTERVAL_SECONDS:-21600}"
# The ceiling on the wrapped command. Generous for a file scan, and far below
# any delay a person would tolerate at session start.
STATUS_TIMEOUT_SECONDS="${ATHENA_INBOX_STATUS_TIMEOUT_SECONDS:-10}"

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
HEALTH_WARN_MARKER="${MARKER_DIR}/athena-inbox-last-health-warn"
LOG_FILE="${MARKER_DIR}/athena-inbox-poll.log"

# PER-PROJECT state, and the only state here that is not per-$HOME.
#
# "This project never opted in" and "this project's registry entry was deleted
# or clobbered" are BYTE-IDENTICAL on disk -- inbox-status answers
# {"channels":[],"failed_candidates":0} and exits 0 for both, correctly, since
# it cannot know a project's history. The second is the silent-dark failure
# CLAUDE.md names for this registry: an untracked file outside git, so its loss
# has no diff and no undo. Somebody has to remember that this project once had
# channels, and the session standing in the project is the only one who can.
#
# The identity is the contract's own key -- the realpath of the git common dir,
# identical for a repo's main checkout and all its worktrees. It is READ OUT OF
# `inbox-status --json` (`repo_key`), not computed here: that command already
# resolves it, and a hook that recomputed it would be a second implementation of
# the identity rule, free to drift from the contract. This file calls the
# skill's public surface and nothing below it. The key is hashed for the marker
# filename, because a filename must not be a filesystem path.
SEEN_DIR="${MARKER_DIR}/athena-inbox-seen"
SEEN_MARKER=""
SEEN_WARN_MARKER=""

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

# The per-project marker paths, now that the status document can name this
# repo. Every way of failing to derive them is LOGGED rather than silently
# disabling the detector: an inert R16 looks exactly like a healthy project, and
# a lookup that finds nothing must still leave something a later reader can see.
if [ "${POLL_OK}" -eq 1 ]; then
  # ABSENT and EMPTY are different answers and must not collapse. An empty
  # `repo_key` means "this cwd is in no git repository", which legitimately has
  # no identity to remember and is the ordinary case for most directories on
  # this machine -- quiet. NO `repo_key` at all means the inbox-status beside
  # this hook predates the field (hook/skill version skew: settings.json wires
  # one tree's hook, which resolves STATUS_BIN from whatever tree that is), and
  # that silently makes the vanished-entry detector inert while looking exactly
  # like a healthy project. `// ""` would have made those two indistinguishable.
  if ! printf '%s' "${STATUS_JSON}" | jq -e 'has("repo_key")' >/dev/null 2>&1; then
    log_reason "the status document carries no repo_key, so this project's inbox-seen marker could not be named and a vanished registry entry would go unnoticed here. Fix: the inbox-status beside this hook predates the field — check that ai/skills/athena:inbox and ai/hooks come from the same checkout."
    PROJECT_KEY=""
  else
    PROJECT_KEY="$(printf '%s' "${STATUS_JSON}" | jq -r '.repo_key' 2>/dev/null)" || PROJECT_KEY=""
  fi
  if [ -z "${PROJECT_KEY}" ]; then
    :
  elif ! command -v sha256sum >/dev/null 2>&1; then
    log_reason "sha256sum is not on PATH, so this project's inbox-seen marker could not be named and a vanished registry entry would go unnoticed here. Fix: install coreutils' sha256sum and start a new session."
  else
    PROJECT_HASH="$(printf '%s' "${PROJECT_KEY}" | sha256sum 2>/dev/null | cut -c1-32)"
    case "${PROJECT_HASH}" in
      ''|*[!0-9a-f]*)
        log_reason "this project's identity could not be hashed, so its inbox-seen marker could not be named and a vanished registry entry would go unnoticed here. Fix: check that sha256sum and cut behave normally on this machine."
        ;;
      *)
        SEEN_MARKER="${SEEN_DIR}/${PROJECT_HASH}"
        # Rate-limited by a marker of its OWN, beside the fact it is about. A
        # per-project fault must not be silenced by another project's warning,
        # which is what a shared $HOME-level marker would do.
        SEEN_WARN_MARKER="${SEEN_DIR}/${PROJECT_HASH}.warn"
        ;;
    esac
  fi
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
  WARN_TEXT="athena:inbox: this project had inbox channels on an earlier session and has none now, so its mail is going unread. Fix: its registry entry under \${ATHENA_INBOX_ROOT:-~/.local/share/athena}/projects/ is missing or no longer names this repo — restore it, or, if the project was retired deliberately, delete ${SEEN_MARKER} to stop this notice."
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
    WARN_TEXT="athena:inbox: ${HEALTH_TEXT}. Fix: run ai/skills/athena:inbox/bin/inbox-status from this project to see which."
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
  # Only a run that actually polled something says so. A non-opted-in repo has
  # already logged its own one line, and two lines per session in every repo on
  # the machine is how a 200-line reason log becomes useless.
  [ "${POLL_OK}" -eq 1 ] && [ "${OPTED_IN}" -eq 1 ] && log_reason "polled; nothing to report."
  exit 0
fi

emit "${MESSAGE}"
exit 0
