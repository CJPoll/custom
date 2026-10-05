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
#   * A merge onto a base tip whose own CI or deploy run is RED, or whose tree
#     holds what ai/config/main-content-checks.json forbids (a duplicated
#     migration version), is REFUSED (stop the line, DND-1902), unless the
#     pinned head contains that tip and removes every duplicate (a red-main
#     fix). What cannot be read is COULD NOT LOOK and refused; a pending run
#     is not red. See gmg_line_check. glab-athena's guard
#     (ai/lib/glab-merge-guard.sh) loads this file and runs the same
#     gmg_line_check and content judge on GitLab, with its own pipelines
#     read as the runs judge (DND-1941).
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
# Residual of the receipt check (DND-969): a repo that declares no gate on its
# base tip is not checked at all. The receipt is a local file, but a written
# one no longer passes: ir_read_receipt verifies its seal (DND-1814). OPEN,
# both DND-1808's: (a) the sealer is an oracle to any same-uid process, so
# code running as this user that invokes the sealer (ai/bin/receipt-seal
# seal) or reads the seal key can still forge one this guard accepts; (b)
# gen_saas's gate cannot be sandboxed, so its branch code has that access. Since
# DND-1463 a receipt on an older base the tip descends from is accepted, so the
# head combined with the base's newer commits was never gated; GitHub's squash
# refuses only a textual conflict. The owner accepted that risk for velocity
# (2026-10-01). locked-merge also checks the landed tree and that the head
# contains the receipt's base; this guard does neither, because the pinned head
# need not be in the local object store. integration-gate records only a base
# the head contains, and a hand-written receipt does not verify (DND-1814), so
# only a deliberate forger (one that runs the sealer or reads its key) meets
# that gap.
#
# **Later (2026-10-02, DND-1814):** this residual said any local actor can
# write a receipt, "the same trust level as critic-verdicts". Narrowed, not
# closed: both receipt kinds are sealed and every reader verifies the seal, so
# a merely written receipt is refused; deliberate forgery stays open (DND-1808).
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
  echo "${GMG_TOOL:-gh-athena}: REFUSING: cannot load ai/lib/forge-api-scan.sh, so no merge can be judged." >&2
  echo "  Fix: run ${GMG_TOOL:-gh-athena} from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

# The integration-gate receipt and gate-declaration rules, shared with
# integration-gate and locked-merge so the three cannot drift (DND-969).
# shellcheck source=integration-receipt.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/integration-receipt.sh" || {
  echo "${GMG_TOOL:-gh-athena}: REFUSING: cannot load ai/lib/integration-receipt.sh, so no merge can be judged." >&2
  echo "  Fix: run ${GMG_TOOL:-gh-athena} from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

GMG_TOOL="${GMG_TOOL:-gh-athena}"
GMG_IS_MERGE=0
GMG_BASE_TIP=""
GMG_ESCALATE='Never merge or move a branch around this (a bare `gh pr merge`, a `gh api` merge or ref write, or the owner'"'"'s token); if the checks cannot go green, escalate to your admiral with the PR number and this output.'
# The one recommended merge path (DND-969): integration-gate, then locked-merge,
# which makes the pinned `pr merge` call itself under the repo's merge lock.
GMG_MB="~/dev/custom/ai/skills/athena:merge-boarding/scripts"
GMG_LAND="run \`$GMG_MB/integration-gate\` on the PR's head from a checkout of its repo, then land it with \`$GMG_MB/locked-merge --pr <n> --head <the SHA its INTEGRATION OK line names>\` (athena:merge-boarding -> Landing onto a moving main)"
GMG_SAFE_PATH="wait until every check on the PR's exact head SHA is green (\`~/dev/custom/ai/bin/gh-ci-wait --repo <owner>/<repo> --sha <head>\`), then $GMG_LAND"

# gh's own top-level commands (gh 2.83). A first word outside this list may be
# an alias, which is expanded and checked.
GMG_BUILTINS=" agent-task alias api attestation auth browse cache codespace completion config copilot extension gist gpg-key help issue label org pr preview project release repo ruleset run search secret ssh-key status variable version workflow "

# GMG_REFUSE_WORD is the word every guard refusal carries. gmg_refuse prints
# `<tool>: <word> `<what>`: <why>`, and gmg_refusal_has_reason reads that shape
# back, so the format has one home (DND-1908): a merge tool that classifies a
# refusal calls the reader and never spells the word or the shape itself.
GMG_REFUSE_WORD="REFUSING"

gmg_refuse() {
  # $1 what was refused, $2 why (may be multi-line), $3 the Fix: text
  printf '%s: %s `%s`: %s\n  Fix: %s. %s\n' "$GMG_TOOL" "$GMG_REFUSE_WORD" "$1" "$2" "$3" "$GMG_ESCALATE" >&2
  exit 3
}

