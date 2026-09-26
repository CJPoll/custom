# shellcheck shell=bash
#
# gh-merge-guard.sh — the merge guard behind `gh-athena pr merge` (DND-609).
# Sourced, never run.
#
# The defect: on 2026-09-25 06:03Z `gh-athena pr merge 362 --squash --auto`
# merged gen_saas PR #362 IMMEDIATELY while CI on its head was still queued.
# `--auto` waits only on the base branch's REQUIRED checks. CJPoll/gen_saas is a
# free private repo: branch protection and rulesets both answer 403 "Upgrade to
# GitHub Pro", so the required set is empty and `--auto` gates on nothing. The
# skills called branch protection "the gate" — a mechanism that could not fire.
#
# So, before gh ever runs a merge:
#
#   * `pr merge --auto` is REFUSED unless a non-empty required-checks set for
#     the PR's base branch can be READ. Two sources are asked: classic branch
#     protection (…/branches/<b>/protection/required_status_checks) and
#     rulesets (…/rules/branches/<b>). Either one listing >= 1 required check
#     establishes the gate. A 403/404, an empty set, a malformed body, or any
#     failed lookup is "could not establish a gate" — never "fine". Every
#     source's outcome is printed with the refusal.
#   * A non-auto `pr merge` is REFUSED unless it pins the exact head with
#     `--match-head-commit <sha>`, that sha IS the PR's head, and every check
#     reported on that head concluded green: a CheckRun COMPLETED with
#     SUCCESS/NEUTRAL/SKIPPED, a commit StatusContext SUCCESS. Zero reported
#     checks is not green. The pin makes GitHub itself refuse the merge if the
#     head moves between this read and the merge.
#   * A gh ALIAS is expanded the way gh expands it (see gmg_expand_alias) and
#     the EXPANDED argv is what the guard judges, so `gh alias set p pr` then
#     `p merge 5 --auto` is refused like `pr merge 5 --auto`. A gh shell alias
#     (`!…`), an alias with quoting, and a failed alias lookup are refused.
#
# `gh api` merges are REFUSED outright (DND-728), before gh runs and with no
# reads: REST PUT …/pulls/<n>/merge, POST …/merges and …/merge-upstream (every
# method/flag/endpoint spelling gh accepts, normalized), and the GraphQL
# mutations mergePullRequest, enablePullRequestAutoMerge, enqueuePullRequest and
# mergeBranch, wherever the query comes from: -f/-F fields, -F k=@file, or an
# --input JSON body. What the guard cannot read (stdin, an unreadable file, a
# body that is not JSON, an unknown flag, an endpoint it cannot normalize, its
# own scratch file failing) is refused too. See gmg_api_guard.
#
# `gh api` writes that CREATE OR MOVE A REF are REFUSED outright too (DND-741),
# by the same parser, endpoint normalisation and GraphQL scan: REST writes to
# …/git/refs[/…] and …/git/ref/… (every method but a plain DELETE), any write
# to …/contents/… (each one is a commit on a branch), POST
# …/branches/<b>/rename, PUT …/pulls/<n>/update-branch (it merges the base into
# the PR's HEAD branch, which may itself be the default branch), and the GraphQL
# mutations createCommitOnBranch, createRef, updateRef, updateRefs,
# createLinkedBranch, revertPullRequest and updatePullRequestBranch. Each one
# puts commits on a branch (the default branch included) with no pinned head
# and no green check, and a free private repo has no branch protection to stop
# it. A ref DELETE (REST DELETE …/git/refs/…, GraphQL deleteRef) moves nothing
# onto a ref and passes; GitHub itself refuses to delete the default branch.
#
# SCOPE DECISION (DND-741, 2026-09-26): EVERY API ref write is refused, not
# only one aimed at the default branch. Reasons:
#   * Nothing legitimate uses them. Branches move by `gh-athena git push` (the
#     harness session fast-forwards custom main that way; shipwright pushes
#     main that way); a grep of ai/, scripts/, gen_saas and walt_ui found no
#     `gh api` ref write.
#   * The target is often not in the call. updateRef takes an opaque ref node
#     id, createCommitOnBranch may take a branch node id, and a query can carry
#     its target in variables or a file. Resolving it needs reads; an
#     unresolvable target would have to be refused anyway.
#   * "The default branch" is a read that can fail or change under the call
#     (PATCH repos/<o>/<r> default_branch), and "protected" cannot be read at
#     all on a free private repo (403). A refusal that needs no read has no
#     lookup to get wrong (~/.claude/CLAUDE.md -> *A failed lookup must never
#     look like an empty one*).
# The cost: a feature-branch ref write by API is refused too; its Fix is the
# `gh-athena git push` the fleet already uses.
#
# `pr merge --disable-auto` (without --auto) merges nothing and passes as-is.
# Every other command passes as-is with no extra reads, except that a first
# word gh does not ship as a command is looked up in `gh alias list`.
# The branch name goes into the API path unencoded (a `/` in it is accepted by
# GitHub's branch routes); if a lookup fails on it, that fails CLOSED.
#
# Residual (NOT checked; each still runs): a CLI command that moves a ref
# without `api` — `gh pr update-branch` (on a PR whose head is the default
# branch it merges the base into it) and `gh repo edit --default-branch` / a
# PATCH repos/<o>/<r> default_branch (it re-points which branch is the default;
# it moves no ref); a push by a GitHub Actions workflow with its own token; a
# ref-writing mutation GitHub adds after 2026-09-26; gh extensions
# (`gh <ext>`); a check that has not REPORTED yet on the head (a workflow that
# never queued a run is invisible to the rollup — the reason zero checks is
# refused, but one green check among several unstarted workflows passes);
# `--admin` is not refused on its own (with it, a non-auto merge still needs a
# green pinned head); a merge mutation name GitHub adds after 2026-09-26 (the
# list below is from that day's schema introspection).
#
# The App token cannot read classic protection (it has no Administration
# permission: 403 "Resource not accessible by integration", measured
# 2026-09-25), so on a repo that gates only through classic protection `--auto`
# is refused too. That is deny-by-default working: take the non-auto path.
#
# Usage: set GMG_TOOL, then `gmg_guard "$@"`. It returns 0 when the command may
# run, and exits 3 with a REFUSING line and a Fix: line otherwise. It calls
# `gh` for its reads, so the caller exports GH_TOKEN/GH_HOST first. After it
# returns, GMG_IS_MERGE is 1 when the command is a merge.

