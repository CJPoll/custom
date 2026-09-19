#!/usr/bin/env bash
# maildir.sh -- DOMAIN: pure.
#
# SCOPE. DND-183 shipped only the unread predicate, because counting was all
# `bin/inbox-status` needed. DND-184 adds the rest of the reader's half: the
# filename grammar, frontmatter parse/validate, and the
# "never ack your own message" rule (QA D-20 … D-25).
#
# **Later (2026-09-18):** this note previously said the WRITER's half was
# deliberately absent -- "QA M-11 and M-12 are `send-mail` cases [...] and this
# ticket ships no send entry point, so writing that machinery here would mean
# shipping an untested writer to satisfy a row in a matrix", with `<seq>`
# allocation named as going the same way. DND-187 is that ticket: `bin/send-mail`
# exists, so the writer's half lands here under THE WRITER'S HALF banner below,
# beside the caller that gives it a reason to be correct.
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
# AN UNTERMINATED `---` BLOCK YIELDS NOTHING, and that is the whole point of
# buffering rather than streaming.
#
# The contract fixes the shape as fenced by `---` on the first line AND A
# MATCHING `---`. Without the closing fence this parser used to harvest every
# `key: value` line to EOF while `maildir_body` emitted nothing -- so a message
# whose body happened to be `key: value`-shaped parsed as perfectly good
# frontmatter, passed validation, RENDERED WITH AN EMPTY BODY, and was then
# ACKED INTO `.acked/`. Peer content silently destroyed and recorded as
# ingested, in the skill whose entire purpose is that mail is never lost
# quietly. Reproduced end to end before this was written.
#
# So the pairs are collected and emitted ONLY once the closing `---` is seen.
# An unterminated block yields `{}`, which fails the required-key check in
# `maildir_validate_message`, which routes the file down the non-conformant
# path: counted, not rendered, not acked, and left on disk intact.
maildir_parse_frontmatter() {
  awk '
    NR == 1 && $0 != "---" { exit }       # no frontmatter block at all
    NR == 1 { inside = 1; next }
    inside && $0 == "---" { closed = 1; exit }
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
        if (k ~ /^[A-Za-z_][A-Za-z0-9_-]*$/) buf[++n] = k "\t" v
      }
    }
    END {
      if (!closed) exit               # unterminated: emit NOTHING
      for (j = 1; j <= n; j++) print buf[j]
    }
  ' | _maildir_fm_to_json
}