# gmg_refusal_has_reason <stderr-file> <mark> : true when a guard refusal in the
# file opens its reason with <mark>, a line shaped
# `<tool>: <word> `<what>`: <mark>...` as gmg_refuse prints it. A mark inside
# the refused command text, or opening a later line of the reason, is no match.
# An unreadable file or an empty mark is false.
gmg_refusal_has_reason() {
  local line rest
  [ -r "$1" ] && [ -n "$2" ] && [ -n "${GMG_REFUSE_WORD}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      *": ${GMG_REFUSE_WORD} \`"*) ;;
      *) continue ;;
    esac
    rest="${line#*": ${GMG_REFUSE_WORD} \`"}"
    case "${rest}" in
      *"\`: "*) rest="${rest#*"\`: "}" ;;
      *) continue ;;
    esac
    [[ "${rest}" == "$2"* ]] && return 0
  done < "$1"
  return 1
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

# `gh api` flags, the table for fas_parse_api (ai/lib/forge-api-scan.sh, the
# argv parser shared with glab-athena's guard since DND-742). The table itself
# is FAS_GH_API_* there, shared with the outbound scan (DND-2007).
GMG_API_VALUED="$FAS_GH_API_VALUED"
GMG_API_BOOL="$FAS_GH_API_BOOL"
GMG_API_SVALUED="$FAS_GH_API_SVALUED"
GMG_API_SBOOL="$FAS_GH_API_SBOOL"

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
  local look="${GMG_LOOK_MARK} $GMG_TOOL cannot tell whether $owner/$repo declares an integration gate"
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
  # The tip the red-tip check (gmg_tip_gate, DND-1902) judges: the same read.
  GMG_BASE_TIP="$tip"
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
GMG_ROLLUP_QUERY='query($owner: String!, $repo: String!, $oid: GitObjectID!) { repository(owner: $owner, name: $repo) { object(oid: $oid) { __typename ... on Commit { statusCheckRollup { contexts(first: 100) { totalCount pageInfo { hasNextPage } nodes { __typename ... on CheckRun { name status conclusion startedAt detailsUrl checkSuite { databaseId app { databaseId slug } workflowRun { event workflow { databaseId } } } } ... on StatusContext { context state createdAt targetUrl } } } } } } } }'

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

# The definitions both judges share: the head's (GMG_ROLLUP_JUDGE) and the
# base tip's (GMG_TIP_JUDGE, DND-1902), so a run's identity, order and colour
# are read one way. by_identity turns the rollup into one array per check
# identity, holding that identity's runs grouped by check suite.
GMG_ROLLUP_DEFS='
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
  def by_identity:
    [.data.repository.object.statusCheckRollup.contexts.nodes | to_entries[] | .key as $i | .value
      | {k: key($i), s: suite($i), v: .}]
    | group_by(.k)[]
    | [group_by(.s)[] | map(.v)];
'

# The judgment. One line per run or finding: BAD<TAB><text> for a run that is
# judged and not green, or a check whose order cannot be read; OLD<TAB><text>
# for a superseded run. The caller refuses on any other line.
GMG_ROLLUP_JUDGE="$GMG_ROLLUP_DEFS"'
  by_identity as $suites
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

# ---- stop the line: the base tip's own runs (DND-1902) ----------------------
# The defect: on 2026-10-03 gen_saas main went red at 14:06Z (a duplicate
# migration version), and an admiral landed another PR onto it at 14:23Z,
# because the stop-the-line message reached it a minute late. Nothing in the
# merge path read the base tip's own CI or deploy runs. custom has the
# mechanical form (ai/bin/main-health's red marker, refused by `gh-athena git
# push`); GitHub-repo merges had none.
#
# So every merge (this guard, and locked-merge, which calls gmg_tip_health
# under its lock) reads the rollup of the base tip itself, the same GraphQL
# read and the same run identity and superseding rules as the head's checks.
# A push run (CI or a post-merge deploy) reports its checks on that commit.
#   * RED: a judged run concluded red (a CheckRun COMPLETED and not
#     SUCCESS/NEUTRAL/SKIPPED, a StatusContext FAILURE/ERROR), and it is not
#     superseded by a newer suite whose runs of that check are all SUCCESS.
#     Refused, naming every red run and its URL, unless the head CONTAINS the
#     tip: a red-main fix, custom's rule. Containment is read from the local
#     object store when both commits are there, else from the forge's compare.
#   * PENDING: a run has not concluded. NOT red, so the merge proceeds at once
#     and names the runs. Holding on pending would block every merge for the
#     length of a deploy, and a pending run that turns red is caught by the
#     next merge's read.
#   * Unreadable (the rollup, its shape, the judge, or containment of a red
#     tip): COULD NOT LOOK, refused, never green, and never reported as red.
#   * No check reported on the tip (a repo with no CI, custom's shape): not
#     red; the merge proceeds as before and says so.
# No flag or env var skips it (~/dev/custom/CLAUDE.md -> "A check's own bar must
# not live in the diff it is checking").
#
# Residuals (named, not closed): a merge onto a PENDING tip that then turns
# red lands onto a red main, and its own merge commit is pending in turn; a
# failed attempt re-run inside the SAME check suite still reads red (the
# head judge's residual too), so the tip stays red until a new commit or a
# fix; a red run beyond the rollup's first 100 contexts is COULD NOT LOOK.
# For a red RUN, containing the tip is the only fix evidence read (the brief's
# rule, mirroring custom's push rule): a head rebased onto the red tip for
# any reason passes as a fix. That is sound where the receipt's gate re-runs
# the red check (custom); a deploy never runs on a PR, so for a red deploy the
# merger must judge that the head fixes it. The content half asks more: the
# head's own tree must drop every duplicate. The content declaration is read
# from the custom checkout this file is loaded from, so a custom branch that
# edits it moves the bar for merges run from that branch's copy.
GMG_TIP_JUDGE="$GMG_ROLLUP_DEFS"'
  def known: .__typename == "StatusContext" or .__typename == "CheckRun";
  def red:
    if .__typename == "StatusContext" then (.state // "") | IN("FAILURE", "ERROR")
    elif .__typename == "CheckRun" then .status == "COMPLETED" and (green | not)
    else false end;
  def pending:
    if .__typename == "StatusContext" then ((.state // "") | IN("SUCCESS", "FAILURE", "ERROR")) | not
    elif .__typename == "CheckRun" then .status != "COMPLETED"
    else false end;
  def url: (if .__typename == "StatusContext" then .targetUrl else .detailsUrl end) // "" | tostring;
  def tlbl: "\(lbl)\(when)\(if url == "" then "" else " \(url)" end)";
  def judge($why):
    if (known | not) then "ODD\t\(lbl)"
    elif red then "RED\t\(tlbl)\($why)"
    elif pending then "PEND\t\(tlbl)"
    else empty end;
  by_identity as $suites
  | if ($suites | length) == 1 then ($suites[0][] | judge(""))
    elif ([$suites[][] | ts | ts_ok] | all | not) then
      ($suites[][] | judge(": runs from \($suites | length) check suites, and their order cannot be read, so this run is not shown superseded"))
    else ($suites | map({t: (map(ts) | max), runs: .}) | sort_by(.t)) as $o
      | ($o[-1].t) as $top | [$o[] | select(.t == $top)] as $tied
      | if ($tied | length) > 1 then
          ($o[].runs[] | judge(": runs from \($tied | length) check suites share the newest start time \($top), so this run is not shown superseded"))
        else $o[-1].runs as $cur | [$o[:-1][].runs[]] as $old | ($cur | all(success)) as $supersedes
          | ($cur[] | judge(", the current run")),
            ($old[] | if (known | not) then "ODD\t\(lbl)"
                      elif (red | not) then empty
                      elif $supersedes then "OLD\t\(tlbl)"
                      else "RED\t\(tlbl): the newer run is not SUCCESS (\([$cur[] | lbl] | join("; "))), so it does not supersede this one" end)
        end
    end'

# gmg_tip_health <owner> <repo> <tip> <head|""> <gitdir> : judges the base
# tip's own runs. Never exits. Sets GMG_TIP_STATE to NONE, CLEAN, PENDING or FIX
# (return 0, the merge may proceed), RED (return 1) or LOOK (return 2), with
# GMG_TIP_RUNS (the red runs, then the pending ones, one per line), GMG_TIP_OLD
# (superseded red runs) and GMG_TIP_WHY (the reason, for LOOK). An empty head
# (`--auto`) can never be a red-main fix. It reads with `gh`, so the caller
# sets the identity, and containment from git in <gitdir> when it can.
gmg_tip_health() {
  local owner="$1" repo="$2" tip="$3" head="$4" gitdir="$5" rollup err rc why shape judged line red="" pend="" odd="" cmp behind
  GMG_TIP_STATE="LOOK" GMG_TIP_RUNS="" GMG_TIP_OLD="" GMG_TIP_WHY=""
  if ! [[ "$tip" =~ ^[0-9a-f]{40}$ ]]; then
    GMG_TIP_WHY="the base tip '$tip' is not a full SHA"; return 2
  fi
  if ! err="$(mktemp)"; then GMG_TIP_WHY="mktemp failed, so the tip's runs could not be read"; return 2; fi
  if rollup="$(gh api graphql -f query="$GMG_ROLLUP_QUERY" -f owner="$owner" -f repo="$repo" -f oid="$tip" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  if [ "$rc" != 0 ]; then
    GMG_TIP_WHY="the runs on $tip could not be read (\`gh api graphql\` statusCheckRollup exit $rc: ${why:-no stderr})"; return 2
  fi
  if ! shape="$(jq -r "$GMG_ROLLUP_SHAPE" <<<"$rollup" 2>/dev/null)"; then
    shape="ERR"$'\t'"the answer is not the expected JSON: $(head -c 200 <<<"$rollup" | tr '\n' ' ')"
  fi
  case "$shape" in
    OK) ;;
    EMPTY) GMG_TIP_STATE="NONE"; return 0 ;;
    *) GMG_TIP_WHY="the runs on $tip could not be read: ${shape#ERR$'\t'}"; return 2 ;;
  esac
  if ! judged="$(jq -r "$GMG_TIP_JUDGE" <<<"$rollup" 2>&1)"; then
    GMG_TIP_WHY="the tip judge in ai/lib/gh-merge-guard.sh failed (jq: $(tr '\n' ' ' <<<"$judged")); a defect in the guard, not in the PR"; return 2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      RED$'\t'*) red+="    ${line#*$'\t'}"$'\n' ;;
      PEND$'\t'*) pend+="    ${line#*$'\t'}"$'\n' ;;
      OLD$'\t'*) GMG_TIP_OLD+="    ${line#*$'\t'}"$'\n' ;;
      *) odd+="    $line"$'\n' ;;
    esac
  done <<<"$judged"
  if [ -n "$odd" ]; then
    GMG_TIP_WHY="the tip judge printed lines it has no meaning for (a context of a type it does not know, or a defect in ai/lib/gh-merge-guard.sh):
