# shellcheck shell=bash
# forge-stub-guard.sh — a test that stubs a tool on PATH can no longer fall
# through PATH to the real tool (DND-1647 for gh/glab; DND-1667 for git,
# docker, curl and claude; limits under "What it cannot see" below). Sourced
# by every harness suite that puts a gh, glab, git, docker, curl or claude stub
# on PATH; ai/bin/check-forge-stub-guard enforces that.
#
# The defect: a suite stubs `gh` by prepending a stub directory to PATH. When
# the stub is missing or lacks its execute bit, PATH lookup skips it and finds
# the REAL gh further down. The test then calls the live forge, with no error.
# Measured during DND-1510: ai/test/lead-time/self-test.sh ran a real
# read-only `gh pr view` against a made-up repo because a stub had no execute
# bit. A stub that falls through can also pass a test against live data.
# (The fix commit's BEFORE run is a fresh reproduction of the same class: the
# unfixed suite, chmod removed, passed while calling `gh pr list` and
# `gh repo view` on a stand-in for the real gh.) The same holds for any tool:
# a git stub that falls through can write a real repo, and a claude stub that
# falls through makes a real model call (DND-1667).
#
# The fix is a guard directory that sits on PATH behind every stub and in
# front of the real tool:
#
#   fsg_arm <dir> [name...]
#       <dir> must be an absolute path with no ':' (a relative one stops
#       matching after any `cd`, and PATH lookup would skip the guard).
#       Creates <dir> with one guard script per name (default: gh glab) and an
#       empty `fallthrough.log`, sets FSG_DIR=<dir>, and prepends <dir> to
#       PATH. Call it BEFORE the suite prepends its own stub directory, so
#       PATH reads stub, guard, then the real tool. A guard never runs the
#       real tool: it appends `<name><TAB><argv>` to the log, prints a FAIL
#       with a Fix: on stderr, and exits 97. A suite that builds PATH itself
#       (`env -i PATH=...`) must put "${FSG_DIR}" behind its stub directory.
#       Use it for a tool the suite never needs for real (gh, glab, claude).
#
#   fsg_make <dir> [name...]
#       fsg_arm without the PATH change (DND-1667). For a tool the suite also
#       runs for real, such as git for its fixtures: a guard at the front of
#       PATH would answer those calls too. The suite puts the guard on each
#       PATH that holds the stub, right behind it:
#       PATH="${STUBS}:${FSG_DIR}:${PATH}". A suite that arms twice (fsg_arm
#       for gh, fsg_make for git) keeps each FSG_DIR in its own variable.
#
#   fsg_require_stubs <stub_dir> <name>...
#       Fails the suite (exit 1, with a Fix:) when a declared stub is missing,
#       not a regular file, or not executable, before that stub is used.
#
#   fsg_verify
#       Returns 0 when no guard ran, in any directory fsg_arm or fsg_make made
#       (FSG_DIRS). Returns 1, naming each call and a Fix:, when one did, so a
#       suite that swallowed the guard's exit 97 still fails. A missing
#       FSG_DIR or log is "could not measure" and returns 1 too, never a clean
#       pass. Call it at the end of the suite and count a non-zero return as a
#       failure.
#
# The agent PATH git wrapper (ai/agent-bin/git, DND-775) sits on PATH in agent
# sessions. A guard in front of it answers first, so neither the wrapper nor
# the git behind it runs; without the wrapper the guard answers the same way.
#
# What it cannot see (named, not hidden): a call to the real tool by absolute
# path (/usr/bin/git), a PATH the suite rebuilds without "${FSG_DIR}", and a
# stub's own pass-through to the real tool (a git shim that ends in
# `exec "${REAL_GIT}"` is the suite's choice).

FSG_LOG=fallthrough.log
FSG_FIX='make the stub exist and executable (`chmod +x <stub_dir>/<name>`), or stub this call; a stubbed suite must never reach the real tool. Do not take the guard directory off PATH to get past this.'