# THE VALUE IS REJOINED, not taken as the first field.
#
# The awk above emits "<key>\t<value>" and the value is PEER-WRITTEN, so it may
# itself contain a tab -- the same delimiter collision that has now cost this
# skill four bugs (a tab in a registry filename, a tab in a channel path, a
# newline in a dedupe key, and a caller recomputing that key without the guard).
#
# Taking `.[1]` TRUNCATES at the first tab, invisibly. A peer sending
# `from: athena<TAB>anything` parses as exactly "athena" -- which is this
# channel's own identity -- so the message is treated as the reader's own
# outgoing mail, never acked, and re-listed on every read forever. A wedge the
# SENDER chose, with nothing anywhere saying why.
_maildir_fm_to_json() {
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t"))
               | map(select(length >= 1))
               | map({(.[0]): (.[1:] | join("\t"))}) | add // {}'
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
  # THE PEER'S VALUE IS NOT QUOTED BACK. `got` is frontmatter the sender
  # wrote, and interpolating it into this reader's own stderr narration puts
  # peer-chosen bytes in the position a reader takes as the tool speaking --
  # the class read-inbox's malformed-file and self-ack reports both refuse by
  # name, by emitting counts and never the slug. The filename's stamp IS
  # quoted: it passed the grammar one check earlier, so it is 16 known-shape
  # characters, and without it the operator cannot tell which of two
  # timestamps the message should have carried.
  if [ "${want}" != "${got}" ]; then
    inbox_fail "message frontmatter \"sent_at\" disagrees with its filename (which says ${want})" \
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

# ============================================================================
# THE WRITER'S HALF (DND-187). Still pure: these build and check STRINGS. The
# staging, the link(2) and the doorbell are fs.sh's, and the order they happen
# in is the manager's.
# ============================================================================

# maildir_valid_slug <slug>
#
# Contract -> "Message filename": lowercase, ^[a-z0-9][a-z0-9-]*$, 1..48 bytes,
# never leading or trailing "-".
#
# The reader already refuses a bad slug through `maildir_valid_message_name`,
# and this looks like the same check twice. It is not: the reader is judging a
# name a PEER chose, where the only available answer is "not a conformant
# message". This judges a slug THIS session typed, where the answer can name
# the rule that was broken before anything is written -- and a refusal a sender
# can act on is the whole point of checking at the boundary rather than after
# the filename has been assembled.
maildir_valid_slug() {
  local slug="$1"
  [ -n "${slug}" ] || return 1
  [[ "${slug}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  case "${slug}" in *-) return 1 ;; esac
  [ "$(names_byte_length "${slug}")" -le 48 ] || return 1
  return 0
}

# maildir_basic_stamp <rfc3339>
#
# 2026-09-01T23:22:15Z -> 20260901T232215 (the filename's <UTCbasic>, without
# the literal Z the name carries separately).
#
# STRING SURGERY, NOT date(1). The filename stamp and the frontmatter
# `sent_at` are two copies of one fact, and `maildir_validate_message` refuses
# a message whose copies disagree -- so a sender that derived them from two
# separate `date` calls could straddle a second boundary and post a message
# the READER then refuses, forever, with the sender seeing a clean exit. One
# `date` call reaches this function and the filename is computed FROM the
# frontmatter value, which makes the agreement structural instead of likely.
maildir_basic_stamp() {
  local s="$1"
  [[ "${s}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
  printf '%s%s%sT%s%s%s\n' \
    "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
}

# maildir_next_seq   (a NUL-delimited directory listing on stdin)
#
# One past the highest <seq> present, zero-padded to at least 3 digits. An
# empty (or entirely non-conformant) directory yields 001.
#
# THE LISTING MUST INCLUDE `.acked/`. The contract is explicit -- "the next
# value is one past the highest <seq> present in the directory INCLUDING
# .acked/" -- and it matters because acking is what empties the live directory:
# a sender that scanned only the unacked names would restart at 001 the moment
# the peer caught up, and then collide with every message already in the
# transcript. The collision is caught (delivery cannot clobber) but it would be
# a retry loop on every send, forever, on a healthy channel.
#
# IT WIDENS PAST 999 RATHER THAN WRAPPING. Wrapping reorders the directory;
# widening does not, because the fixed-width timestamp prefix is what carries
# chronological order and <seq> only breaks ties inside one second.
#
# NUL-DELIMITED for the reason every other listing in this skill is: a name
# containing a newline arrives as two entries through any line-oriented
# encoding, and the slug is prose the PEER chose on the side of the
# conversation the peer writes into.
maildir_next_seq() {
  local name rest seq max=0
  while IFS= read -r -d '' name; do
    maildir_valid_message_name "${name}" || continue
    rest="${name%.md}"; rest="${rest#*Z-}"
    seq="${rest%%-*}"
    # 10# forces base 10: an allocated seq is zero-padded, and without it "008"
    # is an invalid octal constant that aborts the arithmetic -- so the scan
    # would die on precisely the names it allocated itself.
    seq=$((10#${seq}))
    [ "${seq}" -gt "${max}" ] && max="${seq}"
  done
  printf '%03d\n' "$((max + 1))"
}

# maildir_message_name <rfc3339> <seq> <slug>
#
# The filename, built and then RE-VALIDATED through the reader's own grammar.
# Not belt and braces: the builder and the reader must agree about what a
# conformant name is, and the only way to prove they do is to run the reader's
# check over the builder's output. A name this function emits is one the peer's
# reader accepts, or it is not emitted at all.
maildir_message_name() {
  local sent_at="$1" seq="$2" slug="$3" stamp name

  if ! maildir_valid_slug "${slug}"; then
    inbox_fail "refusing to send: the slug is not a legal message slug" \
      'use a slug matching ^[a-z0-9][a-z0-9-]*$, 1 to 48 characters, with no leading or trailing "-" -- it becomes part of the filename the peer sees, and a filename is data, never a path.'
    return 1
  fi
  if ! stamp="$(maildir_basic_stamp "${sent_at}")"; then
    inbox_fail "refusing to send: the timestamp is not RFC 3339 UTC" \
      'pass sent_at as YYYY-MM-DDTHH:MM:SSZ. The filename stamp is derived from this one value so the two copies cannot disagree.'
    return 1
  fi
  case "${seq}" in ''|*[!0-9]*) inbox_fail "refusing to send: the allocated sequence number is not numeric" \
      "this is a bug in the sender, not in your setup: re-run, and report it if it recurs."; return 1 ;;
  esac

  name="${stamp}Z-${seq}-${slug}.md"
  if ! maildir_valid_message_name "${name}"; then
    inbox_fail "refusing to send: the assembled filename does not match the contract's grammar" \
      'the filename is <YYYYMMDD>T<HHMMSS>Z-<seq>-<slug>.md with seq at least 3 digits; shorten the slug or report this as a sender bug.'
    return 1
  fi
  printf '%s\n' "${name}"
}

# maildir_refuse_self_send <to> <identity>
#
# The send-side mirror of `maildir_refuse_self_ack`, and an anti-footgun for
# the same reason: `from` is a LABEL, not authentication, so this is a check on
# MY OWN writes and calling it a security control would overstate it. A message
# addressed to my own identity would be delivered into the directory the PEER
# reads -- where the peer's reader sees a message addressed to someone else and
# the peer's "never ack your own" filter does not fire, so it sits unread
# forever and nothing ever says why.
maildir_refuse_self_send() {
  local to="$1" identity="$2"
  [ -n "${identity}" ] || return 0
  if [ "${to}" = "${identity}" ]; then
    inbox_fail "refusing to send a message addressed to this channel's own identity (\"${identity}\")" \
      "address the message to the PEER's identity -- the one on the other side of this channel, as it appears in the \"from\" of the mail you receive here. A message addressed to yourself lands in the directory the peer reads and is never claimed by anyone."
    return 1
  fi
  return 0
}

# maildir_render_message <from> <to> <sent_at> <re> <thread>   (body on stdin)
#
# The whole message: frontmatter, blank line, body. Buffered, so a refusal
# emits NOTHING -- a half-rendered message is a half-delivered one.
#
# EVERY VALUE IS REFUSED IF IT CAN BREAK THE FORMAT IT IS BEING WRITTEN INTO.
# The frontmatter block is `key: value` lines between `---` and a matching
# `---`, so a value carrying a newline writes a LINE, not a value -- and the
# line it writes may be `---`. A `re:` of $'x\n---\nfrom: someone-else' would
# close the block early and leave the rest of my own header in the body, or
# open a second one; the reader's parser would then attribute the message to
# whoever the injected line named. This is the same delimiter-collision class
# that has already cost this skill four bugs, arriving from the side that
# WRITES the delimiter rather than the side that splits on it.
#
# `from`, `to` and `thread` are covered by grammars that exclude a newline by
# construction; `re` is free text by the contract (an absolute path or a URL),
# so it is the one that needs the explicit arm.
maildir_render_message() {
  local from="$1" to="$2" sent_at="$3" re="${4:-}" thread="${5:-}" body

  if ! names_valid_identity "${from}"; then
    inbox_fail "refusing to send: this channel's \"identity\" is not a legal identity" \
      'set the channel'"'"'s "identity" in $ATHENA_INBOX_ROOT/projects/<project>.json to a name matching ^[a-z0-9][a-z0-9_-]*$, at most 64 bytes.'
    return 1
  fi
  if ! names_valid_identity "${to}"; then
    inbox_fail "refusing to send: the recipient is not a legal identity" \
      'pass --to with the peer'"'"'s identity, matching ^[a-z0-9][a-z0-9_-]*$, at most 64 bytes.'
    return 1
  fi
  if ! maildir_basic_stamp "${sent_at}" >/dev/null; then
    inbox_fail "refusing to send: the timestamp is not RFC 3339 UTC" \
      'pass sent_at as YYYY-MM-DDTHH:MM:SSZ; it must agree with the filename stamp, and the reader refuses a message whose two copies disagree.'
    return 1
  fi
  # The contract's frontmatter table says `re` is "an absolute path or URL".
  # A RELATIVE path is the one shape that silently means something different
  # on the other side: it resolves against the PEER's cwd, which is a different
  # repo on a different clock, and neither side is told the reference moved.
  if [ -n "${re}" ]; then
    case "${re}" in
      /*|*://*) ;;
      *)
        inbox_fail "refusing to send: \"re\" is neither an absolute path nor a URL" \
          "pass --re an absolute path (/home/...) or a URL (https://...). A relative path resolves against the PEER's working directory, so the reference would quietly point somewhere else on the other side."
        return 1
        ;;
    esac
  fi
  case "${re}" in
    *$'\n'*|*$'\r'*)
      inbox_fail "refusing to send: the \"re\" value contains a line break" \
        "pass a single-line absolute path or URL for --re. A line break in a frontmatter value writes a LINE, not a value, and could close the header early or forge a key."
      return 1
      ;;
  esac
  if [ -n "${thread}" ] && ! maildir_valid_message_name "${thread}"; then
    inbox_fail "refusing to send: \"thread\" is not a bare message filename" \
      'pass --thread the BARE FILENAME of the message being replied to (<YYYYMMDD>T<HHMMSS>Z-<seq>-<slug>.md), never a path. A message name is data, and a path there would point the thread link outside the channel.'
    return 1
  fi

  # The body is read whole and its emptiness is checked BEFORE anything is
  # emitted. An empty body is the MISSING-input shape of this command -- a
  # pipeline that produced nothing, an $EDITOR abandoned -- and delivering it
  # would put an empty message in the peer's transcript, immutably, with a
  # successful exit telling the sender their text went out.
  # SLURPED IN PURE BASH, not through `cat`. This is a domain file, and forking
  # for something the shell can do is the smaller reason: the larger one is
  # that a `cat` makes the renderer depend on PATH, so a broken environment
  # produced an EMPTY body and the refusal said "refusing to send an empty
  # message" -- a true statement about a body that was never read, pointing the
  # sender at their own text instead of at their environment. Found by the case
  # that strips PATH to prove the jq refusal names jq.
  #
  # The loop reproduces `cat` exactly at the one edge that matters: a final
  # line with no trailing newline is still part of the body, and `read` returns
  # non-zero having set it.
  local line
  body=""
  while IFS= read -r line; do body+="${line}"$'\n'; done
  [ -z "${line}" ] || body+="${line}"
  if [ -z "${body//[[:space:]]/}" ]; then
    inbox_fail "refusing to send an empty message" \
      "pipe the body in on stdin, or use --body-file. A message is immutable once delivered, so an empty one cannot be corrected -- only followed by another message with a thread: pointer."
    return 1
  fi

  # ASSEMBLED BY CONCATENATION, NOT IN A COMMAND SUBSTITUTION. `$( )` strips
  # ALL trailing newlines, so a header built that way loses the blank line
  # between the closing `---` and the body -- the separator this function's
  # own docstring, bin/send-mail's header and the contract's example all show.
  # Our reader tolerates either shape, so the cost would land entirely on the
  # OTHER implementation of this contract: the peer this channel exists to
  # talk to, which is not ours to assume about.
  local msg
  msg="---"$'\n'
  msg+="from: ${from}"$'\n'
  msg+="to: ${to}"$'\n'
  msg+="sent_at: ${sent_at}"$'\n'
  [ -n "${re}" ]     && msg+="re: ${re}"$'\n'
  [ -n "${thread}" ] && msg+="thread: ${thread}"$'\n'
  msg+="---"$'\n\n'
  msg+="${body}"
  # A trailing newline, always: the last line of the body is a line.
  case "${body}" in *$'\n') ;; *) msg="${msg}"$'\n' ;; esac

  # THE RENDER IS PARSED BACK BEFORE IT IS EMITTED, and refused if any value
  # does not survive.
  #
  # The checks above refuse a value that would break the FORMAT. This refuses
  # one the reader would silently CHANGE, which is the quieter half of the same
  # problem and was a live defect: `maildir_parse_frontmatter` strips a `#`
  # comment that follows whitespace and trims the ends of every value, so
  # `re: /home/x/design.md #section-3` arrives at the peer as
  # `/home/x/design.md` -- the fragment gone, both sides reporting success,
  # nothing anywhere saying a value was edited in transit. Measured, not
  # theorised.
  #
  # It is a ROUND TRIP rather than a list of forbidden characters on purpose:
  # enumerating today's parser rules here would put two copies of that grammar
  # in the tree, and the copy in the writer would go stale the first time the
  # reader learned a new one. Asking the actual parser what it would read costs
  # one pass over a header I have just built, and it cannot drift.
  local fm k got want
  # A MISSING CAPABILITY MUST NOT BE REPORTED AS A BAD VALUE. Without jq the
  # parse yields nothing, every value "does not survive", and the sender is
  # told its `re` carries whitespace or a `#` -- a refusal naming a cause that
  # is not the cause, which is the standing missing-vs-wrong rule arriving
  # inside the check written to honour it. `bin/send-mail` checks jq first, so
  # this is unreachable from the command; the library API is not the command.
  if ! command -v jq >/dev/null 2>&1; then
    inbox_fail "jq is required to render a message and was not found on PATH" \
      "install jq. The renderer parses its own output back to prove no value was silently changed in transit, and it cannot do that without jq -- so it refuses rather than sending unverified."
    return 1
  fi
  fm="$(printf '%s' "${msg}" | maildir_parse_frontmatter)"
  for k in from to sent_at re thread; do
    case "${k}" in
      re)     want="${re}" ;;
      thread) want="${thread}" ;;
      from)   want="${from}" ;;
      to)     want="${to}" ;;
      *)      want="${sent_at}" ;;
    esac
    [ -n "${want}" ] || continue
    got="$(printf '%s' "${fm}" | jq -r --arg k "${k}" '.[$k] // ""' 2>/dev/null)"
    if [ "${got}" != "${want}" ]; then
      inbox_fail "refusing to send: the \"${k}\" value would not survive the reader's own parse of this message" \
        "give \"${k}\" a value with no leading or trailing whitespace and no \" #\" sequence -- the message format treats a \"#\" following whitespace as a comment and trims the ends of every value, so the peer would have received something other than what you passed, with nothing reporting the difference."
      return 1
    fi
  done

  printf '%s' "${msg}"
  return 0
}