# The endpoint normaliser, the `api` argv parser and the GraphQL scan are
# shared with glab-athena's guard (DND-742).
# shellcheck source=forge-api-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-api-scan.sh" || {
  echo "gh-athena: REFUSING: cannot load ai/lib/forge-api-scan.sh, so no merge can be judged." >&2
  echo "  Fix: run gh-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

GMG_TOOL="${GMG_TOOL:-gh-athena}"
GMG_IS_MERGE=0
GMG_ESCALATE='Never merge or move a branch around this (a bare `gh pr merge`, a `gh api` merge or ref write, or the owner'"'"'s token); if the checks cannot go green, escalate to your admiral with the PR number and this output.'
GMG_SAFE_PATH="assert every check green on the PR's exact head SHA (\`gh pr checks <n>\`, \`gh pr view <n> --json headRefOid,statusCheckRollup\`), then \`~/dev/custom/ai/bin/$GMG_TOOL pr merge <n> --squash --match-head-commit <sha>\` WITHOUT --auto"

# gh's own top-level commands (gh 2.83). A first word outside this list may be
# an alias, which is expanded and checked.
GMG_BUILTINS=" agent-task alias api attestation auth browse cache codespace completion config copilot extension gist gpg-key help issue label org pr preview project release repo ruleset run search secret ssh-key status variable version workflow "

gmg_refuse() {
  # $1 what was refused, $2 why (may be multi-line), $3 the Fix: text
  printf '%s: REFUSING `%s`: %s\n  Fix: %s. %s\n' "$GMG_TOOL" "$1" "$2" "$3" "$GMG_ESCALATE" >&2
  exit 3
}

# gmg_false_word <value> : true when cobra would parse <value> as boolean false.
gmg_false_word() { case "$1" in 0|f|F|false|FALSE|False) return 0 ;; esac; return 1; }

