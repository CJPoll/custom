# shellcheck shell=bash
#
# gh-outbound-scan.sh — the outbound scan behind `gh-athena` writes that carry
# free text (DND-699, DND-1976). Sourced by ai/bin/gh-athena, never run. The
# GitLab counterpart is ai/lib/glab-outbound-scan.sh (DND-1938); both apply ONE
# set of rules, ai/lib/outbound-text-scan.sh.
#
# The second publish path. A pre-push hook covers what reaches a public repo
# through git; a PR, issue, comment or release reaches it through the API.
# Before gh runs one of these against a PUBLIC repository, every text field is
# scanned with `ai/bin/outbound-scan --text`:
#
#   pr create|new             --title/-t, --body/-b, --template/-T (a name),
#                             --body-file/-F, --recover (a file)
#   pr edit, issue edit       --title/-t, --body/-b, --body-file/-F
#   pr comment, pr review, issue comment  --body/-b, --body-file/-F
#   pr merge                  --subject/-t, --body/-b, --author-email/-A,
#                             --body-file/-F (a squash or merge commit is made
#                             server-side on the public default branch, where
#                             no pre-push hook runs)
#   pr close|reopen, issue close|reopen   --comment/-c
#   issue create|new          --title/-t, --body/-b, --template/-T,
#                             --body-file/-F, --recover (a file)
#   release create|new        --title/-t, --notes/-n, --discussion-category,
#                             --notes-file/-F, and every positional (the tag,
#                             the asset paths and their #labels), even with no
#                             text flag
#   release edit              --title/-t, --notes/-n, --tag,
#                             --discussion-category, --notes-file/-F, and
#                             every positional
#
# The argv is read the way gh reads it (DND-1976): with a table of every flag
# of each command above and whether it takes a value, built from gh's own
# --help and pinned to one gh version (ai/lib/gh-flag-table.sh, generated and
# checked by ai/bin/gh-flag-table). Every spelling pflag accepts is read, and
# every occurrence is scanned: `--title X`, `--title=X`, `-t X`, `-tX`, `-t=X`,
# and clusters (`-dbX`, `-dF <file>`). A flag the table does not have is
# REFUSED (gh would reject it too, or the table is stale). A value given as its
# own word that names one of the command's file or repo flags
# (`--label -F <file>`) is REFUSED, and every positional is scanned when the
# command carries text (the two rules in ai/lib/outbound-text-scan.sh). Before
# the command path only -R/--repo is read, as cobra reads it (`gh -R X pr
# create`, `gh pr -R X create`); any other flag there is REFUSED, because cobra
# still finds the command past it. Every file, stdin included, is copied once
# into a private file, scanned, and handed to gh in its place.
#
# The TARGET repository is every repository the write could reach: each
# -R/--repo value, the owner/repo of every PR or issue URL given positionally
# (gh acts on the URL's repo, whatever the current directory is), GH_REPO when
# no -R is given, and the current directory's repo when none of these names
# one. The text is scanned unless EVERY target reads PRIVATE or INTERNAL; a
# target whose visibility cannot be read, or a URL it cannot parse, counts as
# PUBLIC. Visibility: `gh repo view [<repo>] --json visibility`, as the App.
#
# Residuals, stated: `gh api` writes (scanning them needs the scan to run after
# the merge guard, as glab-athena's does, which is a change to ai/bin/gh-athena),
# `pr create --fill` (the body is commit messages, which the pre-push hook
# scans), `--generate-notes` and `--notes-from-tag` (text GitHub or the tag
# supplies), an interactive editor or --web, the CONTENT of release asset
# files, other commands (gists, repo and label descriptions, release upload), a
# gh whose flags differ from the pinned table (ai/bin/gh-flag-table --check
# names the drift; its self-test runs it where gh is the pinned version), a
# value no pattern describes, and the waiver. The scanner run is the one beside
# the gh-athena invoked, so a worktree's gh-athena runs that branch's scanner
# (the pre-push hook avoids this by running the main checkout's).
#
# Test seam: none of its own. ai/test/gh-athena-outbound/self-test.sh drives the
# real wrapper with a stub gh on PATH that records every call.

GOS_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=outbound-text-scan.sh
. "$GOS_LIB_DIR/outbound-text-scan.sh"
# shellcheck source=gh-flag-table.sh
. "$GOS_LIB_DIR/gh-flag-table.sh"
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

# gos_roles <command> : sets GOS_TEXT (" long long ") and GOS_FILE for the
# command's text and file flags, and GOS_POS=1 when its positionals are
# published text (a release's tag and asset names). Returns 1 for a command
# this scan does not judge.
gos_roles() {
  GOS_TEXT="" GOS_FILE="" GOS_POS=""
  case "$1" in
    "pr create" | "issue create") GOS_TEXT=" title body template " GOS_FILE=" body-file recover " ;;
    "pr edit" | "issue edit") GOS_TEXT=" title body " GOS_FILE=" body-file " ;;
    "pr comment" | "pr review" | "issue comment") GOS_TEXT=" body " GOS_FILE=" body-file " ;;
    "pr merge") GOS_TEXT=" subject body author-email " GOS_FILE=" body-file " ;;
    "pr close" | "pr reopen" | "issue close" | "issue reopen") GOS_TEXT=" comment " ;;
    "release create") GOS_TEXT=" title notes discussion-category " GOS_FILE=" notes-file " GOS_POS=1 ;;
    "release edit") GOS_TEXT=" title notes tag discussion-category " GOS_FILE=" notes-file " GOS_POS=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# gos_flag_letters <table> <" long long "> : sets GOS_LETTERS to the short
