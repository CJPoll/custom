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
# glab fills placeholders (:branch, :fullpath, :group, :id, :namespace, :repo,
# :user, :username) in the endpoint and in a typed -F value AFTER this scan
# (DND-2009). So an api write is REFUSED (exit 3, Fix:) when its endpoint, path
# or query, holds one anywhere but a whole project segment of :id or :fullpath
# (projects/:id/…, which the visibility read passes to glab as is, so glab
# fills it the same way), whatever the visibility: a fill can move where the
# call routes. A typed -F value holding one is REFUSED when a target is not
# PRIVATE. -f, --form and --input are never filled.
#
# The argv is read the way glab reads it (DND-1976). pflag gives a flag that
# takes a value the next word even when it starts with `-`: `-l -t -d X` is
# label `-t`, description X, and `release create v1 --ref -n -F <file>` is ref
# `-n`, notes read from <file>. So the parse carries a table of every flag of
# each command above and whether it takes a value, built from glab's own help
# and pinned to one glab version (ai/lib/glab-flag-table.sh, generated and
# checked by `ai/bin/cli-flag-table --cli glab`), and reads every spelling
# pflag accepts, clusters included (`-yd X`). glab versions in use differ
# (`--target-project` is not in glab 1.92), so a flag the table lacks is read
# as taking nothing, unless the next word reads as a flag or is `--`, or it is
# a letter with more of its word after it: then it is REFUSED, because which
# text, file or project is sent depends on the reading. This guard's own text,
# file and target flags take a value whatever the table says. A value given as
# its own word that names a file or repo flag (`--label -R <repo>`) is REFUSED,
# and every positional is scanned when the command carries text or has a flag
# the table lacks (which may be a newer text flag) (the two rules
# in ai/lib/outbound-text-scan.sh, shared with gh-athena). A file or stdin is
# copied once into a private file, scanned, and handed to glab in its place.
#
# The TARGET is every project the write can reach: each -R/--repo value
# (before or after the command path; OWNER/REPO, GROUP/NS/REPO, a full URL or a
# git URL), `mr create --target-project`, the project of every positional glab
# reads as an MR or issue reference (an http(s) URL, and for an MR a
# scheme-less `//host/…` one too; glos_positional names the forms, DND-2012),
# and the project glab resolves for the current directory
# (`projects/:id`) when none of these names one. An empty -R names no project:
# glab then reads GITLAB_REPO, but glab-athena scrubs every GITLAB_* variable,
# so the `projects/:id` read and glab's write both resolve the checkout
# (DND-2006). For `api`, the project or group the
# endpoint's second segment names (`projects/<ref>/…`, `groups/<ref>/…`, read
# verbatim, so `:id` resolves as glab resolves it), and a `target_project_id`
# field. <ref> must be spelled plainly: decoded, no empty, . or .. segment
# (DND-2009). glab sends an endpoint holding :// to that URL's own host,
# whatever the scheme's case and whatever --hostname says: only
# http(s)://gitlab.com/api/v4/… (scheme and host case-folded) names a project,
# and http(s)://gitlab.com/api/graphql is GraphQL; any other full URL is an
# unknown target. Only the bare endpoint `graphql` is GraphQL otherwise, as
# glab tests it. MR and issue URLs and -R values read their scheme and host
# without case too.
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
#   no nameable target   scanned as PUBLIC, said on stderr: a positional MR
#                        or issue reference with no /-/ path, a GraphQL mutation (its target is
#                        inside the query), an api write outside projects/
#                        and groups/ (snippets, user, …), or a full URL to a
#                        host other than gitlab.com.
# The text is scanned unless EVERY target reads private.
#
# Text glab builds itself (DND-2014). Some flags make glab write text it
# builds after this scan, from the server, the git history or a local file, so
# the scan can never see it. On a target that is not PRIVATE each is REFUSED
# (exit 3, Fix: pass the text explicitly with --title/--description), even when
# the command carries no text of its own. Read from glab 1.92.1:
#   mr create --related-issue/-i   with an empty or absent --title, the MR
#                                  title is `Resolve "<the issue's title>"`,
#                                  fetched from the server, possibly from a
#                                  PRIVATE issue in another project; with an
#                                  empty or absent --source-branch, glab creates
#                                  a branch named after that title on the
#                                  target. So it needs a non-empty --title AND
#                                  --source-branch.
#   mr create --copy-issue-labels  the related issue's labels
#   mr create, mr update --fill/-f, --fill-commit-body
#                                  commit messages and the branch name
#   mr create, issue create --recover
#                                  a title and description from glab's recovery
#                                  file, which override the flags
#   mr create --signoff            the account's name and email, from the
#                                  server (added only on the template path that
#                                  -d - or a prompt starts; refused whatever the
#                                  path, the stricter reading)
#   mr create, mr update, issue create, issue update --description/-d -
#                                  an editor's text, started from a template
#                                  file, the commit list or the current
#                                  description
# A switch is on unless its last occurrence is 0, f, F, false, FALSE or False
# (pflag's ParseBool; any other value makes glab fail, so it reads as on). A
# value is the last occurrence's, as pflag keeps it. The scan does not fetch
# that text to scan it: matching what glab would build
# (issueutils.IssueFromArg, git.Commits between remote-tracking refs, the
# recovery file's path) is a second implementation that could drift. What glab
# still adds and is not refused: `Closes #<iid>` (a number) in the description,
# and `Draft: ` before the title.
#
# Residuals, stated: an interactive prompt (a command with no -t/-d on a
# terminal, a note with no -m) or --web, the CONTENT of release asset files
# (their paths are scanned as positionals), other commands (snippets, wiki,
# label and repo descriptions, release update), names that are not free text
# (labels, milestones, branch names given with -s), the text of an api
# endpoint's PATH (only its ?query is scanned; a path segment can name a file
# or wiki page), a glab flag that changed whether it takes a value since the
# pinned version, a value no pattern describes, and the waiver. The scanner
# run is the one beside the glab-athena invoked.
#
# Test seam: none of its own. ai/test/glab-athena-outbound/self-test.sh drives
# the real wrapper with a stub glab on PATH that records every call.