${odd%$'\n'}"; return 2
  fi
  if [ -z "$red" ]; then
    GMG_TIP_RUNS="${pend%$'\n'}"
    if [ -n "$pend" ]; then GMG_TIP_STATE="PENDING"; else GMG_TIP_STATE="CLEAN"; fi
    return 0
  fi
  GMG_TIP_RUNS="${red%$'\n'}"
  GMG_TIP_STATE="RED"
  [ -n "$head" ] || return 1
  # Does the head contain the red tip? The commit graph answers when both
  # commits are local (exit 0 yes, 1 no); anything else asks the forge.
  if git -C "$gitdir" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0) GMG_TIP_STATE="FIX"; return 0 ;;
    1) return 1 ;;
  esac
  if ! err="$(mktemp)"; then
    GMG_TIP_STATE="LOOK"; GMG_TIP_WHY="$tip is red, and mktemp failed, so whether the head $head contains it could not be read"; return 2
  fi
  if cmp="$(gh api "repos/$owner/$repo/compare/$tip...$head" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  behind="$(jq -r 'if (.behind_by | type) == "number" then .behind_by else empty end' <<<"$cmp" 2>/dev/null)" || behind=""
  if [ "$rc" != 0 ] || ! [[ "$behind" =~ ^[0-9]+$ ]]; then
    GMG_TIP_STATE="LOOK"
    GMG_TIP_WHY="$tip is red (${GMG_TIP_RUNS#    }), and whether the head $head contains it could not be read (\`gh api repos/$owner/$repo/compare/$tip...$head\` exit $rc: ${why:-body '$(head -c 200 <<<"$cmp" | tr '\n' ' ')'})"
    return 2
  fi
  if [ "$behind" = 0 ]; then GMG_TIP_STATE="FIX"; return 0; fi
  return 1
}

