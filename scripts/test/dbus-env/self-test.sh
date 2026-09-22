#!/usr/bin/env bash
# Discovered self-test for scripts/lib/dbus-env.sh.
#
# Proves athena_dbus_env_setup takes the right branch in each state and ALWAYS
# leaves DBUS_SESSION_BUS_ADDRESS exported to a non-empty value (the property
# that suppresses libdbus/GLib autolaunch). Each branch is forced
# deterministically: the /proc-scanning discovery is stubbed by redefining
# _athena_dbus_discover after sourcing, so the test never depends on the live
# session's buses.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
helper="${here}/../../lib/dbus-env.sh"
[ -r "${helper}" ] || { echo "FAIL helper not readable: ${helper}"; exit 1; }

fails=0
tmproot="$(mktemp -d)"
trap 'rm -rf "${tmproot}"' EXIT

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want [$2] got [$3])"; fails=$((fails+1)); fi
}

# --- 1. an already-set value is never overridden ----------------------------
out="$(
  DBUS_SESSION_BUS_ADDRESS="unix:path=/deliberately/set" \
  bash -c '. "'"${helper}"'"; athena_dbus_env_setup; printf "%s" "$DBUS_SESSION_BUS_ADDRESS"'
)"
assert_eq "already-set value is kept" "unix:path=/deliberately/set" "${out}"

# --- 2. XDG_RUNTIME_DIR/bus socket is preferred when it exists ---------------
if command -v python3 >/dev/null 2>&1; then
  xdg="${tmproot}/xdg"; mkdir -p "${xdg}"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "${xdg}/bus"
  if [ -S "${xdg}/bus" ]; then
    out="$(
      env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="${xdg}" \
      bash -c '. "'"${helper}"'"; athena_dbus_env_setup; printf "%s" "$DBUS_SESSION_BUS_ADDRESS"'
    )"
    assert_eq "XDG bus socket chosen" "unix:path=${xdg}/bus" "${out}"
  else
    echo "SKIP XDG bus case (could not create a unix socket)"
  fi
else
  echo "SKIP XDG bus case (no python3 to create a unix socket)"
fi

# --- 3. discovery result is used when there is no XDG bus socket -------------
# Redefine the /proc-scanning discovery to a fixed reachable address; the empty
# XDG dir has no bus socket, so setup must fall to discovery.
out="$(
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="${tmproot}/empty" \
  bash -c '. "'"${helper}"'"; _athena_dbus_discover() { printf "%s" "unix:path=/tmp/discovered-bus"; }; athena_dbus_env_setup; printf "%s" "$DBUS_SESSION_BUS_ADDRESS"'
)"
assert_eq "discovered bus used" "unix:path=/tmp/discovered-bus" "${out}"

# --- 4. suppression sentinel when nothing is reachable ----------------------
mkdir -p "${tmproot}/empty2"
out="$(
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="${tmproot}/empty2" \
  bash -c '. "'"${helper}"'"; _athena_dbus_discover() { return 0; }; athena_dbus_env_setup; printf "%s" "$DBUS_SESSION_BUS_ADDRESS"'
)"
assert_eq "suppression sentinel set" "unix:path=${tmproot}/empty2/athena-no-session-bus" "${out}"

# --- 5. the sentinel is unconnectable => never a live socket ----------------
if [ -S "${tmproot}/empty2/athena-no-session-bus" ]; then
  echo "FAIL sentinel path is unexpectedly a live socket"; fails=$((fails+1))
else
  echo "PASS sentinel path is not a socket (autolaunch stays suppressed)"
fi

# --- 6. setup always leaves a non-empty exported value ----------------------
out="$(
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="${tmproot}/empty3" \
  bash -c 'set -euo pipefail; . "'"${helper}"'"; _athena_dbus_discover() { return 0; }; athena_dbus_env_setup; [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && echo NONEMPTY'
)"
assert_eq "always leaves a non-empty value under set -e" "NONEMPTY" "${out}"

if [ "${fails}" -eq 0 ]; then
  echo "dbus-env/self-test.sh: OK"
  exit 0
fi
echo "dbus-env/self-test.sh: ${fails} failure(s)" >&2
exit 1
