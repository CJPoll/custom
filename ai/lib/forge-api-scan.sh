# shellcheck shell=bash
#
# forge-api-scan.sh — forge-neutral pieces of the merge guards' `api` judgment
# (DND-742). Sourced, never run. One parser per concern:
#
#   * fas_path       — an API endpoint normalised the way the CLI + forge would
#                      route it. Used by ai/lib/gh-merge-guard.sh (gh-athena,
#                      DND-728) and ai/lib/glab-merge-guard.sh (glab-athena).
#   * fas_parse_api  — a table-driven `<cli> api` argv parser: method, fields,
#                      field files, --input, --form, headers, endpoints. The
#                      flag table is the caller's (gh and glab differ).
#   * fas_graphql_scan — every string a GraphQL query could come from (inline
#                      fields, @files, an --input JSON body, form values),
#                      scanned for a set of mutation names.
#
# All three came out of gh-merge-guard.sh's gmg_api_guard (DND-728, DND-741),
# which now calls them with gh's flag table, as glab-merge-guard.sh does with
# glab's. What stays per forge: the flag table, the merge/ref routes and the
# mutation names.
#
# Every function here judges locally; none reads the network. A failure to
# READ what a call would send (stdin, an unreadable file, a non-JSON body, the
# scratch file) is returned as "cannot tell", which each caller refuses. It is
# never "no match" (~/.claude/CLAUDE.md -> *A failed lookup must never look like
# an empty one*). Nothing here passes a query or body through argv or env: the
# scan goes to a temp file through builtin printf, cat and jq file reads, so a
# large query cannot hit E2BIG (DND-670).

# fas_path <endpoint> [leading segment to drop ...] : echoes the endpoint's path
# as the CLI + forge would route it: no scheme/host, no ?query or #fragment,
# %-escapes decoded, empty and `.` segments dropped, `..` applied, then each
# named leading segment dropped in order when it is next (compared without
# case: `api v3` for GitHub, `api v4` for GitLab). Case is PRESERVED; callers
# lower-case it for route matching. Returns 1 when it cannot normalise: a
# backslash, a malformed escape, a control character, or escapes still left
# after three decodes.
fas_path() {
  local p="${1%%[?#]*}" n seg drop
  shift
  local -a segs=() res=()
  if [[ "$p" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*(.*)$ ]]; then p="${BASH_REMATCH[1]}"; fi
  for n in 1 2 3; do
    [[ "$p" == *\\* ]] && return 1
    [[ "$p" == *%* ]] || break
    [[ "$p" =~ %([^0-9A-Fa-f]|[0-9A-Fa-f][^0-9A-Fa-f]|[0-9A-Fa-f]?$) ]] && return 1
    [[ "$p" =~ %([01][0-9A-Fa-f]|7[Ff]) ]] && return 1
    p="$(printf '%b' "${p//%/\\x}")"
  done
  [[ "$p" == *[%\\]* ]] && return 1
  [[ "$p" == *[[:cntrl:]]* ]] && return 1
  IFS=/ read -ra segs <<<"$p"
  for seg in "${segs[@]}"; do
    case "$seg" in
      ''|.) ;;
      ..) if [ "${#res[@]}" -gt 0 ]; then unset 'res[-1]'; fi ;;
      *) res+=("$seg") ;;
    esac
  done
  for drop in "$@"; do
    if [ "${#res[@]}" -gt 0 ] && [ "${res[0],,}" = "$drop" ]; then res=("${res[@]:1}"); fi
  done
  local IFS=/
  printf '%s' "${res[*]}"
}

