# frozen_string_literal: true

# lead_time_trailer -- the `Lead-time-experiment:` commit trailer (DND-1529).
# DOMAIN: pure; no file, process or clock access.
#
# Every lead-time improver change and revert lands with
#
#   Lead-time-experiment: <measured repo> <phase> <metric>
#
# so any machine can see, from the commit history alone, which phase a
# commit was meant to move. experiments.jsonl is machine-local; the trailer
# is what makes another machine's change on the same phase visible to
# `experiment judge` (a confound), and what `experiment record` requires.
#
# Parsing here is shape only: a repo name, a phase-shaped token and a
# non-empty metric (the rest of the line; a check:<label> metric may hold
# spaces). Whether the phase and metric are ones the experiment tool knows is
# the caller's rule (athena:lead-time-improve's lib/experiment.rb).
#
# Consumers: athena:lead-time-improve's scripts/experiment (record, judge)
# and ai/lib/leadtime_product_io.rb (the product-repo PR body, DND-1540).

require_relative "lead_time_config"

module LeadTimeTrailer
  KEY = "Lead-time-experiment"
  FORMAT = "#{KEY}: <measured repo> <phase> <metric>".freeze
  # Case-insensitive, like git's own trailer keys. Anywhere in the message:
  # a trailer line misplaced above the last paragraph still names a phase,
  # and judge would rather see it than miss a confound.
  LINE_RE = /^#{Regexp.escape(KEY)}:[ \t]*(.*?)[ \t]*$/i.freeze
  PHASE_RE = /\A[a-z][a-z0-9-]{0,31}\z/.freeze

  Trailer = Struct.new(:repo, :phase, :metric, keyword_init: true) do
    def to_s = "#{repo} #{phase} #{metric}"
    def to_h = { "repo" => repo, "phase" => phase, "metric" => metric }
  end

  class Error < StandardError
    attr_reader :fix

    def initialize(what, fix)
      super(what)
      @fix = fix
    end
  end

  module_function

  # The trailer line for a measured repo, phase and metric. Raises Error
  # when a part would not parse back (an empty phase, a repo that is not a
  # name), so a PR body or commit never carries a trailer judge cannot read.
  def line(repo, phase, metric)
    empty = { "repo" => repo, "phase" => phase, "metric" => metric }.select { |_, v| v.to_s.strip.empty? }.keys
    t, why = empty.empty? ? parse("#{repo} #{phase} #{metric}") : [nil, "no #{empty.join(', no ')}"]
    # A spaced repo or phase shifts the other parts: it must parse back
    # exactly as given.
    if t && t.to_h != { "repo" => repo, "phase" => phase, "metric" => metric }
      t = nil
      why = "#{[repo, phase, metric].inspect} does not parse back as repo, phase and metric"
    end
    raise Error.new("cannot build a #{KEY} trailer: #{why}", "pass the measured repo, the phase and the metric (#{FORMAT})") unless t

    "#{KEY}: #{t}"
  end

  # -> [Trailer, nil] or [nil, why]
  def parse(value)
    v = value.to_s.strip
    return [nil, "a control character in #{v.inspect}"] if v.match?(/[[:cntrl:]]/)

    repo, phase, metric = v.split(/[ \t]+/, 3)
    return [nil, "no measured repo"] if repo.nil?
    return [nil, "repo #{repo.inspect} is not a repo name"] unless LeadTimeConfig::NAME_RE.match?(repo)
    return [nil, "no phase after #{repo}"] if phase.nil?
    return [nil, "phase #{phase.inspect} is not a phase name"] unless PHASE_RE.match?(phase)
    return [nil, "no metric after #{repo} #{phase}"] if metric.nil? || metric.empty?

    [Trailer.new(repo: repo, phase: phase, metric: metric), nil]
  end

  # Every trailer line in a commit message: {trailers: [Trailer], malformed: [[value, why]]}.
  def scan(message)
    out = { trailers: [], malformed: [] }
    message.to_s.each_line do |l|
      m = LINE_RE.match(l.chomp) or next
      t, why = parse(m[1])
      t ? out[:trailers] << t : out[:malformed] << [m[1], why]
    end
    out
  end
end
