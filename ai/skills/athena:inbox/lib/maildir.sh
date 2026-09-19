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

# maildir_filter_unread   (directory listing on stdin, one name per line)
#
# Prints the names that are actually unread messages.
#
# D-24: `tmp/` holds half-delivered files (the writer lands there and then
# rename(2)s into place), `.acked/` holds what was already consumed, and
# `.event` is the doorbell, not mail. A reader that counts any of them reports
# messages that do not exist -- and the dotfile rule is what makes that
# exclusion a RULE rather than a list of three names to keep in sync.
#
# Deliberately a filter over a listing rather than a directory read: it stays
# pure, so the exclusion is provable with no directory on disk.
maildir_filter_unread() {
  grep -v -e '^$' -e '^\.' -e '^tmp$' || true
}
