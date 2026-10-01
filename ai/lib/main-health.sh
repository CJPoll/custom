# shellcheck shell=bash
#
# main-health.sh -- the ONE reader of the red-main marker (DND-1482). Sourced,
# never run.
#
# Why: ~/dev/custom has no CI. A landing is a clean rebase plus a fast-forward
# push with no re-gate (owner decision D5, DND-1463), so two clean landings can
# combine into a red origin/main that nothing re-checks. ai/bin/main-health
# gates origin/main after a landing and, on RED, writes a marker. This file is
# how everything else reads that marker:
#   * ai/bin/main-health (status, and the marker it maintains);
#   * ai/lib/forge-git-passthrough.sh, behind every `gh-athena git push` and
#     `glab-athena git push`, which REFUSES a push to main while main is red
#     unless the pushed commit is a gated fix (mh_may_land).
#
# Store: <git common dir>/main-health/ -- shared by the main checkout and every
# linked worktree, like integration-gate's receipts.
#   verdicts/<sha>  one record per checked origin/main SHA (key=value lines)
#   logs/<sha>.log  the gate output behind a verdict
#   red             the marker: present ONLY while the last checked tip is RED
#
# Absent marker = no red is KNOWN. It is not a claim that main is green: main
# may be unchecked. A red is only ever asserted by a check, so the guard
# refuses only on a marker it read. An unreadable or malformed marker is
# "could not look" and refuses too: a marker exists, so a red may be known.
#
# There is deliberately no flag, env var or marker that skips the refusal
# (~/dev/custom/CLAUDE.md -> "A check's own bar must not live in the diff it
# is checking"). The one way past it is a fix: a commit that contains the red
# SHA and has integration-gate's pass receipt for exactly itself. Refreshing
# the verdict (main-health check) clears a stale marker.

MH_SCHEMA_VERDICT="main-health/1"
MH_SCHEMA_RED="main-health-red/1"

# The receipt reader (integration-gate's), for the fix exception.
# shellcheck source=integration-receipt.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/integration-receipt.sh" || return 2

mh_store()       { printf '%s/main-health' "$1"; }
mh_red_path()    { printf '%s/red' "$(mh_store "$1")"; }
mh_verdict_path(){ printf '%s/verdicts/%s' "$(mh_store "$1")" "$2"; }

# mh_kv <file> <key> : the LAST value of key= in a key=value file (empty if none).
mh_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }

# mh_read_red <git-common-dir>
#   0  a red marker was read: sets MH_RED_SHA, MH_RED_FIRST, MH_RED_SINCE,
#      MH_RED_RECORD, MH_RED_ALERT
#   1  no marker: no red is known
#   2  a marker exists but cannot be read or is malformed: sets MH_WHY
mh_read_red() {
  local f
  f="$(mh_red_path "$1")"
  MH_RED_SHA="" MH_RED_FIRST="" MH_RED_SINCE="" MH_RED_RECORD="" MH_RED_ALERT="" MH_WHY=""
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    if [ -e "$(mh_store "$1")" ] && [ ! -x "$(mh_store "$1")" ]; then
      MH_WHY="the store $(mh_store "$1") exists but cannot be searched, so whether main is red is unknown"
      return 2
    fi
    return 1
  fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    MH_WHY="the red-main marker ${f} exists but is not a readable regular file"
    return 2
  fi
  if [ "$(mh_kv "$f" schema)" != "$MH_SCHEMA_RED" ]; then
    MH_WHY="the red-main marker ${f} has schema '$(mh_kv "$f" schema)', not ${MH_SCHEMA_RED}"
    return 2
  fi
  MH_RED_SHA="$(mh_kv "$f" sha)"
  if ! [[ "$MH_RED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    MH_WHY="the red-main marker ${f} records sha '${MH_RED_SHA}', not a full commit SHA"
    MH_RED_SHA=""
    return 2
  fi
  MH_RED_FIRST="$(mh_kv "$f" first_red)"
  MH_RED_SINCE="$(mh_kv "$f" since)"
  MH_RED_RECORD="$(mh_kv "$f" record)"
  MH_RED_ALERT="$(mh_kv "$f" alert)"
  return 0
}

# mh_may_land <git-common-dir> <sha> : may <sha> become main?
#   0  yes: no red is known (MH_NOTE empty), or <sha> is a gated fix for the
#      red SHA (MH_NOTE says so)
#   1  no: main is red and <sha> is not a gated fix (MH_WHY)
#   2  could not look (MH_WHY)
mh_may_land() {
  local common="$1" sha="$2" rc
  MH_NOTE="" MH_WHY=""
  mh_read_red "$common"; rc=$?
  case "$rc" in
    1) return 0 ;;
    2) return 2 ;;
  esac
  if ! git --git-dir="$common" cat-file -e "${MH_RED_SHA}^{commit}" 2>/dev/null; then
    MH_WHY="origin/main is RED at ${MH_RED_SHA}, which is not in the object store under ${common}, so whether ${sha} contains it is unknown"
    return 2
  fi
  git --git-dir="$common" merge-base --is-ancestor "$MH_RED_SHA" "$sha" 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) MH_WHY="origin/main is RED at ${MH_RED_SHA} (since ${MH_RED_SINCE:-?}; record ${MH_RED_RECORD:-?}), and ${sha} does not contain that commit, so it cannot be the fix"
       return 1 ;;
    *) MH_WHY="git merge-base --is-ancestor ${MH_RED_SHA} ${sha} failed (exit ${rc}) under ${common}"
       return 2 ;;
  esac
  if ir_read_receipt "$common" "$sha" "$sha"; then
    MH_NOTE="origin/main is RED at ${MH_RED_SHA}; ${sha} contains it and integration-gate passed exactly ${sha} (${IR_RECEIPT}), so it lands as the fix"
    return 0
  fi
  MH_WHY="origin/main is RED at ${MH_RED_SHA} (since ${MH_RED_SINCE:-?}; record ${MH_RED_RECORD:-?}), and ${sha} has no integration-gate pass for exactly itself (${IR_KIND}: ${IR_WHY})"
  return 1
}

