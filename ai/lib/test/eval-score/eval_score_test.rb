# frozen_string_literal: true

# Deterministic suite for ai/lib/eval_score.rb (DND-225). No model, no git, no
# network. Run by ai/lib/test/eval-score/self-test.sh, which harness-gate
# discovers. Plain stdlib assertions (the eval bins are gem-free).

require_relative "../../eval_score"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises?(klass)
  yield
  false
rescue klass
  true
end

def near?(a, b, tol = 5e-4)
  (a - b).abs <= tol
end

C = EvalScore::Counts

# --- parse_rate: "k/n" -> Counts; "0/0" -> nil (n/a); malformed -> raise -----
check("parse_rate 2/3") { EvalScore.parse_rate("2/3") == C.new(2, 3) }
check("parse_rate 10/10") { EvalScore.parse_rate("10/10") == C.new(10, 10) }
check("parse_rate 0/0 is n/a (nil), never a measured 0") { EvalScore.parse_rate("0/0").nil? }
check("parse_rate k>n raises") { raises?(EvalScore::InvalidCounts) { EvalScore.parse_rate("4/3") } }
check("parse_rate empty raises") { raises?(EvalScore::InvalidCounts) { EvalScore.parse_rate("") } }
check("parse_rate nil raises") { raises?(EvalScore::InvalidCounts) { EvalScore.parse_rate(nil) } }
check("parse_rate fraction text raises") { raises?(EvalScore::InvalidCounts) { EvalScore.parse_rate("0.6") } }
check("parse_rate error carries Fix:") do
  EvalScore.parse_rate("x/3")
  false
rescue EvalScore::InvalidCounts => e
  e.message.include?("Fix:")
end

# --- counts validation ----------------------------------------------------
check("counts rejects n=0 (use nil for n/a)") { raises?(EvalScore::InvalidCounts) { EvalScore.counts(0, 0) } }
check("counts rejects negative k") { raises?(EvalScore::InvalidCounts) { EvalScore.counts(-1, 3) } }
check("counts rejects non-integer") { raises?(EvalScore::InvalidCounts) { EvalScore.counts(1.5, 3) } }

# --- Wilson 95% interval (reference values, z=1.96) ------------------------
lo, hi = EvalScore.wilson(C.new(10, 10))
check("wilson 10/10 lo ~0.722") { near?(lo, 0.7225) }
check("wilson 10/10 hi == 1") { near?(hi, 1.0) }
lo, hi = EvalScore.wilson(C.new(5, 10))
check("wilson 5/10 ~[0.237,0.763]") { near?(lo, 0.2366) && near?(hi, 0.7634) }
lo, hi = EvalScore.wilson(C.new(0, 3))
check("wilson 0/3 ~[0,0.562]") { near?(lo, 0.0) && near?(hi, 0.5615) }
lo, hi = EvalScore.wilson(C.new(3, 3))
check("wilson 3/3 lo ~0.438") { near?(lo, 0.4385) && near?(hi, 1.0) }
check("wilson bounds stay in [0,1]") do
  (1..12).all? { |n| (0..n).all? { |k| l, h = EvalScore.wilson(C.new(k, n)); l >= 0 && h <= 1 && l <= h } }
end

# --- case_score / format --------------------------------------------------
s = EvalScore.case_score(C.new(6, 10))
check("case_score p") { near?(s[:p], 0.6) }
check("case_score carries k/n") { s[:k] == 6 && s[:n] == 10 }
check("case_score of nil is nil (n/a)") { EvalScore.case_score(nil).nil? }
check("format of nil reads n/a, never 0") { EvalScore.format_score(nil) == "n/a" }
check("format of 6/10") { EvalScore.format_score(s) == "0.60 [0.31,0.83] (6/10)" }

# --- aggregate: mean per-case pass-rate over MEASURED cases -----------------
agg = EvalScore.aggregate([C.new(3, 3), C.new(2, 3), nil])
check("aggregate mean over measured only") { near?(agg[:score], (1.0 + 2.0 / 3) / 2) }
check("aggregate counts measured") { agg[:measured] == 2 }
check("aggregate counts n/a separately") { agg[:n_a] == 1 }
agg0 = EvalScore.aggregate([nil, nil])
check("aggregate with nothing measured is n/a (nil), not 0") { agg0[:score].nil? && agg0[:measured].zero? }
check("aggregate of empty list is n/a") { EvalScore.aggregate([])[:score].nil? }

# --- Newcombe hybrid score interval for p_var - p_base ----------------------
d, dlo, dhi = EvalScore.newcombe(C.new(10, 10), C.new(6, 10))
check("newcombe 10/10 -> 6/10 d=-0.4") { near?(d, -0.4) }
check("newcombe 10/10 -> 6/10 excludes 0") { dhi < 0 }
d, dlo, dhi = EvalScore.newcombe(C.new(10, 10), C.new(7, 10))
check("newcombe 10/10 -> 7/10 includes 0") { dlo < 0 && dhi > 0 }
d, dlo, dhi = EvalScore.newcombe(C.new(5, 10), C.new(5, 10))
check("newcombe equal rates symmetric around 0") { near?(d, 0.0) && near?(dlo, -dhi) }

# --- pilot envelope (moved verbatim from variant-eval) ----------------------
check("pilot: 0.9 vs 0.6 float-fuzz stays inconclusive") { EvalScore.pilot_flip(0.9, 0.6) == :inconclusive }
check("pilot: 1.0 vs 0.6 regressed") { EvalScore.pilot_flip(1.0, 0.6) == :regressed }
check("pilot: 0.6 vs 1.0 improved") { EvalScore.pilot_flip(0.6, 1.0) == :improved }

