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
#     `--match-head-commit <sha>`, that sha IS the PR's head, and every judged
#     run on that head concluded green: a CheckRun COMPLETED with
#     SUCCESS/NEUTRAL/SKIPPED, a commit StatusContext SUCCESS. A run is not
#     judged only when a newer check suite holds runs of the same check, all
#     SUCCESS (a close/reopen re-run); it is printed instead. An order that
#     cannot be read refuses (DND-1140; see gmg_checks_green). Zero reported
#     checks is not green. The pin makes
#     GitHub itself refuse the merge if the head moves between this read and
#     the merge.
#   * In a repo whose base-branch tip DECLARES an integration gate
#     (bin/prep-commit.sh or ai/bin/harness-gate, the rule integration-gate
#     uses), a merge is also REFUSED unless integration-gate's receipt exists
#     for exactly the pinned head, recorded against that tip or an ancestor of
#     it (DND-1463), and `--auto` is refused outright (DND-969; see
#     gmg_receipt_gate). The one recommended merge path
#     is integration-gate, then locked-merge, which makes this call.
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
# Residual of the receipt check (DND-969): the receipt is a local file, so any
# local actor can write one (the same trust level as critic-verdicts), and a
# repo that declares no gate on its base tip is not checked at all. Since
# DND-1463 a receipt on an older base the tip descends from is accepted, so the
# head combined with the base's newer commits was never gated; GitHub's squash
# refuses only a textual conflict. The owner accepted that risk for velocity
# (2026-10-01). locked-merge also checks the landed tree and that the head
# contains the receipt's base; this guard does neither, because the pinned head
# need not be in the local object store. integration-gate records only a base
# the head contains, so only a hand-written receipt meets that gap.
#
# Usage: set GMG_TOOL, then `gmg_guard "$@"`. It returns 0 when the command may
# run, and exits 3 with a REFUSING line and a Fix: line otherwise. It calls
# `gh` for its reads, so the caller exports GH_TOKEN/GH_HOST first, and `git`
# in the current directory for the receipt check. After it
# returns, GMG_IS_MERGE is 1 when the command is a merge.

# The endpoint normaliser, the `api` argv parser and the GraphQL scan are
# shared with glab-athena's guard (DND-742).
# shellcheck source=forge-api-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-api-scan.sh" || {
  echo "gh-athena: REFUSING: cannot load ai/lib/forge-api-scan.sh, so no merge can be judged." >&2
  echo "  Fix: run gh-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

# The integration-gate receipt and gate-declaration rules, shared with
# integration-gate and locked-merge so the three cannot drift (DND-969).
# shellcheck source=integration-receipt.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/integration-receipt.sh" || {
  echo "gh-athena: REFUSING: cannot load ai/lib/integration-receipt.sh, so no merge can be judged." >&2
  echo "  Fix: run gh-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

GMG_TOOL="${GMG_TOOL:-gh-athena}"
GMG_IS_MERGE=0
GMG_ESCALATE='Never merge or move a branch around this (a bare `gh pr merge`, a `gh api` merge or ref write, or the owner'"'"'s token); if the checks cannot go green, escalate to your admiral with the PR number and this output.'
# The one recommended merge path (DND-969): integration-gate, then locked-merge,
# which makes the pinned `pr merge` call itself under the repo's merge lock.
GMG_MB="~/dev/custom/ai/skills/athena:merge-boarding/scripts"
GMG_LAND="run \`$GMG_MB/integration-gate\` on the PR's head from a checkout of its repo, then land it with \`$GMG_MB/locked-merge --pr <n> --head <the SHA its INTEGRATION OK line names>\` (athena:merge-boarding -> Landing onto a moving main)"
GMG_SAFE_PATH="wait until every check on the PR's exact head SHA is green (\`~/dev/custom/ai/bin/gh-ci-wait --repo <owner>/<repo> --sha <head>\`), then $GMG_LAND"

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

