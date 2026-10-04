# shellcheck shell=bash
#
# glab-outbound-scan.sh — the outbound scan behind glab-athena writes that
# carry free text (DND-1938). Sourced by ai/bin/glab-athena, never run. The
# GitHub counterpart is ai/lib/gh-outbound-scan.sh (DND-699); both apply ONE
# set of rules, ai/lib/outbound-text-scan.sh.
#
# A pre-push hook covers what reaches a public project through git; an MR,
# issue, note or release reaches it through the API. Before glab runs one of
# these against a project that reads PUBLIC or INTERNAL, every text field is
# scanned with `ai/bin/outbound-scan --text`:
#
#   mr create|new, mr update      --title/-t, --description/-d
#   issue create|new, issue update  the same
#   mr note|comment, issue note|comment, incident note|comment  --message/-m
#   mr merge|accept               --message/-m, --squash-message (a merge or
#                                 squash commit is made server-side on the
#                                 public default branch, where no pre-push hook
#                                 runs)
#   release create                --name/-n, --notes/-N, --tag-message/-T,
#                                 --assets-links/-a, and --notes-file/-F (a
#                                 file, or `-` for stdin)
#   api, any write                every -f/-F/--form field (inline text, an
#                                 @file, or @- for stdin), the --input body (a
#                                 file or `-`), and a ?query on the endpoint.
#                                 A write is any method but GET/HEAD (glab
#                                 defaults to POST when fields or --input are
#                                 given), or one a method-override header or a
#                                 `_method` field could turn into a write.
#
# Every spelling pflag accepts is read, and every occurrence is scanned:
# `--title X`, `--title=X`, `-t X`, `-tX`, `-t=X`. A single-dash cluster that
# carries a text letter (or R) after its first letter (`-yd X`) is REFUSED with
# a Fix rather than guessed at. This parse does not know every valued flag of
# every command (`-l` label, `-a` assignee), and pflag gives such a flag the
# next word even when it starts with `-`: `-l -t -d X` is label `-t`,
# description X to glab, while this parse reads `-d` as the title. So when a
# command carries any text flag, every word this parse reads as positional is
# scanned too: X is scanned either way. Text is not the only thing such a flag
# can hand on: `release create v1 --ref -n -F <file>` is notes `-F` to this
# parse, and notes read from <file> to glab (--ref takes -n). So after a flag
# this parse does not know, a value given as its own word that names a file or
# repo flag (-F, --notes-file, -R, --repo, --target-project) is REFUSED with a
# Fix (DND-1976; both rules are ai/lib/outbound-text-scan.sh's, shared with
# gh-athena, which reads gh's argv with a pinned flag table instead). This
# parse keeps no pinned glab table: glab's help names no value types, and its
# flags differ across the glab versions in use (`--target-project` is not in
# glab 1.92), so a pinned table would refuse a flag one machine has. A
# file or stdin is copied once into a private file, scanned, and handed to glab
# in its place.
#
# The TARGET is every project the write can reach: each -R/--repo value
# (before or after the command path; OWNER/REPO, GROUP/NS/REPO, a full URL or a
# git URL), `mr create --target-project`, the project of every MR or issue URL
# given positionally, and the project glab resolves for the current directory
# (`projects/:id`) when none of these names one. An -R that follows a flag this
# parse does not know may be that flag's value rather than a repository, so the
# directory's project is read too. For `api`, the project or group the
# endpoint's second segment names (`projects/<ref>/…`, `groups/<ref>/…`, read
# verbatim, so `:id` resolves as glab resolves it), and a `target_project_id`
# field.
#
# Visibility is read from the API as Athena (this runs after the wrapper's
# isolation): `glab api projects/<ref>` (or groups/<ref>) -> .visibility.
#   private              not scanned, as gh-athena does not scan PRIVATE
#   public, internal     scanned. GitLab's internal is readable by any signed-in
#                        user, and anyone can sign up on gitlab.com, so the most
#                        restrictive reading is public. (gh-athena skips GitHub's
#                        INTERNAL, which is enterprise-members only.)
#   unreadable, or any   REFUSED, exit 3, COULD NOT LOOK: a failed read is never
#   other value          read as private. gh-athena scans an unreadable target
#                        as PUBLIC instead; this refusal is stricter.
#   no nameable target   scanned as PUBLIC, said on stderr: a positional URL
#                        with no /-/ path, a GraphQL mutation (its target is
#                        inside the query), or an api write outside projects/
#                        and groups/ (snippets, user, …).
# The text is scanned unless EVERY target reads private.
#
# Residuals, stated: `mr create --fill` / `--fill-commit-body` / `--signoff`
# (commit messages, which the pre-push hook scans), an interactive editor
# (`-d -`, a note with no -m) or --web, `--recover` (a title and description
# loaded from a recovery file), the CONTENT of release asset files (their paths
# are scanned as positionals), other commands (snippets, wiki, label and repo
# descriptions, release update), a value no pattern describes, and the waiver.
# The scanner run is the one beside the glab-athena invoked.
#
# Test seam: none of its own. ai/test/glab-athena-outbound/self-test.sh drives
# the real wrapper with a stub glab on PATH that records every call.

