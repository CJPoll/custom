# DND-1697: score bar items 3 and 4 on the held-out set H.
# Usage: ruby score-held-out.rb V1_RUNFILE V2_RUNFILE LABELS
# A case unscored in EITHER run is n/a, named, and left out of both counts.
require "json"
v1_path, v2_path, labels_path = ARGV
abort("usage: ruby score-held-out.rb V1_RUNFILE V2_RUNFILE LABELS. Fix: pass all three paths") unless labels_path
lab = File.readlines(labels_path).reject { |l| l.strip.empty? }.to_h { |l| j = JSON.parse(l); [j["id"], j["label"]] }
load_run = lambda do |path|
  r = JSON.parse(File.read(path))
  puts "# #{File.basename(path)}: run #{r['eval_run_id']} #{r['question_set_version']} #{r['model']} candidate=#{r['candidate'] ? true : false}"
  r["results"].to_h { |c| [c["case_id"], c["outcome"] == "scored" ? c["predicted"] : nil] }
end
a = load_run.call(v1_path)
b = load_run.call(v2_path)
na = lab.keys.select { |id| a[id].nil? || b[id].nil? }
puts "n/a (unscored in either run, left out of both): #{na.size}#{na.empty? ? '' : " #{na.join(', ')}"}"
ids = lab.keys - na
sec = ids.select { |id| lab[id] == "security" }
non = ids.select { |id| lab[id] == "none" }
s1 = sec.count { |id| a[id] == "security" }
s2 = sec.count { |id| b[id] == "security" }
f1 = non.count { |id| a[id] == "security" }
f2 = non.count { |id| b[id] == "security" }
puts "item 3: security cases judged security: v1 #{s1}/#{sec.size}, v2 #{s2}/#{sec.size} -> #{s2 >= s1 - 1 ? 'PASS' : 'FAIL'}"
puts "item 4: none cases judged security: v1 #{f1}/#{non.size}, v2 #{f2}/#{non.size} -> #{f2 <= f1 ? 'PASS' : 'FAIL'}"
lost = sec.select { |id| a[id] == "security" && b[id] != "security" }
puts "security cases v2 lost: #{lost.empty? ? 'none' : lost.join(', ')}"