# mh_push_main_sources <default-branch> <git args...> : print, one per line,
# the source of every refspec in a `git push` whose destination is the default
# branch. Global options before `push` are skipped. Nothing is printed for a
# --dry-run push (it lands nothing) or a delete (`:main`, nothing lands).
#   --all / --mirror     -> refs/heads/<default>
#   <src>:<default>      -> <src>
#   <default>            -> <default>
#   HEAD (no colon)      -> HEAD, when the checked-out branch is <default>
#   no refspec at all    -> HEAD, when the checked-out branch is <default>
# Residual, said out loud: with no refspec git follows push.default and the
# branch's upstream; this reads "on <default>" as "pushes <default>", which is
# what every Athena landing spells explicitly anyway.
mh_push_main_sources() {
  local def="$1" a src dst seen_push=0 seen_repo=0 refspecs=0 dry=0 cur
  local -a glob=() out=()
  shift
  while [ $# -gt 0 ]; do
    a="$1"; shift
    if [ "$seen_push" -eq 0 ]; then
      case "$a" in
        -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix)
          glob+=( "$a" ); [ $# -gt 0 ] && { glob+=( "$1" ); shift; } ;;
        push) seen_push=1 ;;
        *) glob+=( "$a" ) ;;
      esac
      continue
    fi
    case "$a" in
      --dry-run|-n) dry=1 ;;
      --all|--mirror) out+=( "refs/heads/$def" ) ;;
      -o|--push-option|--receive-pack|--exec|--repo) [ $# -gt 0 ] && shift ;;
      --) ;;
      -*) ;;
      *)
        if [ "$seen_repo" -eq 0 ]; then seen_repo=1; continue; fi
        refspecs=1
        a="${a#+}"
        if [[ "$a" == *:* ]]; then src="${a%%:*}"; dst="${a#*:}"; else src="$a"; dst="$a"; fi
        if [ "$dst" = HEAD ] && [[ "$a" != *:* ]]; then
          cur="$(git "${glob[@]}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
          [ "$cur" = "$def" ] && out+=( HEAD )
          continue
        fi
        case "$dst" in
          "$def"|refs/heads/"$def") [ -n "$src" ] && out+=( "$src" ) ;;
        esac ;;
    esac
  done
  [ "$dry" -eq 1 ] && return 0
  if [ "$refspecs" -eq 0 ] && [ "${#out[@]}" -eq 0 ]; then
    cur="$(git "${glob[@]}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    [ "$cur" = "$def" ] && out+=( HEAD )
  fi
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}
