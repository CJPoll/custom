#!/usr/bin/env bash
# fs.sh -- SIDE EFFECTS. The only file I/O in the skill, plus the one `git`
# call. Everything else in lib/ takes strings and returns strings.
#
# **Amended (DND-184).** This file was READ-ONLY through DND-183: `inbox-status`
# counts and must never consume, and the strongest available guarantee that
# counting does not advance an offset was that the code which could advance it
# did not exist yet. The ack ticket is DND-184, so that guarantee has been
# spent: the writes now live here, under the WRITES banner below, and the
# counting path's guarantee is the designated-consumer gate instead -- a
# subagent or a non-holder may count and may peek, and neither advances.
#
# ON CONTAINMENT vs. THE SYMLINK DEFENCE -- two different jobs, and one does
# not do the other's:
#   * names.sh's containment is LEXICAL and runs before any I/O, because the
#     file it protects legitimately may not exist yet (first run).
#   * fs_assert_regular is an lstat job. `realpath` FOLLOWS symlinks, so a
#     symlink inside the root pointing inside the root passes containment and
#     is still a symlink.
#
# A DELIBERATE, NAMED DEVIATION: the contract requires `O_NOFOLLOW` plus an
# `fstat` on the descriptor actually held, which is atomic. This is
# lstat-then-open, which is NOT: between `fs_assert_regular` and the `wc` /
# `tail` / `cat` that follows, the path can be replaced by a symlink and is
# then followed. Shell has no way to hold a descriptor across those commands,
# so the check is the strongest available here rather than an equivalent one,
# and the earlier wording claiming it "mirrors" the client's was overstating
# it. The exposure is bounded -- the root is 0700 and single-user, so winning
# the race requires the access an attacker would already need -- and it is
# recorded here rather than argued away, because the other deliberate
# deviations in this skill are.
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

  local base
  for file in "${dir}"/*.json; do
    [ -e "${file}" ] || continue
    # NOT A CANDIDATE vs. A CANDIDATE THAT FAILED. Only a grammar-conformant
    # `*.json` was ever a registry entry, so only it can have been the one
    # claiming this session. A stray `walt_ui.json.bak` or `.walt_ui.json.swp`
    # says nothing -- and counting it would pin the warning on every status
    # line forever, and a counter that is always on is a counter the owner
    # stops reading, which reopens the silence it was added to close.
    base="${file##*/}"
    names_valid_segment "${base%.json}" || continue
    if [ -L "${file}" ] || [ ! -f "${file}" ]; then bad=$((bad + 1)); continue; fi
    if ! json="$(jq -c . < "${file}" 2>/dev/null)"; then bad=$((bad + 1)); continue; fi
    # `repo` missing or unreadable also makes it a FAILED candidate: it is a
    # well-formed file that could still have been this session's entry.
    if ! printf '%s' "${json}" | jq -e 'type == "object" and (.repo | type == "string")' >/dev/null 2>&1; then
      bad=$((bad + 1)); continue
    fi
    # THE ENTRY'S `repo` IS CANONICALISED HERE, in the adapter, because the
    # contract's schema table makes the match bilateral -- "Matched exactly,
    # AFTER REALPATH, against the session's own" -- and the session's side is
    # already canonical (fs_git_common_dir realpaths it). Comparing a raw
    # string against a canonical one means a grammatically fine entry whose
    # `repo` carries a trailing slash, a `..`, or a symlinked-but-equivalent
    # prefix NEVER matches, is never validated, and is not even a failed
    # candidate -- it parses and has a string `repo`. The session then reports
    # zero channels and exit 0: a dark channel indistinguishable from "not
    # opted in", which is the exact outcome this facility exists to eliminate.
    #
    # `realpath -m` because the path need not exist: an entry naming a repo
    # that was deleted, or that belongs to another machine, still normalises
    # lexically and simply matches no session -- which is correct and quiet.
    # Canonicalising is a filesystem operation, so it belongs in this file and
    # not in descriptor.sh, which stays a pure string comparator.
    local repo_raw repo_canon
    repo_raw="$(printf '%s' "${json}" | jq -r '.repo')"
    repo_canon="$(realpath -m -- "${repo_raw}" 2>/dev/null)" || repo_canon="${repo_raw}"
    json="$(printf '%s' "${json}" | jq -c --arg r "${repo_canon}" '.repo = $r')" || continue
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

