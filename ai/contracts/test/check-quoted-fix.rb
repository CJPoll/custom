#!/usr/bin/env ruby
# frozen_string_literal: true

# check-quoted-fix.rb — assert the refusal text a contract quotes, section by
# section, is exactly the text a fixture pins (DND-411).
#
# A contract quote that drifts from the shipped text fails silently: prose that
# names text no code emits passes every other check. The fixture is the pinned
# copy; the gen_saas tests named in the fixture's header pin the code to it.
#
# Fixture format: `@section <heading text>` starts a section; each following
# non-blank, non-`#` line is one pinned span. In each listed section, every
# inline-code span that contains `Fix:` (and is more than the bare word) must
# equal the pinned lines, in order, whitespace collapsed. Fenced code blocks are
# skipped.
#
# Usage:
#   check-quoted-fix.rb --contract FILE --fixture FILE
#
# Exit codes (kept distinct: "could not look" must never read as "matched"):
#   0  every listed section's quoted spans equal the fixture
#   1  a section's quotes and the fixture differ (each difference is printed)
#   2  the check could not measure: missing file, a section heading not found,
#      a section with zero quoted spans, or a fixture with no sections/lines
#
# Deliberately gem-free (stdlib only).

USAGE = <<~TXT
  Usage: check-quoted-fix.rb --contract FILE --fixture FILE
  Compares the `...Fix:...` spans quoted in each fixture-listed contract section
  to the fixture's pinned lines.
TXT

def cannot_measure(msg, fix)
  warn "check-quoted-fix: CANNOT MEASURE — #{msg}"
  warn "Fix: #{fix}"
  exit 2
end

def parse_args(argv)
  if argv.include?("--help") || argv.include?("-h")
    puts USAGE
    exit 0
  end

  args = argv.dup
  opts = {}
  while (flag = args.shift)
    unless %w[--contract --fixture].include?(flag)
      cannot_measure("unknown argument #{flag.inspect}", "pass only --contract and --fixture")
    end
    opts[flag.delete_prefix("--").to_sym] = args.shift
  end
  %i[contract fixture].each do |key|
    cannot_measure("--#{key} is required", "pass --#{key} FILE") if opts[key].to_s.empty?
    unless File.file?(opts[key])
      cannot_measure("no such file #{opts[key]}", "point --#{key} at the real file")
    end
  end
  opts
end

# [[heading, [pinned lines]], ...] in fixture order.
def parse_fixture(path)
  sections = []
  File.readlines(path, chomp: true).each do |line|
    next if line.strip.empty? || line.start_with?("#")

    if line.start_with?("@section ")
      sections << [line.delete_prefix("@section ").strip, []]
    elsif sections.empty?
      cannot_measure("#{path}: a pinned line precedes any @section", "add an `@section <heading>` line above it")
    else
      sections.last[1] << line
    end
  end
  cannot_measure("fixture #{path} lists no @section", "restore the fixture's @section lines") if sections.empty?
  sections.each do |heading, pinned|
    next unless pinned.empty?

    cannot_measure("fixture section #{heading.inspect} pins no span", "add its pinned lines, or drop the @section")
  end
  sections
end

# The body of the section whose heading text is `heading`, or nil.
def section_body(lines, heading)
  start = lines.index { |l| l =~ /\A(#+)\s+(.*?)\s*\z/ && Regexp.last_match(2) == heading }
  return nil if start.nil?

  level = lines[start][/\A#+/].length
  stop = ((start + 1)...lines.length).find do |i|
    lines[i] == "---" || (lines[i] =~ /\A(#+)\s/ && Regexp.last_match(1).length <= level)
  end
  lines[(start + 1)...(stop || lines.length)]
end

# Inline-code spans containing `Fix:` (not the bare word), whitespace collapsed.
def quoted_spans(body_lines)
  in_fence = false
  prose = body_lines.reject do |l|
    in_fence = !in_fence if l.lstrip.start_with?("```")
    in_fence || l.lstrip.start_with?("```")
  end
  parts = prose.join("\n").split("`", -1)
  parts.each_with_index
       .select { |_, i| i.odd? }
       .map { |s, _| s.gsub(/\s+/, " ").strip }
       .select { |s| s.include?("Fix:") && s != "Fix:" }
end

opts = parse_args(ARGV)
lines = File.readlines(opts[:contract], chomp: true)
drift = false

parse_fixture(opts[:fixture]).each do |heading, pinned|
  body = section_body(lines, heading)
  if body.nil?
    cannot_measure(
      "section heading #{heading.inspect} not found in #{opts[:contract]}",
      "the heading was renamed or removed; update its @section line in #{opts[:fixture]}"
    )
  end

  quoted = quoted_spans(body)
  if quoted.empty?
    cannot_measure(
      "section #{heading.inspect} quotes no span containing Fix:",
      "the quotes moved out of this section; move the @section to where they now live"
    )
  end

  if quoted == pinned
    puts "check-quoted-fix: OK — #{heading.inspect}: #{quoted.length} quoted span(s) match"
    next
  end

  drift = true
  puts "check-quoted-fix: DRIFT — #{heading.inspect} quotes #{quoted.length} span(s); " \
       "the fixture pins #{pinned.length}."
  [quoted.length, pinned.length].max.times do |i|
    next if quoted[i] == pinned[i]

    puts "  span #{i + 1}:"
    puts "    contract: #{quoted[i] || '(none)'}"
    puts "    fixture:  #{pinned[i] || '(none)'}"
  end
end

exit 0 unless drift

puts "Fix: decide which side is the design. If the shipped text changed, update the " \
     "contract quote AND #{opts[:fixture]} together (and the gen_saas test named in its " \
     "header); if the contract is right, fix the code, not the fixture."
exit 1
