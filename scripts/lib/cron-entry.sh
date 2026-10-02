# shellcheck shell=bash
# scripts/lib/cron-entry.sh — the ONE answer to "which crontab lines are ours"
# (DND-1503) and the ONE crontab reader (DND-1638) for the cron installers:
# setup-shipwright-cron, setup-clustering-cron, setup-leadtime-cron and
# setup-athena-inbox-client. Also the call of a runner's own --dry-run that
# setup-clustering-cron and setup-leadtime-cron make (DND-1728).
#
# A line is OURS when it is not a comment and one of its whitespace-separated
# fields IS the runner's absolute path. Nothing else is ours:
#   #0 * * * * <runner>          a commented-out entry
#   0 * * * * <runner>.bak       a longer path
#   0 * * * * /backup<runner>    a longer path that contains the runner path
# A substring match (grep -F <runner>) took all three; an installer then
# deleted them on --install and --remove, and --check called them live.
# DND-1480 fixed it in setup-leadtime-cron; this is that matcher, shared.
#
# cron_entry_lines <runner> <class> [<stale-suffix>]
#   Reads crontab text on stdin and prints the lines of <class>, byte for byte.
#   <runner>        the managed entry's absolute path
#   <class>         ours | stale | notours
#                     ours     the lines above
#                     stale    an uncommented line that is not ours, with a
#                              field ending in <stale-suffix> (another copy of
#                              the runner, e.g. a removed worktree's). Empty
#                              when no <stale-suffix> is given.
#                     notours  every line that is not ours (stale included):
#                              what --install and --remove keep
#   <stale-suffix>  optional, e.g. /scripts/athena-leadtime-run.sh
#   Returns 0; 2 with a Fix: on stderr when <runner> is not an absolute path,
#   contains whitespace, or <class> is unknown; and awk's own non-zero exit if
#   awk fails. Every non-zero return prints no lines, so a caller MUST check
#   the status before writing: an unchecked empty "notours" result would
#   replace the whole crontab. A wrong runner must never read as "no lines
#   are ours": an installer would then append a duplicate, and --check would
#   report MISSING for the wrong reason.
#
#   A line ending in a carriage return (<runner>\r) is not ours: it is kept,
#   and --install adds the canonical entry beside it. setup-leadtime-cron did
#   the same before this lib.
#
# ONE classifier serves each installer's --check, --install and --remove, so
# what is counted as ours is exactly what is replaced or removed.
#
# cron_read_crontab <who> [<crontab-cmd>]
#   The current crontab on stdout, read with `<crontab-cmd> -l` (default
#   crontab). The ONE reader every installer uses (DND-1638).
#   <who>           the installer's name; it prefixes the error line
#   Returns 0 with the crontab; 0 with nothing printed when crontab -l fails
#   with "no crontab for <user>" (an empty crontab); 2 on ANY other failure
#   (a permission error, a broken spool, a crontab that cannot run), with
#   "<who>: could not read the current crontab (...)" and a Fix: on stderr and
#   nothing on stdout. A caller MUST stop on 2 before any write: a failed read
#   that reads as empty makes --install write back only its own line and
#   --remove write back nothing, deleting every other entry. That was
#   `crontab -l 2>/dev/null || true` in two installers.

# cron_main_checkout <script-dir> [<who>]
#   Requires scripts/lib/main-checkout.sh beside this file (sourced below).
#   Where the managed runner lives: the MAIN checkout of the git repo holding
#   <script-dir>, never a linked worktree, whose path vanishes on cleanup and
#   leaves cron firing a missing file (DND-1639). Run it in the caller's shell,
#   not in $(...): it sets two globals.
#     CRON_MAIN_CHECKOUT  the main checkout, absolute, symlinks resolved
#     CRON_IN_WORKTREE    1 when <script-dir> is in a linked worktree, else 0
#   <who> prefixes the error line (default cron_main_checkout).
#   Returns 0; 2 with a Fix: on stderr, and CRON_MAIN_CHECKOUT empty, when
#   <script-dir> is not inside a git checkout or its git dirs cannot be entered,
#   or when scripts/lib/main-checkout.sh is missing beside this file.
#   The resolver is main-checkout.sh's main_checkout, shared with the non-cron
#   tools (setup-hooks, add-athena-mcp; DND-1720); this only renames its globals.

