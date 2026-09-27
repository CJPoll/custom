#!/usr/bin/env bash
# liveness.sh -- is the inbox CLIENT alive, and is each channel fresh? (DND-316)
#
# WHY THIS FILE EXISTS. On 2026-09-22 the inbox client wedged for 96 minutes and
# every check said healthy, because every check asked "does the pid exist?" -- and
# a wedged client and a working one are identical under that question. This file
# asks the two questions that DO tell them apart:
#
#   1. Where is the client in its connect cycle, and for how long? (client log)
#   2. How long since each channel last received a delivery? (the channel's
#      own delivered content -- never the `.event` doorbell, DND-937)
#
# THE WEDGE SIGNATURE. The only verified one (shipwright note, corrections of
# 2026-09-22 20:45Z / 21:57Z / 22:33Z) is a reconnect that never finishes: a
# `reconnecting` / reconnect-STEP line with no `connected` / `joined` after it.
# A CLOSE-WAIT socket is NOT a signature (it appears on healthy clients too) and
# the orphaned socket is NOT an fd leak. Nothing here looks at sockets.
#
# WHY NOT "logged progress within T". A healthy, connected, QUIET client logs
# nothing at all: heartbeats are not logged, and `appended` only fires when mail
# arrives. A predicate of "no log line in T" would therefore kill every idle
# healthy client. The predicate is instead about the LAST LIFECYCLE LINE:
#
#   * a connected-phase line (joined / appended / step joined / ...)   -> progressing,
#     however old: a connected client may legitimately be silent for hours.
#   * a reconnect-phase line (reconnecting in Xs / step <s> / connected to /
#     session ended / the supervisor's start and restart lines)          -> the
#     client is mid-cycle. It is `reconnecting` while the line is younger than
#     its grace (the declared backoff X, if any) plus T, and `wedged` after.
#
# The LV-1 client (gen_saas DND-332) logs each reconnect step on COMPLETION
# (`step dns 2ms`), so a wedge inside a step shows as the PREVIOUS step being the
# last line. The judge names the step the client is stuck IN -- the one after
# the last completed step -- so "wedged" says `tls`, not "a gap".
#
# BUCKETS. `liveness_judge` and `liveness_classify_line` are pure (Domain): facts
# in, verdict out, no I/O, so every branch is provable without a log on disk.
# `liveness_last_event`, `liveness_verdict`, `liveness_last_join_epoch` and
# `liveness_channel_freshness` read files (Side Effects). Both the doctor and the
# supervisor (scripts/athena-inbox-client-run.sh) source this file, so there is
# exactly ONE wedge predicate and one dump-dir derivation on the machine.
#
# Dependencies: coreutils (date, stat, tac), awk, jq (freshness only).

LIVENESS_DEFAULT_WEDGE_AFTER=60
LIVENESS_DEFAULT_LOG_STALE_AFTER=1800

# --- paths (one derivation each) -------------------------------------------

# The supervisor's state dir: its log, pidfiles and stop marker live here.
liveness_state_dir() {
  printf '%s\n' "${ATHENA_INBOX_CLIENT_STATE_DIR:-${HOME}/.local/state}"
}
liveness_client_log() { printf '%s/athena-inbox-client.log\n' "$(liveness_state_dir)"; }
liveness_supervisor_pidfile() { printf '%s/athena-inbox-client.pid\n' "$(liveness_state_dir)"; }

