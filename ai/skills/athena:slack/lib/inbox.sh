# lib/inbox.sh -- "what is new for Athena" detection, shared by the polling
# hook (counts only, never advances state) and bin/read-inbox (bodies, and it
# does advance state). Sourced after lib/slack.sh.
#
# WHY THE SPLIT MATTERS. If the hook advanced the state file, the messages it
# counted would be marked seen before anyone read them, and read-inbox would
# print nothing. The hook is a doorbell; read-inbox is the door.
#
# WHAT COUNTS AS NEW:
#   DM      -- any message in an im/mpim conversation, newer than that
#              conversation's last-seen ts, not written by the bot itself.
#   MENTION -- a message in a channel the bot is a member of, newer than that
#              channel's last-seen ts, not written by the bot itself, whose
#              text contains the literal mention token <@BOT_USER_ID>.
#
# FIRST SIGHT IS NOT NEW. A conversation with no last-seen entry records its
# newest ts and reports nothing. Otherwise the first run after install would
# announce every DM in the workspace's history at once, and the first thing the
# skill ever did would be to cry wolf.

# THE STATE FILE IS SHARED WITH THE FILE CHANNEL (athena:inbox), on purpose.
# The two Slack sources -- this Web API backstop and the athena:inbox file
# reader -- carry the same messages under different identities (the file line
# has an `event_id`, the API poll does not; both have `channel` and `ts`). If
# they kept separate state they would double-report each other's messages. So
# there is ONE state file, derived from the log channel's `.jsonl` path by a
# suffix swap and living under $ATHENA_INBOX_ROOT, holding a single cross-source
# seen-set keyed on `channel + ":" + ts` (Slack's true message identity).
#
# This skill (the producer-side backstop) owns exactly two keys in that file:
# the `channels` per-conversation API watermark (moved here from the old
# ~/.cache/athena-slack/inbox-state.json so the two sources cannot disagree) and
# `last_api_poll_at`. It READS `seen_keys` to drop anything the file channel
# already delivered, and ADDS to `seen_keys` what it reports. Every other key
# (`offset`, `seen_event_ids`, `v`, `rotated_at`) belongs to the athena:inbox
# file reader and is preserved verbatim on write -- never clobbered. The contract
# (ai/contracts/athena-inbox.md, "Ordering and duplicates") reserves
# `last_api_poll_at`/`channels` for exactly this producer.
SLACK_INBOX_ROOT="${ATHENA_INBOX_ROOT:-$HOME/.local/share/athena}"
SLACK_INBOX_STATE="${SLACK_INBOX_STATE:-$SLACK_INBOX_ROOT/slack-inbox.state.json}"
# The pre-DND-186 location. Migrated on first run (its per-conversation
# watermark is carried across); a MISSING one is a clean start, not an error.
SLACK_INBOX_LEGACY_STATE="${SLACK_INBOX_LEGACY_STATE:-$SLACK_CACHE_DIR/inbox-state.json}"
# The bound on both dedupe ring buffers, matching athena:inbox's LOGCHAN_RING_CAP
# so the two producers agree on the file's shape.
SLACK_INBOX_RING_CAP="${SLACK_INBOX_RING_CAP:-500}"
# Requests per tick are roughly 2 + (channels scanned). Tier 3 gives ~50/min,
# and the hook runs at most once per 5 minutes, so 25 leaves comfortable room
# for whatever else the session is doing with the same token.
SLACK_INBOX_MAX_CHANNELS="${SLACK_INBOX_MAX_CHANNELS:-25}"
SLACK_INBOX_HISTORY_LIMIT="${SLACK_INBOX_HISTORY_LIMIT:-50}"

INBOX_CAPPED=0
INBOX_SKIPPED=0

# The empty state: the new schema, cross-source-ready. `channels` is the API
# watermark; `seen_keys`/`seen_event_ids` are the shared dedupe rings.
_inbox_state_empty() { printf '{"v":1,"channels":{},"seen_event_ids":[],"seen_keys":[]}'; }

_inbox_state_read() {
  if [ -f "$SLACK_INBOX_STATE" ]; then
    cat "$SLACK_INBOX_STATE"
  elif [ -f "$SLACK_INBOX_LEGACY_STATE" ]; then
    # First run after the state moved into the shared inbox-root file: carry the
    # per-conversation API watermark across so a message already seen by the old
    # cache is not re-announced. The dedupe rings start empty. A parse failure of
    # the legacy file falls back to a clean start rather than aborting the scan.
    jq -c '{v: 1, channels: (.channels // {}), seen_event_ids: [], seen_keys: []}' \
      "$SLACK_INBOX_LEGACY_STATE" 2>/dev/null || _inbox_state_empty
  else
    # A missing state file is a clean start, NOT an error.
    _inbox_state_empty
  fi
}

_inbox_last_seen() {
  _inbox_state_read | jq -r --arg c "$1" '.channels[$c] // ""'
}

