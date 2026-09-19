#!/usr/bin/env bash
# inbox.sh -- MANAGER. Composes the side-effect adapter (fs.sh) with the domain
# (names / descriptor / logchan / maildir) to fulfil the use cases. It returns
# domain values; it renders nothing.
#
# This slice (DND-183) implements exactly one use case: COUNT. Read, ack, send
# and wait arrive with later tickets and go here too, so that there is one path
# every caller takes -- which is what makes the authorization checks below
# unbypassable rather than merely present.
#
# THE ONE RESOLUTION PATH:  cwd -> git common dir -> registry entry keyed by
# that realpath -> the channels that entry declares.  Nothing else. In
# particular there is NO fallback to "scan the inbox root and show whatever is
# there": that fallback passes every other case in the QA plan and fails its
# *Tenancy boundary* end-to-end case (currently step 8), where a session rooted
# in one project must see NO channel belonging to another.
#
# Source order: err.sh, names.sh, descriptor.sh, logchan.sh, maildir.sh, fs.sh,
# then this file. Requires jq.

# inbox_entry [cwd]
# The registry entry owning this session, as one-line JSON. Empty output with
# status 1 when this session owns nothing.
#
# NOT OPTING IN IS NOT A FAULT (D-11). A cwd outside any git repository, and a
# repo with no registry entry, are the ordinary state of most directories on
# this machine: both yield nothing, silently, status 1, and the callers below
# turn that into "zero channels, exit 0". An error here would train the reader
# to ignore errors.
# inbox_failed_candidates
# How many grammar-conformant registry candidates could not be read. Reported
# as a COUNT, never by name -- every other file in projects/ belongs to a
# different tenant, and a denial must not enumerate them.
#
# A separate function rather than a variable set by inbox_entry: every caller
# runs inbox_entry inside `$(...)`, which is a SUBSHELL, so an assignment
# there would never reach the caller -- the count would read 0 everywhere and
# the MUST would look satisfied while doing nothing.
inbox_failed_candidates() {
  local records
  records="$(fs_registry_records)" || { printf '0\n'; return 0; }
  printf '%s\n' "${records}" | awk -F'\t' '/^#unparseable/{n=$2} END{print n+0}'
}

inbox_entry() {
  local repo records entry rc
  repo="$(fs_git_common_dir "${1:-.}")" || return 1
  records="$(fs_registry_records)" || return 2

  entry="$(printf '%s\n' "${records}" | descriptor_select "${repo}")"; rc=$?
  [ "${rc}" -ne 2 ] || return 2                       # ambiguous: fatal

  if [ "${rc}" -eq 0 ]; then printf '%s\n' "${entry}"; return 0; fi

  # No entry matched. If some registry file could not be parsed, ONE OF THEM
  # MAY BE THIS PROJECT'S, and "no entry" would then be a lie that reads
  # exactly like "not opted in". So it refuses -- but by COUNT, never by name:
  # every other file in projects/ belongs to a different tenant, and a denial
  # must not enumerate them.
  local failed
  failed="$(printf '%s\n' "${records}" | awk -F'\t' '/^#unparseable/{n=$2} END{print n+0}')"
  if [ "${failed}" -gt 0 ]; then
    inbox_fail "${failed} registry entry(s) unreadable, and no entry matched this repo -- one of them may be this project's" \
      "run: for f in \"\${ATHENA_INBOX_ROOT:-\$HOME/.local/share/athena}\"/projects/*.json; do jq . \"\$f\" >/dev/null || echo \"\$f\"; done -- then fix the JSON in whichever file that names."
    return 2
  fi
  return 1
}

# inbox_channels [cwd]
# Channel names this session owns, one per line. Exit 0 and silence when none.
inbox_channels() {
  local entry rc
  entry="$(inbox_entry "${1:-.}")"; rc=$?
  [ "${rc}" -ne 2 ] || return 1          # a malformed/ambiguous registry: fatal
  [ -n "${entry}" ] || return 0          # nothing owned: not a fault
  descriptor_validate "${entry}" || return 1
  descriptor_channel_names "${entry}"
}