# fsg_make <dir> [name...]
fsg_make() {
  local dir="${1:-}" name
  [ "$#" -gt 0 ] && shift
  [ "$#" -gt 0 ] || set -- gh glab
  case "${dir}" in
    /*) ;;
    *)
      echo "forge-stub-guard: FAIL — the guard directory '${dir}' is not an absolute path, so a later cd would take the guard off PATH and let a call reach the real tool (DND-1647)." >&2
      echo "  Fix: pass fsg_arm/fsg_make an absolute directory inside the suite's mktemp -d, e.g. fsg_arm \"\${TMP}/forge-guard\"." >&2
      exit 1 ;;
  esac
  case "${dir}" in
    *:*)
      echo "forge-stub-guard: FAIL — the guard directory '${dir}' contains ':', the PATH separator, so PATH cannot hold it (DND-1647)." >&2
      echo "  Fix: pass fsg_arm/fsg_make a directory whose path has no ':'." >&2
      exit 1 ;;
  esac
  if [ -z "${dir}" ] || ! mkdir -p "${dir}" || ! : > "${dir}/${FSG_LOG}"; then
    echo "forge-stub-guard: FAIL — could not create the guard directory '${dir}' (DND-1647)." >&2
    echo "  Fix: pass fsg_arm/fsg_make a writable directory inside the suite's mktemp -d." >&2
    exit 1
  fi
  for name in "$@"; do
    cat > "${dir}/${name}" <<'GUARD'
#!/bin/sh
# forge-stub-guard (DND-1647/DND-1667, ai/lib/forge-stub-guard.sh). Stands
# between a suite's stubs and the real tool. It never runs the real tool.
name=${0##*/}
printf '%s\t%s\n' "${name}" "$*" >> "${0%/*}/fallthrough.log"
echo "forge-stub-guard: FAIL — this test ran \`${name} $*\` past its stub: the ${name} stub is missing or not executable, so PATH fell through toward the real ${name} (DND-1647/DND-1667). The real ${name} was NOT run." >&2
echo "  Fix: make the stub exist and executable (\`chmod +x <stub_dir>/${name}\`), or stub this call; a stubbed suite must never reach the real tool. Do not take the guard directory off PATH to get past this." >&2
exit 97
GUARD
    chmod +x "${dir}/${name}"
  done
  FSG_DIR="${dir}"
  # FSG_DIRS is this shell's list for fsg_verify; not exported, so a suite run
  # from inside another never inherits its parent's guard logs.
  FSG_DIRS="${FSG_DIRS:+${FSG_DIRS}:}${dir}"
  export FSG_DIR
}

# fsg_arm <dir> [name...]
fsg_arm() {
  fsg_make "$@"
  PATH="${FSG_DIR}:${PATH}"
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
  local dirs="${FSG_DIRS:-${FSG_DIR:-}}" d rc=0 old_ifs="${IFS}"
  if [ -z "${dirs}" ]; then
    echo "forge-stub-guard: FAIL — could not measure: no guard directory was armed (FSG_DIR unset), so whether a stub fell through is unknown (DND-1647)." >&2
    echo "  Fix: call fsg_arm or fsg_make before the tests and do not delete its directory before fsg_verify." >&2
    return 1
  fi
  IFS=:
  # shellcheck disable=SC2086 # split on ':' on purpose; fsg_make refuses a dir holding ':'
  set -- ${dirs}
  IFS="${old_ifs}"
  for d in "$@"; do
    if [ ! -f "${d}/${FSG_LOG}" ]; then
      echo "forge-stub-guard: FAIL — could not measure: the guard log '${d}/${FSG_LOG}' is gone, so whether a stub fell through is unknown (DND-1647)." >&2
      echo "  Fix: call fsg_arm or fsg_make before the tests and do not delete its directory before fsg_verify." >&2
      rc=1
      continue
    fi
    [ -s "${d}/${FSG_LOG}" ] || continue
    echo "forge-stub-guard: FAIL — this suite reached a tool past its stub $(wc -l < "${d}/${FSG_LOG}" | tr -d ' ') time(s); each would have run the REAL tool without the guard (DND-1647/DND-1667):" >&2
    sed 's/^/  - /' "${d}/${FSG_LOG}" >&2
    echo "  Fix: ${FSG_FIX}" >&2
    rc=1
  done
  return "${rc}"
}
