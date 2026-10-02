# shellcheck shell=bash
# scripts/lib/main-checkout.sh — the ONE shell answer to "where is the MAIN
# checkout of the repo holding this script" (DND-1639, DND-1642, DND-1720).
#
# Every tool that writes a path into machine state must write the MAIN
# checkout's path, never a linked worktree's: a worktree path vanishes on
# cleanup, and whatever names it (a crontab line, a settings.json hook, an MCP
# headersHelper) then fires a missing file with no error. The cron installers
# (through cron_main_checkout in cron-entry.sh), scripts/setup-hooks and
# scripts/add-athena-mcp all resolve it here.
#
# main_checkout <script-dir> [<who>]
#   Run it in the caller's shell, not in $(...): it sets two globals.
#     MAIN_CHECKOUT              the main checkout, absolute, symlinks resolved
#     MAIN_CHECKOUT_IN_WORKTREE  1 when <script-dir> is in a linked worktree, else 0
#   <who> prefixes the error line (default main_checkout).
#   Returns 0; 2 with a Fix: on stderr, and MAIN_CHECKOUT empty, when
#   <script-dir> is not inside a git checkout or its git dirs cannot be entered.
#   A resolution failure is never answered with a fallback directory: the
#   caller's own directory is exactly the worktree path this exists to avoid.

main_checkout() {
  local dir="${1:-}" who="${2:-main_checkout}" common gitdir
  MAIN_CHECKOUT=""; MAIN_CHECKOUT_IN_WORKTREE=0
  common="$(git -C "${dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  gitdir="$(git -C "${dir}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  case "${common}|${gitdir}" in
    /*\|/*) ;;
    *) echo "${who}: '${dir}' is not inside a git checkout (git common dir '${common}', git dir '${gitdir}')" >&2
       echo "  Fix: run the copy in the main checkout's scripts/ (e.g. ~/dev/custom/scripts/)." >&2
       return 2 ;;
  esac
  common="$(cd -- "${common}" && pwd -P)" && gitdir="$(cd -- "${gitdir}" && pwd -P)" || {
    echo "${who}: cannot enter the git dirs of '${dir}' (common '${common}', git dir '${gitdir}')" >&2
    echo "  Fix: run the copy in the main checkout's scripts/ (e.g. ~/dev/custom/scripts/)." >&2
    return 2
  }
  MAIN_CHECKOUT="$(dirname -- "${common}")"
  [ "${gitdir}" = "${common}" ] || MAIN_CHECKOUT_IN_WORKTREE=1
  return 0
}
