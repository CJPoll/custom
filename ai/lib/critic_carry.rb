# frozen_string_literal: true

# CriticCarry -- the pure half of "a critic PASS carries across an identical
# rebase" (DND-986, owner-approved P4). No I/O: ai/bin/critic-review computes
# the inputs through git and reads the receipts; this module only derives keys
# and decides.
#
# What a carry MEANS is the owner's rule (round 3): "If a rebase doesn't
# change the branch itself and the last critic review for the branch passed,
# the critic's job should only be to see if the changes from the rebase cause
# a problem." -- Cody, 2026-09-27 (Slack, relayed by the coordinator). A carry
# hit covers the branch's own diff; the head passes only when an INTERACTION
# review of the upstream delta passes (see "The interaction review" below).
# With nothing new upstream, the carried PASS stands alone.
#
# The rule it encodes: a PASS recorded on one commit may stand for another
# commit only when the judge would have been shown an IDENTICAL PROMPT -- the same
# patch (git patch-id --stable, computed by the caller), the same patch BYTES
# (patch-id ignores whitespace, so an indentation change would otherwise
# carry), the same commit messages (the judge reads them for BUG_FIX_RULE), and
# the same prompt + agent definition. Every key is required. Any doubt is a
# miss, and a miss runs the judge.
#
# Identical PROMPT, not identical CONTEXT: the judge can also read the tree,
# and after a rebase the surrounding code is new. That second look is what the
# owner accepted giving up (P4); the new base is still gated by
# integration-gate on the integrated head, and the model version behind the
# CLI is not observable here (a stated residual).
#
# A BLOCK recorded on the same change (same patch bytes and messages, under ANY
# judge version) VETOES the carry, whatever order the receipts come in: a carry
# can only replace a model call with a PASS that already exists for the same
# input, never turn a BLOCK into a PASS. An unreadable receipt could be such a
# BLOCK, so it stops the attempt. So does an UNKEYED BLOCK (schema 1, unknown
# schema, or a null key) whose patch cannot be recomputed. The price: while
# such a receipt sits in any store (its commit pruned, say), no carry happens
# in that repo -- every run is judged, which is the pre-carry behaviour. One
# class is set aside, not doubted: a CLEAN (dirty == false) unkeyed BLOCK with
# no recorded merge-base whose commit is already in the head's base (:landed).
# Its judge saw committed content, which is upstream of the head's diff; it is
# counted and each receipt is named in a NOTE. A dirty one stays doubt: its
# judge may have seen uncommitted work that never landed. Its residual: a
# landed change, reverted, then re-applied byte-identically by this branch.
#
# Stated residuals, not closed here: a BLOCK that lands in another checkout
# after this decision; an identical hunk inserted at a different spot with the
# same context lines (hunk line numbers are normalised away, by design, so a
# rebase keeps the key); judge inputs outside the digest (the model an alias
# resolves to, the CLI version, CLAUDE.md files the CLI loads).
#
# Four outcomes, never conflated (ai/CLAUDE.md -> "A failed lookup must never
# look like an empty one"):
#   :carry          a usable PASS was found
#   :refused        a BLOCK on the identical change vetoes
#   :miss           looked, found nothing usable (with counts and reasons)
#   :not_attempted  could not look: a head key is missing, or a receipt is unreadable
require "digest"

