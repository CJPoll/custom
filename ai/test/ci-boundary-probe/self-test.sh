#!/usr/bin/env bash
# self-test.sh -- functional suite for dockerfiles/ci-harness/boundary-probe.sh
# (DND-2085). The probe runs in CI as the image's root in an unmasked sibling
# container and must find /proc/sys and /proc/sysrq-trigger unwritable and
# /proc/kcore unreadable. Here it runs as a non-root user against a fixture
# tree (--root DIR), where file modes stand in for the kernel's denial. Each
# denied row has a miss case: the same fixture with that one path allowed must
# fail, naming the path. Functional only (DND-1222): files, no docker, no
# network, no timing.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
PROBE="${ROOT}/dockerfiles/ci-harness/boundary-probe.sh"

[ -x "${PROBE}" ] || { echo "ci-boundary-probe self-test: FAIL -- ${PROBE} is missing or not executable"; echo "  Fix: restore dockerfiles/ci-harness/boundary-probe.sh (DND-2085), mode 0755."; exit 1; }
if [ "$(id -u)" -eq 0 ]; then
  echo "ci-boundary-probe self-test: FAIL -- running as root, so file modes deny nothing and every miss case would pass for the wrong reason"
  echo "  Fix: run this suite as a non-root user (harness-gate in CI runs as ci)."
  exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "${TMP}" 2>/dev/null; rm -rf "${TMP}"' EXIT

# fixture NAME: a /proc stand-in where every probed path is denied.
fixture() {
  local d="${TMP}/$1"
  mkdir -p "${d}/sys/kernel"
  : > "${d}/sys/kernel/core_pattern"
  : > "${d}/sysrq-trigger"
  : > "${d}/kcore"
  chmod 0444 "${d}/sys/kernel/core_pattern" "${d}/sysrq-trigger"
  chmod 0000 "${d}/kcore"
  printf '%s\n' "${d}"
}

# expect NAME WANT-EXIT NEEDLE CMD...: run CMD, check its exit and output.
expect() {
  local name="$1" want="$2" needle="$3" out rc
  shift 3
  out="$("$@" 2>&1)"
  rc=$?
  if [ "${rc}" -eq "${want}" ] && [[ "${out}" == *"${needle}"* ]]; then ok "${name}"; else bad "${name}" "want exit ${want} naming [${needle}], got exit ${rc}: ${out}"; fi
}

d="$(fixture all-denied)"
expect "every row denied passes"            0 "OK"                 "${PROBE}" --root "${d}"

d="$(fixture core-pattern)"; chmod 0644 "${d}/sys/kernel/core_pattern"
expect "writable core_pattern fails"        1 "sys/kernel/core_pattern" "${PROBE}" --root "${d}"
expect "an allowed row names a rootful daemon in its Fix:" 1 "rootful" "${PROBE}" --root "${d}"

d="$(fixture sysrq)"; chmod 0644 "${d}/sysrq-trigger"
expect "writable sysrq-trigger fails"       1 "sysrq-trigger"      "${PROBE}" --root "${d}"

d="$(fixture kcore)"; chmod 0444 "${d}/kcore"
expect "readable kcore fails"               1 "kcore"              "${PROBE}" --root "${d}"

# A probed path that does not exist is not a denial: it could not look.
d="$(fixture missing)"; rm -f "${d}/kcore"
expect "missing kcore is could-not-measure" 3 "could not"          "${PROBE}" --root "${d}"
d="$(fixture missing-sys)"; chmod -R u+w "${d}/sys"; rm -rf "${d}/sys"
expect "missing core_pattern is could-not-measure" 3 "core_pattern" "${PROBE}" --root "${d}"

# On the real /proc the probe must run as uid 0: a non-root denial proves
# nothing about the daemon behind the socket.
expect "non-root on the real /proc is could-not-measure" 3 "uid 0"  "${PROBE}"

expect "--help answers on stdout"           0 "boundary-probe"     "${PROBE}" --help
expect "unknown argument is usage"          2 "Fix:"               "${PROBE}" --bogus
expect "--root without a directory is usage" 2 "Fix:"              "${PROBE}" --root

echo
echo "ci-boundary-probe self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
