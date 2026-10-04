# shellcheck shell=bash
#
# gh-outbound-scan.sh — the outbound scan behind `gh-athena` writes that carry
# free text (DND-699, DND-1976, DND-2007). Sourced by ai/bin/gh-athena, never
# run. The GitLab counterpart is ai/lib/glab-outbound-scan.sh (DND-1938); both
# apply ONE set of rules, ai/lib/outbound-text-scan.sh.
#
# The second publish path. A pre-push hook covers what reaches a public repo
# through git; a PR, issue, comment, release or any `gh api` write reaches it
# through the API.
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
#   api, any write            every -f/-F field (inline text, an @file, or @-
#                             for stdin), the --input body (a file or `-`),
#                             and a ?query on the endpoint (DND-2007). A write
#                             is any method but GET/HEAD (gh defaults to POST
#                             when fields or --input are given), or one a
#                             method-override header or a `_method` field
#                             could turn into a write. `api` must be the first
#                             word; anything else is REFUSED.
#
# An `api` argv is read with gh's api flag table (FAS_GH_API_* in
# ai/lib/forge-api-scan.sh, the one the merge guard reads) and the shared
# collector (ots_api_collect). A flag the table lacks, an endpoint that cannot
# be normalized or does not spell its repository plainly (a ., .. or empty
# segment, or an escaped / in repos/<owner>/<repo>), or a GraphQL call whose
# query cannot be read is REFUSED (exit 3, Fix:): an api write the scan cannot
# classify never passes. Its targets are
# gos_api_target's: repos/<owner>/<repo>/… names <owner>/<repo>, and
# repos/{owner}/{repo}/… (or :owner/:repo) names GH_REPO, else the current
# directory's repo, as gh fills them. A GraphQL mutation (its target is inside
# the query) and any other endpoint (repositories/<id>, gists, user, orgs, a
# full URL on another host) name no target this guard resolves, and are
# scanned as PUBLIC. A GraphQL query with no mutation is a read.
#
# The argv is read the way gh reads it (DND-1976): with a table of every flag
# of each command above and whether it takes a value, built from gh's own
# --help and pinned to one gh version (ai/lib/gh-flag-table.sh, generated and
# checked by ai/bin/cli-flag-table). Every spelling pflag accepts is read, and
# every occurrence is scanned: `--title X`, `--title=X`, `-t X`, `-tX`, `-t=X`,
# and clusters (`-dbX`, `-dF <file>`). A flag the table does not have is
# REFUSED (gh would reject it too, or the table is stale). A value given as its
# own word that names one of the command's file or repo flags
# (`--label -F <file>`) is REFUSED, and every positional is scanned when the
# command carries text or such a value names a text flag (`--label -b X`: X is
# the body if the table has drifted) (the two rules in
# ai/lib/outbound-text-scan.sh). Before the command path only -R/--repo is
# read, as cobra reads it (`gh -R X pr create`, `gh pr -R X create`), and a
# help flag passes (cobra shows the help and runs nothing); any other flag
# there is REFUSED, because cobra still finds the command past it. Every file, stdin included, is copied once
# into a private file, scanned, and handed to gh in its place.
#
# The TARGET repository is every repository the write could reach: each
# non-empty -R/--repo value, the owner/repo of every PR or issue URL given
# positionally (gh acts on the URL's repo, whatever the current directory is),
# and the repository gh falls back to when the last -R is empty or absent:
# GH_REPO, else the current directory's repo (not added beside a URL). An empty
# -R is not a target: gh then uses GH_REPO (DND-2006; the resolution and its
# measurement are in ai/lib/gh-target-repo.sh). A non-empty -R, or the GH_REPO
# gh falls back to, that is not in a form gh reads is REFUSED (exit 3, COULD
# NOT LOOK). The text
# is scanned unless EVERY target reads PRIVATE or INTERNAL; a target whose
# visibility cannot be read, or a URL it cannot parse, counts as PUBLIC.
# Visibility: `gh repo view [<repo>] --json visibility`, as the App.
#
# This runs after the merge guard (ai/bin/gh-athena, DND-2007), so it reads
# nothing before the guard decides (the guard's api refusals stay read-free),
# and the guard reads no stdin before the copy.
#
# Residuals, stated: a field or --input FILE that changes between the merge
# guard's read of a GraphQL query and this scan's copy of it (gh sends the
# copy, which the guard did not read), `pr create --fill` (the body is commit messages, which the pre-push hook
# scans), `--generate-notes` and `--notes-from-tag` (text GitHub or the tag
# supplies), an interactive editor or --web, the CONTENT of release asset
# files, names that are not free text but reach the public repository (labels,
# milestones, projects, issue types: gh refuses a name that does not exist), a
# gh whose flags differ from the pinned table (`ai/bin/cli-flag-table --cli gh
# --check` names the drift only where gh is the pinned version; its self-test
# fails where the table differs from origin/main's and cannot be compared), a
# value no pattern describes, and the waiver. The scanner run is the one beside
# the gh-athena invoked, so a worktree's gh-athena runs that branch's scanner
# (the pre-push hook avoids this by running the main checkout's).
#
# Test seam: none of its own. ai/test/gh-athena-outbound/self-test.sh drives the
# real wrapper with a stub gh on PATH that records every call.

