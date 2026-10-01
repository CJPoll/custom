# frozen_string_literal: true

# manager_test.rb -- the MANAGER layer of ticket-classify --epic (DND-1382):
# the Path part runs after the classification and keys on the Kind that is
# filed, not on the filer's Kind. Loaded by self-test.sh as
#   ruby manager_test.rb <path of scripts/ticket-classify>
# The effects (the body file, the Notion read, the Athena POST) are stubbed;
# nothing leaves the process. Prints one "ok"/"FAIL" line per case, then a
# "manager: N passed, M failed" line; exits non-zero on any failure.

require "json"
require "stringio"

SCRIPT = ARGV.fetch(0)
load SCRIPT # main() runs only when the script is $PROGRAM_NAME

PASSED = []
FAILED = []

def check(name, got, want)
  if got == want
    PASSED << name
    puts "ok   #{name}"
  else
    FAILED << name
    puts "FAIL #{name}"
    puts "     expected [#{want.inspect}], got [#{got.inspect}]"
  end
end

CANDIDATES = { chosen: [{ ref: "DND-717", page_id: "p", title: "t", summary: "s" }], open: 1, epic_title: "E" }.freeze
PATH_ANSWER = {
  "status" => "judged",
  "path" => { "decided" => "Off", "blocks" => nil, "source" => "filer", "reason" => "mode_off" },
  "provenance_line" => "Jev path: {}"
}.freeze

def classification_answer(kind)
  severity = kind == "Feature" ? nil : "MEDIUM"
  {
    "status" => "judged",
    "properties" => {
      "kind" => { "decided" => kind, "source" => "jev", "judged" => { "confidence" => 0.9 } },
      "severity" => { "decided" => severity, "source" => "filer", "reason" => "mode_off", "judged" => nil },
      "security" => { "decided" => "none", "source" => "filer", "reason" => "mode_off", "judged" => nil }
    },
    "provenance_line" => "Jev classification: {}"
  }
end

# A stubbed run: the classification endpoint answers `classify_reply` (a
# Hash body, or :down for an unreachable server); `parsed` overrides what
# Classify.parse_result returns (to reach a decided Kind its own check
# refuses). Returns [exit code, posted paths, stdout, stderr].
def run_manager(filer_kind, classify_reply, parsed: nil)
  posted = []
  Effects.define_singleton_method(:read_body_file) { |_path| "body" }
  Effects.define_singleton_method(:epic_candidates) { |_epic| CANDIDATES }
  Effects.define_singleton_method(:post) do |path, _body|
    posted << path
    if path == ENDPOINT
      server_unreachable!("stubbed outage") if classify_reply == :down
      { curl_rc: 0, status: 200, body: JSON.generate(classify_reply) }
    else
      { curl_rc: 0, status: 200, body: JSON.generate(PATH_ANSWER) }
    end
  end
  original = Classify.method(:parse_result)
  Classify.define_singleton_method(:parse_result) { |doc, filer| parsed || original.call(doc, filer) }
  severity = filer_kind == "Feature" ? "none" : "MEDIUM"
  opts = {
    title: "T", body_file: "unused", project: "harness", ref: nil, json: false,
    filer: { kind: filer_kind, severity: severity, security: "none" },
    epic: "3e6349da-87fb-817a-acfb-d72c30bf9986", found_while: nil, claimed_blocks: nil
  }
  out = StringIO.new
  err = StringIO.new
  code = Manager.run(opts, out, err)
  [code, posted, out.string, err.string]
ensure
  Classify.define_singleton_method(:parse_result) { |doc, filer| original.call(doc, filer) } if original
end

code, posted, out, = run_manager("Bug", classification_answer("Bug"))
check("a Bug decided Bug: both parts run, classification first", posted, [ENDPOINT, BLOCKING_ENDPOINT])
check("a Bug decided Bug: exit 0 with a Path line", [code, out.include?("Path: Off (filer: mode_off)")], [0, true])

code, posted, = run_manager("Bug", classification_answer("Vulnerability"))
check("a Bug decided Vulnerability still has its Path judged", [code, posted], [0, [ENDPOINT, BLOCKING_ENDPOINT]])

code, posted, out, = run_manager("Bug", :down)
check("an unavailable classification judges Path on the filer's Kind", posted, [ENDPOINT, BLOCKING_ENDPOINT])
check("an unavailable classification: exit 3, the filer's Kind printed", [code, out.include?("Kind: Bug\n")], [3, true])

# The policy never assigns Feature and Classify.parse_result refuses an
# answer that does, so this decided Feature is forced past that check: it
# proves the Path part reads the decided Kind, not the filer's.
code, posted, out, err = run_manager("Bug", classification_answer("Feature"), parsed: classification_answer("Feature"))
check("a decided Feature: the Path is never sent [DND-1382]", posted, [ENDPOINT])
check("a decided Feature: no Path line, exit 0", [code, out.include?("Path:")], [0, false])
check("a decided Feature: stderr says its Path is authored", err.include?("the decided Kind is Feature; its Path is authored, never judged"), true)

code, posted, out, = run_manager("Bug", classification_answer("Feature"))
check("a real decided-Feature answer is unreadable: exit 3", code, 3)
check("and the Path is judged on the Kind filed, the filer's Bug", [posted, out.include?("Kind: Bug\n"), out.include?("Path: Off")], [[ENDPOINT, BLOCKING_ENDPOINT], true, true])

puts "manager: #{PASSED.size} passed, #{FAILED.size} failed"
exit(FAILED.empty? ? 0 : 1)