# gmg_parse <args...> : sets GMG_IS_MERGE, GMG_AUTO, GMG_DISABLE_AUTO,
# GMG_REPO, GMG_SELECTOR, GMG_MATCH_SHA.
gmg_parse() {
  local -a pos=()
  local a v i c rest
  GMG_IS_MERGE=0 GMG_AUTO=0 GMG_DISABLE_AUTO=0 GMG_REPO="" GMG_SELECTOR="" GMG_MATCH_SHA=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) pos+=("$@"); break ;;
      --auto) GMG_AUTO=1 ;;
      --auto=*) v="${a#--auto=}"; if gmg_false_word "$v"; then GMG_AUTO=0; else GMG_AUTO=1; fi ;;
      --disable-auto) GMG_DISABLE_AUTO=1 ;;
      --disable-auto=*) gmg_false_word "${a#*=}" || GMG_DISABLE_AUTO=1 ;;
      --repo|--match-head-commit|--body|--body-file|--subject|--author-email)
        v="${1:-}"; [ $# -gt 0 ] && shift
        case "$a" in --repo) GMG_REPO="$v" ;; --match-head-commit) GMG_MATCH_SHA="$v" ;; esac ;;
      --repo=*) GMG_REPO="${a#*=}" ;;
      --match-head-commit=*) GMG_MATCH_SHA="${a#*=}" ;;
      --*) ;;
      -?*)
        # Short flags, possibly combined (-sd, -Ro/r, -R o/r). Booleans are
        # consumed; the first value-taking letter takes the rest of the token,
        # or the next argument when it is last.
        rest="${a#-}"; i=0
        while [ "$i" -lt "${#rest}" ]; do
          c="${rest:$i:1}"
          case "$c" in
            R|b|F|t|A)
              v="${rest:$((i+1))}"; v="${v#=}"
              if [ -z "$v" ]; then v="${1:-}"; [ $# -gt 0 ] && shift; fi
              [ "$c" = R ] && GMG_REPO="$v"
              break ;;
          esac
          i=$((i+1))
        done ;;
      *) pos+=("$a") ;;
    esac
  done
  if [ "${pos[0]:-}" = pr ] && [ "${pos[1]:-}" = merge ]; then
    GMG_IS_MERGE=1
    GMG_SELECTOR="${pos[2]:-}"
  fi
}

