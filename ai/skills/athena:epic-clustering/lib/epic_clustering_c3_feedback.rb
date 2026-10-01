# frozen_string_literal: true

# epic_clustering_c3_feedback -- the C3 merge's receiver feedback for
# finding triage (DOMAIN, pure; DND-1468).
#
# When the pass merges a near-duplicate (SKILL.md -> *The pass* -> C3), the
# cancelled ticket is the finding whose Jev advisory may have judged the kept
# ticket NOT a duplicate. That is Jev being wrong, signal
# filed_despite_advice (ai/contracts/athena-judgments.md -> *Receiver
# feedback*, the finding_triage row). This turns each merged pair and the
# duplicate's pasted advisory (read by athena:ticket-management's
# lib/triage_advisory.rb) into one outcome, and each wrong call into ONE
# ai/bin/judgment-feedback command carrying every correction for that call
# (the server keeps one report per call and reporter, so two commands for one
# call would replace each other). It runs nothing: the architect runs it.
#
# Jev's answer for the kept ticket is known only when the advisory shows it:
#   - advised `related`: Jev said related; a duplicate makes that wrong.
#   - not advised while the advisory says duplicate is uncalibrated: every
#     duplicate answer is accepted then (DND-1450), so Jev's answer was not
#     duplicate; wrong.
#   - not advised while a duplicate threshold was in force: Jev may have
#     answered duplicate below it. That is `ambiguous`, never recorded: a
#     correction equal to Jev's own answer would count as a wrong call.
#
# Every pair lands in exactly one reason, so a pair that records nothing
# still says why (a failed lookup must never look like an empty one):
#   record, agreed (advised duplicate), ambiguous, unlinked (no call line),
#   no_call ("call: unavailable"), malformed, not_on (mode not on: nothing
#   was advised), not_a_candidate (the kept ticket was not asked about),
#   unread (the caller could not read the body; the run is incomplete).

module EpicClusteringC3Feedback
  module_function

  FEEDBACK = "~/dev/custom/ai/bin/judgment-feedback"
  REASONS = %i[record agreed ambiguous unlinked no_call malformed not_on not_a_candidate unread].freeze
  ID = /\ADND-\d+\z/

  Pair = Struct.new(:duplicate, :keep, keyword_init: true)

  # pairs(text) -> [Pair] from "DND-9=DND-5,DND-12=DND-7" (duplicate=keep).
  # Raises ArgumentError naming the entry at fault.
  def pairs(text)
    list = text.to_s.split(",").map(&:strip).reject(&:empty?)
    raise ArgumentError, "no pair given; pass DUPLICATE=KEEP, e.g. DND-9=DND-5" if list.empty?

    list.map do |entry|
      parts = entry.split("=", -1)
      raise ArgumentError, "#{entry} is not DUPLICATE=KEEP with ticket ids like DND-12" unless parts.size == 2

      pair(parts[0].strip, parts[1].strip, entry)
    end
  end

  # summary_pairs(summary) -> [Pair] from a pass summary's "merged" list
  # ({"keep","duplicate"} each, as `digest --pass-summary` reads it). An
  # empty list is a pass that merged nothing.
  def summary_pairs(summary)
    merged = summary.is_a?(Hash) ? summary["merged"] : nil
    raise ArgumentError, "the pass summary has no \"merged\" list" unless merged.is_a?(Array)

    merged.each_with_index.map do |m, i|
      raise ArgumentError, "merged[#{i}] is not an object with keep and duplicate" unless m.is_a?(Hash)

      pair(m["duplicate"], m["keep"], "merged[#{i}]")
    end
  end

  def pair(duplicate, keep, label)
    unless duplicate.is_a?(String) && keep.is_a?(String) && ID.match?(duplicate) && ID.match?(keep)
      raise ArgumentError, "#{label} is not DUPLICATE=KEEP with DND ticket ids like DND-12"
    end
    raise ArgumentError, "#{label} names one ticket as both duplicate and keep" if duplicate == keep

    Pair.new(duplicate: duplicate, keep: keep)
  end

  # decide(pair, advisory) -> {reason:, duplicate:, keep:, call:, question:}
  # `advisory` is TriageAdvisory.parse of the duplicate's body.
  def decide(pair, advisory)
    reason = reason_for(pair, advisory)
    out = { reason: reason, duplicate: pair.duplicate, keep: pair.keep, call: nil, question: nil }
    return out unless reason == :record

    out.merge(call: advisory[:call], question: advisory[:questions].fetch(pair.keep))
  end

  def reason_for(pair, advisory)
    case advisory[:status]
    when :unlinked then :unlinked
    when :call_unavailable then :no_call
    when :linked then linked_reason(pair, advisory)
    else :malformed
    end
  end

  def linked_reason(pair, advisory)
    return :not_on unless advisory[:mode] == "on"
    return :not_a_candidate unless advisory[:questions].key?(pair.keep)

    case advisory[:advised][pair.keep]
    when "duplicate" then :agreed
    when "related" then :record
    else advisory[:duplicate_uncalibrated] ? :record : :ambiguous
    end
  end

  def unread(pair)
    { reason: :unread, duplicate: pair.duplicate, keep: pair.keep, call: nil, question: nil }
  end

  # commands(results) -> one record command per call, in first-seen order,
  # with every question that call got wrong.
  def commands(results)
    by_call = {}
    results.each do |r|
      next unless r[:reason] == :record

      (by_call[r[:call]] ||= []) << r[:question]
    end
    by_call.map { |call, questions| command(call, questions.uniq) }
  end

  def command(call, questions)
    corrections = questions.map { |q| "--correct #{q}=duplicate" }.join(" ")
    "#{FEEDBACK} record --call #{call} #{corrections} --signal filed_despite_advice --session-label harness"
  end

  # counts(results) -> {reason => n} over every reason, zeros included.
  def counts(results)
    REASONS.to_h { |r| [r, results.count { |x| x[:reason] == r }] }
  end
end
