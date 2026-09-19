#!/usr/bin/env bash
# lock.sh -- the consumer lock. SIDE EFFECTS.
#
# `<channel>.consumer.lock` beside the channel, taken with `flock -n`.
# Non-holders READ; only the holder ADVANCES (offset, maildir ack, sweep,
# rotation).
#
# ================== THE PART THAT LOOKS LIKE A BUG AND IS NOT ==============
#
# There is NO staleness check, NO pid probe, and NOTHING is ever reaped. The
# ticket and the QA matrix (M-3) ask for "a lock whose pid is dead is reaped by
# a direct pid check". The contract -- later, and normative -- forbids exactly
# that (`ai/contracts/athena-inbox.md` -> "The designated consumer"):
#
#     `flock` alone decides ownership, and there is nothing to reap. A flock(2)
#     lock is released by the kernel when the holding descriptor closes,
#     including on process death -- so a dead holder cannot block `flock -n`,
#     and no staleness check is needed or wanted. [...] An implementer who adds
#     a pid check and steals the lock when the content "looks stale" has built
#     a race against a live holder, which is worse than the problem it imagines
#     it is solving.
#
# So M-3's OBSERVABLE claim -- the ack proceeds when the recorded pid is dead --
# holds here, and holds for a better reason than a pid check: the kernel
# released the lock when that process died, so `flock -n` simply succeeds. The
# suite asserts it that way, and asserts separately that no `pgrep` exists
# anywhere in this skill (the harness Hard Rule's item 4: a `pgrep -f` wait
# self-matches the waiting shell and never exits).
#
# The `{session_id, pid, started_at}` content is DIAGNOSTICS -- for a human
# reading the file, and for the `Fix:` line on a refusal. It MUST NEVER be read
# to decide whether the lock is available, and `inbox_lock_holder_hint` below
# is the only reader of it, called only after `flock -n` has ALREADY refused.
#
# ================== HOLD THE DESCRIPTOR ACROSS THE WHOLE ADVANCE ===========
#
# Not merely across the write. A lock taken and released around the state write
# leaves the READ-THEN-ACK interval unprotected, and that is the interval that
# matters: two sessions both read from offset N, both ack to offset M, and the
# second one's report is a duplicate of the first's. The fd is held at process
# scope for exactly that reason -- `exec` on a numbered descriptor rather than
# a `flock ... -c 'cmd'` wrapper, because the advance spans several commands
# and a subshell would drop the fd at the end of the first one.
#
# Source order: err.sh, names.sh, fs.sh, then this file. Requires flock(1).

# Fd 9 is the ADVANCE lock, held across read+ack. There is deliberately only
# one: a second fd on the same file from the same process would fail `flock -n`
# against our own lock (flock is per open-file-description), so a "sweep-only"
# second acquire would silently skip the sweep on exactly the path that is
# entitled to run it. `inbox_lock_acquire` is therefore IDEMPOTENT for the path
# it already holds.
# THE FD IS ALLOCATED AT ACQUIRE TIME, NOT HARD-CODED. A literal `exec 9<>`
# silently clobbers fd 9 when a caller already has it open -- a wrapper's
# `9>log`, a hook harness -- and that caller would find its own descriptor
# replaced by our lock with nothing said. `exec {var}<>` asks bash for a free
# descriptor (>= 10) instead, and the number lands in INBOX_LOCK_FD for
# `flock` and for the close. It stays empty until something is held, which is
# also what makes "are we holding anything" answerable without a stat.
INBOX_LOCK_FD=""
INBOX_LOCK_PATH=""

