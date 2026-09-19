#!/usr/bin/env bash
# names.sh -- the path and name grammar of the Athena Inbox. DOMAIN: pure.
#
# Nothing here touches the filesystem. Every function takes strings and returns
# strings or a status, which is what makes the whole grammar provable without a
# single fixture on disk -- and it is why the containment check below is
# LEXICAL.
#
# On containment vs. the symlink defence (contract -> "Root and permissions"):
# these are two different jobs and one does not do the other's.
#   * containment (here)  -- refuse a path that escapes the root, BEFORE any
#     I/O. Lexical, because `realpath` on a not-yet-created file fails ENOENT,
#     and "First run, missing files, and a stale offset" declares that file
#     normal.
#   * substitution (fs.sh) -- refuse a symlink or a non-regular file at the
#     resolved path. `realpath` cannot do this: it FOLLOWS symlinks, so a
#     symlink inside the root pointing inside the root passes containment and
#     is still a symlink. That is an lstat/O_NOFOLLOW job and lives in fs.sh.
#
# Source order: err.sh, then this file.

# --- name grammars ----------------------------------------------------------

# names_byte_length <string>
names_byte_length() { LC_ALL=C printf '%s' "$1" | wc -c | tr -d ' '; }

# names_valid_inbox_name <name>  (kind `log` -> descriptor `path`)
#
# Normative in the contract -> "Path grammar"; it mirrors `Inbox.valid_name?`
# in the deployed Ruby client, which is corroboration, not the source. A log
# path is a BARE FILENAME sitting directly in the root: the writer's
# `Inbox.resolve` asserts `File.dirname(path) == root`, so a `<namespace>/`
# prefix is impossible for this kind however sensible it looks. Only `maildir`
# namespaces are prefixed.
names_valid_inbox_name() {
  local name="$1"

  [ -n "${name}" ] || return 1
  # The suffix is load-bearing: state/doorbell/lock are derived from it by
  # suffix substitution, so a name without it has no derivable siblings.
  case "${name}" in
    *.jsonl) ;;
    *) return 1 ;;
  esac
  [ "${name}" != ".jsonl" ] || return 1
  case "${name}" in
    .*) return 1 ;;                    # no leading dot
    */*|*\\*) return 1 ;;              # no separator of either flavour
    *..*) return 1 ;;                  # no traversal, anywhere in the string
    *$'\0'*) return 1 ;;               # unreachable via a bash variable; see
                                       # SABOTAGE_RECORDS.md (measured zero)
  esac
  [ "$(names_byte_length "${name}")" -le 128 ] || return 1
  return 0
}

# names_valid_segment <segment>
# The one segment grammar the contract uses for a channel name, an identity, a
# maildir `read`/`write`, and each namespace segment: ^[a-z0-9][a-z0-9_-]*$,
# <= 64 bytes.
names_valid_segment() {
  local seg="$1"
  [[ "${seg}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  [ "$(names_byte_length "${seg}")" -le 64 ] || return 1
  return 0
}

names_valid_channel_name() { names_valid_segment "$1"; }
names_valid_identity()     { names_valid_segment "$1"; }

# names_valid_namespace <relative-path>
# One or more segments, each matching the segment grammar. No `..`, no leading
# dot, no absolute path.
names_valid_namespace() {
  local ns="$1" seg
  [ -n "${ns}" ] || return 1
  case "${ns}" in /*|*//*|*/) return 1 ;; esac
  local IFS=/
  for seg in ${ns}; do
    names_valid_segment "${seg}" || return 1
  done
  return 0
}

# --- derived paths ----------------------------------------------------------
# Contract -> "Derived paths". Suffix substitution on the inbox name, which is
# the whole reason `.jsonl` is mandatory.

names_state_name()    { printf '%s.state.json\n'    "${1%.jsonl}"; }
names_doorbell_name() { printf '%s.event\n'         "${1%.jsonl}"; }
names_lock_name()     { printf '%s.consumer.lock\n' "${1%.jsonl}"; }

# --- containment ------------------------------------------------------------

# names_resolve_in_root <root> <relative-path>
# Prints the joined absolute path, or refuses with a `Fix:` clause.
#
# Purely lexical on purpose (see the header). An absolute path, an empty path,
# and any `..`/`.` component are refused before a caller can turn the result
# into I/O.
names_resolve_in_root() {
  local root="${1%/}" rel="$2" comp
  local fix='give the channel a path relative to ATHENA_INBOX_ROOT with no leading "/" and no ".." component.'

  if [ -z "${rel}" ]; then
    inbox_fail "empty path cannot be resolved inside the inbox root" "${fix}"
    return 1
  fi
  case "${rel}" in
    /*)
      inbox_fail "path \"${rel}\" is absolute and would escape the inbox root" "${fix}"
      return 1
      ;;
  esac

  local IFS=/
  for comp in ${rel}; do
    case "${comp}" in
      ..|.)
        inbox_fail "path \"${rel}\" escapes the inbox root (component \"${comp}\")" "${fix}"
        return 1
        ;;
    esac
  done

  printf '%s/%s\n' "${root}" "${rel}"
  return 0
}
