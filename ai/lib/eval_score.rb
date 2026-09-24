# frozen_string_literal: true

# EvalScore — the numeric eval score and the noise-threshold rule (DND-225).
#
# Pure domain code: no IO, no model, no git. Consumed by ai/bin/variant-eval
# (the per-case A/B verdict) and ai/bin/admiral-eval (the score block in --run
# output). Tested by ai/lib/test/eval-score/self-test.sh, which harness-gate
# discovers. The measured noise band and the method behind these rules are in
# ai/docs/eval-noise-band.md.
#
# The model-in-loop eval signal is a Bernoulli trial per sample: a case either
# passes its deterministic scorer or not. So a case's score is its pass-rate
# k/n, and its sampling noise is the binomial interval around that rate:
#
#   * per case:   p = k/n with a Wilson 95% score interval [lo, hi].
#   * aggregate:  the mean per-case p over MEASURED cases. Descriptive only; it
#                 is comparable across runs only over a byte-identical corpus.
#   * a delta:    p_var - p_base with Newcombe's hybrid-score 95% interval
#                 (method 10, built from the two Wilson intervals). A delta whose
#                 interval contains 0 is inside the noise band: INCONCLUSIVE.
#
# The verdict rule is ASYMMETRIC so that DND-225 can only make variant-eval
# more cautious, never less (safety checks get faster, never weaker):
#
#   regression  = statistical OR pilot envelope   (never less sensitive)
#   improvement = statistical AND pilot envelope  (a KEEP only gets harder)
#
# The pilot envelope is DND-174's fixed |Δp| > 0.3, moved here unchanged.
#
# A side that was not measured is `nil`, rendered "n/a", and is NEVER coerced
# to a measured 0 (~/dev/custom/CLAUDE.md -> *A failed lookup must never look
# like an empty one*):
#   * new in the variant (no baseline):   :new      — not an improvement
#   * absent from the variant:            :missing  — fails closed (regression)
module EvalScore
  Z95 = 1.959963984540054
  PILOT_ENVELOPE = 0.3
  # Keep a flip of EXACTLY the envelope inconclusive despite float fuzz
  # (0.9 - 0.6 == 0.30000000000000004).
  ENVELOPE_EPS = 1e-9

  Counts = Struct.new(:k, :n)

  class InvalidCounts < ArgumentError; end

  module_function

  # Validated sample counts. n must be >= 1: "nothing measured" is nil, not 0/0.
  def counts(k, n)
    unless k.is_a?(Integer) && n.is_a?(Integer) && n >= 1 && k >= 0 && k <= n
      raise InvalidCounts,
            "invalid sample counts k=#{k.inspect} n=#{n.inspect}. Fix: pass integers with 0 <= k <= n and " \
            "n >= 1; represent an unmeasured case as nil (n/a), never as 0/0."
    end
    Counts.new(k, n)
  end

  # "k/n" -> Counts. "0/0" (nothing sampled) -> nil, i.e. n/a. Anything else
  # raises: a malformed rate is an error, not an empty result.
  def parse_rate(str)
    m = /\A(\d+)\/(\d+)\z/.match(str.to_s.strip)
    unless m
      raise InvalidCounts,
            "unparseable pass-rate #{str.inspect}. Fix: a rate is \"<passes>/<samples>\" (e.g. \"2/3\"); " \
            "an unmeasured case is \"0/0\"."
    end
    k = m[1].to_i
    n = m[2].to_i
    return nil if k.zero? && n.zero?

    counts(k, n)
  end

  # Wilson score interval for k/n at z. Returns [lo, hi], clamped to [0, 1].
  def wilson(c, z: Z95)
    n = c.n.to_f
    p = c.k / n
    denom = 1 + (z * z / n)
    centre = (p + (z * z / (2 * n))) / denom
    half = z * Math.sqrt((p * (1 - p) / n) + (z * z / (4 * n * n))) / denom
    [[centre - half, 0.0].max, [centre + half, 1.0].min]
  end

  # { k:, n:, p:, lo:, hi: } for measured counts; nil (n/a) for nil.
  def case_score(c)
    return nil if c.nil?

    lo, hi = wilson(c)
    { k: c.k, n: c.n, p: c.k.to_f / c.n, lo: lo, hi: hi }
  end

  def format_score(score)
    return "n/a" if score.nil?

    format("%.2f [%.2f,%.2f] (%d/%d)", score[:p], score[:lo], score[:hi], score[:k], score[:n])
  end

  # Mean per-case pass-rate over measured cases. score is nil (n/a) when
  # nothing was measured — never 0.
  def aggregate(counts_list)
    measured = counts_list.compact
    score = measured.empty? ? nil : measured.sum { |c| c.k.to_f / c.n } / measured.size
    { score: score, measured: measured.size, n_a: counts_list.size - measured.size }
  end

  # Newcombe hybrid-score interval for d = p_var - p_base.
  # Returns [d, lo, hi].
  def newcombe(base, var, z: Z95)
    pb = base.k.to_f / base.n
    pv = var.k.to_f / var.n
    lb, ub = wilson(base, z: z)
    lv, uv = wilson(var, z: z)
    d = pv - pb
    lo = d - Math.sqrt(((pv - lv)**2) + ((ub - pb)**2))
    hi = d + Math.sqrt(((uv - pv)**2) + ((pb - lb)**2))
    [d, lo, hi]
  end

  # DND-174's pilot rule, unchanged: |Δp| must exceed the envelope.
  def pilot_flip(p_base, p_var, envelope = PILOT_ENVELOPE)
    return :regressed if (p_base - p_var) - envelope > ENVELOPE_EPS
    return :improved  if (p_var - p_base) - envelope > ENVELOPE_EPS

    :inconclusive
  end

  # The statistical rule: conclusive only when the Newcombe interval excludes 0.
  def stat_flip(base, var)
    _d, lo, hi = newcombe(base, var)
    return :regressed if hi.negative?
    return :improved  if lo.positive?

    :inconclusive
  end

  # The noise-threshold rule variant-eval consumes. base/var are Counts or nil.
  def classify(base, var, envelope: PILOT_ENVELOPE)
    return :n_a     if base.nil? && var.nil?
    return :new     if base.nil?
    return :missing if var.nil?

    stat = stat_flip(base, var)
    pilot = pilot_flip(base.k.to_f / base.n, var.k.to_f / var.n, envelope)
    return :regressed if stat == :regressed || pilot == :regressed
    return :improved  if stat == :improved && pilot == :improved

    :inconclusive
  end

  # True for the flips that block adoption (REVERT).
  def regression?(flip)
    %i[regressed missing].include?(flip)
  end

  # The rule's A/A false-REVERT probability for ONE case: baseline and variant
  # are each n independent draws of the same true pass-rate p, so any
  # regression classify reports is noise by construction.
  def aa_false_regression_rate(p, n)
    raise ArgumentError, "p=#{p.inspect} outside [0,1]. Fix: pass a pass-rate in [0,1]." unless p.between?(0.0, 1.0)

    pmf = binomial_pmf(p, n)
    (0..n).sum do |kb|
      (0..n).sum { |kv| classify(counts(kb, n), counts(kv, n)) == :regressed ? pmf[kb] * pmf[kv] : 0.0 }
    end
  end

  def binomial_pmf(p, n)
    (0..n).map { |k| choose(n, k) * (p**k) * ((1 - p)**(n - k)) }
  end

  def choose(n, k)
    (1..k).reduce(1) { |acc, i| acc * (n - k + i) / i }
  end

  # What N buys: the smallest drop from a perfect n/n baseline that the
  # statistical rule calls a regression with n samples per side; nil if none.
  def min_detectable_drop(n)
    base = counts(n, n)
    (1..n).find { |drop| stat_flip(base, counts(n - drop, n)) == :regressed }
  end
end
