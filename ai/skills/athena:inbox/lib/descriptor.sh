#!/usr/bin/env bash
# descriptor.sh -- the tenancy registry: parse, validate, select, resolve.
# DOMAIN. Every function here takes TEXT and returns text or a status; the one
# effect is a refusal on stderr via err.sh.
# Nothing opens a file, runs git, or looks at the filesystem; that is fs.sh's
# job, and keeping it that way is what makes D-8 / D-10 / A-8 provable with no
# fixtures at all.
#
# WHERE THE CONFIG LIVES -- owner decision 2026-09-18 (DND-202, "option B").
# An earlier design had each consumer repo COMMIT a `.athena-inbox.json` at its
# root. That was reversed: nothing about the inbox may land in a consumer repo,
# because a shared work repo would have carried a personal machine's paths into
# a file coworkers read. The tenancy config now lives entirely harness-side:
#
#     $ATHENA_INBOX_ROOT/projects/<project>.json     (default root ~/.local/share/athena)
#
# machine-local, untracked, 0600 in a 0700 directory. The SCHEMA is the old
# descriptor's almost verbatim; what changed is where the file lives and how it
# is found.
#
# HOW AN ENTRY IS FOUND -- by repo identity, which is the realpath of
# `git rev-parse --git-common-dir` (fs.sh computes it; this file only compares
# strings). That value is identical for a repo's main checkout and every one of
# its worktrees, and distinct per repo, so a worktree session resolves to its
# parent repo's channels for free. The rejected alternative was the origin
# remote URL: a repo-DECLARED value, which a repo could forge to name someone
# else's remote. The common dir is a local filesystem fact. The trust boundary
# stays local.
#
# THE INVARIANT THIS FILE EXISTS TO HOLD: a session must never see another
# project's channels. `descriptor_select` matches on the repo key and returns
# NOTHING when no entry matches -- it never falls back to "well, show them
# whatever is in the root". A resolver with that fallback passes every other
# case in the QA plan and fails its *Tenancy boundary* end-to-end case
# (currently step 8), which is why the no-match path is asserted rather than
# assumed.
#
# Source order: err.sh, names.sh, then this file. Requires jq.

DESCRIPTOR_SCHEMA_V=1

# Allow-lists, not deny-lists. An unknown key is a HARD error at every level
# (D-8): ignoring it makes a typo indistinguishable from a default, and a
# silently-defaulted channel is one nobody is watching. This is the deliberate
# OPPOSITE of the maildir frontmatter rule (strict about what I write, lenient
# about what I receive) -- a config file I wrote is not a message a peer sent.
DESCRIPTOR_TOP_KEYS='["v","repo","channels"]'
DESCRIPTOR_LOG_KEYS='["kind","path","dedupe","schema_v"]'
DESCRIPTOR_MAILDIR_KEYS='["kind","namespace","read","write","identity"]'
# `event_id` and `channel+ts` are the ONLY recognised dedupe members, because
# they are the only two keys the reference reader (logchan.sh -> logchan_scan)
# actually ingests. Under the landed Option (C) event-platform model the platform
# mints NO `op` stream and holds NO durable dedupe key: a platform-produced line
# is the routed STATE-CHANGE event (current state; a delete carries entity_id
# only), which the reference reader does not yet ingest -- it derives a line's key
# only from `event_id` / `channel+ts`. So declaring a platform-delivery channel is
# barred until reader support for state-change lines lands (see
# ai/contracts/athena-inbox.md -> "The inbox as an event-platform delivery
# adapter", the Known-open note), and this validator REJECTS the not-yet-modeled
# `"stream"` key (an unknown channel-object key) and any dedupe member other than
# `event_id` / `channel+ts` for exactly that reason. The "One validator" rule cuts
# both ways: the validator must never accept what the reader would drop.
DESCRIPTOR_DEDUPE_MEMBERS='["event_id","channel+ts"]'

_descriptor_fix='edit $ATHENA_INBOX_ROOT/projects/<project>.json to match the registry schema in ai/contracts/athena-inbox.md, then re-run.'

# _descriptor_jq <json> <program> [jq-args...]
# Runs jq against the document, returning non-zero on unparseable input rather
# than letting a jq error escape as output.
_descriptor_jq() {
  local doc="$1" prog="$2"; shift 2
  printf '%s' "${doc}" | jq -e -r "$@" "${prog}" 2>/dev/null
}

