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
  # Validated before it reaches the arithmetic context: `$(( ))` executes a
  # command substitution inside an array subscript, so an unvalidated offset
  # here is code execution, not a bad read.
  case "${2}" in
    ''|*[!0-9]*)
      inbox_fail "refusing a non-numeric byte offset for \"$1\"" \
        "reset the channel's .state.json \"offset\" to 0; a non-numeric offset means the state file is corrupt."
      return 1
      ;;
  esac
  tail -c "+$(( ${2} + 1 ))" "$1" 2>/dev/null || true
}

# fs_assert_no_nul <path>
# A NUL byte in a .jsonl is corruption: the writer emits JSON, where a NUL is
# escaped as \u0000, so a raw one never comes from a healthy producer.
#
# It has to be REFUSED rather than tolerated, because shell cannot carry it:
# a command substitution drops NULs (printing `warning: command substitution:
# ignored null byte in input` onto the very stderr this entry point exists to
# keep clean) and the dropped bytes make the byte count SHORT -- so the
# next_offset that D-13's crash-safety guarantee rests on would land before
# the real complete-line boundary. Silently miscounting is the one outcome
# worse than refusing.
fs_assert_no_nul() {
  local path="$1" raw stripped
  [ -f "${path}" ] || return 0
  raw="$(wc -c < "${path}" | tr -d ' ')"
  stripped="$(tr -d '\0' < "${path}" | wc -c | tr -d ' ')"
  [ "${raw}" = "${stripped}" ] && return 0
  inbox_fail "channel file \"${path}\" contains a NUL byte, so it cannot be counted safely" \
    "the file is corrupt -- a JSON writer escapes NUL as \\u0000 and never emits a raw one. Move it aside and let the producer recreate it, then reset the matching .state.json offset to 0."
  return 1
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
  # `-e` is FALSE for a dangling symlink, so `-e || -L` is what stops the walk
  # from stepping past one and judging containment on its parent instead.
  while [ -n "${anc}" ] && [ ! -e "${anc}" ] && [ ! -L "${anc}" ]; do
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
# Emits one "<compact json>\t<path>" line per PARSEABLE registry file, then a
# trailing "#unparseable\t<count>" line when some file could not be read.
#
# THE JSON COMES FIRST. With the path first, a registry FILENAME containing a
# tab would shift the JSON into the remainder field and the entry would be
# silently dropped -- no match, no error. jq -c escapes a tab inside a string,
# so the JSON field itself can never contain one.
#
# AN UNPARSEABLE FILE IS COUNTED, NOT NAMED, AND DOES NOT ABORT THE SCAN.
# Every file in projects/ belongs to a DIFFERENT tenant, and failing here on
# any of them had two costs: one project's typo wedged `inbox-status` for
# every project on the machine, and the refusal printed another tenant's
# registry filename -- the same disclosure `descriptor_select` refuses by
# name. The caller decides: if its OWN entry was found, another tenant's
# broken file is not its problem; if no entry matched AND something was
# unparseable, the caller must refuse, because the broken one may be its own.
#
# A symlinked registry file is refused for the same reason a symlinked inbox
# is: the mode and ownership you checked are not the ones you read.
fs_registry_records() {
  local dir file json bad=0
  dir="$(fs_registry_dir)"
  [ -d "${dir}" ] || return 0

  for file in "${dir}"/*.json; do
    [ -e "${file}" ] || continue
    if [ -L "${file}" ] || [ ! -f "${file}" ]; then bad=$((bad + 1)); continue; fi
    if ! json="$(jq -c . < "${file}" 2>/dev/null)"; then bad=$((bad + 1)); continue; fi
    printf '%s\t%s\n' "${json}" "${file}"
  done
  [ "${bad}" -eq 0 ] || printf '#unparseable\t%s\n' "${bad}"
  return 0
}

# fs_list_dir_z <path>
# Bare names, NUL-delimited, INCLUDING dotfiles. Empty for a directory that
# does not exist; the domain predicate decides what counts.
#
# NUL-delimited, not `ls -A`, because `ls` is a LOSSY encoding of a directory:
# a filename containing a newline arrives as two lines and is counted twice.
# Here that is not academic -- a maildir message's slug is prose the PEER
# chose, so `ls` would let the peer decide how many messages it had sent.
# NUL is the one byte a filename cannot contain.
fs_list_dir_z() {
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null || true
}

# fs_assert_not_symlink <path>
# The directory counterpart of fs_assert_regular. `fs_assert_contained` uses
# realpath, which FOLLOWS symlinks, so a symlinked directory inside the root
# pointing elsewhere inside the root passes containment and is still a
# redirect. Same reasoning as the inbox file's lstat defence, applied to the
# directory a maildir channel reads from.
fs_assert_not_symlink() {
  local path="$1"
  if [ -L "${path}" ]; then
    inbox_fail "refusing to follow a symlinked directory at \"${path}\"" \
      "replace \"${path}\" with a real directory; a symlink there redirects the read to a location the containment check already approved under a different name."
    return 1
  fi
  return 0
}