# ============================================================================
# WRITES (DND-184). Everything above this line is read-only; everything below
# it can change something on disk, and each one carries the crash story that
# decided its ordering.
# ============================================================================

# --- clocks -----------------------------------------------------------------
# Local wall time, always. The contract is explicit that `received_at` is a
# SERVER stamp with a measured ~2.5s skew against this machine, and that
# "staleness, latency, and liveness checks MUST use local file mtimes, never a
# `received_at` differenced against local `now`". Retention is a liveness
# question, so every clock it uses is local.

fs_now_epoch()    { date -u +%s; }
fs_now_rfc3339()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# fs_epoch_of_rfc3339 <stamp> -- empty + status 1 on anything unparseable.
# An unparseable `rotated_at` must not become epoch 0, which would read as
# "1970" and make every channel instantly sweepable. Empty is the input
# logchan_should_rotate/sweep both answer "no" to.
fs_epoch_of_rfc3339() {
  local s="$1" out
  [ -n "${s}" ] || return 1
  fs_require_date_d || return 1
  out="$(date -u -d "${s}" +%s 2>/dev/null)" || return 1
  case "${out}" in ''|*[!0-9-]*) return 1 ;; esac
  printf '%s\n' "${out}"
}

# fs_require_date_d
#
# `date -u -d <rfc3339>` is a GNU extension. Without it this function fails for
# EVERY input, and the failure is indistinguishable from "this generation has
# no rotated_at": `_inbox_retain` takes the absent/unparseable branch, re-stamps
# `rotated_at` to now on every ack, and rotation therefore NEVER FIRES. The
# inbox grows forever, every ack still reports success, and nothing anywhere
# says the retention policy stopped existing.
#
# That is the standing missing-input shape -- an absent capability reading as a
# benign "nothing to do" -- in the one subsystem whose whole job is to delete
# things on a schedule. It gets reported once per process rather than silently.
#
# Reported, NOT fatal: mail still delivers without retention, and taking the
# reader down over a missing date(1) flag would turn a disk-growth problem into
# an outage.
_INBOX_DATE_D_OK=""
fs_require_date_d() {
  if [ -z "${_INBOX_DATE_D_OK}" ]; then
    if date -u -d "2026-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
      _INBOX_DATE_D_OK=yes
    else
      _INBOX_DATE_D_OK=no
      inbox_fail "this date(1) does not support -d, so retention cannot run" \
        "install GNU coreutils (on macOS: brew install coreutils, and put gnubin on PATH). Mail still delivers; what stops is ROTATION AND THE SWEEP, so the channel file grows without bound and nothing else would have told you."
    fi
  fi
  [ "${_INBOX_DATE_D_OK}" = "yes" ]
}

# fs_mtime_epoch <path>
fs_mtime_epoch() {
  [ -e "$1" ] || return 1
  stat -c %Y "$1" 2>/dev/null || return 1
}

# --- atomic state write -----------------------------------------------------

