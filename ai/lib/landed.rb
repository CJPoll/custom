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
# ONE READ PER GATE RUN (DND-735). harness-gate runs for 11-15 minutes, and
# main can move in that time. When each check ran its own ls-remote, a push to
# origin mid-run turned every landed-ref check red at once, for a reason that
# had nothing to do with the change. So harness-gate reads origin's main ONCE
# at start (Landed.pin) and hands every check the answer in PIN_SHA_ENV, keyed
# to the repository by PIN_REPO_ENV (the realpath of its git common dir). A
# check given a pin for ITS repository takes the pin as origin's tip:
#   - the local REF is the pin: the ratchet runs against it;
#   - the local REF descends from the pin (a session sharing this repository
#     fetched mid-run): the ratchet still runs against the PIN, never the
#     local ref;
#   - anything else (behind the pin, diverged from it): Mismatch, as before.
# The bar is still origin's main, as of the gate start. A pin that is set but
# malformed, or half set, is Unreadable, never a fallback. A pin keyed to
# another repository (a fixture repo a self-test builds under the gate) does
# not apply there: that repository reads its own origin live. Run by hand,
# with no pin, a check reads origin itself exactly as before.
#
# ANYONE CAN SET AN ENVIRONMENT VARIABLE, so a pin is not trusted on its own
# (no side channel would help: whatever the gate can hand a child, any caller
# can hand it too; only origin cannot be forged). A pinned check still runs
# its ls-remote and requires the pin to be ON origin's main: origin's tip is
# the pin, or is present here and descends from it. A pin at a commit origin
# never landed (the relabel commit itself) is a Mismatch. Said out loud, the
# residual: a hand-set pin can name an OLDER landed commit, which lowers the
# tip point to that commit's bar; and when origin's current tip has not been
# fetched here, the pin cannot be checked against it and is taken as given.
# harness-gate itself never inherits a pin: it sets both variables from its
# own ls-remote, or clears both.
#
# NOT BEING ABLE TO READ THE BAR IS A FAILURE, never a pass. Every miss raises
# Unreadable carrying each probe and what it gave, so the caller prints "could
# not measure" as a list of places looked, distinct from "0 weakening(s)".
#
# There is no in-repo escape hatch here or in any caller: anything a check could
# read, the diff under test could write. The owner lands a new bar on main, and
# a branch rebased onto it passes.
#
# CONTENT THAT MOVED (DND-539, shared since DND-551). A ratchet keyed on a path
# is blind to a move: the landed path disappears and a "new" entry appears. So
# Landed.rename_pairs traces landed blobs to working-tree files with git's own
# rename detection, `git diff --no-index -M50% -l0`, over copies in a temp dir
# (the repo is only read). The same blob and an edited move alike map. 50% is
# git's default, the "this was moved" verdict `git diff -M`, `log --follow`,
# merges, and the forge all use: lower matches scripts that share only a
# shebang and boilerplate, higher lets a lightly edited copy through. `-l0`
# lifts the rename limit, so a large diff cannot skip detection. A detection
# that fails raises Unreadable ("could not measure"), never "nothing moved".
# Callers: check-guard-messages (a moved guard keeps its bar), check-tool-risk
# (a moved tool keeps its landed class), check-bin-help (an exemption covers
# only its landed content).
#
# Deliberately gem-free (stdlib only).

require "fileutils"
require "open3"
require "tmpdir"