# ---- stop the line: the base tip's CONTENT (DND-1902) -----------------------
# A green run is not enough. gen_saas main runs only its post-merge deploy, not
# the suite, and on 2026-10-03 9374d81c's deploy reported SUCCESS ("Migrations
# already up") while main held two athena migrations with one version. So the
# tip's TREE is read too, against what ai/config/main-content-checks.json
# declares for the repo. The declaration lives in custom, never in the repo
# whose merge it judges (~/dev/custom/CLAUDE.md -> "A check's own bar must not
# live in the diff it is checking"). One check kind exists:
#   unique_migration_dirs (ERE on a directory path): in every matching
#   directory, two files <digits>_*.exs with the same digits are RED.
# A red-main fix is a head that contains the tip AND whose own tree no longer
# holds the duplicate (a merge of a head that contains the tip lands the
# head's tree). In a repo that declares an integration gate, the receipt gate
# has already required the head's own INTEGRATION OK receipt.
GMG_CONTENT_CONFIG="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../config/main-content-checks.json"

# gmg_mig_dups <gitdir> <rev> <dir-ere> : reads <rev>'s tree (a commit or a
# tree id). Sets GMG_DUPS (one line per duplicated version, "<dir> version
# <v>: <file>, <file>", sorted), GMG_DUP_NDIRS (directories the ERE matched)
# and GMG_DUP_NFILES (migrations read). Returns 0, 2 when the tree cannot be
# read, or 3 when the ERE matched NO directory: a declared check that finds
# nothing to read is never read as clean (a path move or a typo in the ERE).
gmg_mig_dups() {
  local gitdir="$1" rev="$2" re="$3" tree path dir base v key
  local -A files=() dirs=()
  GMG_DUPS="" GMG_DUP_NDIRS=0 GMG_DUP_NFILES=0
  # NUL-separated, so a path git would quote is read as itself.
  if ! tree="$(git -C "$gitdir" ls-tree -r -z --name-only "$rev" 2>/dev/null | tr '\0' '\n')"; then return 2; fi
  [ -n "$tree" ] || return 2
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    dir="${path%/*}"; [ "$dir" != "$path" ] || dir=""
    [[ "$dir" =~ $re ]] || continue
    dirs["$dir"]=1
    base="${path##*/}"
    [[ "$base" =~ ^([0-9]+)_.*\.exs$ ]] || continue
    v="${BASH_REMATCH[1]}"
    key="$dir version $v"
    files["$key"]+="${files[$key]:+, }$base"
    GMG_DUP_NFILES=$((GMG_DUP_NFILES + 1))
  done <<<"$tree"
  GMG_DUP_NDIRS="${#dirs[@]}"
  [ "$GMG_DUP_NDIRS" -gt 0 ] || return 3
  for key in "${!files[@]}"; do
    if [[ "${files[$key]}" == *", "* ]]; then GMG_DUPS+="$key: ${files[$key]}"$'\n'; fi
  done
  if [ -n "$GMG_DUPS" ]; then GMG_DUPS="$(sort <<<"${GMG_DUPS%$'\n'}")"; fi
  return 0
}

