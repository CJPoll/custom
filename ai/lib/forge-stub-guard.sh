# shellcheck shell=bash
# forge-stub-guard.sh — a test that stubs gh/glab on PATH can no longer fall
# through PATH to the real forge CLI (DND-1647; limits under "What it cannot
# see" below). Sourced by every harness suite that
# puts a gh or glab stub on PATH.
#
# The defect: a suite stubs `gh` by prepending a stub directory to PATH. When
# the stub is missing or lacks its execute bit, PATH lookup skips it and finds
# the REAL gh further down. The test then calls the live forge, with no error.
# Measured during DND-1510: ai/test/lead-time/self-test.sh ran a real
# read-only `gh pr view` against a made-up repo because a stub had no execute
# bit. A stub that falls through can also pass a test against live data.
# (The fix commit's BEFORE run is a fresh reproduction of the same class: the
# unfixed suite, chmod removed, passed while calling `gh pr list` and
# `gh repo view` on a stand-in for the real gh.)
#
# The fix is a guard directory that sits on PATH behind every stub and in
# front of the real CLI:
#
#   fsg_arm <dir> [name...]
#       <dir> must be an absolute path with no ':' (a relative one stops
#       matching after any `cd`, and PATH lookup would skip the guard).
#       Creates <dir> with one guard script per name (default: gh glab) and an
#       empty `fallthrough.log`, sets FSG_DIR=<dir>, and prepends <dir> to
#       PATH. Call it BEFORE the suite prepends its own stub directory, so
#       PATH reads stub, guard, then the real CLI. A guard never runs the real
#       CLI: it appends `<name><TAB><argv>` to the log, prints a FAIL with a
#       Fix: on stderr, and exits 97. A suite that builds PATH itself (`env -i
#       PATH=...`) must put "${FSG_DIR}" behind its stub directory.
#
#   fsg_require_stubs <stub_dir> <name>...
#       Fails the suite (exit 1, with a Fix:) when a declared stub is missing,
#       not a regular file, or not executable, before that stub is used.
#
#   fsg_verify
#       Returns 0 when no guard ran. Returns 1, naming each call and a Fix:,
#       when one did, so a suite that swallowed the guard's exit 97 still
#       fails. A missing FSG_DIR or log is "could not measure" and returns 1
#       too, never a clean pass. Call it at the end of the suite and count a
#       non-zero return as a failure.
#
# What it cannot see (named, not hidden): a call to the real CLI by absolute
# path (/usr/bin/gh), and a PATH the suite rebuilds without "${FSG_DIR}".

FSG_LOG=fallthrough.log
FSG_FIX='make the stub exist and executable (`chmod +x <stub_dir>/<name>`), or stub this call; a stubbed suite must never reach the real forge CLI. Do not take the guard directory off PATH to get past this.'

# fsg_arm <dir> [name...]
fsg_arm() {
  local dir="${1:-}" name
  [ "$#" -gt 0 ] && shift
  [ "$#" -gt 0 ] || set -- gh glab
  case "${dir}" in
    /*) ;;
    *)
      echo "forge-stub-guard: FAIL — the guard directory '${dir}' is not an absolute path, so a later cd would take the guard off PATH and let a call reach the real CLI (DND-1647)." >&2
      echo "  Fix: pass fsg_arm an absolute directory inside the suite's mktemp -d, e.g. fsg_arm \"\${TMP}/forge-guard\"." >&2
      exit 1 ;;
  esac
  case "${dir}" in
    *:*)
      echo "forge-stub-guard: FAIL — the guard directory '${dir}' contains ':', the PATH separator, so PATH cannot hold it (DND-1647)." >&2
      echo "  Fix: pass fsg_arm a directory whose path has no ':'." >&2
      exit 1 ;;
  esac
  if [ -z "${dir}" ] || ! mkdir -p "${dir}" || ! : > "${dir}/${FSG_LOG}"; then
    echo "forge-stub-guard: FAIL — could not create the guard directory '${dir}' (DND-1647)." >&2
    echo "  Fix: pass fsg_arm a writable directory inside the suite's mktemp -d." >&2
    exit 1
  fi
  for name in "$@"; do
    cat > "${dir}/${name}" <<'GUARD'
#!/bin/sh
# forge-stub-guard (DND-1647, ai/lib/forge-stub-guard.sh). Stands between a
# suite's stubs and the real CLI. It never runs the real CLI.
name=${0##*/}
printf '%s\t%s\n' "${name}" "$*" >> "${0%/*}/fallthrough.log"
echo "forge-stub-guard: FAIL — this test ran \`${name} $*\` past its stub: the ${name} stub is missing or not executable, so PATH fell through toward the real ${name} (DND-1647). The real ${name} was NOT run." >&2
echo "  Fix: make the stub exist and executable (\`chmod +x <stub_dir>/${name}\`), or stub this call; a stubbed suite must never reach the real forge CLI. Do not take the guard directory off PATH to get past this." >&2
exit 97
GUARD
    chmod +x "${dir}/${name}"
  done
  FSG_DIR="${dir}"
  export FSG_DIR
  PATH="${dir}:${PATH}"
  export PATH
}

# fsg_require_stubs <stub_dir> <name>...
fsg_require_stubs() {
  local dir="${1:-}" name bad=0
  [ "$#" -gt 0 ] && shift
  for name in "$@"; do
    if [ ! -e "${dir}/${name}" ]; then
      echo "forge-stub-guard: FAIL — the declared stub ${dir}/${name} does not exist (DND-1647)." >&2
      bad=1
    elif [ ! -f "${dir}/${name}" ]; then
      echo "forge-stub-guard: FAIL — the declared stub ${dir}/${name} is not a regular file (DND-1647)." >&2
      bad=1
    elif [ ! -x "${dir}/${name}" ]; then
      echo "forge-stub-guard: FAIL — the declared stub ${dir}/${name} is not executable, so PATH would skip it and reach the real ${name} (DND-1647)." >&2
      bad=1
    fi
  done
  if [ "${bad}" -ne 0 ]; then
    echo "  Fix: ${FSG_FIX}" >&2
    exit 1
  fi
}

# fsg_verify
fsg_verify() {
  if [ -z "${FSG_DIR:-}" ] || [ ! -f "${FSG_DIR}/${FSG_LOG}" ]; then
    echo "forge-stub-guard: FAIL — could not measure: the guard log '${FSG_DIR:-<FSG_DIR unset>}/${FSG_LOG}' is gone, so whether a stub fell through is unknown (DND-1647)." >&2
    echo "  Fix: call fsg_arm before the tests and do not delete its directory before fsg_verify." >&2
    return 1
  fi
  [ -s "${FSG_DIR}/${FSG_LOG}" ] || return 0
  echo "forge-stub-guard: FAIL — this suite reached the forge CLI past its stub $(wc -l < "${FSG_DIR}/${FSG_LOG}" | tr -d ' ') time(s); each would have run the REAL CLI without the guard (DND-1647):" >&2
  sed 's/^/  - /' "${FSG_DIR}/${FSG_LOG}" >&2
  echo "  Fix: ${FSG_FIX}" >&2
  return 1
}