GOS_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=outbound-text-scan.sh
. "$GOS_LIB_DIR/outbound-text-scan.sh"
OTS_TOOL=gh-athena OTS_DEST=repository
# The gh api flag table and argv parser (DND-2007). A failed load fails the
# source, which ai/bin/gh-athena refuses.
# shellcheck source=forge-api-scan.sh
. "$GOS_LIB_DIR/forge-api-scan.sh" || return 1
# The pinned flag table. A table that is missing or does not define its arrays
# refuses every judged write (below, in gos_guard) rather than reading argv
# without it.
GOS_TABLE_OK=""
# shellcheck source=gh-target-repo.sh
. "$GOS_LIB_DIR/gh-target-repo.sh"
# shellcheck source=gh-flag-table.sh
if . "$GOS_LIB_DIR/gh-flag-table.sh" 2>/dev/null && declare -p GFT_FLAGS GFT_ALIAS >/dev/null 2>&1; then
  GOS_TABLE_OK=1
fi

# gos_positional <word> : a positional that is a URL adds its repository to the
# caller's `targets` (dynamic scope). github.com URLs become OWNER/REPO; another
# host becomes HOST/OWNER/REPO; a URL without an owner and repo becomes
# "?:<why>" (unknown, scanned as PUBLIC).
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
    targets+=("?:a positional URL names a repository this guard cannot parse")
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

# gos_guarded_group <word> : true for a command group this scan judges.
gos_guarded_group() { case "$1" in pr | issue | release) return 0 ;; esac; return 1; }

# gos_shown <endpoint> : the endpoint without its ?query or #fragment, for a
# message (a query can carry the very value the scan refuses to print).
gos_shown() { printf '%s' "${1%%[?#]*}"; }

# gos_api_target <endpoint> : adds the repository an api write to <endpoint>
# reaches to the caller's `targets`, or nothing for a GraphQL read (a query
# with no mutation). Exits 3 when the endpoint cannot be read.
#   repos/<owner>/<repo>[/…]     <owner>/<repo> (HOST/<owner>/<repo> under a
#                                --hostname other than github.com)
#   repos/{owner}/{repo}[/…]     gh fills both from GH_REPO, else from the
#   (or :owner, :repo)           current directory's repo: so GH_REPO, else ""
#   graphql, with a mutation     unknown: the target is inside the query
#   anything else                unknown (repositories/<id>, gists, user, orgs,
#                                a placeholder mixed with text, a full URL on
#                                another host)
# An unknown target is scanned as PUBLIC, said on stderr.
gos_api_target() {
  local ep="$1" shown path lower host="" o rp sc hosted=""
  local -a s=()
  shown="$(gos_shown "$ep")"
  if ! path="$(fas_path "$ep" api v3)"; then
    ots_refuse 3 "the endpoint '$shown' cannot be normalized (a backslash, a control character, or a malformed or nested %-escape), so the outbound scan cannot tell which repository it writes to. Fix: spell the endpoint plainly (repos/<owner>/<repo>/…)."
  fi
  lower="${path,,}"
  # gh sends ONLY the bare endpoint `graphql` to the GraphQL API.
  if [ "$lower" = graphql ]; then
    if fas_graphql_scan mutation; then sc=0; else sc=$?; fi
    case "$sc" in
      0) targets+=("?:a GraphQL mutation names its target inside the query") ;;
      1) ;;
      *) ots_refuse 3 "the outbound scan cannot tell whether this GraphQL call writes: $FAS_WHY. Fix: $FAS_HOW." ;;
    esac
    return 0
  fi
  case "$ep" in
    http://* | https://*) host="${ep#*://}"; host="${host%%/*}"; host="${host,,}" ;;
  esac
  case "$host" in
    "" | api.github.com | github.com | www.github.com) ;;
    *) targets+=("?:the endpoint '$shown' is on the host '$host', which this guard does not resolve"); return 0 ;;
  esac
  if [ -n "$FAS_HOSTNAME" ] && [ "${FAS_HOSTNAME,,}" != github.com ]; then hosted="$FAS_HOSTNAME/"; fi
  IFS=/ read -ra s <<<"$path"
  if [ "${#s[@]}" -lt 3 ] || [ "${s[0],,}" != repos ]; then
    targets+=("?:the endpoint '$shown' names no repository (repos/<owner>/<repo>/…)"); return 0
  fi
  o="${s[1]}" rp="${s[2]}"
  gos_api_spelled "$ep" "${s[0]}/$o/$rp" \
    || ots_refuse 3 "the endpoint '$shown' does not route to the repository it spells (a ., .. or empty segment, or an escaped /), so the outbound scan cannot tell which repository it writes to. Fix: spell the endpoint plainly (repos/<owner>/<repo>/…)."
  case "$o:$rp" in
    "{owner}:{repo}" | ":owner::repo") targets+=("${GH_REPO:-}"); return 0 ;;
  esac
  if [[ "$o$rp" == *[{}]* ]] || [[ "$o" == :* ]] || [[ "$rp" == :* ]]; then
    targets+=("?:the endpoint '$shown' mixes a placeholder into the repository name"); return 0
  fi
  targets+=("$hosted$o/$rp")
  return 0
}