# cron_runner_dry_run <runner>
#   Runs the managed runner's own --dry-run, the read-only check of what a tick
#   needs before it spawns a session (its skill, its MCP preflight, the
#   scripts/lib files it loads), and discards the brief it prints. An installer
#   runs it last in --check, --install and --dry-run, so a green installer
#   means the runner's own preflight passes, including checks the installer
#   does not make itself (DND-1728: the libs a tick loads).
#   Returns 0 when it exits 0. Otherwise returns 1 and sets
#     CRON_DRY_WHY  "the runner's own --dry-run refuses (exit <n>): <its reason>"
#     CRON_DRY_FIX  the runner's own Fix: line, else how to see why
#   The runner inherits the caller's environment, so the seams an installer
#   honours (LEADTIME_CLAUDE_JSON, CLUSTERING_CLAUDE_JSON) reach it too.
cron_runner_dry_run() {
  local runner="${1:-}" err rc=0
  CRON_DRY_WHY=""; CRON_DRY_FIX=""
  err="$("${runner}" --dry-run 2>&1 >/dev/null </dev/null)" || rc=$?
  [ "${rc}" -ne 0 ] || return 0
  CRON_DRY_WHY="the runner's own --dry-run refuses (${runner} --dry-run, exit ${rc}): $(printf '%s\n' "${err}" | grep -v '^[[:space:]]*Fix: ' | grep -v '^[[:space:]]*$' | tail -n1 || true)"
  CRON_DRY_FIX="$(printf '%s\n' "${err}" | sed -n 's/^[[:space:]]*Fix: //p' | tail -n1 || true)"
  [ -n "${CRON_DRY_FIX}" ] || CRON_DRY_FIX="run ${runner} --dry-run by hand to see why."
  return 1
}

_cron_entry_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -r "${_cron_entry_lib_dir}/main-checkout.sh" ]; then
  # shellcheck source=scripts/lib/main-checkout.sh
  . "${_cron_entry_lib_dir}/main-checkout.sh"
fi

cron_main_checkout() {
  local who="${2:-cron_main_checkout}" rc=0
  CRON_MAIN_CHECKOUT=""; CRON_IN_WORKTREE=0
  if ! declare -F main_checkout >/dev/null; then
    echo "${who}: ${_cron_entry_lib_dir}/main-checkout.sh is missing, so the main checkout cannot be resolved" >&2
    echo "  Fix: restore scripts/lib/main-checkout.sh (fast-forward this checkout to a main that has it), then re-run." >&2
    return 2
  fi
  main_checkout "${1:-}" "${who}" || rc=$?
  [ "${rc}" -eq 0 ] || return "${rc}"
  CRON_MAIN_CHECKOUT="${MAIN_CHECKOUT}"; CRON_IN_WORKTREE="${MAIN_CHECKOUT_IN_WORKTREE}"
  return 0
}

cron_read_crontab() {
  local who="${1:-cron_read_crontab}" cmd="${2:-crontab}" out err rc=0 msg
  err="$(mktemp)" || {
    echo "${who}: could not read the current crontab (mktemp failed, so crontab -l's error could not be captured)" >&2
    echo "  Fix: make \${TMPDIR:-/tmp} writable, then re-run. The crontab was not written." >&2
    return 2
  }
  # LC_ALL=C: "no crontab for" is matched in crontab's untranslated text.
  out="$(LC_ALL=C "${cmd}" -l 2>"${err}")" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if grep -q 'no crontab for' "${err}"; then rm -f "${err}"; return 0; fi
    msg="$(tr '\n' ' ' <"${err}")"; rm -f "${err}"
    echo "${who}: could not read the current crontab (${cmd} -l exit ${rc}: ${msg})" >&2
    echo "  Fix: make 'crontab -l' succeed for this user first (a broken spool dir: scripts/setup-shipwright-cron --install repairs it, with sudo; a permission error: check the spool dir's owner and mode against the crontab binary's group), then re-run. The crontab was not written." >&2
    return 2
  fi
  rm -f "${err}"
  [ -z "${out}" ] || printf '%s\n' "${out}"
}

cron_entry_lines() {
  local runner="${1:-}" class="${2:-}" suffix="${3:-}"
  case "${runner}" in
    *[[:space:]]*)
       echo "cron_entry_lines: runner '${runner}' contains whitespace, so it can never equal one crontab field" >&2
       echo "  Fix: install the runner under a path with no spaces or tabs." >&2
       return 2 ;;
    /*) ;;
    *) echo "cron_entry_lines: runner '${runner}' is not an absolute path" >&2
       echo "  Fix: pass the managed runner's absolute path (resolve it with pwd -P first)." >&2
       return 2 ;;
  esac
  case "${class}" in
    ours|stale|notours) ;;
    *) echo "cron_entry_lines: unknown class '${class}'" >&2
       echo "  Fix: pass one of ours, stale, notours." >&2
       return 2 ;;
  esac
  # ENVIRON, not -v: awk -v rewrites backslash escapes in the value.
  CRON_ENTRY_RUNNER="${runner}" CRON_ENTRY_SUFFIX="${suffix}" CRON_ENTRY_CLASS="${class}" \
  awk '
    BEGIN { r = ENVIRON["CRON_ENTRY_RUNNER"]; s = ENVIRON["CRON_ENTRY_SUFFIX"]; want = ENVIRON["CRON_ENTRY_CLASS"] }
    {
      cls = "other"
      if ($0 !~ /^[[:space:]]*#/) {
        for (i = 1; i <= NF; i++) {
          if ($i == r) { cls = "ours"; break }
          if (s != "" && length($i) >= length(s) && substr($i, length($i) - length(s) + 1) == s) cls = "stale"
        }
      }
      if (cls == want || (want == "notours" && cls != "ours")) print
    }'
}
