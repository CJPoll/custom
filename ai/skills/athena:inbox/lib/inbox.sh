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
# there": that fallback passes every other case in the QA plan and fails E2E
# step 8, where a session rooted in one project must see NO channel belonging
# to another.
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
inbox_entry() {
  local repo records
  repo="$(fs_git_common_dir "${1:-.}")" || return 1
  records="$(fs_registry_records)" || return 2
  printf '%s\n' "${records}" | descriptor_select "${repo}"
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

  [ -e "${inbox}" ] || never="true"
  size="$(fs_size "${inbox}")"

  local state_json
  state_json="$(fs_read_state "${state}")" || return 1
  offset="$(printf '%s' "${state_json}" | jq -r '.offset // 0' 2>/dev/null)" || offset=0
  case "${offset}" in ''|*[!0-9]*) offset=0 ;; esac
  if [ "${offset}" -gt "${size}" ]; then offset=0; stale="true"; fi

  seen_ev="$(printf '%s' "${state_json}" | jq -r '(.seen_event_ids // [])[]' 2>/dev/null)"
  seen_ky="$(printf '%s' "${state_json}" | jq -r '(.seen_keys // [])[]' 2>/dev/null)"

  slice="$(fs_slice_from "${inbox}" "${offset}"; printf X)"; slice="${slice%X}"
  scan="$(printf '%s' "${slice}" | logchan_scan "${offset}" "${schema_csv}" "${seen_ev}" "${seen_ky}")"

  # COUNTS ONLY. `messages` carries ts/channel/event_id and is dropped here
  # rather than at the renderer: a body, a subject or a peer-chosen string must
  # not exist in the manager's return value at all, so no future renderer can
  # print one by accident.
  printf '%s' "${scan}" | jq -c \
    --argjson never "${never}" --argjson stale "${stale}" \
    '{new: .new, unreadable: .unreadable, never_delivered: $never, offset_reset: $stale}'
}

# _inbox_count_maildir <resolved-paths>
_inbox_count_maildir() {
  local resolved="$1" read_dir n never="false"
  read_dir="$(_inbox_path read_dir "${resolved}")"
  fs_assert_contained "$(fs_inbox_root)" "${read_dir}" || return 1
  [ -d "${read_dir}" ] || never="true"
  n="$(fs_list_dir "${read_dir}" | maildir_filter_unread | grep -c . || true)"
  # Again counts only: the FILENAMES are peer-chosen prose (the slug is written
  # by whoever sent the message) and never leave this function.
  jq -n -c --argjson n "${n:-0}" --argjson never "${never}" \
    '{unread: $n, never_delivered: $never}'
}

# inbox_status_json [cwd]
# {"channels":[{"name":…,"kind":…,"new":…}…]} -- counts only, for every channel
# this session owns. An empty channel list is a legitimate, silent result.
inbox_status_json() {
  local entry rc chan kind resolved counts schema_csv out="[]"

  entry="$(inbox_entry "${1:-.}")"; rc=$?
  [ "${rc}" -ne 2 ] || return 1
  if [ -z "${entry}" ]; then printf '{"channels":[]}\n'; return 0; fi
  descriptor_validate "${entry}" || return 1

  while IFS= read -r chan; do
    [ -n "${chan}" ] || continue
    resolved="$(descriptor_resolve "$(fs_inbox_root)" "${entry}" "${chan}")" || return 1
    kind="$(_inbox_path kind "${resolved}")"
    case "${kind}" in
      log)
        schema_csv="$(printf '%s' "${entry}" | jq -r --arg c "${chan}" \
          '((.channels[$c].schema_v // [1]) | map(tostring) | join(","))')"
        counts="$(_inbox_count_log "${resolved}" "${schema_csv}")" || return 1
        ;;
      maildir)
        counts="$(_inbox_count_maildir "${resolved}")" || return 1
        ;;
      *) continue ;;
    esac
    out="$(printf '%s' "${out}" | jq -c --arg n "${chan}" --arg k "${kind}" \
      --argjson c "${counts}" '. + [{name: $n, kind: $k} + $c]')"
  done < <(descriptor_channel_names "${entry}")

  printf '%s' "${out}" | jq -c '{channels: .}'
}