# ---- the integration-gate receipt (DND-969) ---------------------------------
# locked-merge requires integration-gate's receipt (DND-965), but a direct
# `pr merge --match-head-commit <sha>` only asked whether CI was green, so it
# merged heads integration-gate never passed. Now every merge of a repo that
# DECLARES a gate needs the receipt for exactly the pinned head, recorded
# against the base branch's current tip or an ancestor of it.
#
# **Later (2026-10-01, DND-1463):** the recorded base had to EQUAL the tip, so
# any merge that landed while a PR waited forced a full re-gate. Superseded by
# owner decision ("Let's soften that merge guard requirement."): an ancestor
# is accepted, because the base moved on and nothing rewrote it. A recorded
# base that is not an ancestor is still RECEIPT FOR ANOTHER BASE. The
# declaration rule and the
# receipt reader are ai/lib/integration-receipt.sh, the ones integration-gate
# and locked-merge use.
#
# The receipt is local (<git common dir>/integration-receipts/), so the merge
# must run from a checkout of the PR's repo. A cwd that is not one, a base tip
# the forge will not report, and a base tip that is not in the local object
# store are each COULD NOT LOOK and refused: none of them may read as "this
# repo declares no gate". A repo whose base tip declares no gate merges as
# before. There is no flag or env var that skips this (~/dev/custom/CLAUDE.md
# -> "A check's own bar must not live in the diff it is checking").

