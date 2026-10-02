# frozen_string_literal: true

# epic_clustering_view -- the presentation of athena:epic-clustering (DND-982):
# proof lines, the digest's text and Block Kit, and one won't-fix notice as
# Block Kit. The UI bucket: it formats what the rules in
# epic_clustering.rb decided, and holds no rule of its own beyond the shape of
# a message.
#
# Everything interpolated into Slack mrkdwn from ticket data or caller text is
# escaped (&, <, >), so a title holding "<!channel>" cannot ping a channel.
require_relative "epic_clustering"

module EpicClusteringView
  DataError = EpicClustering::DataError
  NEXT_N = EpicClustering::NEXT_N
  UNREAD_SHOWN = EpicClustering::UNREAD_SHOWN
  SECTION_TEXT_MAX = 3000

  module_function

  # Slack mrkdwn control characters in data.
  def esc(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  def proof_lines(snapshot)
    snapshot.map do |id, s|
      list = s["count"].zero? ? "0 (none)" : "#{s['count']}: #{s['ids'].join(', ')}"
      "never-movable #{s['name']} (#{id}): #{list}"
    end
  end


  def fmt_counts(counts)
    counts.sort_by { |k, _| NextMission::KIND_ORDER.index(k) || 99 }.map do |kind, sev|
      "#{kind} " + sev.sort_by { |s, _| NextMission::SEVERITIES.index(s) || 9 }.map { |s, n| "#{s}:#{n}" }.join(" ")
    end.join("; ")
  end

  def digest_sections(d)
    s = {}
    s["Tier-4 queue (by project and Area)"] =
      if d[:tier4_queue].empty? then ["none"]
      else d[:tier4_queue].map { |g| "#{g[:project]} / #{g[:area]}: #{g[:count]} (#{fmt_counts(g[:counts])})" }
      end
    off = Array(d[:features_off_path])
    s["Tier-4 queue (by project and Area)"] << "Features with no Path=Critical (not queued here; a planning gap): " \
                                               "#{off.empty? ? 'none' : "#{off.size}: #{off.join(', ')}"}"
    s["Next #{NEXT_N} in work order (next-mission tier-4 order)"] =
      if d[:next].empty? then ["none ready"]
      else d[:next].each_with_index.map { |x, i| "#{i + 1}. #{x[:id]} #{x[:severity] || '-'} #{x[:kind]}: #{x[:title]}" }
      end
    s["Why tier 4 is or isn't moving"] = moving_lines(d[:moving])
    s["Won't-fix candidates"] =
      d[:wont_fix].empty? ? ["None today"] : d[:wont_fix].map { |x| "#{x[:id]} #{x[:title]}: #{x[:reason]}" }
    s["Pass summary"] = pass_lines(d[:pass_summary])
    s["Status hygiene"] = status_lines(d[:status])
    s["Ticket hygiene (N1)"] = hygiene_lines(d[:hygiene])
    s
  end

  def moving_lines(m)
    c = m[:tier_counts]
    lines = ["Open tier 1: #{c[1]}, tier 2: #{c[2]}, tier 3: #{c[3]}."]
    lines << "Started: #{m[:started].empty? ? 'none' : m[:started].join(', ')}."
    lines << "Blocked on a dependency: #{m[:blocked].empty? ? 'none' : m[:blocked].join(', ')}."
    lines << if m[:owner_gated].empty?
               "Owner-gated (Needs Attention): none."
             else
               "Owner-gated (Needs Attention): " + m[:owner_gated].map { |x| "#{x[:id]} (tier #{x[:tier]}) #{x[:title]}" }.join("; ") + "."
             end
    if m[:held_by_functional_first].empty?
      lines << "Functional-first holds: none."
    else
      m[:held_by_functional_first].each do |h|
        lines << "Functional-first: #{h[:held]} tier-4 held in #{h[:epic]} until #{h[:unfinished].join(', ')} land."
      end
    end
    lines
  end

  def pass_lines(p)
    return ["not given (no --pass-summary; this digest ran without a pass)"] if p.nil?

    moved = Array(p["moved"]).map { |m| "#{m['id']} #{m['from']} -> #{m['to']}" }
    merged = Array(p["merged"]).map { |m| "#{m['duplicate']} into #{m['keep']}" }
    closed = Array(p["closed"]).map { |m| "#{m['id']} (#{m['evidence']})" }
    wont = Array(p["wont_fix"]).map { |m| "#{m['id']} (#{m['reason']})" }
    ["Moved: #{moved.empty? ? 'none' : moved.join('; ')}",
     "Merged (C3): #{merged.empty? ? 'none' : merged.join('; ')}",
     "Closed as fixed (C4): #{closed.empty? ? 'none' : closed.join('; ')}",
     "Closed as Won't Fix (veto by its notice): #{wont.empty? ? 'none' : wont.join('; ')}"]
  end

  def status_lines(s)
    return ["stale In Progress check not run"] if s.nil?
    return ["stale In Progress check skipped: #{s[:skipped]}"] if s[:stale].nil?

    stray = Array(s[:started_not_open])
    note = stray.empty? ? [] : ["note: --started id(s) naming no open ticket (typo?): #{stray.join(', ')}"]
    return ["stale In Progress: none of #{s[:checked]} (source: --started)"] + note if s[:stale].empty?

    ["stale In Progress (no live captain per --started): #{s[:stale].size} of #{s[:checked]}"] +
      s[:stale].map { |x| "#{x[:id]} #{x[:title]}" } + ["Fix per ticket-management: #{s[:stale].first[:fix]}"] + note
  end

  def hygiene_lines(h)
    return ["ticket bodies not scanned"] if h.nil?

    head = "scanned #{h[:scanned]} bodies, flagged #{h[:flagged].size}"
    unless h[:unread].empty?
      shown = h[:unread].first(UNREAD_SHOWN)
      more = h[:unread].size - shown.size
      head += "; #{h[:unread].size} UNREAD (not judged): #{shown.join(', ')}#{more.positive? ? " and #{more} more" : ''}"
      why = h[:unread_reasons].to_h
      head += " [#{why.map { |k, n| "#{n}x #{k}" }.join('; ')}]" unless why.empty?
    end
    [head] + h[:flagged].map { |x| "#{x[:id]} (#{x[:kind]}) lacks #{x[:missing].join(', ')}" }
  end

  def digest_text(d)
    out = ["Daily digest #{d[:now]}"]
    digest_sections(d).each do |title, lines|
      if title == "Won't-fix candidates" && lines == ["None today"]
        out << "Won't-fix candidates: None today"
        next
      end
      out << "" << "#{title}:"
      out.concat(lines.map { |l| "  #{l}" })
    end
    out.join("\n")
  end

  SECTION_MAX = 2900

  # Informational Block Kit: header line naming the sending session, one
  # section per part. No buttons (nothing is asked; a won't-fix notice is separate).
  def digest_blocks(d, session:)
    blocks = [section("*#{esc(session)}:*\nDaily ticket digest, #{esc(d[:now])}. Tier 4 is worked after tiers 1-3.")]
    digest_sections(d).each do |title, lines|
      blocks << section(clip("*#{title}*\n" + lines.map { |l| "• #{esc(l)}" }.join("\n")))
    end
    raise DataError, "digest renders #{blocks.size} blocks; Slack allows 50" if blocks.size > 50

    blocks
  end

  def section(text) = { "type" => "section", "text" => { "type" => "mrkdwn", "text" => text } }

  def clip(text)
    return text if text.length <= SECTION_MAX

    kept = text[0, SECTION_MAX - 40].rpartition("\n").first
    "#{kept}\n• … #{text.count("\n") - kept.count("\n")} more lines in the run log"
  end

  # ---------------------------------------------------------------- notice

  # A won't-fix needs no approval (~/.claude/CLAUDE.md -> Owner approval
  # policy). The notice reports a close already made and offers the owner a
  # veto; its buttons are athena:ticket-management -> Promote and won't-fix.
  NOTICE_BUTTONS = [
    ["Keep closed (recommended)", "keep", true],
    ["Reopen", "reopen", false]
  ].freeze

  # veto_by_hand: the poster cannot verify a click (the clustering cron's
  # headless session exits after the pass, DND-1749), so the notice offers no
  # buttons and says how to veto: reopen the ticket in Notion.
  # veto_by_grant: the poster got a ticket.wontfix_veto grant (DND-1758). The
  # server posted its own approval message, whose Reopen button the server
  # acts on, so this notice has no buttons and points at that message.
  def wont_fix_notice(ticket:, title:, background:, why:, session:, veto_by_hand: false, veto_by_grant: false)
    { "background" => background, "why" => why, "title" => title }.each do |k, v|
      raise DataError, "#{k} is empty; a won't-fix notice needs background, why and title" if v.to_s.strip.empty?
    end
    raise DataError, "ticket #{ticket.inspect} is not an id like DND-12" unless ticket.to_s.match?(NextMission::ID_RE)
    raise DataError, "a notice has one veto form: by hand or by grant, not both" if veto_by_hand && veto_by_grant

    reopen = notice_reopen(ticket, veto_by_hand: veto_by_hand, veto_by_grant: veto_by_grant)
    body = [
      "*#{esc(session)}:*\n*Closed #{ticket} as Won't Fix.*\n#{ticket}: #{esc(title)}",
      "*Background*\n#{esc(background)}",
      "*Why it matters*\n#{esc(why)}",
      "*Options*\n• Keep closed: nothing changes.\n#{reopen}",
      "*Recommendation*\nKeep closed. Silence keeps it closed."
    ]
    long = body.find { |t| t.length > SECTION_TEXT_MAX }
    raise DataError, "a notice section is #{long.length} characters; Slack allows #{SECTION_TEXT_MAX}" if long

    head = "#{esc(session)}: Closed #{ticket} #{esc(title)} as Won't Fix."
    if veto_by_hand
      return { text: "#{head} To veto, reopen it in Notion; silence keeps it closed.",
               blocks: body.map { |t| section(t) } }
    end
    if veto_by_grant
      return { text: "#{head} To veto, press Reopen on its approval message; silence keeps it closed.",
               blocks: body.map { |t| section(t) } }
    end

    buttons = NOTICE_BUTTONS.map do |label, choice, primary|
      b = { "type" => "button", "text" => { "type" => "plain_text", "text" => label },
            "value" => "wontfix:#{choice}:#{ticket}", "action_id" => "wontfix_#{choice}" }
      b["style"] = "primary" if primary
      b
    end
    { text: "#{head} Reopen to veto; silence keeps it closed.",
      blocks: body.map { |t| section(t) } + [{ "type" => "actions", "elements" => buttons }] }
  end

  def notice_reopen(ticket, veto_by_hand:, veto_by_grant:)
    if veto_by_hand
      "• Reopen: set #{ticket} back to Todo, or Parked if work exists, in Notion. " \
        "This notice has no buttons: the session that posted it has ended, so no click could be verified."
    elsif veto_by_grant
      "• Reopen: press Reopen on the approval message Athena sent for #{ticket}. The server sets it back " \
        "to Todo, or Parked if work exists, and says so on that message."
    else
      "• Reopen: Status goes back to Todo, or Parked if work exists."
    end
  end
end