# gmg_expand_alias <args...> : sets GMG_ARGV to the argv gh will really run.
# gh expands an alias only when it is the FIRST argument. Each remaining
# argument fills a `$N` placeholder while the expansion still has a `$`, and
# is appended after it otherwise (both can happen in one expansion). So
# `gh alias set p pr` turns `p merge 5 --auto` into `pr merge 5 --auto`, and
# `x: pr $1` turns `x merge 5 --auto` into the same: the guard must parse the
# EXPANDED argv, never the alias word. Refused outright: a shell alias (`!…`,
# it can run anything), an expansion this cannot tokenize the way gh does
# (quotes or backslashes), and a failed alias lookup (a lookup that fails must
# not read as "no aliases").
gmg_expand_alias() {
  local first="${1:-}" list rc line name exp i a
  local -a words=()
  GMG_ARGV=("$@")
  [ -n "$first" ] || return 0
  case "$first" in -*) return 0 ;; esac
  case "$GMG_BUILTINS" in *" $first "*) return 0 ;; esac
  if list="$(gh alias list 2>&1)"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    # gh exits 1 with exactly this when no alias is configured.
    [ "$list" = "no aliases configured" ] && return 0
    gmg_refuse "gh $*" "'$first' is not a gh command, and \`gh alias list\` failed (exit $rc: $(tr '\n' ' ' <<<"$list")), so $GMG_TOOL cannot tell whether it is an alias that merges" \
      "run the command by its real gh name (e.g. \`~/dev/custom/ai/bin/$GMG_TOOL pr …\`), not an alias"
  fi
  while IFS= read -r line; do
    name="${line%%:*}"; exp="${line#*:}"; exp="${exp# }"
    [ "$name" = "$first" ] || continue
    case "$exp" in
      '!'*) gmg_refuse "gh $*" "'$first' is a gh shell alias ('$exp'), which can run anything, so $GMG_TOOL cannot check whether it merges" \
              "run the underlying command directly through the wrapper — \`~/dev/custom/ai/bin/$GMG_TOOL <the expanded command>\`" ;;
      *[\'\"\\]*) gmg_refuse "gh $*" "'$first' is a gh alias ('$exp') with quoting $GMG_TOOL does not tokenize the way gh does, so it cannot check whether it merges" \
              "run the expanded command directly — \`~/dev/custom/ai/bin/$GMG_TOOL <the expanded command>\`" ;;
    esac
    shift
    # gh's own loop (pkg/cmd/root alias expansion), step for step: walk the
    # remaining args in order; while the expansion still contains a `$`, the
    # arg fills its `$N` (i = its 1-based position); once no `$` is left, the
    # arg is APPENDED. So `x: pr $1` + `x merge 5 --auto` -> `pr merge 5 --auto`.
    local -a extra=()
    i=1
    for a in "$@"; do
      if [[ "$exp" == *'$'* ]]; then exp="${exp//"\$$i"/"$a"}"; else extra+=("$a"); fi
      i=$((i+1))
    done
    if [[ "$exp" =~ \$[0-9] ]]; then
      gmg_refuse "gh $first $*" "gh alias '$first' has unfilled placeholders after expansion ('$exp')" \
        "run the expanded command directly — \`~/dev/custom/ai/bin/$GMG_TOOL <the expanded command>\`"
    fi
    # gh splits the substituted expansion with shlex; read -ra only matches it
    # when no quote or backslash is present (an argument can bring one in).
    case "$exp" in
      *[\'\"\\]*) gmg_refuse "gh $first $*" "the expansion of gh alias '$first' contains quoting after substitution ('$exp'), which $GMG_TOOL does not tokenize the way gh does" \
              "run the expanded command directly — \`~/dev/custom/ai/bin/$GMG_TOOL <the expanded command>\`" ;;
    esac
    read -ra words <<<"$exp"
    GMG_ARGV=("${words[@]}" "${extra[@]}")
    return 0
  done <<<"$list"
  return 0
}

# gmg_probe_count <label> <jq-count-filter> <gh api args...> : one required-
# checks source. Appends "<label>: <outcome>" to GMG_PROBE_FILE (it runs in a
# command substitution, so a variable would not survive) and echoes the count
# (0 on any failure, malformed body included).
gmg_probe_count() {
  local label="$1" filter="$2" out err rc n
  shift 2
  err="$(mktemp)"
  # `if` form: the caller may run under `set -e` (gh-athena does).
  if out="$(gh api "$@" 2>"$err")"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    printf '  - %s: lookup FAILED (exit %s): %s\n' "$label" "$rc" "$(tr '\n' ' ' <"$err")" >>"$GMG_PROBE_FILE"
    rm -f "$err"; echo 0; return
  fi
  rm -f "$err"
  if ! n="$(jq -e "$filter" <<<"$out" 2>/dev/null)" || ! [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '  - %s: unreadable body (not the expected shape): %s\n' "$label" "$(head -c 200 <<<"$out" | tr '\n' ' ')" >>"$GMG_PROBE_FILE"
    echo 0; return
  fi
  printf '  - %s: %s required check(s)\n' "$label" "$n" >>"$GMG_PROBE_FILE"
  echo "$n"
}

# ---- `gh api` merges (DND-728) ---------------------------------------------
# `gh api` can merge without `pr merge`: REST PUT …/pulls/<n>/merge, POST
# …/merges and …/merge-upstream, and the GraphQL mutations below. Every one is
# REFUSED, never routed through the pinned-head check: `pr merge` is the one
# guarded merge path, and a second one would mean proving the REST body's `sha`
# field the way gh builds it. The judgment is local (no reads), so a refusal
# sends nothing. What the guard cannot read (a body on stdin, a file it cannot
# open, a body that is not JSON, a flag it does not know, an endpoint it cannot
# normalize) is refused too: an unseen merge must read as "refuse".

# The mutations that merge or schedule a merge, from live schema introspection
# (2026-09-26). disablePullRequestAutoMerge / dequeuePullRequest merge nothing
# into the base and pass. updatePullRequestBranch merges nothing into the base
# either, but it moves the PR's head branch, so it is a ref write (below).
GMG_MERGE_MUTATIONS="mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|mergeBranch"
GMG_API_FIX="merge only through the one guarded path: open a PR if there is none, then $GMG_SAFE_PATH"

# The mutations that create or move a ref (DND-741), from the same day's
# introspection. deleteRef moves nothing onto a ref and passes. updateRefs is
# listed before updateRef so a match names the longer one.
GMG_REF_MUTATIONS="createCommitOnBranch|createRef|updateRefs|updateRef|createLinkedBranch|revertPullRequest|updatePullRequestBranch"
GMG_REF_FIX="commit locally and move a branch only with \`~/dev/custom/ai/bin/$GMG_TOOL git push origin <feature-branch>\` (athena:github -> Pushing as Athena); land on the default branch only through a PR: $GMG_SAFE_PATH"

# gmg_api_path <endpoint> : echoes the endpoint's path as gh + GitHub would
# route it, lower-cased, with a leading api/ and api/v3/ (GHES) dropped. The
# normalisation itself (scheme/host, ?query and #fragment stripped, %-escapes
# decoded, `.`/`..`/empty segments applied) is fas_path in
# ai/lib/forge-api-scan.sh, shared with glab-athena's guard (DND-742). Returns 1
# when it cannot: a backslash, a malformed escape, a control character, or
# escapes still left after three decodes.
gmg_api_path() {
  local p
  p="$(fas_path "$1" api v3)" || return 1
  printf '%s' "${p,,}"
}

# gmg_api_merge_route <normalized path> : true when the path is a REST route
# that merges: repos/<o>/<r>/ or repositories/<id>/ followed by
# pulls/<n>/merge, merges, or merge-upstream (a `.json`/`;x` suffix on the last
# segment is ignored).
gmg_api_merge_route() {
  local -a s rest
  local last
  IFS=/ read -ra s <<<"$1"
  case "${s[0]:-}" in
    repos) rest=("${s[@]:3}") ;;
    repositories) rest=("${s[@]:2}") ;;
    *) return 1 ;;
  esac
  [ "${#rest[@]}" -gt 0 ] || return 1
  last="${rest[-1]%%[.;]*}"
  case "${#rest[@]}:${rest[0]}:$last" in
    3:pulls:merge|1:merges:merges|1:merge-upstream:merge-upstream) return 0 ;;
  esac
  return 1
}

