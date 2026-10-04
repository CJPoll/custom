# shellcheck shell=bash
#
# gh-target-repo.sh — which repository a gh write goes to, resolved the way gh
# resolves it (DND-2006). Sourced by ai/lib/gh-outbound-scan.sh, never run. It
# reads no network and runs nothing: it turns the argv's -R/--repo values and
# GH_REPO into the list of repositories whose visibility the scan reads.
#
# gh's rule (gh 2.96, cmdutil.EnableRepoOverride -> OverrideBaseRepoFunc): the
# last -R/--repo value wins (a pflag string flag); when that value is EMPTY, gh
# uses GH_REPO; when GH_REPO is empty or unset too, gh uses the checkout's
# repository (its remotes, and `gh repo set-default`). `gh repo view` with no
# argument resolves the checkout the same way but IGNORES GH_REPO, so an empty
# -R must never be read as "the checkout" while GH_REPO is set. Measured
# 2026-10-04 with gh 2.96.0: `GH_REPO=<other> gh pr list -R ''` lists the
# other repository's PRs, and `GH_REPO=<other> gh repo view` shows the
# checkout's.
#
# The function is a superset of gh's choice, never a subset: every non-empty
# -R value is a target, not only the last, so a scan can only run more often
# than gh's own choice requires.

# gtr_well_formed <value> : true when <value> is a repository in a form gh
# reads (ghrepo.FromFullName): [HOST/]OWNER/REPO, a URL, or an scp-style git
# address. Anything else gh refuses too; this guard refuses it first, because
# a value it cannot read is not a value it may call private.
gtr_well_formed() {
  local v="$1"
  [[ "$v" =~ [[:space:]] ]] && return 1
  case "$v" in
    *://?*) return 0 ;;
  esac
  [[ "$v" =~ ^[^@/:]+@[^/:]+:[^/]+/[^/]+$ ]] && return 0
  [[ "$v" =~ ^[^/]+/[^/]+(/[^/]+)?$ ]]
}

# gtr_resolve <has_url_target 0|1> [<-R value>...] : sets GTR_TARGETS to the
# repositories the write reaches through -R, GH_REPO or the checkout. The -R
# values come in argv order, empty ones included. "" in GTR_TARGETS means the
# checkout's repository (read with `gh repo view` and no argument). The
# checkout is a target only when gh falls back to it AND no PR or issue URL
# names the repository (gh acts on a URL's repository whatever the directory
# is). Returns 1 with GTR_WHY set (a message ending in a Fix:) when a value
# that decides the target is not a repository gh can read.
gtr_resolve() {
  local has_url="$1" v last="" from
  shift
  GTR_TARGETS=() GTR_WHY=""
  for v in "$@"; do
    last="$v"
    [ -n "$v" ] || continue
    if ! gtr_well_formed "$v"; then
      GTR_WHY="COULD NOT LOOK: the -R/--repo value '$v' is not a repository gh can read ([HOST/]OWNER/REPO or a URL), so which repository this write reaches is unknown; that is not the same as private. Fix: pass -R <owner>/<repo>, then retry."
      return 1
    fi
    GTR_TARGETS+=("$v")
  done
  # gh uses the last -R value; an empty one (or none) falls through.
  [ -z "$last" ] || return 0
  if [ -n "${GH_REPO:-}" ]; then
    if [ "$#" -gt 0 ]; then from="GH_REPO (the -R/--repo value is empty, so gh uses GH_REPO)"; else from="GH_REPO"; fi
    if ! gtr_well_formed "$GH_REPO"; then
      GTR_WHY="COULD NOT LOOK: $from is '$GH_REPO', not a repository gh can read ([HOST/]OWNER/REPO or a URL), so which repository this write reaches is unknown; that is not the same as private. Fix: unset GH_REPO or set it to <owner>/<repo>, or pass a non-empty -R <owner>/<repo>, then retry."
      return 1
    fi
    GTR_TARGETS+=("$GH_REPO")
    return 0
  fi
  [ "$has_url" = 1 ] || GTR_TARGETS+=("")
  return 0
}