GLOS_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=outbound-text-scan.sh
. "$GLOS_LIB_DIR/outbound-text-scan.sh"
# shellcheck source=forge-api-scan.sh
. "$GLOS_LIB_DIR/forge-api-scan.sh"

GLOS_ARGV=()
GLOS_VIS=""

# Letter -> long flag name, for the text and file flags this guard reads.
glos_long_of() {
  case "$1" in
    t) echo title ;; d) echo description ;; m) echo message ;;
    n) echo name ;; N) echo notes ;; T) echo tag-message ;; F) echo notes-file ;;
    a) echo assets-links ;;
    *) echo "$1" ;;
  esac
}

# glos_shown <endpoint or URL> : the text without its ?query or #fragment, for
# a message (a query can carry the very value the scan refuses to print).
glos_shown() { printf '%s' "${1%%[?#]*}"; }

# glos_positional <word> : a positional MR or issue URL adds its project to
# the caller's `targets`; a URL with no /-/ path adds "?" (no nameable target).
glos_positional() {
  local w="$1" rest host p
  case "$w" in
    http://* | https://*) ;;
    *) return 0 ;;
  esac
  rest="${w#*://}"; host="${rest%%/*}"; p="${rest#*/}"
  if [ "$p" = "$rest" ] || [[ "$p" != */-/* ]] || [ -z "$host" ]; then
    targets+=("?:the URL '$(glos_shown "$w")' names no project this guard can parse")
  else
    targets+=("https://$host/${p%%/-/*}")
  fi
  return 0
}

# glos_read_vis <display name> <glab args...> : sets GLOS_VIS to public,
# internal or private from the read; exits 3 (COULD NOT LOOK) otherwise.
glos_read_vis() {
  local display="$1" out err rc=0 why
  shift
  err="$(mktemp 2>/dev/null)" || ots_refuse 3 "COULD NOT LOOK: no scratch file for the visibility read of $display. Fix: make \$TMPDIR (or /tmp) writable and retry."
  out="$(glab "$@" 2>"$err")" || rc=$?
  why="$(tr '\n' ' ' <"$err" | head -c 300)"; rm -f "$err"
  if [ "$rc" != 0 ]; then
    ots_refuse 3 "COULD NOT LOOK: the visibility of $display could not be read (\`glab $*\` exit $rc: ${why:-no output}), so whether this $OTS_WHAT reaches a PUBLIC project is unknown; that is not the same as private. Fix: make the project readable as Athena (the right -R <group>/<project>, a git remote glab can resolve, the network up), then retry; never send the text by another route to skip the scan."
  fi
  GLOS_VIS="$(jq -r 'if type == "object" then (.visibility // "" | tostring) else "" end' <<<"$out" 2>/dev/null)" || GLOS_VIS=""
  case "$GLOS_VIS" in
    public | internal | private) ;;
    *) ots_refuse 3 "COULD NOT LOOK: the visibility of $display read as '${GLOS_VIS:-<none>}', not public, internal or private (\`glab $*\`), so whether this $OTS_WHAT reaches a PUBLIC project is unknown. Fix: check that \`glab $*\` returns the project with its visibility as Athena, then retry; report a defect if it does and this guard still refuses." ;;
  esac
  return 0
}

# glos_target_vis <target> : sets GLOS_VIS for one target: "" (the project glab
# resolves for the current directory), "?:<why>" (unknown), "api:<host>|<path>"
# (an api project or group), or a -R/URL value.
#
# A gitlab.com host is not passed as --hostname: ai/bin/glab-athena exports
# GITLAB_HOST=gitlab.com before this runs, so the read and the write already
# go to the same host.
glos_target_vis() {
  local t="$1" host="" path="" r
  case "$t" in
    "")
      glos_read_vis "the project glab resolves for this directory (projects/:id)" api projects/:id
      return 0 ;;
    "?:"*)
      printf 'glab-athena: %s; scanning as PUBLIC.\n' "${t#\?:}" >&2
      GLOS_VIS=unknown
      return 0 ;;
    api:*)
      r="${t#api:}"; host="${r%%|*}"; path="${r#*|}"
      if [ -n "$host" ]; then glos_read_vis "$path" api --hostname "$host" "$path"; else glos_read_vis "$path" api "$path"; fi
      return 0 ;;
    http://* | https://*)
      r="${t#*://}"; host="${r%%/*}"; path="${r#*/}"; if [ "$path" = "$r" ]; then path=""; fi ;;
    ssh://*)
      r="${t#ssh://}"; host="${r%%/*}"; host="${host#*@}"; host="${host%%:*}"; path="${r#*/}"; if [ "$path" = "$r" ]; then path=""; fi ;;
    *@*:*)
      r="${t#*@}"; host="${r%%:*}"; path="${r#*:}" ;;
    *)
      path="$t" ;;
  esac
  path="${path%/}"; path="${path%%/-/*}"; path="${path%.git}"
  if ! [[ "$path" =~ ^[0-9]+$ || "$path" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*(/[A-Za-z0-9_.][A-Za-z0-9_.-]*)+$ ]]; then
    ots_refuse 3 "COULD NOT LOOK: '$(glos_shown "$t")' does not name a project this guard can read (OWNER/REPO, GROUP/NAMESPACE/REPO, a project id, a project URL or a git URL), so its visibility is unknown. Fix: pass -R <group>/<project>, then retry."
  fi
  if [ -n "$host" ] && [ "$host" != gitlab.com ]; then
    glos_read_vis "$t" api --hostname "$host" "projects/${path//\//%2F}"
  else
    glos_read_vis "$t" api "projects/${path//\//%2F}"
  fi
  return 0
}