GLOS_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=outbound-text-scan.sh
. "$GLOS_LIB_DIR/outbound-text-scan.sh"
# shellcheck source=forge-api-scan.sh
. "$GLOS_LIB_DIR/forge-api-scan.sh"

# The pinned flag table (DND-1976). A table that is missing or does not define
# its arrays refuses every judged write (in glos_guard) rather than reading
# argv without it.
GLOS_TABLE_OK=""
# shellcheck source=glab-flag-table.sh
if . "$GLOS_LIB_DIR/glab-flag-table.sh" 2>/dev/null && declare -p LFT_FLAGS LFT_ALIAS >/dev/null 2>&1; then
  GLOS_TABLE_OK=1
fi

GLOS_ARGV=()
GLOS_VIS=""

# glos_roles <group verb> : for a command this scan judges (or one of its
# known aliases), sets GLOS_CMD to the command's own name and GLOS_TEXT,
# GLOS_FILE, GLOS_TARGET to its text, file and target flags (" long long "),
# and GLOS_REF to how glab reads its positional as an MR or issue reference:
# mr (mrutils.MRFromArgs), issue (issueutils.IssueFromArg), or "" (no
# reference: `release create` takes a tag and asset files, and `mr create` and
# `issue create` take no positional). Returns 1 for any other command.
glos_roles() {
  GLOS_TEXT="" GLOS_FILE="" GLOS_TARGET=" repo " GLOS_REF=""
  case "$1" in
    "mr create" | "mr new") GLOS_CMD="mr create" GLOS_TEXT=" title description " GLOS_TARGET=" repo target-project " ;;
    "mr update") GLOS_CMD="mr update" GLOS_TEXT=" title description " GLOS_REF=mr ;;
    "issue create" | "issue new") GLOS_CMD="issue create" GLOS_TEXT=" title description " ;;
    "issue update") GLOS_CMD="issue update" GLOS_TEXT=" title description " GLOS_REF=issue ;;
    "mr note" | "mr comment") GLOS_CMD="mr note" GLOS_TEXT=" message " GLOS_REF=mr ;;
    "issue note" | "issue comment") GLOS_CMD="issue note" GLOS_TEXT=" message " GLOS_REF=issue ;;
    "incident note" | "incident comment") GLOS_CMD="incident note" GLOS_TEXT=" message " GLOS_REF=issue ;;
    "mr merge" | "mr accept") GLOS_CMD="mr merge" GLOS_TEXT=" message squash-message " GLOS_REF=mr ;;
    "release create") GLOS_CMD="release create" GLOS_TEXT=" name notes tag-message assets-links " GLOS_FILE=" notes-file " ;;
    *) return 1 ;;
  esac
  return 0
}

