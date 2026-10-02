# DND-1697 v3: score the ticket-security-v3 bar's held-out items from two
# `judgment-eval --repeat 3` run files (see README.md -> The ticket-security-v3 bar).
# Usage: ruby score-v3.rb V1_RUNFILE V3_RUNFILE LABELS
#
# Per case, only the verdict `match` (every sample gave the label) is right;
# `miss` and `unstable` are not. A case with no measured verdict in at least
# one run is n/a: named and left out of both counts. An n/a case decides
# item 2 only when it could hide a lost case (v1 did not measure a non-match
# and v3 did not match): then the result is COULD NOT MEASURE, never a pass.
# Reads run files only (they hold no input).
#
# Exit: 0 PASS, 1 FAIL, 3 COULD NOT MEASURE, 2 usage or a refused input.
require "json"

FALSE_SECURITY_MAX = 31
FALSE_SECURITY_BASE = 291
MEASURED = %w[match miss unstable].freeze

def refuse(message)
  warn "score-v3: #{message}"
  exit 2
end

v1_path, v3_path, labels_path = ARGV
refuse("usage: ruby score-v3.rb V1_RUNFILE V3_RUNFILE LABELS. Fix: pass all three paths") unless labels_path && ARGV.size == 3

def read_json_lines(path)
  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
rescue SystemCallError, JSON::ParserError => e
  refuse("cannot read labels #{path}: #{e.message}. Fix: pass the labels JSONL the runs were made from")
end

labels = read_json_lines(labels_path).to_h { |j| [j["id"], j["label"]] }

def load_run(path, want_version, labels)
  run =
    begin
      JSON.parse(File.read(path))
    rescue SystemCallError, JSON::ParserError => e
      refuse("cannot read run file #{path}: #{e.message}. Fix: pass a run file judgment-eval wrote")
    end
  unless run["question_set_version"] == want_version
    refuse("#{path} is #{run['question_set_version'].inspect}, expected #{want_version}. " \
           "Fix: pass the v1 run first and the v3 run second")
  end
  verdicts = run["verdicts"]
  unless run["repeat"].to_i >= 3 && verdicts.is_a?(Array)
    refuse("#{path}: run #{run['eval_run_id']} has repeat #{run['repeat'].inspect} and no per-case verdicts. " \
           "Fix: measure with judgment-eval --repeat 3; the bar counts a case right only when all 3 samples give its label")
  end
  ids = verdicts.map { |v| v["case_id"] }
  dup = ids.select { |id| ids.count(id) > 1 }.uniq
  refuse("#{path} has duplicate verdicts for #{dup.join(', ')}. Fix: pass an unedited judgment-eval run file") unless dup.empty?
  wrong = verdicts.select { |v| labels.key?(v["case_id"]) && labels[v["case_id"]] != v["label"] }.map { |v| v["case_id"] }
  unless wrong.empty?
    refuse("#{path} scored #{wrong.join(', ')} against a different label than #{File.basename(ARGV[2])}. " \
           "Fix: pass the labels file both runs were made from")
  end
  puts "# #{File.basename(path)}: run #{run['eval_run_id']} #{run['question_set_version']} #{run['model']} " \
       "repeat=#{run['repeat']} candidate=#{run['candidate'] ? true : false}"
  [run, verdicts.to_h { |v| [v["case_id"], v["verdict"]] }]
end

r1, v1 = load_run(v1_path, "ticket-security-v1", labels)
r3, v3 = load_run(v3_path, "ticket-security-v3", labels)
unless r1["labels_sha256"].is_a?(String) && r1["labels_sha256"] == r3["labels_sha256"]
  refuse("the runs name different labels files (labels_sha256 #{r1['labels_sha256'].inspect} vs #{r3['labels_sha256'].inspect}). " \
         "Fix: measure both versions against the same labels file")
end

na = labels.keys.reject { |id| MEASURED.include?(v1[id]) && MEASURED.include?(v3[id]) }
puts "n/a (no measured verdict in at least one run, left out of both): #{na.size}#{na.empty? ? '' : " (#{na.join(', ')})"}"
undecided = na.reject { |id| (MEASURED.include?(v1[id]) && v1[id] != "match") || v3[id] == "match" }
puts "n/a that could hide a lost case: #{undecided.size}#{undecided.empty? ? '' : " (#{undecided.join(', ')})"}"

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

if !item2 || !item3
  puts "result: FAIL"
  exit 1
elsif !undecided.empty?
  puts "result: COULD NOT MEASURE (re-run the set once; a second n/a is reported, never scored)"
  exit 3
end
puts "result: PASS"
exit 0
