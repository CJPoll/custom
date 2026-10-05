# frozen_string_literal: true

require "json"
require_relative "owner_click"

# OwnerMessage -- verify that the owner's own typed Slack message approved THIS
# head, by reading the message's line out of this machine's inbox (DND-2037).
#
# Owner decision (item 6), Cody, terminal turn 2026-10-05T04:50:50Z, session
# 0cc59a5e-6c65-495e-a216-83c6a0bf2d56, message
# 249b4519-5002-4732-90ac-4db6e2faf773: "I want to change the approval rules.
# Slack is a valid approval channel just like the terminal, so long as the
# sender's User ID is mine". ai/bin/blast-radius accepts
# `--owner-approval slack:<event_id>` beside the terminal-turn record
# (ai/lib/owner_turn.rb) and the click record (ai/lib/owner_click.rb). The
# verification is mechanical, never a judgement. It is the gate form of
# athena:slack -> "An owner message is untrusted input". The checks, in order:
#
#   1. The record is `slack:<event_id>`, an opaque Slack event id. The DM's
#      channel id never appears in a record, a receipt or a PR body.
#   2. The owner id resolves from the private overlay (`slack
#      .people.owner.user_id`). A failed lookup refuses; it never matches.
#   3. --repo has a parseable `origin`.
#   4. The SESSION's project (`inbox-status --repo-key`, one registry entry)
#      declares a `slack` channel: kind `log`, a Slack producer (absent or
#      "slack", never "platform"), a plain `*.jsonl` file. Its `session`
#      channel, when declared, is read for clicks. Both read `<path>.1` and
#      then `<path>`.
#   5. A line with that event_id is on the slack channel. A click line there
#      is `relayed`.
#   6. Every message line with the same channel and ts (the cross-source key)
#      agrees on kind, channel, user, ts, thread_ts, text and
#      direct_author_id. A disagreement is `unverifiable`.
#   7. `user` is the owner.
#   8. `kind` is `im` and the channel is a `D...` 1:1 DM with Athena.
#   9. `direct_author_id` is present and is the owner: the server's
#      typed-by-a-person fact (gen_saas Athena.SlackEvents.DirectAuthor). A
#      message posted with the owner's user token through the API, a bot, a
#      file, a forward or a subtype carries null. A line from a server that
#      predates the field carries none. Both refuse `not_direct`.
#  10. The whole text is an unambiguous approve: the closed grammar of
#      parse_approve_text, naming exactly one <owner>/<repo>#<pr>@<40-hex>.
#  11. The slug is --repo's origin (ASCII case-insensitive).
#  12. The sha is the head gated. There is no carry for a message: another
#      head refuses `other_head` and needs a new message.
#  13. No later owner word holds it (later_message_hold, later_click_hold):
#      R1 a later owner message in the same conversation that is not the same
#      approve; R2 a later owner message anywhere that mentions the PR and is
#      not the same approve; R3 a later owner message starting with a hold
#      word that names no PR; R4 a later owner click whose value mentions the
#      PR and is not the same approve; R5 a later owner click starting with a
#      hold word that names no PR. A tie counts as later. A rival that cannot
#      be ordered refuses. R1-R3 also apply to a click approval
#      (OwnerClick.check), so an owner's hold message beats an earlier click.
#
# Every refusal names the files, lines, owner messages, clicks and unparsable
# lines it read, and blast-radius prints it with a Fix:.
#
# Residuals, said out loud:
#   - Sender identity is the Athena server's relay of a signed Slack event,
#     the same trust as a click's actor.
#   - A process running as the owner's user can append an inbox line, or
#     point ATHENA_INBOX_ROOT, ATHENA_PRIVATE_ROOT or CLAUDE_PROJECT_DIR at
#     roots it wrote, as for clicks and transcripts. The approved line names
#     the file it read.
#   - direct_author_id closes a user-token post only as far as Slack omits
#     client_msg_id on API posts. Until the server writes the field, no
#     message passes.
#   - Edits and deletes never reach the inbox. A deleted approve still
#     approves; the owner reverses with a new message or a Hold click.
#   - A hold routed to another project's inbox is not seen, as for clicks.
module OwnerMessage
  PREFIX = "slack:"
  RECORD_RE = /\Aslack:(Ev[A-Z0-9]{6,32})\z/.freeze
  VERBS = %w[approve approve-exit4].freeze
  PR_SRC = "[1-9][0-9]{0,9}"
  REF_SRC = "#{OwnerClick::SLUG.source}##{PR_SRC}@[0-9a-f]{40}"
  BODY_SRC = "[A-Za-z0-9-]+[ \\t]+(?:`#{REF_SRC}`|#{REF_SRC})"
  TEXT_RE = /\A[ \t]*(?:`#{BODY_SRC}`|#{BODY_SRC})[ \t]*\z/.freeze
  REF_RE = /(#{OwnerClick::SLUG.source})#(#{PR_SRC})@([0-9a-f]{40})/.freeze
  # Matched against ASCII-folded text, never with Regexp /i (which folds
  # non-ASCII letters too).
  HOLD_WORD_RE = /\A[ \t]*(?:hold|reject|deny|decline|block|stop|cancel|wait|no|nope|dont|don't|do not|revoke|undo|abort|pause)\b/.freeze
  ANY_PR_RE = %r{#[0-9]|/pull/[0-9]|/-/merge_requests/[0-9]}.freeze
  CHANNEL = "slack"
  DM_CHANNEL_RE = /\AD[A-Z0-9]+\z/.freeze
  CLICK_KIND = "slack.interaction"

  FIX = "clear an exit 4 with the owner's own Slack message: in the decision DM's thread " \
        "(athena:slack -> \"An exit-4 ask names the PR and head\"), the owner replies with exactly " \
        "'#{OwnerClick::ASK_VERB} <owner>/<repo>#<pr>@<full head sha>' for the exact head being gated. " \
        "Then pass the line's event_id from a session of the same project: --owner-approval " \
        "'slack:<event_id>'. A message in a group DM or a channel, one the owner did not type (an API " \
        "or user-token post, a bot, a file, a forward), any other wording, another repo, another head " \
        "(no carry: a rebase needs a new message), and an approve the owner later held (a later reply " \
        "in that thread, a later message naming the PR, or a Hold click) never count. Edits and " \
        "deletions are not seen: reverse with a new message or a Hold click. Or pass the owner's " \
        "click, --owner-approval 'click:<delivery_id>', or terminal turn, --owner-approval " \
        "'session:<session-uuid>/<message-uuid> quote:<words>'."

  module_function

  def record?(value)
    value.to_s.strip.start_with?(PREFIX)
  end

  # PURE. -> the event id, or nil when the record is not slack:<event_id>.
  def parse_record(value)
    m = RECORD_RE.match(value.to_s.strip)
    m && m[1]
  end

  def fold(text)
    text.to_s.tr("A-Z", "a-z")
  end

  # PURE. The whole text is one unambiguous approve, by the closed grammar
  # (DND-2037 design, "the closed grammar"):
  #   TEXT := WS* ( "`" BODY "`" | BODY ) WS*
  #   BODY := VERB SP+ ( "`" REF "`" | REF )
  #   VERB := approve | approve-exit4 (ASCII case-insensitive)
  #   REF  := <owner>/<repo>#<pr>@<40 lowercase hex>
  # Only spaces and tabs; no newline, no other word or character; ASCII only.
  # -> {slug:, pr:, sha:} or nil.
  def parse_approve_text(text)
    return nil unless text.is_a?(String) && text.ascii_only? && TEXT_RE.match?(text)

    verb = text.sub(/\A[ \t]*`?/, "")[/\A[A-Za-z0-9-]+/]
    return nil unless VERBS.include?(fold(verb))

    refs = text.scan(REF_RE)
    return nil unless refs.size == 1

    slug, pr, sha = refs.first
    { slug: slug, pr: Integer(pr, 10), sha: sha }
  end

  def same_ref?(got, ref)
    !got.nil? && fold(got[:slug]) == fold(ref[:slug]) && got[:pr] == ref[:pr] && got[:sha] == ref[:sha]
  end

  # PURE. The text mentions PR ref[:pr] of ref[:slug], ASCII case-insensitive:
  # <slug>#<pr>, <slug>/pull/<pr>, <slug>/-/merge_requests/<pr>, a bare
  # #<pr>, each not followed by a digit, or a 7-to-40-hex prefix of the head
  # standing as its own word. Deliberately broad: wider only fails closed.
  def mentions_pr?(text, ref)
    t = fold(text)
    slug = Regexp.escape(fold(ref[:slug]))
    pr = Integer(ref[:pr])
    return true if Regexp.new("(?<![a-z0-9_./-])#{slug}##{pr}(?![0-9])").match?(t)
    return true if Regexp.new("#{slug}/(?:pull|-/merge_requests)/#{pr}(?![0-9])").match?(t)
    return true if Regexp.new("##{pr}(?![0-9])").match?(t)

    sha = ref[:sha].to_s
    t.scan(/(?<![0-9a-z_])[0-9a-f]{7,40}(?![0-9a-z_])/).any? { |hex| sha.start_with?(hex) }
  end

  # PURE. The text names some PR, whichever.
  def any_pr?(text)
    ANY_PR_RE.match?(fold(text))
  end

  # PURE. The text starts with a hold word.
  def hold_word?(text)
    HOLD_WORD_RE.match?(fold(text))
  end

  def click?(line)
    line["kind"] == CLICK_KIND
  end

  def owner_message?(line, owner_id)
    !click?(line) && line["user"] == owner_id
  end

  # A message's conversation root: its thread_ts, or its own ts.
  def root_of(line)
    t = line["thread_ts"]
    t.is_a?(String) && !t.empty? ? t : line["ts"]
  end

  def ref_name(ref)
    "#{ref[:slug]}##{ref[:pr]}@#{ref[:sha]}"
  end

  # PURE. R1-R3: a later owner message that holds the approval named by
  # `ref`, given at `at` in conversation (`channel`, `root`). `exclude` is
  # the approval's own [channel, ts], when it is a message. Used for both a
  # message approval and a click approval (the click's channel and ts are the
  # decision post's). -> nil, or [:refused, kind, reason].
  def later_message_hold(ref:, channel:, root:, at:, messages:, owner_id:, what:, exclude: nil)
    rivals = messages.filter_map do |m|
      next nil unless owner_message?(m, owner_id)
      next nil if exclude && [m["channel"], m["ts"]] == exclude

      text = m["text"].to_s
      same = same_ref?(parse_approve_text(text), ref)
      rule = if m["channel"] == channel && root_of(m) == root && !same then :r1
             elsif mentions_pr?(text, ref) && !same then :r2
             elsif hold_word?(text) && !any_pr?(text) then :r3
             end
      rule && [rule, m, OwnerClick.action_time(m["ts"])]
    end
    undated = rivals.find { |_, _, t| t.nil? }
    if undated
      return [:refused, :unverifiable,
              "an owner message that may hold #{what} has a ts that cannot be ordered " \
              "(#{undated[1]['ts'].to_s[0, 40].inspect}), so whether it came after the approval cannot be told"]
    end
    later = rivals.select { |_, _, t| (t <=> at) >= 0 }
    held = later.find { |rule, _, _| rule != :r3 }
    if held
      where = held[0] == :r1 ? "in the same conversation" : "mentioning #{ref[:slug]}##{ref[:pr]}"
      return [:refused, :superseded,
              "a later owner message #{where} (ts #{held[1]['ts']}, text #{quote(held[1]['text'])}) is " \
              "not the same approve, so it is the owner's last word on #{what}"]
    end
    bare = later.first
    return nil unless bare

    [:refused, :unverifiable,
     "a later owner message (ts #{bare[1]['ts']}, text #{quote(bare[1]['text'])}) starts with a hold " \
     "word and names no PR, so whether it held #{what} cannot be told"]
  end

  # PURE. R4-R5: a later owner click that holds a message approval.
  # -> nil, or [:refused, kind, reason].
  def later_click_hold(ref:, at:, clicks:, owner_id:, what:)
    rivals = clicks.filter_map do |c|
      next nil unless OwnerClick.owner_click?(c, owner_id)

      value = c["value"].to_s
      same = same_ref?(OwnerClick.parse_ask_value(value), ref)
      rule = if mentions_pr?(value, ref) && !same then :r4
             elsif hold_word?(value) && !any_pr?(value) then :r5
             end
      rule && [rule, c, OwnerClick.action_time(c["action_ts"])]
    end
    undated = rivals.find { |_, _, t| t.nil? }
    if undated
      return [:refused, :unverifiable,
              "an owner click that may hold #{what} (#{undated[1]['action_id'].inspect}) has an action_ts " \
              "that cannot be ordered, so whether it came after the approval cannot be told"]
    end
    later = rivals.select { |_, _, t| (t <=> at) >= 0 }
    held = later.find { |rule, _, _| rule == :r4 }
    if held
      return [:refused, :superseded,
              "a later owner click (#{held[1]['action_id'].inspect}, value #{quote(held[1]['value'])}) " \
              "mentions #{ref[:slug]}##{ref[:pr]} and is not the same approve, so it is the owner's last " \
              "word on #{what}"]
    end
    bare = later.first
    return nil unless bare

    [:refused, :unverifiable,
     "a later owner click (#{bare[1]['action_id'].inspect}, value #{quote(bare[1]['value'])}) starts with " \
     "a hold word and names no PR, so whether it held #{what} cannot be told"]
  end

  def quote(text)
    text.to_s[0, 120].inspect
  end

  AGREE_KEYS = %w[kind channel user ts thread_ts text].freeze

  def projection(line)
    AGREE_KEYS.map { |k| line[k] } + [line.key?("direct_author_id") ? line["direct_author_id"] : :absent]
  end

  # PURE. Judge the slack-channel lines carrying one event id against the
  # gate's head. `messages` is every non-click line read from the slack
  # channel; `clicks` every click line read from both channels.
  # -> [:verified, info] | [:refused, kind, reason] |
  #    [:refused, kind, reason, fix].
  def judge(hits, event_id:, owner_id:, head:, slug:, where:, messages: [], clicks: [])
    if hits.empty?
      return [:refused, :not_found,
              "no line with event_id #{event_id} in #{where}. Only a message delivered to the session's " \
              "project slack channel is read: a message routed to another project, a copy on the session " \
              "channel, and a message rotated out of both files are not there"]
    end
    if hits.any? { |l| click?(l) }
      return [:refused, :relayed,
              "event #{event_id} in #{where} is a #{CLICK_KIND} line, not a message: pass a click as " \
              "click:<delivery_id>"]
    end

    line = hits.first
    %w[channel ts].each do |f|
      next if line[f].is_a?(String) && !line[f].empty? && !line[f].match?(/[\s:]/)

      return [:refused, :unverifiable, "message #{event_id} has no usable #{f}"]
    end
    at = OwnerClick.action_time(line["ts"])
    return [:refused, :unverifiable, "message #{event_id}'s ts is not <seconds>.<fraction>"] unless at

    group = (hits + messages.select { |m| m["channel"] == line["channel"] && m["ts"] == line["ts"] })
    if group.map { |l| projection(l) }.uniq.size > 1
      return [:refused, :unverifiable,
              "#{group.size} lines in #{where} carry event #{event_id} or its channel and ts, and they " \
              "disagree on kind, channel, user, ts, thread_ts, text or direct_author_id: a redelivered " \
              "message repeats one message exactly"]
    end
    unless line["user"] == owner_id
      return [:refused, :not_owner, "message #{event_id}'s user is not the overlay's owner id"]
    end
    unless line["kind"] == "im" && DM_CHANNEL_RE.match?(line["channel"])
      return [:refused, :not_dm,
              "message #{event_id} is kind #{line['kind'].inspect}, not a 1:1 DM with Athena (kind \"im\" on " \
              "a D channel): other people are in a group DM, a channel or a channel thread"]
    end
    unless line.key?("direct_author_id")
      return [:refused, :not_direct,
              "message #{event_id}'s line has no direct_author_id: the server that wrote this line predates " \
              "direct_author_id, so whether the owner typed it cannot be told"]
    end
    unless line["direct_author_id"] == owner_id
      return [:refused, :not_direct,
              "message #{event_id} is not a message the owner typed (direct_author_id is not the owner): an " \
              "API or user-token post, a bot, a file, a forward or a subtype"]
    end

    ref = parse_approve_text(line["text"])
    unless ref
      return [:refused, :not_approve,
              "message #{event_id}'s text #{quote(line['text'])} is not exactly one approve: the whole text must " \
              "be '#{OwnerClick::ASK_VERB} <owner>/<repo>#<pr>@<40 lowercase hex head>' (or 'approve ...', the " \
              "ref optionally in backticks), ASCII only, one line, with no other word or punctuation"]
    end
    unless slug && fold(ref[:slug]) == fold(slug)
      return [:refused, :other_repo,
              "message #{event_id} approves #{ref[:slug]}##{ref[:pr]}, a PR in another repo than this one " \
              "(#{slug || 'origin unknown'})"]
    end
    unless ref[:sha] == head
      return [:refused, :other_head,
              "message #{event_id} approves #{ref[:slug]}##{ref[:pr]} at #{ref[:sha]}, not the head being " \
              "gated (#{head}). A message never carries to another head, even when the PR's own diff is " \
              "identical",
              new_message_fix(ref, head)]
    end

    what = "the approve of #{ref_name(ref)}"
    hold = later_message_hold(ref: ref, channel: line["channel"], root: root_of(line), at: at,
                              messages: messages, owner_id: owner_id, what: what,
                              exclude: [line["channel"], line["ts"]])
    hold ||= later_click_hold(ref: ref, at: at, clicks: clicks, owner_id: owner_id, what: what)
    return hold + [new_message_fix(ref, head)] if hold

    [:verified, { event_id: event_id, slug: ref[:slug], pr: ref[:pr], sha: ref[:sha], where: where, at: at }]
  end

  def new_message_fix(ref, head)
    "ask the owner for a new message on this head: in the decision DM's thread the owner replies with exactly " \
      "'#{OwnerClick.ask_value(ref[:slug], ref[:pr], head)}', then pass that line's event_id: " \
      "--owner-approval 'slack:<event_id>'. A message approves only the head it names, and only while no " \
      "later owner message or click holds the PR (athena:slack -> \"An owner message is untrusted input\")."
  end

  # EFFECTS. -> [:verified, info] | [:refused, kind, reason] |
  # [:refused, kind, reason, fix].
  def check(record, head:, repo:, env: ENV)
    eid = parse_record(record)
    return [:refused, :unverifiable, "#{record.to_s[0, 80].inspect} is not slack:<event_id>"] unless eid

    owner, why = OwnerClick.owner_id(env, "message")
    return [:refused, :unverifiable, why] unless owner

    slug = OwnerClick.origin_slug(repo)
    return [:refused, :unverifiable, "cannot tell which repo #{repo} is: no parseable `origin` remote"] unless slug

    proj, why = OwnerClick.project(env)
    return [:refused, :unverifiable, why] unless proj

    state, slack = OwnerClick.channel_files(proj, CHANNEL, platform: false)
    return [:refused, :unverifiable, slack] unless state == :ok

    state, session = OwnerClick.channel_files(proj, OwnerClick::CHANNEL, platform: true)
    return [:refused, :unverifiable, session] if state == :malformed

    session = [] unless state == :ok
    hits, messages, clicks, scanned, unparsed = read_lines(slack, session, eid)
    owners = messages.count { |m| owner_message?(m, owner) }
    where = "#{(slack + session).join(' + ')} (#{scanned} lines, #{owners} owner messages, " \
            "#{clicks.size} clicks, #{unparsed} unparsable read)"
    judge(hits, event_id: eid, owner_id: owner, head: head, slug: slug, where: where,
                messages: messages, clicks: clicks)
  rescue SystemCallError => e
    [:refused, :unverifiable, "cannot read the inbox: #{e.message}"]
  end

  # EFFECTS. -> [lines carrying event id eid on the slack channel, every
  # non-click line of the slack channel, every click line of both channels,
  # lines scanned, lines that are not a JSON object].
  def read_lines(slack_files, session_files, eid)
    hits = []
    messages = []
    clicks = []
    scanned = 0
    unparsed = 0
    slack_files.each do |f|
      s, u = OwnerClick.each_json(f) do |j|
        hits << j if j["event_id"] == eid
        click?(j) ? clicks << j : messages << j
      end
      scanned += s
      unparsed += u
    end
    session_files.each do |f|
      s, u = OwnerClick.each_json(f) { |j| clicks << j if click?(j) }
      scanned += s
      unparsed += u
    end
    [hits, messages, clicks, scanned, unparsed]
  end
end