# GMG_CONTENT_LOOKUP: the jq program gmg_content_re runs over the declaration
# (main-content-checks/2), with -n so it reads every document itself. It
# validates the WHOLE file (exactly one document, every entry's name, paths
# and ERE, no path claimed twice), not only the entry it finds, then prints
# three lines: HIT, the entry's name and its ERE ("" when
# it declares no content check); NEAR, the declared names whose project name
# is the key's, and their paths; or NONE.
GMG_CONTENT_LOOKUP='
  def one_doc: [inputs] as $docs
    | if ($docs | length) != 1 then error("the file holds \($docs | length) JSON documents, not one") else $docs[0] end;
  # \A and \z, never ^ and $: in jq (Oniguruma) $ also matches before a
  # trailing newline, so "gen_saas\n" would pass a ^...$ test.
  def path_ok: type == "string" and test("\\A[a-z0-9._-]+(/[a-z0-9._-]+)+\\z");
  def entry_ok: type == "object" and (keys - ["paths", "unique_migration_dirs"]) == [] and has("paths")
    and (.paths | type) == "array" and (.paths | length) > 0 and (.paths | map(path_ok) | all)
    and ((has("unique_migration_dirs") | not)
         or ((.unique_migration_dirs | type) == "string" and .unique_migration_dirs != "" and (.unique_migration_dirs | test("\n") | not)));
  one_doc
  | if .schema != "main-content-checks/2" then error("schema is not main-content-checks/2")
  elif (.repos | type) != "object" then error("repos is not an object")
  else (.repos | to_entries) as $e
    | ($e | map(select((.key | test("\\A[a-z0-9._-]+\\z") | not) or (.value | entry_ok | not)) | .key)) as $bad
    | if ($bad | length) > 0 then error("the entry \($bad | map(tojson) | join(", ")) is not a lower-case project name holding {\"paths\": [\"<lower-case project path>\", ...], \"unique_migration_dirs\"?: \"<ERE>\"}")
      elif ([$e[].value.paths[]] | group_by(.) | map(select(length > 1)[0]) | length) > 0
        then error("project path(s) \([$e[].value.paths[]] | group_by(.) | map(select(length > 1)[0]) | join(", ")) are declared by more than one entry or twice")
      else ($k | split("/") | last) as $name
        | [$e[] | select(.value.paths | index($k))] as $hit
        | if ($hit | length) == 1 then "HIT", $hit[0].key, ($hit[0].value.unique_migration_dirs // "")
          else [$e[] | select(.key == $name or (.value.paths | map(split("/") | last) | index($name)))] as $near
            | if ($near | length) > 0 then "NEAR", ($near | map(.key) | join(", ")), ([$near[].value.paths[]] | join(", "))
              else "NONE", "", "" end
          end
      end
  end'

# gmg_content_re <owner> <repo> : sets GMG_CONTENT_KEY to the key it looks up
# (lower-case <owner>/<repo>), GMG_CONTENT_ENTRY to the declared product whose
# paths list it ("" when none does), and GMG_CONTENT_RE to that entry's
# unique_migration_dirs ERE, or "" when it declares none. Returns 2 with
# GMG_CONTENT_WHY when the declaration cannot be read or is malformed, when the
# key itself is malformed, or when the key is an undeclared path of a declared
# product (DND-2034). Both forges share it (DND-1941): on GitHub <owner> is the
# account; on GitLab it is the project's namespace path, which may hold more
# than one segment (a nested group), so the key is the full project path.
# An empty segment or whitespace is an error, never "no check declared": a
# wrongly computed key would otherwise match nothing and read as a repo with
# no checks. So is a declared product's name under a path its entry does not
# list: gen_saas moved from cjpoll/ to athena-ai-harness/ (one GitLab
# project), the declaration listed only the old path, and every merge on the
# new one skipped the migration check with exit 0. The rule matches on the
# last path segment, so it catches a namespace move or a stale path, not a
# rename of the project itself: a renamed project's new path is landed in the
# declaration before its first merge, and nothing detects a rename.
gmg_content_re() {
  local key="${1,,}/${2,,}" out kind="" name="" re="" declared
  GMG_CONTENT_RE="" GMG_CONTENT_KEY="$key" GMG_CONTENT_ENTRY=""
  if ! [[ "$key" =~ ^[^/[:space:]]+(/[^/[:space:]]+)+$ ]]; then
    GMG_CONTENT_WHY="the repo key '$key' (owner '$1', repo '$2') is malformed (an empty segment or whitespace), so which content checks it declares cannot be looked up"; return 2
  fi
  if ! out="$(jq -n -r --arg k "$key" "$GMG_CONTENT_LOOKUP" "$GMG_CONTENT_CONFIG" 2>&1)"; then
    GMG_CONTENT_WHY="the content declaration $GMG_CONTENT_CONFIG cannot be read: $(tr '\n' ' ' <<<"$out")"; return 2
  fi
  # $(...) strips trailing empty lines, so a short read is normal: || : keeps
  # it from tripping a caller's set -e.
  { IFS= read -r kind; IFS= read -r name; IFS= read -r re; } <<<"$out" || :
  case "$kind" in
    HIT) GMG_CONTENT_ENTRY="$name" ;;
    NONE) return 0 ;;
    NEAR)
      declared="$re"
      GMG_CONTENT_WHY="the project $key is not declared in $GMG_CONTENT_CONFIG, but its name '${key##*/}' is the declared product '$name' (declared paths: $declared), so its content check would be skipped silently (a project moved to another namespace, or a stale path, DND-2034). If $key is that product, add it to that entry's paths (a change that lands on custom main). If it is another project of the same name, declare it as its own entry with its own paths"
      return 2 ;;
    *) GMG_CONTENT_WHY="the content lookup over $GMG_CONTENT_CONFIG printed '$kind', not HIT, NEAR or NONE (a defect in ai/lib/gh-merge-guard.sh)"; return 2 ;;
  esac
  if [ -n "$re" ] && { [[ "" =~ $re ]]; [ $? = 2 ]; }; then
    GMG_CONTENT_WHY="the unique_migration_dirs pattern for $name ($key) in $GMG_CONTENT_CONFIG is not a valid ERE ('$re')"; return 2
  fi
  GMG_CONTENT_RE="$re"
  return 0
}

