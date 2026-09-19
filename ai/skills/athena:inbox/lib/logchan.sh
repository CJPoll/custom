#!/usr/bin/env bash
# logchan.sh -- the counting rules for a `log` channel. DOMAIN (the one effect
# available to it is a refusal on stderr via err.sh; it does not use one).
#
# It takes a BYTE SLICE on stdin and returns JSON. It never opens the inbox, so
# every rule below is provable without a fixture on disk -- which matters more
# here than anywhere else in the skill, because each of these failures looks
# exactly like the healthy state from the outside:
#
#   * a partial final line parsed as a record   -> a truncated event invented
#   * an offset advanced past that fragment     -> the completion lost forever
#   * an unknown line `v` failing the run       -> a schema bump takes the
#                                                  reader down instead of
#                                                  degrading
#   * a duplicate counted                       -> at-least-once delivery read
#                                                  as new mail
#
# Source order: err.sh, names.sh, then this file. Requires jq.

LOGCHAN_RING_CAP=500

# logchan_dedupe_key <channel> <ts>
#
# `channel + ":" + ts` is the CROSS-SOURCE key, and it has to be: the Slack Web
# API backstop carries no `event_id`, so `event_id` cannot be the identity that
# spans sources. `event_id` remains the INTRA-FILE key that absorbs an
# at-least-once re-append of the same line.
logchan_dedupe_key() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  printf '%s:%s\n' "$1" "$2"
}

# logchan_split_complete
# Reads a byte slice on stdin, writes back ONLY the complete (newline-
# terminated) prefix. The trailing fragment of a writer that died mid-write is
# dropped whole.
#
# The `printf X` dance is not a flourish: `$(...)` strips trailing newlines, and
# the count of trailing newlines is exactly the fact this function exists to
# preserve.
logchan_split_complete() {
  local data
  data="$(cat; printf X)"; data="${data%X}"
  case "${data}" in
    *$'\n'*) printf '%s\n' "${data%$'\n'*}" ;;
    *) : ;;
  esac
}

