# frozen_string_literal: true

# experiment_git -- the read-only git SIDE EFFECTS of scripts/experiment
# (DND-1478). Every reader returns a LeadTimePhases::Source, so "could not
# look" (no repo, no main ref, git failed) never reads as "looked, found
# nothing". Parsing a commit body is the domain's
# (LeadTimeExperiment.revert_refs).

require "open3"
require_relative "../../../lib/lead_time_phases"
require_relative "experiment"

module LeadTimeExperimentGit
  Source = LeadTimePhases::Source
  SEP = "\x1e" # between commits
  FS = "\x1f"  # between a commit's subject and body

  module_function

  # The repo's main ref: origin/main, else main. -> [ref, nil] | [nil, reason]
  def main_ref(repo)
    return [nil, "#{repo} is not on this machine"] unless File.directory?(repo)

    ref = %w[origin/main main].find do |r|
      _, _, st = Open3.capture3("git", "-C", repo, "rev-parse", "--verify", "-q", "#{r}^{commit}")
      st.success?
    end
    ref ? [ref, nil] : [nil, "neither origin/main nor main resolves in #{repo}"]
  rescue SystemCallError => e
    [nil, "git could not run (#{e.message})"]
  end

  # Whether sha is on the repo's main. Source.ok([true|false]).
  def on_main(repo, sha)
    ref, why = main_ref(repo)
    return Source.could_not_look(why) unless ref

    _, _, known = Open3.capture3("git", "-C", repo, "cat-file", "-e", "#{sha}^{commit}")
    return Source.ok([false]) unless known.success? # an object this clone has never seen

    _, err, st = Open3.capture3("git", "-C", repo, "merge-base", "--is-ancestor", sha, ref)
    return Source.ok([true]) if st.success?
    return Source.ok([false]) if st.exitstatus == 1

    Source.could_not_look("git merge-base in #{repo} failed (#{err.strip.lines.first.to_s.strip})")
  rescue SystemCallError => e
    Source.could_not_look("git could not run (#{e.message})")
  end

  # [[subject, body], ...] on main's first-parent history in a time window.
  def commits(repo, since, until_t)
    ref, why = main_ref(repo)
    return Source.could_not_look(why) unless ref

    out, err, st = Open3.capture3("git", "-C", repo, "log", "--first-parent", "--format=%s#{FS}%b#{SEP}",
                                  "--since=#{since}", "--until=#{until_t}", ref)
    return Source.could_not_look("git log in #{repo} failed (#{err.strip.lines.first.to_s.strip})") unless st.success?

    Source.ok(out.split(SEP).map(&:strip).reject(&:empty?).map { |c| c.split(FS, 2).map(&:to_s) })
  rescue SystemCallError => e
    Source.could_not_look("git could not run (#{e.message})")
  end

  # The "Revert" subjects in a window, leaving out reverts of an
  # experiment's own commit (step 2's revert is the loop acting, not a
  # quality signal; counting it would cascade into every other experiment).
  def reverts(repo, since, until_t, experiment_shas)
    src = commits(repo, since, until_t)
    return src if src.could_not_look?

    Source.ok(src.items.select { |subject, body| subject.start_with?("Revert") && (LeadTimeExperiment.revert_refs(body) & experiment_shas).empty? }
                       .map(&:first))
  end

  # A commit's line counts against its first parent (DND-1549):
  # Source.ok([[added | nil, deleted | nil, path], ...]), nil for a binary
  # file. Renames are split into a delete and an add, so an added test is
  # seen under its new path. Which paths are tests is the domain's
  # (LeadTimeExperiment.test_additions).
  def numstat(repo, sha)
    return Source.could_not_look("#{repo} is not on this machine") unless File.directory?(repo)

    out, err, st = Open3.capture3("git", "-C", repo, "show", "--numstat", "-z", "--no-renames", "--format=",
                                  "--diff-merges=first-parent", "#{sha}^{commit}")
    return Source.could_not_look("git show #{sha.to_s[0, 12]} in #{repo} failed (#{err.strip.lines.first.to_s.strip})") unless st.success?

    entries = out.split("\0").map { |e| e.sub(/\A\n+/, "") }.reject(&:empty?).map { |e| numstat_entry(e) }
    odd = entries.find { |_, _, path| path.empty? }
    return Source.could_not_look("git show #{sha.to_s[0, 12]} in #{repo}: a numstat entry with no path") if odd

    Source.ok(entries)
  rescue SystemCallError => e
    Source.could_not_look("git could not run (#{e.message})")
  end

  def numstat_entry(entry)
    added, deleted, path = entry.split("\t", 3)
    [count(added), count(deleted), path.to_s]
  end

  def count(field) = field.to_s.match?(/\A\d+\z/) ? Integer(field, 10) : nil

  # Whether main carries a commit reverting sha. Source.ok([true|false]).
  def reverted?(repo, sha)
    ref, why = main_ref(repo)
    return Source.could_not_look(why) unless ref

    out, err, st = Open3.capture3("git", "-C", repo, "log", "--first-parent", "--format=%b#{SEP}", "-F",
                                  "--grep=This reverts commit #{sha}", ref)
    return Source.could_not_look("git log in #{repo} failed (#{err.strip.lines.first.to_s.strip})") unless st.success?

    Source.ok([out.split(SEP).any? { |b| LeadTimeExperiment.revert_refs(b).include?(sha) }])
  rescue SystemCallError => e
    Source.could_not_look("git could not run (#{e.message})")
  end
end