# inbox_resolve_channel <channel> [cwd]
# "<label>\t<path>" lines for a channel this session owns.
#
# DENY BY DEFAULT (M-6 / A-8). A channel this entry does not declare is not
# addressable, and the refusal lists only the channels THIS entry declares --
# it never echoes the requested name back. An error message is a disclosure
# channel: echoing an unknown name turns the denial into an oracle that
# confirms what a caller guessed, and listing another project's channels would
# hand over the namespace outright.
# _inbox_no_entry_refusal <cwd>
#
# "Nothing resolved" has THREE causes, and collapsing them into one message is
# the epic's standing defect class in its quiet form: a MISSING input reported
# as a benign "not this environment".
#
#   * cwd is in no git repository      -> the repo identity cannot be computed
#   * the registry DIRECTORY is absent -> the root is not provisioned, or
#                                         $ATHENA_INBOX_ROOT points at nothing
#   * the directory exists, nothing claims this repo -> genuinely not opted in
#
# Only the third is "this project declares no channels". Told the third when
# the truth is the second, an operator whose delivery WAS healthy goes looking
# for a missing entry under a directory that does not exist, and a lost or
# unmounted root reads as a project that was never set up. The three get three
# messages.
#
# NOTE ON DISCLOSURE: this names only the registry directory (read from this
# session's own environment) and this repo's own common dir. It never names,
# counts, or implies another tenant's entry -- see *Finding the entry*.
#
# This is a diagnosis, never a decision: all three are refusals, and the
# NON-ZERO status is identical. A reader asked for a named channel and did not
# get it; that is a failure whichever cause produced it. (The COUNT path is
# the opposite by contract -- "no entry is not a fault, zero channels, exit 0"
# -- and an unprovisioned root is caught there by check-inbox-registry, which
# runs unprompted in the harness gate rather than waiting to be thought of.)
_inbox_no_entry_refusal() {
  local cwd="${1:-.}" regdir
  regdir="$(fs_registry_dir)"

  if ! fs_git_common_dir "${cwd}" >/dev/null 2>&1; then
    inbox_fail "this directory is in no git repository, so it has no inbox identity" \
      "a project's channels are keyed by the realpath of its git common dir. Run this from inside the repo whose mail you want."
    return 1
  fi
  if [ ! -d "${regdir}" ]; then
    inbox_fail "the inbox registry directory does not exist: ${regdir}" \
      "this is a MACHINE-level condition, not a project one -- no project on this machine has channels while that directory is missing. Check \$ATHENA_INBOX_ROOT points where you think (default: \$HOME/.local/share/athena) and that the root is present, before concluding this project is not opted in."
    return 1
  fi
  inbox_fail "this project declares no inbox channels" \
    "add ${regdir}/<project>.json with a \"repo\" naming this repo's git common dir (realpath \"\$(git rev-parse --git-common-dir)\"), or run from a project that has one."
  return 1
}

inbox_resolve_channel() {
  local chan="$1" entry rc declared
  entry="$(inbox_entry "${2:-.}")"; rc=$?
  if [ "${rc}" -eq 2 ]; then return 1; fi
  if [ -z "${entry}" ]; then
    _inbox_no_entry_refusal "${2:-.}"
    return 1
  fi
  descriptor_validate "${entry}" || return 1

  if ! descriptor_has_channel "${entry}" "${chan}"; then
    declared="$(descriptor_channel_names "${entry}" | paste -sd, -)"
    inbox_fail "no such channel in this project's registry entry" \
      "ask for one of this project's channels: ${declared:-<none declared>}."
    return 1
  fi
  descriptor_resolve "$(fs_inbox_root)" "${entry}" "${chan}"
}

# _inbox_path <label> <resolved>
_inbox_path() { printf '%s\n' "$2" | awk -F'\t' -v k="$1" '$1==k {print $2; exit}'; }

