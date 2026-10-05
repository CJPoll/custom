#!/usr/bin/env bash
# boundary-probe.sh -- assert the CI gate's unmasked /proc still denies what
# only global root may do (DND-2085, ai/docs/ci-harness-masked-proc.md ->
# The boundary).
#
# Usage: boundary-probe.sh              (as uid 0, in the CI probe container)
#        boundary-probe.sh --root DIR   (a /proc stand-in; the self-test's seam)
#        boundary-probe.sh --help
#
# .gitlab-ci.yml runs it before the gate, in its own container started with
# the gate's three --security-opt values and `--user 0`. On a rootless daemon
# that root is a subuid on the host, so the kernel refuses it:
#   - an open for write of /proc/sys/kernel/core_pattern;
#   - an open for write of /proc/sysrq-trigger;
#   - an open for read of /proc/kcore.
# Each open writes and reads nothing (an append-mode open of zero bytes, a
# read open closed at once), so a probe that finds a path allowed has changed
# no host state. If any is allowed, the daemon behind the job's socket is not
# the `ci` user's rootless one, and the gate must not run unmasked.
#
# Exit: 0 every path denied; 1 a path allowed; 2 usage; 3 could not measure
# (a probed path is missing, or the real /proc probed as non-root, where a
# denial proves nothing).

set -u

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
  exit 0
fi

proc=/proc
seam=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ] || [ ! -d "$2" ]; then
        echo "boundary-probe: --root needs an existing directory" >&2
        echo "  Fix: pass --root DIR (a /proc stand-in), or no arguments to probe /proc." >&2
        exit 2
      fi
      proc="$2"; seam=true; shift 2 ;;
    *)
      echo "boundary-probe: unexpected argument: $1" >&2
      echo "  Fix: run boundary-probe.sh with no arguments (or --root DIR, or --help)." >&2
      exit 2 ;;
  esac
done

if [ "${seam}" = false ] && [ "$(id -u)" -ne 0 ]; then
  echo "boundary-probe: could not measure: running as uid $(id -u), not uid 0, so a denial proves nothing about the daemon" >&2
  echo "  Fix: start the probe container with \`--user 0\` (.gitlab-ci.yml's probe line)." >&2
  exit 3
fi

writes=("sys/kernel/core_pattern" "sysrq-trigger")
reads=("kcore")

for rel in "${writes[@]}" "${reads[@]}"; do
  if [ ! -e "${proc}/${rel}" ]; then
    echo "boundary-probe: could not measure: ${proc}/${rel} does not exist, so its denial cannot be told from its absence" >&2
    echo "  Fix: run the probe in a container whose /proc is a real procfs (the gate's options, not a masked or empty /proc)." >&2
    exit 3
  fi
done

allowed=()
for rel in "${writes[@]}"; do
  if ( : >> "${proc}/${rel}" ) 2>/dev/null; then
    allowed+=("write ${proc}/${rel}")
  else
    echo "boundary-probe: ok: write ${proc}/${rel} denied"
  fi
done
for rel in "${reads[@]}"; do
  if ( exec 3< "${proc}/${rel}" ) 2>/dev/null; then
    allowed+=("read ${proc}/${rel}")
  else
    echo "boundary-probe: ok: read ${proc}/${rel} denied"
  fi
done

if [ "${#allowed[@]}" -gt 0 ]; then
  for a in "${allowed[@]}"; do
    echo "boundary-probe: FAIL -- ${a} was allowed" >&2
  done
  echo "  Fix: the docker socket in this job reaches a rootful daemon, or a container root that is global root. Point the runner's \`ci\` entry back at the \`ci\` user's rootless dockerd (system-files/gitlab-runner-runbook.md, DND-1973) before running the gate unmasked." >&2
  exit 1
fi
echo "boundary-probe: OK -- ${#writes[@]} write(s) and ${#reads[@]} read(s) denied under ${proc}"