# glos_lower <text> : <text> with only the ASCII letters A-Z lower-cased. A
# scheme or host is folded with this, never with ${x,,}: in a UTF-8 locale bash
# folds U+0130 to `i`, which would read a host glab sends elsewhere (an IDNA
# name) as gitlab.com (DND-2009 review).
glos_lower() { printf '%s' "$1" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz; }

# glos_shown <endpoint or URL> : the text without its ?query or #fragment, for
# a message (a query can carry the very value the scan refuses to print).
glos_shown() { printf '%s' "${1%%[?#]*}"; }

# Letters spelled out, not a range, so no locale can widen a bracket class.
GLOS_ALPHA="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

# glos_positional <mr|issue> <word> : a positional glab reads as an MR or
# issue reference adds its project to the caller's `targets`; one whose
# project this guard cannot parse adds "?" (no nameable target, scanned as
# PUBLIC). Any other word adds nothing, and the -R or cwd project is judged.
#
# glab 1.92.1 reads the word with Go's url.Parse (cmdutils.ParseGitLabURL for
# mr, issueutils.issueMetadataFromURL for issue) and takes it as a reference
# only when glrepo.FromURL finds a host (DND-2012):
#   mr      the scheme, case-folded, is http, https or NONE, so
#           `//host/<project>/-/merge_requests/N` is a reference
#   issue   the scheme is http or https; a scheme-less word is "Invalid issue
#           format" and nothing is sent
#   both    the #fragment, then the ?query, is cut first; the host is the
#           authority after `//`, past its last @ (the userinfo). A word with
#           no host (`/<project>/-/merge_requests/N`, `https:/…`, `///…`) is
#           no reference: glab reads it as a branch name in the -R or cwd
#           project, which is judged instead.
# A word with a host whose path this guard cannot split at `/-/` adds "?".
# glab also takes `<project>/merge_requests/N` with no /-/, and writes there.
# Where glab's regex rejects the path, an MR word becomes a branch name
# holding `//` or `:`, which no git branch can be, so glab sends nothing and
# the scan is only stricter.
#
# The word is split with parameter expansion, never a regex `.`: Go does not
# check UTF-8, and in a UTF-8 locale `.` does not match a byte that is not
# UTF-8, so a regex split read such a word as no reference (DND-2012 review).
glos_positional() {
  local kind="$1" w="$2" u s scheme="" rest auth host p
  u="${w%%#*}" rest="${w%%#*}"
  # Go's getScheme: [A-Za-z][A-Za-z0-9+.-]* up to the first `:`.
  if [[ "$u" == *:* ]]; then
    s="${u%%:*}"
    case "$s" in
      [$GLOS_ALPHA]*)
        if [ -z "${s//[${GLOS_ALPHA}0123456789+.-]/}" ]; then
          # glab reads the scheme and host without case (DND-2009).
          scheme="$(glos_lower "$s")" rest="${u#*:}"
        fi ;;
    esac
  fi
  case "$kind:$scheme" in
    mr: | mr:http | mr:https | issue:http | issue:https) ;;
    *) return 0 ;;
  esac
  rest="${rest%%\?*}"
  case "$rest" in
    //*) ;;
    *) return 0 ;;
  esac
  rest="${rest#//}"; auth="${rest%%/*}"; p="${rest#"$auth"}"; p="${p#/}"
  host="$(glos_lower "${auth##*@}")"
  [ -n "$host" ] || return 0
  if [ -z "$p" ] || [[ "$p" != */-/* ]]; then
    # The userinfo may hold a credential: it is never shown.
    targets+=("?:the URL '$(glos_shown "${scheme:+$scheme:}//$host/$p")' names no project this guard can parse")
  else
    targets+=("https://$host/${p%%/-/*}")
  fi
  return 0
}

# glos_value <long> : the value of the last occurrence of --<long> (pflag keeps
# the last), or "" when it is not given. glab treats an empty value as absent.
glos_value() {
  local k v=""
  for k in "${!OTS_FN[@]}"; do
    if [ "${OTS_FN[$k]}" = "$1" ]; then v="${OTS_FV[$k]}"; fi
  done
  printf '%s' "$v"
}

# glos_authored <command> : sets GLOS_AUTHORED to the flags with which glab
# builds text itself, after this scan and never seen by it, and GLOS_AUTHORED_WHAT
# to what that text is. Empty when there are none. Read from glab 1.92.1
# (internal/commands/mr/create/mr_create.go, mr/update/mr_update.go,
# issue/create/issue_create.go; DND-2014). See "Text glab builds itself" in the
# header.
glos_authored() {
  local f
  GLOS_AUTHORED="" GLOS_AUTHORED_WHAT=""
  case "$1" in
    "mr create" | "mr update" | "issue create" | "issue update")
      if [ "$(glos_value description)" = - ]; then
        glos_authored_add "--description -" "an editor's text, started from a template, the commit list or the current description"
      fi ;;
  esac
  case "$1" in
    "mr create")
      # Both must be non-empty. With --create-source-branch and a title, glab
      # names the branch after the (scanned) title, which is safe, but this
      # still asks for -s: the stricter reading, and one rule to state.
      if [ -n "$(glos_value related-issue)" ] && { [ -z "$(glos_value title)" ] || [ -z "$(glos_value source-branch)" ]; }; then
        glos_authored_add "--related-issue without a non-empty --title and --source-branch" "the related issue's title, fetched from the server (in the MR title, and in a branch glab creates on the target)"
      fi
      for f in copy-issue-labels fill fill-commit-body recover signoff; do
        if ots_switch_on "$f"; then glos_authored_add "--$f" "$(glos_authored_text "$f")"; fi
      done ;;
    "mr update")
      for f in fill fill-commit-body; do
        if ots_switch_on "$f"; then glos_authored_add "--$f" "$(glos_authored_text "$f")"; fi
      done ;;
    "issue create")
      if ots_switch_on recover; then glos_authored_add --recover "$(glos_authored_text recover)"; fi ;;
  esac
  return 0
}

glos_authored_add() {
  GLOS_AUTHORED+="${GLOS_AUTHORED:+, }$1"
  GLOS_AUTHORED_WHAT+="${GLOS_AUTHORED_WHAT:+; }$2"
}

glos_authored_text() {
  case "$1" in
    copy-issue-labels) printf '%s' "the related issue's labels" ;;
    fill) printf '%s' "commit messages and the branch name" ;;
    fill-commit-body) printf '%s' "commit message bodies" ;;
    recover) printf '%s' "a title and description loaded from glab's recovery file" ;;
    signoff) printf '%s' "the account's name and email, fetched from the server" ;;
  esac
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
    # The scheme and host are read without case, as glab reads them (DND-2009).
    [Hh][Tt][Tt][Pp]://* | [Hh][Tt][Tt][Pp][Ss]://*)
      r="${t#*://}"; host="${r%%/*}"; path="${r#*/}"; if [ "$path" = "$r" ]; then path=""; fi ;;
    [Ss][Ss][Hh]://*)
      r="${t#*://}"; host="${r%%/*}"; host="${host#*@}"; host="${host%%:*}"; path="${r#*/}"; if [ "$path" = "$r" ]; then path=""; fi ;;
    *@*:*)
      r="${t#*@}"; host="${r%%:*}"; path="${r#*:}" ;;
    *)
      path="$t" ;;
  esac
  host="$(glos_lower "$host")"
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