# _inbox_count_log <resolved-paths> <schema_csv>
# Emits the counting fields for one log channel as JSON.
#
# Three decisions live here and each is invisible in production until it burns
# someone:
#
#  * NEVER DELIVERED is reported separately. "nobody ever registered the
#    writer" and "nothing new arrived" are identical on disk (no file / no new
#    bytes) and must not be identical in output, because the first is a broken
#    setup and the second is a good morning.
#  * A STALE OFFSET IS RECOVERED, not trusted. An offset past EOF means the
#    file was rotated or replaced under us; continuing from it would silently
#    skip every message in the new file, and refusing to read would lose them
#    just as silently. Reset to 0 and re-read.
#  * COUNTS ARE POST-DEDUPE. A pre-dedupe count announces messages the read
#    step then declines to show, which reads as the tool losing mail.
_inbox_count_log() {
  local resolved="$1" schema_csv="${2:-1}"
  local inbox state size offset seen_ev seen_ky slice scan never="false" stale="false"

  inbox="$(_inbox_path inbox "${resolved}")"
  state="$(_inbox_path state "${resolved}")"

  fs_assert_regular "${inbox}" || return 1
  fs_assert_contained "$(fs_inbox_root)" "${inbox}" || return 1
  # Before the slice is read into a shell variable, which cannot carry a NUL
  # and would drop it silently -- shortening the byte count that next_offset
  # is derived from, and printing bash's own warning onto the pre-prompt
  # stream on the way past.
  fs_assert_no_nul "${inbox}" || return 1

  [ -e "${inbox}" ] || never="true"
  size="$(fs_size "${inbox}")"

  # A CORRUPT STATE FILE IS RECOVERED AND REPORTED, never silently absorbed.
  #
  # This was the worst of the swallowed failures. An unparseable state
  # document, or an `offset` that is not a number, used to fall through every
  # `2>/dev/null` into offset=0 with EMPTY seen-sets -- so the whole file was
  # re-read AND deduping was silently switched off, and every message ever
  # acked came back as `new`. Unlike the offset-past-EOF path below it set no
  # flag, so the inflated count was indistinguishable from real mail in the
  # pre-prompt position: the tool appearing to work perfectly while announcing
  # a month of old messages as this morning's.
  #
  # Recovering rather than refusing is deliberate -- re-reading over-reports,
  # which is recoverable, where refusing would wedge the channel entirely. But
  # it is reported, because a silent recovery is how this stays invisible.
  local state_json state_bad="false"
  state_json="$(fs_read_state "${state}")" || return 1
  if ! printf '%s' "${state_json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    state_bad="true"; state_json='{}'
  fi

  offset="$(printf '%s' "${state_json}" | jq -r '(.offset // 0) | tostring' 2>/dev/null)" || offset=0
  case "${offset}" in
    ''|*[!0-9]*) offset=0; state_bad="true" ;;
  esac
  if [ "${offset}" -gt "${size}" ]; then offset=0; stale="true"; fi

  # The seen-sets must be an array of strings, or dedupe is silently a no-op.
  if ! printf '%s' "${state_json}" | jq -e \
       '((.seen_event_ids // []) | type == "array" and all(type == "string"))
        and ((.seen_keys // []) | type == "array" and all(type == "string"))' >/dev/null 2>&1; then
    state_bad="true"
    seen_ev=""; seen_ky=""
  else
    seen_ev="$(printf '%s' "${state_json}" | jq -r '(.seen_event_ids // [])[]' 2>/dev/null)"
    seen_ky="$(printf '%s' "${state_json}" | jq -r '(.seen_keys // [])[]' 2>/dev/null)"
  fi

  if [ "${state_bad}" = "true" ]; then
    inbox_fail "channel file \"$(_inbox_path inbox "${resolved}" | sed 's|.*/||')\" has an unreadable state file, so its counts are not deduped and include messages already read" \
      "inspect ${state} (check it with: jq . \"${state}\"). Until it is valid JSON with a numeric \"offset\" and string arrays for \"seen_event_ids\"/\"seen_keys\", this channel re-reports everything; delete the file to start cleanly from offset 0."
  fi

  slice="$(fs_slice_from "${inbox}" "${offset}"; printf X)"; slice="${slice%X}"

  # The scan's status is CHECKED, and its emptiness is checked separately.
  # Neither is paranoia: `$(...)` discards the exit status of the command
  # inside it, and a failed scan produces no output, so feeding that empty
  # string onward gives jq empty input -- which emits nothing and exits ZERO.
  # The failure would then travel as a successful count of nothing: the caller
  # sees a well-formed empty answer, every other channel is discarded with it,
  # and a session that has mail is told it has none. That is the exact
  # "malformed input degrades into silence" conflation this file refuses
  # everywhere else, and it is worse here because the output is injected
  # before the user has spoken.
  if ! scan="$(printf '%s' "${slice}" | logchan_scan "${offset}" "${schema_csv}" "${seen_ev}" "${seen_ky}" 2>/dev/null)" \
     || [ -z "${scan}" ]; then
    inbox_fail "could not count channel \"$(_inbox_path inbox "${resolved}" | sed 's|.*/||')\": the scan failed" \
      "inspect the channel's .jsonl for a line this reader cannot process, or re-run with --json to see which channels did count. A counting failure is reported rather than shown as zero, because zero would read as \"no mail\"."
    return 1
  fi

  # COUNTS ONLY. `messages` carries ts/channel/event_id and is dropped here
  # rather than at the renderer: a body, a subject or a peer-chosen string must
  # not exist in the manager's return value at all, so no future renderer can
  # print one by accident.
  printf '%s' "${scan}" | jq -e -c \
    --argjson never "${never}" --argjson stale "${stale}" --argjson sbad "${state_bad}" \
    '{new: .new, unreadable: .unreadable, never_delivered: $never,
      offset_reset: $stale, state_unreadable: $sbad}'
}

# _inbox_count_maildir <resolved-paths>
_inbox_count_maildir() {
  local resolved="$1" read_dir name n=0 never="false"
  read_dir="$(_inbox_path read_dir "${resolved}")"
  fs_assert_not_symlink "${read_dir}" || return 1
  fs_assert_contained "$(fs_inbox_root)" "${read_dir}" || return 1
  [ -d "${read_dir}" ] || never="true"

  # Counted over a NUL-DELIMITED listing, one name at a time. A line-delimited
  # listing cannot represent a filename containing a newline, and the slug is
  # prose the PEER chose -- so counting lines would let the sender decide how
  # many messages it had sent.
  # `maildir_is_unread` is a NAME predicate and deliberately stays one, so the
  # "is it actually a message file" half lives here, where the filesystem is.
  # A subdirectory that is not `tmp` would otherwise count as a message.
  while IFS= read -r -d '' name; do
    maildir_is_unread "${name}" || continue
    [ -f "${read_dir}/${name}" ] || continue
    [ -L "${read_dir}/${name}" ] && continue
    n=$((n + 1))
  done < <(fs_list_dir_z "${read_dir}")

  # Again counts only: the FILENAMES are peer-chosen prose and never leave
  # this function.
  jq -n -c --argjson n "${n}" --argjson never "${never}" \
    '{unread: $n, never_delivered: $never}'
}

