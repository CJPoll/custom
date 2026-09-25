# frozen_string_literal: true

# ai/lib/landed.rb — READ A CHECK'S BAR FROM WHAT LANDED, NOT FROM THE DIFF.
#
# A gate that reads its threshold, allowlist, or classification from a file the
# change under test may edit is asking the change what the bar should be. See
# ~/dev/custom/CLAUDE.md -> "A check's own bar must not live in the diff it is
# checking". This module is the one place that resolves "what landed", so every
# ratchet reads it the same way. It was extracted from ai/bin/check-guard-messages
# (DND-510 / DND-538) for DND-543, which ratchets ai/tools/risk.yml, the SCOPE
# table in ai/lib/harness_tools.rb, and check-bin-help's EXEMPT.
#
# THE LANDED POINTS. The tip of refs/remotes/origin/main and
# merge-base(HEAD, origin/main). A ratchet compares against the STRICTEST value
# across both, so neither a stale origin/main nor an old merge-base lets a
# loosening through.
#
# THE TIP IS ORIGIN'S, NOT A LOCAL REF (DND-538). refs/remotes/origin/main is a
# local ref anyone can move with `git update-ref`. So it is cross-checked
# against `git ls-remote origin refs/heads/main`, one network round trip
# (~1.4 s over SSH to github.com):
#   - it matches: the ratchet runs;
#   - it differs: Mismatch, naming both SHAs (stale and forged look the same
#     from here, and both mean the local bar is not the landed one);
#   - origin is unreachable, times out, or has no refs/heads/main: Unreadable.
#     Never a fallback to the local ref.
# Nothing here fetches: a fetch writes objects and refs, and a check must stay
# read-only (live verifies run it against the owner's main checkout).
#
# NOT BEING ABLE TO READ THE BAR IS A FAILURE, never a pass. Every miss raises
# Unreadable carrying each probe and what it gave, so the caller prints "could
# not measure" as a list of places looked, distinct from "0 weakening(s)".
#
# There is no in-repo escape hatch here or in any caller: anything a check could
# read, the diff under test could write. The owner lands a new bar on main, and
# a branch rebased onto it passes.
#
# Deliberately gem-free (stdlib only).

require "open3"

