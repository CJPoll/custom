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
#   text           one file's lines (gh-athena's and glab-athena's text scan).
#
# Every git call on the OVERLAY scrubs the GIT_* variables a hook inherits, so
# `git -C <overlay>` can never be pointed back at the public repo.
#
# Deliberately gem-free (stdlib only).

require "open3"
require "fileutils"
require_relative "outbound_scan"
require_relative "private_overlay_resolver"
require_relative "outbound_mark"

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

    Surface = Struct.new(:hits, :counts, keyword_init: true)

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

    # The route's URL form (ai/lib/forge-transport/git-remote-athena-forge).
    ROUTE_PREFIX = "athena-forge::"

    # Where a NEW ref's range ends: what the destination already has, read
    # from the destination itself, never from local remote-tracking refs (a
    # push by URL matches none of them, so the whole history read as new:
    # DND-2086). One of:
    #   :listing    the listing the route's transport read from the
    #               destination (--advertised FILE, from forge-push-scan);
    #   :route      the hook as git runs it inside a route push (URL
    #               athena-forge::...). The route's grant is one-shot, so the
    #               hook cannot read the destination; the transport sending
    #               this very push holds the listing and scans these refs
    #               with it, so the hook leaves them to it;
    #   :ls_remote  any other push: `git ls-remote <url>` (:ls_remote_name for
    #               a remote NAME given without --url, by hand).
    Destination = Struct.new(:kind, :source, keyword_init: true)

    def destination(remote, url, advertised)
      target = url || remote
      return Destination.new(kind: :listing, source: advertised) if advertised
      return Destination.new(kind: :route, source: target) if target.start_with?(ROUTE_PREFIX)

      # git always passes the hook the URL; a run by hand with a remote NAME
      # alone lets git resolve the name, so only a URL is checked for a
      # second rewrite.
      Destination.new(kind: url ? :ls_remote : :ls_remote_name, source: target)
    end

    # -> the destination's tip object ids. Raises Unmeasurable (COULD NOT
    # LOOK) when its listing cannot be read: never an empty destination.
    def destination_tips(dest)
      case dest.kind
      when :listing
        text = begin
          File.binread(dest.source)
        rescue SystemCallError, IOError => e
          raise Unmeasurable, "the destination's ref listing #{dest.source} could not be read " \
                              "(#{e.class.name.split('::').last}) (COULD NOT LOOK)"
        end
        OutboundScan.parse_advertisement(text, "the destination's ref listing")
      when :ls_remote, :ls_remote_name
        ls_remote_tips(dest.source, check_url: dest.kind == :ls_remote)
      else
        raise Unmeasurable, "no ref listing can be read for a #{dest.kind} destination (COULD NOT LOOK)"
      end
    end

    LS_REMOTE_ENV = { "GIT_TERMINAL_PROMPT" => "0" }.freeze

    # `git ls-remote <url>` -> tips. git hands the hook a URL its insteadOf and
    # pushInsteadOf rules already rewrote; ls-remote would apply insteadOf to
    # it again and could read another repository than the one pushed to. So
    # the URL ls-remote would use must be the pushed URL itself, or the
    # listing is COULD NOT LOOK.
    def ls_remote_tips(url, check_url:)
      if check_url
        got, _e, st = Open3.capture3(LS_REMOTE_ENV, "git", "ls-remote", "--get-url", "--", url)
        same = st.success? && got.chomp == url
      end
      if check_url && !same
        raise Unmeasurable, "git ls-remote would read a different URL than the one pushed to " \
                            "(an insteadOf rule rewrites it again), so the destination's refs cannot be read (COULD NOT LOOK)"
      end
      out, _err, st = Open3.capture3(LS_REMOTE_ENV, "git", "ls-remote", "--", url, binmode: true)
      unless st.success?
        raise Unmeasurable, "git ls-remote could not read the destination's refs " \
                            "(exit #{st.exitstatus.inspect}), so the range of a new ref is unknown (COULD NOT LOOK)"
      end
      OutboundScan.parse_advertisement(out, "git ls-remote's listing of the destination")
    end

    # Inside a route push the hook leaves a new ref to the transport. That
    # holds only where the transport scans: its fg_outbound_marked
    # (ai/lib/forge-transport/git-remote-athena-forge) scans when any of three
    # pre-push paths holds the outbound marker, or cannot be read. This reads
    # the same three paths with the same marker rule (OutboundMark.classify)
    # in the same environment (the push's). false -> the hook refuses rather
    # than defer to a transport that would not scan.
    def transport_scans?
      common, _e, st = Open3.capture3("git", "rev-parse", "--path-format=absolute", "--git-common-dir")
      return true unless st.success? && !common.strip.empty?

      hook_path = ["git", "rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-push"]
      plain_env = { "GIT_CONFIG_PARAMETERS" => nil, "GIT_CONFIG_COUNT" => nil }
      resolved = [Open3.capture3(*hook_path), Open3.capture3(plain_env, *hook_path)]
      paths = [File.join(common.strip, "hooks", "pre-push")]
      resolved.each do |out, _err, s|
        return true unless s.success? && !out.strip.empty?

        paths << out.strip
      end
      paths.any? do |p|
        next false unless File.exist?(p) # the transport skips an absent (or dangling) path

        %i[marked unknown].include?(OutboundMark.classify(p).first)
      end
    end

    # git's pre-push stdin -> [new commit shas (deduplicated, stable),
    # deletes, refs left to the route's transport].
    def pre_push_commits(stdin_text, dest)
      shas = []
      deletes = 0
      deferred = []
      tips = nil
      scans = nil
      stdin_text.each_line.with_index(1) do |raw, n|
        line = raw.strip
        next if line.empty?

        fields = line.split(" ")
        raise Unmeasurable, "pre-push stdin line #{n} is not '<local ref> <local sha> <remote ref> <remote sha>'" unless fields.length == 4

        _lref, lsha, rref, rsha = fields
        if ZERO_SHA.match?(lsha)
          deletes += 1
          next
        end
        if dest.kind == :route && !known_commit?(rsha)
          scans = transport_scans? if scans.nil?
          unless scans
            raise Unmeasurable, "this route push's transport does not scan (no pre-push path it reads holds the " \
                                "outbound hook), and the hook cannot read the destination inside a route push, so the " \
                                "range of #{rref} is unknown (COULD NOT LOOK)"
          end
          deferred << rref
          next
        end
        shas.concat(range_commits(lsha, rsha) { tips ||= destination_tips(dest) })
      end
      [shas.uniq, deletes, deferred]
    end

    def known_commit?(rsha)
      !ZERO_SHA.match?(rsha) && Open3.capture3("git", "cat-file", "-e", "#{rsha}^{commit}")[2].success?
    end

    # The one range rule, for the hook and the transport alike. A remote tip
    # we have: <remote sha>..<local sha>. A new ref, or a remote tip we do not
    # have: every commit reachable from <local sha> that no destination tip
    # reaches (the block yields the destination's tips). A tip we do not have
    # cannot be an ancestor of a commit we have, so only local commits bound it.
    def range_commits(lsha, rsha)
      return rev_list("#{rsha}..#{lsha}\n") if known_commit?(rsha)

      exclude = local_commits(yield)
      rev_list(([lsha] + exclude.map { |c| "^#{c}" }).join("\n") + "\n")
    end

    def rev_list(stdin)
      out, _err, st = Open3.capture3("git", "rev-list", "--stdin", stdin_data: stdin, binmode: true)
      raise Unmeasurable, "git could not list the commits being pushed" unless st.success?

      out.split("\n").map(&:strip).reject(&:empty?)
    end

    # tips -> those that peel to a commit in this repository.
    def local_commits(tips)
      return [] if tips.empty?

      out, _err, st = Open3.capture3("git", "cat-file", "--batch-check=%(objectname) %(objecttype)",
                                     stdin_data: tips.map { |t| "#{t}^{commit}\n" }.join, binmode: true)
      lines = out.split("\n")
      unless st.success? && lines.length == tips.length
        raise Unmeasurable, "git could not check which of the destination's tips are local commits"
      end

      lines.each_with_object([]) do |l, acc|
        oid, type = l.split(" ", 2)
        if type == "commit" && OutboundScan::OID_RE.match?(oid)
          acc << oid
        elsif type != "missing"
          raise Unmeasurable, "git gave an unexpected answer checking a destination tip"
        end
      end
    end

    # -> Surface for a list of commits.
    def scan_commits(patterns, shas)
      counts = { commits: 0, lines: 0, patterns: patterns.length, hits: 0 }
      hits = []
      shas.each do |sha|
        counts[:commits] += 1
        scan_message(patterns, sha, hits, counts)
        ps = parents(sha)
        scan_paths(patterns, sha, ps, hits)
        scan_diff(patterns, sha, ps, hits, counts)
      end
      counts[:hits] = hits.length
      Surface.new(hits: hits, counts: counts)
    end

    def scan_message(patterns, sha, hits, counts)
      msg = git!("show", "-s", "--format=%B", sha, what: "read the message of commit #{sha[0, 12]}")
      msg.each_line.with_index(1) do |line, n|
        counts[:lines] += 1
        loc = Location.new(kind: :message, line: n, commit: sha)
        hits.concat(OutboundScan.scan_line(patterns, loc, line))
      end
    end

    def parents(sha)
      git!("rev-list", "--parents", "-n", "1", sha, what: "read the parents of #{sha[0, 12]}").split[1..] || []
    end

    # --text: every file's content is diffed as text, so a `-diff` or `binary`
    # attribute the pushed commit itself adds (.gitattributes) cannot turn its
    # own hunks into "Binary files differ" and skip the scan. The bar is not
    # read from the diff under test. --no-textconv/--no-ext-diff keep a
    # `diff=<driver>` attribute from rewriting the text either.
    COMMON_DIFF = %w[--text --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/].freeze

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

    def scan_paths(patterns, sha, ps, hits)
      new_paths(sha, ps).each do |path|
        labels = OutboundScan.labels_matching(patterns, path)
        next if labels.empty?

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

    def scan_diff(patterns, sha, ps, hits, counts)
      out = git!(*diff_argv(sha, ps, %w[-p --unified=0]), what: "read the diff of #{sha[0, 12]}")
      each_added_line(out, [ps.length, 1].max) do |path, n, text|
        counts[:lines] += 1
        loc = Location.new(kind: :content, path: path, line: n, commit: sha)
        hits.concat(OutboundScan.scan_line(patterns, loc, text))
      end
    end

    # Walk a unified (cols=1) or combined (cols=parents) diff made with --text.
    # Yields (path, line_no, text) for each line the commit introduces -- every
    # prefix column '+'. A state machine, so an added line whose text starts
    # with "++ " is content, never a header. A "Binary files" line cannot occur
    # under --text; if git ever prints one, the scan refuses to call it clean.
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
            raise Unmeasurable, "git reported a binary diff despite --text, so a file's content was not shown"
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

          yield path, n, line[cols..].to_s if prefix.delete("+").empty?
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

      spec = spec.chomp("\t") # git appends a TAB when the path has a space
      s = spec.start_with?('"') ? unquote(spec) : spec
      s.sub(%r{\Ab/}, "").dup.force_encoding(Encoding::UTF_8)
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
      counts = { commits: 0, lines: 0, patterns: patterns.length, hits: 0, files: 0 }
      hits = []
      entries = listing.split("\0").reject(&:empty?)
      raise Unmeasurable, "git ls-files listed zero tracked files" if entries.empty?

      entries.each do |entry|
        meta, path = entry.split("\t", 2)
        mode, blob, = meta.split(" ")
        path = path.dup.force_encoding(Encoding::UTF_8)
        counts[:files] += 1
        labels = OutboundScan.labels_matching(patterns, path)
        unless labels.empty?
          loc = Location.new(kind: :path, path: path)
          labels.each { |l| hits << Hit.new(location: loc, label: l) }
        end
        next if mode == "160000"

        # Binary content is scanned as bytes split on newlines, like text: a
        # file cannot opt out of the scan by holding a NUL.
        content = tree_content(top, path, mode, blob)
        content.each_line.with_index(1) do |line, n|
          counts[:lines] += 1
          hits.concat(OutboundScan.scan_line(patterns, Location.new(kind: :content, path: path, line: n), line))
        end
      end
      counts[:hits] = hits.length
      Surface.new(hits: hits, counts: counts)
    end

    # The INDEX copy (what is tracked and will be committed), never the
    # working-tree file: an uncommitted edit that removes a value must not
    # hide the copy git still holds. A symlink's blob is its target text.
    def tree_content(top, _path, _mode, blob)
      git!("-C", top, "cat-file", "blob", blob, what: "read the index copy of a tracked file")
    end

    # ---- the waiver log ----------------------------------------------------------

    def record_waiver(path, fields)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, "a", 0o600) { |f| f.puts fields.join("\t") }
    end

    # ---- text mode --------------------------------------------------------------

    def scan_text(patterns, file, field)
      text = begin
        File.binread(file)
      rescue SystemCallError
        raise Unmeasurable, "the text file to scan (#{field}) is unreadable"
      end
      counts = { commits: 0, lines: 0, patterns: patterns.length, hits: 0 }
      hits = []
      text.each_line.with_index(1) do |line, n|
        counts[:lines] += 1
        hits.concat(OutboundScan.scan_line(patterns, Location.new(kind: :field, field: field, line: n), line))
      end
      counts[:hits] = hits.length
      Surface.new(hits: hits, counts: counts)
    end
  end
end