module CriticCarry
  # The four keys that define "identical input". merge_base is recorded and
  # must be present on a source (the caller re-derives the source's diff from
  # it), but it is deliberately NOT compared: a rebase changes it.
  MATCH_KEYS = %w[patch_id diff_digest msgs_digest judge_digest].freeze
  HEAD_KEYS  = (["merge_base"] + MATCH_KEYS).freeze
  SHA40 = /\A[0-9a-f]{40}\z/.freeze

  Decision = Struct.new(:outcome, :candidate, :root, :report, :reason, keyword_init: true)

  INDEX_LINE = /\Aindex [0-9a-f]+\.\.[0-9a-f]+(?: [0-7]+)?\r?\n?\z/.freeze
  HUNK_HEAD  = /\A@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/.freeze

  # Exactly two normalisations, both anchored at a line start: drop `index`
  # lines (blob ids move with the base) and blank the hunk line numbers (they
  # move with the base too). A `+index ...` body line starts with `+`, so it is
  # never touched. Nothing else -- whitespace included -- is normalised.
  def self.normalize_diff(text)
    text.to_s.each_line.reject { |l| l.match?(INDEX_LINE) }
        .map { |l| l.sub(HUNK_HEAD, "@@ @@") }.join
  end

  def self.diff_digest(text)
    Digest::SHA256.hexdigest(normalize_diff(text))
  end

  # Bodies only, each NUL-terminated, so [a, b] != [ab] and a trailing empty
  # body still counts. SHAs are not in the input, so a rebase keeps it.
  def self.msgs_digest(bodies)
    Digest::SHA256.hexdigest(bodies.map { |b| "#{b}\0" }.join)
  end

  # The prompt template plus each agent-definition location, labelled by a
  # checkout-independent ROLE (e.g. "project", "user" -- never an absolute
  # path, or two checkouts of one repo could never match), with its bytes or
  # the literal ABSENT. Length-framed so no label/bytes boundary can be
  # shifted to forge a collision.
  def self.judge_digest(template, defs)
    frame = ->(s) { "#{s.bytesize}:#{s}" }
    body = frame.call(template.to_s) + defs.map do |path, bytes|
      frame.call(path.to_s) + (bytes.nil? ? "ABSENT" : "PRESENT" + frame.call(bytes))
    end.join
    Digest::SHA256.hexdigest(body)
  end

  def self.key_ok?(v) = v.is_a?(String) && !v.strip.empty?

  # The veto ignores judge_digest: a BLOCK recorded under another prompt or
  # critic version is still a BLOCK on this change. Only a PASS SOURCE must
  # match the judge too. Dropping a key from the veto only adds vetoes.
  VETO_KEYS = (MATCH_KEYS - ["judge_digest"]).freeze

  # A BLOCK the key comparison can decide: schema 2 with every veto key
  # present. Anything else (schema 1, unknown schema, a null key because a key
  # could not be computed when it was judged) is UNKEYED and needs a recompute.
  def self.keyed_block?(r) = r["schema"] == 2 && VETO_KEYS.all? { |k| key_ok?(r[k]) }

  # head_keys:  { "merge_base", "patch_id", "diff_digest", "msgs_digest", "judge_digest" }
  # candidates: [{ receipt: <parsed JSON Hash>, path:, validated: bool, invalid_reason: }]
  #             validated/invalid_reason are the caller's recompute result (D8).
  def self.decide(head_keys, candidates)
    missing = HEAD_KEYS.reject { |k| key_ok?(head_keys[k]) }
    unless missing.empty?
      return Decision.new(outcome: :not_attempted, reason: "carry key #{missing.join(', ')} could not be computed")
    end

    # A receipt that could not be read might be a BLOCK on this very change
    # (a truncated file is what a concurrent write looks like). It can never
    # silently drop out of the veto, so the carry is not attempted at all.
    if (bad = candidates.find { |c| !c[:receipt].is_a?(Hash) })
      return Decision.new(outcome: :not_attempted, reason: "receipt #{bad[:path]} is unreadable")
    end

    report = { considered: candidates.size, share_patch_id: 0, schema1: 0, unknown_schema: 0,
               fail_open: 0, near_misses: [], landed_blocks: [] }
    same = ->(r) { MATCH_KEYS.all? { |k| r[k] == head_keys[k] } }
    same_change = ->(r) { VETO_KEYS.all? { |k| r[k] == head_keys[k] } }
    schema2 = candidates.select { |c| c[:receipt]["schema"] == 2 }
    report[:schema1] = candidates.count { |c| c[:receipt]["schema"] == 1 }
    report[:unknown_schema] = candidates.size - schema2.size - report[:schema1]

    # The veto first, over every candidate: order and recency never matter.
    # A KEYED block matches on VETO_KEYS. An UNKEYED block (any schema, any
    # null veto key) has its patch recomputed by the caller (:unkeyed_block =
    # :same / :different / a String naming why it could not be); a match on the
    # patch alone is looser than the key match, so it only adds vetoes. An
    # unkeyed block the caller could not classify -- or never classified --
    # might be this change, so the attempt stops: fail closed.
    blocks = candidates.select { |c| c[:receipt]["verdict"] == "block" }
    keyed, unkeyed = blocks.partition { |c| keyed_block?(c[:receipt]) }
    block = keyed.find { |c| same_change.call(c[:receipt]) } || unkeyed.find { |c| c[:unkeyed_block] == :same }
    return Decision.new(outcome: :refused, candidate: block, report: report) if block

    # :landed -- the BLOCK's commit is already in the head's base, so its
    # change is upstream of this head's diff, not in it. It is set aside, and
    # its receipt path is kept (the caller prints each one). Residual, stated: a change that
    # landed, was reverted, and is re-applied byte-identically by this branch.
    report[:landed_blocks] = unkeyed.select { |c| c[:unkeyed_block] == :landed }.map { |c| c[:path] }
    if (doubt = unkeyed.find { |c| !%i[different landed].include?(c[:unkeyed_block]) })
      why = doubt[:unkeyed_block].is_a?(String) ? doubt[:unkeyed_block] : "its patch was not recomputed"
      return Decision.new(outcome: :not_attempted,
                          reason: "BLOCK receipt #{doubt[:path]} has no usable carry keys and #{why}; it might be this change")
    end

    # Several usable sources name the same root (chains never nest). Prefer a
    # receipt the judge itself wrote over a carried one, so the named source is
    # deterministic and, where it still exists, first-hand.
    usable = nil
    schema2.sort_by { |c| c[:receipt]["carried_from"].nil? ? 0 : 1 }.each do |c|
      r = c[:receipt]
      next unless r["patch_id"] == head_keys["patch_id"]

      report[:share_patch_id] += 1
      why = unusable_reason(r, c, head_keys)
      report[:fail_open] += 1 if r["verdict"] == "fail-open" && same.call(r)
      if why
        report[:near_misses] << [c[:path], why]
      else
        usable ||= c
      end
    end
    return Decision.new(outcome: :miss, report: report) unless usable

    r = usable[:receipt]
    Decision.new(outcome: :carry, candidate: usable, root: r["carried_from"] || r["sha"], report: report)
  end

  # nil when a same-patch-id candidate is a usable source, else why not.
  def self.unusable_reason(r, cand, head_keys)
    differ = (MATCH_KEYS - ["patch_id"]).reject { |k| r[k] == head_keys[k] }
    return "#{differ.join(', ')} differ#{differ.size == 1 ? 's' : ''}" unless differ.empty?
    return "verdict #{r['verdict'].inspect} (only a pass carries; a fail-open is not a verdict)" unless r["verdict"] == "pass"
    return "recorded against a dirty tree" unless r["dirty"] == false
    return "null key (#{HEAD_KEYS.reject { |k| key_ok?(r[k]) }.join(', ')})" unless HEAD_KEYS.all? { |k| key_ok?(r[k]) }
    return "sha is not a 40-hex commit" unless r["sha"].to_s.match?(SHA40)
    return "carried_from is malformed" unless r["carried_from"].nil? || r["carried_from"].to_s.match?(SHA40)
    return cand[:invalid_reason] || "recompute mismatch" unless cand[:validated]

    nil
  end

  # --- The interaction review (DND-986 round 3, owner spec) ------------------
  #
  # "If a rebase doesn't change the branch itself and the last critic review
  #  for the branch passed, the critic's job should only be to see if the
  #  changes from the rebase cause a problem." -- Cody, 2026-09-27 (Slack,
  #  relayed by the coordinator).
  #
  # So a carry HIT does not make the head PASS by itself: the carried PASS
  # covers the branch's own diff, and the judge then reviews ONLY the upstream
  # delta the rebase brought in, against the branch.

  # The upstream delta a rebase brought in: the source's judged base .. the
  # head's base. nil when the base did not move -- nothing came in, so the
  # carried PASS stands alone (no model call).
  def self.upstream_range(source, head_keys)
    from = source["merge_base"]
    to = head_keys["merge_base"]
    from == to ? nil : [from, to]
  end

  # Paths both the upstream delta and the branch touch, sorted, deduplicated.
  def self.shared_files(upstream_paths, branch_paths)
    (upstream_paths & branch_paths).uniq.sort
  end

  # The head's verdict from the interaction review's action ->
  # [action, exit_code, pass_label]. Anything but an explicit pass or block is
  # no green verdict.
  def self.interaction_outcome(action)
    case action
    when "pass"  then ["pass", 0, "PASS (CARRIED + INTERACTION)"]
    when "block" then ["block", 2, nil]
    else ["fail-open", 0, nil]
    end
  end

  # The miss's detail lines (the caller prints the headline, which needs the
  # store count and the base it alone knows).
  def self.miss_lines(report)
    lines = report[:near_misses].map { |path, why| "  near miss #{path}: #{why}" }
    if report[:schema1].positive?
      lines << "  #{report[:schema1]} schema 1 receipt(s) have no carry keys and are never a source."
    end
    if report[:unknown_schema].to_i.positive?
      lines << "  #{report[:unknown_schema]} receipt(s) with an unknown or missing schema are never a source."
    end
    lines << "  #{report[:fail_open]} fail-open receipt(s) on this change counted and ignored." if report[:fail_open].positive?
    lines
  end
end