module Landed
  REF = "refs/remotes/origin/main"
  REMOTE = "origin"
  REMOTE_REF = "refs/heads/main"
  LS_REMOTE_PROBE = "git ls-remote #{REMOTE} #{REMOTE_REF}".freeze
  # The bound only stops a hung transport from hanging the gate; hitting it is
  # "could not measure", never a pass.
  LS_REMOTE_TIMEOUT = 30
  # git's own default rename threshold. See "CONTENT THAT MOVED" above.
  RENAME_SIMILARITY = 50
  RENAME_PROBE = "git diff --no-index -M#{RENAME_SIMILARITY}% (rename detection)".freeze
  # The pinned landed ref harness-gate hands its checks. See "ONE READ PER GATE
  # RUN" above.
  PIN_SHA_ENV = "ATHENA_LANDED_PIN_SHA"
  PIN_REPO_ENV = "ATHENA_LANDED_PIN_REPO"
  PIN_PROBE = "#{LS_REMOTE_PROBE}, read once at harness-gate start (#{PIN_SHA_ENV})".freeze

  # The landed bar could not be read. Carries every probe and what it gave.
  class Unreadable < StandardError
    attr_reader :probes

    def initialize(probes)
      @probes = probes
      super("the landed bar could not be read")
    end
  end

  # The local REF disagrees with origin's REMOTE_REF: the bar this checkout
  # would compare against is not the one that landed. source names where the
  # remote SHA came from: a live ls-remote, or the gate's pin.
  class Mismatch < StandardError
    attr_reader :local, :remote, :source

    def initialize(local, remote, source = LS_REMOTE_PROBE)
      @local = local
      @remote = remote
      @source = source
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

  # The repository key a pin is scoped to: the realpath of root's git common
  # dir, the same for a main checkout and every worktree of it. Raises
  # Unreadable when it cannot be computed: a key that cannot be resolved is an
  # error, never "no pin applies".
  def repo_key(root, probes)
    dir, ok = git_read(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    dir = dir.strip
    unless ok && dir.start_with?("/")
      probes << ["git rev-parse --git-common-dir", "failed or not absolute: #{dir.inspect}"]
      raise Unreadable.new(probes)
    end
    File.realpath(dir)
  rescue SystemCallError => e
    probes << ["git rev-parse --git-common-dir", "#{dir.inspect} cannot be resolved: #{e.message}"]
    raise Unreadable.new(probes)
  end

  # The gate's pinned landed ref for root's repository, or nil when there is
  # none for it. Raises Unreadable when the pin is set but malformed or half
  # set. A pin for another repository is recorded as a probe and not applied.
  def pinned_tip(root, probes, env = ENV)
    sha = env[PIN_SHA_ENV]
    repo = env[PIN_REPO_ENV]
    return nil if sha.nil? && repo.nil?

    problem = if sha.nil? || repo.nil?
                "half a pin: #{PIN_SHA_ENV}=#{sha.inspect} #{PIN_REPO_ENV}=#{repo.inspect} (set both or neither)"
              elsif !sha.match?(/\A\h{40}\z/)
                "#{PIN_SHA_ENV}=#{sha.inspect} is not a 40-hex SHA"
              elsif !repo.start_with?("/")
                "#{PIN_REPO_ENV}=#{repo.inspect} is not an absolute path"
              end
    if problem
      probes << [PIN_PROBE, problem]
      raise Unreadable.new(probes)
    end

    key = repo_key(root, probes)
    if key != repo
      probes << [PIN_PROBE, "pinned for #{repo}, not this repository (#{key}); origin read live"]
      return nil
    end
    probes << [PIN_PROBE, sha[0, 12]]
    sha
  end

  # Is ancestor an ancestor of (or equal to) descendant? false when either
  # commit is missing locally.
  def ancestor?(root, ancestor, descendant)
    _out, ok = git_read(root, "merge-base", "--is-ancestor", ancestor, descendant)
    ok
  end

  # Is the pin on origin's main as origin reports it now (remote)? Proven when
  # remote IS the pin, or remote is present here and descends from it. When
  # remote is not present here (origin moved and nothing here fetched it),
  # there is nothing to prove against: the pin is taken as read at gate start,
  # and a probe says so. See "ONE READ PER GATE RUN" for that residual.
  def pin_on_origin?(root, pinned, remote, probes)
    return true if remote == pinned

    _out, present = git_read(root, "cat-file", "-e", "#{remote}^{commit}")
    return ancestor?(root, pinned, remote) if present

    probes << [PIN_PROBE, "origin moved to #{remote[0, 12]}, not fetched here; " \
                          "pin #{pinned[0, 12]} taken as read at gate start"]
    true
  end

  # What harness-gate hands its checks: origin's main for root's repository,
  # read once. Returns { PIN_SHA_ENV => sha, PIN_REPO_ENV => key }. Raises
  # Unreadable, with its probes, when origin or the key cannot be read.
  def pin(root)
    probes = []
    key = repo_key(root, probes)
    { PIN_SHA_ENV => remote_tip(root, probes), PIN_REPO_ENV => key }
  end

  # Resolves the landed points. Returns [points, probes]: points is
  # [[label, sha], ...] (one entry when the tip IS the merge-base), probes the
  # list of what was asked. Raises Unreadable on any miss, Mismatch when the
  # local tip is not origin's (or, pinned, neither the pin nor a descendant).
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

    pinned = pinned_tip(root, probes)
    remote = remote_tip(root, probes)
    if pinned
      raise Mismatch.new(tip, pinned, PIN_PROBE) unless tip == pinned || ancestor?(root, pinned, tip)
      # A pin anyone could set: it must still be on origin's main.
      raise Mismatch.new(tip, remote) unless pin_on_origin?(root, pinned, remote, probes)

      # The bar is the pin, never a local ref that moved past it.
      tip = pinned
    else
      raise Mismatch.new(tip, remote) unless remote == tip
    end

    mb, ok = git_read(root, "merge-base", "HEAD", tip)
    mb = mb.strip
    unreadable.call("merge-base(HEAD, origin/main)", "no common ancestor (or no HEAD commit)") if !ok || mb.empty?
    probes << ["merge-base(HEAD, origin/main)", mb[0, 12]]

    pinned_note = pinned ? " (pinned at harness-gate start)" : ""
    pts = if mb == tip
            [["origin/main tip#{pinned_note} = merge-base(HEAD, origin/main)", tip]]
          else
            [["origin/main (tip)#{pinned_note}", tip], ["merge-base(HEAD, origin/main)", mb]]
          end
    [pts, probes]
  end

  # The blob sha of path at commit sha, or nil when the commit's tree has no
  # such path. "No such path" is a MEASUREMENT (it had not landed at that
  # point); anything else that stops the read raises Unreadable.
  def blob_at(root, sha, path, label)
    listing, ok = git_read(root, "ls-tree", "-z", sha, "--", path)
    raise Unreadable.new([[label, "#{sha[0, 12]}: git ls-tree failed for #{path}"]]) unless ok

    row = listing.split("\0").find { |r| r.split("\t", 2)[1] == path }
    return nil unless row

    _mode, type, blob = row.split("\t", 2)[0].split(" ")
    raise Unreadable.new([[label, "#{sha[0, 12]}: #{path} is a #{type}, not a file"]]) unless type == "blob"

    blob
  end

  # The text of path at commit sha, or nil when the commit's tree has no such
  # path (see blob_at).
  def file_at(root, sha, path, label)
    blob = blob_at(root, sha, path, label)
    return nil unless blob

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
     "remote URL, credentials) and re-run: the check never falls back to the local ref. " \
     "If a probe names a malformed landed file, the bar on main itself is broken: it is " \
     "repaired on main, then this branch rebases onto it."]
  end

  # The failure lines for a local tip that is not origin's. source is where
  # the remote SHA came from (Mismatch#source).
  def mismatch_lines(local, remote, source = LS_REMOTE_PROBE)
    ["  the local landed ref disagrees with origin, so it is not the landed bar and no " \
     "weakening was measured:",
     "    #{REF} (local) -> #{local}",
     "    #{source} -> #{remote}",
     "  Fix: `git fetch #{REMOTE}` so #{REF} matches what landed, rebase onto " \
     "it, and re-run. A local ref moved by hand (git update-ref) does not move the bar, " \
     "and neither does a hand-set #{PIN_SHA_ENV}: the check compares against origin's " \
     "#{REMOTE_REF} (under harness-gate, as read once at gate start, and still required " \
     "to be on origin's #{REMOTE_REF})."]
  end

  # [[tag, rel, score]] for every (landed blob -> working-tree file) pair git's
  # rename detection finds. sources is [[tag, blob_sha], ...] (a tag may carry
  # several blobs, one per landed point); added is [rel, ...] under root. Git
  # pairs each file with at most one source: exact matches first, then the best
  # score. Runs on copies in a temp dir, so no index, object, or ref is
  # written. Raises Unreadable when detection cannot run.
  def rename_pairs(root, sources, added)
    return [] if sources.empty? || added.empty?

    Dir.mktmpdir("landed-renames-") do |tmp|
      src_names = write_rename_side(File.join(tmp, "src"), "s", sources) do |(_tag, blob)|
        text, ok = git_read(root, "cat-file", "blob", blob)
        raise Unreadable.new([[RENAME_PROBE, "git cat-file blob #{blob[0, 12]} failed"]]) unless ok

        text
      end
      dst_names = write_rename_side(File.join(tmp, "dst"), "d", added) { |rel| File.binread(File.join(root, rel)) }
      out, err, status = Open3.capture3("git", "diff", "--no-index", "--no-ext-diff", "-M#{RENAME_SIMILARITY}%",
                                        "-l0", "--name-status", "-z", "src", "dst", chdir: tmp)
      # --no-index exits 1 both for "differences found" and for an error, so a
      # non-empty stderr is what tells them apart.
      unless [0, 1].include?(status.exitstatus) && err.strip.empty?
        raise Unreadable.new([[RENAME_PROBE, "failed (exit #{status.exitstatus}): #{err.strip}"]])
      end

      parse_renames(out).map { |src, dst, score| [src_names.fetch(src)[0], dst_names.fetch(dst), score] }
    end
  rescue Errno::ENOENT
    raise Unreadable.new([[RENAME_PROBE, "git executable not found on PATH"]])
  end

  # The similarity score (100 for the same blob) at which the working-tree file
  # rel carries one of blobs' content, or nil when it maps to none of them.
  # One file against one tag's blobs, so git cannot pair rel with some other
  # tag's content instead. Raises Unreadable when it cannot be measured.
  def maps_to(root, blobs, rel)
    out, ok = git_read(root, "hash-object", "--", rel)
    raise Unreadable.new([[RENAME_PROBE, "git hash-object #{rel} failed"]]) unless ok
    return 100 if blobs.include?(out.strip)

    pair = rename_pairs(root, blobs.map { |blob| [blob, blob] }, [rel]).first
    pair && pair[2]
  end

  # Writes one file per item under dir, named <prefix><n>, from the block's
  # content. Returns { "<side>/<name>" => item }.
  def write_rename_side(dir, prefix, items)
    FileUtils.mkdir_p(dir)
    side = File.basename(dir)
    items.each_with_index.to_h do |item, i|
      name = format("%s%05d", prefix, i)
      File.binwrite(File.join(dir, name), yield(item))
      ["#{side}/#{name}", item]
    end
  end

  # [[src, dst, score]] from `--name-status -z` output: "R<score>\0src\0dst\0".
  def parse_renames(out)
    tokens = out.split("\0")
    renames = []
    until tokens.empty?
      status = tokens.shift
      paths = tokens.shift(status.start_with?("R", "C") ? 2 : 1)
      renames << [paths[0], paths[1], status[1..].to_i] if status.start_with?("R")
    end
    renames
  end
end