# inbox_status_json [cwd]
# {"channels":[{"name":…,"kind":…,"new":…}…]} -- counts only, for every channel
# this session owns. An empty channel list is a legitimate, silent result.
# A channel that CANNOT be counted is marked `"error": true` and the run
# CONTINUES. It is not silently dropped, and it does not take the other
# channels down with it.
#
# The previous shape -- `|| return 1` per channel -- meant one symlinked inbox
# or one unreadable state file suppressed every OTHER channel's count, so a
# session with real mail on channel B was told nothing because channel A is
# misconfigured. That also contradicted err.sh's own contract, which returns a
# status rather than exiting precisely "so a caller can refuse one channel
# without killing a multi-channel run". The refusal for the broken channel has
# already gone to stderr with its `Fix:` clause; the overall exit stays
# non-zero, so the failure is still loud.
inbox_status_json() {
  local entry rc chan kind resolved counts schema_csv out="[]" failed=0

  entry="$(inbox_entry "${1:-.}")"; rc=$?
  [ "${rc}" -ne 2 ] || return 1
  if [ -z "${entry}" ]; then
    jq -n -c --argjson f "$(inbox_failed_candidates)" '{channels: [], failed_candidates: $f}'
    return 0
  fi
  descriptor_validate "${entry}" || return 1

  while IFS= read -r chan; do
    [ -n "${chan}" ] || continue
    counts=""
    if resolved="$(descriptor_resolve "$(fs_inbox_root)" "${entry}" "${chan}")"; then
      kind="$(_inbox_path kind "${resolved}")"
      case "${kind}" in
        log)
          schema_csv="$(printf '%s' "${entry}" | jq -r --arg c "${chan}" \
            '((.channels[$c].schema_v // [1]) | map(tostring) | join(","))')"
          counts="$(_inbox_count_log "${resolved}" "${schema_csv}")" || counts=""
          # THE SWEEP RUNS ON EVERY COUNT, not only inside a rotation (R-6).
          # A channel that rotated once and then went quiet would otherwise
          # keep its rotated generation until it happened to rotate again --
          # which, for a channel measured in hundreds of bytes per week, is
          # never. That is the case the 14-day window exists for.
          #
          # It is best-effort and cannot fail a count: gated by the
          # designated-consumer rule, skipped silently when a reading session
          # holds the lock, and it never writes state.
          _inbox_sweep_due "${resolved}" "$(fs_read_state "$(_inbox_path state "${resolved}")" 2>/dev/null)" \
            "channel \"${chan}\"" || true
          ;;
        maildir)
          counts="$(_inbox_count_maildir "${resolved}")" || counts=""
          ;;
        *) continue ;;
      esac
    else
      kind="unknown"
    fi
    if [ -z "${counts}" ]; then
      failed=1
      counts='{"error":true}'
    fi
    out="$(printf '%s' "${out}" | jq -c --arg n "${chan}" --arg k "${kind}" \
      --argjson c "${counts}" '. + [{name: $n, kind: $k} + $c]')"
  done < <(descriptor_channel_names "${entry}")

  printf '%s' "${out}" | jq -c --argjson f "$(inbox_failed_candidates)" \
    '{channels: ., failed_candidates: $f}' || return 1
  # The JSON is emitted FIRST and the failure is signalled by the status, so a
  # caller gets the counts it CAN have plus an honest non-zero.
  [ "${failed}" -eq 0 ]
}

# ============================================================================
# READ / ACK / RETENTION (DND-184).
#
# One gate, one path. Every function below that can ADVANCE state -- the
# offset, a maildir ack, the sweep, a rotation -- goes through
# `inbox_require_consumer` first, and nothing else in the skill may advance
# without it.
# ============================================================================

# inbox_require_consumer <lock-path> <label> [hook-stdin-json]
#
# THE DESIGNATED-CONSUMER RULE. Three conditions, ALL required:
#
#   1. TENANCY -- structural, and already done by the time this is called: the
#      only way to obtain a <lock-path> is `inbox_resolve_channel`, which
#      resolves from the registry entry whose `repo` matches THIS session's git
#      common dir. A channel another project declares has no path here to
#      refuse, because it never resolves. That is deliberately stronger than a
#      check: there is no argument to pass that would reach another tenant's
#      channel.
#   2. NOT A SUBAGENT -- `inbox_is_subagent`, which is main-session-policy.sh's
#      predicate and its fail-open-to-main direction.
#   3. LOCK -- `flock -n`, held by us, across the whole advance.
#
# Reading is OPEN. Only advancing is gated, which is why `--peek` never calls
# this and why a refusal's `Fix:` points at `--peek` rather than at working
# around the lock.
inbox_require_consumer() {
  local lock="$1" label="${2:-this channel}" hook_json="${3:-}"

  if inbox_is_subagent "${hook_json}"; then
    inbox_fail "a subagent may not advance ${label}'s consumption state" \
      "re-run with --peek to read without acking. A subagent that acked would take the offset from the session that reports to Cody: the mail would be marked consumed by a session that finishes without telling anyone, and nothing would record that it happened."
    return 1
  fi
  inbox_lock_acquire "${lock}" "${label}" || return 1
  return 0
}

