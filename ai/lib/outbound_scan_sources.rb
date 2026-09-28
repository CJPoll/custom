# frozen_string_literal: true

# ai/lib/outbound_scan_sources.rb -- the SIDE-EFFECT half of the outbound scan
# (DND-699): it reads the overlay's pattern list and the surfaces to scan, and
# hands every decision to the pure rules in ai/lib/outbound_scan.rb.
#
#   patterns       the UNION of the overlay's working-tree outbound/patterns.tsv
#                  and its committed copy (git show HEAD:outbound/patterns.tsv).
#                  No overlay, no git history, no committed copy, or zero
#                  patterns raises Unmeasurable: it is never an empty pass.
#   pre_push       the commits a `git push` would publish (git's pre-push stdin):
#                  the lines and paths each commit INTRODUCES (a merge: only
#                  what differs from every parent; see diff_argv and the
#                  contract's Surfaces), and its message.
#   tree           every tracked file of the current repo: content and path.
#   text           one file's lines (gh-athena's title/body scan).
#
# Every git call on the OVERLAY scrubs the GIT_* variables a hook inherits, so
# `git -C <overlay>` can never be pointed back at the public repo.
#
# Deliberately gem-free (stdlib only).

require "open3"
require_relative "outbound_scan"
require_relative "private_overlay_resolver"