# gmg_api_ref_route <normalized path> <method> : true when a REST write to the
# path creates or moves a ref (DND-741); echoes what it does. Same prefix and
# suffix rules as gmg_api_merge_route. <method> is never GET/HEAD here; a plain
# DELETE of a ref moves nothing onto it and is not a match, but a DELETE with a
# method-override header is (it is not a plain DELETE).
gmg_api_ref_route() {
  local method="$2" first second last
  local -a s rest
  IFS=/ read -ra s <<<"$1"
  case "${s[0]:-}" in
    repos) rest=("${s[@]:3}") ;;
    repositories) rest=("${s[@]:2}") ;;
    *) return 1 ;;
  esac
  [ "${#rest[@]}" -gt 0 ] || return 1
  first="${rest[0]%%[.;]*}"; second="${rest[1]:-}"; second="${second%%[.;]*}"; last="${rest[-1]%%[.;]*}"
  case "$first:$second" in
    git:ref|git:refs)
      [ "$method" = DELETE ] && return 1
      echo "a write to git/$second"; return 0 ;;
    contents:*) echo "a commit through the contents API"; return 0 ;;
  esac
  if [ "$first" = branches ] && [ "${#rest[@]}" -ge 3 ] && [ "$last" = rename ]; then
    echo "a branch rename"; return 0
  fi
  if [ "$first" = pulls ] && [ "${#rest[@]}" = 3 ] && [ "$last" = update-branch ]; then
    echo "a merge of the base into the PR's head branch"; return 0
  fi
  return 1
}

# `gh api` flags (gh 2.83), the table for fas_parse_api (ai/lib/forge-api-scan.sh,
# the argv parser shared with glab-athena's guard since DND-742).
GMG_API_VALUED=" --method --raw-field --field --header --input --jq --template --preview --hostname --cache "
GMG_API_BOOL=" --include --paginate --slurp --silent --verbose --help "
GMG_API_SVALUED="XFfHqtp"
GMG_API_SBOOL="ih"