# inbox_scan <newline-separated-output-file>
# Writes one compact JSON object per new message:
#   {"kind":"dm"|"mention","channel":"C..","ts":"..","user":"U..","text":".."}
# and leaves the newest observed ts per channel in $SLACK_TMPDIR/latest.tsv,
# which inbox_state_advance consumes. Sets INBOX_CAPPED=1 if the channel list
# was truncated.
inbox_scan() {
  _is_out="$1"
  : > "$_is_out"
  slack_tmp_init
  : > "$SLACK_TMPDIR/latest.tsv"
  slack_load_identity
  slack_cache_dir

  # DM + group-DM conversations. conversations.list defaults to public_channel
  # only, so the types parameter is what makes DMs visible at all.
  # Two statements, not a pipeline: in POSIX sh `a | b` exits with b's status,
  # so a slack_die inside slack_paginate would be swallowed by a jq that
  # happily succeeds on the empty input it was left. The scan would then report
  # "nothing new" for a revoked token, indefinitely and silently.
  slack_paginate conversations.list \
    "limit=200&exclude_archived=true&types=im%2Cmpim" '.channels' \
    > "$SLACK_TMPDIR/dms.jsonl"
  # Slackbot's IM is listed by conversations.list and then 404s on
  # conversations.history -- measured against the real workspace on 2026-09-01:
  # `conversations.history failed: channel_not_found` for the USLACKBOT im,
  # which aborted the whole scan. It can never carry a message for Athena, so
  # it is dropped by name rather than merely tolerated below.
  jq -r 'select((.user // "") != "USLACKBOT") | .id' "$SLACK_TMPDIR/dms.jsonl" \
    > "$SLACK_TMPDIR/dm-ids"

  # Channels the bot has actually joined. conversations.history on a channel the
  # bot is not in returns not_in_channel, so scanning all of them would be one
  # guaranteed error per non-member channel.
  _is_ch_file="$(_slack_channels_file)"
  if ! _slack_cache_fresh "$_is_ch_file" "$SLACK_CHANNELS_TTL_MIN"; then
    slack_refresh_channels
  fi
  jq -r 'map(select(.is_member == true)) | .[].id' "$_is_ch_file" > "$SLACK_TMPDIR/member-ids"

  _is_budget="$SLACK_INBOX_MAX_CHANNELS"
  _is_total=$(( $(wc -l < "$SLACK_TMPDIR/dm-ids") + $(wc -l < "$SLACK_TMPDIR/member-ids") ))
  if [ "$_is_total" -gt "$_is_budget" ]; then
    INBOX_CAPPED=1
  fi

  _inbox_scan_list dm "$SLACK_TMPDIR/dm-ids" "$_is_out"
  _inbox_scan_list mention "$SLACK_TMPDIR/member-ids" "$_is_out"

  # Cross-source dedupe. Drop anything the FILE channel already delivered: its
  # reader records each message's `channel:ts` in the shared `seen_keys`, and a
  # message delivered there must not be re-reported here. Runs for the hook (so
  # its count is not inflated) and for read-inbox (so a body is not shown twice)
  # alike; read-inbox is what later adds these keys back for the file reader.
  _inbox_drop_seen "$_is_out"
  return 0
}