# glos_api_target <endpoint> : adds the endpoint's target to the caller's
# `targets`, or nothing for a GraphQL read (a query with no mutation).
glos_api_target() {
  local ep="$1" shown path lower r host="" root rest ref dec want sc
  shown="$(glos_shown "$ep")"
  if ! path="$(fas_path "$ep" api v4)"; then
    ots_refuse 3 "the endpoint '$shown' cannot be normalized (a backslash, a control character, or a malformed or nested %-escape), so the outbound scan cannot tell which project it writes to. Fix: spell the endpoint plainly (projects/<id or url-encoded path>/…)."
  fi
  lower="${path,,}"
  # glab sends ONLY the bare endpoint `graphql` to the GraphQL API; any other
  # path ending in graphql (a wiki slug, a repository file) is a REST write.
  if [ "$lower" = graphql ]; then
    if fas_graphql_scan mutation; then sc=0; else sc=$?; fi
    case "$sc" in
      0) targets+=("?:a GraphQL mutation names its target inside the query") ;;
      1) ;;
      *) ots_refuse 3 "the outbound scan cannot tell whether this GraphQL call writes: $FAS_WHY. Fix: $FAS_HOW." ;;
    esac
    return 0
  fi
  r="$ep"
  case "$r" in
    http://* | https://*) r="${r#*://}"; host="${r%%/*}"; r="${r#"$host"}" ;;
  esac
  r="${r#/}"
  if [[ "${r,,}" == api/v4/* ]]; then r="${r:7}"; fi
  r="${r%%[?#]*}"
  root="${r%%/*}"; rest="${r#*/}"; ref="${rest%%/*}"
  if [ "$root" = "$r" ] || [ -z "$ref" ]; then
    targets+=("?:the endpoint '$shown' names no project or group"); return 0
  fi
  case "${root,,}" in
    projects | groups) ;;
    *) targets+=("?:the endpoint '$shown' names no project or group"); return 0 ;;
  esac
  if ! dec="$(fas_path "$ref")" || [ -z "$dec" ]; then
    ots_refuse 3 "the project segment '$ref' of the endpoint '$shown' cannot be normalized. Fix: spell the endpoint plainly (projects/<id or url-encoded path>/…)."
  fi
  want="${root,,}/${dec,,}"
  if [ "$lower" != "$want" ] && [[ "$lower" != "$want"/* ]]; then
    ots_refuse 3 "the endpoint '$shown' does not route to the project it spells ('$ref'), so the outbound scan cannot tell which project it writes to. Fix: spell the endpoint plainly, with no . or .. segments (projects/<id or url-encoded path>/…)."
  fi
  if [ -n "$FAS_HOSTNAME" ]; then host="$FAS_HOSTNAME"; fi
  if [ "$host" = gitlab.com ]; then host=""; fi
  targets+=("api:$host|${root,,}/$ref")
  return 0
}

# glos_api <offset of the first word after `api`> <args after api...> : fills
# the caller's text and file arrays and `targets` for an api write.
glos_api() {
  local off="$1" k ep host=""
  shift
  FAS_API_VALUED="$FAS_GLAB_API_VALUED" FAS_API_BOOL="$FAS_GLAB_API_BOOL"
  FAS_API_SVALUED="$FAS_GLAB_API_SVALUED" FAS_API_SBOOL="$FAS_GLAB_API_SBOOL"
  if ! fas_parse_api "$@"; then
    ots_refuse 3 "'$FAS_UNKNOWN' is not a \`glab api\` flag the outbound scan knows (glab 1.112), so it cannot tell which text this call sends. Fix: drop the flag (glab rejects an unknown flag anyway)."
  fi
  # What a write is, which fields it sends, and the GraphQL copy step are
  # shared with gh-athena (ai/lib/outbound-text-scan.sh, DND-1976).
  ots_api_collect GLOS_ARGV "$off" api v4 || return 0
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0

  for ep in "${FAS_POS[@]}"; do glos_api_target "$ep"; done
  # A merge request created in one project can target another (a fork's MR
  # into its upstream): that project is a target too.
  if [ -n "$FAS_HOSTNAME" ] && [ "$FAS_HOSTNAME" != gitlab.com ]; then host="$FAS_HOSTNAME"; fi
  for k in "${!FAS_FKEY[@]}"; do
    if [ "${FAS_FKEY[$k]}" = target_project_id ]; then
      case "${FAS_FKIND[$k]}" in
        file | formfile) targets+=("?:the target_project_id field is read from a file") ;;
        *) targets+=("api:$host|projects/${FAS_FVAL[$k]}") ;;
      esac
    fi
  done
  return 0
}

# glos_guard <glab argv...> : the entry point. Sets GLOS_ARGV to the argv glab
# must run (a file or stdin value replaced by its scanned private copy).
# Returns 0, or exits 1 (HITS) or 3 (cannot judge).
glos_guard() {
  GLOS_ARGV=("$@")
  OTS_TOOL=glab-athena OTS_DEST=project OTS_WHAT="glab command"
  local -a argv=("$@") path=() targets=() texts=() tlab=() fsrc=() fidx=() fpre=() flab=() fnoun=() fflag=() pos=()
  local -A fbase=()
  local n=$# i=0 a v c rest pre="" group="" verb="" tl="" ts="" fl="" fs="" tg="" lf
  local after_unknown="" r_ambiguous=""

  # The words before the command path. Only -R/--repo may sit there: any other
  # flag can make cobra's command walk differ from this parse (the merge
  # guard's rule, ai/lib/glab-merge-guard.sh -> glmg_prepath_flag).
  while [ "$i" -lt "$n" ]; do
    a="${argv[$i]}"
    case "$a" in
      -R | --repo) i=$((i + 1)); targets+=("${argv[$i]:-}") ;;
      --repo=*) targets+=("${a#--repo=}") ;;
      -R?*) v="${a#-R}"; targets+=("${v#=}") ;;
      -*) pre="$a"; break ;;
      *)
        path+=("$a")
        if [ "${#path[@]}" = 2 ]; then i=$((i + 1)); break; fi
        case "$a" in
          mr | issue | release | incident) ;;
          *) i=$((i + 1)); break ;;
        esac ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$pre" ]; then
    for a in "${argv[@]}"; do
      case "$a" in
        mr | issue | release | incident | api)
          ots_refuse 3 "'$pre' comes before the command path and is not -R/--repo, so the outbound scan cannot tell which command runs or which text it sends. Fix: put the command first and every flag after it (\`glab-athena mr note <iid> -m …\`)." ;;
      esac
    done
    return 0
  fi

  group="${path[0]:-}"; verb="${path[1]:-}"
  case "$group $verb" in
    "mr create" | "mr new")
      tl=" --title --description " ts="td" tg=" --target-project " ;;
    "mr update" | "issue create" | "issue new" | "issue update")
      tl=" --title --description " ts="td" ;;
    "mr note" | "mr comment" | "issue note" | "issue comment" | "incident note" | "incident comment")
      tl=" --message " ts="m" ;;
    "mr merge" | "mr accept")
      tl=" --message --squash-message " ts="m" ;;
    "release create")
      tl=" --name --notes --tag-message --assets-links " ts="nNTa" fl=" --notes-file " fs="F" ;;
    "api "*)
      if [ "$i" != 1 ]; then
        ots_refuse 3 "\`api\` is not the first word, so the outbound scan cannot tell how glab parses the flags before it. Fix: put \`api\` first: \`glab-athena api <endpoint> [flags]\`."
      fi
      OTS_WHAT="api write"
      glos_api 1 "${argv[@]:1}" ;;
    *) return 0 ;;
  esac

  if [ "$group" != api ]; then
    OTS_WHAT="$group $verb"
    # Rule 2 (ai/lib/outbound-text-scan.sh): after an unknown flag, which may
    # take the next word, a value given as its own word that names a file or
    # repo flag is refused: `release create v1 --ref -n -F <file>` is notes
    # `-F` to this parse, and to glab (--ref takes -n) notes read from <file>.
    local ft_letters="${fs}R" ft_longs="$fl$tg --repo "
    while [ "$i" -lt "$n" ]; do
      a="${argv[$i]}"
      if [ -n "$after_unknown" ] && [ "$((i + 1))" -lt "$n" ] && ots_names_flag "${argv[$((i + 1))]}" "$ft_letters" "$ft_longs"; then
        case "$a" in
          -R | --repo) ots_refuse_flag_value "$a" "${argv[$((i + 1))]}" ;;
          --*=*) ;;
          --*) if [[ "$tl$fl$tg" == *" $a "* ]]; then ots_refuse_flag_value "$a" "${argv[$((i + 1))]}"; fi ;;
          -?) if [[ "$ts$fs" == *"${a:1:1}"* ]]; then ots_refuse_flag_value "$a" "${argv[$((i + 1))]}"; fi ;;
        esac
      fi
      case "$a" in
        --)
          for a in "${argv[@]:$((i + 1))}"; do pos+=("$a"); glos_positional "$a"; done
          break ;;
        -R | --repo | -R?* | --repo=*)
          case "$a" in
            -R | --repo) i=$((i + 1)); v="${argv[$i]:-}" ;;
            --repo=*) v="${a#--repo=}" ;;
            *) v="${a#-R}"; v="${v#=}" ;;
          esac
          targets+=("$v")
          if [ -n "$after_unknown" ]; then r_ambiguous=1; fi ;;
        --*=*)
          lf="${a%%=*}"
          if [[ "$tl" == *" $lf "* ]]; then texts+=("${a#*=}"); tlab+=("${lf#--}")
          elif [[ "$fl" == *" $lf "* ]]; then fsrc+=("${a#*=}"); fidx+=("$i"); fpre+=("$lf="); flab+=("${lf#--}"); fnoun+=(notes); fflag+=("$lf")
          elif [[ "$tg" == *" $lf "* ]]; then targets+=("${a#*=}"); fi ;;
        --*)
          if [[ "$tl" == *" $a "* ]]; then i=$((i + 1)); texts+=("${argv[$i]:-}"); tlab+=("${a#--}")
          elif [[ "$fl" == *" $a "* ]]; then i=$((i + 1)); fsrc+=("${argv[$i]:-}"); fidx+=("$i"); fpre+=(""); flab+=("${a#--}"); fnoun+=(notes); fflag+=("$a")
          elif [[ "$tg" == *" $a "* ]]; then i=$((i + 1)); targets+=("${argv[$i]:-}")
          else after_unknown=1; i=$((i + 1)); continue; fi ;;
        -?)
          c="${a:1:1}"
          if [[ "$ts" == *"$c"* ]]; then i=$((i + 1)); texts+=("${argv[$i]:-}"); tlab+=("$(glos_long_of "$c")")
          elif [[ -n "$fs" && "$fs" == *"$c"* ]]; then i=$((i + 1)); fsrc+=("${argv[$i]:-}"); fidx+=("$i"); fpre+=(""); flab+=("$(glos_long_of "$c")"); fnoun+=(notes); fflag+=("-$c")
          else after_unknown=1; i=$((i + 1)); continue; fi ;;
        -?*)
          c="${a:1:1}"; rest="${a:2}"
          if [[ "$ts" == *"$c"* ]]; then texts+=("${rest#=}"); tlab+=("$(glos_long_of "$c")")
          elif [[ -n "$fs" && "$fs" == *"$c"* ]]; then
            v="-$c"; if [[ "$rest" == =* ]]; then v="$v="; fi
            fsrc+=("${rest#=}"); fidx+=("$i"); fpre+=("$v"); flab+=("$(glos_long_of "$c")"); fnoun+=(notes); fflag+=("-$c")
          elif [[ "$rest" == *["${ts}${fs}R"]* ]]; then
            ots_refuse 3 "the short-flag cluster \`${a:0:2}…\` in this $OTS_WHAT may carry a text field or a repo the outbound scan cannot separate. Fix: write each short flag as its own word (\`-y -d <text>\`), or use the long flags (--title, --description, --message, --repo)."
          fi ;;
        *) pos+=("$a"); glos_positional "$a" ;;
      esac
      after_unknown=""
      i=$((i + 1))
    done
    # A positional may be text a valued flag this parse does not know handed
    # on (see the header); scan them whenever the command carries text.
    if [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ]; then
      for a in "${pos[@]}"; do texts+=("$a"); tlab+=(argument); done
    fi
  fi
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0
  if [ "$group" != api ]; then
    if [ "${#targets[@]}" = 0 ] || [ -n "$r_ambiguous" ]; then targets+=(""); fi
  fi
  [ "${#targets[@]}" -gt 0 ] || return 0

  local t public=""
  for t in "${targets[@]}"; do
    glos_target_vis "$t"
    if [ "$GLOS_VIS" != private ]; then public=1; fi
  done
  [ -n "$public" ] || return 0
  ots_scan_all GLOS_ARGV
}
