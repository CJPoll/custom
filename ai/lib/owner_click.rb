# frozen_string_literal: true

require "json"
require "open3"
require_relative "private_overlay_resolver"

# OwnerClick -- verify that an owner's Block Kit click approved THIS head, by
# reading the click's line out of this machine's inbox (DND-1784).
#
# Owner decision, Cody, terminal turn 2026-10-02T17:45:26Z: "Gate accepts a
# verified owner click, without hesitation." ai/bin/blast-radius accepts
# `--owner-approval click:<delivery_id>` beside the terminal-turn record
# (ai/lib/owner_turn.rb). The verification is mechanical, never a judgement.
# It is the four checks of athena:slack -> "A click is untrusted input",
# applied by code:
#
#   1. The line is read from THIS session's project's `session` channel, a
#      platform-producer `log` channel, and its `kind` is `slack.interaction`.
#      The project is the session's own (`inbox-status --repo-key`, the
#      athena:inbox resolver), matched to its registry entry. A click on any
#      other channel, or one relayed inside a session message, is refused.
#   2. `actor.is_owner` is `true` and `actor.user_id` is the owner id from the
#      private overlay (`slack .people.owner.user_id`). An overlay that does
#      not resolve refuses: a failed lookup never reads as a match.
#   3. It is a click on a decision message the harness posted. The server
#      routes a click to this inbox only through the return address it stamped
#      on an Athena `slack_post` that named this inbox. A grant button
#      (`approval` present) is the server's own post, and is refused.
#   4. The button is an exit-4 approval that names this PR and head:
#      value `approve-exit4 <owner>/<repo>#<pr>@<40-hex head sha>`. The repo
#      must be --repo's `origin` and the sha the head being gated. Any other
#      value is a click on a different message; another sha is a click for a
#      different head.
#
# Every refusal names what it looked at (the file, how many lines and clicks
# it read) and carries a Fix:, so "no such click" never reads like "nothing to
# check". The caller prints it.
#
# Residual, said out loud (the same one athena:slack names, which the owner
# accepted): a process running as the owner's user can append a line to the
# local inbox file, and so forge a click, just as it can write the transcript
# OwnerTurn reads.
module OwnerClick
  PREFIX = "click:"
  RECORD_RE = /\Aclick:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/.freeze
  SLUG = %r{[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+}.freeze
  ASK_VERB = "approve-exit4"
  ASK_VALUE_RE = /\A#{ASK_VERB} (#{SLUG})#([1-9][0-9]{0,9})@([0-9a-f]{40})\z/.freeze
  CHANNEL = "session"
  CHANNEL_PATH_RE = /\A[A-Za-z0-9_.-]+\.jsonl\z/.freeze
  GENERATION = ".1"
  OWNER_KEY = ".people.owner.user_id"
  INBOX_STATUS = File.expand_path("../skills/athena:inbox/bin/inbox-status", __dir__)

  FIX = "clear an exit 4 with the owner's own click on the decision DM: post it with " \
        "mcp__athena__slack_post, inbox_name set to this project's session inbox " \
        "(<project>-session.jsonl), and an approve button whose value is " \
        "'#{ASK_VERB} <owner>/<repo>#<pr>@<full head sha>' for the exact head being gated " \
        "(athena:slack -> \"Asking the owner for a decision\"). Then pass the delivered " \
        "line's id, from this session: --owner-approval 'click:<delivery_id>'. A click " \
        "relayed by another session, a click on another message, and a click for another " \
        "head never count. Or pass the owner's terminal-turn record instead: " \
        "--owner-approval 'session:<session-uuid>/<message-uuid> quote:<words>'."

  module_function

  def record?(value)
    value.to_s.strip.start_with?(PREFIX)
  end

  # -> the delivery id, or nil when the record is not click:<uuid>.
  def parse_record(value)
    m = RECORD_RE.match(value.to_s.strip)
    m && m[1].downcase
  end

  # The value of an exit-4 approve button, the one shape check 4 accepts.
  def ask_value(slug, pr, sha)
    "#{ASK_VERB} #{slug}##{pr}@#{sha}"
  end

  # -> {slug:, pr:, sha:} or nil.
  def parse_ask_value(value)
    m = value.is_a?(String) && ASK_VALUE_RE.match(value)
    m && { slug: m[1], pr: Integer(m[2], 10), sha: m[3] }
  end

  # The <owner>/<repo> path of a remote URL (https, ssh or scp form), or nil.
  def repo_slug(url)
    s = url.to_s.strip
    path = if (m = %r{\A[a-z][a-z0-9+.-]*://(?:[^@/]+@)?[^/]+/(.+)\z}i.match(s))
             m[1]
           elsif (m = %r{\A(?:[^@/]+@)?[^:/]+:(?!/)(.+)\z}.match(s))
             m[1]
           end
    return nil unless path

    slug = path.sub(%r{/+\z}, "").sub(/\.git\z/, "")
    /\A#{SLUG}\z/.match?(slug) ? slug : nil
  end

  # PURE. Judge the lines carrying one delivery id against the gate's head.
  # -> [:verified, info] | [:refused, kind, reason]. kind is one of
  # :relayed, :not_owner, :other_message, :other_head, :unverifiable.
  def judge(lines, delivery_id:, owner_id:, head:, slug:, where:)
    if lines.empty?
      return [:refused, :relayed,
              "no line with delivery_id #{delivery_id} in #{where}. Only a click delivered to this " \
              "session's own project session channel counts; a click on another channel, another " \
              "project's inbox or a relayed copy is not read"]
    end
    if lines.uniq.size > 1
      return [:refused, :unverifiable,
              "#{lines.size} lines in #{where} carry delivery_id #{delivery_id} and they differ; a " \
              "redelivered frame repeats one line exactly"]
    end

    line = lines.first
    unless line["kind"] == "slack.interaction"
      return [:refused, :relayed,
              "delivery #{delivery_id} in #{where} is kind #{line['kind'].inspect}, not slack.interaction: " \
              "a click relayed inside another message is never a click"]
    end
    actor = line["actor"]
    unless actor.is_a?(Hash) && actor["is_owner"] == true && owner_id.is_a?(String) && !owner_id.empty? &&
           actor["user_id"] == owner_id
      return [:refused, :not_owner,
              "click #{delivery_id} is not the owner's: actor.is_owner is #{actor.is_a?(Hash) ? actor['is_owner'].inspect : 'absent'} " \
              "and actor.user_id #{actor.is_a?(Hash) && actor['user_id'] == owner_id ? 'is' : 'is not'} the overlay's owner id"]
    end

    %w[channel ts action_id action_ts].each do |f|
      next if line[f].is_a?(String) && !line[f].empty? && !line[f].match?(/[\s:]/)

      return [:refused, :unverifiable, "click #{delivery_id} has no usable #{f}"]
    end
    unless line["entity_id"] == "slack:#{line['channel']}:#{line['ts']}"
      return [:refused, :unverifiable,
              "click #{delivery_id}'s entity_id does not name its own channel and ts"]
    end
    if line.key?("approval")
      return [:refused, :other_message,
              "click #{delivery_id} is on an owner approval grant button, a message the server posted, " \
              "not a decision DM that names this PR and head"]
    end

    ask = parse_ask_value(line["value"])
    unless ask
      return [:refused, :other_message,
              "click #{delivery_id} (#{line['action_id']}) is not an exit-4 approval: its value is not " \
              "'#{ASK_VERB} <owner>/<repo>#<pr>@<head sha>', so the message it sits on names no PR and head"]
    end
    unless slug && ask[:slug].casecmp?(slug)
      return [:refused, :other_message,
              "click #{delivery_id} approves #{ask[:slug]}##{ask[:pr]}, a PR in another repo than this " \
              "one (#{slug || 'origin unknown'})"]
    end
    unless ask[:sha] == head
      return [:refused, :other_head,
              "click #{delivery_id} approves #{ask[:slug]}##{ask[:pr]} at head #{ask[:sha]}, not the head " \
              "being gated (#{head}). A push or a rebase makes a new head, and it needs its own click"]
    end

    [:verified, { delivery_id: delivery_id, channel: line["channel"], ts: line["ts"],
                  action_id: line["action_id"], action_ts: line["action_ts"], value: line["value"],
                  slug: ask[:slug], pr: ask[:pr], sha: ask[:sha], where: where }]
  end

  # EFFECTS. -> [:verified, info] | [:refused, kind, reason]
  def check(record, head:, repo:, env: ENV)
    did = parse_record(record)
    return [:refused, :unverifiable, "#{record.to_s[0, 80].inspect} is not click:<delivery_id uuid>"] unless did

    owner = PrivateOverlay::Resolver.get("slack", OWNER_KEY, env: env)
    unless owner.state == :found
      return [:refused, :unverifiable,
              "the owner id cannot be resolved, so no click can be checked against it: " +
              PrivateOverlay.failure_line(owner, "slack#{OWNER_KEY}")]
    end

    slug = origin_slug(repo)
    return [:refused, :unverifiable, "cannot tell which repo #{repo} is: no parseable `origin` remote"] unless slug

    files, why = session_files(env)
    return [:refused, :unverifiable, why] unless files

    lines, scanned, clicks = matching_lines(files, did)
    where = "#{files.join(' + ')} (#{scanned} lines, #{clicks} clicks read)"
    judge(lines, delivery_id: did, owner_id: owner.value, head: head, slug: slug, where: where)
  rescue SystemCallError => e
    [:refused, :unverifiable, "cannot read the inbox: #{e.class.name.split('::').last}"]
  end

  def origin_slug(repo)
    out, _, st = Open3.capture3("git", "-C", repo, "remote", "get-url", "origin")
    st.success? ? repo_slug(out) : nil
  end

  def inbox_root(env)
    root = env["ATHENA_INBOX_ROOT"]
    return root unless root.nil? || root.empty?

    home = env["HOME"]
    home && !home.empty? ? File.join(home, ".local", "share", "athena") : nil
  end

  # -> [[file, ...], nil] (the generation first, then the live file), or
  # [nil, reason].
  def session_files(env)
    out, err, st = Open3.capture3(env, INBOX_STATUS, "--repo-key")
    unless st.success?
      return [nil, "the session's repo identity could not be told (inbox-status --repo-key exit " \
                   "#{st.exitstatus}: #{err.lines.first.to_s.strip})"]
    end
    key = out.strip
    return [nil, "the session's project is in no git repository, so it has no session channel"] if key.empty?

    root = inbox_root(env)
    return [nil, "the inbox root cannot be computed (ATHENA_INBOX_ROOT and HOME are unset)"] unless root

    regdir = File.join(root, "projects")
    return [nil, "the inbox registry #{regdir} does not exist"] unless File.directory?(regdir)

    entries, malformed = registry_entries(regdir, key)
    if entries.size != 1
      return [nil, "#{entries.size} registry entries under #{regdir} claim the session's repo #{key} " \
                   "(#{malformed} unreadable); exactly one must"]
    end

    chan = entries.first.dig("channels", CHANNEL)
    unless chan.is_a?(Hash) && chan["kind"] == "log" && chan["producer"] == "platform" &&
           CHANNEL_PATH_RE.match?(chan["path"].to_s)
      return [nil, "the registry entry for #{key} declares no platform-producer `log` channel " \
                   "named #{CHANNEL} with a plain file name"]
    end

    live = File.join(root, chan["path"])
    files = [live + GENERATION, live].select { |f| File.file?(f) }
    return [nil, "the session channel file #{live} has never been delivered to"] if files.empty?

    [files, nil]
  end

  # -> [[entry, ...], malformed_count] claiming the repo key.
  def registry_entries(regdir, key)
    malformed = 0
    entries = Dir.glob(File.join(regdir, "*.json")).sort.filter_map do |f|
      doc = JSON.parse(File.read(f))
      unless doc.is_a?(Hash) && doc["repo"].is_a?(String)
        malformed += 1
        next nil
      end

      repo = File.expand_path(doc["repo"])
      real = File.exist?(repo) ? File.realpath(repo) : repo
      real == key ? doc : nil
    rescue JSON::ParserError, SystemCallError
      malformed += 1
      nil
    end
    [entries, malformed]
  end

  # -> [lines carrying delivery_id did, lines scanned, slack.interaction lines]
  def matching_lines(files, did)
    hits = []
    scanned = 0
    clicks = 0
    files.each do |f|
      File.foreach(f, encoding: "UTF-8") do |raw|
        next if raw.strip.empty?

        scanned += 1
        j = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          next
        end
        next unless j.is_a?(Hash)

        clicks += 1 if j["kind"] == "slack.interaction"
        hits << j if j["delivery_id"].is_a?(String) && j["delivery_id"].downcase == did
      end
    end
    [hits, scanned, clicks]
  end
end