# --- retention --------------------------------------------------------------

# _inbox_sweep_due <resolved> <state-json> <label> [hook-json]
#
# THE SWEEP, on the COUNT path. Best-effort and silent by design:
#
#   * it is an ACK-PATH operation, so it is gated by the same
#     designated-consumer rule -- deleting content is at least as privileged as
#     advancing past it (R-8, R-9). A subagent or a non-holder may count and
#     may peek; neither sweeps.
#   * FAILING TO ACQUIRE THE LOCK IS NOT AN ERROR FOR A COUNT. The contract is
#     explicit: a count neither advances state nor needs the lock, so a count
#     that wants to sweep attempts `flock -n` for that one operation and simply
#     skips the sweep when another session is reading. Without that sentence an
#     implementer either breaks `inbox-status` whenever a reading session holds
#     the lock, or never sweeps on a count and turns the every-count rule into
#     dead letter.
#   * it NEVER writes state. `rotated_at` absent means the generation is not
#     sweepable at all (see logchan_should_sweep), and the count path must not
#     create a state file the contract says to create only "when there is
#     something to record".
_inbox_sweep_due() {
  local resolved="$1" state_json="$2" label="$3" hook_json="${4:-}"
  local inbox lock gen rot rot_epoch now

  inbox="$(_inbox_path inbox "${resolved}")"
  gen="$(fs_rotated_name "${inbox}")"
  [ -f "${gen}" ] || return 0

  rot="$(printf '%s' "${state_json}" | jq -r '.rotated_at // empty' 2>/dev/null)"
  rot_epoch="$(fs_epoch_of_rfc3339 "${rot}")" || return 0
  now="$(fs_now_epoch)"
  [ "$(logchan_should_sweep "${rot_epoch}" "${now}")" = "yes" ] || return 0

  inbox_is_subagent "${hook_json}" && return 0          # R-9
  lock="$(_inbox_path lock "${resolved}")"
  inbox_lock_try "${lock}" || return 0                  # R-8, and the contract
  fs_sweep_generation "${gen}" || true
  inbox_lock_release
  return 0
}

# _inbox_retain <resolved> <state-json> <offset>
#
# Rotation, on the ACK path, with the lock ALREADY held. Prints the state
# updates rotation implies (`{}` when it did not rotate), so the caller folds
# them into the SAME single atomic state write as the ack itself.
#
# RENAME FIRST, THEN WRITE THE STATE. Both crash stories were weighed and this
# is the cheaper one:
#   * state first, then crash -- `offset = 0` against a still-full live file,
#     so the whole file is re-read. The seen-sets are ring buffers of <= 500,
#     so an 8 MiB re-read re-reports far more than they can absorb: a mass
#     duplicate report, which is the one thing the counts-only surface must
#     never produce.
#   * rename first, then crash -- a stale offset past EOF, which "a stale
#     offset is recovered, not trusted" already handles cleanly. The cost is a
#     `.1` the next rotation may clobber: lost evidence, not lost mail.
# Between losing evidence and flooding the owner with duplicates, take the
# former.
_inbox_retain() {
  local resolved="$1" state_json="$2" offset="$3"
  local inbox size rot rot_epoch now rc

  inbox="$(_inbox_path inbox "${resolved}")"
  size="$(fs_size "${inbox}")"
  now="$(fs_now_epoch)"

  rot="$(printf '%s' "${state_json}" | jq -r '.rotated_at // empty' 2>/dev/null)"
  if [ -z "${rot}" ] || ! rot_epoch="$(fs_epoch_of_rfc3339 "${rot}")"; then
    # The UPGRADE case, and the first one any implementation meets: today's
    # deployed state files carry `offset` and the seen-sets and nothing else.
    # Absent means UNKNOWN, not "infinitely old" -- stamp it to now so the
    # clock starts from the first reader that understood it, and rotate
    # nothing this time. One deferred rotation, versus rotating a file nobody
    # meant to rotate yet.
    jq -n --arg t "$(fs_now_rfc3339)" '{rotated_at: $t}'
    return 0
  fi

  if [ "$(logchan_should_rotate "${offset}" "${size}" "${rot_epoch}" "${now}")" != "yes" ]; then
    printf '{}\n'
    return 0
  fi

  fs_rotate_log "${inbox}" "${offset}"; rc=$?
  case "${rc}" in
    0)
      # Offset resets to 0; the seen-set ring buffers are KEPT (they are what
      # suppresses a re-report if a stale offset later forces a full re-read).
      jq -n --arg t "$(fs_now_rfc3339)" '{offset: 0, rotated_at: $t}'
      ;;
    2)
      # Abandoned: bytes landed between the trigger and the rename. Not a
      # failure -- the trigger will still hold next time, and carrying those
      # bytes into a `.1` nothing ever reads would lose them silently.
      printf '{}\n'
      ;;
    *)
      printf '{}\n'
      ;;
  esac
  return 0
}

# --- read -------------------------------------------------------------------