# The placeholders glab fills (glab 1.92.1, internal/commands/api/api.go,
# placeholderRE): in the whole endpoint, path and query, and in a typed -F
# value; never in -f, --form or --input. A name counts when the next character
# is not [A-Za-z0-9_] (Go's \b); glab's regex has no boundary before the colon.
GLOS_PLACEHOLDERS="branch fullpath group id namespace repo user username"

# glos_has_placeholder <text> : true when glab would fill a placeholder in it.
# The letters are spelled out, not a range, so no locale can widen the class.
glos_has_placeholder() {
  local s="$1" n rest
  for n in $GLOS_PLACEHOLDERS; do
    rest="$s"
    while [[ "$rest" == *":$n"* ]]; do
      rest="${rest#*":$n"}"
      case "${rest:0:1}" in
        [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]) ;;
        *) return 0 ;;
      esac
    done
  done
  return 1
}

# glos_unescape <segment> : the segment %-decoded the way fas_path decodes it
# (up to three rounds), with no dot-segment applied. Call it only on text
# fas_path has already accepted, which rules out every escape printf would
# misread.
glos_unescape() {
  local p="$1" n
  for n in 1 2 3; do
    [[ "$p" == *%* ]] || break
    p="$(printf '%b' "${p//%/\\x}")"
  done
  printf '%s' "$p"
}

# glos_api_target <endpoint> : adds the endpoint's target to the caller's
# `targets`, or nothing for a GraphQL read (a query with no mutation), and sets
# GLOS_API_HOST to the host the request goes to ("" for gitlab.com, "?" for
# one this guard does not resolve). Exits 3 when the endpoint cannot be read.
#   graphql (exactly, as glab tests it)   GraphQL: a mutation is unknown
#   a full URL (any endpoint holding ://) glab sends it to that URL's host,
#                                         whatever the scheme's case and
#                                         whatever --hostname says. Only
#                                         http(s)://gitlab.com (scheme and host
#                                         case-folded) is resolved:
#                                         /api/graphql is GraphQL, /api/v4/… is
#                                         read below. Anything else is unknown.
#   [/][api/v4/]projects/<ref>[/…]        the project <ref>, read verbatim
#   [/][api/v4/]groups/<ref>[/…]          the group <ref>
#   anything else                         unknown
# An unknown target is scanned as PUBLIC, said on stderr. <ref> must be
# spelled plainly (DND-2009): decoded, it holds no empty, . or .. segment, and
# the endpoint, normalized, still routes under it. The endpoint holds no
# placeholder glab fills, except a whole <ref> of :id or :fullpath under
# projects/ (glab fills each as one segment, and the visibility read passes the
# same text, so glab fills it the same way): a fill can move where the call
# routes, so any other is REFUSED whatever the visibility.
glos_api_target() {
  local ep="$1" shown path lower r host="" root rest ref dec want scheme auth
  shown="$(glos_shown "$ep")"
  GLOS_API_HOST=""
  if ! path="$(fas_path "$ep" api v4)"; then
    ots_refuse 3 "the endpoint '$shown' cannot be normalized (a backslash, a control character, or a malformed or nested %-escape), so the outbound scan cannot tell which project it writes to. Fix: spell the endpoint plainly (projects/<id or url-encoded path>/…)."
  fi
  lower="${path,,}"
  r="${ep%%[?#]*}"
  glos_endpoint_placeholder "$ep"
  if [[ "$ep" == *://* ]]; then
    if ! [[ "$r" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(.*)$ ]]; then
      GLOS_API_HOST="?"
      targets+=("?:the endpoint '$shown' holds :// but is not a URL this guard can read"); return 0
    fi
    scheme="$(glos_lower "${BASH_REMATCH[1]}")" auth="$(glos_lower "${BASH_REMATCH[2]}")" r="${BASH_REMATCH[3]}"
    if { [ "$scheme" != https ] && [ "$scheme" != http ]; } || [ "$auth" != gitlab.com ]; then
      GLOS_API_HOST="?"
      targets+=("?:the endpoint '$shown' is a full URL to a host other than gitlab.com"); return 0
    fi
    if [ "$r" = /api/graphql ]; then glos_api_graphql; return 0; fi
    if [[ "$r" != /api/v4/* ]]; then
      targets+=("?:the endpoint '$shown' is a gitlab.com URL outside /api/v4/, so it names no project"); return 0
    fi
    r="${r#/api/v4/}"
  else
    if [ -n "$FAS_HOSTNAME" ] && [ "$(glos_lower "$FAS_HOSTNAME")" != gitlab.com ]; then host="$FAS_HOSTNAME"; fi
    GLOS_API_HOST="$host"
    # glab sends ONLY the bare endpoint `graphql` to the GraphQL API; any other
    # path ending in graphql (a wiki slug, a repository file) is a REST write.
    if [ "$ep" = graphql ]; then glos_api_graphql; return 0; fi
    r="${r#/}"
    if [[ "${r,,}" == api/v4/* ]]; then r="${r:7}"; fi
  fi
  GLOS_API_HOST="$host"
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
  case "/$(glos_unescape "$ref")/" in
    *//* | */./* | */../*)
      ots_refuse 3 "the project segment '$ref' of the endpoint '$shown' does not spell its project plainly (decoded, it holds an empty, . or .. segment), so the outbound scan cannot tell which project it writes to. Fix: spell the endpoint plainly (projects/<id or url-encoded path>/…, with no . or .. segment, escaped or not)." ;;
  esac
  want="${root,,}/${dec,,}"
  if [ "$lower" != "$want" ] && [[ "$lower" != "$want"/* ]]; then
    ots_refuse 3 "the endpoint '$shown' does not route to the project it spells ('$ref'), so the outbound scan cannot tell which project it writes to. Fix: spell the endpoint plainly, with no . or .. segments (projects/<id or url-encoded path>/…)."
  fi
  targets+=("api:$host|${root,,}/$ref")
  return 0
}

# glos_api_graphql : a GraphQL call adds an unknown target when its query holds
# a mutation, and nothing when it is a read. Exits 3 when the query cannot be
# read.
glos_api_graphql() {
  local sc
  if fas_graphql_scan mutation; then sc=0; else sc=$?; fi
  case "$sc" in
    0) targets+=("?:a GraphQL mutation names its target inside the query") ;;
    1) ;;
    *) ots_refuse 3 "the outbound scan cannot tell whether this GraphQL call writes: $FAS_WHY. Fix: $FAS_HOW." ;;
  esac
  return 0
}

# glos_endpoint_placeholder <endpoint> : exits 3 when glab would fill a
# placeholder in the endpoint after this scan: in its query, or in its path
# with a leading projects/:id or projects/:fullpath set aside (only a
# lower-case, plain prefix qualifies). Called for every api write, with text or
# not, before anything else judges the endpoint.
glos_endpoint_placeholder() {
  local ep="$1" ph
  ph="${ep%%[?#]*}"
  if [[ "$ph" =~ ^(([A-Za-z][A-Za-z0-9+.-]*://[^/]*)?/?(api/v4/)?projects/)(:id|:fullpath)(/.*)?$ ]]; then
    ph="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
  fi
  if glos_has_placeholder "$ph" || { [[ "$ep" == *[?#]* ]] && glos_has_placeholder "${ep#*[?#]}"; }; then
    glos_refuse_placeholder "$(glos_shown "$ep")"
  fi
  return 0
}

# glos_refuse_placeholder <shown endpoint> : exits 3 for an endpoint that holds
# a placeholder glab fills after this scan.
glos_refuse_placeholder() {
  ots_refuse 3 "the endpoint '$1' (path or query) holds a placeholder glab fills after this scan (:branch, :fullpath, :group, :id, :namespace, :repo, :user, :username), so neither the text sent nor the project it routes to is what was scanned. Only a whole project segment of :id or :fullpath (projects/:id/…) is read as glab fills it. Fix: write the value out in full, or use projects/:id/… for the current directory's project."
}

# glos_api <offset of the first word after `api`> <args after api...> : fills
# the caller's text and file arrays and `targets` for an api write.
glos_api() {
  local off="$1" k ep
  shift
  FAS_API_VALUED="$FAS_GLAB_API_VALUED" FAS_API_BOOL="$FAS_GLAB_API_BOOL"
  FAS_API_SVALUED="$FAS_GLAB_API_SVALUED" FAS_API_SBOOL="$FAS_GLAB_API_SBOOL"
  if ! fas_parse_api "$@"; then
    ots_refuse 3 "'$FAS_UNKNOWN' is not a \`glab api\` flag the outbound scan knows (glab 1.112), so it cannot tell which text this call sends. Fix: drop the flag (glab rejects an unknown flag anyway)."
  fi
  # What a write is, which fields it sends, and the GraphQL copy step are
  # shared with gh-athena (ai/lib/outbound-text-scan.sh, DND-1976).
  ots_api_collect GLOS_ARGV "$off" api v4 || return 0
  # A placeholder in a write's endpoint is refused even when the write carries
  # no text: a fill can move where it routes (DND-2009).
  for ep in "${FAS_POS[@]}"; do glos_endpoint_placeholder "$ep"; done
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || return 0

  # glab fills a placeholder in a typed -F value AFTER this scan (DND-2009):
  # the scanned text would not be the text sent (a branch named after a work
  # ticket, say). Refused in glos_guard when a target is not PRIVATE.
  for k in "${!FAS_FKIND[@]}"; do
    if [ "${FAS_FKIND[$k]}" = typed ] && glos_has_placeholder "${FAS_FVAL[$k]}"; then
      GLOS_API_FILLED="the typed field '${FAS_FKEY[$k]}' (-F)"; break
    fi
  done
  GLOS_API_HOST=""
  for ep in "${FAS_POS[@]}"; do glos_api_target "$ep"; done
  # A merge request created in one project can target another (a fork's MR
  # into its upstream): that project is a target too, on the host the
  # endpoint goes to.
  for k in "${!FAS_FKEY[@]}"; do
    if [ "${FAS_FKEY[$k]}" = target_project_id ]; then
      case "${FAS_FKIND[$k]}:$GLOS_API_HOST" in
        file:* | formfile:*) targets+=("?:the target_project_id field is read from a file") ;;
        *:\?) targets+=("?:the target_project_id field names a project on a host this guard does not resolve") ;;
        *) targets+=("api:$GLOS_API_HOST|projects/${FAS_FVAL[$k]}") ;;
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
  GLOS_API_FILLED="" GLOS_AUTHORED="" GLOS_AUTHORED_WHAT=""
  OTS_TOOL=glab-athena OTS_DEST=project OTS_WHAT="glab command"
  local -a argv=("$@") path=() targets=() texts=() tlab=() fsrc=() fidx=() fpre=() flab=() fnoun=() fflag=() pos=()
  local -A fbase=()
  local n=$# i=0 a v pre="" group="" verb="" cmd table prc

  # The words before the command path. Only -R/--repo may sit there: any other
  # flag can make cobra's command walk differ from this parse (the merge
  # guard's rule, ai/lib/glab-merge-guard.sh -> glmg_prepath_flag). A help
  # flag passes: cobra shows the help and runs nothing.
  while [ "$i" -lt "$n" ]; do
    a="${argv[$i]}"
    case "$a" in
      -R | --repo)
        i=$((i + 1)); v="${argv[$i]:-}"
        if ots_flag_shaped "$v"; then ots_refuse_flag_value "$a" "$v"; fi
        targets+=("$v") ;;
      --repo=*) targets+=("${a#--repo=}") ;;
      -R?*) v="${a#-R}"; targets+=("${v#=}") ;;
      -h | --help) return 0 ;;
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
  if [ "$group" = api ]; then
    if [ "$i" != 1 ]; then
      ots_refuse 3 "\`api\` is not the first word, so the outbound scan cannot tell how glab parses the flags before it. Fix: put \`api\` first: \`glab-athena api <endpoint> [flags]\`."
    fi
    OTS_WHAT="api write"
    glos_api 1 "${argv[@]:1}"
  else
    cmd="$group $verb"
    if [ -n "$GLOS_TABLE_OK" ] && [ -n "${LFT_ALIAS[$cmd]+x}" ]; then cmd="${LFT_ALIAS[$cmd]}"; fi
    glos_roles "$cmd" || return 0
    cmd="$GLOS_CMD"
    OTS_WHAT="$cmd"
    if [ -z "$GLOS_TABLE_OK" ] || [ -z "${LFT_FLAGS[$cmd]+x}" ]; then
      ots_refuse 3 "the pinned glab flag table ($GLOS_LIB_DIR/glab-flag-table.sh) is missing, does not define LFT_FLAGS and LFT_ALIAS, or has no \`$cmd\`, so the outbound scan cannot read this argv. Fix: run glab-athena from a full ~/dev/custom checkout; if the file is damaged, regenerate it with \`ai/bin/cli-flag-table --cli glab --write\`."
    fi
    # The guard's own text, file and target flags always take a value, in the
    # table or not (`--target-project` is not in glab 1.92).
    table="$(ots_with_roles "${LFT_FLAGS[$cmd]}" "$GLOS_TEXT $GLOS_FILE $GLOS_TARGET")"
    # Lenient: this glab may have flags the table's glab lacked (header).
    prc=0; ots_pflag_parse lenient "$table" "$i" "${argv[@]:$i}" || prc=$?
    case "$prc" in
      0) ;;
      2) ots_refuse 3 "'$OTS_UNKNOWN' is not a flag of \`glab $cmd\` in the pinned table (glab $LFT_VERSION), and \`$OTS_AMBIG\` after it reads as a flag: if '$OTS_UNKNOWN' takes a value, glab reads \`$OTS_AMBIG\` as that value, and the outbound scan cannot tell which text, file or project this sends. Fix: attach the value (\`--flag=value\`), drop the flag, or put it after the text flags' values; if this glab has the flag, run \`ai/bin/cli-flag-table --cli glab --write\` and commit the table." ;;
      *) ots_refuse 3 "'$OTS_UNKNOWN' in this $OTS_WHAT is not a flag pflag can read. Fix: correct the flag (\`--name\` or \`--name=value\`)." ;;
    esac
    [ -z "$OTS_HELP" ] || return 0
    # Rule 2 of ai/lib/outbound-text-scan.sh, and the sort into text, files
    # and targets.
    ots_collect "$table" "$GLOS_TEXT" "$GLOS_FILE" "$GLOS_TARGET"
    for a in "${OTS_PO[@]}"; do
      pos+=("$a")
      [ -z "$GLOS_REF" ] || glos_positional "$GLOS_REF" "$a"
    done
    glos_authored "$cmd"
    # A flag the table lacks may be a newer text flag whose value this parse
    # reads as a positional: every positional is then text.
    if [ -n "$OTS_POS_TEXT" ] || [ -n "$OTS_SAW_UNKNOWN" ] || [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ]; then
      for a in "${pos[@]}"; do texts+=("$a"); tlab+=(argument); done
    fi
  fi
  # A command where glab builds text itself is judged even when it carries
  # none of its own (DND-2014).
  [ "$((${#texts[@]} + ${#fsrc[@]}))" -gt 0 ] || [ -n "$GLOS_AUTHORED" ] || return 0
  if [ "$group" != api ] && [ "${#targets[@]}" = 0 ]; then targets+=(""); fi
  [ "${#targets[@]}" -gt 0 ] || return 0

  local t public=""
  for t in "${targets[@]}"; do
    glos_target_vis "$t"
    if [ "$GLOS_VIS" != private ]; then public=1; fi
  done
  [ -n "$public" ] || return 0
  if [ -n "$GLOS_AUTHORED" ]; then
    ots_refuse 3 "$GLOS_AUTHORED makes glab send text glab builds itself ($GLOS_AUTHORED_WHAT) to this PUBLIC (or unknown) project, after the outbound scan and never seen by it. Fix: pass the text explicitly, so it is scanned: --title \"…\" --description \"…\" (with --related-issue, a non-empty --title and --source-branch <name> too), never -d - (an editor), and drop --fill, --fill-commit-body, --recover, --signoff and --copy-issue-labels."
  fi
  if [ -n "$GLOS_API_FILLED" ]; then
    ots_refuse 3 "$GLOS_API_FILLED holds a placeholder glab fills after this scan (:branch, :fullpath, :group, :id, :namespace, :repo, :user, :username), so the text sent to this PUBLIC (or unknown) project is not the text scanned. Fix: send the value with -f (raw; glab does not fill it), or write it out in full."
  fi
  ots_scan_all GLOS_ARGV
}
