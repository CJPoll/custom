# shellcheck shell=bash
# scripts/lib/cron-entry.sh — the ONE answer to "which crontab lines are ours"
# (DND-1503) and the ONE crontab reader (DND-1638) for the cron installers:
# setup-shipwright-cron, setup-clustering-cron, setup-leadtime-cron and
# setup-athena-inbox-client.
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

cron_read_crontab() {
  local who="${1:-cron_read_crontab}" cmd="${2:-crontab}" out err rc=0 msg
  err="$(mktemp)" || {
    echo "${who}: could not read the current crontab (mktemp failed, so crontab -l's error could not be captured)" >&2
    echo "  Fix: make \${TMPDIR:-/tmp} writable, then re-run. Nothing was written." >&2
    return 2
  }
  out="$("${cmd}" -l 2>"${err}")" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if grep -q 'no crontab for' "${err}"; then rm -f "${err}"; return 0; fi
    msg="$(tr '\n' ' ' <"${err}")"; rm -f "${err}"
    echo "${who}: could not read the current crontab (${cmd} -l exit ${rc}: ${msg})" >&2
    echo "  Fix: make 'crontab -l' succeed for this user first (scripts/setup-shipwright-cron repairs a broken spool dir, with sudo), then re-run. Nothing was written." >&2
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
