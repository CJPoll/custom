# frozen_string_literal: true

# Domain suite for keeping a ticket's Jev lines verbatim (DND-1354):
# ../lib/provenance_lines.rb, pure. Run by self-test.sh beside this file.
# Synthetic text only (this repo is public). Fail-first cases: [ticket].

require_relative "../../lib/provenance_lines"

PL = ProvenanceLines
$failures = []
$checks = 0

def check(desc)
  $checks += 1
  ok = begin
    yield
  rescue StandardError => e
    $failures << desc
    puts "FAIL #{desc} (raised #{e.class}: #{e.message})"
    return
  end
  $failures << desc unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{desc}"
end

def raises(text)
  PL.parse_file(text)
  nil
rescue ArgumentError => e
  e.message
end

CL = 'Jev classification: {"kind":{"value":"Bug","source":"filer","accepted":false}}'
PATHL = 'Jev path: {"path":{"decided":"Off","source":"filer"}}'

puts "== select"
check("select keeps only the Jev lines, in order [ticket]") do
  PL.select(["Kind: Bug (filer: mode_off)", CL, "3 candidates considered", "Path: Off (filer: mode_off)", PATHL]) == [CL, PATHL]
end
check("select of output with no Jev line is empty (the caller says so)") { PL.select(["COULD NOT REACH SERVER: x. Fix: y"]).empty? }

puts "== parse_file"
check("a file of Jev lines parses") { PL.parse_file("#{CL}\n#{PATHL}\n") == [CL, PATHL] }
check("an empty file is an error, never nothing to check [ticket]") { raises("\n").to_s.include?("holds no Jev line") }
check("a non-Jev line is an error naming its number") { raises("#{CL}\nKind: Bug\n").to_s.include?("line 2") }
check("two lines with one prefix is an error") { raises("#{CL}\n#{CL}\n").to_s.include?("two lines with one prefix") }

puts "== compare"
check("the body's last line equal byte for byte is verbatim [ticket]") do
  PL.compare([CL], ["Body.", CL]) == [[CL, :verbatim]]
end
check("surrounding whitespace on the body line is not part of it") { PL.compare([CL], ["  #{CL} "]) == [[CL, :verbatim]] }
check("a paraphrase is :differs [ticket]") do
  PL.compare([CL], ["Jev classification: Kind Bug, Severity LOW, Security none (filer: mode_off)."]) == [[CL, :differs]]
end
check("an older verbatim line before a newer paraphrase is :differs (the LAST line is what readers read)") do
  PL.compare([CL], [CL, "Jev classification: Kind Bug (filer)"]) == [[CL, :differs]]
end
check("no line with the prefix is :missing") { PL.compare([CL, PATHL], [CL]) == [[CL, :verbatim], [PATHL, :missing]] }
check("one changed character is :differs") { PL.compare([CL], [CL.sub("Bug", "Bog")]) == [[CL, :differs]] }

puts
puts "#{$checks - $failures.size}/#{$checks} provenance-lines domain checks passed"
exit($failures.empty? ? 0 : 1)