# --- classify: the noise-threshold rule ------------------------------------
# Regression = statistical OR pilot (never less sensitive than before DND-225).
check("classify 10/10 -> 6/10 regressed") { EvalScore.classify(C.new(10, 10), C.new(6, 10)) == :regressed }
check("classify 10/10 -> 7/10 inconclusive") { EvalScore.classify(C.new(10, 10), C.new(7, 10)) == :inconclusive }
check("classify 30/30 -> 24/30 regressed by the statistical rule alone") do
  EvalScore.classify(C.new(30, 30), C.new(24, 30)) == :regressed
end
check("classify 5/10 -> 1/10 still regressed (pilot keeps the old sensitivity)") do
  EvalScore.classify(C.new(5, 10), C.new(1, 10)) == :regressed
end
# Improvement = statistical AND pilot (a KEEP claim only gets harder).
check("classify 0/10 -> 4/10 improved") { EvalScore.classify(C.new(0, 10), C.new(4, 10)) == :improved }
check("classify 5/10 -> 9/10 inconclusive (pilot says improved; the interval includes 0)") do
  EvalScore.classify(C.new(5, 10), C.new(9, 10)) == :inconclusive
end
check("classify 24/30 -> 30/30 inconclusive (statistical alone never claims an improvement)") do
  EvalScore.classify(C.new(24, 30), C.new(30, 30)) == :inconclusive
end
# The AE-02 shape at K=3: the interval includes 0, but the pilot envelope
# (0.33 > 0.3) calls it a regression. OR keeps it failing closed; the measured
# band (ai/docs/eval-noise-band.md) is why that REVERT is expected noise at K=3.
check("stat_flip AE-02 shape 2/3 -> 1/3 inconclusive") { EvalScore.stat_flip(C.new(2, 3), C.new(1, 3)) == :inconclusive }
check("classify AE-02 shape 2/3 -> 1/3 regressed (pilot, fail closed)") do
  EvalScore.classify(C.new(2, 3), C.new(1, 3)) == :regressed
end
check("stat_flip 24/30 -> 30/30 improved") { EvalScore.stat_flip(C.new(24, 30), C.new(30, 30)) == :improved }
check("stat_flip 10/10 -> 6/10 regressed") { EvalScore.stat_flip(C.new(10, 10), C.new(6, 10)) == :regressed }
check("classify 3/3 -> 3/3 inconclusive") { EvalScore.classify(C.new(3, 3), C.new(3, 3)) == :inconclusive }
# Missing sides: a failed lookup must never look like a measured 0.
check("classify new-in-variant (base n/a) is :new, never :improved") { EvalScore.classify(nil, C.new(10, 10)) == :new }
check("classify missing-in-variant is :missing (fail closed)") { EvalScore.classify(C.new(10, 10), nil) == :missing }
check("classify both n/a is :n_a") { EvalScore.classify(nil, nil) == :n_a }
check("regression? treats :missing as a regression") { EvalScore.regression?(:missing) && EvalScore.regression?(:regressed) }
check("regression? is false for :new/:n_a/:inconclusive/:improved") do
  %i[new n_a inconclusive improved].none? { |f| EvalScore.regression?(f) }
end

# --- min_detectable_drop: what N buys ------------------------------------
# Statistical rule only, from a perfect baseline, N samples per side.
check("min_detectable_drop N=1 is nil (one sample cannot show a drop)") { EvalScore.min_detectable_drop(1).nil? }
check("min_detectable_drop N=3 is 3 (only 3/3 -> 0/3 is conclusive)") { EvalScore.min_detectable_drop(3) == 3 }
check("min_detectable_drop N=10 is 4 (10/10 -> 6/10)") { EvalScore.min_detectable_drop(10) == 4 }
check("min_detectable_drop N=30 is 5 (30/30 -> 25/30)") { EvalScore.min_detectable_drop(30) == 5 }

# --- aa_false_regression_rate: the rule's A/A false-REVERT probability -------
# Both sides are n draws of the SAME case with true pass-rate p; any
# "regression" the rule calls is noise by construction.
check("aa rate p=1.0 is 0 (a perfect case never flips)") { near?(EvalScore.aa_false_regression_rate(1.0, 10), 0.0) }
check("aa rate p=0.0 is 0") { near?(EvalScore.aa_false_regression_rate(0.0, 10), 0.0) }
check("aa rate p=0.5 n=1 is 0.25 (1/1 -> 0/1 trips the pilot)") { near?(EvalScore.aa_false_regression_rate(0.5, 1), 0.25) }
check("aa rate p=0.9 n=3 matches the hand sum") do
  # regressed pairs at n=3 (pilot fires on any drop of >= 1/3 since 1/3 > 0.3):
  # P(k_var < k_base) for two Binomial(3, 0.9) draws.
  pmf = [0.001, 0.027, 0.243, 0.729]
  want = (0..3).sum { |kb| (0...kb).sum { |kv| pmf[kb] * pmf[kv] } }
  near?(EvalScore.aa_false_regression_rate(0.9, 3), want, 1e-9)
end
check("aa rate rejects p outside [0,1]") { raises?(ArgumentError) { EvalScore.aa_false_regression_rate(1.2, 3) } }

if $failures.empty?
  puts "eval-score: self-test OK (#{$checks} checks)"
  exit 0
end
$failures.each { |f| warn "eval-score: FAIL -- #{f}" }
warn "eval-score: self-test FAILED (#{$failures.size}/#{$checks})"
warn "  Fix: ai/lib/eval_score.rb's scoring or noise-threshold rule drifted from the cases above. " \
     "Restore it (regression = statistical OR pilot; improvement = statistical AND pilot; a missing side is " \
     "never a measured 0), or change a case only with the measurement that justifies it in ai/docs/eval-noise-band.md."
exit 1