# logchan_scan <offset> <schema_v_csv> <seen_event_ids> <seen_keys> [with_text]
#
# Byte slice on stdin (the file from <offset> to EOF). Emits one JSON object:
#   {"new":N,"unreadable":U,"next_offset":O,
#    "messages":[{"ts":…,"channel":…,"event_id":…}, …]}
#
# `with_text` (default 0) is what separates the COUNT path from the READ path,
# and it is a parameter rather than a filter applied afterwards on purpose.
# With it off, no message body exists in this function's return value AT ALL --
# so the counting path cannot leak one even through a future renderer's
# mistake, because there is nothing there to print. The contract's counts-only
# rule is about the pre-prompt position, and this is the structural half of it.
# The read path passes 1 and renders inside a nonce fence.
#
# `next_offset` advances over COMPLETE LINES ONLY (D-13). That is the whole
# crash-safety guarantee: the fragment is neither parsed nor counted, and the
# offset stops in front of it, so when the writer completes that line it is
# counted exactly once (D-14) rather than zero times or twice.
#
# `messages` is ordered by `ts`, NOT by file position (D-19). File order is
# DELIVERY order and the two disagree: a client draining a backlog after an
# outage appends older messages after newer ones. `received_at` is monotonic;
# `ts` is not, and `ts` is what recency means to a human.
logchan_scan() {
  local offset="$1" schema_csv="${2:-1}" seen_ev="${3:-}" seen_ky="${4:-}" with_text="${5:-0}"
  local complete bytes sv_json ev_json ky_json wt_json

  # The offset is validated HERE, not only by the caller. It reaches an
  # arithmetic context below, and bash EXECUTES a command substitution inside
  # an array subscript in that context -- `a[$(...)]` runs. The manager does
  # sanitize it today, but this function is documented as a strings-in domain
  # primitive with no stated precondition, and its taint source is a state
  # file that becomes writable the moment the ack ticket lands. A primitive
  # that is only safe because of its current caller is not safe.
  case "${offset}" in
    ''|*[!0-9]*)
      inbox_fail "refusing a non-numeric byte offset" \
        "pass logchan_scan a decimal byte offset; a state file whose \"offset\" is not a plain number is corrupt and should be reset to 0."
      return 1
      ;;
  esac

  complete="$(logchan_split_complete; printf X)"; complete="${complete%X}"
  bytes="$(LC_ALL=C printf '%s' "${complete}" | wc -c | tr -d ' ')"

  sv_json="$(printf '%s' "${schema_csv}" | jq -R 'split(",") | map(select(length>0) | tonumber)')"
  ev_json="$(printf '%s' "${seen_ev}" | jq -R -s 'split("\n") | map(select(length>0))')"
  ky_json="$(printf '%s' "${seen_ky}" | jq -R -s 'split("\n") | map(select(length>0))')"
  case "${with_text}" in 1|true|yes) wt_json=true ;; *) wt_json=false ;; esac

  printf '%s' "${complete}" | jq -R -s \
    --argjson sv "${sv_json}" \
    --argjson ev "${ev_json}" \
    --argjson ky "${ky_json}" \
    --argjson wt "${wt_json}" \
    --argjson next "$((offset + bytes))" '
    def parse: try fromjson catch null;

    reduce (split("\n") | map(select(length > 0)) | .[]) as $line
      ({new: [], unreadable: 0, ev: ($ev | map({(.): true}) | add // {}),
        ky: ($ky | map({(.): true}) | add // {})};
        ($line | parse) as $o
        | if ($o | type) != "object" then
            # Not JSON at all, or a bare scalar: unreadable, never fatal.
            .unreadable += 1
          elif ($sv | index($o.v) | not) then
            # D-15: an unknown line `v` DEGRADES. It is counted separately and
            # never fails the run -- the deliberate opposite of an unknown `v`
            # on the registry entry, which is a hard error. A schema bump on
            # the writer must not take the reader down.
            .unreadable += 1
          else
            # Both keys are forced to STRINGS before they are used as object
            # keys. A line is JSON written by other people: nothing guarantees
            # `event_id` is a string, and `.ev[7]` is not a lookup that misses,
            # it is `Cannot index object with number` -- a jq FATAL that aborts
            # the scan of every remaining line in the slice. A malformed line
            # must cost one `unreadable`, never the whole channel.
            # A DEDUPE KEY CARRYING A NEWLINE OR TAB IS NOT A KEY.
            #
            # The seen-sets travel as NEWLINE-delimited lists (see
            # logchan_ring_append) and these fields are PEER-CONTROLLED: a line
            # with "event_id":"a\nEv-victim" would inject a SECOND entry into
            # the seen-set, and the next genuine message carrying `Ev-victim`
            # would be silently suppressed as already-seen. That is message
            # loss chosen by the sender, with nothing reported anywhere.
            #
            # This is the third instance of one class in this skill -- the
            # first was a tab in a registry FILENAME shifting the JSON out of
            # the record emitted by fs_registry_records, the second a tab in a channel
            # `path` colliding with the `<label>\t<path>` resolve protocol
            # (both fixed on main). The lesson recorded there was to grep for
            # every other place the protocol is used rather than patch the
            # instance; this is the result of that grep.
            #
            # Such a key is DISCARDED rather than sanitised, and a line left
            # with no usable key falls through to the `unreadable` branch
            # below -- the same treatment as a line carrying no key at all,
            # for the same reason: deduping on nothing means re-reporting
            # forever, and a rule that says so once should not grow a second
            # spelling.
            def usable: if type == "string" and (test("[\n\t]") | not) then . else null end;
            (if ($o.channel // "") != "" and ($o.ts // "") != ""
             then ("\($o.channel):\($o.ts)" | usable) else null end) as $key
            | (if ($o.event_id | type) == "null" then null
               else ($o.event_id | tostring | usable) end) as $eid
            | if $eid == null and $key == null then
                # A line carrying NEITHER key cannot be deduped, so counting it
                # would mean deduping on nothing and re-reporting it forever.
                .unreadable += 1
              elif ($eid != null and (.ev[$eid] // false))
                or ($key != null and (.ky[$key] // false)) then
                # D-16 / D-17: already seen. At-least-once delivery makes a
                # re-append NORMAL, not an anomaly.
                .
              else
                .new += [ ({ts: ($o.ts // ""), channel: ($o.channel // ""), event_id: ($eid // "")}
                           + (if $wt then
                                # Every peer-controlled field is forced to a
                                # STRING here. A `text` that arrived as an
                                # object or an array would otherwise reach the
                                # renderer as a jq structure and print as one,
                                # and the fence renders what it is given -- so
                                # the coercion is part of the boundary, not
                                # cosmetics.
                                {text: (($o.text // "") | tostring),
                                 user: (($o.user // "") | tostring),
                                 kind: (($o.kind // "") | tostring),
                                 permalink: (($o.permalink // "") | tostring)}
                              else {} end)) ]
                | (if $eid != null then .ev[$eid] = true else . end)
                | (if $key != null then .ky[$key] = true else . end)
              end
          end
      )
    | {new: (.new | length),
       unreadable: .unreadable,
       next_offset: $next,
       messages: (.new | sort_by((.ts | tonumber? // 0), .ts))}
  '
}

# logchan_state_merge <existing-state-json> <updates-json>
#
# The channel state file, rewritten. PURE: it merges two documents and returns
# a third; the atomic write is fs.sh's job (and lands with the ack ticket,
# DND-184 -- nothing in THIS slice writes state).
#
# UNRECOGNISED KEYS ARE PRESERVED VERBATIM. This is the deliberate OPPOSITE of
# the registry parser's rule in descriptor.sh, and both parsers live in this
# one library, so the asymmetry looks like an inconsistency unless it is
# written down:
#
#   * registry entry (descriptor.sh) -- an unknown key is a HARD ERROR (D-8).
#     It is MY OWN CONFIGURATION, hand-written, so a typo is a bug I want
#     reported loudly rather than defaulted silently.
#   * state file (here) -- an unknown key is PRESERVED. It is MACHINE-WRITTEN
#     state, and the machine that wrote it may be a NEWER version of this
#     tooling than the one reading it. Emitting a fixed key set would discard
#     that writer's data on the very next ack.
#
# The concrete failure this exists to prevent: the retention policy (DND-184)
# adds a `rotated_at` key. An ack that rewrote a fixed key set would drop it,
# rotation would then never fire again, the log would grow forever -- which is
# exactly the defect retention exists to fix -- and nothing would report it.
# A discarded key is invisible in production by construction.
# The defaults are assigned rather than written as `${1:-\{\}}`: inside double
# quotes a backslash before `{` is LITERAL, so that spelling defaults to the
# string `\{}` and jq dies on it. The first-run case -- no state file yet, so
# an empty or absent existing document -- is precisely the one the ack ticket
# will hit first, and jq given empty input never reaches the `// {}` guard in
# the program, so the guard alone is not enough.
logchan_state_merge() {
  local existing="${1:-}" updates="${2:-}"
  [ -n "${existing}" ] || existing='{}'
  [ -n "${updates}" ] || updates='{}'
  printf '%s' "${existing}" | jq -c --argjson u "${updates}" '(. // {}) * $u'
}

# logchan_ring_append <cap> <existing> <additions>
#
# Both lists newline-separated, oldest first; prints the capped result. The
# seen-sets live in a state file rewritten on every ack, so unbounded growth is
# its own failure mode -- a state file that grows without limit eventually
# costs more to rewrite than the messages are worth.
logchan_ring_append() {
  local cap="${1:-${LOGCHAN_RING_CAP}}" existing="${2:-}" additions="${3:-}"
  # `|| true` on the filter: under `set -o pipefail` a `grep` that matches
  # nothing exits 1 and takes the whole pipeline with it, so appending nothing
  # to an empty ring -- the FIRST-RUN case, and the first one the ack ticket
  # will hit -- would look like a failure.
  { printf '%s\n%s\n' "${existing}" "${additions}" | grep -v '^$' || true; } \
    | awk '!seen[$0]++' \
    | tail -n "${cap}"
}

# --- retention: the rotation and sweep decisions (DND-204) ------------------
#
# DOMAIN, and deliberately so. Both decisions are arithmetic over four numbers,
# and keeping them here means R-1 … R-7 are provable with no file on disk, no
# `touch -t`, and no clock. The I/O half -- the rename, the unlink, the
# re-check under the lock -- is fs.sh's, and the gate is the manager's.

LOGCHAN_ROTATE_AGE_S=604800        # 7 days
LOGCHAN_ROTATE_SIZE=8388608        # 8 MiB
LOGCHAN_SWEEP_AGE_S=1209600        # 14 days

# logchan_should_rotate <offset> <size> <rotated_at_epoch|""> <now_epoch>
# Prints "yes" or "no". Never fails a run: an unparseable input is "no".
#
# ALL of these must hold (contract -> "Rotation trigger"):
#
#   1. offset == size            the EOF gate. Rotating with unread bytes
#                                DESTROYS them, and retention's whole principle
#                                is that it never touches content nobody has
#                                read. Age NEVER overrides this (R-1): a reader
#                                away for three weeks comes back to a large
#                                un-rotated inbox, and that is the system
#                                working.
#   2. size > 0                  the non-emptiness clause, and it is not
#                                decoration. Rotation resets the offset to 0,
#                                so an empty live file means nothing arrived
#                                since the last rotation -- and without this a
#                                quiet channel would rename an EMPTY file over
#                                its `.1` every 7 days, destroying the evidence
#                                the sweep's 14-day window promises, on exactly
#                                the low-traffic channel where that window is
#                                the only thing that ever fires.
#   3. age >= 7d OR size >= 8MiB age is the PRIMARY trigger and size the
#                                backstop, not the reverse. This channel
#                                carries the routable subset of a workspace --
#                                hundreds of bytes per week -- so a size-only
#                                threshold never fires and the file grows
#                                forever, which is the defect retention exists
#                                to close.
#
# An ABSENT `rotated_at` is "unknown", not "infinitely old", and the answer is
# NO. That is the upgrade case and the very first case any implementation
# meets: today's deployed state files carry `offset` and the seen-sets and
# nothing else. Treating absent as ancient would rotate, on the first drain, a
# file nobody meant to rotate. The caller stamps it to `now` instead and the
# clock starts from the first reader that understood it.
logchan_should_rotate() {
  local offset="$1" size="$2" rot="$3" now="$4" age

  case "${offset}${size}${now}" in ''|*[!0-9]*) printf 'no\n'; return 0 ;; esac
  [ "${offset}" = "${size}" ] || { printf 'no\n'; return 0; }
  [ "${size}" -gt 0 ]         || { printf 'no\n'; return 0; }

  if [ "${size}" -ge "${LOGCHAN_ROTATE_SIZE}" ]; then printf 'yes\n'; return 0; fi

  case "${rot}" in ''|*[!0-9]*) printf 'no\n'; return 0 ;; esac
  age=$(( now - rot ))
  # A `rotated_at` in the FUTURE (a clock stepped backwards, a hand-edited
  # state file) yields a negative age, which is not >= the window, so it does
  # not rotate. That is the conservative direction: a deferred rotation costs
  # disk, an eager one costs evidence.
  if [ "${age}" -ge "${LOGCHAN_ROTATE_AGE_S}" ]; then printf 'yes\n'; else printf 'no\n'; fi
  return 0
}

# logchan_should_sweep <rotated_at_epoch|""> <now_epoch>
# Prints "yes" or "no".
#
# THE CLOCK IS `rotated_at`, NOT THE `.1` MTIME, and the difference is not
# academic. `rename(2)` PRESERVES mtime, so a rotated file's mtime is the
# timestamp of its last APPEND and can already be days old at the moment it
# becomes `.1` -- sweeping on that would make the real retention window vary
# with write traffic, which is the one thing a stated window must not do. The
# reader stamps `.1`'s mtime to `now` on rotation as a convenience for a human
# running `ls -l`; where the two disagree, `rotated_at` wins and the mtime is
# restamped.
#
# `rotated_at` ABSENT -- a `.1` left by an older reader -- is NOT sweepable.
# The reader does not compute a window from mtime at all; it stamps
# `rotated_at` to now so the clock starts from the first reader that
# understood it. Keeping evidence a fortnight too long is recoverable;
# destroying it early is not.
logchan_should_sweep() {
  local rot="$1" now="$2"
  case "${now}" in ''|*[!0-9]*) printf 'no\n'; return 0 ;; esac
  case "${rot}" in ''|*[!0-9]*) printf 'no\n'; return 0 ;; esac
  if [ $(( now - rot )) -gt "${LOGCHAN_SWEEP_AGE_S}" ]; then printf 'yes\n'; else printf 'no\n'; fi
  return 0
}