# liveness_dump_dir
# Where the LV-1 client writes its SIGQUIT dumps and LV-2 writes its capture
# directories. It MUST be derived exactly as the client derives it
# (AthenaInboxClient::Client.dump_dir): $XDG_STATE_HOME, or ~/.local/state when
# unset or EMPTY, then athena/inbox-client-dumps. A second derivation that
# disagreed would have the capture wait on a directory the client never writes
# -- a dump that exists, recorded as absent.
#
# A RELATIVE $XDG_STATE_HOME is refused (status 1, nothing printed): the client
# would resolve it against ITS cwd, this shell against its own, and the two
# would silently name different directories. That is a wrongly computed key,
# which must fail where it is produced rather than match nothing later.
liveness_dump_dir() {
  local base="${XDG_STATE_HOME:-}"
  [ -n "${base}" ] || base="${HOME}/.local/state"
  case "${base}" in
    /*) printf '%s/athena/inbox-client-dumps\n' "${base%/}" ;;
    *)  return 1 ;;
  esac
}

# --- pure: time --------------------------------------------------------------

# liveness_epoch_of <YYYY-MM-DDTHH:MM:SSZ>
# The client and the supervisor both stamp UTC, second precision. Anything else
# is refused (status 1) rather than coerced -- an unparseable stamp read as
# epoch 0 would make every line "56 years old" and every client wedged.
liveness_epoch_of() {
  local s="$1" out
  case "${s}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  out="$(date -u -d "${s}" +%s 2>/dev/null)" || return 1
  case "${out}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "${out}"
}

# --- pure: classification ----------------------------------------------------

# liveness_classify_line <log-line>
# Prints "<phase>\t<step>\t<grace-seconds>" for a LIFECYCLE line, nothing and
# status 1 for anything else (a neutral line, a stack trace, junk).
#
#   phase  connected | reconnecting
#   step   for reconnecting: the step the client is stuck IN if this is the
#          last line (sleep, dns, tcp_connect, tls, ws_upgrade, join, joined,
#          reconnect, start); "-" for connected.
#   grace  seconds the line itself says to wait before anything else is
#          expected (the backoff in `reconnecting in 4.6s`, the supervisor's
#          `restart 2 in 10s`), rounded UP; 0 otherwise.
#
# The table mirrors the LV-1 client's own reconnect sequence:
#   reconnecting in Xs -> step sleep_done -> step dns -> step tcp_connect ->
#   step tls -> step ws_upgrade -> connected to -> step join -> step joined ->
#   joined machine:self
# A step that FAILS is followed at once by `session ended` and `reconnecting`,
# so a failed step as the last line means the client is stuck getting to the
# next reconnect.
liveness_classify_line() {
  printf '%s\n' "$1" | awk '
    {
      # TS SEV msg -- only stamped lines are lifecycle candidates.
      if ($1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) exit 1
      sev = $2
      msg = $0; sub(/^[^ ]+ [^ ]+ /, "", msg)
      if (sev == "SUPERVISOR") {
        if (msg ~ /^supervising /) { print "reconnecting\tstart\t0"; exit 0 }
        if (msg ~ /^client exited .* restart [0-9]+ in [0-9]+s$/) {
          g = msg; sub(/^.* in /, "", g); sub(/s$/, "", g)
          print "reconnecting\tstart\t" g; exit 0
        }
        exit 1
      }
      if (msg ~ /^joined / || msg ~ /^appended / || msg ~ /^step joined / \
          || msg ~ /^refused event/ || msg ~ /^ack rejected/ || msg ~ /^ignoring unknown event/) {
        print "connected\t-\t0"; exit 0
      }
      if (msg ~ /^reconnecting in [0-9.]+s/) {
        g = msg; sub(/^reconnecting in /, "", g); sub(/s.*$/, "", g); g = g + 0
        gi = int(g); if (gi < g) gi++
        print "reconnecting\tsleep\t" gi; exit 0
      }
      if (msg ~ /^session ended/)        { print "reconnecting\treconnect\t0"; exit 0 }
      if (msg ~ /^connected to /)         { print "reconnecting\tjoin\t0"; exit 0 }
      if (msg ~ /^step [a-z_]+ failed /)  { print "reconnecting\treconnect\t0"; exit 0 }
      if (msg ~ /^step [a-z_]+ [0-9]+ms/) {
        s = msg; sub(/^step /, "", s); sub(/ .*$/, "", s)
        n = (s == "sleep_done") ? "dns" : (s == "dns") ? "tcp_connect" : (s == "tcp_connect") ? "tls" \
          : (s == "tls") ? "ws_upgrade" : (s == "ws_upgrade") ? "join" : (s == "join") ? "joined" : "after_" s
        print "reconnecting\t" n "\t0"; exit 0
      }
      exit 1
    }'
}

# liveness_judge <last-lifecycle-line> <now-epoch> [wedge-after-seconds]
# Pure. Prints "<state>\t<step>\t<age>\t<detail>":
#
#   progressing   the last lifecycle line is connected-phase (age is its age)
#   reconnecting  mid-cycle, still inside grace + T
#   wedged        mid-cycle past grace + T: the 2026-09-22 15:55Z shape
#   unknown       no lifecycle line, or one whose stamp will not parse
#
# `unknown` is deliberately NOT `progressing`: a log that says nothing about the
# connect cycle is a failed lookup, and must not read as a healthy client.
liveness_judge() {
  local line="$1" now="$2" t="${3:-${LIVENESS_DEFAULT_WEDGE_AFTER}}" cls phase step grace ts epoch age
  case "${now}" in ''|*[!0-9]*) printf 'unknown\t-\t-\tno usable clock reading\n'; return 0 ;; esac
  case "${t}" in ''|*[!0-9]*) t="${LIVENESS_DEFAULT_WEDGE_AFTER}" ;; esac
  if [ -z "${line}" ] || ! cls="$(liveness_classify_line "${line}")"; then
    printf 'unknown\t-\t-\tno connect-cycle line in the client log\n'
    return 0
  fi
  IFS=$'\t' read -r phase step grace <<<"${cls}"
  ts="${line%% *}"
  if ! epoch="$(liveness_epoch_of "${ts}")"; then
    printf 'unknown\t-\t-\tthe last connect-cycle line has an unparseable timestamp\n'
    return 0
  fi
  age=$(( now - epoch )); [ "${age}" -ge 0 ] || age=0
  if [ "${phase}" = "connected" ]; then
    printf 'progressing\t-\t%s\tconnected; last connect-cycle event %ss ago\n' "${age}" "${age}"
  elif [ "${age}" -gt $(( grace + t )) ]; then
    printf 'wedged\t%s\t%s\tstuck in step %s for %ss (allowed %ss)\n' "${step}" "${age}" "${step}" "${age}" "$(( grace + t ))"
  else
    printf 'reconnecting\t%s\t%s\tin step %s for %ss (allowed %ss)\n' "${step}" "${age}" "${step}" "${age}" "$(( grace + t ))"
  fi
}

# --- side effects: reading the log ------------------------------------------

# _liveness_last_lifecycle_in <file>
# The newest lifecycle line in ONE file, or nothing. Scans backwards and stops
# at the first hit, so an 8 MiB log costs one tac, not one parse per line.
_liveness_last_lifecycle_in() {
  local f="$1" line
  [ -r "${f}" ] || return 0
  while IFS= read -r line; do
    if liveness_classify_line "${line}" >/dev/null; then
      printf '%s\n' "${line}"
      return 0
    fi
  done < <(tac -- "${f}" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z (INFO|WARN|ERROR|SUPERVISOR) (joined |appended |step |refused event|ack rejected|ignoring unknown event|reconnecting in |session ended|connected to |supervising |client exited )')
  return 0
}

# liveness_last_event [log]
# The newest lifecycle line across the live log and, when the live log has none
# (the client's own rotation just started a fresh file), its `.1` generation.
# Status 1 when NEITHER file exists -- "no log" is a different fact from "a log
# with no connect-cycle line", and the caller must be able to say which.
liveness_last_event() {
  local log="${1:-$(liveness_client_log)}" line
  [ -e "${log}" ] || [ -e "${log}.1" ] || return 1
  line="$(_liveness_last_lifecycle_in "${log}")"
  [ -n "${line}" ] || line="$(_liveness_last_lifecycle_in "${log}.1")"
  printf '%s\n' "${line}"
}

# liveness_verdict [log] [now] [wedge-after]
# The judge applied to the log on disk. A missing log is its own state,
# `absent`, never `unknown` and never `progressing`.
liveness_verdict() {
  local log="${1:-$(liveness_client_log)}" now="${2:-$(date -u +%s)}" t="${3:-${ATHENA_INBOX_CLIENT_WEDGE_AFTER:-${LIVENESS_DEFAULT_WEDGE_AFTER}}}" line
  if ! line="$(liveness_last_event "${log}")"; then
    printf 'absent\t-\t-\tno client log at %s\n' "${log}"
    return 0
  fi
  liveness_judge "${line}" "${now}" "${t}"
}

# liveness_last_join_epoch [log]
# Epoch of the newest `joined` line (live log, then `.1`); empty when none.
liveness_last_join_epoch() {
  local log="${1:-$(liveness_client_log)}" f ts
  for f in "${log}" "${log}.1"; do
    [ -r "${f}" ] || continue
    ts="$(tac -- "${f}" 2>/dev/null | grep -m1 -E '^[0-9TZ:-]{20} INFO joined ' | cut -d' ' -f1)"
    if [ -n "${ts}" ]; then liveness_epoch_of "${ts}"; return 0; fi
  done
  return 0
}

# --- side effects: per-channel freshness (R2) --------------------------------

# liveness_stale_after <entry-json> <chan> <kind>
# The channel's staleness threshold in seconds, or "null" for none. Per-channel
# `stale_after_s` in the registry entry wins; 0 or null there DISABLES it.
# Defaults: 1800 for a `log` channel, none for a `maildir` (a conversation may
# be quiet for days).
liveness_stale_after() {
  local entry="$1" chan="$2" kind="$3" v
  # A jq failure is an ERROR (status 1), never an empty value: empty would fall
  # to "null" below and silently DISABLE staleness for the channel.
  v="$(printf '%s' "${entry}" | jq -r --arg c "${chan}" \
        '.channels[$c] | if has("stale_after_s") then (.stale_after_s | tostring) else "default" end' 2>/dev/null)" || return 1
  [ -n "${v}" ] || return 1
  case "${v}" in
    default) [ "${kind}" = "log" ] && printf '%s\n' "${LIVENESS_DEFAULT_LOG_STALE_AFTER}" || printf 'null\n' ;;
    null|0|'') printf 'null\n' ;;
    *) printf '%s\n' "${v}" ;;
  esac
}

# liveness_channel_freshness <entry-json> <chan> <resolved-paths> [now]
# One JSON object for one channel:
#   last_delivery_age_s  seconds since the last delivery, or null (nothing was
#                        ever delivered that is still on disk)
#   age_basis            "inbox" | "rotation" | "message" | "none" -- what said so
#   age_is_lower_bound   true when the age is a floor, not a measurement
#                        (basis "rotation"; see below)
#   stale_after_s        the threshold, or null (none)
#   stale                true only when both are known and age > threshold
#   last_join_age_s      seconds since the CLIENT last joined (machine-wide;
#                        log channels only, null when there is no client log)
# Status 1 (nothing printed) when a channel's content EXISTS but its age cannot
# be read -- "could not look" is never "found nothing".
#
# AGE SOURCE: THE CHANNEL'S OWN DELIVERED CONTENT, NEVER THE DOORBELL (DND-937).
# This used the `.event` doorbell mtime (DND-315/316). A doorbell is provisioned
# by inbox-wait before anything is delivered, and re-created if it goes missing,
# so its mtime can be a creation, not a delivery. Measured 2026-09-26: the doctor
# graded `ok freshness:slack ... last delivery 257090s ago (doorbell mtime)` while
# custom-slack.jsonl did not exist. A never-delivered channel read as delivered,
# and a re-provisioned doorbell could hide a stale one. So:
#
#   log      the live inbox file, when NON-EMPTY: its mtime is its last append,
#            since only the writer changes it (readers keep offsets in the state
#            file). An empty or absent live file with a NON-EMPTY `.1` means
#            nothing arrived since the rotation, so the last delivery predates
#            `rotated_at`: the age is `now - rotated_at`, a LOWER BOUND (STALE
#            past the threshold is certain; under it, it may fire up to one
#            threshold late). `.1`'s mtime is not used: rotation restamps it.
#            Neither holds -> no delivery (null).
#   maildir  the newest message file (`*.md`) in the read directory or its
#            `.acked/`: a message's mtime is its write, and neither link(2)
#            nor the ack's rename(2) changes it. None -> no delivery (null).
#
# All clocks are this machine's (file mtimes, and `rotated_at`, which this
# machine's reader stamps), never a server `received_at` (contract -> "Delivery
# timestamps"). The server's last `acked_at` is the cross-check, reported by
# inbox-doctor's server check.
#
# STALENESS IS THIS MACHINE'S OWN FACT (file mtimes, a threshold it configured),
# never message content, so reporting it keeps the counts-only rule.
liveness_channel_freshness() {
  local entry="$1" chan="$2" resolved="$3" now="${4:-$(date -u +%s)}"
  local kind newest="" basis="none" lower="false" age="null" thr join join_age="null" stale="false"
  kind="$(printf '%s\n' "${resolved}" | awk -F'\t' '$1=="kind"{print $2; exit}')"
  case "${kind}" in
    log)     newest="$(_liveness_log_last_delivery "${resolved}")" || return 1 ;;
    maildir) newest="$(_liveness_maildir_last_delivery "${resolved}")" || return 1 ;;
    *) printf '{"last_delivery_age_s":null,"age_basis":"none","age_is_lower_bound":false,"stale_after_s":null,"stale":false,"last_join_age_s":null}\n'; return 0 ;;
  esac
  if [ -n "${newest}" ]; then
    IFS=$'\t' read -r basis newest <<<"${newest}"
    [ "${basis}" = "rotation" ] && lower="true"
    age=$(( now - newest )); [ "${age}" -ge 0 ] || age=0
  fi
  thr="$(liveness_stale_after "${entry}" "${chan}" "${kind}")" || return 1
  if [ "${thr}" != "null" ] && [ "${age}" != "null" ] && [ "${age}" -gt "${thr}" ]; then stale="true"; fi
  if [ "${kind}" = "log" ]; then
    join="$(liveness_last_join_epoch)"
    if [ -n "${join}" ]; then join_age=$(( now - join )); [ "${join_age}" -ge 0 ] || join_age=0; fi
  fi
  jq -n -c --argjson age "${age}" --arg basis "${basis}" --argjson lower "${lower}" --argjson thr "${thr}" \
    --argjson stale "${stale}" --argjson join "${join_age}" \
    '{last_delivery_age_s: $age, age_basis: $basis, age_is_lower_bound: $lower, stale_after_s: $thr, stale: $stale, last_join_age_s: $join}'
}

# _liveness_mtime <path>  -- the mtime epoch, or status 1. An existing file whose
# mtime cannot be read is a failed measurement, never "no delivery".
_liveness_mtime() {
  local mt
  mt="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1
  case "${mt}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "${mt}"
}

# _liveness_searchable_dir <dir>  -- status 1 unless <dir> is a directory this
# process can search. Past a directory it cannot search, every file reads as
# absent, and "absent" here means "never delivered": that is could-not-look
# dressed as found-nothing.
_liveness_searchable_dir() { [ -d "$1" ] && [ -x "$1" ]; }

# _liveness_log_last_delivery <resolved>
# "<basis>\t<epoch>" for a log channel's last delivery, nothing when none, and
# status 1 when content exists but cannot be aged.
_liveness_log_last_delivery() {
  local resolved="$1" inbox state one rot epoch
  inbox="$(printf '%s\n' "${resolved}" | awk -F'\t' '$1=="inbox"{print $2; exit}')"
  state="$(printf '%s\n' "${resolved}" | awk -F'\t' '$1=="state"{print $2; exit}')"
  [ -n "${inbox}" ] || return 1
  _liveness_searchable_dir "$(dirname -- "${inbox}")" || return 1
  one="${inbox}.1"
  if [ -s "${inbox}" ]; then
    epoch="$(_liveness_mtime "${inbox}")" || return 1
    printf 'inbox\t%s\n' "${epoch}"
    return 0
  fi
  [ -s "${one}" ] || return 0
  # Rotated and nothing since. The state file is the only record of when; a
  # missing or unparseable `rotated_at` leaves content we cannot age.
  [ -n "${state}" ] && [ -r "${state}" ] || return 1
  rot="$(jq -r '.rotated_at // empty' <"${state}" 2>/dev/null)" || return 1
  epoch="$(liveness_epoch_of "${rot}")" || return 1
  printf 'rotation\t%s\n' "${epoch}"
}

# _liveness_maildir_last_delivery <resolved>
# "message\t<epoch>" for the newest message file in the read directory or its
# `.acked/`, nothing when none (or no read directory yet: the peer creates it
# on first send), status 1 when a directory that exists cannot be listed.
_liveness_maildir_last_delivery() {
  local resolved="$1" dir d newest="" mt out
  for d in read_dir ack_dir; do
    dir="$(printf '%s\n' "${resolved}" | awk -F'\t' -v k="${d}" '$1==k{print $2; exit}')"
    [ -n "${dir}" ] || { [ "${d}" = "read_dir" ] && return 1; continue; }
    [ -e "${dir}" ] || continue
    [ -r "${dir}" ] && _liveness_searchable_dir "${dir}" || return 1
    out="$(find "${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.md' -printf '%T@\n' 2>/dev/null)" || return 1
    mt="$(printf '%s\n' "${out}" | awk -F. 'NF && $1 ~ /^[0-9]+$/ && $1 > m {m = $1} END {if (m != "") print m}')"
    if [ -n "${mt}" ] && { [ -z "${newest}" ] || [ "${mt}" -gt "${newest}" ]; }; then newest="${mt}"; fi
  done
  [ -z "${newest}" ] || printf 'message\t%s\n' "${newest}"
}

# liveness_human_age <seconds>  ->  "94m", "3h12m", "45s" (for one-line reports)
liveness_human_age() {
  local s="$1"
  case "${s}" in ''|null|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  if [ "${s}" -lt 120 ]; then printf '%ss\n' "${s}"
  elif [ "${s}" -lt 7200 ]; then printf '%sm\n' "$(( s / 60 ))"
  else printf '%sh%sm\n' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  fi
}