module OutboundScan
  module Sources
    ZERO_SHA = /\A0+\z/.freeze
    PATTERNS_REL = "outbound/patterns.tsv"
    # Variables that redirect git away from `-C <dir>`. A pre-push hook runs
    # with some of them set for the PUBLIC repo.
    GIT_REDIRECT_VARS = %w[
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_QUARANTINE_PATH
    ].freeze
    BINARY_PROBE = 8000

    Surface = Struct.new(:hits, :counts, :redacted, keyword_init: true)

    module_function

    # -> [patterns] (non-empty). Raises Unmeasurable naming the reason.
    def patterns(env: ENV)
      r = PrivateOverlay::Resolver.root(env: env)
      case r.state
      when :absent
        raise Unmeasurable, "overlay is ABSENT (probed #{r.root})"
      when :malformed
        raise Unmeasurable, "overlay is MALFORMED: #{r.reason} (root #{r.root || '(none)'})"
      end
      root = r.root
      committed = OutboundScan.parse_patterns(committed_text(root), "committed HEAD:#{PATTERNS_REL}")
      set = OutboundScan.union(committed, working_tree_patterns(root))
      raise Unmeasurable, "overlay at #{root} has zero patterns in #{PATTERNS_REL}" if set.empty?

      set
    end

    def working_tree_patterns(root)
      path = File.join(root, PATTERNS_REL)
      return [] unless File.exist?(path)
      raise Unmeasurable, "working-tree #{PATTERNS_REL} in the overlay is not a regular file" unless File.file?(path)

      text = begin
        File.binread(path)
      rescue SystemCallError
        raise Unmeasurable, "working-tree #{PATTERNS_REL} in the overlay is unreadable"
      end
      OutboundScan.parse_patterns(text, "working-tree #{PATTERNS_REL}")
    end

    # The floor. Each way it can be missing is its own reason.
    def committed_text(root)
      top, _err, st = overlay_git(root, "rev-parse", "--show-toplevel")
      unless st.success? && same_dir?(top.strip, root)
        raise Unmeasurable, "overlay at #{root} is not a git repository of its own, so there is no committed floor"
      end
      _o, _e, st = overlay_git(root, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
      raise Unmeasurable, "overlay git repository at #{root} has no commits, so there is no committed floor" unless st.success?

      _o, _e, st = overlay_git(root, "cat-file", "-e", "HEAD:#{PATTERNS_REL}")
      raise Unmeasurable, "overlay at #{root} has no committed #{PATTERNS_REL} (it is not committed in HEAD)" unless st.success?

      text, _e, st = overlay_git(root, "show", "HEAD:#{PATTERNS_REL}")
      raise Unmeasurable, "could not read the committed #{PATTERNS_REL} from the overlay at #{root}" unless st.success?

      text
    end

    def overlay_git(root, *args)
      env = GIT_REDIRECT_VARS.to_h { |k| [k, nil] }
      Open3.capture3(env, "git", "-C", root, *args, binmode: true)
    end

    def same_dir?(a, b)
      File.realpath(a) == File.realpath(b)
    rescue SystemCallError
      false
    end

    # ---- the public repo (cwd) ------------------------------------------------

    def git!(*args, what:)
      out, _err, st = Open3.capture3("git", "-c", "core.quotepath=off", *args, binmode: true)
      raise Unmeasurable, "git could not #{what}" unless st.success?

      out
    end

    # git's pre-push stdin -> list of new commit shas (deduplicated, stable).
    def pre_push_commits(stdin_text, remote)
      shas = []
      deletes = 0
      stdin_text.each_line.with_index(1) do |raw, n|
        line = raw.strip
        next if line.empty?

        fields = line.split(" ")
        raise Unmeasurable, "pre-push stdin line #{n} is not '<local ref> <local sha> <remote ref> <remote sha>'" unless fields.length == 4

        _lref, lsha, _rref, rsha = fields
        if ZERO_SHA.match?(lsha)
          deletes += 1
          next
        end
        shas.concat(range_commits(lsha, rsha, remote))
      end
      [shas.uniq, deletes]
    end

    def range_commits(lsha, rsha, remote)
      known = !ZERO_SHA.match?(rsha) &&
              Open3.capture3("git", "cat-file", "-e", "#{rsha}^{commit}")[2].success?
      args = if known
               ["rev-list", "#{rsha}..#{lsha}"]
             else
               # A new ref, or a remote tip we do not have: everything not
               # already on a remote-tracking ref of this remote. A URL remote
               # matches no tracking ref, so this scans the whole history:
               # conservative, never a miss.
               ["rev-list", lsha, "--not", "--remotes=#{remote}"]
             end
      git!(*args, what: "list the commits being pushed").split("\n").map(&:strip).reject(&:empty?)
    end

    # -> Surface for a list of commits.
    def scan_commits(patterns, shas)
      counts = { commits: 0, lines: 0, patterns: patterns.length, hits: 0, binary: 0 }
      hits = []
      redacted = {}
      matcher = quick_matcher(patterns)
      shas.each do |sha|
        counts[:commits] += 1
        scan_message(patterns, matcher, sha, hits, counts)
        ps = parents(sha)
        scan_paths(patterns, sha, ps, hits, redacted)
        scan_diff(patterns, matcher, sha, ps, hits, counts)
      end
      counts[:hits] = hits.length
      Surface.new(hits: hits, counts: counts, redacted: redacted)
    end

    def scan_message(patterns, matcher, sha, hits, counts)
      msg = git!("show", "-s", "--format=%B", sha, what: "read the message of commit #{sha[0, 12]}")
      msg.each_line.with_index(1) do |line, n|
        counts[:lines] += 1
        next unless quick?(matcher, line)

        loc = Location.new(kind: :message, line: n, commit: sha)
        hits.concat(OutboundScan.scan_line(patterns, loc, line))
      end
    end

    def parents(sha)
      git!("rev-list", "--parents", "-n", "1", sha, what: "read the parents of #{sha[0, 12]}").split[1..] || []
    end

    COMMON_DIFF = %w[--no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/].freeze

    # The full git argv for what this commit INTRODUCES, with `extra` flags:
    #   root commit   its whole tree (diff-tree --root);
    #   one parent    its diff against that parent, renames detected;
    #   a merge       a combined diff (--cc): only what differs from EVERY
    #                 parent. Content the merge carries in from a parent is that
    #                 parent's: it is scanned where that parent is new, and is
    #                 already public where it is not. A conflict resolution
    #                 (text in no parent) is what --cc shows.
    def diff_argv(sha, ps, extra)
      if ps.empty?
        ["diff-tree", "-r", "--root", "--no-commit-id", "-M", *COMMON_DIFF, *extra, sha]
      elsif ps.length == 1
        ["diff", "-M", *COMMON_DIFF, *extra, ps.first, sha]
      else
        ["diff-tree", "-r", "--cc", "--no-commit-id", *COMMON_DIFF, *extra, sha]
      end
    end

    def scan_paths(patterns, sha, ps, hits, redacted)
      new_paths(sha, ps).each do |path|
        labels = OutboundScan.labels_matching(patterns, path)
        next if labels.empty?

        redacted[path] = true
        loc = Location.new(kind: :path, path: path, commit: sha)
        labels.each { |l| hits << Hit.new(location: loc, label: l) }
      end
    end

    # Paths the commit adds or renames to. For a merge: paths that differ from
    # every parent (a path a parent brought in is that parent's).
    def new_paths(sha, ps)
      if ps.length > 1
        out = git!(*diff_argv(sha, ps, %w[--name-only -z]), what: "list the paths of merge #{sha[0, 12]}")
        return out.split("\0").reject(&:empty?).map { |p| p.dup.force_encoding(Encoding::UTF_8) }
      end
      out = git!(*diff_argv(sha, ps, %w[--name-status -z]), what: "list the paths of #{sha[0, 12]}")
      fields = out.split("\0")
      paths = []
      i = 0
      while i < fields.length
        status = fields[i]
        width = status.start_with?("R", "C") ? 3 : 2
        path = fields[i + width - 1]
        paths << path.dup.force_encoding(Encoding::UTF_8) if path && status.start_with?("A", "R", "C")
        i += width
      end
      paths
    end

    def scan_diff(patterns, matcher, sha, ps, hits, counts)
      out = git!(*diff_argv(sha, ps, %w[-p --unified=0]), what: "read the diff of #{sha[0, 12]}")
      each_added_line(out, [ps.length, 1].max) do |kind, path, n, text|
        if kind == :binary
          counts[:binary] += 1
          next
        end
        counts[:lines] += 1
        next unless quick?(matcher, text)

        loc = Location.new(kind: :content, path: path, line: n, commit: sha)
        hits.concat(OutboundScan.scan_line(patterns, loc, text))
      end
    end

    # Walk a unified (cols=1) or combined (cols=parents) diff. Yields
    # (:add, path, line_no, text) for each line the commit introduces -- every
    # prefix column '+' -- and (:binary, path) for a binary file. A state
    # machine, so an added line whose text starts with "++ " is content, never
    # a header.
    def each_added_line(diff, cols = 1)
      state = :none
      path = nil
      n = 0
      diff.each_line do |raw|
        line = raw.chomp
        if line.start_with?("diff --git ", "diff --cc ", "diff --combined ")
          state = :header
          path = nil
          next
        end
        case state
        when :header
          if line.start_with?("+++ ")
            path = diff_path(line[4..])
          elsif line.start_with?("Binary files ")
            yield :binary, path, 0, nil
          elsif line.start_with?("@@")
            state = :hunk
            n = hunk_start(line)
          end
        when :hunk
          if line.start_with?("@@")
            n = hunk_start(line)
            next
          end
          prefix = line[0, cols].to_s
          next if prefix.length < cols || prefix.start_with?("\\")
          next if prefix.include?("-") # a removed line: not in the result

          yield :add, path, n, line[cols..].to_s if prefix.delete("+").empty?
          n += 1
        end
      end
    end

    def hunk_start(line)
      m = line.match(/\A@@+ (?:-\d+(?:,\d+)? )+\+(\d+)/)
      raise Unmeasurable, "a diff hunk header could not be parsed" unless m

      Integer(m[1], 10)
    end

    def diff_path(spec)
      return nil if spec == "/dev/null"

      s = spec.start_with?('"') ? unquote(spec) : spec
      s.sub(%r{\Ab/}, "")
    end

    # git's C-style path quoting.
    def unquote(s)
      body = s[1...-1] || ""
      out = +"".b
      i = 0
      while i < body.length
        c = body[i]
        if c == "\\" && i + 1 < body.length
          nxt = body[i + 1]
          if nxt =~ /[0-7]/
            out << body[i + 1, 3].to_i(8).chr
            i += 4
            next
          end
          out << ({ "n" => "\n", "t" => "\t", "\\" => "\\", '"' => '"', "a" => "\a", "b" => "\b", "f" => "\f", "r" => "\r", "v" => "\v" }[nxt] || nxt)
          i += 2
        else
          out << c.b
          i += 1
        end
      end
      out.force_encoding(Encoding::UTF_8)
    end

    # ---- tree mode --------------------------------------------------------------

    def scan_tree(patterns)
      top = git!("rev-parse", "--show-toplevel", what: "find the repository top level").strip
      listing = git!("-C", top, "ls-files", "-z", "-s", what: "list the tracked files")
      counts = { commits: 0, lines: 0, patterns: patterns.length, hits: 0, binary: 0, files: 0 }
      hits = []
      redacted = {}
      matcher = quick_matcher(patterns)
      entries = listing.split("\0").reject(&:empty?)
      raise Unmeasurable, "git ls-files listed zero tracked files" if entries.empty?

      entries.each do |entry|
        meta, path = entry.split("\t", 2)
        mode, blob, = meta.split(" ")
        path = path.dup.force_encoding(Encoding::UTF_8)
        counts[:files] += 1
        labels = OutboundScan.labels_matching(patterns, path)
        unless labels.empty?
          redacted[path] = true
          loc = Location.new(kind: :path, path: path)
          labels.each { |l| hits << Hit.new(location: loc, label: l) }
        end
        next if mode == "160000"

        content = tree_content(top, path, mode, blob)
        if content.byteslice(0, BINARY_PROBE).include?("\0")
          counts[:binary] += 1
          next
        end
        content.each_line.with_index(1) do |line, n|
          counts[:lines] += 1
          next unless quick?(matcher, line)

          hits.concat(OutboundScan.scan_line(patterns, Location.new(kind: :content, path: path, line: n), line))
        end
      end
      counts[:hits] = hits.length
      Surface.new(hits: hits, counts: counts, redacted: redacted)
    end

    def tree_content(top, path, mode, blob)
      abs = File.join(top, path)
      return File.readlink(abs).b if mode == "120000" && File.symlink?(abs)
      return File.binread(abs) if mode != "120000" && File.file?(abs) && !File.symlink?(abs)

      git!("-C", top, "cat-file", "blob", blob, what: "read the index copy of a tracked file")
    rescue SystemCallError
      git!("-C", top, "cat-file", "blob", blob, what: "read the index copy of a tracked file")
    end

    # ---- text mode --------------------------------------------------------------

    def scan_text(patterns, file, field)
      text = begin
        File.binread(file)
      rescue SystemCallError
        raise Unmeasurable, "the text file to scan (#{field}) is unreadable"
      end
      counts = { commits: 0, lines: 0, patterns: patterns.length, hits: 0, binary: 0 }
      hits = []
      text.each_line.with_index(1) do |line, n|
        counts[:lines] += 1
        hits.concat(OutboundScan.scan_line(patterns, Location.new(kind: :field, field: field, line: n), line))
      end
      counts[:hits] = hits.length
      Surface.new(hits: hits, counts: counts, redacted: {})
    end

    # ---- a cheap pre-filter -------------------------------------------------------

    def quick_matcher(patterns)
      Regexp.new(Regexp.union(patterns.map(&:regex)).source, timeout: MATCH_TIMEOUT)
    end

    def quick?(matcher, text)
      matcher.match?(OutboundScan.normalise(text))
    rescue Regexp::TimeoutError
      raise Unmeasurable, "a pattern exceeded the #{MATCH_TIMEOUT}s match budget"
    end
  end
end