module Landed
  REF = "refs/remotes/origin/main"
  REMOTE = "origin"
  REMOTE_REF = "refs/heads/main"
  LS_REMOTE_PROBE = "git ls-remote #{REMOTE} #{REMOTE_REF}".freeze
  # The bound only stops a hung transport from hanging the gate; hitting it is
  # "could not measure", never a pass.
  LS_REMOTE_TIMEOUT = 30

  # The landed bar could not be read. Carries every probe and what it gave.
  class Unreadable < StandardError
    attr_reader :probes

    def initialize(probes)
      @probes = probes
      super("the landed bar could not be read")
    end
  end

  # The local REF disagrees with origin's REMOTE_REF: the bar this checkout
  # would compare against is not the one that landed.
  class Mismatch < StandardError
    attr_reader :local, :remote

    def initialize(local, remote)
      @local = local
      @remote = remote
      super("#{REF} disagrees with #{REMOTE} #{REMOTE_REF}")
    end
  end

  module_function

  # Runs cmd with no stdin; kills its whole process group after timeout
  # seconds. Returns [stdout, stderr, status], status nil on a timeout.
  def capture_with_timeout(env, cmd, timeout)
    Open3.popen3(env, *cmd, pgroup: true) do |stdin, out, err, wait|
      stdin.close
      readers = [Thread.new { out.read }, Thread.new { err.read }]
      status = wait.join(timeout)&.value
      unless status
        begin
          Process.kill("KILL", -wait.pid)
        rescue Errno::ESRCH
          nil
        end
        wait.join
      end
      [readers[0].value, readers[1].value, status]
    end
  end

  # [stdout, success?]; never raises.
  def git_read(root, *args)
    out, _err, status = Open3.capture3({ "GIT_OPTIONAL_LOCKS" => "0" }, "git", "-C", root, *args)
    [out, status.success?]
  rescue Errno::ENOENT
    ["", false]
  end

  # origin's REMOTE_REF, read over the network. Every outcome but a single
  # 40-hex SHA raises Unreadable with the probes so far.
  def remote_tip(root, probes)
    env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_OPTIONAL_LOCKS" => "0" }
    out, err, status = capture_with_timeout(env, ["git", "-C", root, "ls-remote", "--exit-code",
                                                  REMOTE, REMOTE_REF], LS_REMOTE_TIMEOUT)
    outcome = if status.nil?
                "timed out after #{LS_REMOTE_TIMEOUT}s (origin unreachable)"
              elsif status.exitstatus == 2
                "origin is reachable but has no #{REMOTE_REF}"
              elsif !status.success?
                "failed (exit #{status.exitstatus}, origin unreachable): #{err.strip.lines.first.to_s.strip}"
              end
    sha = out.split("\n").map { |l| l.split("\t") }.select { |_, ref| ref == REMOTE_REF }.map(&:first)
    outcome ||= "no single #{REMOTE_REF} line in the reply: #{out.strip.inspect}" unless
      sha.size == 1 && sha[0].match?(/\A\h{40}\z/)
    if outcome
      probes << [LS_REMOTE_PROBE, outcome]
      raise Unreadable.new(probes)
    end
    probes << [LS_REMOTE_PROBE, sha[0][0, 12]]
    sha[0]
  rescue Errno::ENOENT
    probes << [LS_REMOTE_PROBE, "git executable not found on PATH"]
    raise Unreadable.new(probes)
  end

  # Resolves the landed points. Returns [points, probes]: points is
  # [[label, sha], ...] (one entry when the tip IS the merge-base), probes the
  # list of what was asked. Raises Unreadable on any miss, Mismatch when the
  # local tip is not origin's.
  def points(root)
    probes = []
    unreadable = lambda do |ref, outcome|
      probes << [ref, outcome]
      raise Unreadable.new(probes)
    end

    tip, ok = git_read(root, "rev-parse", "--verify", "--quiet", "#{REF}^{commit}")
    tip = tip.strip
    unreadable.call(REF, "no such ref") if !ok || tip.empty?
    probes << [REF, tip[0, 12]]

    shallow, ok = git_read(root, "rev-parse", "--is-shallow-repository")
    unreadable.call("git rev-parse --is-shallow-repository", "failed") unless ok
    if shallow.strip == "true"
      unreadable.call("history depth", "shallow clone: the merge-base with origin/main cannot be proven")
    end

    remote = remote_tip(root, probes)
    raise Mismatch.new(tip, remote) unless remote == tip

    mb, ok = git_read(root, "merge-base", "HEAD", tip)
    mb = mb.strip
    unreadable.call("merge-base(HEAD, origin/main)", "no common ancestor (or no HEAD commit)") if !ok || mb.empty?
    probes << ["merge-base(HEAD, origin/main)", mb[0, 12]]

    pts = if mb == tip
            [["origin/main tip = merge-base(HEAD, origin/main)", tip]]
          else
            [["origin/main (tip)", tip], ["merge-base(HEAD, origin/main)", mb]]
          end
    [pts, probes]
  end

  # The text of path at commit sha, or nil when the commit's tree has no such
  # path. "No such path" is a MEASUREMENT (the bar had not landed at that
  # point); anything else that stops the read raises Unreadable.
  def file_at(root, sha, path, label)
    listing, ok = git_read(root, "ls-tree", "-z", sha, "--", path)
    raise Unreadable.new([[label, "#{sha[0, 12]}: git ls-tree failed for #{path}"]]) unless ok

    row = listing.split("\0").find { |r| r.split("\t", 2)[1] == path }
    return nil unless row

    _mode, type, blob = row.split("\t", 2)[0].split(" ")
    raise Unreadable.new([[label, "#{sha[0, 12]}: #{path} is a #{type}, not a file"]]) unless type == "blob"

    text, ok = git_read(root, "cat-file", "blob", blob)
    raise Unreadable.new([[label, "#{sha[0, 12]}: #{path} could not be read"]]) unless ok

    text
  end

  # Reads path at every landed point and yields (text, label, sha) for each
  # point that has it; the block parses the text into the caller's bar (and
  # raises Unreadable on a malformed one). Returns [points, bars]: bars holds
  # one parsed value per point that had the file, empty when none did (the
  # bar is being introduced by this diff).
  def read_bar(root, path)
    pts, probes = points(root)
    bars = pts.filter_map do |label, sha|
      text = file_at(root, sha, path, label)
      text && yield(text, label, sha)
    rescue Unreadable => e
      raise Unreadable.new(probes + e.probes)
    end
    [pts, bars]
  end

  # "label @ sha12, ..." for an OK line.
  def describe(pts)
    pts.map { |label, sha| "#{label} @ #{sha[0, 12]}" }.join(", ")
  end

  # The failure lines for "could not measure": every probe and what it gave,
  # then the Fix:. what names the bar ("classification", "risk registry", ...).
  def unreadable_lines(what, probes)
    ["  could not measure the landed #{what}, so no weakening could be detected.",
     "  This is a missing MEASUREMENT, not a clean result. Probed, and what each gave:",
     *probes.map { |ref, outcome| "    #{ref} -> #{outcome}" },
     "  Fix: give the check a landed bar to compare against: `git fetch origin main` " \
     "(so #{REF} exists and shares history with HEAD), or `git fetch --unshallow` " \
     "in a shallow clone. Run from a branch that descends from origin/main. If the " \
     "failing probe is `#{LS_REMOTE_PROBE}`, make #{REMOTE} reachable (network, " \
     "remote URL, credentials) and re-run: the check never falls back to the local ref."]
  end

  # The failure lines for a local tip that is not origin's.
  def mismatch_lines(local, remote)
    ["  the local landed ref disagrees with origin, so it is not the landed bar and no " \
     "weakening was measured:",
     "    #{REF} (local) -> #{local}",
     "    #{LS_REMOTE_PROBE} -> #{remote}",
     "  Fix: `git fetch #{REMOTE}` so #{REF} matches what landed, rebase onto " \
     "it, and re-run. A local ref moved by hand (git update-ref) does not move the bar: " \
     "the check compares against origin's #{REMOTE_REF}."]
  end
end