# inbox_read_json <channel> [cwd]
#
# The read use case. Returns the messages WITH their text, plus the offset the
# caller must ack to and the dedupe keys it must record. It renders nothing --
# the fence is the framework's job -- and it advances nothing, which is what
# makes `--peek` the same code path with the ack step omitted rather than a
# second, subtly different reader.
#
# The offset it returns is the one it actually READ TO. The ack takes that
# value; it MUST NOT recompute EOF. Acking by re-stat'ing EOF silently discards
# every line appended between the read and the ack -- the reader reports N
# messages and marks N+3 consumed, and the three are gone with no error
# anywhere. The contract calls that "the single easiest way to reintroduce
# silent loss, and it looks completely reasonable in code".
inbox_read_json() {
  local chan="$1" cwd="${2:-.}" resolved kind

  resolved="$(inbox_resolve_channel "${chan}" "${cwd}")" || return 1
  kind="$(_inbox_path kind "${resolved}")"
  case "${kind}" in
    log)     _inbox_read_log "${resolved}" "${chan}" "${cwd}" ;;
    maildir) _inbox_read_maildir "${resolved}" "${chan}" ;;
    *)
      inbox_fail "channel \"${chan}\" has a kind this reader cannot read" \
        "set the channel's \"kind\" to \"log\" or \"maildir\" in \$ATHENA_INBOX_ROOT/projects/<project>.json."
      return 1
      ;;
  esac
}

_inbox_read_log() {
  local resolved="$1" chan="$2" cwd="${3:-.}"
  local inbox state entry schema_csv state_json offset size seen_ev seen_ky slice scan

  inbox="$(_inbox_path inbox "${resolved}")"
  state="$(_inbox_path state "${resolved}")"

  fs_assert_regular "${inbox}" || return 1
  fs_assert_contained "$(fs_inbox_root)" "${inbox}" || return 1
  fs_assert_no_nul "${inbox}" || return 1

  entry="$(inbox_entry "${cwd}")" || return 1
  schema_csv="$(printf '%s' "${entry}" | jq -r --arg c "${chan}" \
    '((.channels[$c].schema_v // [1]) | map(tostring) | join(","))')"

  state_json="$(_inbox_state_or_recovered "${state}")" || return 1
  size="$(fs_size "${inbox}")"
  offset="$(_inbox_offset_of "${state_json}" "${size}")"
  seen_ev="$(printf '%s' "${state_json}" | jq -r '(.seen_event_ids // [])[]' 2>/dev/null)"
  seen_ky="$(printf '%s' "${state_json}" | jq -r '(.seen_keys // [])[]' 2>/dev/null)"

  slice="$(fs_slice_from "${inbox}" "${offset}"; printf X)"; slice="${slice%X}"

  # Status AND emptiness both checked: `$(...)` discards the inner status, and
  # a failed scan yields an empty string, which jq reads as empty input and
  # exits ZERO -- so the failure would travel as a successful read of nothing
  # and the session would be told it has no mail when it has some.
  if ! scan="$(printf '%s' "${slice}" | logchan_scan "${offset}" "${schema_csv}" "${seen_ev}" "${seen_ky}" 1)" \
     || [ -z "${scan}" ]; then
    inbox_fail "could not read channel \"${chan}\": the scan failed" \
      "inspect the channel's .jsonl for a line this reader cannot process. A read failure is reported rather than shown as an empty inbox, because an empty inbox reads as \"no mail\"."
    return 1
  fi

  printf '%s' "${scan}" | jq -c --arg c "${chan}" '
    {kind: "log", channel: $c, next_offset: .next_offset,
     unreadable: .unreadable, messages: .messages,
     event_ids: [.messages[].event_id | select(. != "")],
     keys: [.messages[] | select((.channel != "") and (.ts != "")) | "\(.channel):\(.ts)"]}'
}

# _inbox_state_or_recovered <state-path>
# The state document, or `{}` when it is unreadable -- and a REFUSAL on stderr
# when it had to be recovered. A corrupt state file degrading into silence is
# the defect this skill has already been bitten by once: an unparseable
# document fell through to offset 0 with EMPTY seen-sets, so the channel
# re-read everything AND deduping was switched off, re-announcing every acked
# message as new with no flag anywhere.
_inbox_state_or_recovered() {
  local state="$1" json
  json="$(fs_read_state "${state}")" || return 1
  if ! printf '%s' "${json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    inbox_fail "the state file \"${state}\" is not readable as JSON, so this read is NOT deduped and may repeat messages you have already seen" \
      "inspect it with: jq . \"${state}\" -- then fix or delete it. Deleting it starts cleanly from offset 0."
    printf '{}\n'
    return 0
  fi
  printf '%s' "${json}"
}

# _inbox_offset_of <state-json> <size>
# A non-numeric offset is 0, and an offset past EOF is 0 -- the file was
# rotated or replaced underneath the reader, and continuing from a stale offset
# would skip every message in the new file silently.
_inbox_offset_of() {
  local json="$1" size="$2" offset
  offset="$(printf '%s' "${json}" | jq -r '(.offset // 0) | tostring' 2>/dev/null)" || offset=0
  case "${offset}" in ''|*[!0-9]*) offset=0 ;; esac
  [ "${offset}" -le "${size}" ] || offset=0
  printf '%s\n' "${offset}"
}