# gmg_api_guard <shown> <gh api args (after the word api)...> : returns 0 when
# the call neither merges nor writes a ref; exits 3 otherwise. The argv parser
# and the GraphQL scan are fas_parse_api / fas_graphql_scan, shared with
# glab-athena's guard (DND-742); the routes and mutation names are GitHub's.
gmg_api_guard() {
  local shown="$1" ep path last what method sc name
  shift
  FAS_API_VALUED="$GMG_API_VALUED" FAS_API_BOOL="$GMG_API_BOOL"
  FAS_API_SVALUED="$GMG_API_SVALUED" FAS_API_SBOOL="$GMG_API_SBOOL"
  if ! fas_parse_api "$@"; then
    gmg_refuse "$shown" "'$FAS_UNKNOWN' is not a \`gh api\` flag $GMG_TOOL knows (gh 2.83), so it cannot tell how the rest of the call parses or whether it merges" \
      "drop the flag (gh rejects an unknown flag anyway); to merge, $GMG_SAFE_PATH"
  fi
  method="$FAS_METHOD"
  if [ -z "$method" ]; then
    if [ "$FAS_NPARAMS" -gt 0 ] || [ -n "$FAS_INPUT" ]; then method=POST; else method=GET; fi
  fi
  [ "$FAS_OVERRIDE" = 1 ] && method="$method with a method-override header"

  for ep in "${FAS_POS[@]}"; do
    if ! path="$(gmg_api_path "$ep")"; then
      gmg_refuse "$shown" "the endpoint '$ep' cannot be normalized (a backslash, a control character, or a malformed or nested %-escape), so $GMG_TOOL cannot tell whether it is a merge route" \
        "spell the endpoint plainly (e.g. repos/<owner>/<repo>/pulls/<n>); to merge, $GMG_SAFE_PATH"
    fi
    last="${path##*/}"; last="${last%%[.;]*}"
    if [ "$last" = graphql ]; then
      # 0 = a merge or ref-write name found, 1 = none, 2 = the guard cannot
      # tell (stdin, an unreadable file, a non-JSON body, its own scratch file
      # or grep failing), which is refused, never read as "none".
      if fas_graphql_scan "$GMG_MERGE_MUTATIONS|$GMG_REF_MUTATIONS"; then sc=0; else sc=$?; fi
      if [ "$sc" = 2 ]; then
        gmg_refuse "$shown" "$GMG_TOOL cannot tell whether this GraphQL call merges or moves a branch: $FAS_WHY" \
          "$FAS_HOW; to merge, $GMG_SAFE_PATH"
      fi
      if [ "$sc" = 0 ]; then
        name="$FAS_FOUND"
        # A merge name is reported as a merge; anything else that matched
        # (including a name that could not be re-extracted) as a ref write.
        if [[ "${name,,}" =~ ^(${GMG_MERGE_MUTATIONS,,})$ ]]; then
          gmg_refuse "$shown" "this GraphQL call carries the merge mutation '$name', which merges (or schedules a merge) without the pinned-head, all-green check (DND-728)" \
            "$GMG_API_FIX"
        fi
        gmg_refuse "$shown" "this GraphQL call carries the ref-write mutation '${name:-?}', which creates or moves a branch (it can put commits on the default branch) with no pinned head and no green check (DND-741)" \
          "$GMG_REF_FIX"
      fi
      continue
    fi
    case "$method" in GET|HEAD) continue ;; esac
    if gmg_api_merge_route "$path"; then
      gmg_refuse "$shown" "this is a REST merge ($method $path), which merges without the pinned-head, all-green check (DND-728)" \
        "$GMG_API_FIX"
    fi
    if what="$(gmg_api_ref_route "$path" "$method")"; then
      gmg_refuse "$shown" "this is $what ($method $path), which creates or moves a branch (it can put commits on the default branch) with no pinned head and no green check (DND-741)" \
        "$GMG_REF_FIX"
    fi
  done
  GMG_IS_MERGE=0
  return 0
}