# ---- fas_parse_api ----------------------------------------------------------
# The caller sets the flag table first (space-delimited, each with a leading and
# trailing space):
#   FAS_API_VALUED  long flags that take a value, e.g. " --method --field … "
#   FAS_API_BOOL    long boolean flags, e.g. " --include --paginate … "
#   FAS_API_SVALUED short letters that take a value, e.g. "XFfH"
#   FAS_API_SBOOL   short boolean letters, e.g. "ih"
# Meaning is fixed by name: --method/-X, --field/-F (typed; a value starting
# with @ is a file, @- is stdin), --raw-field/-f, --header/-H, --input,
# --form (a value starting with @ is a file), --hostname. Every other known
# flag's value is ignored.
#
# fas_parse_api <args after the word api...> : returns 0 and sets
#   FAS_METHOD    the -X/--method value upper-cased, or "" when none
#   FAS_NPARAMS   how many --field/--raw-field/--form were given
#   FAS_FKEY/FAS_FVAL/FAS_FKIND  every field and form, in order; kind is
#                 raw | typed | file | form | formfile
#   FAS_RAW       every inline field/form value (for the GraphQL scan)
#   FAS_FILES     every @file a field or form reads (for the GraphQL scan)
#   FAS_INPUT     the --input path, or ""
#   FAS_NFORM     how many --form were given
#   FAS_OVERRIDE  1 when a header overrides the HTTP method
#   FAS_HOSTNAME  the --hostname value, or ""
#   FAS_POS       the positional words (the endpoint)
# It returns 1 on a flag outside the table, with FAS_UNKNOWN naming it: an
# unknown flag means the rest of the argv may not parse the way the CLI parses
# it, so the caller refuses.
fas_parse_api() {
  local a v i c rest
  FAS_METHOD="" FAS_NPARAMS=0 FAS_INPUT="" FAS_NFORM=0 FAS_OVERRIDE=0 FAS_HOSTNAME="" FAS_UNKNOWN=""
  FAS_FKEY=() FAS_FVAL=() FAS_FKIND=() FAS_RAW=() FAS_FILES=() FAS_POS=()
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) FAS_POS+=("$@"); break ;;
      --*=*)
        if [[ "$FAS_API_VALUED" == *" ${a%%=*} "* ]]; then fas_api_opt "${a%%=*}" "${a#*=}"
        elif [[ "$FAS_API_BOOL" == *" ${a%%=*} "* ]]; then :
        else FAS_UNKNOWN="${a%%=*}"; return 1; fi ;;
      --*)
        if [[ "$FAS_API_VALUED" == *" $a "* ]]; then
          v="${1:-}"; [ $# -gt 0 ] && shift
          fas_api_opt "$a" "$v"
        elif [[ "$FAS_API_BOOL" == *" $a "* ]]; then :
        else FAS_UNKNOWN="$a"; return 1; fi ;;
      -?*)
        rest="${a#-}"; i=0
        while [ "$i" -lt "${#rest}" ]; do
          c="${rest:$i:1}"
          if [[ "$FAS_API_SBOOL" == *"$c"* ]]; then :
          elif [[ "$FAS_API_SVALUED" == *"$c"* ]]; then
            v="${rest:$((i+1))}"; v="${v#=}"
            if [ -z "$v" ]; then v="${1:-}"; [ $# -gt 0 ] && shift; fi
            case "$c" in
              X) fas_api_opt --method "$v" ;;
              F) fas_api_opt --field "$v" ;;
              f) fas_api_opt --raw-field "$v" ;;
              H) fas_api_opt --header "$v" ;;
            esac
            break
          else FAS_UNKNOWN="-$c (in '$a')"; return 1; fi
          i=$((i+1))
        done ;;
      *) FAS_POS+=("$a") ;;
    esac
  done
  return 0
}

# fas_api_opt <long flag> <value> : records one flag of fas_parse_api.
fas_api_opt() {
  # A field with no `=` is rejected by the CLI; its whole text is kept as the
  # value anyway, so the GraphQL scan still sees it.
  local k="${2%%=*}" v="${2#*=}"
  case "$1" in
    --method) FAS_METHOD="${2^^}" ;;
    --raw-field) FAS_NPARAMS=$((FAS_NPARAMS+1)); FAS_FKEY+=("$k"); FAS_FVAL+=("$v"); FAS_FKIND+=(raw); FAS_RAW+=("$v") ;;
    --field|--form)
      FAS_NPARAMS=$((FAS_NPARAMS+1))
      [ "$1" = --form ] && FAS_NFORM=$((FAS_NFORM+1))
      FAS_FKEY+=("$k"); FAS_FVAL+=("$v")
      # The CLI reads a file only when the VALUE starts with @ (key=@path).
      if [[ "$v" == @* ]]; then
        FAS_FILES+=("${v#@}")
        if [ "$1" = --form ]; then FAS_FKIND+=(formfile); else FAS_FKIND+=(file); fi
      else
        FAS_RAW+=("$v")
        if [ "$1" = --form ]; then FAS_FKIND+=(form); else FAS_FKIND+=(typed); fi
      fi ;;
    --header)
      if [[ "${2,,}" =~ ^[[:space:]]*x-(http-)?method(-override)?[[:space:]]*: ]]; then FAS_OVERRIDE=1; fi ;;
    --input) FAS_INPUT="$2" ;;
    --hostname) FAS_HOSTNAME="$2" ;;
  esac
}

