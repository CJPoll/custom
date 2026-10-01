# frozen_string_literal: true

# critic_verdict_stores -- the ONE enumeration of a repo's critic-verdict
# stores (DND-457), extracted from ai/bin/critic-review for DND-1477 so
# ai/bin/lead-time-phases reads the same stores rather than a second copy.
#
# critic-review WRITES a receipt per worktree ($GIT_DIR/critic-verdicts). A
# reader keys on what every checkout of a repo shares, the realpath of its git
# COMMON dir, and searches every per-checkout store under it:
#   <common>/critic-verdicts                  (the main checkout's $GIT_DIR)
#   <common>/worktrees/<id>/critic-verdicts   (each linked worktree's $GIT_DIR)
# A receipt inside a REMOVED worktree went with it.
module CriticVerdictStores
  module_function

  # Every CANDIDATE store under a common dir, realpath'd. The key is validated
  # for its TYPE first: a relative, empty, or non-directory common dir is an
  # ERROR here, never an empty candidate list -- a wrongly computed key and a key
  # that correctly matches nothing must not read the same.
  # -> [candidates, nil] or [nil, reason]
  def stores(common)
    c = common.to_s
    return [nil, "the git common dir is empty"] if c.strip.empty?
    return [nil, "the git common dir #{c.inspect} is not absolute (a cwd-relative key matches nothing from any other directory)"] unless c.start_with?("/")
    return [nil, "the git common dir #{c} is not a directory"] unless File.directory?(c)

    real = File.realpath(c)
    wt = File.join(real, "worktrees")
    if File.directory?(wt) && !(File.readable?(wt) && File.executable?(wt))
      return [nil, "#{wt} exists but cannot be listed"]
    end

    # One candidate per checkout's $GIT_DIR, whether or not its store exists
    # yet: a checkout that has never run the judge is still a place we looked.
    gitdirs = Dir.glob(File.join(wt, "*")).select { |d| File.directory?(d) }.sort
    [[File.join(real, "critic-verdicts")] + gitdirs.map { |d| File.join(d, "critic-verdicts") }, nil]
  end
end