# gmg_guard <gh args...> : the entry point. Returns 0 or exits 3.
gmg_guard() {
  local shown="gh $*" pr_json err rc url owner repo base head n_prot n_rules bad total w
  gmg_expand_alias "$@"
  # The first non-flag word of the EXPANDED argv picks the command; `api` is
  # judged by gmg_api_guard (DND-728), everything else by the pr merge rules.
  local -a before=()
  for w in "${GMG_ARGV[@]}"; do
    case "$w" in
      -*) before+=("$w") ;;
      api) gmg_api_guard "$shown" "${before[@]}" "${GMG_ARGV[@]:$(( ${#before[@]} + 1 ))}"; return 0 ;;
      *) break ;;
    esac
  done
  gmg_parse "${GMG_ARGV[@]}"
  [ "$GMG_IS_MERGE" = 1 ] || return 0
  if [ "$GMG_AUTO" = 0 ] && [ "$GMG_DISABLE_AUTO" = 1 ]; then return 0; fi

  local -a view=(pr view)
  [ -n "$GMG_SELECTOR" ] && view+=("$GMG_SELECTOR")
  [ -n "$GMG_REPO" ] && view+=(-R "$GMG_REPO")
  err="$(mktemp)"
  if pr_json="$(gh "${view[@]}" --json number,url,baseRefName,headRefOid,statusCheckRollup 2>"$err")"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ] || ! jq -e '.url and .baseRefName and .headRefOid' >/dev/null 2>&1 <<<"$pr_json"; then
    local why; why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
    gmg_refuse "$shown" "could not read the PR (\`gh ${view[*]}\` exit $rc: ${why:-no usable JSON}), so no merge gate can be established" \
      "make the PR readable (right number, right -R <owner>/<repo>), then $GMG_SAFE_PATH"
  fi
  rm -f "$err"
  url="$(jq -r .url <<<"$pr_json")"; base="$(jq -r .baseRefName <<<"$pr_json")"; head="$(jq -r .headRefOid <<<"$pr_json")"
  if ! [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/[0-9]+$ ]]; then
    gmg_refuse "$shown" "the PR URL '$url' is not a github.com pull URL, so its repo cannot be resolved" "$GMG_SAFE_PATH"
  fi
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"

  if [ "$GMG_AUTO" = 1 ]; then
    GMG_PROBE_FILE="$(mktemp)"
    n_prot="$(gmg_probe_count "branch protection (repos/$owner/$repo/branches/$base/protection/required_status_checks)" \
      '((.contexts // []) + ((.checks // []) | map(.context))) | unique | length' \
      "repos/$owner/$repo/branches/$base/protection/required_status_checks")"
    n_rules="$(gmg_probe_count "rulesets (repos/$owner/$repo/rules/branches/$base)" \
      'if type == "array" then [.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?] | length else error("not an array") end' \
      "repos/$owner/$repo/rules/branches/$base?per_page=100")"
    local probes; probes="$(cat "$GMG_PROBE_FILE")"; rm -f "$GMG_PROBE_FILE"
    if [ "$(( n_prot + n_rules ))" -gt 0 ]; then return 0; fi
    gmg_refuse "$shown" "\`--auto\` waits only on the base branch's REQUIRED checks, and $GMG_TOOL could not establish a gate for $owner/$repo:$base: 0 required checks readable. Probes:
$probes
  With no required set, --auto merges IMMEDIATELY, whatever CI is doing (gen_saas PR #362, 2026-09-25)" \
      "$GMG_SAFE_PATH"
  fi

  if [ -z "$GMG_MATCH_SHA" ]; then
    gmg_refuse "$shown" "a merge without --auto must pin the exact head it was checked on, and no --match-head-commit was given (PR head is $head)" \
      "$GMG_SAFE_PATH"
  fi
  if [ "$GMG_MATCH_SHA" != "$head" ]; then
    gmg_refuse "$shown" "--match-head-commit $GMG_MATCH_SHA is not the PR's head; the head is $head (pass the full 40-char SHA)" \
      "re-check CI on $head, then $GMG_SAFE_PATH"
  fi
  total="$(jq -r '(.statusCheckRollup // []) | length' <<<"$pr_json")"
  if [ "$total" = 0 ]; then
    gmg_refuse "$shown" "no check has reported on head $head, so nothing shows it green" \
      "wait for CI to report on $head (\`gh pr checks <n> --watch\`), then $GMG_SAFE_PATH"
  fi
  bad="$(jq -r '(.statusCheckRollup // [])[]
      | if .__typename == "StatusContext" then
          select(.state != "SUCCESS") | "    \(.context): \(.state)"
        else
          select(.status != "COMPLETED" or ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED") | not))
          | "    \(.name // "?"): \(.status // "?")/\(if (.conclusion // "") == "" then "-" else .conclusion end)"
        end' <<<"$pr_json" 2>&1)" || bad="    (rollup unreadable: $bad)"
  if [ -n "$bad" ]; then
    gmg_refuse "$shown" "not every check on head $head is green:
$bad" \
      "wait for these to conclude (\`gh pr checks <n> --watch\`) and fix any red one, then $GMG_SAFE_PATH"
  fi
  return 0
}