# fs_write_state <path> <json>
#
# Contract: "write a sibling temp file, fsync, then rename(2) into place. A
# state file truncated by a crash loses the offset and re-reports everything."
#
# The temp file is a SIBLING, not something under /tmp: rename(2) is only
# atomic within one filesystem, and a cross-device rename degrades into
# copy-then-unlink, which is exactly the non-atomic write this exists to avoid.
#
# `sync` rather than a true per-file fsync, because shell has no fsync(2).
# Named rather than glossed: this is weaker than the contract's letter (it
# flushes more than this file and guarantees less about ordering than fsync on
# a held descriptor would), and it is the strongest form available here. The
# rename is still atomic, which is the half that protects a reader from ever
# seeing a truncated state file.
fs_write_state() {
  local path="$1" json="$2" tmp

  # I-7: a symlinked state file is refused. Without this, `> "${path}"` (and
  # even the rename's target resolution) follows the link and the state lands
  # wherever it points -- and the mode you checked is not the mode you wrote.
  fs_assert_regular "${path}" || return 1

  if ! printf '%s' "${json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    inbox_fail "refusing to write a state file that is not a JSON object" \
      "this is a bug in the reader, not in your setup: the state writer was handed a non-object. Re-run; if it recurs, inspect ${path} and report it."
    return 1
  fi

  tmp="${path}.tmp.$$"
  ( umask 077; printf '%s\n' "${json}" > "${tmp}" ) || {
    inbox_fail "cannot write the state file beside \"${path}\"" \
      "check that the directory is writable and mode 0700; the state file is written as a sibling temp file and renamed into place."
    return 1
  }
  chmod 0600 "${tmp}" 2>/dev/null || true
  sync "${tmp}" 2>/dev/null || sync 2>/dev/null || true
  if ! mv -f "${tmp}" "${path}"; then
    rm -f "${tmp}" 2>/dev/null || true
    inbox_fail "cannot atomically replace the state file \"${path}\"" \
      "check the permissions on the directory holding it; the reader writes a sibling temp file and renames it into place, and the rename failed."
    return 1
  fi
  return 0
}

# --- retention: rotate and sweep --------------------------------------------

# fs_rotated_name <inbox-path>  -- exactly one generation, `<channel>.jsonl.1`.
fs_rotated_name() { printf '%s.1\n' "$1"; }

# fs_rotate_log <inbox-path> <offset>
#
# MUST be called with the consumer lock held. Status 0 = rotated; status 2 =
# ABANDONED because the file moved; status 1 = a real failure.
#
# THE RE-CHECK IS THE WHOLE FUNCTION. The lock excludes other READERS, not the
# writer, which appends at any moment -- so a line landing between the trigger
# evaluation and the rename is carried into `.1`, and NOTHING EVER READS `.1`.
# Those bytes are lost with no error, no doorbell anomaly and no way to notice.
# It is the same defect the contract forbids when it says ack MUST NOT
# recompute EOF, arriving from the other direction. Abandoning costs one
# deferred rotation; the trigger will still hold next time.
#
# ABANDONED IS STATUS 2, NOT 1: a deferred rotation is the system working, and
# a caller that treated it as a failure would print a refusal on an ordinary
# healthy path.
fs_rotate_log() {
  local inbox="$1" offset="$2" size target

  case "${offset}" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "${inbox}" ] || return 2
  fs_assert_regular "${inbox}" || return 1

  size="$(fs_size "${inbox}")"
  if [ "${size}" != "${offset}" ]; then
    return 2                    # bytes arrived; abandon, do not carry them off
  fi

  target="$(fs_rotated_name "${inbox}")"
  fs_assert_regular "${target}" || return 1
  # The ONE place a destructive rename is correct: exactly one generation is
  # kept, and renaming over the older one is the entire point. The contract's
  # non-clobbering rules govern DELIVERY, where an overwrite loses a message.
  if ! mv -f "${inbox}" "${target}"; then
    inbox_fail "cannot rotate the channel file \"${inbox}\"" \
      "check the permissions on \$ATHENA_INBOX_ROOT; rotation renames the live file over its single kept generation."
    return 1
  fi
  chmod 0600 "${target}" 2>/dev/null || true
  # The mtime stamp is a CONVENIENCE for a human running `ls -l`, not the
  # retention clock -- rename(2) preserves mtime, so without this the `.1`
  # carries the timestamp of its last append. `rotated_at` in the state file is
  # the authority (see logchan_should_sweep).
  touch "${target}" 2>/dev/null || true
  return 0
}

# fs_sweep_generation <rotated-path>
#
# `unlink` ONLY. A reader MUST NOT attempt a secure erase: on a copy-on-write
# or SSD-backed filesystem it does not do what its name claims, and offering it
# invites the false belief that the content is unrecoverable. Status 0 whether
# or not the file was there -- the sweep is idempotent by nature.
fs_sweep_generation() {
  local path="$1"
  [ -e "${path}" ] || return 0
  fs_assert_regular "${path}" || return 1
  rm -f "${path}" || {
    inbox_fail "cannot delete the rotated generation \"${path}\"" \
      "check the permissions on \$ATHENA_INBOX_ROOT; the rotated generation is deleted 14 days after the rotation that created it."
    return 1
  }
  return 0
}

