# shellcheck shell=bash
#
# glab-seed-mirror.sh -- `glab-athena git seed-mirror` (DND-1983). Sourced by
# ai/bin/glab-athena after ai/lib/forge-git-passthrough.sh and
# ai/lib/forge-identity.sh; never run.
#
# Why: the first step of moving a repo from GitHub to GitLab is seeding the
# empty GitLab project's main. The ungated-main refusal (DND-1690,
# fg_refuse_ungated_main) refuses that push: a GitHub squash-merge SHA, or a
# tip landed by a clean rebase, has no integration-gate receipt of its own, and
# a fresh GitLab project has no landed main to judge a clean rebase against.
# This is the one sanctioned way past it, and only for that seed. It is not a
# skip flag: the push guard accepts the commit because THIS command proved,
# in-process and immediately before the push, every condition below.
#
# Usage: glab-athena git seed-mirror --to https://gitlab.com/<ns>/<project>.git
#                                    [--from origin]
# The source is the checkout's own origin, the GitHub project whose bar the
# commit already passed. Only `origin` is accepted for --from.
#
# It pushes <source main>:refs/heads/main to the target, as the target
# namespace's bot, only when ALL of these hold. Each refusal names its
# condition and carries Fix:, exit 3. A read that fails is COULD NOT LOOK and
# refuses; it is never read as "absent" or "fine".
#   1 TARGET        --to is https://gitlab.com/<ns>/<project>[.git], with no
#                   credentials, query or fragment, and the identity map
#                   (DND-1936) resolves its namespace to a bot.
#   2 POST-FLIP     origin does not reach gitlab.com (its URL, its resolved
#                   fetch URL, any push URL). Once the cutover flips origin to
#                   the GitLab project the mode refuses, so it cannot become a
#                   standing bypass.
#   3 SOURCE        origin's URL and resolved fetch URL are on github.com, and
#                   it names no remote.origin.vcs helper.
#   4 RED SOURCE    ai/bin/main-health has no RED marker for this checkout's
#                   origin/main (an unreadable marker refuses). No marker
#                   means no red is known, as for the red-main refusal.
#   5 FRESH SHA     the pushed SHA is origin's refs/heads/main as read by
#                   `git ls-remote` in this command; it must be in the local
#                   object store (the push sends it from there).
#   6 FAST-FORWARD  the target's main, read through the route in this command,
#                   is absent, or is a strict ancestor of the pushed SHA. The
#                   push carries no `+`, so the forge refuses a non-fast-forward
#                   too. Equal: nothing to push, exit 0.
# Then it runs `push <target> <sha>:refs/heads/main` through the same route as
# `glab-athena git push` (fg_refuse_non_https, fg_git_exec): every other check
# there still applies. Branches and tags are not this command's: push them with
# `glab-athena git push`, under the normal rules.
#
# The sanction: gsm_main sets FG_SEED_SHA and FG_SEED_URL, which
# forge-git-passthrough.sh resets to "" every time it is sourced, so a value in
# the caller's environment never reaches fg_refuse_ungated_main. That function
# accepts exactly FG_SEED_SHA pushed to exactly FG_SEED_URL, and nothing else.
# Residual, said out loud: a shell that sources the library itself and sets the
# variables is past this guard, as it is past every other one here, since it
# could run git directly; the agent PATH git wrapper (ai/lib/agent-forge-push.sh)
# is the layer that refuses a forge push outside the route.
#
# Test seams, honored ONLY under GLAB_ATHENA_GIT_DRY_RUN=1 (which never pushes)
# and refused otherwise: GLAB_ATHENA_SEED_SOURCE_READ and
# GLAB_ATHENA_SEED_TARGET_READ name a local repository that the source and the
# target ls-remote read instead of origin and the target URL. Every other check,
# the host checks on origin's configured URLs included, runs unchanged.

GSM_TO=""
GSM_FROM="origin"
GSM_SRC_SHA=""
GSM_TGT_SHA=""
GSM_OUTCOME=""
GSM_WHY=""
GSM_PUSH_ARGV=()

