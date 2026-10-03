# frozen_string_literal: true

require "json"

# ToolPropose::Label -- the pure decision of ai/bin/tool-propose (DND-176):
# from variant-eval's JSON, the sandbox exit, the baseline gate and the
# isolated per-target re-check, exactly one label. RECOMMENDED needs ALL of:
#   - the sandboxed variant-eval exited 0 or 1 and wrote a JSON for exactly this
#     candidate and base (schema variant-eval/proposal@1, corpus deterministic);
#   - verdict keep, regressions == [] (an Array, never null);
#   - every target case under deterministic.fixed and none under new (D-L15);
#   - every target re-checked in its own fresh sandbox, classified by the host,
#     with a verdict equal to its expect (R2-3).
# There is no exit-code-only path to RECOMMENDED: a forged 0 with no JSON is
# UNMEASURED (D-L13). Every other outcome is NOT RECOMMENDED, exit 1.
#
# Pure: no IO. JSON strings are untrusted (the candidate ran inside the
# measurement), so anything quoted from them is cleaned and capped.
module ToolPropose
  module Label
    RECOMMENDED = "RECOMMENDED — MEASURED IMPROVEMENT; human adoption required"
    NOT = "NOT RECOMMENDED"
    ADOPTION = "A human adopts: apply proposal.diff in your own worktree, reclassify the tool's risk.yml entry if " \
               "it is not destructive, and open a PR (critic + harness-gate). Agents never apply a tool-propose " \
               "proposal."
    MEASURED_NOTE = "Gate and regression results were measured with the candidate inside the measurement; target " \
                    "fixes were re-checked in isolation."
    SCHEMA = "variant-eval/proposal@1"
    CORPUS = "deterministic"
    CASE_PREFIX = "he:"
    MEASURED_EXITS = [0, 1].freeze

    module_function

    # -> { label:, exit:, reasons: [String], recheck: bool }
    #   baseline_gate: nil (not run) | :green | { red: [lines] }
    #   isolated:      nil (not run) | { case name => "fires" | "clean" | "error" }
    #   targets:       [{ name:, expect: }]
    def decide(json:, cand_sha:, base_sha:, targets:, sandbox_exit:, baseline_gate:, isolated:)
      why = exit_problem(sandbox_exit)
      return unmeasured(why) if why

      doc, why = document(json)
      return unmeasured(why) if why

      why = identity_problem(doc, cand_sha, base_sha)
      return unmeasured(why) if why

      case doc["verdict"]
      when "unmeasured" then unmeasured("variant-eval: #{clean(doc.dig('unmeasured', 'reason') || 'no reason given', 160)}")
      when "blocked" then blocked(doc, baseline_gate)
      when "revert" then regression(doc)
      when "keep", "inconclusive" then measured(doc, targets, isolated)
      else unmeasured("unknown verdict #{clean(doc['verdict'].inspect, 40)}")
      end
    end

    def exit_problem(code)
      return nil if MEASURED_EXITS.include?(code)
      return "timeout: the sandbox wall limit fired" if code == 124
      return "sandbox: tool-sandbox could not set the sandbox up" if code == 125
      return "interrupted: the run was stopped by signal #{code - 128}" if code.is_a?(Integer) && code > 128
      return "no exit status from the sandbox" if code.nil?

      "variant-eval exited #{code} (accepted: 0 or 1)"
    end

    # -> [Hash, nil] or [nil, why]
    def document(json)
      return [nil, "scorecard unreadable: variant-eval wrote no readable scorecard.json"] if json.nil? || json == :unreadable

      doc = json
      if json.is_a?(String)
        doc = begin
          JSON.parse(json)
        rescue JSON::ParserError
          return [nil, "scorecard unreadable: scorecard.json does not parse"]
        end
      end
      return [nil, "scorecard unreadable: scorecard.json is not an object"] unless doc.is_a?(Hash)

      [doc, nil]
    end

    def identity_problem(doc, cand_sha, base_sha)
      return "scorecard schema is #{clean(doc['schema'].inspect, 40)}, not #{SCHEMA}" unless doc["schema"] == SCHEMA
      return "scorecard corpus is #{clean(doc['corpus'].inspect, 40)}, not #{CORPUS}" unless doc["corpus"] == CORPUS
      return "scorecard is for another candidate (variant_sha is not #{cand_sha})" unless doc["variant_sha"] == cand_sha
      return "scorecard is for another base (baseline_sha is not #{base_sha})" unless doc["baseline_sha"] == base_sha

      nil
    end

    def blocked(doc, baseline_gate)
      return unmeasured("the variant gate is red and the baseline gate did not run") if baseline_gate.nil?
      if baseline_gate.is_a?(Hash) && baseline_gate.key?(:red)
        return unmeasured("sandbox env: the variant gate is red and the pristine baseline gate is red too")
      end
      return unmeasured("the baseline gate result is unknown") unless baseline_gate == :green

      lines = Array(doc["gate_detail"]).map(&:to_s).grep(/FAIL/i).first(3).map { |l| clean(l, 120) }
      result("#{NOT}: gate red (#{lines.empty? ? 'see scorecard.txt' : lines.join('; ')})", 1)
    end

    def regression(doc)
      regs = doc["regressions"].is_a?(Array) ? doc["regressions"] : doc.dig("deterministic", "regressed")
      names = Array(regs).map { |r| clean(r.to_s, 80) }
      result("#{NOT}: regression (#{names.empty? ? 'see scorecard.txt' : names.join(', ')})", 1)
    end

    def measured(doc, targets, isolated)
      det = doc["deterministic"]
      regs = doc["regressions"]
      return unmeasured("regressions is not a list") unless regs.is_a?(Array)
      unless det.is_a?(Hash) && %w[regressed fixed new].all? { |k| det[k].is_a?(Array) }
        return unmeasured("the deterministic block is malformed")
      end
      return unmeasured("no target cases") if targets.empty?
      return regression(doc) unless regs.empty? && det["regressed"].empty?

      keys = targets.to_h { |t| [t[:name], "#{CASE_PREFIX}#{t[:name]}"] }
      new_ones = keys.select { |_, k| det["new"].include?(k) }.keys
      return result("#{NOT}: target not fixed (new, not fixed: #{new_ones.join(', ')})", 1) unless new_ones.empty?

      not_fixed = keys.reject { |_, k| det["fixed"].include?(k) }.keys
      return result("#{NOT}: target not fixed (#{not_fixed.join(', ')})", 1) unless not_fixed.empty?
      return result("#{NOT}: target not fixed (verdict #{doc['verdict']})", 1) unless doc["verdict"] == "keep"

      if isolated.nil?
        return unmeasured("the isolated per-target re-check did not run").merge(recheck: true)
      end

      wrong = targets.reject { |t| isolated[t[:name]] == t[:expect] }.map { |t| t[:name] }
      return result("#{NOT}: target not fixed (isolated re-check: #{wrong.join(', ')})", 1) unless wrong.empty?

      result(RECOMMENDED, 0)
    end

    # harness-eval's bin-stdin rule, applied by the host to one isolated run.
    # tool-sandbox's own codes (124, 125, 128+N) and anything else are error.
    def isolated_verdict(exit_status:, output:)
      return "clean" if exit_status == 0
      return "fires" if exit_status == 1 && output.to_s.include?("Fix:")

      "error"
    end

    def unmeasured(why)
      result("#{NOT}: UNMEASURED (#{why})", 1)
    end

    def result(label, exit)
      { label: label, exit: exit, recheck: false }
    end

    # Untrusted text -> one printable line, capped.
    def clean(text, max)
      s = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/[[:cntrl:]]/, " ").strip
      s.length > max ? "#{s[0, max]}..." : s
    end
  end

  # proposal.md: the recorded recommendation. Renders from host memory only.
  module Proposal
    module_function

    # label: Label.decide's hash, or { label: "REJECTED: ...", exit: 1 }.
    def render(label:, targets:, guard:, run_id:, cand_sha:, base_sha:, scorecard:, isolated:)
      out = +"# tool-propose proposal\n\n"
      out << "**#{label[:label]}**\n\n"
      recommended = label[:label] == Label::RECOMMENDED
      out << "#{Label::MEASURED_NOTE}\n\n" if recommended
      out << "- tool: `ai/bin/#{guard || '?'}`\n- run: `#{run_id}`\n- base (origin/main): `#{base_sha || '?'}`\n"
      out << "- candidate commit (in a discarded clone, on no ref): `#{cand_sha || 'not built'}`\n"
      out << "- provenance line in the tool: `#{format(Candidate::PROVENANCE, run_id)}`\n" if cand_sha
      unless targets.empty?
        out << "\n## Targets\n\n| case | expect | isolated re-check |\n|---|---|---|\n"
        targets.each do |t|
          out << "| #{t[:name]} | #{t[:expect]} | #{isolated ? isolated.fetch(t[:name], 'not run') : 'not run'} |\n"
        end
      end
      out << "\n## Scorecard\n\nscorecard.txt holds variant-eval's full text.\n" if scorecard
      out << "\n## Adoption\n\n#{Label::ADOPTION}\n" if recommended
      out << "\ntool-propose wrote this file and nothing else outside its out-dir. It moved no ref, made no " \
             "commit on any host repo, and opened no PR.\n"
      out
    end
  end
end

require_relative "candidate"
