#!/usr/bin/env bash
# wait-fixture.sh -- what the three resume-waiter parts share (DND-1361 split
# of DND-1007's wait part): session B, its answers and cache path, and fw().
# Sourced after common.sh and fixture.sh, never run.

SID_B="5f488432-6c65-495e-a216-000000000484"
DRAIN_B="$(answer drain override:force_drain null "${OV_DRAIN}" "${SID_B}")"
RUN_B="$(answer run default null "${P1_SNAP}" "${SID_B}")"
CACHE_B="${XDG_STATE_HOME}/athena/fleet/${SID_B}.json"

# fw <args...> -- run fleet-control wait for session B; sets OUT, ERR, RC, HITS.
fw() {
  local before
  before="$(fleet_log_count)"
  OUT="$(timeout 60 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" "$@" 2>"${TMP}/werr")"; RC=$?
  ERR="$(cat "${TMP}/werr")"
  HITS=$(( $(fleet_log_count) - before ))
}

# fw_budget_line_seen <file> -- 0 if <file> holds the waiter's own budget line
# (bin/fleet-control prints it first, as "fleet-control: wait: budget ...").
# The bare word "budget" also matched a --budget refusal (DND-1719).
fw_budget_line_seen() { grep -q '^fleet-control: wait: budget [0-9]' "$1" 2>/dev/null; }

# fw_until_budget_line <file> <args...> -- start the waiter for session B with
# its stderr in <file>, kill it once it has printed its budget line, and wait
# for it. <file> is emptied HERE, before the waiter starts: the waiter's own 2>
# runs in the child, so until then the poll could read an earlier case's
# output (DND-1719). The 60 s timeout and the poll bound are hang caps only
# (DND-1007); a waiter that exits ends the poll at once.
fw_until_budget_line() {
  local f="$1" p i; shift
  : > "${f}"
  timeout 60 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" "$@" >/dev/null 2>"${f}" & p=$!
  for i in $(seq 1 1200); do
    fw_budget_line_seen "${f}" && break
    kill -0 "${p}" 2>/dev/null || break
    sleep 0.05
  done
  kill "${p}" 2>/dev/null; wait "${p}" 2>/dev/null
}
