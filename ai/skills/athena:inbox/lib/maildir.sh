#!/usr/bin/env bash
# maildir.sh -- DOMAIN: pure.
#
# SCOPE. DND-183 shipped only the unread predicate, because counting was all
# `bin/inbox-status` needed. DND-184 adds the rest of the reader's half: the
# filename grammar, `<seq>` allocation, frontmatter parse/validate, and the
# "never ack your own message" rule (QA D-20 … D-25).
#
# What is deliberately still absent is the WRITER's half. QA M-11 and M-12 are
# `send-mail` cases -- stage in `tmp/`, deliver without clobbering, bump the
# doorbell after -- and this ticket ships no send entry point, so writing that
# machinery here would mean shipping an untested writer to satisfy a row in a
# matrix. `maildir_next_seq` is here because the READER needs to understand
# the grammar it enumerates, not because anything here allocates a name.
#
# Source order: err.sh, names.sh, then this file. `maildir_parse_frontmatter`
# requires jq (it emits JSON); everything else is shell-only.

# maildir_is_unread <name>
#
# The predicate, over ONE bare directory entry name.
#
# D-24: `tmp/` holds half-delivered files (the writer lands there and then
# rename(2)s into place), `.acked/` holds what was already consumed, and
# `.event` is the doorbell, not mail. A reader that counts any of them reports
# messages that do not exist -- and the dotfile rule is what makes that
# exclusion a RULE rather than a list of three names to keep in sync.
maildir_is_unread() {
  local name="$1"
  [ -n "${name}" ] || return 1
  case "${name}" in
    .*) return 1 ;;                    # .acked/, .event, any dotfile
    tmp) return 1 ;;                   # half-delivered, not yet renamed
    # A newline in a message filename. The slug is PEER-CHOSEN prose, so the
    # peer picks these bytes; a name carrying a newline is not a conformant
    # message name (the filename grammar lands with DND-184) and, counted
    # through any line-oriented listing, it would arrive as two entries and
    # inflate the count. The peer does not get to choose how many messages it
    # sent. Unlike the NUL arm deliberately absent from names.sh, `$'\n'` IS a
    # real character in bash and this arm genuinely fires.
    *$'\n'*) return 1 ;;
  esac
  return 0
}

# maildir_filter_unread   (directory listing on stdin, one name per line)
#
# The line-oriented form of the predicate. Deliberately a filter over a
# listing rather than a directory read: it stays pure, so the exclusion is
# provable with no directory on disk.
#
# Callers that must be exact about the COUNT use the NUL-delimited listing and
# the predicate directly -- a line-delimited listing cannot represent a name
# containing a newline, and this filter can only ever see what survived that
# lossy encoding.
maildir_filter_unread() {
  local name
  while IFS= read -r name; do
    maildir_is_unread "${name}" && printf '%s\n' "${name}"
  done
  return 0
}

