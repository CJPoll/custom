# shellcheck shell=bash
# scripts/lib/lead-time-repos.sh — the ONE reader of `ai/bin/lead-time-repos
# --json` for the shell callers (DND-1604): scripts/athena-leadtime-run.sh and
# scripts/setup-leadtime-cron.
#
# Before this lib each caller ran the resolver and parsed its JSON with its own
# jq, and the runner parsed it a second time for its product repos. Three
# parsers of one output drift apart silently when the resolver's JSON grows.
# Now the resolver's schema is read here, once, into plain variables; the
# callers keep only their own messages, exit codes and Fix: text.
#
# It lives beside scripts/lib/mcp-preflight.sh because it is the same kind of
# thing for the same callers: a definition-only lib that a runner and its
# installer both source, that prints nothing, and that hands back a result for
# each caller to word. The Ruby readers (ai/lib/lead_time_config*.rb) read the
# config files directly, not this JSON, so they are not callers.
#
# lt_repos_resolve <resolver>
#   Runs `<resolver> --json` (stdin /dev/null, stderr captured) and reads it.
#   Prints nothing; never exits; safe under `set -euo pipefail`. Returns 0.
#   Sets:
#     LT_RES_RC      0 the list resolved; else non-zero, never an empty list:
#                      127 <resolver> absent or not executable, or no jq
#                      73  mktemp failed, so the resolver could not run
#                      <n> the resolver's own non-zero exit
#                      1   it exited 0 but its --json is unreadable, or is
#                          not the documented shape, or lists no repo
#     LT_RES_FAULT   none | resolver-missing | jq-missing | mktemp |
#                    resolver-exit | unreadable (the caller words each one)
#     LT_RES_RAN     "exit <n>" once the resolver ran, else "not run"
#     LT_RES_ERR     the resolver's stderr (its Fix: line included), if it ran
#     LT_RES_DETAIL  on unreadable: jq's error, one line
#   On LT_RES_RC 0 only (all empty otherwise, so a half-read list is never
#   left behind):
#     LT_RES_SOURCE       .source (default | override)
#     LT_RES_PATH         .path, the config file it read
#     LT_RES_CONSIDERED   .considered
#     LT_RES_REPOS        one line per repo: name US mode US path US idle_workflow
#                         (US = $'\x1f'; idle_workflow is "" when null/absent)
#     LT_RES_NAMES        name,name,...
#     LT_RES_DESC         "name (mode, path); ..."
#     LT_RES_TSV          one "name<TAB>mode" line per repo
#     LT_RES_SKIPPED      "name (reason); ..." or "" with no skip
#     LT_RES_SKIPPED_RUN  "name(reason),..." or "none"
#     LT_RES_TEXT         the printable list: a header naming the source and
#                         file, one padded line per repo, one per skip, counts
#
# Every value is flattened onto one line (newline, carriage return, tab and
# the US separator become a space), so a value can never shift a field.
#
# It is stricter than the two jq readers it replaced in one way: a repo whose
# name, mode or path is not a non-empty string is refused as unreadable. The
# resolver's --help schema never prints one.
#
# A failed or malformed resolution is an error at its source, never an empty
# list (~/.claude/CLAUDE.md -> "A failed lookup must never look like an empty
# one"): "exited 0 but lists no repo" is LT_RES_RC 1, not a run over nothing.

