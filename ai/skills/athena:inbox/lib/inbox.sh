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
inbox_resolve_channel() {
  local chan="$1" entry rc declared
  entry="$(inbox_entry "${2:-.}")"; rc=$?
  if [ "${rc}" -eq 2 ]; then return 1; fi
  if [ -z "${entry}" ]; then
    inbox_fail "this project declares no inbox channels" \
      "add \$ATHENA_INBOX_ROOT/projects/<project>.json with a \"repo\" naming this repo's git common dir, or run from a project that has one."
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