# --- the message filename grammar (D-20) ------------------------------------
# Contract -> "Message filename":  <UTCbasic>Z-<seq>-<slug>.md
#
#   <UTCbasic>  YYYYMMDDTHHMMSS, UTC
#   Z           literal, so the timestamp is unambiguously UTC
#   <seq>       zero-padded, AT LEAST 3 digits, and it WIDENS past 999 rather
#               than wrapping -- wrapping would reorder the directory
#   <slug>      ^[a-z0-9][a-z0-9-]*$, 1..48 chars, no leading/trailing "-"
#
# Lexicographic filename order IS chronological order, and that rests on the
# fixed-width timestamp prefix. A short `<seq>` (`-1-`) is refused for the same
# reason: `-1-` sorts after `-10-`, so accepting one name breaks the ordering
# guarantee for every name around it.
#
# A filename is advisory data from another party, never a path (A-3). It is
# checked BEFORE any I/O, and the traversal shapes are excluded by the grammar
# itself rather than by a separate scan: `..` cannot match the timestamp field,
# and `/` cannot match any field.
maildir_valid_message_name() {
  local name="$1" rest seq slug

  [ -n "${name}" ] || return 1
  case "${name}" in *.md) ;; *) return 1 ;; esac
  # ${name%.md} rather than a regex over the whole thing: the slug grammar
  # below must not be allowed to match the ".md" itself.
  rest="${name%.md}"

  # Timestamp + Z + "-"
  [[ "${rest}" =~ ^[0-9]{8}T[0-9]{6}Z- ]] || return 1
  rest="${rest#*Z-}"

  seq="${rest%%-*}"
  [ "${seq}" != "${rest}" ] || return 1          # no second "-", so no slug
  slug="${rest#*-}"

  [[ "${seq}" =~ ^[0-9]{3,}$ ]] || return 1      # at least 3 digits, digits only
  [[ "${slug}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  case "${slug}" in *-) return 1 ;; esac         # never trailing "-"
  [ "$(names_byte_length "${slug}")" -le 48 ] || return 1
  return 0
}

# maildir_message_stamp <name>  -- the RFC 3339 form of the filename's stamp.
# 20260901T232215Z -> 2026-09-01T23:22:15Z, so D-23 can compare it against
# frontmatter `sent_at` as text, with no date(1) and no timezone anywhere near
# the comparison.
maildir_message_stamp() {
  local name="$1" t
  maildir_valid_message_name "${name}" || return 1
  t="${name%%Z-*}"
  printf '%s-%s-%sT%s:%s:%sZ\n' \
    "${t:0:4}" "${t:4:2}" "${t:6:2}" "${t:9:2}" "${t:11:2}" "${t:13:2}"
}

# maildir_next_seq   (directory listing on stdin, one bare name per line)
#
# D-21: one past the highest `<seq>` present, zero-padded to at least 3. The
# contract requires the scan to include `.acked/`, so the CALLER feeds both
# listings in -- keeping this function a pure fold over names rather than a
# directory walk that would have to know the layout.
#
# Names that are not conformant messages are ignored rather than refused: the
# deployed corpus predates the grammar, and a seq allocator that died on a
# legacy filename would make the directory unwritable.
maildir_next_seq() {
  local name seq max=0 width=3 n
  while IFS= read -r name; do
    maildir_valid_message_name "${name}" || continue
    seq="${name#*Z-}"; seq="${seq%%-*}"
    # 10# forces base 10: bash reads a leading-zero literal as OCTAL, so "008"
    # is a syntax error and "010" is 8. A seq field is zero-padded by
    # definition, which makes this the normal case, not the edge case.
    n=$(( 10#${seq} ))
    if [ "${n}" -gt "${max}" ]; then max="${n}"; fi
    if [ "${#seq}" -gt "${width}" ]; then width="${#seq}"; fi
  done
  n=$(( max + 1 ))
  # WIDENS rather than wraps (contract): once the value needs more digits than
  # the current width, the field grows. printf's minimum width does exactly
  # that on its own -- 1000 with %03d is "1000", not "000".
  printf "%0${width}d\n" "${n}"
}

# --- frontmatter (D-22, D-23) -----------------------------------------------

# maildir_parse_frontmatter   (message content on stdin) -> one JSON object
#
# YAML in name only: the contract fixes the shape at `key: value` lines between
# a leading `---` and a matching `---`, and a real YAML parser would accept
# structures this format has no meaning for.
#
# AN UNKNOWN KEY IS IGNORED, NOT AN ERROR (D-22) -- the deliberate opposite of
# the registry rule in descriptor.sh, and of the state-file rule in logchan.sh
# it superficially resembles:
#
#   * registry entry  -- unknown key is a HARD ERROR. My own configuration; a
#                        typo must be shouted about.
#   * state file      -- unknown key is PRESERVED. My own machine-written data,
#                        possibly by a newer writer than this one.
#   * frontmatter     -- unknown key is IGNORED. The other party's message;
#                        strictness would let a peer's harmless addition break
#                        delivery. Strict about what I write, lenient about
#                        what I receive.
#
# A message with no frontmatter at all yields `{}` rather than a refusal: the
# body is still deliverable text, and refusing would let a malformed header
# make a message unreadable forever.
maildir_parse_frontmatter() {
  awk '
    NR == 1 && $0 != "---" { exit }       # no frontmatter block at all
    NR == 1 { inside = 1; next }
    inside && $0 == "---" { exit }
    inside {
      i = index($0, ":")
      if (i > 1) {
        k = substr($0, 1, i - 1)
        v = substr($0, i + 1)
        sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        # A comment is stripped only when it follows whitespace, so a "#" that
        # is part of a value (a channel name, a fragment in a URL) survives.
        sub(/[ \t]+#.*$/, "", v)
        if (k ~ /^[A-Za-z_][A-Za-z0-9_-]*$/) printf "%s\t%s\n", k, v
      }
    }
  ' | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")) 
                   | map(select(length >= 1)) 
                   | map({(.[0]): (.[1] // "")}) | add // {}'
}

# maildir_body   (message content on stdin) -- everything after the closing ---
maildir_body() {
  awk '
    NR == 1 && $0 != "---" { print; body = 1; next }
    NR == 1 { next }
    body { print; next }
    !seen && $0 == "---" { seen = 1; body = 1; next }
  '
}

# maildir_validate_message <name> <frontmatter-json>
#
# D-23: `sent_at` MUST agree with the filename. They are two copies of one
# fact, and a disagreement means one of them is wrong -- with no way to tell
# which, so the message is refused rather than silently believed in one of the
# two directions. Compared as TEXT against the filename's own stamp: no date(1),
# so no timezone can creep into the comparison.
#
# `from`/`to` are required by the contract. Absent, the message cannot be
# attributed at all, and "never ack your own message" below has nothing to
# check against.
maildir_validate_message() {
  local name="$1" fm="$2" want got

  if ! maildir_valid_message_name "${name}"; then
    inbox_fail "message filename does not match the contract's grammar" \
      'a message filename is <YYYYMMDD>T<HHMMSS>Z-<seq>-<slug>.md with seq at least 3 digits and slug matching ^[a-z0-9][a-z0-9-]*$ (1..48 chars).'
    return 1
  fi

  for want in from to sent_at; do
    got="$(printf '%s' "${fm}" | jq -r --arg k "${want}" '.[$k] // empty' 2>/dev/null)"
    if [ -z "${got}" ]; then
      inbox_fail "message is missing required frontmatter key \"${want}\"" \
        "ask the sender to include from, to and sent_at in the message's frontmatter; without them the message cannot be attributed."
      return 1
    fi
  done

  want="$(maildir_message_stamp "${name}")"
  got="$(printf '%s' "${fm}" | jq -r '.sent_at // empty' 2>/dev/null)"
  if [ "${want}" != "${got}" ]; then
    inbox_fail "message frontmatter \"sent_at\" (${got}) disagrees with its filename (${want})" \
      "ask the sender to re-send with sent_at matching the filename stamp; two copies of one fact that disagree cannot both be believed, and there is no way to tell which is wrong."
    return 1
  fi
  return 0
}

# maildir_refuse_self_ack <from> <identity>
#
# D-25 / the brief's M-12: NEVER ACK YOUR OWN MESSAGE. A message whose `from`
# is my own identity is one the PEER has not got to yet, and the writer does
# not get to decide its own message was handled -- acking it would move my
# outgoing mail into `.acked/` and tell me it was ingested by someone who
# never saw it.
#
# `from` is a LABEL, not authentication (contract -> "Frontmatter"): any local
# process can claim any `from`. This is deliberately an anti-footgun check on
# my own writes, not a security control, and calling it one would overstate
# what it does. The security boundary is elsewhere -- "Untrusted input" denies
# every message any authority at all, so a forged `from` buys nothing beyond
# misattribution.
maildir_refuse_self_ack() {
  local from="$1" identity="$2"
  [ -n "${identity}" ] || return 0
  if [ "${from}" = "${identity}" ]; then
    inbox_fail "refusing to ack a message whose \"from\" is this channel's own identity (\"${identity}\")" \
      "this is a message YOU sent, sitting where the peer has not consumed it yet. Acking it would move your own outgoing mail into .acked/ and record it as ingested by a peer that never saw it. Ack only messages addressed to you."
    return 1
  fi
  return 0
}