# inbox_lock_acquire <lock-path> [channel-label]
# Status 0 = held by us. Status 1 = refused (someone else holds it), with a
# `Fix:` clause naming the holder as far as the diagnostics allow.
inbox_lock_acquire() {
  local path="$1" label="${2:-this channel}" dir hint

  if [ -n "${INBOX_LOCK_PATH}" ] && [ "${INBOX_LOCK_PATH}" = "${path}" ]; then
    return 0                       # already ours; see the fd note above
  fi
  if [ -n "${INBOX_LOCK_PATH}" ]; then
    # One advance at a time, per process. Swapping fd 9 to a second channel
    # would RELEASE the first channel's lock mid-advance without anything
    # saying so.
    inbox_fail "this process already holds a consumer lock for another channel" \
      "advance one channel at a time: finish (or abandon) the current read/ack before acquiring ${label}'s lock."
    return 1
  fi

  # A symlinked lock file would have `exec 9>` follow it and lock -- and later
  # rewrite -- a file somewhere else entirely. lstat first, exactly as fs.sh
  # does for the inbox and the state file.
  fs_assert_regular "${path}" || return 1

  dir="${path%/*}"
  if [ ! -d "${dir}" ]; then
    # The reader creates its own lock file (the contract's conformance
    # checklist forbids a WRITER from creating one, not a reader), so it may
    # need the directory. 0700, like the root.
    mkdir -p -m 0700 "${dir}" 2>/dev/null || {
      inbox_fail "cannot create the directory for ${label}'s consumer lock" \
        "check that \$ATHENA_INBOX_ROOT exists and is writable (it should be mode 0700), then re-run."
      return 1
    }
  fi

  # `<>` (read-write), NOT `>`. A `>` redirect TRUNCATES on open, and the open
  # happens BEFORE flock decides -- so a non-holder's failed attempt would wipe
  # the live holder's diagnostics on its way to being refused, and the refusal
  # it then printed could not name the holder it had just erased. The suite
  # caught exactly that. `<>` creates the file if absent and truncates nothing.
  if ! exec {INBOX_LOCK_FD}<>"${path}"; then
    inbox_fail "cannot open ${label}'s consumer lock file" \
      "check the permissions on \$ATHENA_INBOX_ROOT (0700) and on the .consumer.lock file (0600), then re-run."
    return 1
  fi

  if ! flock -n "${INBOX_LOCK_FD}"; then
    hint="$(inbox_lock_holder_hint "${path}")"
    exec {INBOX_LOCK_FD}>&-; INBOX_LOCK_FD=""
    inbox_fail "another session is the designated consumer of ${label}${hint:+ (${hint})}" \
      "read without advancing: re-run with --peek. Only one session may advance a channel's offset or ack its mail; when that session exits, the kernel releases the lock and this one can advance."
    return 1
  fi

  INBOX_LOCK_PATH="${path}"
  chmod 0600 "${path}" 2>/dev/null || true
  # Written AFTER the lock is held, so the content can never describe a holder
  # that is not the holder, and through a SEPARATE truncating open now that
  # we are the holder --
  # the held descriptor is deliberately non-truncating (see above), so writing
  # through it would leave a shorter new document tailed by the old one's
  # bytes. Safe to truncate here precisely because we are the holder.
  printf '{"session_id":%s,"pid":%s,"started_at":%s}\n' \
    "$(printf '%s' "${CLAUDE_SESSION_ID:-unknown}" | jq -R .)" \
    "$$" \
    "$(printf '%s' "$(fs_now_rfc3339)" | jq -R .)" \
    > "${path}" 2>/dev/null || true
  return 0
}

# inbox_lock_release
# Closing the descriptor IS the release; the file is deliberately left behind
# (it is the diagnostics, and an unlink would race a waiter that has already
# opened it).
inbox_lock_release() {
  [ -n "${INBOX_LOCK_PATH}" ] || return 0
  [ -n "${INBOX_LOCK_FD}" ] && { exec {INBOX_LOCK_FD}>&-; } 2>/dev/null
  INBOX_LOCK_FD=""
  INBOX_LOCK_PATH=""
  return 0
}

# inbox_lock_holder_hint <lock-path>
# DIAGNOSTICS ONLY, for a `Fix:` line. Called only after `flock -n` has already
# decided. Unparseable or absent content yields an empty string and changes
# nothing -- the contract is explicit that this content never decides anything.
inbox_lock_holder_hint() {
  local path="$1" sid pid
  [ -f "${path}" ] || return 0
  sid="$(jq -r '.session_id // empty' < "${path}" 2>/dev/null)"
  pid="$(jq -r '.pid // empty' < "${path}" 2>/dev/null)"
  [ -n "${sid}${pid}" ] || return 0
  printf 'held by pid %s, session %s\n' "${pid:-?}" "${sid:-?}"
}

# inbox_lock_try <lock-path>
# The SWEEP-ONLY acquire for the count path. Silent on failure BY DESIGN:
# the contract -- "The sweep" -- says a count neither advances state nor needs
# the lock, so "someone else is reading" must not make `inbox-status` fail or
# print anything. The sweep is skipped this time and the count reports
# normally. Without that, an implementer either breaks the status command
# whenever a reading session holds the lock, or never sweeps on a count at all
# and turns the every-count rule into dead letter.
# Status 0 = NEWLY acquired: the caller took it and MUST release it.
# Status 2 = already held by this process: the caller did NOT take it and MUST
#            NOT release it.
# Status 1 = not acquired.
#
# The three-way status is not fussiness. Collapsing "newly acquired" and
# "already ours" into 0 is exactly the shape that makes a caller release a
# lock it never took: the ack path takes the lock for the whole advance and
# then sweeps, and a sweep that released on its way out would drop the
# channel's lock MID-ADVANCE -- `INBOX_LOCK_PATH` cleared, fd 9 closed, the
# EXIT trap in bin/read-inbox a no-op, and another session free to take the
# channel while this one still believes it is the designated consumer. That
# it is currently harmless rests on the sweep happening to run after the state
# write, which makes the "hold the descriptor across the whole advance"
# invariant a property of CALL ORDERING rather than of this file. Invariants
# that live in call ordering are the ones that break when someone reorders
# two lines for an unrelated reason.
inbox_lock_try() {
  local path="$1"
  if [ -n "${INBOX_LOCK_PATH}" ] && [ "${INBOX_LOCK_PATH}" = "${path}" ]; then
    return 2
  fi
  [ -n "${INBOX_LOCK_PATH}" ] && return 1
  fs_assert_regular "${path}" >/dev/null 2>&1 || return 1
  [ -d "${path%/*}" ] || return 1
  exec {INBOX_LOCK_FD}<>"${path}" 2>/dev/null || return 1
  if ! flock -n "${INBOX_LOCK_FD}"; then
    exec {INBOX_LOCK_FD}>&-; INBOX_LOCK_FD=""
    return 1
  fi
  INBOX_LOCK_PATH="${path}"
  chmod 0600 "${path}" 2>/dev/null || true
  return 0
}
