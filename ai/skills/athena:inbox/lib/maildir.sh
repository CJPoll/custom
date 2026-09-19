#!/usr/bin/env bash
# maildir.sh -- DOMAIN: pure. Partial by design.
#
# SCOPE NOTE. This ticket (DND-183) owns counting, not reading, acking or
# sending. The maildir filename grammar, seq allocation, frontmatter
# parse/render and the "never ack your own message" rule (QA D-20 … D-25) land
# with the read/ack ticket. Only the ONE function `bin/inbox-status` needs to
# produce an honest unread count lives here, so that the counting entry point
# is complete rather than half-wired for maildir channels.
#
# Source order: err.sh, names.sh, then this file.

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
