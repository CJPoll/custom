# shellcheck shell=bash
# scripts/lib/main-checkout.sh — the ONE shell answer to "where is the MAIN
# checkout of the repo holding this script" (DND-1639, DND-1642, DND-1720).
#
# Every tool that writes a path into machine state must write the MAIN
# checkout's path, never a linked worktree's: a worktree path vanishes on
# cleanup, and whatever names it (a crontab line, a settings.json hook, an MCP
# headersHelper) then fires a missing file with no error. The cron installers
# (through cron_main_checkout in cron-entry.sh), scripts/setup-hooks,
# scripts/add-athena-mcp, the lead-time and clustering cron runners and
# ai/bin/slack-roots-tick (DND-1722) all resolve it here.
#
# main_checkout <script-dir> [<who>]
#   Run it in the caller's shell, not in $(...): it sets two globals.
#     MAIN_CHECKOUT              the main checkout, absolute, symlinks resolved
#     MAIN_CHECKOUT_IN_WORKTREE  1 when <script-dir> is in a linked worktree, else 0
#   <who> prefixes the error line (default main_checkout).
#   Returns 0; 2 with a Fix: on stderr, and MAIN_CHECKOUT empty, when
#   <script-dir> is not inside a git checkout, its git dirs cannot be entered,
#   or its common dir is not <checkout>/.git (a --separate-git-dir repo).
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
  # The main checkout is the common dir's parent only when the common dir IS
  # <checkout>/.git. A --separate-git-dir repo's parent is somewhere else
  # entirely: a well-formed wrong key, so it is refused, never used.
  case "${common}" in
    */.git) ;;
    *) echo "${who}: the git common dir of '${dir}' is '${common}', not <checkout>/.git, so its main checkout cannot be derived from it" >&2
       echo "  Fix: run the copy in a main checkout whose git dir is its own .git (e.g. ~/dev/custom/scripts/)." >&2
       return 2 ;;
  esac
  MAIN_CHECKOUT="$(dirname -- "${common}")"
  [ "${gitdir}" = "${common}" ] || MAIN_CHECKOUT_IN_WORKTREE=1
  return 0
}
