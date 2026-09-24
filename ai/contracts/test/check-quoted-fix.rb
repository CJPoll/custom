#!/usr/bin/env ruby
# frozen_string_literal: true

# check-quoted-fix.rb — assert the `Fix:` clauses a contract section quotes are
# exactly the clauses a fixture pins (DND-411).
#
# A contract quote that drifts from the shipped text fails silently: prose that
# names text no code emits passes every other check. The fixture is the pinned
# copy; the gen_saas test named in the fixture's header pins the code to it.
#
# Usage:
#   check-quoted-fix.rb --contract FILE --fixture FILE --section "HEADING TEXT"
#
# Exit codes (kept distinct: "could not look" must never read as "matched"):
#   0  every quoted clause equals the fixture, in order
#   1  the quotes and the fixture differ (each difference is printed)
#   2  the check could not measure: missing file, section not found, or zero
#      quoted clauses / zero fixture lines
#
# Deliberately gem-free (stdlib only).

def usage
  <<~TXT
    Usage: check-quoted-fix.rb --contract FILE --fixture FILE --section "HEADING TEXT"
    Compares the `Fix: ...` spans quoted in one contract section to a fixture.
  TXT
end

def cannot_measure(msg, fix)
  warn "check-quoted-fix: CANNOT MEASURE — #{msg}"
  warn "Fix: #{fix}"
  exit 2
end

args = ARGV.dup
if args.include?("--help") || args.include?("-h")
  puts usage
  exit 0
end

opts = {}
while (flag = args.shift)
  case flag
  when "--contract", "--fixture", "--section"
    opts[flag.delete_prefix("--").to_sym] = args.shift
  else
    cannot_measure("unknown argument #{flag.inspect}", "pass only --contract, --fixture, --section")
  end
end

%i[contract fixture section].each do |key|
  next if opts[key] && !opts[key].empty?

  cannot_measure("--#{key} is required", "pass --#{key}")
end

[opts[:contract], opts[:fixture]].each do |path|
  next if File.file?(path)

  cannot_measure("no such file #{path}", "point the argument at the real file")
end

lines = File.readlines(opts[:contract], chomp: true)
start = lines.index { |l| l =~ /\A#+\s+#{Regexp.escape(opts[:section])}\s*\z/ }
if start.nil?
  cannot_measure(
    "section heading #{opts[:section].inspect} not found in #{opts[:contract]}",
    "the heading was renamed or removed; update the --section argument in " \
    "ai/contracts/test/self-test.sh to the section that now holds these quotes"
  )
end

level = lines[start][/\A#+/].length
stop = ((start + 1)...lines.length).find do |i|
  lines[i] == "---" || (lines[i] =~ /\A(#+)\s/ && Regexp.last_match(1).length <= level)
end
body = lines[(start + 1)...(stop || lines.length)].join("\n")

quoted = body.scan(/`(Fix:[^`]+)`/m).map { |(s)| s.gsub(/\s+/, " ").strip }
quoted.reject! { |s| s == "Fix:" }
pinned = File.readlines(opts[:fixture], chomp: true).reject { |l| l.strip.empty? || l.start_with?("#") }

if quoted.empty?
  cannot_measure(
    "section #{opts[:section].inspect} quotes no `Fix: ...` span",
    "the quotes moved out of this section; point --section at where they now live"
  )
end
if pinned.empty?
  cannot_measure("fixture #{opts[:fixture]} pins no clause", "restore the fixture's clause lines")
end

if quoted == pinned
  puts "check-quoted-fix: OK — #{quoted.length} quoted Fix: clause(s) in " \
       "#{opts[:section].inspect} match #{File.basename(opts[:fixture])}"
  exit 0
end

puts "check-quoted-fix: DRIFT — #{opts[:contract]} section #{opts[:section].inspect} " \
     "quotes #{quoted.length} Fix: clause(s); the fixture pins #{pinned.length}."
[quoted.length, pinned.length].max.times do |i|
  next if quoted[i] == pinned[i]

  puts "  clause #{i + 1}:"
  puts "    contract: #{quoted[i] || '(none)'}"
  puts "    fixture:  #{pinned[i] || '(none)'}"
end
puts "Fix: decide which side is the design. If the shipped text changed, update the " \
     "contract quote AND #{opts[:fixture]} together (and the gen_saas test named in " \
     "its header); if the contract is right, fix the code, not the fixture."
exit 1