# letters of the named flags and GOS_LONGS to their " --long " spellings.
gos_flag_letters() {
  local e rest s l
  GOS_LETTERS="" GOS_LONGS=" "
  for e in $1; do
    rest="${e#*:}"; s="${rest%%:*}"; l="${rest#*:}"
    if [[ "$2" == *" $l "* ]]; then
      GOS_LONGS+="--$l "
      GOS_LETTERS+="$s"
    fi
  done
}

# gos_guarded_group <word> : true for a command group this scan judges.
gos_guarded_group() { case "$1" in pr | issue | release) return 0 ;; esac; return 1; }

# gos_guard <gh argv...> : sets GOS_ARGV to the argv gh must run (a file or
# stdin value replaced by its scanned private copy). Returns 0, or exits 1
# (HITS) or 3 (cannot judge).
gos_guard() {
  GOS_ARGV=("$@")
  OTS_WHAT="gh command"
  local -a argv=("$@") path=() texts=() tlab=() fsrc=() fidx=() fpre=() flab=() fnoun=() fflag=() targets=()
  local -A fbase=()
  local n=$# i=0 a v w k role cmd have_r=""

  # The command path. cobra finds `pr create` past a -R/--repo and its value
  # (`gh -R X pr create`, `gh pr -R X create`), and pflag then reads that -R
  # with the command's own flags: so a -R there is a target. Any other flag
  # before the path is refused when the argv names a judged command.
  while [ "$i" -lt "$n" ]; do
    a="${argv[$i]}"
    case "$a" in
      -R | --repo)
        i=$((i + 1)); v="${argv[$i]-}"
        if ots_flag_shaped "$v"; then OTS_WHAT="gh command"; ots_refuse_flag_value "$a" "$v"; fi
        targets+=("$v"); have_r=1 ;;
      --repo=*) targets+=("${a#--repo=}"); have_r=1 ;;
      -R?*) v="${a#-R}"; targets+=("${v#=}"); have_r=1 ;;
      -*)
        for w in "${argv[@]}"; do
          if gos_guarded_group "$w"; then
            ots_refuse 3 "'$a' comes before the command path, so the outbound scan cannot tell which command runs or which text it sends. Fix: put the command first and every flag after it (\`gh-athena pr create -t … -b …\`)."
          fi
        done
        return 0 ;;
      *)
        path+=("$a")
        if [ "${#path[@]}" = 2 ]; then i=$((i + 1)); break; fi
        gos_guarded_group "$a" || return 0 ;;
    esac
    i=$((i + 1))
  done
  [ "${#path[@]}" = 2 ] || return 0
  cmd="${path[0]} ${path[1]}"
  if [ -n "${GFT_ALIAS[$cmd]+x}" ]; then cmd="${GFT_ALIAS[$cmd]}"; fi
  gos_roles "$cmd" || return 0
  [ -n "${GFT_FLAGS[$cmd]+x}" ] || ots_refuse 3 "the pinned gh flag table has no \`$cmd\`, so the outbound scan cannot read its argv. Fix: run \`ai/bin/gh-flag-table --write\` and commit the table."
  OTS_WHAT="$cmd"

  if ! ots_pflag_parse "${GFT_FLAGS[$cmd]}" "$i" "${argv[@]:$i}"; then
    ots_refuse 3 "'$OTS_UNKNOWN' is not a flag of \`gh $cmd\` in the pinned table (gh $GFT_GH_VERSION), so the outbound scan cannot tell which words gh reads as text. Fix: drop or correct the flag; if this gh has it, run \`ai/bin/gh-flag-table --write\` and commit the table."
  fi
  [ -z "$OTS_HELP" ] || return 0
  # Rule 2: a value (its own word) naming a file or repo flag is refused.
  gos_flag_letters "${GFT_FLAGS[$cmd]}" "$GOS_FILE repo "
  local ft_letters="$GOS_LETTERS" ft_longs="$GOS_LONGS"
  for k in "${!OTS_FN[@]}"; do
    role=""
    if [[ "$GOS_TEXT" == *" ${OTS_FN[$k]} "* ]]; then role=text
    elif [[ "$GOS_FILE" == *" ${OTS_FN[$k]} "* ]]; then role=file
    elif [ "${OTS_FN[$k]}" = repo ]; then role=target; fi
    if [ "$role" != text ] && [ "${OTS_FS[$k]}" = 1 ] && ots_names_flag "${OTS_FV[$k]}" "$ft_letters" "$ft_longs"; then
      ots_refuse_flag_value "--${OTS_FN[$k]}" "${OTS_FV[$k]}"
    fi
    case "$role" in
      text) texts+=("${OTS_FV[$k]}"); tlab+=("${OTS_FN[$k]}") ;;
      file)
        fsrc+=("${OTS_FV[$k]}"); fidx+=("${OTS_FI[$k]}"); fpre+=("${OTS_FP[$k]}")
        flab+=("${OTS_FN[$k]}"); fnoun+=("${OTS_FN[$k]%-file}"); fflag+=("--${OTS_FN[$k]}") ;;
      target) targets+=("${OTS_FV[$k]}"); have_r=1 ;;
    esac
  done
  if [ -z "$GOS_POS" ]; then
    for w in "${OTS_PO[@]}"; do gos_positional "$w"; done
  fi
  if [ -n "$GOS_POS" ] || [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ]; then
    for w in "${OTS_PO[@]}"; do texts+=("$w"); tlab+=(argument); done
  fi
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0

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
  ots_scan_all GOS_ARGV
}
