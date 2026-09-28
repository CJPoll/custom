# frozen_string_literal: true

# ai/lib/outbound_tree_check.rb -- the PURE verdict of the harness-gate tree
# scan (DND-699 part 2). Contract: ai/contracts/athena-private-overlay.md ->
# Outbound-scan interface -> the `--tree` surface.
#
# Domain only: given what the side effects found (the machine mark, the
# overlay state, and the tree scan's outcome), decide pass or fail and the
# lines to print. No filesystem, no git, no environment. The manager is
# ai/bin/check-outbound-tree; the mark probe is ai/lib/outbound_mark.rb; the
# scan itself is ai/lib/outbound_scan_sources.rb.
#
# The one rule this file exists to keep: only an ABSENT overlay on a machine
# KNOWN not to be marked passes unscanned, and that pass never reads as CLEAN.
# Everything else that cannot measure fails: a marked machine, a mark that
# could not be determined, a malformed overlay, zero patterns, no committed
# floor, or a scan that could not read the tree.
#
# Inputs:
#   mark     :marked | :unmarked | :unknown   (the outbound pre-push hook)
#   overlay  :found | :absent | :malformed    (PrivateOverlay::Resolver.root)
#   detail   the probed path (absent) or the reason (malformed)
#   scan     nil when the overlay was not found; else a Hash:
#              { state: :clean,      counts: {...} }
#              { state: :hits,       counts: {...}, hits: ["<location> label=<label>", ...] }
#              { state: :unmeasured, reason: "..." }
#            A hit is already rendered by OutboundScan.render_location, so it
#            carries a location and a label, never the matched text.
#
# Deliberately gem-free (stdlib only).

require_relative "outbound_scan"

module OutboundTreeCheck
  PROG = "check-outbound-tree"

  Verdict = Struct.new(:ok, :state, :lines, keyword_init: true)

  MARK_WHY = {
    marked: "this machine is marked as one that holds the overlay (the outbound pre-push hook is installed)",
    unknown: "whether this machine is marked could not be determined, so it counts as marked",
  }.freeze

  MARKED_ABSENT_FIX =
    "Fix: this machine must measure. Create the overlay (the owner runs `scripts/setup-private-overlay --init`, " \
    "then fills outbound/patterns.tsv and commits it), or, if this machine should not hold it, the owner removes " \
    "the outbound pre-push hook (`scripts/setup-private-overlay --remove`). Contract: " \
    "ai/contracts/athena-private-overlay.md -> Outbound-scan interface."

  MALFORMED_FIX =
    "Fix: correct the overlay problem named above (`ai/bin/private-overlay status` shows it). A malformed " \
    "overlay fails on every machine, marked or not: an overlay that is there but broken is never read as absent."

  module_function

  def decide(mark:, overlay:, detail:, scan:)
    case overlay
    when :absent then absent(mark, detail)
    when :malformed then malformed(detail)
    when :found then scanned(scan)
    else fail_verdict(:unmeasured, ["#{PROG}: FAIL: COULD NOT MEASURE: unknown overlay state #{overlay.inspect}.",
                                    "Fix: report this as a defect in ai/bin/check-outbound-tree."])
    end
  end

  def absent(mark, probed)
    if mark == :unmarked
      return Verdict.new(ok: true, state: :not_measured, lines: [
        "#{PROG}: NOT MEASURED (no overlay on this unmarked machine; probed #{probed})",
        "Nothing was scanned. This is not a clean result: this machine holds no pattern list and has no " \
        "outbound pre-push hook, so there is no bar to measure against here.",
      ])
    end

    why = MARK_WHY.fetch(mark, MARK_WHY[:unknown])
    fail_verdict(:unmeasured, [
      "#{PROG}: FAIL: COULD NOT MEASURE: the private overlay is ABSENT (probed #{probed}), and #{why}.",
      "NOT SCANNED: no result, clean or otherwise.",
      MARKED_ABSENT_FIX,
    ])
  end

  def malformed(reason)
    fail_verdict(:unmeasured, [
      "#{PROG}: FAIL: COULD NOT MEASURE: the private overlay is MALFORMED: #{reason}.",
      "NOT SCANNED: no result, clean or otherwise.",
      MALFORMED_FIX,
    ])
  end

  def scanned(scan)
    case scan && scan[:state]
    when :clean
      Verdict.new(ok: true, state: :clean, lines: [
        "#{PROG}: CLEAN: no tracked file carries a work-domain pattern",
        OutboundScan.counts_line(scan[:counts]),
      ])
    when :hits then hits(scan)
    when :unmeasured
      fail_verdict(:unmeasured, [
        "#{PROG}: FAIL: COULD NOT MEASURE: #{scan[:reason]}.",
        "NOT SCANNED: no result, clean or otherwise.",
        OutboundScan.unmeasured_fix(scan[:reason].to_s),
      ])
    else
      fail_verdict(:unmeasured, ["#{PROG}: FAIL: COULD NOT MEASURE: the overlay was found but no scan result was recorded.",
                                 "Fix: report this as a defect in ai/bin/check-outbound-tree."])
    end
  end

  def hits(scan)
    list = scan[:hits] || []
    fail_verdict(:hits, [
      "#{PROG}: FAIL: HITS: #{list.length} match(es) of work-domain patterns in tracked files. " \
      "The matched text is never printed.",
      *list.map { |h| "  #{h}" },
      OutboundScan.counts_line(scan[:counts]),
      OutboundScan::HIT_FIX,
    ])
  end

  def fail_verdict(state, lines)
    Verdict.new(ok: false, state: state, lines: lines)
  end
end
