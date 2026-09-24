# frozen_string_literal: true

# ai/lib/first_party.rb — WHICH FILES ARE FIRST-PARTY CODE in this repo.
#
# One definition, meant for every check that needs "every first-party
# executable": ai/bin/check-guard-messages (DND-218, which classifies them) and
# ai/bin/harness-gate (DND-507, which asserts every inline --self-test they
# define is run). Two checks that each keep their own idea of the scope drift
# apart silently: one of them stops reading a directory, and prints OK anyway.
#
# PROVENANCE AND RECONCILIATION. This is check-guard-messages' `discover`,
# extracted as a library, including DND-512's untracked-third-party rule; the
# bodies match check-guard-messages as of 0e8fab3. check-guard-messages still
# carries its own copy (DND-512 was editing it while this was written, so it was
# left alone), so for now the two are parallel copies of ONE rule. The
# follow-up is to make check-guard-messages `require_relative
# "../lib/first_party"` and delete its copy. Until then, a change to either
# copy's rule must be made in both.
#
# THE RULE. A candidate is a path `git ls-files` returns that is a regular file
# (never a symlink) and is executable, or lives under a lib/ or wt-lib/
# directory (sourced code), or is an ai/hooks/*.sh. Two sources:
#   - TRACKED paths (`--cached`: committed or staged) are always candidates.
#   - UNTRACKED paths (`--others --exclude-standard`) are candidates only when
#     no directory segment marks a package manager's install output
#     (node_modules, .venv, vendor/bundle). Those are returned separately as
#     `skipped` so a caller can count them; nothing is dropped silently.
#
# Not being able to ask git is a MeasureError, never an empty result: an empty
# first-party set would read as "nothing to check" and pass every caller.
#
# Deliberately gem-free (stdlib only).

require "open3"

module FirstParty
  MeasureError = Class.new(StandardError)

  # Sourced code is discovered even though it is not executable.
  LIB_SEGMENTS = %w[lib wt-lib].freeze

  # Package-manager install directories. An UNTRACKED path with one of these
  # segments is third-party and skipped; a tracked one is still a candidate.
  THIRD_PARTY_SEGMENTS  = %w[node_modules .venv].freeze
  THIRD_PARTY_SEQUENCES = [%w[vendor bundle]].freeze

  module_function

  def segments(rel)
    rel.split("/")
  end

  # A test suite: a `test/` directory segment, or a `*.self-test.sh` file.
  def test_path?(rel)
    segs = segments(rel)
    segs[0..-2].include?("test") || segs.last.end_with?(".self-test.sh")
  end

  def lib_path?(rel)
    (segments(rel)[0..-2] & LIB_SEGMENTS).any?
  end

  def hook_script?(rel)
    rel.start_with?("ai/hooks/") && rel.end_with?(".sh")
  end

  def third_party_path?(rel)
    dirs = segments(rel)[0..-2]
    return true if (dirs & THIRD_PARTY_SEGMENTS).any?

    THIRD_PARTY_SEQUENCES.any? { |seq| dirs.each_cons(seq.size).include?(seq) }
  end

  # Paths git lists for one ls-files mode.
  def git_ls(root, *mode)
    out, err, status = Open3.capture3("git", "-C", root, "ls-files", "-z", *mode)
    raise MeasureError, "git -C #{root} ls-files #{mode.join(' ')} failed: #{err.strip}" unless status.success?

    out.split("\0").uniq
  rescue Errno::ENOENT
    raise MeasureError, "git executable not found on PATH"
  end

  def candidate?(root, rel)
    abs = File.join(root, rel)
    return false if File.symlink?(abs) || !File.file?(abs)

    File.executable?(abs) || lib_path?(rel) || hook_script?(rel)
  end

  # [found, skipped]: found is every first-party candidate, sorted; skipped is
  # every untracked third-party path that would otherwise have been one.
  def discover(root)
    tracked = git_ls(root, "--cached")
    untracked = git_ls(root, "--others", "--exclude-standard") - tracked
    third_party, new_files = untracked.partition { |rel| third_party_path?(rel) }
    found = (tracked + new_files).uniq.select { |rel| candidate?(root, rel) }.sort
    [found, third_party.select { |rel| candidate?(root, rel) }.sort]
  end

  # The entry points: discovered, executable, and not a test suite. Sourced
  # libraries are not entry points; test suites are run by discovery, not
  # checked for flags.
  def executables(root)
    found, skipped = discover(root)
    tools = found.reject { |rel| test_path?(rel) }
                 .select { |rel| File.executable?(File.join(root, rel)) }
    [tools, found, skipped]
  end
end