# gmg_checkout_for <owner> <repo> : sets GMG_TOP and GMG_COMMON to the cwd's
# checkout when one of its remotes is github.com/<owner>/<repo>. Returns 1 with
# GMG_WHY otherwise.
gmg_checkout_for() {
  local want u found=0 urls
  want="${1,,}/${2,,}"
  GMG_TOP="" GMG_COMMON="" GMG_WHY=""
  if ! GMG_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$GMG_TOP" ]; then
    GMG_WHY="the current directory ($(pwd)) is not inside a git checkout"; return 1
  fi
  GMG_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || GMG_COMMON=""
  case "$GMG_COMMON" in
    /*) ;;
    *) GMG_WHY="the git common dir of ${GMG_TOP} did not resolve to an absolute path (got '${GMG_COMMON}'; git >= 2.31 is needed)"; return 1 ;;
  esac
  urls="$(git remote -v 2>/dev/null | awk '{print $2}' | sort -u)" || urls=""
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    u="${u,,}"; u="${u%/}"; u="${u%.git}"
    case "$u" in *"github.com:$want"|*"github.com/$want") found=1 ;; esac
  done <<<"$urls"
  if [ "$found" != 1 ]; then
    GMG_WHY="${GMG_TOP} is not a checkout of $1/$2 (its remotes: $(tr '\n' ' ' <<<"${urls:-none}"))"; return 1
  fi
  return 0
}

# gmg_receipt_gate <shown> <owner> <repo> <base-branch> <pinned-head|""> :
# returns 0 when the merge may proceed; exits 3 otherwise. An empty head means
# `--auto`, which GitHub completes later onto whatever the base is then, so no
# receipt can cover it: in a gated repo it is refused.
gmg_receipt_gate() {
  local shown="$1" owner="$2" repo="$3" base="$4" head="$5" ref_json err rc tip gate why
  local look="COULD NOT LOOK: $GMG_TOOL cannot tell whether $owner/$repo declares an integration gate"
  if ! gmg_checkout_for "$owner" "$repo"; then
    gmg_refuse "$shown" "$look, because $GMG_WHY. The integration-gate receipt lives in the repo's git common dir, so it can only be read from a checkout" \
      "cd into a checkout or worktree of $owner/$repo (\`git remote -v\` names github.com/$owner/$repo), then $GMG_LAND"
  fi
  err="$(mktemp)"
  if ref_json="$(gh api "repos/$owner/$repo/git/ref/heads/$base" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  tip="$(jq -r '.object.sha // empty' <<<"$ref_json" 2>/dev/null)" || tip=""
  if [ "$rc" != 0 ] || ! [[ "$tip" =~ ^[0-9a-f]{40}$ ]]; then
    gmg_refuse "$shown" "$look: the tip of its base branch '$base' could not be read (\`gh api repos/$owner/$repo/git/ref/heads/$base\` exit $rc: ${why:-body '$(head -c 200 <<<"$ref_json" | tr '\n' ' ')'})" \
      "make the base branch readable (right -R <owner>/<repo>, network up), then $GMG_LAND"
  fi
  if gate="$(ir_declared_gate_on "$GMG_TOP" "$tip")"; then rc=0; else rc=$?; fi
  case "$rc" in
    1) return 0 ;;   # the base tip declares no gate: merge as before
    2) gmg_refuse "$shown" "$look: the base tip $tip (origin/$base on the forge) is not in the object store of $GMG_TOP" \
         "\`cd $GMG_TOP && git fetch origin\` so $tip is local, then $GMG_LAND" ;;
  esac
  if [ -z "$head" ]; then
    gmg_refuse "$shown" "$owner/$repo declares an integration gate ($gate on $base at $tip), and \`--auto\` merges later, when the required checks pass, onto whatever $base is then. No integration-gate receipt can cover that base" \
      "drop --auto; wait until every check on the PR's head is green (\`~/dev/custom/ai/bin/gh-ci-wait --repo <owner>/<repo> --sha <head>\`), then $GMG_LAND"
  fi
  if ! ir_read_receipt "$GMG_COMMON" "$head" "$tip"; then
    gmg_refuse "$shown" "$IR_KIND: $owner/$repo declares an integration gate ($gate on $base at $tip), and $IR_WHY" \
      "${IR_HOW:+$IR_HOW }$GMG_LAND"
  fi
  if [ "$IR_BASE_MOVED" = 1 ]; then
    printf '%s: RECEIPT %s base %s recorded %s; BASE MOVED: %s is an ancestor of the tip %s, so the head with the newer %s commits was never gated (DND-1463)\n' \
      "$GMG_TOOL" "$IR_RECEIPT" "$IR_BASE" "$IR_RECORDED_AT" "$IR_BASE" "$tip" "$base" >&2
  else
    printf '%s: RECEIPT %s base %s recorded %s\n' "$GMG_TOOL" "$IR_RECEIPT" "$tip" "$IR_RECORDED_AT" >&2
  fi
  return 0
}

# ---- the checks on the pinned head: the LATEST run of each check (DND-1140) --
# The defect: gen_saas PR #488, head d0889159, 2026-09-28. CI run 36464818403
# failed its Test job (a ticketed flake). The App cannot re-run jobs, so the PR
# was closed and reopened, and run 36467382644 re-ran CI on the SAME head, all
# green; `gh pr checks` showed all green. The head's rollup still held both
# runs, the guard judged every check-run, and the superseded Test failure kept
# refusing the merge.
#
# So a run may be SUPERSEDED by a newer run of the same check, the way
# `gh pr checks` and GitHub's required-check view already ignore it. The rules,
# each chosen to fail closed:
#   * One check run identity is (app id, workflow id, workflow-run event,
#     check name). The app separates two apps reporting the same name; the
#     workflow separates two workflow files with a same-named job; the event
#     keeps a push run and a pull_request run of one workflow apart (both are
#     current). This is stricter than GitHub's own (app, name) key. A commit
#     status's identity is its context.
#   * Superseding happens only ACROSS check suites. Within one identity the
#     runs are grouped by check suite; the suite whose newest run started last
#     is current, and EVERY run of that identity in it is judged. So two
#     current jobs that share a display name in one workflow run are both
#     judged, and a re-run attempt inside the same suite does not hide the
#     failed attempt (residual: such a re-run still refuses; a close/reopen or
#     a new commit makes a new suite). Each commit status is its own "suite".
#   * Runs in older suites are superseded only when every current run of that
#     identity concluded SUCCESS. A newer SKIPPED or NEUTRAL run (a job gated
#     off on reopen, say) proves nothing, so an older red run stays judged.
#   * A run whose identity cannot be read (no name, no app id, no suite id,
#     no app slug, or an Actions run with no workflow or event) is judged on
#     its own, never folded.
#   * Across suites, a missing or malformed start time refuses, and so does a
#     tie for the newest start time: the order cannot be read, so no suite may
#     be called current. Times must be whole-second UTC (GitHub's format), so
#     string order is time order; a fractional time is refused, not guessed.
#   * Every superseded run is printed, on a pass and on a refusal.
#
# The contexts are read by GraphQL for the PINNED head commit itself, not from
# `pr view`'s rollup, because only the check suite carries the app, suite,
# workflow and event. One page of 100: a rollup with more (another page, or a
# totalCount the page does not match) is refused, since unread runs are not
# green. Zero contexts is refused, as before: no evidence is not green.
GMG_ROLLUP_QUERY='query($owner: String!, $repo: String!, $oid: GitObjectID!) { repository(owner: $owner, name: $repo) { object(oid: $oid) { __typename ... on Commit { statusCheckRollup { contexts(first: 100) { totalCount pageInfo { hasNextPage } nodes { __typename ... on CheckRun { name status conclusion startedAt checkSuite { databaseId app { databaseId slug } workflowRun { event workflow { databaseId } } } } ... on StatusContext { context state createdAt } } } } } } } }'

# The answer's shape: OK, EMPTY (no context), or ERR<TAB><why>.
GMG_ROLLUP_SHAPE='
  if (.errors // null) != null then "ERR\tthe GraphQL answer carries errors: \([.errors[]? | (.message // tostring)] | join("; "))"
  elif (.data.repository.object.__typename // null) != "Commit" then "ERR\tthe forge returned no commit for it (object: \(.data.repository.object // null | tojson))"
  elif .data.repository.object.statusCheckRollup == null then "EMPTY"
  else .data.repository.object.statusCheckRollup.contexts as $c
    | if ($c.nodes | type) != "array" then "ERR\tthe rollup carries no contexts list"
      elif $c.pageInfo.hasNextPage != false then "ERR\tthe head has more than \($c.nodes | length) check contexts (another page exists), and unread runs are not green"
      elif $c.totalCount != ($c.nodes | length) then "ERR\tthe rollup counts \($c.totalCount) contexts but returned \($c.nodes | length)"
      elif ($c.nodes | length) == 0 then "EMPTY"
      else "OK" end
  end'

# The judgment. One line per run or finding: BAD<TAB><text> for a run that is
# judged and not green, or a check whose order cannot be read; OLD<TAB><text>
# for a superseded run. The caller refuses on any other line.
GMG_ROLLUP_JUDGE='
  def ts: if .__typename == "StatusContext" then .createdAt else .startedAt end;
  def ts_ok: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def nonempty: type == "string" and length > 0;
  def green:
    if .__typename == "StatusContext" then .state == "SUCCESS"
    elif .__typename == "CheckRun" then .status == "COMPLETED" and ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED"))
    else false end;
  def success:
    if .__typename == "StatusContext" then .state == "SUCCESS"
    elif .__typename == "CheckRun" then .status == "COMPLETED" and .conclusion == "SUCCESS"
    else false end;
  def cname: (if .__typename == "StatusContext" then .context else .name end) // "?" | tostring;
  def lbl:
    if .__typename == "StatusContext" then "\(cname): \(.state // "?")"
    elif .__typename == "CheckRun" then "\(cname): \(.status // "?")/\(if (.conclusion // "") == "" then "-" else .conclusion end)"
    else "a context of unknown type \(.__typename // "?" | tostring)" end;
  def when: " (started \(ts // "?" | tostring))";
  def key($i):
    if .__typename == "StatusContext" and (.context | nonempty) then ["status", .context]
    elif .__typename == "CheckRun" and (.name | nonempty)
         and (.checkSuite.databaseId | type == "number")
         and (.checkSuite.app.databaseId | type == "number")
         and (.checkSuite.app.slug | nonempty)
         and (.checkSuite.app.slug != "github-actions"
              or ((.checkSuite.workflowRun.workflow.databaseId | type == "number")
                  and (.checkSuite.workflowRun.event | nonempty)))
      then ["check", .checkSuite.app.databaseId, (.checkSuite.workflowRun.workflow.databaseId // null),
            (.checkSuite.workflowRun.event // null), .name]
    else ["alone", $i] end;
  def suite($i): if .__typename == "CheckRun" then .checkSuite.databaseId else $i end;
  [.data.repository.object.statusCheckRollup.contexts.nodes | to_entries[] | .key as $i | .value
    | {k: key($i), s: suite($i), v: .}]
  | group_by(.k)[]
  | [group_by(.s)[] | map(.v)] as $suites
  | if ($suites | length) == 1 then ($suites[0][] | if green then empty else "BAD\t\(lbl)" end)
    elif ([$suites[][] | ts | ts_ok] | all | not) then
      "BAD\t\($suites[0][0] | cname): runs from \($suites | length) check suites on the head, and their order cannot be read (start times: \([$suites[][] | ts | tostring] | join(", "))), so which run is current is unknown; a run with no start time has not started yet"
    else ($suites | map({t: (map(ts) | max), runs: .}) | sort_by(.t)) as $o
      | ($o[-1].t) as $top | [$o[] | select(.t == $top)] as $tied
      | if ($tied | length) > 1 then
          "BAD\t\($o[-1].runs[0] | cname): runs from \($tied | length) check suites share the newest start time \($top) (\([$tied[].runs[] | lbl] | join("; "))), so which run is current is unknown"
        else $o[-1].runs as $cur | [$o[:-1][].runs[]] as $old | ($cur | all(success)) as $supersedes
          | ($cur[] | if green then empty else "BAD\t\(lbl)\(when), the current run" end),
            ($old[] | if $supersedes or green then "OLD\t\(lbl)\(when)"
                      else "BAD\t\(lbl)\(when): the newer run is not SUCCESS (\([$cur[] | lbl] | join("; "))), so it does not supersede this one" end)
        end
    end'

# gmg_checks_green <shown> <owner> <repo> <head> : returns 0 when every judged
# run on <head> is green; exits 3 otherwise.
gmg_checks_green() {
  local shown="$1" owner="$2" repo="$3" head="$4" rollup err rc why shape judged kind text bad="" old="" n_old=0 odd=""
  local rfix="make the head's checks readable (network up, the right -R <owner>/<repo>), then $GMG_SAFE_PATH"
  err="$(mktemp)"
  if rollup="$(gh api graphql -f query="$GMG_ROLLUP_QUERY" -f owner="$owner" -f repo="$repo" -f oid="$head" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  if [ "$rc" != 0 ]; then
    gmg_refuse "$shown" "could not read the checks on head $head (\`gh api graphql\` statusCheckRollup exit $rc: ${why:-no stderr}${rollup:+; body $(head -c 300 <<<"$rollup" | tr '\n' ' ')}), so nothing shows it green" \
      "$rfix"
  fi
  if ! shape="$(jq -r "$GMG_ROLLUP_SHAPE" <<<"$rollup" 2>/dev/null)"; then
    shape="ERR"$'\t'"the answer is not the expected JSON: $(head -c 200 <<<"$rollup" | tr '\n' ' ')"
  fi
  case "$shape" in
    OK) ;;
    EMPTY) gmg_refuse "$shown" "no check has reported on head $head, so nothing shows it green" \
             "wait for CI to report on $head (\`~/dev/custom/ai/bin/gh-ci-wait --repo <owner>/<repo> --sha <head>\`), then $GMG_SAFE_PATH" ;;
    *) gmg_refuse "$shown" "could not read the checks on head $head: ${shape#ERR$'\t'}, so nothing shows it green" "$rfix" ;;
  esac
  if ! judged="$(jq -r "$GMG_ROLLUP_JUDGE" <<<"$rollup" 2>&1)"; then
    gmg_refuse "$shown" "the checks on head $head could not be judged: $GMG_TOOL's own rollup judge failed (jq: $(tr '\n' ' ' <<<"$judged"))" \
      "this is a defect in ai/lib/gh-merge-guard.sh, not in the PR; do not merge, and report this output to your admiral so it is ticketed"
  fi
  # Every line must be BAD or OLD; anything else is refused, never skipped.
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    text="${kind#*$'\t'}"
    case "$kind" in
      BAD$'\t'*) bad+="    $text"$'\n' ;;
      OLD$'\t'*) old+="    $text"$'\n'; n_old=$((n_old + 1)) ;;
      *) odd+="    $kind"$'\n' ;;
    esac
  done <<<"$judged"
  if [ -n "$odd" ]; then
    gmg_refuse "$shown" "the rollup judge for head $head printed lines it has no meaning for:
${odd%$'\n'}" \
      "this is a defect in ai/lib/gh-merge-guard.sh, not in the PR; do not merge, and report this output to your admiral so it is ticketed"
  fi
  if [ -n "$bad" ]; then
    gmg_refuse "$shown" "not every check on head $head is green (a run superseded by a newer SUCCESS run of the same check is not judged):
${bad%$'\n'}${old:+
  superseded runs, not judged:
${old%$'\n'}}" \
      "wait for these to conclude (\`~/dev/custom/ai/bin/gh-ci-wait --repo <owner>/<repo> --sha <head>\`) and fix any red one. A run with no start time is queued: wait for it to start. A tie for the newest start time needs a fresh run on a new commit. Then $GMG_SAFE_PATH"
  fi
  printf '%s: CHECKS head %s: every judged run is green; %s superseded run(s) not judged%s\n' \
    "$GMG_TOOL" "$head" "$n_old" "${old:+:
${old%$'\n'}}" >&2
  return 0
}

# gmg_guard <gh args...> : the entry point. Returns 0 or exits 3.
gmg_guard() {
  local shown="gh $*" pr_json err rc url owner repo base head n_prot n_rules w
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
  if pr_json="$(gh "${view[@]}" --json number,url,baseRefName,headRefOid 2>"$err")"; then rc=0; else rc=$?; fi
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
    if [ "$(( n_prot + n_rules ))" -gt 0 ]; then
      gmg_receipt_gate "$shown" "$owner" "$repo" "$base" ""
      return 0
    fi
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
  gmg_checks_green "$shown" "$owner" "$repo" "$head"
  gmg_receipt_gate "$shown" "$owner" "$repo" "$base" "$head"
  return 0
}