_inbox_read_maildir() {
  local resolved="$1" chan="$2" read_dir identity name out="[]" content fm body

  read_dir="$(_inbox_path read_dir "${resolved}")"
  identity="$(_inbox_path identity "${resolved}")"
  fs_assert_not_symlink "${read_dir}" || return 1
  fs_assert_contained "$(fs_inbox_root)" "${read_dir}" || return 1

  # NUL-delimited and sorted by NAME: lexicographic filename order IS
  # chronological order, and that rests on the fixed-width timestamp prefix.
  # A line-delimited listing cannot represent a name containing a newline, and
  # the slug is prose the PEER chose.
  while IFS= read -r -d '' name; do
    maildir_is_unread "${name}" || continue
    [ -f "${read_dir}/${name}" ] || continue
    [ -L "${read_dir}/${name}" ] && continue
    content="$(fs_read_message "${read_dir}/${name}"; printf X)" || continue
    content="${content%X}"
    fm="$(printf '%s' "${content}" | maildir_parse_frontmatter)"
    body="$(printf '%s' "${content}" | maildir_body; printf X)"; body="${body%X}"
    out="$(printf '%s' "${out}" | jq -c --arg n "${name}" --argjson f "${fm}" --arg b "${body}" \
      '. + [{name: $n,
             from: (($f.from // "") | tostring),
             to: (($f.to // "") | tostring),
             sent_at: (($f.sent_at // "") | tostring),
             body: $b}]')"
  done < <(fs_list_dir_z "${read_dir}" | sort -z)

  printf '%s' "${out}" | jq -c --arg c "${chan}" --arg id "${identity}" \
    '{kind: "maildir", channel: $c, identity: $id, messages: .}'
}

# --- ack --------------------------------------------------------------------

# inbox_ack_log <channel> <offset> [event-ids-nl] [keys-nl] [cwd] [hook-json]
#
# `offset = max(stored, given)`, and a `given` greater than the file's current
# size is REFUSED. Idempotent (M-7): acking the same offset twice is a no-op,
# not a double-advance -- that is what `max` buys, and why the ack does not
# simply assign.
#
# THE STATE REWRITE GOES THROUGH `logchan_state_merge`, and MUST NOT assemble a
# fixed key set. This is load-bearing, not style: a fixed key set drops
# `rotated_at` on the very next ack, after which rotation SILENTLY NEVER FIRES
# AGAIN -- the inbox grows forever, which is the precise defect retention
# exists to fix, and every ack still looks successful. The failure is invisible
# by construction. (DND-183 sabotage row S38 proves the primitive is
# load-bearing; R-11 in this ticket's suite proves the ACK actually uses it.)
inbox_ack_log() {
  local chan="$1" given="$2" new_ev="${3:-}" new_ky="${4:-}" cwd="${5:-.}" hook_json="${6:-}"
  local resolved lock inbox state state_json size stored target updates merged rot_updates

  resolved="$(inbox_resolve_channel "${chan}" "${cwd}")" || return 1
  [ "$(_inbox_path kind "${resolved}")" = "log" ] || {
    inbox_fail "channel \"${chan}\" is not a log channel, so it has no offset to advance" \
      "ack a maildir channel by message name instead: read-inbox moves each message into .acked/ as it acks it."
    return 1
  }

  case "${given}" in
    ''|*[!0-9]*)
      inbox_fail "refusing a non-numeric ack offset for channel \"${chan}\"" \
        "pass the offset the read step reported. The ack takes the offset it is acking and MUST NOT recompute EOF."
      return 1
      ;;
  esac

  lock="$(_inbox_path lock "${resolved}")"
  inbox_require_consumer "${lock}" "channel \"${chan}\"" "${hook_json}" || return 1

  inbox="$(_inbox_path inbox "${resolved}")"
  state="$(_inbox_path state "${resolved}")"

  # The SAME substitution defences the read path applies, applied again here.
  # They are not redundant: `fs_size` follows a symlink, so without these an
  # ack would compare the caller's offset against some OTHER file's length and
  # then write this channel's state as though it had. The read path refusing a
  # symlinked .jsonl while the ack path accepted one is precisely the
  # "safe only by accident of its current caller" shape.
  fs_assert_regular "${inbox}" || return 1
  fs_assert_contained "$(fs_inbox_root)" "${inbox}" || return 1

  size="$(fs_size "${inbox}")"

  if [ "${given}" -gt "${size}" ]; then
    inbox_fail "refusing to ack past the end of channel \"${chan}\" (offset ${given}, file is ${size} bytes)" \
      "re-run the read step and ack the offset it reports. An offset past EOF would mark bytes consumed that were never delivered, and the contract refuses it rather than trusting the caller."
    return 1
  fi

  state_json="$(_inbox_state_or_recovered "${state}")" || return 1
  stored="$(printf '%s' "${state_json}" | jq -r '(.offset // 0) | tostring' 2>/dev/null)"
  case "${stored}" in ''|*[!0-9]*) stored=0 ;; esac
  if [ "${given}" -gt "${stored}" ]; then target="${given}"; else target="${stored}"; fi

  updates="$(jq -n \
    --argjson o "${target}" \
    --argjson cap "${LOGCHAN_RING_CAP}" \
    --arg ev "$(logchan_ring_append "${LOGCHAN_RING_CAP}" \
                 "$(printf '%s' "${state_json}" | jq -r '(.seen_event_ids // [])[]' 2>/dev/null)" "${new_ev}")" \
    --arg ky "$(logchan_ring_append "${LOGCHAN_RING_CAP}" \
                 "$(printf '%s' "${state_json}" | jq -r '(.seen_keys // [])[]' 2>/dev/null)" "${new_ky}")" \
    '{v: 1, offset: $o,
      seen_event_ids: ($ev | split("\n") | map(select(length > 0)) | .[-$cap:]),
      seen_keys:      ($ky | split("\n") | map(select(length > 0)) | .[-$cap:])}')" || return 1

  # Rotation runs BEFORE the state write, and folds its own updates into the
  # SAME write -- rename first, then state, one atomic rewrite.
  rot_updates="$(_inbox_retain "${resolved}" "${state_json}" "${target}")"
  updates="$(logchan_state_merge "${updates}" "${rot_updates}")" || return 1

  # THE ONE LINE THIS TICKET IS ABOUT. `logchan_state_merge` is `(. // {}) * $u`
  # -- every key the existing document carries and these updates do not is
  # preserved verbatim, including keys written by a NEWER version of this
  # tooling than the one running. Replacing this with a fixed key set is the
  # silent-forever defect described above.
  merged="$(logchan_state_merge "${state_json}" "${updates}")" || return 1
  fs_write_state "${state}" "${merged}" || return 1

  # Every read the designated consumer performs sweeps, not only a rotation.
  # A channel that rotated once and then went quiet must still shed its
  # generation at 14 days, and nothing else would ever clear it.
  _inbox_sweep_due "${resolved}" "${merged}" "channel \"${chan}\"" "${hook_json}"
  return 0
}

# inbox_ack_message <channel> <message-name> [cwd] [hook-json]
#
# The maildir ack: a MOVE into `.acked/` of the directory it was read from.
# Never a delete -- `.acked/` is the only durable transcript of the
# collaboration. Never a message this identity wrote.
inbox_ack_message() {
  local chan="$1" name="$2" cwd="${3:-.}" hook_json="${4:-}"
  local resolved lock read_dir ack_dir identity content fm from

  resolved="$(inbox_resolve_channel "${chan}" "${cwd}")" || return 1
  [ "$(_inbox_path kind "${resolved}")" = "maildir" ] || {
    inbox_fail "channel \"${chan}\" is not a maildir channel, so it has no message to move" \
      "ack a log channel by offset instead."
    return 1
  }

  # The name is checked BEFORE any I/O: a filename arriving from another party
  # is advisory data, never a path (A-3).
  if ! maildir_valid_message_name "${name}"; then
    inbox_fail "refusing to ack a message whose filename does not match the contract's grammar" \
      'a message filename is <YYYYMMDD>T<HHMMSS>Z-<seq>-<slug>.md. A name carrying ".." or a path separator is refused before any I/O, because a filename from another party is data, not a path.'
    return 1
  fi

  read_dir="$(_inbox_path read_dir "${resolved}")"
  ack_dir="$(_inbox_path ack_dir "${resolved}")"
  identity="$(_inbox_path identity "${resolved}")"
  fs_assert_contained "$(fs_inbox_root)" "${read_dir}" || return 1

  # The lock lives beside the channel; for a maildir it sits in the read
  # directory, so the two directions of one conversation lock separately.
  # Resolved, not re-derived -- see descriptor_resolve.
  lock="$(_inbox_path lock "${resolved}")"
  inbox_require_consumer "${lock}" "channel \"${chan}\"" "${hook_json}" || return 1

  content="$(fs_read_message "${read_dir}/${name}")" || {
    inbox_fail "cannot read the message to be acked in channel \"${chan}\"" \
      "re-run read-inbox --peek to list what is actually there; the message may already have been acked."
    return 1
  }
  fm="$(printf '%s' "${content}" | maildir_parse_frontmatter)"
  from="$(printf '%s' "${fm}" | jq -r '.from // empty' 2>/dev/null)"
  maildir_refuse_self_ack "${from}" "${identity}" || return 1

  fs_maildir_ack "${read_dir}" "${name}" "${ack_dir}" || return 1

  # The doorbell of the directory acked IN, bumped AFTER the move -- that is
  # how the PEER learns its message was ingested, because the directory I read
  # from is the one it delivers into. A move into `.acked/` otherwise rings no
  # bell at all and leaves the peer to poll, which the contract forbids.
  fs_bump_doorbell "${read_dir}/.event" || true
  return 0
}
