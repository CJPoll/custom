# shellcheck shell=bash
#
# gh-outbound-scan.sh — the outbound scan behind `gh-athena` PR and issue
# writes (DND-699). Sourced by ai/bin/gh-athena, never run.
#
# The second publish path. A pre-push hook covers what reaches a public repo
# through git; a PR or issue title and body reach it through the API. Before gh
# runs one of these writes against a PUBLIC repository:
#
#   pr create | pr edit | pr comment | pr review | pr merge | pr close | pr reopen
#   issue create | issue edit | issue comment | issue close | issue reopen
#
# (`pr merge` because a squash merge's --subject/--body become a commit on the
# public default branch, made server-side where no pre-push hook runs)
#
# the guard scans --title/--subject/-t, --body/-b, --comment/-c (close/reopen)
# and --body-file/-F (every body file, `-` included, is copied into a private
# file, scanned, and handed to gh in its place)
# with `ai/bin/outbound-scan --text`. What each scanner outcome means (CLEAN,
# WAIVED, HITS, COULD NOT MEASURE and the unmarked-machine warning, a crash)
# and how a field reaches the scanner are shared with glab-athena's scan:
# ai/lib/outbound-text-scan.sh. Only the gh argv parse and the gh visibility
# read live here.
#
# Target visibility: `gh repo view [<repo>] --json visibility`, as the App.
# PRIVATE and INTERNAL targets are not scanned. A visibility that cannot be
# read is scanned as PUBLIC (deny by default).
#
# Residuals, stated: `pr create --fill` (the body is commit messages, which the
# pre-push hook scans), an interactive editor or --web, `gh api` writes, other
# commands (release notes, gists, repo/label descriptions), an unknown flag
# whose value is a field flag's name (`-l -b -t X`: gh reads X as the title,
# this guard as positional), a value no pattern describes, and the waiver. The
# scanner run is the one beside the gh-athena invoked, so a worktree's
# gh-athena runs that branch's scanner (the pre-push hook avoids this by
# running the main checkout's).
#
# Test seam: none of its own. ai/test/gh-athena-outbound/self-test.sh drives the
# real wrapper with a stub gh on PATH that records every call.

# shellcheck source=outbound-text-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/outbound-text-scan.sh"
OTS_TOOL=gh-athena OTS_DEST=repository

# gos_positional <word> : a positional that is a URL adds its repository to the
# caller's `targets` (dynamic scope). github.com URLs become OWNER/REPO; another
# host becomes HOST/OWNER/REPO; a URL without an owner and repo becomes "?"
# (unknown, scanned as PUBLIC).
gos_positional() {
  local w="$1" rest host owner repo
  case "$w" in
    http://* | https://*) ;;
    *) return 0 ;;
  esac
  rest="${w#*://}"
  local re='^([^/]+)/([^/?#]+)/([^/?#]+)'
  if [[ "$rest" =~ $re ]]; then
    host="${BASH_REMATCH[1]}"; owner="${BASH_REMATCH[2]}"; repo="${BASH_REMATCH[3]}"
  else
    host=""; owner=""; repo=""
  fi
  if [ -z "$host" ] || [ -z "$owner" ] || [ -z "$repo" ]; then
    targets+=("?")
  elif [ "$host" = github.com ] || [ "$host" = www.github.com ]; then
    targets+=("$owner/${repo%.git}")
  else
    targets+=("$host/$owner/${repo%.git}")
  fi
}

# gos_comment_verb : true for the commands whose -c means --comment (a public
# comment posted with the close/reopen). Reads GOS_WHAT.
gos_comment_verb() {
  case "$GOS_WHAT" in
    "pr close" | "pr reopen" | "issue close" | "issue reopen") return 0 ;;
    *) return 1 ;;
  esac
}

