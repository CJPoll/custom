#!/usr/bin/env bash
# Discovered self-test for the OpenRC stop path of the system-files/*.initd
# services and the process-tree library they share
# (system-files/lib/initd-proc-tree.sh), DND-812.
#
# The defect: a supervised command that forks long-lived children (run.sh ->
# run-helper.sh -> Runner.Listener; dockerd-rootless.sh -> rootlesskit ->
# dockerd) is the ONLY process supervise-daemon signals on stop. The children
# re-parent to PID 1 and keep running, so a "stopped" GitHub runner kept taking
# jobs.
#
# HERMETIC. It never runs openrc-run, supervise-daemon, sudo, or anything under
# /etc. It emulates the two openrc-run invocations that matter:
#   start: source the initd, then start its command the way supervise-daemon
#          does (chdir to $directory, apply every --env from
#          supervise_daemon_args / start_stop_daemon_args), detached;
#   stop:  source the initd in a NEW process, SIGTERM only the supervised pid
#          (exactly what supervise-daemon --stop does), wait for it, then run
#          stop_post if the initd defines one.
# DND-838 adds the respawn path: SIGKILL only the supervised pid (a crash),
# then start the command again WITHOUT start_pre, as supervise-daemon does,
# and assert the crashed command's children are gone (one Runner.Listener).
# Every process it starts is a stub under a private temp dir, and cleanup kills
# only pids it recorded, by PID, after checking they still live under that dir.
set -uo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
sysfiles="$(cd -- "${here}/../.." && pwd -P)"
lib="${sysfiles}/lib/initd-proc-tree.sh"
reap_exec="${sysfiles}/lib/initd-reap-exec"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/initd-proc-tree.XXXXXX")"
state="${tmp}/state"
mkdir -p "${state}"
: > "${state}/all.pids"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# alive PID: the process exists and is not a zombie (a SIGKILLed orphan is a
# zombie until its new parent reaps it; kill -0 still succeeds on it).
alive() {
  local st
  st="$(awk '/^State:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null)" || return 1
  [ -n "${st}" ] && [ "${st}" != "Z" ]
}

# Every process this suite starts inherits INITD_PROC_TREE_SELFTEST=<tmp>, so
# cleanup finds its own leftovers (even unrecorded ones) and nothing else. It
# kills by PID, never by name.
marker="INITD_PROC_TREE_SELFTEST=${tmp}"
export INITD_PROC_TREE_SELFTEST="${tmp}"
cleanup() {
  local d pid
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "${pid}" = "$$" ] && continue
    grep -zqFx -- "${marker}" "${d}/environ" 2>/dev/null || continue
    if alive "${pid}"; then kill -KILL "${pid}" 2>/dev/null || true; fi
  done
  rm -rf "${tmp}"
}
trap cleanup EXIT INT TERM

me="$(id -un)"

# A real binary copied under a runner dir, so /proc/<pid>/exe lies inside it
# (the live Runner.Listener is RUNNER_DIR/bin/Runner.Listener).
mk_sleeper() { # dest
  mkdir -p "$(dirname "$1")"
  cp "$(command -v sleep)" "$1"
  chmod 755 "$1"
  "$1" 0 || { echo "FAIL cannot run a copied sleep binary at $1"; exit 1; }
}

# A stub supervised command: forks a long-lived child (optionally through an
# intermediate shell, like run.sh -> run-helper.sh -> Listener), records every
# pid, signals ready, and waits. SIGTERM kills only this shell; the child lives
# on, which is exactly the live defect.
mk_stub() { # path name child-cmd
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/sh
echo \$\$ >> "${state}/all.pids"
sh -c 'echo \$\$ >> "${state}/all.pids"; echo \$\$ > "${state}/$2.helper"; $3 & echo \$! >> "${state}/all.pids"; echo \$! > "${state}/$2.child"; wait' &
wait_n=0
while [ ! -s "${state}/$2.child" ] && [ \$wait_n -lt 100 ]; do sleep 0.05; wait_n=\$((wait_n + 1)); done
: > "${state}/$2.ready"
wait
EOF
  chmod 755 "$1"
}

