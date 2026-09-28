# frozen_string_literal: true

# ai/lib/outbound_scan.rb -- the PURE rules of the outbound scan (DND-699).
# Contract: ai/contracts/athena-private-overlay.md -> Outbound-scan interface.
#
# Domain only: parse a patterns.tsv text, union two pattern sets, match lines,
# and render a report. No filesystem, no git, no environment. The sources
# (overlay files, git ranges, the tracked tree) are
# ai/lib/outbound_scan_sources.rb; ai/bin/outbound-scan is the manager.
#
# THE ONE RULE THIS FILE EXISTS TO KEEP: a matched literal never leaves it.
# A hit is (location, label). A location that would itself carry a literal (a
# path that matches a pattern) is redacted before it is rendered. Parse errors
# name the source and the line number, never the line's text.
#
# Deliberately gem-free (stdlib only).

module OutboundScan
  EXIT = { clean: 0, hits: 1, usage: 2, unmeasured: 3, waived: 0 }.freeze

  LABEL_RE = /\A[a-z0-9][a-z0-9_.-]{0,63}\z/.freeze
  # Per-match budget: a pathological pattern must not hang a push. A timeout
  # is COULD NOT MEASURE, never a miss. Each pattern is matched on its own:
  # a combined union regex renumbers capture groups, so a backreference in
  # one pattern would silently stop matching (a miss read as CLEAN).
  MATCH_TIMEOUT = 2.0

  Pattern = Struct.new(:label, :source, :regex, keyword_init: true)

  # A place a line came from. `path` is nil for commit messages and text
  # fields. `render` never includes the scanned text.
  Location = Struct.new(:kind, :path, :line, :commit, :field, keyword_init: true)

  Hit = Struct.new(:location, :label, keyword_init: true)

  # Raised for anything that makes the scan unable to say CLEAN honestly.
  class Unmeasurable < StandardError; end

  module_function

  # text -> [patterns]. Raises Unmeasurable naming `origin` and the line number.
  def parse_patterns(text, origin)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise Unmeasurable, "#{origin} is not valid UTF-8" unless text.valid_encoding?

    text.each_line.with_index(1).filter_map do |raw, n|
      line = raw.chomp
      next nil if line.strip.empty? || line.lstrip.start_with?("#")

      label, tab, src = line.partition("\t")
      raise Unmeasurable, "#{origin} line #{n} has no TAB between label and regex" if tab.empty?
      raise Unmeasurable, "#{origin} line #{n} has a label that is not [a-z0-9][a-z0-9_.-]*" unless LABEL_RE.match?(label)
      raise Unmeasurable, "#{origin} line #{n} has an empty regex" if src.empty?

      Pattern.new(label: label, source: src, regex: compile(src, origin, n))
    end
  end

  def compile(src, origin, n)
    Regexp.new(src, timeout: MATCH_TIMEOUT)
  rescue RegexpError
    raise Unmeasurable, "#{origin} line #{n} has a regex that does not compile"
  end

  # The union of two sets, keyed on (label, regex source). Order: a's first.
  def union(a, b)
    seen = {}
    (a + b).each_with_object([]) do |p, out|
      key = [p.label, p.source]
      next if seen[key]

      seen[key] = true
      out << p
    end
  end

  # -> array of labels matching `text` (each label once).
  def labels_matching(patterns, text)
    t = normalise(text)
    patterns.each_with_object([]) do |p, out|
      out << p.label if !out.include?(p.label) && p.regex.match?(t)
    end
  rescue Regexp::TimeoutError
    raise Unmeasurable, "a pattern exceeded the #{MATCH_TIMEOUT}s match budget"
  end

  def normalise(text)
    s = text.dup.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.scrub("?")
  end

  # -> [Hit] for one line.
  def scan_line(patterns, location, text)
    labels_matching(patterns, text).map { |l| Hit.new(location: location, label: l) }
  end

  # Render one location. A path that itself matches any pattern is never
  # printed. The decision is made HERE, against the patterns, for every path at
  # render time -- not looked up in a set built elsewhere, whose keys could
  # differ in encoding or miss a path (a modified file) that never went in.
  def render_location(loc, patterns)
    path = loc.path && !labels_matching(patterns, loc.path).empty? ? "<path redacted: it matches a pattern>" : loc.path
    sha = loc.commit && loc.commit[0, 12]
    case loc.kind
    when :content
      where = "#{path}:#{loc.line}"
      sha ? "#{where} (commit #{sha})" : where
    when :path
      sha ? "commit #{sha} path <redacted>" : "tracked path <redacted>"
    when :message
      "commit #{sha} message:#{loc.line}"
    when :field
      "#{loc.field}:#{loc.line}"
    else
      "unknown location"
    end
  end

  # The SCANNED counts line every measured run prints.
  def counts_line(counts)
    "SCANNED commits=#{counts[:commits].to_i} lines=#{counts[:lines].to_i} " \
      "patterns=#{counts[:patterns].to_i} hits=#{counts[:hits].to_i}"
  end

  HIT_FIX = "Fix: move each value to the private overlay and read it with `ai/bin/private-overlay get <file> <.key.path>` " \
            "(ai/contracts/athena-private-overlay.md -> Consumer obligation); for a commit message, reword that " \
            "commit (git commit --amend for the tip) and push again. Never print or paste the matched text to find it: the labels and locations are enough."

  def unmeasured_fix(reason)
    "Fix: #{reason_fix(reason)} Until then this scan cannot call anything clean."
  end

  def reason_fix(reason)
    case reason
    when /overlay is ABSENT/
      "this machine has no private overlay, so there is no pattern list; the owner creates it " \
        "(ai/contracts/athena-private-overlay.md -> Discovery)."
    when /overlay is MALFORMED/
      "correct the overlay problem named above (`ai/bin/private-overlay status` shows it)."
    when /not a git repository|has no commits|not committed|no committed/
      "commit outbound/patterns.tsv in the overlay's local git history (the committed copy is the floor)."
    when /zero patterns/
      "add at least one `label<TAB>regex` line to outbound/patterns.tsv in the overlay and commit it."
    else
      "correct the problem named above and re-run."
    end
  end
end