# descriptor_validate <json>
# Exit 0 if the document is a conformant registry entry; otherwise one stderr
# refusal NAMING the offending key/field, with a Fix: clause.
descriptor_validate() {
  local doc="$1" v out chan kind

  if ! printf '%s' "${doc}" | jq -e . >/dev/null 2>&1; then
    inbox_fail "registry entry is not parseable JSON" "${_descriptor_fix}"
    return 1
  fi
  if [ "$(printf '%s' "${doc}" | jq -r 'type')" != "object" ]; then
    inbox_fail "registry entry's top level is not a JSON object" "${_descriptor_fix}"
    return 1
  fi

  # An unknown `v` is a HARD error -- deliberately the opposite of an unknown
  # `v` on a log LINE. A tool cannot partially honour a configuration file it
  # does not understand, and there is nothing to "count separately" about one.
  v="$(printf '%s' "${doc}" | jq -r '.v // empty')"
  if [ "${v}" != "${DESCRIPTOR_SCHEMA_V}" ]; then
    inbox_fail "registry entry declares v=\"${v:-<absent>}\"; this tool understands v=${DESCRIPTOR_SCHEMA_V} only" \
      "set \"v\": ${DESCRIPTOR_SCHEMA_V} in the registry entry, or upgrade the athena:inbox skill to one that knows v=${v:-?}."
    return 1
  fi

  out="$(printf '%s' "${doc}" | jq -r --argjson ok "${DESCRIPTOR_TOP_KEYS}" \
    '[keys_unsorted[] | select(. as $k | $ok | index($k) | not)] | join(", ")')"
  if [ -n "${out}" ]; then
    inbox_fail "registry entry carries unknown top-level key(s): ${out}" \
      "remove or correct ${out}; the only top-level keys are $(printf '%s' "${DESCRIPTOR_TOP_KEYS}" | jq -r 'join(", ")')."
    return 1
  fi

  # The repo key is what binds this entry to a checkout. Absent, it can never
  # match any session, which is a silently dead entry rather than an error the
  # author sees -- so it is required.
  out="$(printf '%s' "${doc}" | jq -r '.repo // empty')"
  if [ -z "${out}" ]; then
    inbox_fail "registry entry has no \"repo\" key, so no session can ever match it" \
      "add \"repo\": \"<realpath of git rev-parse --git-common-dir in that checkout>\" to the registry entry."
    return 1
  fi
  case "${out}" in
    /*) ;;
    *)
      inbox_fail "registry entry's \"repo\" is not an absolute path" \
        "set \"repo\" to the ABSOLUTE realpath of that repo's git common dir (run: realpath \"\$(git rev-parse --git-common-dir)\")."
      return 1
      ;;
  esac

  if [ "$(printf '%s' "${doc}" | jq -r '.channels | type')" != "object" ]; then
    inbox_fail "registry entry's \"channels\" is not a JSON object" "${_descriptor_fix}"
    return 1
  fi

  while IFS= read -r chan; do
    [ -n "${chan}" ] || continue
    _descriptor_validate_channel "${doc}" "${chan}" || return 1
  done < <(printf '%s' "${doc}" | jq -r '.channels | keys_unsorted[]')

  return 0
}

_descriptor_validate_channel() {
  local doc="$1" chan="$2" kind out allowed

  if ! names_valid_channel_name "${chan}"; then
    inbox_fail "channel name \"${chan}\" is not a legal name" \
      'use a channel name matching ^[a-z0-9][a-z0-9_-]*$, at most 64 bytes.'
    return 1
  fi

  if [ "$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c] | type')" != "object" ]; then
    inbox_fail "channel \"${chan}\" is not a JSON object" "${_descriptor_fix}"
    return 1
  fi

  kind="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].kind // empty')"
  case "${kind}" in
    log)     allowed="${DESCRIPTOR_LOG_KEYS}" ;;
    maildir) allowed="${DESCRIPTOR_MAILDIR_KEYS}" ;;
    "")
      inbox_fail "channel \"${chan}\" has no \"kind\"" \
        "add \"kind\": \"log\" or \"kind\": \"maildir\" to channel \"${chan}\"."
      return 1
      ;;
    *)
      inbox_fail "channel \"${chan}\" declares unknown kind \"${kind}\"" \
        "set channel \"${chan}\"'s \"kind\" to \"log\" or \"maildir\"; those are the only kinds this tool implements."
      return 1
      ;;
  esac

  out="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" --argjson ok "${allowed}" \
    '[.channels[$c] | keys_unsorted[] | select(. as $k | $ok | index($k) | not)] | join(", ")')"
  if [ -n "${out}" ]; then
    inbox_fail "channel \"${chan}\" carries unknown key(s): ${out}" \
      "remove or correct ${out} on channel \"${chan}\"; a ${kind} channel takes only $(printf '%s' "${allowed}" | jq -r 'join(", ")')."
    return 1
  fi

  case "${kind}" in
    log)     _descriptor_validate_log "${doc}" "${chan}" ;;
    maildir) _descriptor_validate_maildir "${doc}" "${chan}" ;;
  esac
}

_descriptor_validate_log() {
  local doc="$1" chan="$2" path out

  path="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].path // empty')"
  if [ -z "${path}" ]; then
    inbox_fail "log channel \"${chan}\" is missing required field \"path\"" \
      "add \"path\": \"<name>.jsonl\" to channel \"${chan}\"; state, doorbell and lock names are all derived from it."
    return 1
  fi
  # D-10 / A-4: refused HERE, on text, before anything can turn it into I/O.
  if ! names_valid_log_path "${path}"; then
    inbox_fail "log channel \"${chan}\" declares an illegal path" \
      'give the channel a path relative to ATHENA_INBOX_ROOT ending in .jsonl, with no leading "/", no ".." component and no leading dot.'
    return 1
  fi
  # Belt and braces: the grammar already excludes "..", but containment is the
  # check the contract names, so it runs too and on the same text.
  names_resolve_in_root "/" "${path}" >/dev/null || return 1
  if names_reserved_prefix "${path}"; then
    inbox_fail "log channel \"${chan}\" declares a path inside the reserved projects/ directory" \
      "move channel \"${chan}\"'s \"path\" out of projects/; that directory holds the tenancy registry, and a message surface there would read and be read as configuration."
    return 1
  fi

  if printf '%s' "${doc}" | jq -e --arg c "${chan}" 'has("channels") and (.channels[$c] | has("dedupe"))' >/dev/null 2>&1; then
    if [ "$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].dedupe | type')" != "array" ]; then
      inbox_fail "log channel \"${chan}\"'s \"dedupe\" is not an array" "${_descriptor_fix}"
      return 1
    fi
    out="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" --argjson ok "${DESCRIPTOR_DEDUPE_MEMBERS}" \
      '[.channels[$c].dedupe[] | select(. as $m | $ok | index($m) | not)] | join(", ")')"
    if [ -n "${out}" ]; then
      # A reader must never silently dedupe on nothing: an unrecognised member
      # would be applied as a no-op and every duplicate would be re-reported.
      inbox_fail "log channel \"${chan}\" declares unrecognised dedupe key(s): ${out}" \
        "use only $(printf '%s' "${DESCRIPTOR_DEDUPE_MEMBERS}" | jq -r 'join(", ")') in channel \"${chan}\"'s \"dedupe\"."
      return 1
    fi
  fi

  if printf '%s' "${doc}" | jq -e --arg c "${chan}" '.channels[$c] | has("schema_v")' >/dev/null 2>&1; then
    if ! printf '%s' "${doc}" | jq -e --arg c "${chan}" \
      '.channels[$c].schema_v | (type == "array") and (length > 0) and all(type == "number")' >/dev/null 2>&1; then
      inbox_fail "log channel \"${chan}\"'s \"schema_v\" is not a non-empty array of numbers" \
        "set channel \"${chan}\"'s \"schema_v\" to a list of line schema versions this reader understands, e.g. [1]."
      return 1
    fi
  fi
  return 0
}

_descriptor_validate_maildir() {
  local doc="$1" chan="$2" field val read_dir write_dir

  for field in namespace read write identity; do
    val="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" --arg f "${field}" '.channels[$c][$f] // empty')"
    if [ -z "${val}" ]; then
      inbox_fail "maildir channel \"${chan}\" is missing required field \"${field}\"" \
        "add \"${field}\" to channel \"${chan}\"; a maildir channel needs namespace, read, write and identity."
      return 1
    fi
  done

  val="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].namespace')"
  if ! names_valid_namespace "${val}"; then
    inbox_fail "maildir channel \"${chan}\" declares an illegal namespace" \
      'give the channel a namespace of "/"-joined segments matching ^[a-z0-9][a-z0-9_-]*$, relative to ATHENA_INBOX_ROOT.'
    return 1
  fi
  names_resolve_in_root "/" "${val}" >/dev/null || return 1
  if names_reserved_prefix "${val}"; then
    inbox_fail "maildir channel \"${chan}\" declares a namespace inside the reserved projects/ directory" \
      "move channel \"${chan}\"'s \"namespace\" out of projects/; that directory holds the tenancy registry, and pointing a maildir at it would count other projects' registry entries as unread mail."
    return 1
  fi

  read_dir="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].read')"
  write_dir="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].write')"
  for val in "${read_dir}" "${write_dir}"; do
    if ! names_valid_segment "${val}"; then
      inbox_fail "maildir channel \"${chan}\" declares an illegal read/write directory name" \
        'use a single segment matching ^[a-z0-9][a-z0-9_-]*$ for "read" and "write" -- they are directory names inside the namespace, not paths.'
      return 1
    fi
  done
  # Equal read and write would make every send land in the directory this
  # identity reads from, so the sender would ingest its own outgoing mail.
  if [ "${read_dir}" = "${write_dir}" ]; then
    inbox_fail "maildir channel \"${chan}\" reads and writes the same directory \"${read_dir}\"" \
      "give channel \"${chan}\" a \"write\" directory different from its \"read\" directory; the peer's mirrored entry swaps the two."
    return 1
  fi

  val="$(printf '%s' "${doc}" | jq -r --arg c "${chan}" '.channels[$c].identity')"
  if ! names_valid_identity "${val}"; then
    inbox_fail "maildir channel \"${chan}\" declares an illegal identity" \
      'use an identity matching ^[a-z0-9][a-z0-9_-]*$, at most 64 bytes.'
    return 1
  fi
  return 0
}

# --- reading a validated entry ----------------------------------------------

# descriptor_repo_key <json>
descriptor_repo_key() { _descriptor_jq "$1" '.repo // empty'; }

# descriptor_channel_names <json>  -- one per line, declaration order.
descriptor_channel_names() { printf '%s' "$1" | jq -r '.channels | keys_unsorted[]' 2>/dev/null; }

# descriptor_channel_field <json> <channel> <field>
descriptor_channel_field() {
  printf '%s' "$1" | jq -r --arg c "$2" --arg f "$3" '.channels[$c][$f] // empty' 2>/dev/null
}

# descriptor_has_channel <json> <channel>
descriptor_has_channel() {
  printf '%s' "$1" | jq -e --arg c "$2" '.channels | has($c)' >/dev/null 2>&1
}

# --- selection: which entry owns this session -------------------------------

# descriptor_select <repo-id>   (records on stdin: "<source>\t<one-line json>")
#
# Status 1 = NO ENTRY NAMES THIS REPO, with no output. That is not a fault and
# must stay silent: a cwd in an unregistered repo is the ordinary state of most
# repos on this machine, and an error there would train the reader to ignore
# errors.
#
# Status 2 = AMBIGUOUS, a hard error. Two entries naming the same repo is the
# one case where picking a winner could hand a session another project's
# channels, so it refuses -- and the refusal names the FILES, never their
# channels, because a denial must not be usable to enumerate a namespace.
#
# The two failures get DIFFERENT statuses on purpose. Sharing status 1 would
# make every caller's "no entry, so zero channels, exit 0" branch swallow the
# ambiguity too, and ambiguous ownership would present as "this project has not
# opted in" -- a well-formed empty answer, which is exactly the conflation the
# hard error exists to prevent.
descriptor_select() {
  local want="$1" line src json match="" match_src="" dupes=""

  while IFS=$'\t' read -r json src; do
    [ -n "${json}" ] || continue
    case "${json}" in '#unparseable') continue ;; esac
    [ "$(descriptor_repo_key "${json}")" = "${want}" ] || continue
    if [ -n "${match}" ]; then
      dupes="${dupes}${dupes:+, }${src}"
      continue
    fi
    match="${json}"; match_src="${src}"
  done

  if [ -n "${dupes}" ]; then
    inbox_fail "registry files ${match_src}, ${dupes} all claim the same repo; ownership is ambiguous" \
      "leave exactly one registry file whose \"repo\" is \"${want}\" and delete or re-key the others." 2
    return 2
  fi
  [ -n "${match}" ] || return 1
  printf '%s\n' "${match}"
  return 0
}

# --- resolution: channel -> absolute paths ----------------------------------

# descriptor_resolve <root> <json> <channel>
# Prints "<label>\t<absolute path>" lines. PURE: it joins strings, it does not
# stat anything. Every path goes through names_resolve_in_root first, so a path
# that escapes the root is refused here rather than at the open(2).
descriptor_resolve() {
  local root="${1%/}" doc="$2" chan="$3" kind

  if ! descriptor_has_channel "${doc}" "${chan}"; then
    # Name-free, exactly like the manager's copy one layer up. The suite
    # exercises this path directly as "the check the next entry point will
    # rely on", so echoing the requested name here would reinstate the very
    # oracle the manager's refusal is asserted not to be.
    inbox_fail "no such channel in this registry entry" \
      "declare it in \$ATHENA_INBOX_ROOT/projects/<project>.json, or ask for a channel this project declares: $(descriptor_channel_names "${doc}" | paste -sd, -)."
    return 1
  fi

  kind="$(descriptor_channel_field "${doc}" "${chan}" kind)"
  printf 'kind\t%s\n' "${kind}"
  case "${kind}" in
    log)
      local path inbox
      path="$(descriptor_channel_field "${doc}" "${chan}" path)"
      inbox="$(names_resolve_in_root "${root}" "${path}")" || return 1
      printf 'inbox\t%s\n'    "${inbox}"
      printf 'state\t%s\n'    "$(names_state_name "${inbox}")"
      printf 'doorbell\t%s\n' "$(names_doorbell_name "${inbox}")"
      printf 'lock\t%s\n'     "$(names_lock_name "${inbox}")"
      ;;
    maildir)
      local ns base rd wr
      ns="$(descriptor_channel_field "${doc}" "${chan}" namespace)"
      base="$(names_resolve_in_root "${root}" "${ns}")" || return 1
      rd="$(descriptor_channel_field "${doc}" "${chan}" read)"
      wr="$(descriptor_channel_field "${doc}" "${chan}" write)"
      printf 'read_dir\t%s/%s\n'  "${base}" "${rd}"
      printf 'write_dir\t%s/%s\n' "${base}" "${wr}"
      printf 'ack_dir\t%s/%s/.acked\n' "${base}" "${rd}"
      # BOTH doorbells, derived HERE, for the same reason `lock` is: a path
      # spelled out at its point of use is a path that can diverge from the
      # one the other caller spells. A waiter watches both -- the `read` bell
      # for incoming mail, the `write` bell for the peer's acks of what this
      # identity sent. Labelling one watch-only and the other bump-only breaks
      # the ack notification outright: my ack happens inside MY read directory,
      # which is the directory the PEER delivers into, so the peer learns of it
      # only by watching that same bell from its own side.
      printf 'read_doorbell\t%s/%s/.event\n'  "${base}" "${rd}"
      printf 'write_doorbell\t%s/%s/.event\n' "${base}" "${wr}"
      # The WRITE side's `.acked/` too, for the same reason `ack_dir` exists
      # above: the waiter provisions both mail directories, and a `.acked`
      # spelled at its point of use is a second copy of a path that must be the
      # same directory the ack writes into.
      printf 'write_ack_dir\t%s/%s/.acked\n' "${base}" "${wr}"
      # Derived HERE, once. It was previously spelled out in both the ack
      # manager and bin/read-inbox: two copies of a path that must be the same
      # file, where a divergence would mean the reader takes one lock and the
      # acker takes another, and the mutual exclusion the lock exists for
      # quietly stops existing.
      printf 'lock\t%s/%s/.consumer.lock\n' "${base}" "$(descriptor_channel_field "${doc}" "${chan}" read)"
      printf 'identity\t%s\n' "$(descriptor_channel_field "${doc}" "${chan}" identity)"
      ;;
  esac
  return 0
}
