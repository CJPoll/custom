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
