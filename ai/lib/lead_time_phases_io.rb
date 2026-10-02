# frozen_string_literal: true

# lead_time_phases_io -- the SIDE EFFECTS of ai/bin/lead-time-phases
# (DND-1477): every file, git and process read, and the two stores it writes.
# Each reader returns a LeadTimePhases::Source, so "could not look" (a missing
# store, an unreadable file) never reads as "looked, found nothing".
#
# It writes only the state dir: ledger.jsonl, cursor.<repo>.txt, and (on an
# explicit --rejoin) ledger-replaced.jsonl, the rows it replaced. Everything
# else (git, integration receipts, critic verdicts, harness-gate timings,
# telemetry) is read-only.

require "json"
require "time"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "lead_time_phases"
require_relative "lead_time_config"
require_relative "critic_verdict_stores"
require_relative "athena_telemetry"

module LeadTimePhasesIO
  Source = LeadTimePhases::Source

  # ledger.jsonl: one JSON row per (repo, landed commit, ticket). First write
  # wins on append; a row is rewritten only by an explicit --rejoin (replace).
  class LedgerStore
    attr_reader :path

    def initialize(path)
      @path = path
    end

    def exist? = File.exist?(path)

    # -> [rows, malformed count]; raises SystemCallError when it cannot read.
    def read
      return [[], 0] unless File.exist?(path)

      rows = []
      bad = 0
      File.foreach(path) do |line|
        next if line.strip.empty?

        r = JSON.parse(line) rescue nil
        r.is_a?(Hash) ? rows << r : bad += 1
      end
      [rows, bad]
    end

    # Append the rows whose key is not in the ledger yet, under an exclusive
    # lock so two ingests cannot both add one key. -> [added, already present]
    def append(rows)
      with_lock do |f|
        existing, = read
        fresh = LeadTimePhases::Ledger.fresh(rows, existing)
        fresh.each { |r| f.write("#{JSON.generate(r)}\n") }
        f.flush
        [fresh.size, rows.size - fresh.size]
      end
    end

    # DND-1490 --rejoin: for each of `repo`'s rejoinable rows
    # (Ledger.rejoinable?), Ledger.rejoin_verdict against `replacements`
    # decides; a :replace row is swapped for its fresh row, under the same lock
    # as append. Every other line, malformed ones included, is kept verbatim
    # and in order. The replaced originals are appended to `archive` before
    # the new ledger is renamed into place, so history is moved aside, never
    # dropped. A crash between the two leaves an original archived but not yet
    # replaced; the next --rejoin archives it again (a duplicate, never a loss).
    # -> [[verdict, ledger row, fresh row or nil], ...] for every rejoinable
    # row of `repo`. No :replace writes nothing.
    def replace(replacements, archive, repo:)
      with_lock do |f|
        outcomes = []
        old = []
        out = File.readlines(path).map do |line|
          row = JSON.parse(line) rescue nil
          next line unless row.is_a?(Hash) && row["repo"] == repo && LeadTimePhases::Ledger.rejoinable?(row)

          fresh = replacements[LeadTimePhases::Ledger.key(row)]
          verdict = LeadTimePhases::Ledger.rejoin_verdict(row, fresh)
          outcomes << [verdict, row, fresh]
          next line unless verdict == :replace

          old << line
          "#{JSON.generate(fresh)}\n"
        end
        write_replaced(f, out, old, archive) unless old.empty?
        outcomes
      end
    end

    # True while `f` is the file at `path`. A replace renames a new file into
    # place; a writer that opened the old one before that holds a lock on an
    # unlinked file and must reopen.
    def live?(f)
      st = File.stat(path)
      st.ino == f.stat.ino && st.dev == f.stat.dev
    rescue Errno::ENOENT
      false
    end

    private

    def write_replaced(locked, lines, old, archive)
      File.open(archive, File::WRONLY | File::CREAT | File::APPEND, 0o644) do |a|
        a.write(old.join)
        a.fsync
      end
      tmp = "#{path}.tmp.#{Process.pid}"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, locked.stat.mode & 0o777) do |t|
          t.write(lines.join)
          t.fsync
        end
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp)
      end
    end

    # The ledger opened for append (the test seam for a stale handle).
    def open_ledger = File.open(path, File::RDWR | File::CREAT | File::APPEND, 0o644)

    # Yields the ledger opened for append and exclusively locked, reopening
    # when a replace moved the file while this waited on the lock.
    def with_lock
      FileUtils.mkdir_p(File.dirname(path))
      loop do
        f = open_ledger
        begin
          f.flock(File::LOCK_EX)
          return yield(f) if live?(f)
        ensure
          f.close
        end
      end
    end
  end

  # cursor.<repo>.txt: the RFC 3339 time the next scan starts from.
  class CursorStore
    attr_reader :path

    def initialize(dir, repo)
      @path = File.join(dir, "cursor.#{repo}.txt")
    end

    # -> [iso or nil, nil] or [nil, reason]. A missing cursor is nil; a
    # malformed one is an error, never "no cursor" (that would re-backfill).
    def read
      return [nil, nil] unless File.exist?(path)

      text = File.read(path).strip
      [Time.iso8601(text).utc.iso8601, nil]
    rescue ArgumentError
      [nil, "#{path} holds #{text.inspect}, not an RFC 3339 time"]
    rescue SystemCallError => e
      [nil, "could not read #{path} (#{e.class.name.split('::').last})"]
    end

    def write(iso)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, "#{iso}\n")
      File.rename(tmp, path)
    end
  end

  module Git
    module_function

    # The repo's git common dir, absolute. -> [path, nil] or [nil, reason]
    def common_dir(repo)
      out, err, st = Open3.capture3("git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
      return [out.strip, nil] if st.success? && out.strip.start_with?("/")

      [nil, "git rev-parse --git-common-dir in #{repo} failed (#{err.strip.lines.first.to_s.strip})"]
    rescue SystemCallError => e
      [nil, "git could not run (#{e.message})"]
    end

    # The repo label the telemetry writer stamps on every event: one rule,
    # shared with the resolver's name/basename check (DND-1526).
    def repo_label(common) = LeadTimeConfig.repo_label(common)
  end

  # <common>/integration-receipts/<head>.json (integration-gate, DND-965).
  module ReceiptReader
    module_function

    def read(common, head)
      return Source.could_not_look("no git common dir") unless common

      dir = File.join(common, "integration-receipts")
      return Source.could_not_look("no integration-receipts store at #{dir}") unless File.directory?(dir)

      file = File.join(dir, "#{head}.json")
      return Source.empty("no receipt for #{head[0, 8]} in #{dir}") unless File.exist?(file)

      Source.ok([JSON.parse(File.read(file))])
    rescue JSON::ParserError, SystemCallError => e
      Source.could_not_look("#{file} is unreadable (#{e.class.name.split('::').last})")
    end
  end

  # Which gated heads cover a push landing (DND-1809): ir_push_covered in
  # ai/lib/integration-receipt.sh, the one copy of the rule gh-athena's push
  # guard uses (an exact receipt, or a gated head whose clean merge onto the
  # pre-push main gives the landed tree, matched by author, author date and
  # subject). Run read-only in a bash child.
  module PushCover
    LIB = File.expand_path("integration-receipt.sh", __dir__)
    # $1 the lib, $2 common dir, $3 pushed sha, $4 pre-push main (or "").
    # Prints: rc, IR_COVER, the covering heads (space-separated), IR_WHY.
    SCRIPT = <<~'SH'
      . "$1" || exit 9
      rc=0
      ir_push_covered "$2" "$3" "$4" || rc=$?
      printf '%s\n%s\n%s\n%s\n' "$rc" "$IR_COVER" "${IR_COVER_HEADS[*]}" "${IR_KIND:+$IR_KIND: }$IR_WHY"
    SH

    module_function

    # -> Source: ok [{"cover", "heads", "onto"}]; empty(why) when no gated
    # head covers it; could_not_look(why) when the rule could not be run.
    def read(common, landed, before)
      return Source.could_not_look("no git common dir") unless common
      return Source.could_not_look("#{LIB} is missing") unless File.file?(LIB)

      out, err, st = Open3.capture3("bash", "-c", SCRIPT, "ir-push-covered", LIB, common, landed, before.to_s)
      return Source.could_not_look("could not load #{LIB} (#{err.strip.lines.first.to_s.strip})") if st.exitstatus == 9

      rc, cover, heads, why = out.split("\n", 4).map(&:to_s)
      why = why.to_s.strip
      case rc
      when "0" then Source.ok([{ "cover" => cover, "heads" => heads.split, "onto" => before }])
      when "1" then Source.empty(why)
      else Source.could_not_look(why.empty? ? "ir_push_covered exited #{rc.inspect} (#{err.strip})" : why)
      end
    rescue SystemCallError => e
      Source.could_not_look("bash could not run (#{e.message})")
    end
  end

  # Every critic-verdicts store of the repo, for one sha.
  module VerdictReader
    module_function

    def read(common, sha)
      return Source.could_not_look("no git common dir") unless common

      stores, why = CriticVerdictStores.stores(common)
      return Source.could_not_look(why) unless stores

      found = stores.map { |s| File.join(s, "#{sha}.json") }.select { |f| File.exist?(f) }
      return Source.empty("no verdict receipt for #{sha[0, 8]} in #{stores.size} store(s)") if found.empty?

      Source.ok(found.map { |f| JSON.parse(File.read(f)) })
    rescue JSON::ParserError, SystemCallError => e
      Source.could_not_look("a verdict receipt for #{sha[0, 8]} is unreadable (#{e.class.name.split('::').last})")
    end
  end

  # harness-gate's per-check timings, $XDG_STATE_HOME/athena/harness-gate/timings.jsonl.
  module TimingsReader
    module_function

    def path(env)
      base = env["XDG_STATE_HOME"].to_s
      base = File.join(env["HOME"].to_s, ".local", "state") if base.empty?
      File.join(base, "athena", "harness-gate", "timings.jsonl")
    end

    # -> [{head => Source}, malformed line count] for the heads asked about.
    def read(file, heads)
      return [heads.to_h { |h| [h, Source.could_not_look("no timings file at #{file}")] }, 0] unless File.exist?(file)

      want = heads.to_h { |h| [h, []] }
      bad = 0
      File.foreach(file) do |line|
        r = JSON.parse(line) rescue nil
        next bad += 1 unless r.is_a?(Hash)

        want[r["head"]] << r if want.key?(r["head"])
      end
      [want.transform_values { |rows| rows.empty? ? Source.empty("no rows") : Source.ok(rows) }, bad]
    rescue SystemCallError => e
      [heads.to_h { |h| [h, Source.could_not_look("could not read #{file} (#{e.class.name.split('::').last})")] }, 0]
    end
  end

  # The phase events, through the DND-1473 reader only.
  module TelemetryReader
    module_function

    # -> [Source, AthenaTelemetry::ReadResult or nil]. An :incomplete read
    # (a day file it could not read) keeps NO events: a partial set would
    # undercount counters and move anchors, so every telemetry anchor reads
    # "could not look" (ai/contracts/athena-telemetry.md -> The reader).
    def read(env) = read_kinds(env, LeadTimePhases::EVENTS)

    # Every kind: the origin check (DND-1531) counts a local event of any kind.
    def read_all(env) = read_kinds(env, nil)

    # names: the event names to keep, or nil for every kind.
    def read_kinds(env, names)
      res = AthenaTelemetry.read(events: names, env: env)
      src = case res.status
            when :no_store, :incomplete then Source.could_not_look(res.reason)
            else Source.ok(res.events)
            end
      [src, res]
    rescue AthenaTelemetry::ConfigError => e
      [Source.could_not_look("the telemetry store path is unusable (#{e.message})"), nil]
    end
  end

  # The ticket a PR row names: the SAME parser the telemetry writer resolves
  # `unit` with (AthenaTelemetry::TicketRefs, which requires the shared parser
  # ai/lib/ticket_ref.rb that ai/bin/lead-time uses too), so the join key
  # matches by construction.
  module TicketFor
    module_function

    # -> [ticket or nil, nil] or [nil, why it could not be read]. A parser
    # that cannot load, or an overlay fault, is "could not look", never
    # "unticketed".
    def call(row)
      return [row["ticket"], nil] if row.key?("ticket")

      parser = AthenaTelemetry::TicketRefs.parser
      return [nil, "the ticket-ref parser (ai/lib/ticket_ref.rb) did not load"] unless parser

      fault = false
      [row["branch"], row["title"]].each do |text|
        next if text.to_s.empty?

        ref = parser.call(text.to_s)
        return [ref, nil] if ref.is_a?(String)

        fault ||= AthenaTelemetry::TicketRefs.last_overlay_fault?
      end
      fault ? [nil, "the private overlay could not give the work-ticket prefix"] : [nil, nil]
    end
  end

  # ai/bin/lead-time's own --since rule, loaded WRAPPED in its own module so
  # the two tools accept exactly the same WHEN.
  module LeadTimeLib
    PATH = File.expand_path("../bin/lead-time", __dir__)

    module_function

    def lead_time
      @lead_time ||= begin
        wrap = Module.new
        load(PATH, wrap)
        wrap::LeadTime
      end
    end

    # -> [utc iso, nil] or [nil, reason]
    def parse_since(text) = lead_time.parse_since(text)
  end

  # ai/bin/lead-time --since --json --meta (DND-1009), as a subprocess.
  module LeadTimeRunner
    Result = Struct.new(:code, :signal, :rows, :meta, :stderr, :error, keyword_init: true)

    module_function

    def run(bin, repo, since, env)
      Dir.mktmpdir("lead-time-phases-") do |tmp|
        meta_file = File.join(tmp, "meta.json")
        out, err, st = Open3.capture3(env, bin, "--repo", repo, "--since", since, "--json", "--meta", meta_file)
        meta = File.exist?(meta_file) ? (JSON.parse(File.read(meta_file)) rescue :malformed) : nil
        rows = out.strip.empty? ? nil : (JSON.parse(out) rescue :malformed)
        Result.new(code: st.exitstatus, signal: st.termsig, rows: rows, meta: meta, stderr: err)
      end
    rescue SystemCallError => e
      Result.new(code: nil, error: "#{bin} could not run (#{e.message})", stderr: "")
    end
  end

  # Commits on main whose subject starts with "Revert", in a time window.
  module RevertCounter
    module_function

    def count(repo, since, until_t)
      ref = %w[origin/main main].find do |r|
        _, _, st = Open3.capture3("git", "-C", repo, "rev-parse", "--verify", "-q", "#{r}^{commit}")
        st.success?
      end
      return Source.could_not_look("neither origin/main nor main resolves in #{repo}") unless ref

      out, err, st = Open3.capture3("git", "-C", repo, "log", "--first-parent", "--format=%s",
                                    "--since=#{since}", "--until=#{until_t}", ref)
      return Source.could_not_look("git log in #{repo} failed (#{err.strip.lines.first.to_s.strip})") unless st.success?

      Source.ok(out.lines.map(&:strip).select { |s| s.start_with?("Revert") })
    rescue SystemCallError => e
      Source.could_not_look("git could not run (#{e.message})")
    end
  end
end
