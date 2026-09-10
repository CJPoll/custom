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

SLACK_INBOX_STATE="${SLACK_INBOX_STATE:-$SLACK_CACHE_DIR/inbox-state.json}"
# Requests per tick are roughly 2 + (channels scanned). Tier 3 gives ~50/min,
# and the hook runs at most once per 5 minutes, so 25 leaves comfortable room
# for whatever else the session is doing with the same token.
SLACK_INBOX_MAX_CHANNELS="${SLACK_INBOX_MAX_CHANNELS:-25}"
SLACK_INBOX_HISTORY_LIMIT="${SLACK_INBOX_HISTORY_LIMIT:-50}"

INBOX_CAPPED=0
INBOX_SKIPPED=0

_inbox_state_read() {
  if [ -f "$SLACK_INBOX_STATE" ]; then
    cat "$SLACK_INBOX_STATE"
  else
    printf '{"version":1,"channels":{}}'
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

# Merge the newest-observed timestamps into the state file. Called only by
# read-inbox, never by the hook.
inbox_state_advance() {
  slack_cache_dir
  if [ ! -s "$SLACK_TMPDIR/latest.tsv" ]; then return 0; fi
  _inbox_state_read \
    | jq --rawfile tsv "$SLACK_TMPDIR/latest.tsv" '
        .channels = (
          ($tsv | split("\n") | map(select(length > 0) | split("\t"))
                | map({key: .[0], value: .[1]}) | from_entries)
          as $new
          | .channels + $new
        )
      ' > "$SLACK_INBOX_STATE.tmp" || slack_die "could not update inbox state"
  mv "$SLACK_INBOX_STATE.tmp" "$SLACK_INBOX_STATE"
  return 0
}
