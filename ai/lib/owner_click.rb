# frozen_string_literal: true

require "digest"
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
#      different head, which only check 6 can clear. For the exact head, the
#      PR number is as the button states it: only the repo and the head are
#      checked.
#   5. No later owner click on the same message chose otherwise. A hold or
#      reject after the approve is the owner's last word, and it wins. A
#      rival click that cannot be ordered refuses. The check is per
#      message: a hold on a different DM does not reverse this one.
#   6. The carry (DND-1832). The owner approved this rule by click, relayed
#      by the laptop and the coordinator on 2026-10-03. A click that passes
#      1-5 for head A of PR X also clears a later head B when ALL of these
#      hold, and it is refused otherwise:
#      - A's objects are in --repo. If they are not, that is COULD NOT LOOK
#        with a fetch Fix:, never a mismatch and never a pass.
#      - The PR's own diff is byte-identical at both heads. That diff is
#        `git diff --binary <merge-base(base, head)> <head>`, where base is
#        the gate's target (origin/main). The gate computes both diffs from
#        git objects and never takes a session's word that they match. A
#        rebase and a merge of main both keep it identical. A one-byte
#        difference refuses, naming both merge-bases and both heads, with a
#        Fix: asking for a new click on head B.
#      - origin's PR head ref for X (`refs/pull/X/head` on GitHub,
#        `refs/merge-requests/X/head` on GitLab) is B, read with `git
#        ls-remote`. A different PR never matches. A ref that is missing or
#        cannot be read is COULD NOT LOOK.
#      - No owner click after the approve, on any message, names X and is
#        not an exit-4 approve. Such a click is a later hold, and it wins.
#        A later click on the same message is check 5.
#      The blast-radius classification still runs on B's own diff.
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
#   - The carry reads origin's PR head ref over git's own transport. The same
#     user can redirect that transport (GIT_SSH_COMMAND, url.*.insteadOf) to
#     a forge it controls, as it can forge the inbox line itself. The diff
#     equality does not depend on origin: it is read from local objects.
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
        "project, a click on another message, a click for another PR, a click for an " \
        "earlier head whose PR diff (git diff --binary <merge-base> <head>) is not " \
        "byte-identical to this head's, and an approve the owner later reversed or held " \
        "never count. A click that rotated out of the inbox needs a " \
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
  # -> [:verified, info] | [:carry, info] (every check but the head passed;
  # check 6 decides) | [:refused, kind, reason]. kind is one of :not_found,
  # :relayed, :not_owner, :other_message, :superseded, :unverifiable.
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

    info = { delivery_id: delivery_id, action_id: line["action_id"], value: line["value"],
             slug: ask[:slug], pr: ask[:pr], sha: ask[:sha], where: where, at: at }
    # Another head: only the carry (check 6) can clear it, and the caller
    # gathers its facts from git.
    return [:carry, info] unless ask[:sha] == head

    [:verified, info]
  end

  # A click's value names PR <slug>#<pr>: the slug (case-insensitive) is not
  # the tail of a longer path, and the number is not the head of a longer one.
  def names_pr?(value, slug, pr)
    return false unless value.is_a?(String)

    Regexp.new("(?<![A-Za-z0-9_./-])#{Regexp.escape(slug)}##{Integer(pr)}(?![0-9])", Regexp::IGNORECASE)
          .match?(value)
  end

  # PURE. A later owner click, on any message, that names the approved PR and
  # is not an exit-4 approve: a hold, and the owner's last word on that PR.
  # -> nil, or [:refused, kind, reason].
  def later_hold(info, clicks, owner_id)
    named = clicks.select do |c|
      owner_click?(c, owner_id) && c["delivery_id"] != info[:delivery_id] &&
        parse_ask_value(c["value"]).nil? && names_pr?(c["value"], info[:slug], info[:pr])
    end
    undated = named.find { |c| action_time(c["action_ts"]).nil? }
    if undated
      return [:refused, :unverifiable,
              "an owner click naming #{info[:slug]}##{info[:pr]} (#{undated['action_id'].inspect}) has an " \
              "action_ts that cannot be ordered, so whether it held the PR after click #{info[:delivery_id]} " \
              "could not be told"]
    end
    later = named.find { |c| (action_time(c["action_ts"]) <=> info[:at]) == 1 }
    return nil unless later

    [:refused, :superseded,
     "the owner clicked #{later['action_id'].inspect} (#{later['value'].to_s[0, 120].inspect}), naming " \
     "#{info[:slug]}##{info[:pr]}, after click #{info[:delivery_id]}: that later hold is the owner's decision, " \
     "so the approve of #{info[:sha]} does not carry"]
  end

  def new_click_fix(info, head)
    "ask the owner for a new click on head B: post the decision DM (athena:slack -> \"Asking the owner for " \
      "a decision\") with an approve button whose value is '#{ask_value(info[:slug], info[:pr], head)}', that " \
      "string also in the visible text, then pass the delivered line's id: --owner-approval " \
      "'click:<delivery_id>'. A click carries to a later head only while the PR's own diff is " \
      "byte-identical and origin's PR head ref is that head (DND-1832)."
  end

  # PURE. Judge the carry's local facts: A present, both merge-bases, both
  # diffs. facts: {present: bool, error: String|nil, mb_from:, mb_to:,
  # diff_from: bytes, diff_to: bytes}. -> nil (identical) or a refusal with
  # its own Fix as the 4th element.
  def judge_carry_diff(info, head, base, facts, repo: ".")
    a = info[:sha]
    unless facts[:present]
      return [:refused, :unverifiable,
              "head A #{a}, which click #{info[:delivery_id]} approves, is not in this repository's objects, so " \
              "the PR's own diff at A could not look and nothing about head B #{head} is decided",
              "fetch head A into #{repo} (`git fetch origin #{a}` there), then re-run. If origin no longer has it, " \
              "#{new_click_fix(info, head)}"]
    end
    if facts[:error]
      return [:refused, :unverifiable,
              "the PR's own diffs could not look: #{facts[:error]}", new_click_fix(info, head)]
    end
    return nil if facts[:diff_from] == facts[:diff_to]

    [:refused, :diff_changed,
     "click #{info[:delivery_id]} approves #{info[:slug]}##{info[:pr]} at head A #{a}, not the head being gated, " \
     "B #{head}. The PR's own diff differs: `git diff --binary #{facts[:mb_from]} #{a}` (merge-base of A with " \
     "base #{base}; #{facts[:diff_from].bytesize} bytes, sha256 #{digest(facts[:diff_from])}) against `git diff " \
     "--binary #{facts[:mb_to]} #{head}` (merge-base of B; #{facts[:diff_to].bytesize} bytes, sha256 " \
     "#{digest(facts[:diff_to])}). A click carries only to a byte-identical change",
     new_click_fix(info, head)]
  end

  # PURE. Judge origin's PR head ref for the approved PR against head B.
  # refs: {state: :found, shas: {ref => sha}} | {state: :none} |
  # {state: :error, detail: String}. -> nil (B is the PR's head) or a refusal.
  def judge_pr_ref(info, head, refs, repo: ".")
    pr = info[:pr]
    names = pr_refs(pr).join(" ")
    case refs[:state]
    when :error
      [:refused, :unverifiable,
       "origin's head ref for PR ##{pr} could not look: `git ls-remote origin #{names}` failed (#{refs[:detail]})",
       "make origin readable from this checkout (`git -C #{repo} ls-remote origin #{names}` must succeed), then " \
       "re-run. Or #{new_click_fix(info, head)}"]
    when :none
      [:refused, :unverifiable,
       "origin's head ref for PR ##{pr} could not look: origin has none of #{names}, so whether head B #{head} " \
       "is PR ##{pr}'s head cannot be told",
       "check PR ##{pr} is open on origin and head B is pushed to it, then re-run integration-gate without " \
       "--rebase. Or #{new_click_fix(info, head)}"]
    else
      other = refs[:shas].reject { |_, sha| sha == head }
      return nil if other.empty?

      [:refused, :other_pr,
       "click #{info[:delivery_id]} approves #{info[:slug]}##{pr}, and origin's head for PR ##{pr} is " \
       "#{other.map { |ref, sha| "#{sha} (#{ref})" }.join(', ')}, not head B #{head}: B is not that PR's head, " \
       "and a click never carries to another PR",
       "if B belongs to PR ##{pr}, push it there and re-run integration-gate without --rebase. Otherwise " \
       "#{new_click_fix(info, head)}"]
    end
  end

  def pr_refs(pr)
    ["refs/pull/#{pr}/head", "refs/merge-requests/#{pr}/head"]
  end

  def digest(bytes)
    Digest::SHA256.hexdigest(bytes.to_s)
  end

  # EFFECTS. -> [:verified, info] | [:refused, kind, reason] |
  # [:refused, kind, reason, fix] (a refusal with its own Fix:). `base` is the
  # gate's target (origin/main); without it no click carries to another head.
  def check(record, head:, repo:, base: nil, env: ENV)
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
    verdict = judge(lines, delivery_id: did, owner_id: owner.value, head: head, slug: slug, where: where,
                    clicks: clicks)
    return verdict unless verdict.first == :carry

    carry(verdict[1], head: head, base: base, repo: repo, clicks: clicks, owner_id: owner.value)
  rescue SystemCallError => e
    [:refused, :unverifiable, "cannot read the inbox: #{e.message}"]
  end

  # EFFECTS. Check 6: decide whether a click for head A clears head B.
  # Local facts first, so a changed diff never reaches the network.
  def carry(info, head:, base:, repo:, clicks:, owner_id:)
    unless base
      return [:refused, :other_head,
              "click #{info[:delivery_id]} approves #{info[:slug]}##{info[:pr]} at head #{info[:sha]}, not the head " \
              "being gated (#{head}), and no base was given to compare the PR's own diffs against",
              new_click_fix(info, head)]
    end

    facts = carry_facts(repo, base, info[:sha], head)
    refusal = judge_carry_diff(info, head, base, facts, repo: repo)
    return refusal if refusal

    refusal = later_hold(info, clicks, owner_id)
    return refusal if refusal

    refs = origin_pr_head(repo, info[:pr])
    refusal = judge_pr_ref(info, head, refs, repo: repo)
    return refusal if refusal

    [:verified, info.merge(carried_to: head, mb_from: facts[:mb_from], mb_to: facts[:mb_to],
                           diff_sha256: digest(facts[:diff_to]), pr_ref: refs[:shas].keys.join(", "))]
  end

  # EFFECTS. -> {present:, error:, mb_from:, mb_to:, diff_from:, diff_to:}.
  def carry_facts(repo, base, from, to)
    _, _, st = Open3.capture3("git", "-C", repo, "cat-file", "-e", "#{from}^{commit}")
    return { present: false } unless st.success?

    mb_from, d_from, why = pr_diff(repo, base, from)
    return { present: true, error: why } if why

    mb_to, d_to, why = pr_diff(repo, base, to)
    return { present: true, error: why } if why

    { present: true, error: nil, mb_from: mb_from, mb_to: mb_to, diff_from: d_from, diff_to: d_to }
  end

  # The PR's own diff at `head`: `git diff --binary <merge-base(base, head)>
  # <head>`. The flags pin what config could vary (an external diff driver,
  # textconv, color, rename detection, a relative diff), so the bytes depend
  # on git objects alone. -> [merge_base, bytes, nil] or [nil, nil, why].
  def pr_diff(repo, base, head)
    out, err, st = Open3.capture3("git", "-C", repo, "merge-base", base, head)
    mb = out.strip
    unless st.success? && /\A[0-9a-f]{40}\z/.match?(mb)
      return [nil, nil, "`git merge-base #{base} #{head}` found no merge-base (exit #{st.exitstatus}: " \
                        "#{err.lines.first.to_s.strip})"]
    end

    out, err, st = Open3.capture3("git", "-C", repo, "diff", "--binary", "--no-ext-diff", "--no-textconv",
                                  "--no-color", "--no-renames", "--no-relative", mb, head, binmode: true)
    return [nil, nil, "`git diff --binary #{mb} #{head}` failed (exit #{st.exitstatus}: #{err.lines.first.to_s.strip})"] unless st.success?

    [mb, out, nil]
  end

  # EFFECTS. origin's head ref for PR `pr`, read with `git ls-remote`.
  # -> {state: :found, shas: {ref => sha}} | {state: :none} |
  # {state: :error, detail:}.
  def origin_pr_head(repo, pr)
    out, err, st = Open3.capture3({ "GIT_TERMINAL_PROMPT" => "0" }, "timeout", "120", "git", "-C", repo,
                                  "ls-remote", "origin", *pr_refs(pr))
    unless st.success?
      return { state: :error, detail: "exit #{st.exitstatus}: #{err.lines.first.to_s.strip}" }
    end

    shas = out.lines.filter_map do |l|
      sha, ref = l.strip.split("\t", 2)
      [ref, sha] if ref && /\A[0-9a-f]{40}\z/.match?(sha.to_s) && pr_refs(pr).include?(ref)
    end.to_h
    shas.empty? ? { state: :none } : { state: :found, shas: shas }
  rescue SystemCallError => e
    { state: :error, detail: "cannot run git ls-remote: #{e.message}" }
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
