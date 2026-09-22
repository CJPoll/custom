#!/usr/bin/env bash
# athena-attend-lib.sh -- shared helpers for the standing channel-session
# launcher/supervisor (scripts/athena-channel-session.sh) and the inbox-doctor
# `channel:` line. Sourced, never executed.
#
# PROVENANCE (DND-283 input correction). Extracted from the CLOSED PR #47's
# scripts/athena-attend-run.sh: the flock single-instance discipline, the
# durable stop/dark/wedged marker scheme, count-failed-is-NEVER-zero, and
# new>0-is-the-trigger. DROPPED from #47, because the standing channel session
# (design §4) replaces it: the `claude -p` handler, the wake BRIEF, epochs
# (--session-id/--resume), and --max-budget-usd.
#
# DESIGN. Pure where it can be. The rotation / version / count / state
# DECISIONS are functions of their arguments, so the self-test drives them
# directly and the launcher's imperative shell (tmux / claude / dm) stays a thin
# skin around them. Every count-bearing decision keys on the NORMALIZED
# per-channel `count` field inbox-status now emits (DND-283 ruling 2): a null or
# absent count is UNCOUNTABLE, never a zero -- reading a broken channel as
# "idle" is the failed-lookup-looks-empty class this whole facility exists to
# close.
#
# Requires: jq (count parsing). Source order: this file stands alone.

# ---------------------------------------------------------------------------
# names / paths (one computation, shared by launcher AND doctor, so the tmux
# session name and the marker dir are byte-identical on both sides -- a mismatch
# here is exactly the silent-dark class)
# ---------------------------------------------------------------------------

# attend_session_name <project-name> -> the tmux session name.
attend_session_name() { printf 'athena-attend-%s\n' "${1:?project name}"; }

# attend_state_dir <project-name> -> the per-project state/marker directory.
# ATHENA_ATTEND_STATE_DIR overrides it verbatim (a test seam), matching #47.
attend_state_dir() {
  if [ -n "${ATHENA_ATTEND_STATE_DIR:-}" ]; then
    printf '%s\n' "${ATHENA_ATTEND_STATE_DIR}"
  else
    printf '%s/athena-attend/%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}" "${1:?project name}"
  fi
}

# attend_marker <state-dir> <dark|wedged|stopped> -> the marker file path.
attend_marker() { printf '%s/channel.%s\n' "${1:?state dir}" "${2:?marker}"; }

# ---------------------------------------------------------------------------
# durable markers (the supervisor writes them; inbox-doctor reads them)
# ---------------------------------------------------------------------------

# attend_write_marker <state-dir> <dark|wedged|stopped> <message>
# First line is a human/LLM-facing sentence (carries a Fix: for wedged, per the
# repo's guard-message convention). A ".notified" sibling is cleared so a fresh
# marker re-notifies exactly once.
attend_write_marker() {
  local dir="${1:?}" kind="${2:?}" msg="${3:-}" f
  mkdir -p -- "${dir}" 2>/dev/null || true
  f="$(attend_marker "${dir}" "${kind}")"
  {
    printf 'channel %s at %s\n' "${kind}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "${msg}"
  } >"${f}" 2>/dev/null || true
  rm -f -- "${f}.notified" 2>/dev/null || true
}

# attend_clear_markers <state-dir>
# Clears the dark marker (a successful (re)launch means the channel is live
# again). The stopped/wedged markers are NOT cleared here: they are deliberate
# terminal states a human resolves, exactly as #47's stop/wedge markers were.
attend_clear_markers() {
  local dir="${1:?}"
  rm -f -- "$(attend_marker "${dir}" dark)" "$(attend_marker "${dir}" dark).notified" 2>/dev/null || true
}