# _inbox_drop_seen <scan-output-file>
# Rewrites the scan output, removing any message whose `channel:ts` is already
# in the shared seen_keys set.
_inbox_drop_seen() {
  _ds_out="$1"
  [ -s "$_ds_out" ] || return 0
  _ds_keys="$SLACK_TMPDIR/seen_keys.json"
  _inbox_state_read | jq -c '.seen_keys // []' > "$_ds_keys" 2>/dev/null \
    || printf '[]' > "$_ds_keys"
  if jq -c --slurpfile k "$_ds_keys" '
        ($k[0] // []) as $seen
        | select(($seen | index(.channel + ":" + .ts)) | not)
      ' "$_ds_out" > "$_ds_out.tmp" 2>/dev/null; then
    mv "$_ds_out.tmp" "$_ds_out"
  else
    rm -f "$_ds_out.tmp" 2>/dev/null || true
  fi
  return 0
}

# _inbox_scan_list <kind> <id-file> <out-file>
_inbox_scan_list() {
  _sl_kind="$1"
  _sl_ids="$2"
  _sl_out="$3"
  _sl_attempted=0
  _sl_skipped_before="$INBOX_SKIPPED"
  while IFS= read -r _sl_ch; do
    if [ -z "$_sl_ch" ]; then continue; fi
    if [ "$_is_budget" -le 0 ]; then return 0; fi
    _is_budget=$((_is_budget - 1))

    _sl_last="$(_inbox_last_seen "$_sl_ch")"
    _sl_q="channel=$(slack_urlencode "$_sl_ch")&limit=$SLACK_INBOX_HISTORY_LIMIT"
    if [ -n "$_sl_last" ]; then
      _sl_q="$_sl_q&oldest=$(slack_urlencode "$_sl_last")"
    else
      _sl_q="$_sl_q&limit=1"
    fi
    # One unreadable conversation must not blind the whole inbox. The subshell
    # is load-bearing: slack_die runs `exit`, so calling slack_get directly in
    # an `if !` condition would take the entire script down instead of failing
    # the test. Skips are counted, and a scan in which EVERY conversation
    # failed is still an error -- otherwise a broken read would look exactly
    # like a quiet inbox, which is the failure this whole design is arranged
    # to make impossible.
    _sl_attempted=$((_sl_attempted + 1))
    if ! ( slack_get conversations.history "$_sl_q" > "$SLACK_TMPDIR/hist.json" ) 2>/dev/null; then
      INBOX_SKIPPED=$((INBOX_SKIPPED + 1))
      continue
    fi

    # conversations.history returns newest first, so [0] is the newest ts in
    # the window -- the value the state file must advance to whether or not any
    # of those messages were addressed to us.
    _sl_newest="$(jq -r '.messages[0].ts // ""' "$SLACK_TMPDIR/hist.json")"
    if [ -n "$_sl_newest" ]; then
      printf '%s\t%s\n' "$_sl_ch" "$_sl_newest" >> "$SLACK_TMPDIR/latest.tsv"
    elif [ -z "$_sl_last" ]; then
      # First sight of a conversation that has no messages at all. It must
      # still get a state entry, or it stays "first sight" forever and the
      # first real message that ever arrives is swallowed by the rule that
      # exists to suppress backlog. A ts of 0 means "seen nothing yet", so the
      # next message is new. Measured against the real workspace: 10 of 13
      # conversations were empty on the first scan and recorded nothing.
      printf '%s\t%s\n' "$_sl_ch" "0" >> "$SLACK_TMPDIR/latest.tsv"
    fi

    # First sight: record where we are, report nothing.
    if [ -z "$_sl_last" ]; then continue; fi

    jq -c --arg kind "$_sl_kind" --arg ch "$_sl_ch" --arg me "$SLACK_BOT_USER_ID" '
      .messages[]?
      | select((.user // "") != $me)
      | select((.subtype // "") != "message_changed")
      | select((.subtype // "") != "message_deleted")
      | select(($kind == "dm") or ((.text // "") | contains("<@" + $me + ">")))
      | {kind: $kind, channel: $ch, ts: .ts, user: (.user // .bot_id // "unknown"),
         thread_ts: (.thread_ts // .ts), text: (.text // "")}
    ' "$SLACK_TMPDIR/hist.json" >> "$_sl_out"
  done < "$_sl_ids"
  if [ "$_sl_attempted" -gt 0 ] &&
     [ "$((INBOX_SKIPPED - _sl_skipped_before))" -eq "$_sl_attempted" ]; then
    slack_die "every $_sl_kind conversation failed to read ($_sl_attempted of $_sl_attempted)"
  fi
  return 0
}

# inbox_state_advance [reported-jsonl]
# Merge the newest-observed timestamps into the state file, record the reported
# messages' `channel:ts` in the shared cross-source `seen_keys`, and stamp the
# backstop's last-poll time. Called only by read-inbox (the door), NEVER by the
# hook (the doorbell) -- a hook that advanced state would mark messages seen
# before anyone read them.
#
# Read-modify-write that PRESERVES every key this producer does not own
# (`offset`, `seen_event_ids`, `v`, `rotated_at`): they belong to the
# athena:inbox file reader, which shares this one file. Clobbering them would
# rewind the file channel's consumption or drop its intra-file dedupe ring.
inbox_state_advance() {
  _isa_reported="${1:-}"
  # $ATHENA_INBOX_ROOT, not the ~/.cache dir: this file is the shared one.
  _isa_dir="${SLACK_INBOX_STATE%/*}"
  mkdir -p "$_isa_dir" 2>/dev/null || slack_die "cannot create $_isa_dir"

  # channel:ts of everything reported this read, one per line, for seen_keys.
  _isa_keys="$SLACK_TMPDIR/reported-keys"
  : > "$_isa_keys"
  if [ -n "$_isa_reported" ] && [ -s "$_isa_reported" ]; then
    jq -r 'select((.channel // "") != "" and (.ts // "") != "")
           | .channel + ":" + .ts' "$_isa_reported" >> "$_isa_keys" 2>/dev/null || true
  fi

  _isa_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  _inbox_state_read \
    | jq --rawfile tsv "$SLACK_TMPDIR/latest.tsv" \
         --rawfile keys "$_isa_keys" \
         --arg now "$_isa_now" \
         --argjson cap "$SLACK_INBOX_RING_CAP" '
        .v = (.v // 1)
        | .channels = (
            (.channels // {})
            + ($tsv | split("\n") | map(select(length > 0) | split("\t"))
                    | map({key: .[0], value: .[1]}) | from_entries)
          )
        | .seen_keys = (
            ((.seen_keys // []) + ($keys | split("\n") | map(select(length > 0))))
            | .[-$cap:]
          )
        | .last_api_poll_at = $now
      ' > "$SLACK_INBOX_STATE.tmp" || slack_die "could not update inbox state"
  mv "$SLACK_INBOX_STATE.tmp" "$SLACK_INBOX_STATE"
  return 0
}