# gos_api_spelled <endpoint> <normalized repos/<owner>/<repo>> : true when the
# endpoint's own first three path segments (after any scheme and host, and a
# leading api/ and v3/), each %-decoded on its own, are exactly that prefix.
# fas_path applies `.` and `..` and decodes an escaped `/`; neither gh nor
# GitHub need agree, so a prefix reached that way is not trusted.
gos_api_spelled() {
  local r="${1%%[?#]*}" want="$2" seg dec n=0 got=""
  local -a raw=()
  if [[ "$r" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*(.*)$ ]]; then r="${BASH_REMATCH[1]}"; fi
  r="${r#/}"
  IFS=/ read -ra raw <<<"$r"
  if [ "${#raw[@]}" -gt 0 ] && [ "${raw[0],,}" = api ]; then raw=("${raw[@]:1}"); fi
  if [ "${#raw[@]}" -gt 0 ] && [ "${raw[0],,}" = v3 ]; then raw=("${raw[@]:1}"); fi
  for seg in "${raw[@]}"; do
    [ "$n" -lt 3 ] || break
    case "$seg" in "" | . | ..) return 1 ;; esac
    dec="$(fas_path "$seg")" || return 1
    case "$dec" in "" | */*) return 1 ;; esac
    got+="${got:+/}$dec"; n=$((n + 1))
  done
  [ "$got" = "$want" ]
}

# gos_api <args after the word api...> : fills the caller's text and file
# arrays and `targets` for an api write; returns 0 with nothing collected for
# a read. Exits 3 on an argv it cannot read.
gos_api() {
  local ep
  FAS_API_VALUED="$FAS_GH_API_VALUED" FAS_API_BOOL="$FAS_GH_API_BOOL"
  FAS_API_SVALUED="$FAS_GH_API_SVALUED" FAS_API_SBOOL="$FAS_GH_API_SBOOL"
  if ! fas_parse_api "$@"; then
    ots_refuse 3 "'$FAS_UNKNOWN' is not a \`gh api\` flag the outbound scan knows, so it cannot tell which text this call sends. Fix: drop the flag (gh rejects an unknown flag anyway)."
  fi
  # What a write is, which fields it sends, and the GraphQL copy step are
  # shared with glab-athena (ai/lib/outbound-text-scan.sh, DND-1976).
  ots_api_collect GOS_ARGV 1 api v3 || return 0
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0
  if [ "${#FAS_POS[@]}" = 0 ]; then
    targets+=("?:the call names no endpoint")
  fi
  for ep in "${FAS_POS[@]}"; do gos_api_target "$ep"; done
  return 0
}

# gos_guard <gh argv...> : sets GOS_ARGV to the argv gh must run (a file or
# stdin value replaced by its scanned private copy). Returns 0, or exits 1
# (HITS) or 3 (cannot judge).
gos_guard() {
  GOS_ARGV=("$@")
  OTS_WHAT="gh command"
  local -a argv=("$@") path=() texts=() tlab=() fsrc=() fidx=() fpre=() flab=() fnoun=() fflag=() targets=()
  local -A fbase=()
  local n=$# i=0 a v w cmd

  # An api call (DND-2007). Only as the first word: cobra's walk past a flag
  # before it can differ from this parse.
  if [ "${argv[0]:-}" = api ]; then
    OTS_WHAT="api write"
    gos_api "${argv[@]:1}"
    [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0
    [ "${#targets[@]}" -gt 0 ] || return 0
    gos_scan_targets
    return 0
  fi

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
        targets+=("$v") ;;
      --repo=*) targets+=("${a#--repo=}") ;;
      -R?*) v="${a#-R}"; targets+=("${v#=}") ;;
      # cobra answers a help flag with the help and runs nothing.
      -h | --help) return 0 ;;
      -*)
        for w in "${argv[@]}"; do
          if gos_guarded_group "$w" || [ "$w" = api ]; then
            ots_refuse 3 "'$a' comes before the command path, so the outbound scan cannot tell which command runs or which text it sends. Fix: put the command first and every flag after it (\`gh-athena pr create -t … -b …\`)."
          fi
        done
        return 0 ;;
      *)
        if [ "$a" = api ] && [ "${#path[@]}" = 0 ]; then
          ots_refuse 3 "\`api\` is not the first word, so the outbound scan cannot tell how gh parses the words before it. Fix: put \`api\` first: \`gh-athena api <endpoint> [flags]\`."
        fi
        path+=("$a")
        if [ "${#path[@]}" = 2 ]; then i=$((i + 1)); break; fi
        gos_guarded_group "$a" || return 0 ;;
    esac
    i=$((i + 1))
  done
  [ "${#path[@]}" = 2 ] || return 0
  cmd="${path[0]} ${path[1]}"
  if [ -z "$GOS_TABLE_OK" ]; then
    # Without the table an alias cannot be resolved: refuse every verb a
    # judged command or its alias could be.
    case "${path[1]}" in create | new | edit | comment | review | merge | close | reopen) ;; *) return 0 ;; esac
    ots_refuse 3 "the pinned gh flag table ($GOS_LIB_DIR/gh-flag-table.sh) is missing or does not define GFT_FLAGS and GFT_ALIAS, so the outbound scan cannot read the argv of \`gh $cmd\`. Fix: run gh-athena from a full ~/dev/custom checkout; if the file is damaged, regenerate it with \`ai/bin/cli-flag-table --cli gh --write\`."
  fi
  if [ -n "${GFT_ALIAS[$cmd]+x}" ]; then cmd="${GFT_ALIAS[$cmd]}"; fi
  gos_roles "$cmd" || return 0
  [ -n "${GFT_FLAGS[$cmd]+x}" ] || ots_refuse 3 "the pinned gh flag table has no \`$cmd\`, so the outbound scan cannot read its argv. Fix: run \`ai/bin/cli-flag-table --cli gh --write\` and commit the table."
  OTS_WHAT="$cmd"

  if ! ots_pflag_parse strict "${GFT_FLAGS[$cmd]}" "$i" "${argv[@]:$i}"; then
    ots_refuse 3 "'$OTS_UNKNOWN' is not a flag of \`gh $cmd\` in the pinned table (gh $GFT_VERSION), so the outbound scan cannot tell which words gh reads as text. Fix: drop or correct the flag; if this gh has it, run \`ai/bin/cli-flag-table --cli gh --write\` and commit the table."
  fi
  [ -z "$OTS_HELP" ] || return 0
  # Rule 2 of ai/lib/outbound-text-scan.sh, and the sort into text, files and
  # targets.
  ots_collect "${GFT_FLAGS[$cmd]}" "$GOS_TEXT" "$GOS_FILE" " repo "
  # At this point `targets` holds every -R/--repo value in argv order, empty ones
  # included; gtr_resolve (below) turns them into repositories.
  local -a rvals=("${targets[@]}")
  targets=()
  if [ -z "$GOS_POS" ]; then
    for w in "${OTS_PO[@]}"; do gos_positional "$w"; done
  fi
  if [ -n "$GOS_POS" ] || [ -n "$OTS_POS_TEXT" ] || [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ]; then
    for w in "${OTS_PO[@]}"; do texts+=("$w"); tlab+=(argument); done
  fi
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0

  # -R, then GH_REPO, then the checkout, as gh resolves them (DND-2006).
  local has_url=0
  [ "${#targets[@]}" = 0 ] || has_url=1
  declare -F gtr_resolve >/dev/null || ots_refuse 3 "$GOS_LIB_DIR/gh-target-repo.sh did not load, so the outbound scan cannot tell which repository this $OTS_WHAT reaches. Fix: run gh-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)."
  gtr_resolve "$has_url" "${rvals[@]}" || ots_refuse 3 "$GTR_WHY"
  targets+=("${GTR_TARGETS[@]}")
  gos_scan_targets
}

# gos_scan_targets : reads the visibility of each of the caller's `targets` and
# scans the caller's collected texts and files unless EVERY target reads
# PRIVATE or INTERNAL. A target is "" (the current directory's repo), a
# repository gh can name, or "?:<why>" (unknown, scanned as PUBLIC). Exits 1
# (HITS) or 3; returns 0.
gos_scan_targets() {
  local t vis public=""
  for t in "${targets[@]}"; do
    if [[ "$t" == "?:"* ]]; then
      printf 'gh-athena: %s; scanning as PUBLIC.\n' "${t#\?:}" >&2
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
