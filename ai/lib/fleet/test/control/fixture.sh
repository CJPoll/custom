#!/usr/bin/env bash
# fixture.sh -- the fake-server world the server, watch and wait parts share
# (DND-1007). Sourced after common.sh, never run: the inbox and effects
# libraries, an isolated fleet_fixture_env, two throwaway repos registered as
# the gen_saas and custom projects, and fc().
# shellcheck disable=SC1091
for f in err names descriptor logchan maildir fence session fs lock inbox; do . "${AI}/skills/athena:inbox/lib/${f}.sh"; done
# shellcheck source=../../effects.sh
. "${LIB}/effects.sh"
# shellcheck source=../../control-effects.sh
. "${LIB}/control-effects.sh"
# shellcheck source=../helpers.sh
. "${TESTS}/helpers.sh"
fleet_fixture_env
# DND-1007: these only cap a HANG. No verdict in these parts depends on either
# one firing: every answer comes from the loopback fake server, an unreachable
# server is a closed port (refused at once, never a timeout), and the one
# held request (the trap case in wait/) sets its own FLEET_MAX_TIME_S. They
# were 2 s and 3 s, so a loaded host could turn a server answer into
# "server-unreachable": a verdict that flipped with machine speed.
export FLEET_CONNECT_TIMEOUT_S=30 FLEET_MAX_TIME_S=60

# Two throwaway repos registered as the gen_saas and custom projects.
for p in gen_saas custom; do
  git init -q "${TMP}/${p}"
  jq -n --arg r "$(realpath "${TMP}/${p}/.git")" '{v: 1, repo: $r, channels: {}}' > "${ATHENA_INBOX_ROOT}/projects/${p}.json"
done
chmod 600 "${ATHENA_INBOX_ROOT}"/projects/*.json
GS="${TMP}/gen_saas"
CU="${TMP}/custom"
CACHE="${XDG_STATE_HOME}/athena/fleet/${SID}.json"

# fc <args...> -- run fleet-control check; sets OUT, ERR, RC.
fc() {
  OUT="$("${BIN}" "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

