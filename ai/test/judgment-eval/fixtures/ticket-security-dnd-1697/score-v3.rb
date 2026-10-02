# DND-1697 v3: score the ticket-security-v3 bar's held-out items from two
# `judgment-eval --repeat 3` run files (see README.md -> The ticket-security-v3 bar).
# Usage: ruby score-v3.rb V1_RUNFILE V3_RUNFILE LABELS
#
# Per case, only the verdict `match` (every sample gave the label) is right;
# `miss` and `unstable` are not. A case with no verdict, or `n/a`, in EITHER
# run is n/a: named, left out of both counts, and the result is
# COULD NOT MEASURE, never a pass. Reads run files only (they hold no input).
require "json"

FALSE_SECURITY_MAX = 31
FALSE_SECURITY_BASE = 291

v1_path, v3_path, labels_path = ARGV
unless labels_path
  warn "usage: ruby score-v3.rb V1_RUNFILE V3_RUNFILE LABELS. Fix: pass all three paths"
  exit 2
end

labels = File.readlines(labels_path).reject { |l| l.strip.empty? }.to_h do |l|
  j = JSON.parse(l)
  [j["id"], j["label"]]
end

load_verdicts = lambda do |path|
  run = JSON.parse(File.read(path))
  verdicts = run["verdicts"]
  unless run["repeat"].to_i >= 3 && verdicts.is_a?(Array)
    warn "#{path}: run #{run['eval_run_id']} has repeat #{run['repeat'].inspect} and no per-case verdicts. " \
         "Fix: measure with judgment-eval --repeat 3; the bar counts a case right only when all 3 samples give its label"
    exit 2
  end
  puts "# #{File.basename(path)}: run #{run['eval_run_id']} #{run['question_set_version']} #{run['model']} " \
       "repeat=#{run['repeat']} candidate=#{run['candidate'] ? true : false}"
  verdicts.to_h { |v| [v["case_id"], v["verdict"]] }
end

v1 = load_verdicts.call(v1_path)
v3 = load_verdicts.call(v3_path)

measured = ->(verdict) { %w[match miss unstable].include?(verdict) }
na = labels.keys.reject { |id| measured.call(v1[id]) && measured.call(v3[id]) }
puts "n/a (no verdict in either run, left out of both): #{na.size}#{na.empty? ? '' : " (#{na.join(', ')})"}"

ids = labels.keys - na
sec = ids.select { |id| labels[id] == "security" }
non = ids.select { |id| labels[id] == "none" }

lost = ids.select { |id| v1[id] == "match" && v3[id] != "match" }
item2 = lost.empty?
puts "item 2: cases v1 matches that v3 does not: #{lost.size}#{lost.empty? ? '' : " (#{lost.join(', ')})"} -> #{item2 ? 'PASS' : 'FAIL'}"

f1 = non.count { |id| v1[id] != "match" }
f3 = non.count { |id| v3[id] != "match" }
item3 = f3 <= FALSE_SECURITY_MAX && f3 * FALSE_SECURITY_BASE <= FALSE_SECURITY_MAX * non.size
puts "item 3 (held-out): none cases not matched: v1 #{f1}/#{non.size}, v3 #{f3}/#{non.size} -> #{item3 ? 'PASS' : 'FAIL'}"

s1 = sec.count { |id| v1[id] == "match" }
s3 = sec.count { |id| v3[id] == "match" }
puts "security cases matched (context): v1 #{s1}/#{sec.size}, v3 #{s3}/#{sec.size}"
gained = ids.select { |id| v1[id] != "match" && v3[id] == "match" }
puts "cases v3 matches that v1 does not (context): #{gained.size}#{gained.empty? ? '' : " (#{gained.join(', ')})"}"

result =
  if !na.empty? then "COULD NOT MEASURE (re-run the set once; a second n/a is reported, never scored)"
  elsif item2 && item3 then "PASS"
  else "FAIL"
  end
puts "result: #{result}"
