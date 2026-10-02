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
# It applies the checks of athena:slack -> "A click is untrusted input" by
# code, with check 3 replaced by a binding the code can test:
#
#   1. The line is read from the `session` channel of the SESSION's project, a
#      platform-producer `log` channel, and its `kind` is `slack.interaction`.
#      The project is the session's (`inbox-status --repo-key`, the
#      athena:inbox resolver), matched to its registry entry. Every session of
#      that project shares the channel. A click on any other channel, or one
#      relayed inside a session message, is refused.
#   2. `actor.is_owner` is `true` and `actor.user_id` is the owner id from the
#      private overlay (`slack .people.owner.user_id`). An overlay that does
#      not resolve refuses: a failed lookup never reads as a match.
#   3. (replaced) The skill binds a click to its question by the post's
#      `{channel, ts}`, which only the posting session holds. The gate binds
#      it by the button value instead (check 4). The server routes a click to
#      this inbox only through the return address it stamped on an Athena
#      `slack_post` that named this inbox. A grant button (`approval` present)
#      is the server's own post, and is refused.
#   4. The button is an exit-4 approval that names this PR and head:
#      value `approve-exit4 <owner>/<repo>#<pr>@<40-hex head sha>`. The repo
#      must be --repo's `origin` and the sha the head being gated. Any other
#      value is a click on a different message; another sha is a click for a
#      different head. The PR number is as the button states it: only the
#      repo and the head are checked.
#   5. No later owner click on the same message chose otherwise. A hold or
#      reject after the approve is the owner's last word, and it wins. A
#      rival click that cannot be ordered refuses. The check is per
#      message: a hold on a different DM does not reverse this one.
#
# Every refusal names what it looked at (the files, how many lines, clicks and
# unparsable lines it read) and carries a Fix:, so "no such click" never
# reads like "nothing to check". The caller prints it.
#
# Residuals, said out loud:
#   - A process running as the owner's user can append a line to the local
#     inbox file, and so forge a click, just as it can write the transcript
#     OwnerTurn reads (the residual athena:slack names, which the owner
#     accepted). The same process can point ATHENA_INBOX_ROOT,
#     ATHENA_PRIVATE_ROOT or CLAUDE_PROJECT_DIR at roots it wrote. The
#     approved line names the inbox file it read.
#   - Slack does not show a button's value. The gate binds the value, not the
#     text the owner read, so the poster is trusted to render the same PR and
#     head. athena:slack -> "Asking the owner for a decision" therefore puts
#     the value string verbatim in the visible text.
module OwnerClick
  PREFIX = "click:"
  RECORD_RE = /\Aclick:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/.freeze
  SLUG = %r{[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+}.freeze
  ASK_VERB = "approve-exit4"
  ASK_VALUE_RE = /\A#{ASK_VERB} (#{SLUG})#([1-9][0-9]{0,9})@([0-9a-f]{40})\z/.freeze
  ACTION_TS_RE = /\A([0-9]+)\.([0-9]{1,9})\z/.freeze
  OWNER_ID_RE = /\A[A-Z0-9]+\z/.freeze
  CHANNEL = "session"
  CHANNEL_PATH_RE = /\A[A-Za-z0-9_.-]+\.jsonl\z/.freeze
  GENERATION = ".1"
  OWNER_KEY = ".people.owner.user_id"
  INBOX_STATUS = File.expand_path("../skills/athena:inbox/bin/inbox-status", __dir__)

  FIX = "clear an exit 4 with the owner's own click on the decision DM: post it with " \
        "mcp__athena__slack_post, inbox_name set to this project's session inbox " \
        "(<project>-session.jsonl), and an approve button whose value is " \
        "'#{ASK_VERB} <owner>/<repo>#<pr>@<full head sha>' for the exact head being gated, " \
        "that string also in the visible text (athena:slack -> \"Asking the owner for a " \
        "decision\"). Then pass the delivered line's id from a session of the same project: " \
        "--owner-approval 'click:<delivery_id>'. A click relayed from another channel or " \
        "project, a click on another message, a click for another head, and an approve the " \
        "owner later reversed never count. A click that rotated out of the inbox needs a " \
        "new ask. Or pass the owner's terminal-turn record instead: " \
        "--owner-approval 'session:<session-uuid>/<message-uuid> quote:<words>'."

  module_function

  def record?(value)
    value.to_s.strip.start_with?(PREFIX)
  end

  # -> the delivery id (lowercase), or nil when the record is not click:<uuid>.
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

  # A Slack action_ts as a comparable [seconds, fraction] pair, or nil.
  def action_time(ts)
    m = ts.is_a?(String) && ACTION_TS_RE.match(ts)
    m && [Integer(m[1], 10), m[2].ljust(9, "0").to_i]
  end

  def owner_click?(line, owner_id)
    line["kind"] == "slack.interaction" && line["actor"].is_a?(Hash) &&
      line["actor"]["is_owner"] == true && line["actor"]["user_id"] == owner_id
  end

  # PURE. Judge the lines carrying one delivery id against the gate's head.
  # `clicks` is every slack.interaction line read, for check 5.
  # -> [:verified, info] | [:refused, kind, reason]. kind is one of
  # :not_found, :relayed, :not_owner, :other_message, :other_head,
  # :superseded, :unverifiable.
  def judge(lines, delivery_id:, owner_id:, head:, slug:, where:, clicks: [])
    if lines.empty?
      return [:refused, :not_found,
              "no line with delivery_id #{delivery_id} in #{where}. Only a click delivered to the " \
              "session's project session channel is read: a click on another channel or another " \
              "project's inbox, a relayed copy, and a click rotated out of both files are not there"]
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
    unless owner_click?(line, owner_id)
      actor = line["actor"]
      return [:refused, :not_owner,
              "click #{delivery_id} is not the owner's: actor.is_owner is " \
              "#{actor.is_a?(Hash) ? actor['is_owner'].inspect : 'absent'} and actor.user_id " \
              "#{actor.is_a?(Hash) && actor['user_id'] == owner_id ? 'is' : 'is not'} the overlay's owner id"]
    end

    %w[channel ts action_id action_ts].each do |f|
      next if line[f].is_a?(String) && !line[f].empty? && !line[f].match?(/[\s:]/)

      return [:refused, :unverifiable, "click #{delivery_id} has no usable #{f}"]
    end
    unless line["entity_id"] == "slack:#{line['channel']}:#{line['ts']}"
      return [:refused, :unverifiable,
              "click #{delivery_id}'s entity_id does not name its own channel and ts"]
    end
    at = action_time(line["action_ts"])
    return [:refused, :unverifiable, "click #{delivery_id}'s action_ts is not <seconds>.<fraction>"] unless at
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

    rivals = clicks.select do |c|
      owner_click?(c, owner_id) && c["channel"] == line["channel"] && c["ts"] == line["ts"] &&
        c["value"] != line["value"]
    end
    # A rival that cannot be ordered might be the owner's later hold: refuse
    # rather than read it as "no reversal".
    undated = rivals.find { |c| action_time(c["action_ts"]).nil? }
    if undated
      return [:refused, :unverifiable,
              "another owner click on the same message (#{undated['action_id'].inspect}) has an action_ts " \
              "that cannot be ordered, so whether it reversed click #{delivery_id} cannot be told"]
    end
    later = rivals.find { |c| (action_time(c["action_ts"]) <=> at) == 1 }
    if later
      return [:refused, :superseded,
              "the owner clicked #{later['action_id'].inspect} on the same message after click " \
              "#{delivery_id}: the later click is the owner's decision, and it is not this approval"]
    end

    [:verified, { delivery_id: delivery_id, action_id: line["action_id"], value: line["value"],
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
    unless OWNER_ID_RE.match?(owner.value.to_s)
      return [:refused, :unverifiable,
              "the overlay's slack#{OWNER_KEY} is not a Slack user id, so no click can be checked against it"]
    end

    slug = origin_slug(repo)
    return [:refused, :unverifiable, "cannot tell which repo #{repo} is: no parseable `origin` remote"] unless slug

    files, why = session_files(env)
    return [:refused, :unverifiable, why] unless files

    lines, clicks, scanned, unparsed = read_lines(files, did)
    where = "#{files.join(' + ')} (#{scanned} lines, #{clicks.size} clicks, #{unparsed} unparsable read)"
    judge(lines, delivery_id: did, owner_id: owner.value, head: head, slug: slug, where: where, clicks: clicks)
  rescue SystemCallError => e
    [:refused, :unverifiable, "cannot read the inbox: #{e.message}"]
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

  def repo_key(env)
    out, err, st = Open3.capture3(env, INBOX_STATUS, "--repo-key")
    return [nil, nil] if st.success? && out.strip.empty?
    return [out.strip, nil] if st.success?

    [nil, "the session's repo identity could not be told (#{INBOX_STATUS} --repo-key exit " \
          "#{st.exitstatus}: #{err.lines.first.to_s.strip})"]
  rescue SystemCallError => e
    [nil, "the session's repo identity could not be told: #{INBOX_STATUS} cannot run (#{e.message})"]
  end

  # -> [[file, ...], nil] (the generation first, then the live file), or
  # [nil, reason].
  def session_files(env)
    key, why = repo_key(env)
    return [nil, why] if why
    return [nil, "the session's project is in no git repository, so it has no session channel"] unless key

    root = inbox_root(env)
    return [nil, "the inbox root cannot be computed (ATHENA_INBOX_ROOT and HOME are unset)"] unless root

    regdir = File.join(root, "projects")
    return [nil, "the inbox registry #{regdir} does not exist"] unless File.directory?(regdir)

    entries, malformed = registry_entries(regdir, key, env)
    # A malformed entry is a hard error for the inbox reader (athena:inbox
    # descriptor_validate), so it is one here too: it might be this repo's.
    if malformed.positive?
      return [nil, "#{malformed} registry entr#{malformed == 1 ? 'y' : 'ies'} under #{regdir} cannot be read " \
                   "as JSON with a string `repo`, and one may be this repo's"]
    end
    if entries.size != 1
      return [nil, "#{entries.size} registry entries under #{regdir} claim the session's repo #{key}; " \
                   "exactly one must"]
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

  # A registry `repo` MAY be written ~/...; expand it against the HOME the
  # caller passed, never the process's own.
  def expand_repo(path, env)
    home = env["HOME"].to_s
    path = home + path[1..] if path.start_with?("~/") && home.start_with?("/")
    File.expand_path(path)
  end

  # -> [[entry, ...], malformed_count] claiming the repo key.
  def registry_entries(regdir, key, env)
    malformed = 0
    entries = Dir.glob(File.join(regdir, "*.json")).sort.filter_map do |f|
      doc = JSON.parse(File.read(f))
      unless doc.is_a?(Hash) && doc["repo"].is_a?(String)
        malformed += 1
        next nil
      end

      repo = expand_repo(doc["repo"], env)
      real = File.exist?(repo) ? File.realpath(repo) : repo
      real == key ? doc : nil
    rescue JSON::ParserError, EncodingError
      malformed += 1
      nil
    end
    [entries, malformed]
  end

  # -> [lines carrying delivery_id did, every slack.interaction line, lines
  # scanned, lines that are not a JSON object]. A line of invalid bytes is
  # counted, never fatal: one bad line must not block every approval.
  def read_lines(files, did)
    hits = []
    clicks = []
    scanned = 0
    unparsed = 0
    files.each do |f|
      File.foreach(f, mode: "rb") do |bytes|
        raw = bytes.force_encoding(Encoding::UTF_8).scrub
        next if raw.strip.empty?

        scanned += 1
        j = begin
          JSON.parse(raw)
        rescue JSON::ParserError, EncodingError
          nil
        end
        unless j.is_a?(Hash)
          unparsed += 1
          next
        end

        clicks << j if j["kind"] == "slack.interaction"
        hits << j if j["delivery_id"].is_a?(String) && j["delivery_id"].downcase == did
      end
    end
    [hits, clicks, scanned, unparsed]
  end
end
