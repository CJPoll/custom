# frozen_string_literal: true

# plain_git_scan.rb — the source half of DND-1977's class test.
#
# Usage: ruby plain_git_scan.rb <repo root> <allowlist.tsv>
#
# Lists every tracked file under ai/, scripts/ and git-custom/ (tests, prose
# and data aside) and reports each place that RUNS git's fetch, pull or
# ls-remote with plain git rather than ai/bin/forge-git:
#   - shell: a `git` command word followed by one of them, read with every
#     quoted string ('…', "…", `…`) blanked out, so message text never
#     matches and `git … || die "…"` still does; a `git ls-remote --get-url`
#     command is blanked first, because it prints the configured URL and
#     opens no transport (a real read later on the same line still matches);
#   - Ruby: an argv array that names "git" and then "fetch" / "ls-remote" /
#     "pull" within three joined lines (a call split over lines), or a git
#     helper call (call, Git.call, git_ok, git_status) naming one. A window
#     that also names FORGE_GIT / forge_git is the routed form.
# Each hit must match an allowlist row (path, a substring of the hit's first
# line, the reason); a row that matches nothing is stale. Exit 0 clean, 1 hits
# or stale rows, 3 could not look (no tracked files). Prints what it scanned.
#
# Residuals, said out loud: a git command word held in a variable ("$GIT"
# fetch), an argv built across more than three lines, and prose an agent
# follows (a SKILL.md) are not read here. Part D of the suite drives the
# runtime paths that use the first form.

require "open3"

root, allow_path = ARGV
abort "usage: plain_git_scan.rb <root> <allowlist.tsv>\nFix: pass the repo root and the allowlist" unless root && allow_path

files, st = Open3.capture2("git", "-C", root, "ls-files", "ai", "scripts", "git-custom")
if !st.success? || files.strip.empty?
  puts "COULD NOT LOOK: git ls-files under #{root} listed nothing"
  puts "Fix: run the suite from a git checkout of the harness."
  exit 3
end

SKIP = %r{(/test/|self-test|\.md\z|\.json\z|\.jsonl\z|\.tsv\z|\.yml\z|\.txt\z)}
NET = "(?:fetch|pull|ls-remote)"
# A command word position: line start, after ; & | ( ! { $( or a keyword, or
# after a `timeout N` / `env` / VAR=value prefix.
SH = /(?:^|[;&|(!{]|\$\(|\bthen\s|\bdo\s|\belse\s)\s*(?:(?:timeout(?:\s+-\S+)*\s+\d+\S*|env|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*git(?:\s+(?:-C\s+\S+|-c\s+\S+|-q|--\S+))*\s+#{NET}\b/
# `ls-remote --get-url` prints the configured URL (insteadOf applied) and
# exits; it opens no transport, so it is a local config read, not a remote one.
SH_LOCAL = /\bgit(?:\s+(?:-C\s+[^\s;&|()]+|-c\s+[^\s;&|()]+|-q|--[^\s;&|()]+))*\s+ls-remote(?:\s+-[^\s;&|()]+)*\s+--get-url(?=\s|$|\))/
RB_ARGV = /"git"\s*,[^\]]*?"#{NET}"/m
RB_CALL = /\b(?:Git\.call|call|git_ok|git_status)\(\s*[^)]*"#{NET}"/
ROUTED = /FORGE_GIT|forge_git/

# Does an argv match START on the window's first line (so each split argv is
# reported once, at its own line)?
def argv_starts_here?(window, first_len)
  m = RB_ARGV.match(window)
  !m.nil? && m.begin(0) < first_len
end

# A command substitution inside double quotes ("$(git … fetch)") is code, not
# text: open it up before the quoted strings are blanked.
def dequote(line)
  line.gsub('"$(', '$(').gsub(')"', ')').gsub(/"(?:[^"\\]|\\.)*"/, "Q").gsub(/'[^']*'/, "Q").gsub(/`[^`]*`/, "Q")
end

allow = File.readlines(allow_path, chomp: true).reject(&:empty?).map { |l| l.split("\t", 3) }
used = Array.new(allow.size, false)
hits = []
scanned = 0

files.split("\n").each do |rel|
  next if rel.match?(SKIP)

  path = File.join(root, rel)
  next unless File.file?(path)

  text = File.binread(path)
  next if text.include?("\0")

  scanned += 1
  lines = text.force_encoding("UTF-8").scrub.split("\n")
  lines.each_with_index do |line, i|
    next if line.lstrip.start_with?("#")

    window = lines[i, 3].join("\n")
    found = dequote(line).gsub(SH_LOCAL, "Q").match?(SH) ||
            (line.include?('"git"') && argv_starts_here?(window, line.length) && !window.match?(ROUTED)) ||
            (line.match?(RB_CALL) && !line.match?(ROUTED))
    next unless found

    k = allow.index { |ap, sub, _| ap == rel && line.include?(sub.to_s) }
    if k
      used[k] = true
    else
      hits << "#{rel}:#{i + 1}: #{line.strip}"
    end
  end
end

stale = allow.each_index.reject { |k| used[k] }.map { |k| "#{allow[k][0]}: #{allow[k][1]}" }
puts "scanned #{scanned} tracked file(s) under ai/, scripts/, git-custom/"
hits.each { |h| puts "PLAIN #{h}" }
stale.each { |s| puts "STALE #{s}" }
unless hits.empty? && stale.empty?
  puts "Fix: route each PLAIN read through ai/bin/forge-git (or allowlist an owner-run one with its reason); drop or update each STALE row."
  exit 1
end