# gsm_refuse <CONDITION> <why> <fix> : print the refusal, exit 3.
gsm_refuse() {
  printf '%s: REFUSING `git seed-mirror` (%s): %s\n  Fix: %s %s\n' "$FG_TOOL" "$1" "$2" "$3" "$FG_ESCALATE" >&2
  exit 3
}

# gsm_cnl <what> <fix> : a read that failed. COULD NOT LOOK, never "absent".
gsm_cnl() { gsm_refuse "COULD NOT LOOK" "$1" "$2"; }

# gsm_parse_args <args...> : sets GSM_TO and GSM_FROM, or refuses.
gsm_parse_args() {
  GSM_TO="" GSM_FROM="origin"
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)   [ $# -ge 2 ] || gsm_refuse USAGE "--to needs a value" "pass --to https://gitlab.com/<namespace>/<project>.git."
              GSM_TO="$2"; shift 2 ;;
      --to=*) GSM_TO="${1#--to=}"; shift ;;
      --from) [ $# -ge 2 ] || gsm_refuse USAGE "--from needs a value" "drop --from (the source is origin) or pass --from origin."
              GSM_FROM="$2"; shift 2 ;;
      --from=*) GSM_FROM="${1#--from=}"; shift ;;
      *) gsm_refuse USAGE "'$1' is no option of seed-mirror (it takes --to <url> and an optional --from origin, nothing else)" \
           "run \`~/dev/custom/ai/bin/glab-athena git seed-mirror --to https://gitlab.com/<namespace>/<project>.git\`; push branches and tags with \`glab-athena git push\`." ;;
    esac
  done
  [ -n "$GSM_TO" ] || gsm_refuse USAGE "no --to: the GitLab project to seed is not named" \
    "pass --to https://gitlab.com/<namespace>/<project>.git."
  [ "$GSM_FROM" = origin ] || gsm_refuse SOURCE "--from '$GSM_FROM' is not origin; the source must be this checkout's origin, the forge whose bar its main passed" \
    "run it from a checkout whose origin is the GitHub project, without --from (or with --from origin)."
}

