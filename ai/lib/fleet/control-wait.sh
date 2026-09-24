#!/usr/bin/env bash
# control-wait.sh -- MANAGER of the resume waiter (DND-484): `fleet-control
# wait`. A drained top-level session arms it in the background; its exit is the
# session's wake. It polls the session's OWN control read (the same server-first
# path as `check`, control-manager.sh) and decides each poll with the pure
# fleet_wait_outcome (control-domain.sh). It reads no inbox file, lock or
# offset, so it fires whether or not this session is its project's designated
# inbox consumer (athena-events.md -> *Layer 4: resume*).
#
# Exit: 0 run on basis server (stdout: the check line); 75 budget elapsed
# (re-arm); 2 refused, with Fix: (re-arming will not help); 1 faulted.
#
# Source order: domain.sh, control-domain.sh, the athena:inbox libs, effects.sh,
# control-effects.sh, control-manager.sh, then this file.

FLEET_WAIT_CHILD=""
FLEET_WAIT_TMP=""

# fleet_wait_tree <pid> -- the pid and all its descendants, parents first.
fleet_wait_tree() {
  local c
  printf '%s\n' "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do fleet_wait_tree "${c}"; done
}

# fleet_wait_reap -- kill the in-flight poll or sleep and every descendant of
# it (the poll's curl is a grandchild, inside a command substitution), by PID.
# The tree is listed BEFORE any kill, so an orphaned curl cannot slip out from
# under a dead parent. Safe to call at any time; the framework's EXIT trap calls
# it, so a waiter killed mid-request leaves nothing behind.
fleet_wait_reap() {
  local p="${FLEET_WAIT_CHILD}" tree
  FLEET_WAIT_CHILD=""
  if [ -n "${p}" ]; then
    tree="$(fleet_wait_tree "${p}")"
    # shellcheck disable=SC2086
    kill -TERM ${tree} 2>/dev/null
    wait "${p}" 2>/dev/null
  fi
  [ -n "${FLEET_WAIT_TMP}" ] && rm -rf -- "${FLEET_WAIT_TMP}"
  FLEET_WAIT_TMP=""
  return 0
}

# fleet_wait_refusal_fix <cause> <session_id>
# The Fix: for a refusal, per cause.
fleet_wait_refusal_fix() {
  case "$1" in
    session-unregistered) printf 'the server does not know session %s from this machine. Pass the TOP-LEVEL session id (a subagent id is never registered), or report session_started from this machine first; re-arming will not help.' "$2" ;;
    server-refused) printf 'the server refused the read for session %s (see the server fix above): repair the machine token or the request, owner-issued, never minted; re-arming will not help.' "$2" ;;
    server-unconfigured) printf 'this machine cannot ask the server for session %s: register the athena MCP entry (scripts/add-athena-mcp) and install the machine token (owner-issued, never minted); re-arming will not help.' "$2" ;;
    invalid-cache-path) printf 'XDG_STATE_HOME (%s) is not absolute, so session %s'"'"'s control answers cannot be cached: set it to an absolute path or unset it, then re-arm.' "${XDG_STATE_HOME:-}" "$2" ;;
    *) printf 'unknown refusal cause for session %s; read the lines above.' "$2" ;;
  esac
}

# fleet_control_wait <session_id> <session-cwd> <harness-dir> <interval-s> <budget-s>
fleet_control_wait() {
  local sid="$1" cwd="$2" harness="$3" interval="$4" budget="$5"
  local deadline now remaining nap rc out basis verdict outcome cause last="" polls=0
  if ! fleet_control_cache_path "${sid}" >/dev/null; then
    printf 'fleet-control: wait refused (invalid-cache-path) before any request. Fix: %s\n' "$(fleet_wait_refusal_fix invalid-cache-path "${sid}")" >&2
    return 2
  fi
  FLEET_WAIT_TMP="$(mktemp -d)" || { printf 'fleet-control: wait could not make a temp dir. Fix: check TMPDIR is writable.\n' >&2; return 1; }
  deadline=$(( $(fleet_now) + budget ))
  while :; do
    polls=$((polls + 1))
    # The poll runs as a background child so the trap can reap it (and its
    # curl) mid-request; `wait` returns the child's exit status.
    ( fleet_control_check "${sid}" "${cwd}" "${harness}" "" ) >"${FLEET_WAIT_TMP}/out" 2>"${FLEET_WAIT_TMP}/err" &
    FLEET_WAIT_CHILD=$!
    rc=0; wait "${FLEET_WAIT_CHILD}" || rc=$?
    FLEET_WAIT_CHILD=""
    out="$(cat "${FLEET_WAIT_TMP}/out")"
    basis=""
    case "${out}" in *" basis="*) basis="${out##* basis=}" ;; esac
    verdict="$(fleet_wait_outcome "${rc}" "${basis}")"
    IFS=$'\t' read -r outcome cause <<<"${verdict}"
    case "${outcome}" in
      resume)
        printf '%s\n' "${out}"
        printf 'fleet-control: wait: session %s is back to run on basis server (poll %s). Next: athena:fleet-drain -> Resume (check, fleet-resume claim, spawn one admiral per CLAIMED).\n' "${sid}" "${polls}" >&2
        return 0 ;;
      refused)
        cat "${FLEET_WAIT_TMP}/err" >&2
        printf 'fleet-control: wait refused (%s) for session %s after %s poll(s). Fix: %s\n' "${cause}" "${sid}" "${polls}" "$(fleet_wait_refusal_fix "${cause}" "${sid}")" >&2
        return 2 ;;
      fault)
        cat "${FLEET_WAIT_TMP}/err" >&2
        printf 'fleet-control: wait: poll %s for session %s faulted (check exit %s, line %s%s). Fix: run fleet-control check --session-id %s and fix its error; an error is never read as run.\n' \
          "${polls}" "${sid}" "${rc}" "${out:-<none>}" "${cause:+, cause ${cause}}" "${sid}" >&2
        return 1 ;;
    esac
    # continue: say so once per basis, never once per poll.
    if [ "${basis}" != "${last}" ]; then
      if [ "${basis}" = "server" ]; then
        printf 'fleet-control: wait: session %s: %s; polling every %ss.\n' "${sid}" "${out}" "${interval}" >&2
      else
        cat "${FLEET_WAIT_TMP}/err" >&2
      fi
      last="${basis}"
    fi
    now="$(fleet_now)"
    remaining=$(( deadline - now ))
    if [ "${remaining}" -le 0 ]; then
      printf 'fleet-control: wait: %ss elapsed and session %s is not back to run on basis server (%s poll(s), last basis %s). Re-arm while a drained run remains; this is not "all clear".\n' \
        "${budget}" "${sid}" "${polls}" "${last:-none}" >&2
      return 75
    fi
    nap="${interval}"
    [ "${remaining}" -lt "${nap}" ] && nap="${remaining}"
    sleep "${nap}" &
    FLEET_WAIT_CHILD=$!
    wait "${FLEET_WAIT_CHILD}"
    FLEET_WAIT_CHILD=""
  done
}
