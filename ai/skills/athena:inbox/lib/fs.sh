#!/usr/bin/env bash
# fs.sh -- SIDE EFFECTS. The only file I/O in the skill, plus the one `git`
# call. Everything else in lib/ takes strings and returns strings.
#
# This slice (DND-183) is READ-ONLY on purpose. There is no state writer in
# this file at all, because `inbox-status` counts and must never consume: the
# strongest available guarantee that counting does not advance an offset is
# that the code which could advance it does not exist yet. The atomic state
# writer arrives with the ack ticket.
#
# ON CONTAINMENT vs. THE SYMLINK DEFENCE -- two different jobs, and one does
# not do the other's:
#   * names.sh's containment is LEXICAL and runs before any I/O, because the
#     file it protects legitimately may not exist yet (first run).
#   * fs_assert_regular is an lstat job. `realpath` FOLLOWS symlinks, so a
#     symlink inside the root pointing inside the root passes containment and
#     is still a symlink. This mirrors the deployed Ruby client's O_NOFOLLOW +
#     regular-file fstat, rather than inventing a second mechanism.
#
# Source order: err.sh, names.sh, then this file. Requires jq.

# fs_inbox_root
# ATHENA_INBOX_ROOT, or the contract's default. Not created here -- this slice
# never writes.
fs_inbox_root() { printf '%s\n' "${ATHENA_INBOX_ROOT:-${HOME}/.local/share/athena}"; }

# fs_registry_dir
fs_registry_dir() { printf '%s/projects\n' "$(fs_inbox_root)"; }

# fs_size <path>   -- 0 for a file that does not exist (first run is normal).
fs_size() {
  [ -f "$1" ] || { printf '0\n'; return 0; }
  wc -c < "$1" | tr -d ' '
}

# fs_slice_from <path> <byte-offset>
# Empty for a file that does not exist -- the first-run case, which the
# contract calls normal. (There was a `[ -f "$2" ]` here that tested the
# OFFSET as a pathname and discarded its result: it read as a guard and was
# not one. `tail` already yields nothing for a missing file, so the guard was
# never needed; what it did was disguise that fact.)
fs_slice_from() {
  tail -c "+$(( ${2} + 1 ))" "$1" 2>/dev/null || true
}

# fs_assert_regular <path>
# Refuses a symlink or any non-regular file AT the path. The `-L` test is an
# lstat and therefore does not follow, which is the entire point.
fs_assert_regular() {
  local path="$1"
  if [ -L "${path}" ]; then
    inbox_fail "refusing to follow a symlink at \"${path}\"" \
      "replace \"${path}\" with a regular file; the inbox writer opens with O_NOFOLLOW and a symlink there is either a mistake or an attempt to redirect a read."
    return 1
  fi
  if [ -e "${path}" ] && [ ! -f "${path}" ]; then
    inbox_fail "\"${path}\" is not a regular file" \
      "replace \"${path}\" with a regular file; a FIFO or device at an inbox path cannot be read safely."
    return 1
  fi
  return 0
}

# fs_assert_contained <root> <path>
# realpath containment through the NEAREST EXISTING ANCESTOR: the target
# legitimately may not exist yet, and `realpath` on a missing file fails
# ENOENT, which would refuse the ordinary first-run case.
fs_assert_contained() {
  local root="$1" path="$2" real_root anc real_anc
  real_root="$(realpath -q "${root}" 2>/dev/null)" || real_root="${root}"

  anc="${path}"
  while [ -n "${anc}" ] && [ ! -e "${anc}" ]; do
    local parent="${anc%/*}"
    [ "${parent}" != "${anc}" ] || break
    anc="${parent:-/}"
  done
  real_anc="$(realpath -q "${anc}" 2>/dev/null)" || real_anc="${anc}"

  case "${real_anc}/" in
    "${real_root}/"*) return 0 ;;
  esac
  inbox_fail "path \"${path}\" resolves outside the inbox root" \
    "give the channel a path inside \$ATHENA_INBOX_ROOT; a symlinked ancestor pointing out of the root has the same effect as a \"..\" and is refused the same way."
  return 1
}

# fs_read_state <path>   -- "{}" when absent. Reading never creates it.
fs_read_state() {
  if [ ! -e "$1" ]; then printf '{}\n'; return 0; fi
  fs_assert_regular "$1" || return 1
  cat "$1"
}

# fs_git_common_dir [cwd]
#
# The repo identity: the realpath of `git rev-parse --git-common-dir`. It is
# IDENTICAL for a repo's main checkout and every one of its worktrees, and
# distinct per repo, so a worktree session resolves to its parent repo's
# channels for free. Empty + status 1 when the cwd is in no git repository --
# which is NOT a fault, just "no channels".
fs_git_common_dir() {
  local dir="${1:-.}" out
  out="$(cd "${dir}" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "${out}" ] || return 1
  case "${out}" in
    /*) ;;
    *) out="$(cd "${dir}" && printf '%s/%s\n' "$(pwd)" "${out}")" ;;
  esac
  realpath -q "${out}" 2>/dev/null || return 1
}

# fs_registry_records
#
# Emits one "<path>\t<compact json>" line per readable registry file. A
# malformed file is a HARD error naming it: a registry nobody can parse must
# not silently degrade into "this project has no channels", which is
# indistinguishable from not having opted in.
#
# A symlinked registry file is refused for the same reason a symlinked inbox
# is: the mode and ownership you checked are not the ones you read.
fs_registry_records() {
  local dir file json
  dir="$(fs_registry_dir)"
  [ -d "${dir}" ] || return 0

  for file in "${dir}"/*.json; do
    [ -e "${file}" ] || continue
    fs_assert_regular "${file}" || return 1
    if ! json="$(jq -c . < "${file}" 2>/dev/null)"; then
      inbox_fail "registry file \"${file}\" is not parseable JSON" \
        "fix the JSON in \"${file}\" (check it with: jq . \"${file}\"), or remove the file if the project no longer uses the inbox."
      return 1
    fi
    printf '%s\t%s\n' "${file}" "${json}"
  done
  return 0
}

# fs_list_dir <path>   -- bare names, one per line, INCLUDING dotfiles. Empty
# for a directory that does not exist; the domain filter decides what counts.
fs_list_dir() {
  [ -d "$1" ] || return 0
  ls -A -- "$1" 2>/dev/null || true
}