# gsm_judge_target_url <url> : pure. 0 when <url> is a plain
# https://<FG_HOST>/<ns>/<project>[.git]; else 1 with GSM_WHY.
gsm_judge_target_url() {
  local u="$1" rest path
  GSM_WHY=""
  case "$u" in
    "https://$FG_HOST/"*) ;;
    *) GSM_WHY="'$u' is not an https://$FG_HOST/ URL"; return 1 ;;
  esac
  case "$u" in
    *[[:space:]]*|*\?*|*\#*|*%*) GSM_WHY="'$u' holds whitespace, a query, a fragment or an encoded character"; return 1 ;;
  esac
  rest="${u#https://$FG_HOST/}"
  path="${rest%.git}"
  case "$path" in
    ''|*//*|/*|*/) GSM_WHY="'$u' names no <namespace>/<project> path"; return 1 ;;
    */*) ;;
    *) GSM_WHY="'$u' names no <namespace>/<project> path"; return 1 ;;
  esac
  return 0
}

# gsm_check_target : condition 1.
gsm_check_target() {
  gsm_judge_target_url "$GSM_TO" || gsm_refuse TARGET "$GSM_WHY" \
    "pass the project's plain URL: --to https://$FG_HOST/<namespace>/<project>.git."
  fid_resolve_url "$GSM_TO" || gsm_refuse TARGET "the identity map does not give $GSM_TO a bot: $FID_STATE: ${FID_WHY%.}" "$FID_FIX"
}

# gsm_host <url> : the lowercased host of <url>, empty for a local path.
gsm_host() { local sh; sh="$(fg_url_host_scheme "$1")"; [ -n "$sh" ] && printf '%s' "${sh#* }"; }

# gsm_check_origin : conditions 2 and 3.
gsm_check_origin() {
  local raw resolved rc=0 h u vcs pout
  local -a pushes=()
  raw="$(git config --get remote.origin.url 2>/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    1) gsm_refuse SOURCE "this checkout has no origin remote, so there is no source main to mirror" \
         "run it from the checkout whose origin is the GitHub project." ;;
    *) gsm_cnl "git config could not read remote.origin.url (exit $rc)" "repair this checkout's git config and retry." ;;
  esac
  resolved="$(git ls-remote --get-url origin 2>/dev/null)" \
    || gsm_cnl "git ls-remote --get-url origin failed" "repair this checkout's git config and retry."
  pout="$(git remote get-url --push --all origin 2>/dev/null)" \
    || gsm_cnl "git remote get-url --push origin failed" "repair this checkout's git config and retry."
  mapfile -t pushes <<<"$pout"
  [ -n "$pout" ] || gsm_cnl "git remote get-url --push origin listed no URL" "repair this checkout's git config and retry."
  for u in "$raw" "$resolved" "${pushes[@]}"; do
    h="$(gsm_host "$u")"
    case "$h" in
      "$FG_HOST"|*."$FG_HOST")
        gsm_refuse POST-FLIP "origin already reaches $FG_HOST ($(fid_shown "$u")): the cutover has flipped this checkout, and seed-mirror is a one-time step before that flip" \
          "nothing to seed from here. A main push to the GitLab project now needs integration-gate's receipt (\`integration-gate --with-critic --rebase\`, then \`glab-athena git push\`)." ;;
    esac
  done
  for u in "$raw" "$resolved"; do
    h="$(gsm_host "$u")"
    [ "$h" = github.com ] || gsm_refuse SOURCE "origin's URL $(fid_shown "$u") is not on github.com, so its main has not passed the GitHub bar this mirror relies on" \
      "run it from the checkout whose origin is the GitHub project (\`git remote get-url origin\` names github.com)."
  done
  rc=0; vcs="$(git config --get remote.origin.vcs 2>/dev/null)" || rc=$?
  case "$rc" in
    0) gsm_refuse SOURCE "remote.origin.vcs is '$vcs', so git reads origin through git-remote-$vcs, not from github.com" \
         "unset remote.origin.vcs in this checkout." ;;
    1) ;;
    *) gsm_cnl "git config could not read remote.origin.vcs (exit $rc)" "repair this checkout's git config and retry." ;;
  esac
}

# gsm_check_health : condition 4.
gsm_check_health() {
  local common rc=0
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$common" ] \
    || gsm_cnl "git rev-parse --git-common-dir failed, so the main-health marker cannot be found" "run it inside the checkout and retry."
  # shellcheck source=main-health.sh
  . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/main-health.sh" 2>/dev/null \
    || gsm_cnl "ai/lib/main-health.sh did not load, so whether origin/main is red is unknown" \
         "run glab-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)."
  mh_read_red "$common" || rc=$?
  case "$rc" in
    0) gsm_refuse "RED SOURCE" "main-health recorded origin/main RED at $MH_RED_SHA (since ${MH_RED_SINCE:-?}; record ${MH_RED_RECORD:-?}); a red main is not mirrored" \
         "land the fix on GitHub first, then refresh the verdict with \`~/dev/custom/ai/bin/main-health check --repo <this checkout>\` and retry." ;;
    1) printf '%s: note: main-health holds no red marker for this checkout (no red is known; an unchecked main is not a green one)\n' "$FG_TOOL" >&2 ;;
    *) gsm_cnl "the main-health marker cannot be read: $MH_WHY" \
         "inspect it (\`~/dev/custom/ai/bin/main-health status --repo <this checkout>\`), repair what it names, refresh it with \`main-health check\`, and retry." ;;
  esac
}

# gsm_seam <var> : sets GSM_SEAM to the seam's value when it may be used. A
# seam set outside a dry run refuses: it never redirects a read behind a real
# push. Called in the wrapper's own shell, never in $(...), so its refusal
# exits the command.
GSM_SEAM=""
gsm_seam() {
  GSM_SEAM="${!1:-}"
  [ -n "$GSM_SEAM" ] || return 0
  [ "${FG_DRY_RUN:-}" = 1 ] || gsm_refuse USAGE "$1 is set, a test seam honored only under GLAB_ATHENA_GIT_DRY_RUN=1" \
    "unset $1 and retry."
}

# gsm_main_of <ls-remote output> : pure. Sets GSM_MAIN to refs/heads/main's
# sha, or "" when absent; returns 2 with GSM_WHY on a malformed line. Called in
# the caller's shell (never in $(...)), so GSM_WHY reaches it.
GSM_MAIN=""
gsm_main_of() {
  local line sha ref
  GSM_WHY="" GSM_MAIN=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha="${line%%$'\t'*}"; ref="${line#*$'\t'}"
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || [ "$ref" = "$line" ]; then
      GSM_WHY="ls-remote printed a line that is no '<sha><TAB><ref>' record: '$line'"; GSM_MAIN=""; return 2
    fi
    [ "$ref" = refs/heads/main ] && GSM_MAIN="$sha"
  done <<<"$1"
  return 0
}

# gsm_read_source : condition 5's read. Sets GSM_SRC_SHA.
gsm_read_source() {
  local where out rc=0
  gsm_seam GLAB_ATHENA_SEED_SOURCE_READ
  where="${GSM_SEAM:-origin}"
  out="$(timeout 60 env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 git ls-remote "$where" refs/heads/main 2>/dev/null </dev/null)" || rc=$?
  [ "$rc" = 0 ] || gsm_cnl "the fresh read of origin's main (\`git ls-remote origin refs/heads/main\`) exited $rc" \
    "check this checkout can read its GitHub origin (\`git ls-remote origin refs/heads/main\`), then retry."
  gsm_main_of "$out" || gsm_cnl "the fresh read of origin's main: $GSM_WHY" "retry; if it repeats, check origin."
  GSM_SRC_SHA="$GSM_MAIN"
  [ -n "$GSM_SRC_SHA" ] || gsm_cnl "origin lists no refs/heads/main (an empty list is not an empty repository)" \
    "check origin's default branch is main and this checkout can read it, then retry."
  git cat-file -e "${GSM_SRC_SHA}^{commit}" 2>/dev/null || gsm_refuse "FRESH SHA" "origin's main is $GSM_SRC_SHA, which this checkout does not have, so the push cannot send it" \
    "run \`git fetch origin\` in this checkout, then retry."
}

# gsm_read_target <self> : condition 6's read, through the route as the
# target's bot (<self> is this glab-athena). Sets GSM_TGT_SHA ("" = absent).
gsm_read_target() {
  local self="$1" out rc=0 seam err
  gsm_seam GLAB_ATHENA_SEED_TARGET_READ; seam="$GSM_SEAM"
  err="$(mktemp)" || gsm_cnl "mktemp failed" "check the temporary directory is writable, then retry."
  if [ -n "$seam" ]; then
    out="$(timeout 120 env GIT_TERMINAL_PROMPT=0 git ls-remote "$seam" refs/heads/main 2>"$err" </dev/null)" || rc=$?
  else
    out="$(timeout 120 env -u GLAB_ATHENA_GIT_DRY_RUN "$self" git ls-remote "$GSM_TO" refs/heads/main 2>"$err" </dev/null)" || rc=$?
  fi
  local why; why="$(head -c 300 "$err" | tr '\n' ' ')"; rm -f "$err"
  [ "$rc" = 0 ] || gsm_cnl "the read of the target's main (\`glab-athena git ls-remote $GSM_TO refs/heads/main\`) exited $rc${why:+: $why}" \
    "check the bot can read $GSM_TO (\`~/dev/custom/ai/bin/glab-athena git ls-remote $GSM_TO\`), then retry. An unreadable target is not an empty one."
  gsm_main_of "$out" || gsm_cnl "the read of the target's main: $GSM_WHY" "retry; if it repeats, check $GSM_TO."
  GSM_TGT_SHA="$GSM_MAIN"
}

# gsm_judge <source sha> <target sha or ""> <target object local: 1/0>
#           <merge-base --is-ancestor rc, or "">
# Pure. Sets GSM_OUTCOME (push / already / not-ff / could-not-look) and GSM_WHY.
gsm_judge() {
  local src="$1" tgt="$2" tgt_local="$3" anc="$4"
  GSM_OUTCOME="" GSM_WHY=""
  if [ -z "$tgt" ]; then GSM_OUTCOME=push; GSM_WHY="the target has no main"; return; fi
  if [ "$tgt" = "$src" ]; then GSM_OUTCOME=already; GSM_WHY="the target's main is already $src"; return; fi
  if [ "$tgt_local" != 1 ]; then
    GSM_OUTCOME=could-not-look; GSM_WHY="the target's main $tgt is not in this checkout, so whether it is an ancestor of $src is unknown"; return
  fi
  case "$anc" in
    0) GSM_OUTCOME=push; GSM_WHY="the target's main $tgt is an ancestor of $src (a fast-forward)" ;;
    1) GSM_OUTCOME=not-ff; GSM_WHY="the target's main $tgt is not an ancestor of origin's main $src, so the push is no fast-forward (it never forces)" ;;
    *) GSM_OUTCOME=could-not-look; GSM_WHY="git merge-base --is-ancestor $tgt $src exited ${anc:-?}" ;;
  esac
}

# gsm_main <self> <seed-mirror args...> : check every condition, then set the
# sanction and GSM_PUSH_ARGV for the caller to run through the route. Exits 0
# when there is nothing to push; exits 3 on any refusal.
gsm_main() {
  local self="$1" tgt_local=0 anc=""
  shift
  gsm_parse_args "$@"
  gsm_check_target
  gsm_check_origin
  gsm_check_health
  gsm_read_source
  gsm_read_target "$self"
  if [ -n "$GSM_TGT_SHA" ] && [ "$GSM_TGT_SHA" != "$GSM_SRC_SHA" ]; then
    git cat-file -e "${GSM_TGT_SHA}^{commit}" 2>/dev/null && tgt_local=1
    if [ "$tgt_local" = 1 ]; then
      anc=0; git merge-base --is-ancestor "$GSM_TGT_SHA" "$GSM_SRC_SHA" 2>/dev/null || anc=$?
    fi
  fi
  gsm_judge "$GSM_SRC_SHA" "$GSM_TGT_SHA" "$tgt_local" "$anc"
  case "$GSM_OUTCOME" in
    push) ;;
    already) printf '%s: seed-mirror: nothing to push: %s\n' "$FG_TOOL" "$GSM_WHY" >&2; exit 0 ;;
    not-ff) gsm_refuse FAST-FORWARD "$GSM_WHY" \
              "compare the two mains (\`git ls-remote origin refs/heads/main\`, \`glab-athena git ls-remote $GSM_TO refs/heads/main\`) and reconcile them by hand; the admiral decides which is canonical." ;;
    *) gsm_cnl "$GSM_WHY" "fetch the target's main through the route (\`~/dev/custom/ai/bin/glab-athena git fetch $GSM_TO refs/heads/main\`), then retry." ;;
  esac
  printf '%s: seed-mirror: pushing origin main %s to %s main (%s; the bot for %s/%s)\n' \
    "$FG_TOOL" "$GSM_SRC_SHA" "$GSM_TO" "$GSM_WHY" "$FID_HOST" "$FID_NS" >&2
  FG_SEED_SHA="$GSM_SRC_SHA" FG_SEED_URL="$GSM_TO"
  GSM_PUSH_ARGV=( push "$GSM_TO" "${GSM_SRC_SHA}:refs/heads/main" )
}