# attend_channel_state <state-dir> <has-session:0|1> -> one of
#   wedged | dark | stopped | registered | no-session
#
# NOTE: T3 writes `dark` and `wedged` (launch/dialog + runtime dark detection);
# `stopped` is READ here but has no T3 writer yet -- it is reserved for the
# shim's waiter-death signal (server.mjs marks that condition with a stderr
# diagnostic today; the durable marker is a follow-up). The launcher's own
# count-based dark detection covers the practical harm meanwhile, so a genuinely
# deaf-but-alive session still surfaces (as `dark`) rather than silently reading
# `registered`.
# The inbox-doctor `channel:` line (design §3.4). Precedence puts the faults a
# human must act on first (wedged, then dark), then the deliberate stop, then
# the live/absent split. "no-session" and "dark" are DISTINCT strings from
# "registered" by construction, so a dead or dark channel can never read as a
# healthy one (the ticket's must-never-read-the-same requirement).
attend_channel_state() {
  local dir="${1:?}" has_session="${2:-0}"
  [ -e "$(attend_marker "${dir}" wedged)" ] && { printf 'wedged\n'; return 0; }
  [ -e "$(attend_marker "${dir}" dark)" ]   && { printf 'dark\n';   return 0; }
  [ -e "$(attend_marker "${dir}" stopped)" ] && { printf 'stopped\n'; return 0; }
  [ "${has_session}" = "1" ] && { printf 'registered\n'; return 0; }
  printf 'no-session\n'
}

# ---------------------------------------------------------------------------
# counts (key on the normalized `count`; null/absent = uncountable, never 0)
# ---------------------------------------------------------------------------

# attend_counts_state <inbox-status-json>
# Classifies the whole document for the rotation gate and the wake counter.
# Prints ONE token on stdout and returns:
#   "zero"        rc 0  -- every channel counted, all counts == 0 (idle)
#   "unread"      rc 0  -- every channel counted, some count > 0
#   "uncountable" rc 1  -- the doc did not parse, had no channels array, or ANY
#                          channel's count is null/absent. On stdout after the
#                          token: the space-joined names of the uncountable
#                          channels (or "(unparseable)"). NEVER folded into
#                          "zero" -- an uncountable channel blocks rotation and
#                          is logged by name, never called idle (ruling 2c).
attend_counts_state() {
  local doc="${1:-}" parsed
  parsed="$(printf '%s' "${doc}" | jq -e '.channels | type == "array"' 2>/dev/null)" || {
    printf 'uncountable (unparseable)\n'; return 1;
  }
  [ "${parsed}" = "true" ] || { printf 'uncountable (unparseable)\n'; return 1; }
  local bad
  bad="$(printf '%s' "${doc}" | jq -r '
    [ .channels[] | select((.count == null) or (has("count") | not)) | (.name // "(unnamed)") ]
    | join(" ")' 2>/dev/null)"
  if [ -n "${bad}" ]; then
    printf 'uncountable %s\n' "${bad}"; return 1
  fi
  local sum
  sum="$(printf '%s' "${doc}" | jq -e '[.channels[].count] | add // 0' 2>/dev/null)" || {
    printf 'uncountable (unparseable)\n'; return 1;
  }
  case "${sum}" in ''|*[!0-9-]*) printf 'uncountable (unparseable)\n'; return 1 ;; esac
  if [ "${sum}" -gt 0 ]; then printf 'unread\n'; else printf 'zero\n'; fi
  return 0
}

# attend_wake_completed <prev-token> <cur-token>
# A "wake" for the pre-T4 wake counter is a transition from unread to zero: mail
# arrived and the session drained it. rc 0 = a wake just completed. Uncountable
# on either side is NOT a wake (we cannot claim the mail drained).
attend_wake_completed() {
  [ "${1:-}" = "unread" ] && [ "${2:-}" = "zero" ]
}

# ---------------------------------------------------------------------------
# rotation bounds
# ---------------------------------------------------------------------------

# attend_transcript_bytes <slug-dir>
# The newest *.jsonl transcript's byte size in <slug-dir>, or "n/a" when it
# cannot be measured (dir absent, no transcript, unreadable). NEVER 0 for
# "unmeasurable": a real 0-byte transcript and a missing one must not read the
# same, and rotation must not fire on an unmeasurable size (design §4.2).
attend_transcript_bytes() {
  local dir="${1:-}" newest n
  [ -n "${dir}" ] && [ -d "${dir}" ] || { printf 'n/a\n'; return 0; }
  newest="$(ls -1t "${dir}"/*.jsonl 2>/dev/null | head -n 1)"
  [ -n "${newest}" ] && [ -f "${newest}" ] || { printf 'n/a\n'; return 0; }
  n="$(wc -c <"${newest}" 2>/dev/null | tr -d ' ')"
  case "${n}" in ''|*[!0-9]*) printf 'n/a\n' ;; *) printf '%s\n' "${n}" ;; esac
}

