# frozen_string_literal: true

# experiment_git_test -- the git adapters answer for the repo they are given
# even when the caller's environment carries GIT_DIR / GIT_WORK_TREE /
# GIT_INDEX_FILE for ANOTHER repo (DND-1602). git reads those before -C, so a
# leak made every reader answer for the wrong repo with exit 0.

require "tmpdir"
require "open3"
require "fileutils"
require_relative "../lib/experiment_git"
require_relative "../../../lib/lead_time_phases_io"
require_relative "../../../lib/lead_time_config_io"

G = LeadTimeExperimentGit

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

HERMETIC = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_DIR" => nil, "GIT_WORK_TREE" => nil,
             "GIT_INDEX_FILE" => nil }.freeze

def git(repo, *args)
  out, err, st = Open3.capture3(HERMETIC, "git", "-C", repo, *args)
  raise "git #{args.join(' ')} failed: #{err}" unless st.success?

  out.strip
end

def make_repo(dir, file)
  FileUtils.mkdir_p(dir)
  git(dir, "init", "-q", "-b", "main")
  git(dir, "config", "user.email", "t@example.invalid")
  git(dir, "config", "user.name", "t")
  File.write(File.join(dir, file), "one\ntwo\n")
  git(dir, "add", file)
  git(dir, "commit", "-q", "-m", "add #{file}")
  git(dir, "rev-parse", "HEAD")
end

# Run the block with the given variables set in this process's environment
# (so every child git inherits them), then restore.
def with_env(vars)
  saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  vars.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| ENV[k] = v }
end

Dir.mktmpdir("expgit-") do |tmp|
  a = File.join(tmp, "a")
  b = File.join(tmp, "b")
  sha_a = make_repo(a, "alpha.txt")
  sha_b = make_repo(b, "beta.txt")

  c = File.join(tmp, "c")
  sha_c = make_repo(c, "gamma.txt")
  git(c, "commit", "-q", "--allow-empty", "-m", "Revert \"add gamma.txt\"", "-m", "This reverts commit #{sha_c}.")

  leak = { "GIT_DIR" => File.join(b, ".git"), "GIT_WORK_TREE" => b, "GIT_INDEX_FILE" => File.join(b, ".git", "index") }

  check("baseline: on_main answers for repo A") { G.on_main(a, sha_a).items == [true] }

  with_env(leak) do
    check("a leaked GIT_DIR does not change what on_main answers for repo A") { G.on_main(a, sha_a).items == [true] }
    check("a leaked GIT_DIR does not make repo B's commit look on A's main") { G.on_main(a, sha_b).items == [false] }
    check("a leaked GIT_DIR does not change numstat's repo") { G.numstat(a, sha_a).items == [[2, 0, "alpha.txt"]] }
    check("a leaked GIT_DIR does not change message's repo") { G.message(a, sha_a).items == ["add alpha.txt\n\n"] }
    check("a leaked GIT_DIR does not change landed_file's repo") { G.landed_file(a, "alpha.txt").items&.first == "one\ntwo\n" }
    check("a leaked GIT_DIR does not change reverted?'s repo") { G.reverted?(c, sha_c).items == [true] }
    check("a leaked GIT_DIR does not change contains?'s repo") { G.contains?(a, sha_a, sha_a).items == [true] }
    check("a leaked GIT_DIR does not change landed_at's repo") { G.landed_at(a, sha_a).items.map(&:first) == [sha_a] }
    check("a leaked GIT_DIR does not change commits' repo") do
      G.commits(a, "2000-01-01T00:00:00Z", "2030-01-01T00:00:00Z").items.map(&:first) == ["add alpha.txt"]
    end
    check("a leaked GIT_DIR does not change trailer_commits' repo") do
      G.trailer_commits(a, "2000-01-01T00:00:00Z").items.map(&:first) == [sha_a]
    end
    check("a leaked GIT_DIR does not change the phases adapter's common dir") do
      LeadTimePhasesIO::Git.common_dir(a).first == File.realpath(File.join(a, ".git"))
    end
    check("a leaked GIT_DIR does not change the phases adapter's revert count repo") do
      LeadTimePhasesIO::RevertCounter.count(c, "2000-01-01T00:00:00Z", "2030-01-01T00:00:00Z").items.size == 1
    end
  end
end

if $failures.empty?
  puts "experiment_git_test: #{$checks} checks ok"
else
  puts $failures.map { |f| "FAIL #{f}" }
  puts "experiment_git_test: #{$failures.size} of #{$checks} checks FAILED"
  exit 1
end