# The emulated openrc-run. Written as a file so start and stop run as separate
# processes, the way two `rc-service` invocations do.
driver="${tmp}/openrc-run-emu.sh"
cat > "${driver}" <<'EOF'
#!/bin/sh
# usage: openrc-run-emu.sh start|respawn|crash|stop INITD NAME STATE [COMMAND_OVERRIDE]
#   respawn: what supervise-daemon does after its command dies: start the
#            command again, with the same --env args, and NO start_pre.
#   crash:   SIGKILL only the supervised pid (the command dies on its own).
phase="$1"; initd="$2"; name="$3"; state="$4"; override="${5:-}"
ebegin() { :; }
eend() { return "${1:-0}"; }
einfo() { echo "einfo: $*" >&2; }
ewarn() { echo "ewarn: $*" >&2; }
eerror() { echo "eerror: $*" >&2; }
yesno() { case "$1" in [Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]|[Oo][Nn]) return 0 ;; esac; return 1; }
service_set_value() { :; }
service_get_value() { :; }
. "${initd}"
# COMMAND_OVERRIDE replaces the service's real program with a stub. When the
# initd runs it through the respawn-safe wrapper (DND-838), the real program is
# the first word after `--` in command_args, and that is what is replaced.
if [ -n "${override}" ]; then
  if [ -n "${ATHENA_REAP_EXEC:-}" ] && [ "${command}" = "${ATHENA_REAP_EXEC}" ]; then
    new_args=""; after=0; replaced=0
    for w in ${command_args:-}; do
      if [ "${after}" = 1 ] && [ "${replaced}" = 0 ]; then w="${override}"; replaced=1; fi
      [ "${w}" = "--" ] && after=1
      new_args="${new_args:+${new_args} }${w}"
    done
    [ "${replaced}" = 1 ] || { echo "emu: no program after -- in: ${command_args:-}" >&2; exit 3; }
    command_args="${new_args}"
  else
    command="${override}"
  fi
fi
case "${phase}" in
crash)
  pid="$(cat "${state}/${name}.supervised")"
  kill -KILL "${pid}" 2>/dev/null
  n=0
  while [ $n -lt 100 ]; do
    st="$(awk '/^State:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null)"
    { [ -z "${st}" ] || [ "${st}" = "Z" ]; } && break
    sleep 0.05; n=$((n + 1))
  done
  ;;
start|respawn)
  # openrc-run runs start_pre first and aborts the start on failure. Its log
  # pre-create (`: > /var/log/<name>.log`) cannot succeed for a normal user,
  # and every name here is a selftest-* name no real service has. Under /bin/sh
  # (POSIX mode) a failed redirection on `:` exits the shell, so run_driver
  # runs the START phase under bash, where it is a harmless error. The stop
  # phase, and the lib cases below, run under /bin/sh as openrc-run does.
  if [ "${phase}" = start ] && command -v start_pre >/dev/null 2>&1; then
    start_pre || exit $?
  fi
  envs=""
  if [ -n "${supervisor:-}" ]; then args="${supervise_daemon_args-${start_stop_daemon_args:-}}"
  else args="${start_stop_daemon_args:-}"; fi
  # shellcheck disable=SC2086
  set -- ${args}
  while [ $# -gt 0 ]; do
    case "$1" in
      -e|--env) envs="${envs} $2"; shift 2 ;;
      --env=*) envs="${envs} ${1#--env=}"; shift ;;
      *) shift ;;
    esac
  done
  # shellcheck disable=SC2086
  ( [ -n "${directory:-}" ] && cd "${directory}"; exec env ${envs} "${command}" ${command_args:-} ) \
    </dev/null >/dev/null 2>&1 &
  echo $! > "${state}/${name}.supervised"
  echo $! >> "${state}/all.pids"
  ;;
stop)
  pid="$(cat "${state}/${name}.supervised")"
  kill -TERM "${pid}" 2>/dev/null
  n=0
  while [ $n -lt 100 ]; do
    st="$(awk '/^State:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null)"
    { [ -z "${st}" ] || [ "${st}" = "Z" ]; } && break
    sleep 0.05; n=$((n + 1))
  done
  if command -v stop_post >/dev/null 2>&1; then
    stop_post; exit $?
  fi
  exit 0
  ;;
esac
EOF
chmod 755 "${driver}"

