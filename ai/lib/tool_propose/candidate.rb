# frozen_string_literal: true

require "ripper"
require "yaml"

# ToolPropose::Candidate -- the pure domain of ai/bin/tool-propose's candidate
# handling (DND-176): extract the one fenced block from an untrusted proposer
# reply, review its shape mechanically, and compute the exact file set the
# candidate commit holds. Everything here works on strings: the candidate is
# DATA on the host, never executed outside tool-sandbox.
#
# The commit holds exactly four paths, all runner-written but the tool body:
#   ai/bin/<guard>                                the candidate + a provenance line
#   ai/test/tool-propose/<guard>/self-test.sh     runs `ai/bin/<guard> --self-test`
#   ai/tools/risk.yml                             + `<guard>: destructive/generated`
#   ai/bin/harness-gate                           + one INLINE_SELF_TEST_COVERED_BY
#                                                 line, so the gate's inline
#                                                 --self-test coverage accounts
#                                                 for the new tool
# Never a fixture: a candidate that would touch ai/eval/** is refused (D-C10),
# so the candidate can never author the test it is scored against.
module ToolPropose
  module Candidate
    SHEBANGS = ["#!/usr/bin/env bash", "#!/bin/bash", "#!/usr/bin/env ruby", "#!/usr/bin/ruby"].freeze
    MAX_BYTES = 40 * 1024
    REQUIRED_TOKENS = ["--help", "--self-test", "Fix:"].freeze
    FENCE_RE = /\A```[A-Za-z0-9_+-]*[ \t]*\z/
    PROVENANCE = "# athena-tool-propose: candidate run %s; human adoption only (ai/docs/tool-propose.md)"
    RUN_ID_RE = /\A[A-Za-z0-9._:-]{1,80}\z/
    GATE_REL = "ai/bin/harness-gate"
    RISK_REL = "ai/tools/risk.yml"
    GATE_ANCHOR_RE = /^INLINE_SELF_TEST_COVERED_BY = \{\n/
    RISK_CLASS = "destructive"
    RISK_REASON = "generated"

    module_function

    # -> [:ok, block text] when the reply holds exactly one fenced block.
    def extract(reply)
      lines = reply.to_s.lines
      fences = lines.each_index.select { |i| lines[i].chomp.match?(FENCE_RE) }
      unless fences.size == 2
        return [:error, "the reply must hold exactly one fenced code block (found #{fences.size} fence line(s))"]
      end

      [:ok, lines[(fences[0] + 1)...fences[1]].join]
    end

    # The mechanical shape review, before anything runs. -> [:ok, text]
    def validate(text)
      return [:error, "the candidate is empty"] if !text.is_a?(String) || text.empty?
      return [:error, "the candidate is #{text.bytesize} bytes, over #{MAX_BYTES / 1024} KiB"] if text.bytesize > MAX_BYTES
      return [:error, "the candidate holds a NUL byte"] if text.include?("\0")

      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      return [:error, "the candidate is not valid UTF-8"] unless utf8.valid_encoding?

      first = utf8.lines.first.to_s.chomp
      unless SHEBANGS.include?(first)
        return [:error, "shebang #{first[0, 60].inspect} is not one of #{SHEBANGS.join(', ')}"]
      end

      missing = REQUIRED_TOKENS.reject { |t| utf8.include?(t) }
      return [:error, "the candidate lacks the token(s) #{missing.join(', ')}"] unless missing.empty?

      [:ok, text]
    end

    # The shebang stays line 1; the provenance line becomes line 2.
    def with_provenance(text, run_id)
      raise ArgumentError, "run id #{run_id.inspect} is not a plain token" unless RUN_ID_RE.match?(run_id.to_s)

      lines = text.lines
      first = lines.first.to_s
      first += "\n" unless first.end_with?("\n")
      first + format(PROVENANCE, run_id) + "\n" + lines.drop(1).join
    end

    def self_test_rel(guard)
      "ai/test/tool-propose/#{guard}/self-test.sh"
    end

    # The fixed suite that makes harness-gate run the candidate's --self-test.
    def self_test_script(guard)
      <<~SH
        #!/usr/bin/env bash
        # Runs ai/bin/#{guard} --self-test and exits with its status. Written by
        # ai/bin/tool-propose (DND-176), not by the candidate; discovered by
        # ai/bin/harness-gate.
        set -euo pipefail
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        root="$(cd "${here}/../../../.." && pwd)"
        exec "${root}/ai/bin/#{guard}" --self-test
      SH
    end

    # risk.yml + one entry, deny by default. -> [:ok, text]
    def risk_text(text, guard)
      tools = risk_tools(text)
      return [:error, "ai/tools/risk.yml does not parse as a registry with a `tools` map"] unless tools.is_a?(Hash)
      return [:error, "ai/tools/risk.yml already has an entry for #{guard}"] if tools.key?(guard)

      body = text.end_with?("\n") ? text : "#{text}\n"
      out = "#{body}  #{guard}: { class: #{RISK_CLASS}, reason: #{RISK_REASON} }\n"
      unless risk_tools(out)&.fetch(guard, nil) == { "class" => RISK_CLASS, "reason" => RISK_REASON }
        return [:error, "appending #{guard} to ai/tools/risk.yml did not yield that entry; its layout changed"]
      end

      [:ok, out]
    end

    def risk_tools(text)
      doc = YAML.safe_load(text)
      doc.is_a?(Hash) ? doc["tools"] : nil
    rescue Psych::Exception
      nil
    end

    # harness-gate + one INLINE_SELF_TEST_COVERED_BY line. -> [:ok, text]
    def gate_text(text, guard)
      anchors = text.scan(GATE_ANCHOR_RE).size
      unless anchors == 1
        return [:error, "ai/bin/harness-gate has #{anchors} `INLINE_SELF_TEST_COVERED_BY = {` line(s), not 1"]
      end
      return [:error, "ai/bin/harness-gate already maps ai/bin/#{guard}"] if text.include?("\"ai/bin/#{guard}\"")

      line = "  \"ai/bin/#{guard}\" => \"#{self_test_rel(guard)}\",\n"
      out = text.sub(GATE_ANCHOR_RE) { |m| m + line }
      return [:error, "ai/bin/harness-gate does not parse as Ruby after the insertion"] if Ripper.sexp(out).nil?

      [:ok, out]
    end

    # path -> [git mode, bytes]
    def files(guard:, text:, run_id:, risk:, gate:)
      {
        "ai/bin/#{guard}" => ["100755", with_provenance(text, run_id)],
        self_test_rel(guard) => ["100755", self_test_script(guard)],
        RISK_REL => ["100644", risk],
        GATE_REL => ["100755", gate]
      }
    end

    # The paths the built commit actually changed, against the expected set.
    def check_paths(paths, guard)
      expected = ["ai/bin/#{guard}", self_test_rel(guard), RISK_REL, GATE_REL]
      eval_paths = paths.select { |p| p.start_with?("ai/eval/") }
      return [:error, "candidate touches eval fixtures (#{eval_paths.join(', ')})"] unless eval_paths.empty?

      extra = paths - expected
      return [:error, "the candidate commit changes unexpected path(s): #{extra.join(', ')}"] unless extra.empty?

      missing = expected - paths
      return [:error, "the candidate commit is missing path(s): #{missing.join(', ')}"] unless missing.empty?

      [:ok, nil]
    end

    # The proposer prompt: the tool name, its contract, and every target case.
    def prompt(guard:, cases:)
      out = +<<~TXT
        Write ONE new command-line tool for a developer harness: ai/bin/#{guard}.

        The contract (all of it is checked):
        - It reads its input on stdin. It exits 0 when the input is clean. It exits 1
          and prints a line containing `Fix:` (what to change) when the input should
          be flagged. Any other exit is an error.
        - `#{guard} --help` prints usage on stdout, exits 0, and does nothing else.
        - `#{guard} --self-test` runs an inline test suite of the tool's own logic and
          exits 0 only when it passes.
        - The first line is one of: #{SHEBANGS.join(', ')}.
        - stdlib only: no gems, no packages, and no `require` or `source` of any file
          in the repository. It runs alone, with nothing beside it.
        - no network, and no writes outside $TMPDIR.
        - At most #{MAX_BYTES / 1024} KiB.

        These cases define the behaviour (each input is shown between the markers):
      TXT
      cases.each do |c|
        out << "\n## #{c[:name]}\n"
        out << "regression: #{c[:regression]}\n"
        out << "expect: #{c[:expect]} (#{c[:expect] == 'fires' ? 'exit 1 with a Fix: line' : 'exit 0'})\n"
        out << "args: #{c[:args].empty? ? '(none)' : c[:args].inspect}\n"
        out << "-----BEGIN INPUT-----\n#{c[:input]}#{c[:input].end_with?("\n") ? '' : "\n"}-----END INPUT-----\n"
      end
      out << "\nReply with exactly one fenced code block holding the whole tool, and nothing else in a fence.\n"
      out
    end
  end
end
