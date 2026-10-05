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

  OID_RE = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/.freeze
  ZERO_OID_RE = /\A0+\z/.freeze

  # A destination's ref advertisement (`git ls-remote` output, or the
  # transport's "<oid> <ref>" listing) -> its tip object ids (unique, in
  # order). The separator is a TAB or a space; a peeled tag line
  # ("<oid> refs/tags/x^{}") is a tip like any other, and a zero id (an
  # empty repository's "capabilities^{}" placeholder) is none. Raises
  # Unmeasurable on any other line: a listing that cannot be read is never
  # an empty destination (DND-2086).
  def parse_advertisement(text, origin)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise Unmeasurable, "#{origin} is not valid UTF-8 (COULD NOT LOOK)" unless text.valid_encoding?

    text.each_line.with_index(1).each_with_object([]) do |(raw, n), oids|
      next if raw.strip.empty?

      oid, ref = raw.chomp.split(/[\t ]/, 2)
      unless OID_RE.match?(oid.to_s) && ref && !ref.strip.empty?
        raise Unmeasurable, "#{origin} line #{n} is not '<oid> <ref>' (COULD NOT LOOK)"
      end
      next if ZERO_OID_RE.match?(oid) || oids.include?(oid)

      oids << oid
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

  def look_fix(reason)
    case reason
    when /insteadOf/
      "git ls-remote would read another URL than the one pushed to: push to the URL your insteadOf rules " \
        "produce (`git ls-remote --get-url <url>`), or drop the rule that rewrites it again, then push again."
    when /transport does not scan/
      "this route push has no transport scan to leave it to: install the outbound hook in the main checkout " \
        "(scripts/setup-private-overlay --install) or push through ~/dev/custom/ai/bin/gh-athena / glab-athena, then push again."
    when /ls-remote/
      "`git ls-remote <url>` could not list it: check that the push URL is reachable and readable with your " \
        "credentials, then push again."
    else
      "the listing the route's transport handed the scan was missing or malformed: push again through " \
        "~/dev/custom/ai/bin/gh-athena git / glab-athena git, and report it if it recurs."
    end
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
    when /COULD NOT LOOK/
      "a new ref's range is everything the destination does not already have, read from the destination's " \
        "own ref listing, and #{look_fix(reason)}"
    when /zero patterns/
      "add at least one `label<TAB>regex` line to outbound/patterns.tsv in the overlay and commit it."
    else
      "correct the problem named above and re-run."
    end
  end
end
