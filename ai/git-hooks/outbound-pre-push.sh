#!/usr/bin/env bash
# outbound-pre-push.sh -- the `pre-push` hook for the PUBLIC ~/dev/custom repo
# (DND-699). git runs it with <remote-name> <remote-url> as arguments and the
# pushed refs on stdin; it runs the MAIN CHECKOUT's ai/bin/outbound-scan, which
# refuses a push that carries a work-domain value.
#
# Installed by `scripts/setup-private-overlay --install` (DND-703; never by
# hand from a worktree) as a wrapper at the main checkout's .git/hooks/pre-push
# that execs this script. That one file serves every linked worktree and
# shipwright lane, because hooks live in the common git dir. It runs the
# scanner that LANDED in the main checkout, never a worktree's copy, so a
# branch cannot weaken the scan that judges its own push.
#
# A new ref's range is everything the destination does not already have,
# from the destination's own ref listing (DND-2086): the file the route's
# transport passes as a third argument, else `ai/bin/forge-git ... ls-remote <url>` in the
# scanner. Inside a route push (URL athena-forge::...) the scanner leaves a
# new ref to the transport, which holds the listing.
#
# Fails closed: a scanner it cannot find or run refuses the push (exit 3,
# COULD NOT MEASURE). An installed hook marks this machine as one that must
# measure, so an absent overlay refuses the push too.
#
# Residuals, stated (contract -> Outbound-scan interface): a push outside the
# Athena route that skips this hook (`--no-verify`, a core.hooksPath override;
# a routed push is scanned again by the route's transport, ai/lib/forge-push-scan,
# DND-2023), ATHENA_OUTBOUND_WAIVE=<reason> (printed and logged), editing the
# main checkout's scanner, a local commit that lowers the overlay's pattern
# floor, and a value no pattern describes. Each raises the cost or leaves a
# trace; none is impossible.

case "${1:-}" in
  -h | --help)
    printf '%s\n' "outbound-pre-push.sh <remote-name> <remote-url> [<listing-file>]   (git runs it; ref lines on stdin)" \
      "  <listing-file> is passed only by the route's transport: the destination's refs it read (DND-2086)." \
      "  The pre-push hook for the public ~/dev/custom repo (DND-699). It runs the MAIN" \
      "  checkout's ai/bin/outbound-scan --pre-push and refuses a push carrying a" \
      "  work-domain value, or one it could not measure. Not run by hand. Installed" \
      "  at the main checkout's .git/hooks/pre-push by scripts/setup-private-overlay --install." \
      "  Contract: ai/contracts/athena-private-overlay.md -> Outbound-scan interface."
    exit 0 ;;
esac

refuse() {
  printf 'outbound-pre-push: COULD NOT MEASURE: %s. The push is refused. Fix: %s\n' "$1" "$2" >&2
  cat >/dev/null
  exit 3
}

[ -n "${1:-}" ] || refuse "git passed no remote name" "run this only as git's pre-push hook (git push invokes it with <remote> <url>)."

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || refuse "git could not resolve the repository's common dir" "push from inside the repository, or report the git error."
[ "$(basename "$common")" = ".git" ] \
  || refuse "the common git dir ${common} is not a main checkout's .git" "this hook serves a non-bare checkout; install it only in ~/dev/custom's main checkout."
main="$(dirname "$common")"
scanner="${main}/ai/bin/outbound-scan"
[ -x "$scanner" ] \
  || refuse "the main checkout's scanner ${scanner} is missing or not executable" "fast-forward the main checkout (git -C ${main} merge --ff-only origin/main) so the landed scanner exists, then push again."

# A third argument is the destination's ref listing that the route's
# transport read (ai/lib/forge-push-scan, DND-2086). git passes a hook two
# arguments, so only the transport supplies it.
if [ -n "${3:-}" ]; then
  exec "$scanner" --pre-push --remote "$1" --url "${2:-$1}" --advertised "$3"
fi
exec "$scanner" --pre-push --remote "$1" --url "${2:-$1}"