# attend_rotation_reason <wakes> <max-wakes> <bytes|n/a> <max-bytes> <age-s> <max-age-s>
# Prints the FIRST tripped bound (max-wakes | max-bytes | max-age) or "" when
# none tripped. An "n/a" (unmeasurable) transcript size NEVER trips -- the other
# two bounds still apply (design §4.2).
attend_rotation_reason() {
  local wakes="${1:-0}" maxw="${2:-30}" bytes="${3:-n/a}" maxb="${4:-262144}" age="${5:-0}" maxa="${6:-86400}"
  case "${wakes}" in ''|*[!0-9]*) wakes=0 ;; esac
  case "${age}" in ''|*[!0-9]*) age=0 ;; esac
  if [ "${wakes}" -ge "${maxw}" ]; then printf 'max-wakes\n'; return 0; fi
  case "${bytes}" in
    ''|n/a|*[!0-9]*) : ;;  # unmeasurable -> do NOT rotate on size
    *) [ "${bytes}" -ge "${maxb}" ] && { printf 'max-bytes\n'; return 0; } ;;
  esac
  if [ "${age}" -ge "${maxa}" ]; then printf 'max-age\n'; return 0; fi
  printf '\n'
}

# attend_rotation_gate_open <counts-token> <idle:0|1> <permission-open:0|1>
# Whether a rotation whose bound has already tripped may PROCEED now, without
# cutting a reply in half (design §4.2). rc 0 = open. ALL of:
#   * counts-token == "zero" -- every channel counted and all counts are 0.
#     "unread" (mail waiting) and "uncountable" (a null count -- ruling 2c) both
#     BLOCK: an uncountable channel is never treated as idle.
#   * idle == 1 -- no turn in flight (the Stop-hook idle signal / ack_wake).
#   * permission-open == 0 -- the T5 seam: a rotation must also not fire while a
#     permission request is open. Pre-T5 the caller always passes 0; the gate is
#     shaped so T5 can wire the real signal in with no change here.
attend_rotation_gate_open() {
  [ "${1:-}" = "zero" ] && [ "${2:-0}" = "1" ] && [ "${3:-0}" = "0" ]
}

# ---------------------------------------------------------------------------
# restart-rate cap (dark -> restart, bounded 3/hour; design §3.4)
# ---------------------------------------------------------------------------

# attend_restart_allowed <restarts-log> <cap> <window-s> <now-epoch>
# The log holds one epoch-second per past restart. Prunes entries older than the
# window, counts what remains; if it is below the cap, APPENDS <now> and returns
# 0 (this restart is allowed). At/over the cap, returns 1 and appends nothing --
# the caller wedges. Keeps a restart storm from masquerading as recovery.
attend_restart_allowed() {
  local log="${1:?}" cap="${2:-3}" window="${3:-3600}" now="${4:?}" kept cutoff
  cutoff=$(( now - window ))
  kept=""
  if [ -f "${log}" ]; then
    while IFS= read -r ts; do
      case "${ts}" in ''|*[!0-9]*) continue ;; esac
      [ "${ts}" -ge "${cutoff}" ] && kept="${kept}${ts}"$'\n'
    done <"${log}"
  fi
  printf '%s' "${kept}" >"${log}" 2>/dev/null || true
  local count
  # grep -c already prints 0 on no match (and exits 1); `|| true` swallows only
  # the exit, never appends a second "0" (which would make count "0\n0").
  count="$(printf '%s' "${kept}" | grep -c '[0-9]' 2>/dev/null || true)"
  case "${count}" in ''|*[!0-9]*) count=0 ;; esac
  if [ "${count}" -lt "${cap}" ]; then
    printf '%s\n' "${now}" >>"${log}" 2>/dev/null || true
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# version pin (HARD FAIL; design §4.3, DND-283 ruling amendment 2)
# ---------------------------------------------------------------------------

# attend_version_ok <actual> <pinned> -> rc 0 when they match exactly.
# A blind keypress into an unknown dialog is the hazard, so a mismatch is a hard
# no-launch, never "log and attempt".
attend_version_ok() {
  [ -n "${1:-}" ] && [ "${1}" = "${2:-}" ]
}

# attend_extract_version <claude --version output>
# The dotted version token from `claude --version` ("Claude Code v2.1.278" or
# "2.1.278 (...)"), or "" when none is present.
attend_extract_version() {
  printf '%s' "${1:-}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}