# gmg_content_none_note : what a NONE content state says. A declared product
# with no check is told apart from a key no entry lists (DND-2034).
gmg_content_none_note() {
  if [ -n "${GMG_CONTENT_ENTRY:-}" ]; then
    printf 'the declared product %s (%s) declares no content check' "$GMG_CONTENT_ENTRY" "$GMG_CONTENT_KEY"
  else
    printf 'no check declared for %s (no entry lists it, and no declared product has its name)' "$GMG_CONTENT_KEY"
  fi
}

# gmg_dups_why <rc> <what> : GMG_CONTENT_WHY for a gmg_mig_dups failure.
gmg_dups_why() {
  case "$1" in
    3) GMG_CONTENT_WHY="the unique_migration_dirs pattern '$GMG_CONTENT_RE' in $GMG_CONTENT_CONFIG matches no directory in $2, so the declared check has nothing to read (a moved path or a wrong ERE; fix the declaration)" ;;
    *) GMG_CONTENT_WHY="the tree of $2 cannot be read (\`git ls-tree -r\` failed; fetch origin so it is local)" ;;
  esac
}

# gmg_content_health <owner> <repo> <tip> <head|""> <gitdir> : judges the base
# tip's content. Never exits. Sets GMG_CONTENT_STATE to NONE (no check
# declared), CLEAN or FIX (return 0), RED (return 1) or LOOK (return 2), with
# GMG_CONTENT_DUPS and GMG_CONTENT_WHY.
gmg_content_health() {
  local owner="$1" repo="$2" tip="$3" head="$4" gitdir="$5" rc
  GMG_CONTENT_STATE="LOOK" GMG_CONTENT_DUPS="" GMG_CONTENT_WHY="" GMG_CONTENT_COUNTS=""
  gmg_content_re "$owner" "$repo" || return 2
  if [ -z "$GMG_CONTENT_RE" ]; then GMG_CONTENT_STATE="NONE"; return 0; fi
  if gmg_mig_dups "$gitdir" "$tip" "$GMG_CONTENT_RE"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then gmg_dups_why "$rc" "the tip $tip"; return 2; fi
  GMG_CONTENT_COUNTS="$GMG_DUP_NDIRS director(ies), $GMG_DUP_NFILES migration(s) read"
  if [ -z "$GMG_DUPS" ]; then GMG_CONTENT_STATE="CLEAN"; return 0; fi
  GMG_CONTENT_DUPS="$(sed 's/^/    /' <<<"$GMG_DUPS")"
  GMG_CONTENT_STATE="RED"
  [ -n "$head" ] || return 1
  if git -C "$gitdir" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) GMG_CONTENT_STATE="LOOK"
       GMG_CONTENT_WHY="the tip $tip holds a duplicated migration version, and the head $head is not in the object store of $gitdir, so whether it is a fix cannot be read (fetch the PR branch)"
       return 2 ;;
  esac
  if gmg_mig_dups "$gitdir" "$head" "$GMG_CONTENT_RE"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    GMG_CONTENT_STATE="LOOK"; gmg_dups_why "$rc" "the head $head"; return 2
  fi
  if [ -n "$GMG_DUPS" ]; then
    GMG_CONTENT_DUPS+=$'\n'"  the head $head contains the tip but still holds:"$'\n'"$(sed 's/^/    /' <<<"$GMG_DUPS")"
    return 1
  fi
  GMG_CONTENT_STATE="FIX"; return 0
}