# --- the doorbell -----------------------------------------------------------

# fs_bump_doorbell <path>
# Zero bytes, 0600, mtime bumped. The contract: it is a bell, not a letter --
# it MUST stay zero bytes and carry no count, payload or hint.
#
# `touch` is an ATTRIB-only change on an existing file, which is precisely why
# a waiter MUST watch `attrib` as well as `modify`. Creating it when absent is
# allowed for a reader ("a waiter MAY create a zero-byte 0600 doorbell").
fs_bump_doorbell() {
  local path="$1"
  fs_assert_regular "${path}" || return 1
  ( umask 077; : > "${path}" ) 2>/dev/null || return 1
  chmod 0600 "${path}" 2>/dev/null || true
  touch "${path}" 2>/dev/null || return 1
  return 0
}

# --- maildir ack ------------------------------------------------------------

# fs_maildir_ack <read-dir> <name> <ack-dir>
#
# A MOVE IS THE ACK. Never a delete, never a copy:
#   * delete -- `.acked/` is the only durable transcript of the collaboration,
#     and the contract forbids deleting a message outright;
#   * copy -- would leave the original in place, so the message stays unread
#     forever while looking acked, and the pair can silently diverge.
#
# NON-CLOBBERING. `mv` over an existing destination silently replaces it, so a
# re-ack of a name already in `.acked/` would destroy the earlier message with
# no error. Refused instead: two different messages sharing a name is a fact
# worth surfacing, and an idempotent re-ack of the SAME message cannot arise
# here because the source no longer exists after the first one.
fs_maildir_ack() {
  local read_dir="$1" name="$2" ack_dir="$3" src="$1/$2" dst

  # The grammar is re-checked HERE, not only in the manager that calls this.
  # The manager does validate today, but this function takes a bare name and
  # joins it onto a directory: a primitive that is safe only because of its
  # current caller is not safe, and the next caller inherits nothing. Same
  # reasoning as logchan_scan re-validating its own offset.
  if ! maildir_valid_message_name "${name}"; then
    inbox_fail "refusing to move a message whose filename does not match the contract's grammar" \
      'a message filename is <YYYYMMDD>T<HHMMSS>Z-<seq>-<slug>.md; a name from another party is data, never a path.'
    return 1
  fi

  fs_assert_not_symlink "${read_dir}" || return 1
  if [ ! -f "${src}" ] || [ -L "${src}" ]; then
    inbox_fail "there is no such message to ack in this channel's read directory" \
      "list the channel again with read-inbox --peek; the message may already have been acked, or it may never have been a regular file."
    return 1
  fi

  if [ ! -d "${ack_dir}" ]; then
    mkdir -p -m 0700 "${ack_dir}" 2>/dev/null || {
      inbox_fail "cannot create this channel's .acked directory" \
        "check that the read directory is writable and mode 0700; a maildir ack moves the message into .acked/ beside it."
      return 1
    }
  fi
  fs_assert_not_symlink "${ack_dir}" || return 1

  dst="${ack_dir}/${name}"
  if [ -e "${dst}" ]; then
    inbox_fail "a different message with this name is already in .acked/" \
      "move the existing file aside by hand and re-run; the ack refuses to rename over it, because .acked/ is the only durable transcript of this collaboration."
    return 1
  fi
  if ! mv "${src}" "${dst}"; then
    inbox_fail "cannot move the message into .acked/" \
      "check the permissions on the read directory and on .acked/ (both 0700); a maildir ack is a move, never a delete."
    return 1
  fi
  return 0
}

# fs_read_message <path>  -- one maildir message's content, symlink refused.
fs_read_message() {
  local path="$1"
  fs_assert_regular "${path}" || return 1
  [ -f "${path}" ] || return 1
  cat "${path}"
}