wait_ready() { # name
  local n=0
  while [ ! -e "${state}/$1.ready" ] && [ "${n}" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  [ -e "${state}/$1.ready" ]
}

# run_driver: one emulated openrc-run. RC_SVCNAME (always selftest-NAME) is
# set in its env exactly as in the real openrc-run, so the reaper must NOT
# match on it, or the stop side would match itself.
run_driver() { # phase initd name override env...
  local phase="$1" initd="$2" name="$3" override="$4"; shift 4
  env RC_SVCNAME="selftest-${name}" ATHENA_PROC_TREE_LIB="${ATHENA_PROC_TREE_LIB_OVERRIDE:-${lib}}" \
    ATHENA_REAP_EXEC="${ATHENA_REAP_EXEC_OVERRIDE:-${reap_exec}}" \
    ATHENA_PROC_TREE_TIMEOUT=3 "$@" \
    "$([ "${phase}" = start ] && echo bash || echo sh)" "${driver}" "${phase}" "${initd}" "${name}" "${state}" "${override}"
}

child_of() { cat "${state}/$1.child" 2>/dev/null; }
helper_of() { cat "${state}/$1.helper" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. github-runner: stop kills run.sh's whole tree, for THIS instance only.
#    Two instances, dirs chosen so one is a string prefix of the other
#    (actions-runner vs actions-runner-2): an unanchored match kills both.
r1="${tmp}/home/actions-runner"
r2="${tmp}/home/actions-runner-2"
mk_sleeper "${r1}/bin/Runner.Listener"
mk_sleeper "${r2}/bin/Runner.Listener"
mk_stub "${r1}/run.sh" gh1 "${r1}/bin/Runner.Listener 300"
mk_stub "${r2}/run.sh" gh2 "${r2}/bin/Runner.Listener 300"
: > "${r1}/.runner"; : > "${r2}/.runner"
[ -d "/run/user/$(id -u)" ] || fail "start_pre needs /run/user/$(id -u) (the initd's XDG_RUNTIME_DIR check); run this as a logged-in user"

gh_env1=(RUNNER_USER="${me}" RUNNER_DIR="${r1}")
gh_env2=(RUNNER_USER="${me}" RUNNER_DIR="${r2}")
run_driver start "${sysfiles}/github-runner.initd" gh1 "" "${gh_env1[@]}"
run_driver start "${sysfiles}/github-runner.initd" gh2 "" "${gh_env2[@]}"
if wait_ready gh1 && wait_ready gh2 && alive "$(child_of gh1)" && alive "$(child_of gh2)"; then
  pass "github-runner: both instances start (start_pre passes, Listeners run)"
else
  fail "github-runner: the stubs never started; every 'gone' check below would be vacuous"
fi

# An orphan from BEFORE this fix: untagged, cwd outside the runner dir, but
# its exe is instance 1's Listener. Only the anchored exe match can find it.
( cd "${tmp}" && exec "${r1}/bin/Runner.Listener" 300 ) </dev/null >/dev/null 2>&1 &
legacy1=$!; disown "${legacy1}"; echo "${legacy1}" >> "${state}/all.pids"
# An untagged process of instance 2 whose cwd is instance 2's dir.
( cd "${r2}" && exec "$(command -v sleep)" 300 ) </dev/null >/dev/null 2>&1 &
legacy2=$!; disown "${legacy2}"; echo "${legacy2}" >> "${state}/all.pids"

# A bystander that carries RC_SVCNAME=selftest-gh1 but is not in the tree, as a
# concurrent `rc-service selftest-gh1 status` would. RC_SVCNAME is NOT the tag.
( cd "${tmp}" && exec env RC_SVCNAME=selftest-gh1 "$(command -v sleep)" 300 ) </dev/null >/dev/null 2>&1 &
bystander=$!; disown "${bystander}"; echo "${bystander}" >> "${state}/all.pids"


# Stop instance 1 from a shell whose cwd is inside ITS runner dir: the stop
# side must never match (and kill) itself.
stop_out="$(cd "${r1}" && run_driver stop "${sysfiles}/github-runner.initd" gh1 "" "${gh_env1[@]}" 2>&1)"
stop_rc=$?
[ "${stop_rc}" -eq 0 ] && pass "github-runner: stop exits 0" \
  || fail "github-runner: stop exited ${stop_rc}: ${stop_out}"
alive "$(child_of gh1)" && fail "github-runner: Runner.Listener survived stop (orphaned to PID 1)" \
  || pass "github-runner: Runner.Listener is gone after stop"
alive "$(helper_of gh1)" && fail "github-runner: run-helper survived stop" \
  || pass "github-runner: run-helper is gone after stop"
alive "${legacy1}" && fail "github-runner: a pre-fix untagged orphan of this instance survived stop" \
  || pass "github-runner: a pre-fix untagged orphan of this instance is reaped (anchored exe)"
alive "$(child_of gh2)" && pass "github-runner: the OTHER instance's Listener is untouched" \
  || fail "github-runner: stopping instance 1 killed instance 2's Listener"
alive "${legacy2}" && pass "github-runner: a process with cwd in the sibling-prefix dir is untouched" \
  || fail "github-runner: stopping instance 1 killed a process under actions-runner-2"

alive "${bystander}" && pass "github-runner: a non-tree process carrying RC_SVCNAME=selftest-gh1 is untouched" \
  || fail "github-runner: stop killed a process only because it carried RC_SVCNAME"

stop2_out="$(run_driver stop "${sysfiles}/github-runner.initd" gh2 "" "${gh_env2[@]}" 2>&1)"
alive "$(child_of gh2)" && fail "github-runner: instance 2 Listener survived its own stop: ${stop2_out}" \
  || pass "github-runner: instance 2 stops its own tree"
alive "${legacy2}" && fail "github-runner: instance 2's untagged cwd process survived its own stop" \
  || pass "github-runner: instance 2 reaps its own untagged process (anchored cwd)"

# 1b. start: a leftover of this instance from an unclean stop (here: a pre-fix
#     untagged Listener) is ended BEFORE the new copy starts, so a
#     registration never has two listeners.
( cd "${tmp}" && exec "${r1}/bin/Runner.Listener" 300 ) </dev/null >/dev/null 2>&1 &
leftover=$!; disown "${leftover}"; echo "${leftover}" >> "${state}/all.pids"
rm -f "${state}/gh1.ready" "${state}/gh1.child" "${state}/gh1.helper"
restart_out="$(run_driver start "${sysfiles}/github-runner.initd" gh1 "" "${gh_env1[@]}" 2>&1)"
restart_rc=$?
if [ "${restart_rc}" -eq 0 ] && wait_ready gh1; then pass "github-runner: start succeeds with a leftover present"
else fail "github-runner: start exited ${restart_rc}: ${restart_out}"; fi
alive "${leftover}" && fail "github-runner: start left the old Listener running (two listeners)" \
  || pass "github-runner: start ends this instance's leftover Listener first"
alive "$(child_of gh1)" && pass "github-runner: the new Listener runs after start" \
  || fail "github-runner: start reaped its own new Listener"
run_driver stop "${sysfiles}/github-runner.initd" gh1 "" "${gh_env1[@]}" >/dev/null 2>&1
alive "$(child_of gh1)" && fail "github-runner: the restarted Listener survived stop" \
  || pass "github-runner: the restarted tree stops cleanly"

# ---------------------------------------------------------------------------
# 2. The rest of the class: every supervised initd whose command can fork.
#    The command is overridden with a stub; the stop logic is the initd's own.
sweep() { # initd name env...
  local initd="$1" name="$2"; shift 2
  local stub="${tmp}/bin/${name}-stub"
  mk_stub "${stub}" "${name}" "$(command -v sleep) 300"
  run_driver start "${sysfiles}/${initd}" "${name}" "${stub}" "$@"
  if ! wait_ready "${name}" || ! alive "$(child_of "${name}")"; then
    fail "${initd}: stub never started, so its stop cannot be judged"; return
  fi
  local out rc
  out="$(run_driver stop "${sysfiles}/${initd}" "${name}" "${stub}" "$@" 2>&1)"; rc=$?
  [ "${rc}" -eq 0 ] || fail "${initd}: stop exited ${rc}: ${out}"
  if alive "$(child_of "${name}")" || alive "$(helper_of "${name}")"; then
    fail "${initd}: the command's children survived stop (orphaned to PID 1)"
  else
    pass "${initd}: stop leaves no child of the command running"
  fi
}
printf '[[runners]]\n' > "${tmp}/gitlab-config.toml"
sweep gitlab-runner.initd gitlab-runner RUNNER_USER="${me}" RUNNER_HOME="${tmp}" \
  RUNNER_BIN="${tmp}/bin/gitlab-runner-stub" RUNNER_CONFIG="${tmp}/gitlab-config.toml"
sweep docker-rootless-github-runner.initd docker-rootless-github-runner DOCKER_ROOTLESS_USER="${me}"
sweep docker-rootless-gitlab-runner.initd docker-rootless-gitlab-runner DOCKER_ROOTLESS_USER="${me}"
sweep docker-rootless-athena.initd docker-rootless-athena DOCKER_ROOTLESS_USER="${me}"
sweep btmon.initd btmon

# ---------------------------------------------------------------------------
# 2b. Respawn (DND-838). When its command dies, supervise-daemon starts it
#     again with the same --env args and runs NO start_pre. So the start-side
#     reap never runs, and whatever the dead command forked (run.sh's
#     Runner.Listener) would live on next to the new copy: two listeners for
#     one registration. Every initd run under supervise-daemon needs a case
#     here; the discovery check below fails on one that has none.
exe_count() { # PATH: how many live processes run exactly PATH
  local d n=0
  for d in /proc/[0-9]*; do
    [ "$(readlink "${d}/exe" 2>/dev/null)" = "$1" ] || continue
    alive "${d#/proc/}" && n=$((n + 1))
  done
  echo "${n}"
}
respawn_covered=" "
respawn_listener=""
respawn_case() { # initd name stub|"" env...
  local initd="$1" name="$2" override=""; shift 2
  if [ "$1" = stub ]; then
    override="${tmp}/bin/${name}-stub"
    mk_stub "${override}" "${name}" "$(command -v sleep) 300"
  fi
  shift
  respawn_covered="${respawn_covered}${initd} "
  run_driver start "${sysfiles}/${initd}" "${name}" "${override}" "$@"
  if ! wait_ready "${name}" || ! alive "$(child_of "${name}")"; then
    fail "${initd}: respawn: the command never started, so its respawn cannot be judged"; return
  fi
  local old_child old_helper out rc
  old_child="$(child_of "${name}")"; old_helper="$(helper_of "${name}")"
  run_driver crash "${sysfiles}/${initd}" "${name}" "${override}" "$@"
  if ! alive "${old_child}"; then
    fail "${initd}: respawn: the crash also ended the child, so this case proves nothing"; return
  fi
  rm -f "${state}/${name}.ready" "${state}/${name}.child" "${state}/${name}.helper"
  out="$(run_driver respawn "${sysfiles}/${initd}" "${name}" "${override}" "$@" 2>&1)"; rc=$?
  if [ "${rc}" -ne 0 ] || ! wait_ready "${name}" || ! alive "$(child_of "${name}")"; then
    fail "${initd}: respawn: the respawned command never came up (rc=${rc}): ${out}"
  elif alive "${old_child}" || alive "${old_helper}"; then
    fail "${initd}: respawn: the crashed command's children run next to the respawned copy"
  else
    pass "${initd}: respawn ends the crashed command's children before the new copy runs"
  fi
  if [ -n "${respawn_listener}" ]; then
    local count
    count="$(exe_count "${respawn_listener}")"
    [ "${count}" -eq 1 ] && pass "${initd}: exactly one listener after a respawn" \
      || fail "${initd}: ${count} listeners after a respawn (want 1)"
  fi
  run_driver stop "${sysfiles}/${initd}" "${name}" "${override}" "$@" >/dev/null 2>&1
  alive "$(child_of "${name}")" && fail "${initd}: respawn: the respawned tree survived stop" \
    || pass "${initd}: the respawned tree stops cleanly"
}

r3="${tmp}/home/actions-runner-3"
mk_sleeper "${r3}/bin/Runner.Listener"
mk_stub "${r3}/run.sh" gh3 "${r3}/bin/Runner.Listener 300"
: > "${r3}/.runner"
respawn_listener="${r3}/bin/Runner.Listener"
respawn_case github-runner.initd gh3 "" RUNNER_USER="${me}" RUNNER_DIR="${r3}"
respawn_listener=""
respawn_case gitlab-runner.initd glr-respawn stub RUNNER_USER="${me}" RUNNER_HOME="${tmp}" \
  RUNNER_BIN="${tmp}/bin/glr-respawn-stub" RUNNER_CONFIG="${tmp}/gitlab-config.toml"
respawn_case docker-rootless-github-runner.initd dgh-respawn stub DOCKER_ROOTLESS_USER="${me}"
respawn_case docker-rootless-gitlab-runner.initd dgl-respawn stub DOCKER_ROOTLESS_USER="${me}"

supervised=""
for f in "${sysfiles}"/*.initd; do
  grep -q '^supervisor="supervise-daemon"' "${f}" || continue
  b="$(basename "${f}")"
  supervised="${supervised}${b} "
  case "${respawn_covered}" in
    *" ${b} "*) ;;
    *) fail "${b}: runs under supervise-daemon (so it respawns) but has no respawn_case in this test" ;;
  esac
done
if [ -n "${supervised}" ]; then
  pass "respawn: every supervise-daemon initd has a respawn case (${supervised% })"
else
  fail "respawn: found no supervise-daemon initd under ${sysfiles}; the discovery grep is wrong"
fi

# 2c. The respawn wrapper refuses to run without its inputs, loudly, and
#     never execs the command then (a missing tag must not read as "nothing
#     to reap").
wrap_case() { # desc env-assignments... -- wrapper-args...
  local desc="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local out rc
  rm -f "${tmp}/wrap-ran"
  out="$(env -u ATHENA_SVC_TREE "${envs[@]}" sh "${reap_exec}" "$@" 2>&1)"; rc=$?
  if [ "${rc}" -eq 2 ] && [ ! -e "${tmp}/wrap-ran" ]; then pass "reap-exec: ${desc} -> 2, command not run"
  else fail "reap-exec: ${desc} -> rc ${rc}, command ran: $([ -e "${tmp}/wrap-ran" ] && echo yes || echo no): ${out}"; fi
  case "${out}" in *Fix:*) : ;; *) fail "reap-exec: ${desc}: no Fix: line in: ${out}" ;; esac
}
if [ -r "${reap_exec}" ]; then
  help_out="$(sh "${reap_exec}" --help 2>/dev/null)"; help_rc=$?
  if [ "${help_rc}" -eq 0 ] && [ -n "${help_out}" ]; then pass "reap-exec: --help prints usage on stdout, exit 0"
  else fail "reap-exec: --help -> rc ${help_rc}, stdout '${help_out}'"; fi
  wrap_case "no ATHENA_SVC_TREE" -- --lib "${lib}" -- touch "${tmp}/wrap-ran"
  wrap_case "empty ATHENA_SVC_TREE" ATHENA_SVC_TREE= -- --lib "${lib}" -- touch "${tmp}/wrap-ran"
  wrap_case "unknown option" ATHENA_SVC_TREE=selftest-wrap -- --lib "${lib}" --bogus -- touch "${tmp}/wrap-ran"
  wrap_case "no command after --" ATHENA_SVC_TREE=selftest-wrap -- --lib "${lib}" --
  wrap_case "missing lib" ATHENA_SVC_TREE=selftest-wrap -- --lib "${tmp}/no-such-lib.sh" -- touch "${tmp}/wrap-ran"
  wrap_case "relative anchor" ATHENA_SVC_TREE=selftest-wrap -- --lib "${lib}" --anchor rel/dir -- touch "${tmp}/wrap-ran"
  # The happy path execs the command with the tag restored and its cwd kept.
  mkdir -p "${tmp}/wrapdir"
  ok_out="$(cd "${tmp}/wrapdir" && env ATHENA_SVC_TREE=selftest-wrap-ok sh "${reap_exec}" --lib "${lib}" --timeout 1 \
    -- sh -c 'printf "%s|%s" "${ATHENA_SVC_TREE}" "$(pwd -P)"' 2>/dev/null)"; ok_rc=$?
  if [ "${ok_rc}" -eq 0 ] && [ "${ok_out}" = "selftest-wrap-ok|$(cd "${tmp}/wrapdir" && pwd -P)" ]; then
    pass "reap-exec: execs the command with the tag and the original cwd"
  else
    fail "reap-exec: happy path rc ${ok_rc}, got '${ok_out}'"
  fi
else
  fail "reap-exec: ${reap_exec} does not exist"
fi

# 2d. A supervised initd whose respawn wrapper is not installed refuses to
#     start, with a Fix:, instead of starting a command that can double.
nowrap_out="$(ATHENA_REAP_EXEC_OVERRIDE="${tmp}/no-such-reap-exec" \
  run_driver start "${sysfiles}/docker-rootless-github-runner.initd" nowrap "${tmp}/bin/dgh-respawn-stub" \
  DOCKER_ROOTLESS_USER="${me}" 2>&1)"
nowrap_rc=$?
if [ "${nowrap_rc}" -ne 0 ] && [ ! -e "${state}/nowrap.supervised" ]; then
  pass "missing reap-exec: start fails and starts nothing"
else
  fail "missing reap-exec: start exited ${nowrap_rc} (supervised pid file: $([ -e "${state}/nowrap.supervised" ] && echo yes || echo no))"
fi
case "${nowrap_out}" in
  *Fix:*) pass "missing reap-exec: start failure carries a Fix: line" ;;
  *) fail "missing reap-exec: start failure has no Fix: line: ${nowrap_out}" ;;
esac

# ---------------------------------------------------------------------------
# 3. A missing library is a loud stop failure with a Fix:, never a silent
#    "nothing to reap".
mk_stub "${tmp}/bin/nolib-stub" nolib "$(command -v sleep) 300"
nostart_out="$(ATHENA_PROC_TREE_LIB_OVERRIDE="${tmp}/no-such-lib.sh" \
  run_driver start "${sysfiles}/docker-rootless-athena.initd" nolib "${tmp}/bin/nolib-stub" DOCKER_ROOTLESS_USER="${me}" 2>&1)"
nostart_rc=$?
if [ "${nostart_rc}" -ne 0 ] && [ ! -e "${state}/nolib.supervised" ]; then
  pass "missing lib: start fails and starts nothing"
else
  fail "missing lib: start exited ${nostart_rc} (supervised pid file: $([ -e "${state}/nolib.supervised" ] && echo yes || echo no))"
fi
case "${nostart_out}" in
  *Fix:*) pass "missing lib: start failure carries a Fix: line" ;;
  *) fail "missing lib: start failure has no Fix: line: ${nostart_out}" ;;
esac
# Stop with the lib missing: start the tree WITH the lib, then lose it.
run_driver start "${sysfiles}/docker-rootless-athena.initd" nolib "${tmp}/bin/nolib-stub" DOCKER_ROOTLESS_USER="${me}"
wait_ready nolib || fail "nolib stub never became ready"
nolib_out="$(ATHENA_PROC_TREE_LIB_OVERRIDE="${tmp}/no-such-lib.sh" \
  run_driver stop "${sysfiles}/docker-rootless-athena.initd" nolib "${tmp}/bin/nolib-stub" DOCKER_ROOTLESS_USER="${me}" 2>&1)"
nolib_rc=$?
if [ "${nolib_rc}" -ne 0 ]; then pass "missing lib: stop fails"; else fail "missing lib: stop exited 0"; fi
case "${nolib_out}" in
  *Fix:*) pass "missing lib: failure carries a Fix: line" ;;
  *) fail "missing lib: no Fix: line in: ${nolib_out}" ;;
esac

# ---------------------------------------------------------------------------
# 4. Library contract: a malformed key is an error (exit 2, Fix:), never an
#    empty match that reads as "nothing to reap".
if [ -r "${lib}" ]; then
  lib_case() { # desc expected-rc args...
    local desc="$1" want="$2"; shift 2
    local out rc
    # shellcheck disable=SC1090
    out="$(sh -c '. "$0" && proc_tree_reap "$@"' "${lib}" "$@" 2>&1)"; rc=$?
    if [ "${rc}" -eq "${want}" ]; then pass "lib: ${desc} -> ${want}"
    else fail "lib: ${desc} -> ${rc} (want ${want}): ${out}"; fi
    if [ "${want}" -eq 2 ]; then
      case "${out}" in *Fix:*) : ;; *) fail "lib: ${desc}: no Fix: line" ;; esac
    fi
  }
  uid="$(id -u)"
  lib_case "empty tag" 2 "" "${uid}" 1
  lib_case "tag containing =" 2 "a=b" "${uid}" 1
  lib_case "empty uid (a failed id -u)" 2 svc "" 1
  lib_case "non-numeric uid" 2 svc abc 1
  lib_case "non-numeric timeout" 2 svc "${uid}" x
  lib_case "relative anchor" 2 svc "${uid}" 1 relative/dir
  lib_case "root anchor" 2 svc "${uid}" 1 /
  lib_case "empty anchor" 2 svc "${uid}" 1 ""
  lib_case "no matches is a clean 0" 0 "initd-proc-tree-selftest-none-$$" "${uid}" 1 "${tmp}/nonexistent"
  # The exe-equals-anchor path gitlab-runner uses (anchor = RUNNER_BIN): an
  # untagged process running exactly that binary is found; one running a
  # sibling binary whose name merely starts with it is not.
  mk_sleeper "${tmp}/usr/bin/gitlab-runner"
  mk_sleeper "${tmp}/usr/bin/gitlab-runner-helper"
  ( cd / && exec "${tmp}/usr/bin/gitlab-runner" 300 ) </dev/null >/dev/null 2>&1 &
  glr=$!; disown "${glr}"
  ( cd / && exec "${tmp}/usr/bin/gitlab-runner-helper" 300 ) </dev/null >/dev/null 2>&1 &
  glh=$!; disown "${glh}"
  n=0; while { [ "$(readlink "/proc/${glr}/exe" 2>/dev/null)" != "${tmp}/usr/bin/gitlab-runner" ] \
    || [ "$(readlink "/proc/${glh}/exe" 2>/dev/null)" != "${tmp}/usr/bin/gitlab-runner-helper" ]; } \
    && [ "${n}" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  exe_out="$(. "${lib}" && proc_tree_reap "initd-proc-tree-selftest-exe-$$" "${uid}" 1 "${tmp}/usr/bin/gitlab-runner" 2>&1)"
  if ! alive "${glr}"; then pass "lib: an untagged process running exactly the anchor binary is reaped"
  else fail "lib: exe-equals-anchor process survived: ${exe_out}"; fi
  if alive "${glh}"; then pass "lib: a binary whose path only starts with the anchor is untouched"
  else fail "lib: reaped gitlab-runner-helper for anchor gitlab-runner"; fi
  kill -KILL "${glh}" 2>/dev/null || true
  # A tree member that ignores SIGTERM (ignored signals survive exec, so the
  # sleep ignores it too) must still be ended: SIGKILL escalation.
  stubborn_tag="initd-proc-tree-selftest-stubborn-$$"
  env ATHENA_SVC_TREE="${stubborn_tag}" sh -c 'trap "" TERM; sleep 300' </dev/null >/dev/null 2>&1 &
  stubborn=$!; disown "${stubborn}"
  n=0; while ! grep -zqFx -- "ATHENA_SVC_TREE=${stubborn_tag}" "/proc/${stubborn}/environ" 2>/dev/null \
    && [ "${n}" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  stubborn_out="$(. "${lib}" && proc_tree_reap "${stubborn_tag}" "${uid}" 1 2>&1)"; stubborn_rc=$?
  if [ "${stubborn_rc}" -eq 0 ] && ! alive "${stubborn}"; then
    pass "lib: a SIGTERM-ignoring tree member is SIGKILLed"
  else
    fail "lib: SIGTERM-ignoring member: rc=${stubborn_rc}, alive=$(alive "${stubborn}" && echo yes || echo no): ${stubborn_out}"
  fi
  case "${stubborn_out}" in
    *SIGKILL*) pass "lib: the escalation to SIGKILL is reported" ;;
    *) fail "lib: SIGKILL escalation not reported: ${stubborn_out}" ;;
  esac
  # The count of what was scanned is visible even on a clean miss.
  miss_out="$(. "${lib}" && proc_tree_reap "initd-proc-tree-selftest-none-$$" "${uid}" 1 2>&1)"
  case "${miss_out}" in
    *scanned*) pass "lib: a clean miss reports what it scanned" ;;
    *) fail "lib: a clean miss is silent: ${miss_out}" ;;
  esac
  # A caller running under `set -f` must still scan /proc, not the literal
  # '/proc/[0-9]*' (DND-838: the reap wrapper splits its anchors that way, and
  # its first cut scanned 0 processes and reported "no leftover processes").
  noglob_tag="initd-proc-tree-selftest-noglob-$$"
  env ATHENA_SVC_TREE="${noglob_tag}" "$(command -v sleep)" 300 </dev/null >/dev/null 2>&1 &
  noglob=$!; disown "${noglob}"
  n=0; while ! grep -zqFx -- "ATHENA_SVC_TREE=${noglob_tag}" "/proc/${noglob}/environ" 2>/dev/null \
    && [ "${n}" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  noglob_out="$(sh -c 'set -f; . "$0" && proc_tree_reap "$1" "$2" 1' "${lib}" "${noglob_tag}" "${uid}" 2>&1)"
  if alive "${noglob}"; then fail "lib: under set -f the tagged process survived: ${noglob_out}"
  else pass "lib: a caller under set -f still finds and ends the tree"; fi
else
  fail "lib: ${lib} does not exist"
fi

if [ "${fails}" -eq 0 ]; then
  echo "initd-proc-tree/self-test.sh: OK"
  exit 0
fi
echo "initd-proc-tree/self-test.sh: ${fails} failure(s)" >&2
exit 1