# fas_graphql_scan <mutation-name ERE alternation> : scans every string the
# query of the call fas_parse_api just parsed could come from. Returns
#   0  a named mutation was found; FAS_FOUND names it
#   1  none was found
#   2  the guard cannot tell; FAS_WHY says why and FAS_HOW how to fix it
# GraphQL names cannot be escaped or split, so a word match on the raw text
# finds the field whatever alias or fragment wraps it. A name inside a string
# argument matches too (an accepted false positive: the caller refuses).
fas_graphql_scan() {
  local re="$1" scan v grc
  FAS_FOUND="" FAS_WHY="" FAS_HOW=""
  if ! scan="$(mktemp 2>/dev/null)" || [ -z "$scan" ]; then
    FAS_WHY="it could not create a scratch file to scan the GraphQL query"
    FAS_HOW="check that \$TMPDIR (or /tmp) is writable, then re-run"
    return 2
  fi
  if [ "${#FAS_RAW[@]}" -gt 0 ] && ! printf '%s\n' "${FAS_RAW[@]}" >>"$scan" 2>/dev/null; then
    rm -f "$scan"
    FAS_WHY="it could not write the GraphQL fields to its scratch file"
    FAS_HOW="check that \$TMPDIR (or /tmp) is writable and not full, then re-run"
    return 2
  fi
  for v in "${FAS_FILES[@]}"; do
    if [ "$v" = - ]; then
      rm -f "$scan"
      FAS_WHY="a GraphQL field is read from stdin ('@-'), which cannot be inspected without consuming it"
      FAS_HOW="pass the query inline (-f query='…') or from a readable file (-F query=@<file>)"
      return 2
    fi
    if ! cat -- "$v" >>"$scan" 2>/dev/null; then
      rm -f "$scan"
      FAS_WHY="it cannot read the GraphQL field file '$v'"
      FAS_HOW="make the file readable, or pass the query inline (-f query='…')"
      return 2
    fi
  done
  if [ -n "$FAS_INPUT" ]; then
    if [ "$FAS_INPUT" = - ]; then
      rm -f "$scan"
      FAS_WHY="the GraphQL body is read from stdin ('--input -'), which cannot be inspected without consuming it"
      FAS_HOW="write the body to a file and pass --input <file>, or pass the query inline (-f query='…')"
      return 2
    fi
    if ! [ -f "$FAS_INPUT" ] || ! [ -r "$FAS_INPUT" ]; then
      rm -f "$scan"
      FAS_WHY="it cannot read the --input body '$FAS_INPUT'"
      FAS_HOW="make the file readable, or pass the query inline (-f query='…')"
      return 2
    fi
    # Every string in the body, JSON escapes decoded (a \u escape cannot hide a
    # name).
    if ! jq -r '.. | strings' "$FAS_INPUT" >>"$scan" 2>/dev/null; then
      rm -f "$scan"
      FAS_WHY="the --input body '$FAS_INPUT' is not JSON, so the query cannot be read out of it"
      FAS_HOW="send a JSON body ({\"query\": \"…\"}) or pass the query inline (-f query='…')"
      return 2
    fi
  fi
  # grep: 0 = found, 1 = none, anything else = the scan itself failed.
  if grep -aEiq "(^|[^A-Za-z0-9_])($re)([^A-Za-z0-9_]|$)" "$scan"; then grc=0; else grc=$?; fi
  if [ "$grc" != 0 ] && [ "$grc" != 1 ]; then
    rm -f "$scan"
    FAS_WHY="scanning the GraphQL query failed (grep exit $grc)"
    FAS_HOW="re-run; if it repeats, pass the query inline (-f query='…')"
    return 2
  fi
  if [ "$grc" = 0 ]; then
    FAS_FOUND="$(grep -aEio "(^|[^A-Za-z0-9_])($re)([^A-Za-z0-9_]|$)" "$scan" | grep -Eio "$re" | head -n1 || true)"
    rm -f "$scan"
    return 0
  fi
  rm -f "$scan"
  return 1
}
