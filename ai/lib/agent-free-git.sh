# ai/lib/agent-free-git.sh -- sourced (sh/bash); defines agent_free_git.
#
# agent_free_git: print the path of the first `git` on PATH that is not the
# agent PATH git wrapper (ai/agent-bin/git, DND-775), which carries the text
# "git (agent wrapper)" in its first five lines. Returns 1 with a Fix: on
# stderr when there is none.
#
# WHO USES IT: test fixtures that build a synthetic PATH out of links to
# `command -v <tool>` (to hide one tool, or to put a stub in front of git) and
# mean "the real git" (DND-1103). In an agent session `command -v git` is the
# wrapper. Linked alone into a PATH that holds no real git, the wrapper can
# only exit 127, so the fixture tests "git is broken" instead of the case it
# names; several such cases still passed, for the wrong reason. Fixture repos
# are mktemp repos with no shared stash list, so reaching git without the
# wrapper there removes no protection. Code that runs in a real repo keeps
# calling `git` through PATH.

# _afg_is_wrapper <file>: its first five lines carry the wrapper's mark. Shell
# builtins only: the PATH being searched may hold no grep, and a missing grep
# must not read as "not the wrapper".
_afg_is_wrapper() {
  _afg_n=0
  while [ "${_afg_n}" -lt 5 ] && IFS= read -r _afg_l; do
    case "${_afg_l}" in *'git (agent wrapper)'*) return 0 ;; esac
    _afg_n=$((_afg_n + 1))
  done < "$1" 2>/dev/null
  return 1
}

agent_free_git() {
  _afg_ifs=$IFS
  IFS=:
  for _afg_d in ${PATH}; do
    # Absolute entries only: a fixture links the result into another dir, where
    # a relative path dangles. An unreadable file cannot be shown not to be the
    # wrapper, so it is passed over too.
    case "${_afg_d}" in /*) ;; *) continue ;; esac
    if [ -f "${_afg_d}/git" ] && [ -x "${_afg_d}/git" ] && [ -r "${_afg_d}/git" ] \
      && ! _afg_is_wrapper "${_afg_d}/git"; then
      IFS=$_afg_ifs
      printf '%s\n' "${_afg_d}/git"
      return 0
    fi
  done
  IFS=$_afg_ifs
  printf 'agent_free_git: no readable git in an absolute PATH entry besides the agent wrapper (PATH=%s). Fix: put the directory holding the real git (usually /usr/bin) on PATH.\n' "${PATH}" >&2
  return 1
}