# GMG_RED_MARK opens a red-tip refusal's reason. The merge tool reads it back
# from the guard's stderr to tell a red tip from the guard's other exit-3
# refusals (DND-1906), so the guard and the tool share this one constant. It
# reads it with gmg_refusal_has_reason, anchored on the refusal's own shape
# (DND-1908).
GMG_RED_MARK="MAIN RED:"
# GMG_LOOK_MARK opens a COULD NOT LOOK refusal's reason (DND-1907): the guard
# could not read the base tip's runs, tree or content, or whether the repo
# declares a gate. The merge tool reads it back like GMG_RED_MARK, so the two
# share this one constant.
GMG_LOOK_MARK="COULD NOT LOOK:"

# gmg_line_check <owner> <repo> <base> <tip> <head|""> <gitdir> [runs judge] :
# the whole stop-the-line judgment, the runs and the content
# (gmg_content_health). Never exits. Returns 0 (GMG_LINE_NOTE says why the
# merge may proceed), 1 RED or 2 COULD NOT LOOK (GMG_LINE_WHY says why). A red
# finding outranks a COULD NOT LOOK in the other half: either refuses.
#
# The runs judge is GitHub's gmg_tip_health unless [runs judge] names another
# function with its contract: called as `<judge> <owner> <repo> <tip> <head|"">
# <gitdir> <base>`, it sets GMG_TIP_STATE (NONE, CLEAN, PENDING or FIX: return
# 0; RED: return 1; LOOK: return 2), GMG_TIP_RUNS, GMG_TIP_OLD and GMG_TIP_WHY.
# glab-athena's guard passes glmg_tip_health, which judges the tip's GitLab
# pipelines (DND-1941); the content half and this composition are the same
# code on both forges. A judge that is not a defined function is COULD NOT
# LOOK, never a clean tip.
gmg_line_check() {
  local owner="$1" repo="$2" base="$3" tip="$4" head="$5" gitdir="$6" judge="${7:-gmg_tip_health}" rr cr
  GMG_LINE_NOTE="" GMG_LINE_WHY=""
  if ! declare -F "$judge" >/dev/null; then
    GMG_TIP_STATE="LOOK" GMG_TIP_RUNS="" GMG_TIP_OLD=""
    GMG_TIP_WHY="the runs judge '$judge' is not a defined function (a defect in the guard that called gmg_line_check)"; rr=2
  elif "$judge" "$owner" "$repo" "$tip" "$head" "$gitdir" "$base"; then rr=0; else rr=$?; fi
  if gmg_content_health "$owner" "$repo" "$tip" "$head" "$gitdir"; then cr=0; else cr=$?; fi
  if [ "$rr" = 1 ] || [ "$cr" = 1 ]; then
    GMG_LINE_WHY="${GMG_RED_MARK} $base tip $tip is RED, so the line is stopped (DND-1902)."
    [ "$rr" = 1 ] && GMG_LINE_WHY+=" Red run(s):
$GMG_TIP_RUNS${GMG_TIP_OLD:+
  superseded red runs, not judged:
${GMG_TIP_OLD%$'\n'}}"
    [ "$cr" = 1 ] && GMG_LINE_WHY+="
  Duplicated migration version(s) (ai/config/main-content-checks.json):
$GMG_CONTENT_DUPS"
    GMG_LINE_WHY+="
  The head ${head:-(none: --auto)} is not a red-main fix: it must contain $tip and remove every duplicate."
    [ "$rr" = 2 ] && GMG_LINE_WHY+="
  Also COULD NOT LOOK at the runs: $GMG_TIP_WHY"
    [ "$cr" = 2 ] && GMG_LINE_WHY+="
  Also COULD NOT LOOK at the content: $GMG_CONTENT_WHY"
    return 1
  fi
  if [ "$rr" = 2 ] || [ "$cr" = 2 ]; then
    GMG_LINE_WHY="${GMG_LOOK_MARK} whether the $base tip $tip is red cannot be told:"
    [ "$rr" = 2 ] && GMG_LINE_WHY+=" $GMG_TIP_WHY."
    [ "$cr" = 2 ] && GMG_LINE_WHY+=" $GMG_CONTENT_WHY."
    return 2
  fi
  case "$GMG_TIP_STATE" in
    NONE) GMG_LINE_NOTE="BASE-TIP $base $tip: no check has reported on it, so no run is red" ;;
    CLEAN) GMG_LINE_NOTE="BASE-TIP $base $tip: no judged run is red" ;;
    PENDING) GMG_LINE_NOTE="BASE-TIP $base $tip PENDING: no judged run is red, and these have not concluded; a pending run is not red, so this merge is not held:
$GMG_TIP_RUNS" ;;
    FIX) GMG_LINE_NOTE="BASE-TIP $base $tip is RED, and the head contains it: RED-MAIN FIX, merging onto the red tip. Containing the tip is the only evidence read for a red RUN, so this head must really fix it. Red run(s):
$GMG_TIP_RUNS" ;;
  esac
  case "$GMG_CONTENT_STATE" in
    NONE) GMG_LINE_NOTE+=$'\n'"  content: $(gmg_content_none_note)" ;;
    CLEAN) GMG_LINE_NOTE+=$'\n'"  content: no duplicated migration version ($GMG_CONTENT_COUNTS)" ;;
    FIX) GMG_LINE_NOTE+=$'\n'"  content: RED-MAIN FIX: the tip holds a duplicated migration version and the head removes it:"$'\n'"$GMG_CONTENT_DUPS" ;;
  esac
  GMG_LINE_NOTE+=" (DND-1902)"
  return 0
}

# gmg_line_fix <owner> <repo> <base> <tip> : the Fix: text for a RED tip.
gmg_line_fix() {
  printf 'land only a red-main fix: a head that contains %s, removes every duplicate named above, and (in a repo that declares an integration gate) carries its own INTEGRATION OK receipt (merge origin/%s into it, fix it, push as Athena, re-gate). Every other PR waits until %s is green again (`~/dev/custom/ai/bin/gh-ci-wait --repo %s/%s --sha <the new %s tip>`)' \
    "$4" "$3" "$3" "$1" "$2" "$3"
}

# gmg_tip_gate <shown> <owner> <repo> <base> <tip> <head|""> : returns 0 when
# the base tip does not stop the merge; exits 3 otherwise.
gmg_tip_gate() {
  local shown="$1" owner="$2" repo="$3" base="$4" tip="$5" head="$6" rc
  # GMG_TOP: the checkout gmg_receipt_gate resolved, which holds the tip.
  if gmg_line_check "$owner" "$repo" "$base" "$tip" "$head" "$GMG_TOP"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) printf '%s: %s\n' "$GMG_TOOL" "$GMG_LINE_NOTE" >&2; return 0 ;;
    1) gmg_refuse "$shown" "$GMG_LINE_WHY" "$(gmg_line_fix "$owner" "$repo" "$base" "$tip"). Then $GMG_LAND" ;;
    *) gmg_refuse "$shown" "$GMG_LINE_WHY" \
         "make the tip readable (network up, the right -R <owner>/<repo>, gh auth, \`git fetch origin\` in this checkout; an undeclared path of a declared product is added to that product's paths in ~/dev/custom/ai/config/main-content-checks.json, landed on custom main, DND-2034), then $GMG_LAND" ;;
  esac
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
      gmg_tip_gate "$shown" "$owner" "$repo" "$base" "$GMG_BASE_TIP" ""
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
  gmg_tip_gate "$shown" "$owner" "$repo" "$base" "$GMG_BASE_TIP" "$head"
  return 0
}