# gos_guard <gh argv...> : sets GOS_ARGV to the argv gh must run (a `-` body
# file is replaced by the scanned private copy).
#
# Every spelling gh's flag parser accepts for the three fields is read, and
# every occurrence is scanned (not only the last): `--title X`, `--title=X`,
# `-t X`, `-tX`, and the same for --body/-b and --body-file/-F. A single-dash
# cluster that carries t, b, F or R after its first letter (`-dbX`, `-Bmain`
# with a t in it) could hide a field inside it, so it is REFUSED with a Fix
# rather than guessed at. Everything after `--` is positional.
#
# The TARGET repository is every repository the write could reach: each
# -R/--repo value, the owner/repo of every PR or issue URL given positionally
# (gh acts on the URL's repo, whatever the current directory is), GH_REPO when
# no -R is given, and the current directory's repo when none of these names
# one. The text is scanned unless EVERY target reads PRIVATE or INTERNAL; a
# target whose visibility cannot be read, or a URL it cannot parse, counts as
# PUBLIC.
gos_guard() {
  GOS_ARGV=("$@")
  local group="${1:-}" verb="${2:-}"
  case "$group $verb" in
    "pr create" | "pr edit" | "pr comment" | "pr review" | "pr merge" | "pr close" | "pr reopen" | \
      "issue create" | "issue edit" | "issue comment" | "issue close" | "issue reopen") ;;
    *) return 0 ;;
  esac
  GOS_WHAT="$group $verb" OTS_WHAT="$group $verb"

  local i=2 n=$# a have_r=""
  local -a argv=("$@") titles=() bodies=() bf_idx=() bf_pre=() bf_path=() targets=()
  while [ "$i" -lt "$n" ]; do
    a="${argv[$i]}"
    case "$a" in
      --)
        for a in "${argv[@]:$((i + 1))}"; do gos_positional "$a"; done
        break ;;
      --title=* | --subject=*) titles+=("${a#--*=}") ;;
      --subject) i=$((i + 1)); titles+=("${argv[$i]:-}") ;;
      --body=*) bodies+=("${a#--body=}") ;;
      # --comment takes text only on close/reopen; on `pr review` it is a switch.
      --comment=*) if gos_comment_verb; then bodies+=("${a#--comment=}"); fi ;;
      --comment) if gos_comment_verb; then i=$((i + 1)); bodies+=("${argv[$i]:-}"); fi ;;
      --body-file=*) bf_idx+=("$i"); bf_pre+=("--body-file="); bf_path+=("${a#--body-file=}") ;;
      --repo=*) targets+=("${a#--repo=}"); have_r=1 ;;
      -t | --title) i=$((i + 1)); titles+=("${argv[$i]:-}") ;;
      -b | --body) i=$((i + 1)); bodies+=("${argv[$i]:-}") ;;
      -F | --body-file) i=$((i + 1)); bf_idx+=("$i"); bf_pre+=(""); bf_path+=("${argv[$i]:-}") ;;
      -R | --repo) i=$((i + 1)); targets+=("${argv[$i]:-}"); have_r=1 ;;
      -t?*) titles+=("${a#-t}") ;;
      -b?*) bodies+=("${a#-b}") ;;
      -c) if gos_comment_verb; then i=$((i + 1)); bodies+=("${argv[$i]:-}"); fi ;;
      -c?*) if gos_comment_verb; then bodies+=("${a#-c}"); fi ;;
      -F?*) bf_idx+=("$i"); bf_pre+=("-F"); bf_path+=("${a#-F}") ;;
      -R?*) targets+=("${a#-R}"); have_r=1 ;;
      --*) ;;
      -?*)
        if [ "${#a}" -gt 2 ] && { [[ "${a:2}" == *[tbFR]* ]] || { gos_comment_verb && [[ "${a:2}" == *c* ]]; }; }; then
          ots_refuse 3 "the short-flag cluster \`${a:0:2}…\` in this $GOS_WHAT may carry a title, body or repo the outbound scan cannot separate. Fix: write each short flag as its own word (\`-d -b <text>\`, \`-B <branch>\`), or use the long flags (--title, --body, --body-file, --repo)."
        fi ;;
      *) gos_positional "$a" ;;
    esac
    i=$((i + 1))
  done
  [ "$((${#titles[@]} + ${#bodies[@]} + ${#bf_path[@]}))" -gt 0 ] || return 0

  if [ -z "$have_r" ] && [ -n "${GH_REPO:-}" ]; then targets+=("$GH_REPO"); fi
  [ "${#targets[@]}" -gt 0 ] || targets=("")
  local t vis public=""
  for t in "${targets[@]}"; do
    if [ "$t" = "?" ]; then
      printf 'gh-athena: a positional URL names a repository this guard cannot parse; scanning as PUBLIC.\n' >&2
      public=1; continue
    fi
    if [ -n "$t" ]; then
      vis="$(gh repo view "$t" --json visibility --jq .visibility 2>/dev/null)" || vis=""
    else
      vis="$(gh repo view --json visibility --jq .visibility 2>/dev/null)" || vis=""
    fi
    case "$vis" in
      PRIVATE | INTERNAL) ;;
      PUBLIC) public=1 ;;
      *) printf 'gh-athena: the visibility of %s could not be read; scanning as PUBLIC.\n' "${t:-the current directory repository}" >&2; public=1 ;;
    esac
  done
  [ -n "$public" ] || return 0

  local k
  for k in "${!titles[@]}"; do ots_scan_text title title "title-$k" "${titles[$k]}"; done
  for k in "${!bodies[@]}"; do ots_scan_text body body "body-$k" "${bodies[$k]}"; done
  for k in "${!bf_path[@]}"; do
    ots_copy_scan body-file body --body-file "body-file-$k" "${bf_path[$k]}"
    GOS_ARGV[${bf_idx[$k]}]="${bf_pre[$k]}$OTS_COPY"
  done
  return 0
}