# The one jq program. It validates the shape the resolver documents (its
# --help) and prints a tagged stream, one record per line, fields split by US:
#   meta US source US path US considered
#   repo US name US mode US path US idle_workflow
#   skip US name US reason
# Any shape it cannot vouch for is error(), so jq exits non-zero.
LT_REPOS_JQ='
def one: if . == null then "" else tostring end | gsub("[\n\r\t\u001f]"; " ");
def need_str($k): if (.[$k] | type) == "string" and (.[$k] | length) > 0 then . else error("a repo has no string \($k)") end;
if type != "object" then error("not a JSON object")
elif (.repos | type) != "array" or (.repos | length) == 0 then error("no resolved repos")
elif (.skipped // [] | type) != "array" then error(".skipped is not an array")
else . end
| [.repos[] | need_str("name") | need_str("mode") | need_str("path")] as $checked
| ["meta", (.source | one), (.path | one), (.considered | one)],
  (.repos[] | ["repo", (.name | one), (.mode | one), (.path | one), (.idle_workflow | one)]),
  ((.skipped // [])[] | ["skip", (.name | one), (.reason | one)])
| join("\u001f")'

lt_repos_reset() {
  LT_RES_SOURCE=""; LT_RES_PATH=""; LT_RES_CONSIDERED=""
  LT_RES_REPOS=""; LT_RES_NAMES=""; LT_RES_DESC=""; LT_RES_TSV=""
  LT_RES_SKIPPED=""; LT_RES_SKIPPED_RUN=""; LT_RES_TEXT=""
}

# lt_repos_pad <text> <width> — <text> then spaces to <width>, at least one.
lt_repos_pad() {
  local n=$(( $2 - ${#1} ))
  [ "${n}" -ge 1 ] || n=1
  printf '%s%*s' "$1" "${n}" ''
}

lt_repos_resolve() {
  local resolver="${1:-}" out err_file stream rc=0
  local us=$'\x1f' tag a b c d nrepo=0 nskip=0 line skips_text=""
  LT_RES_RC=0; LT_RES_FAULT="none"; LT_RES_RAN="not run"; LT_RES_ERR=""; LT_RES_DETAIL=""
  lt_repos_reset
  if [ -z "${resolver}" ] || [ ! -x "${resolver}" ]; then
    LT_RES_RC=127; LT_RES_FAULT="resolver-missing"; return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    LT_RES_RC=127; LT_RES_FAULT="jq-missing"; return 0
  fi
  err_file="$(mktemp 2>/dev/null)" || { LT_RES_RC=73; LT_RES_FAULT="mktemp"; return 0; }
  out="$("${resolver}" --json 2>"${err_file}" </dev/null)" || rc=$?
  LT_RES_RAN="exit ${rc}"
  LT_RES_ERR="$(cat -- "${err_file}" 2>/dev/null || true)"
  rm -f -- "${err_file}"
  if [ "${rc}" -ne 0 ]; then
    LT_RES_RC="${rc}"; LT_RES_FAULT="resolver-exit"; return 0
  fi
  # One jq call over the whole document, so a list it cannot read is one
  # fault, never a half-read list.
  if ! stream="$(jq -r "${LT_REPOS_JQ}" <<<"${out}" 2>&1)"; then
    LT_RES_RC=1; LT_RES_FAULT="unreadable"
    LT_RES_DETAIL="$(printf '%s' "${stream}" | tr '\n\r' '  ')"
    return 0
  fi
  while IFS="${us}" read -r tag a b c d; do
    case "${tag}" in
      meta) LT_RES_SOURCE="${a}"; LT_RES_PATH="${b}"; LT_RES_CONSIDERED="${c}" ;;
      repo)
        nrepo=$(( nrepo + 1 ))
        LT_RES_REPOS="${LT_RES_REPOS}${a}${us}${b}${us}${c}${us}${d}"$'\n'
        LT_RES_NAMES="${LT_RES_NAMES:+${LT_RES_NAMES},}${a}"
        LT_RES_DESC="${LT_RES_DESC:+${LT_RES_DESC}; }${a} (${b}, ${c})"
        LT_RES_TSV="${LT_RES_TSV}${a}"$'\t'"${b}"$'\n'
        line="  $(lt_repos_pad "${a}" 10)$(lt_repos_pad "${b}" 8)${c}"
        LT_RES_TEXT="${LT_RES_TEXT}${line}"$'\n' ;;
      skip)
        nskip=$(( nskip + 1 ))
        LT_RES_SKIPPED="${LT_RES_SKIPPED:+${LT_RES_SKIPPED}; }${a} (${b})"
        LT_RES_SKIPPED_RUN="${LT_RES_SKIPPED_RUN:+${LT_RES_SKIPPED_RUN},}${a}(${b})"
        skips_text="${skips_text}  skipped ${a}: ${b}"$'\n' ;;
    esac
  done <<<"${stream}"
  LT_RES_REPOS="${LT_RES_REPOS%$'\n'}"
  LT_RES_TSV="${LT_RES_TSV%$'\n'}"
  LT_RES_TEXT="Repos (ai/bin/lead-time-repos: source=${LT_RES_SOURCE} ${LT_RES_PATH}):"$'\n'"${LT_RES_TEXT}${skips_text}  ${LT_RES_CONSIDERED} considered, ${nrepo} resolved, ${nskip} skipped"
  [ -n "${LT_RES_SKIPPED_RUN}" ] || LT_RES_SKIPPED_RUN="none"
  # The jq program refuses an empty list; this guards the reader itself.
  if [ "${nrepo}" -eq 0 ]; then
    lt_repos_reset
    LT_RES_RC=1; LT_RES_FAULT="unreadable"; LT_RES_DETAIL="no repo record was read from the resolver's --json"
    return 0
  fi
  return 0
}
