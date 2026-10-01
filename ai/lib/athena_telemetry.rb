# frozen_string_literal: true

# athena_telemetry -- the ONE telemetry writer and reader (DND-1473).
#
# Normative home: ai/contracts/athena-telemetry.md. This file implements it;
# where they disagree, the contract wins and this file is the bug.
#
# Ruby emitters require this file and call AthenaTelemetry.emit in-process.
# Shell emitters run ai/bin/telemetry-emit, a thin CLI over this module, so
# there is one implementation. Ruby stdlib only. No network, ever.
#
# Buckets:
#   DOMAIN (pure)   Label, Event, Registry, Unit, Retention
#   SIDE EFFECTS    Store (every file read and write), GitContext (one bounded `git rev-parse`),
#                   TicketRefs (loads the ticket-ref parser ai/bin/lead-time
#                   uses), Clock, Host
#   MANAGER         AthenaTelemetry.emit, .read, .prune
#
# FAILS OPEN, OBSERVABLY. emit never raises, never retries, and never changes
# the caller's exit code. Every failure or drop increments a reason in the
# store's `write-failures` counter. If even that write fails, the process
# prints ONE `athena-telemetry:` line on stderr, once per process. The reader
# returns that counter with every read, so a missing event never reads as
# "nothing happened".
#
# Test seams (tests only; there is no switch that turns telemetry off):
#   ATHENA_TELEMETRY_DIR            the store directory (absolute)
#   ATHENA_TELEMETRY_NOW            ISO 8601 "now"
#   ATHENA_TELEMETRY_DAY_CAP_BYTES  the per-day cap (default 64 MiB)

require "json"
require "time"
require "date"
require "fileutils"
require_relative "bounded_command"
require "socket"

module AthenaTelemetry
  SCHEMA_VERSION = 1
  MAX_LINE_BYTES = 4096
  DEFAULT_DAY_CAP_BYTES = 64 * 1024 * 1024
  DEFAULT_RETAIN_DAYS = 30
  COUNTER_FILE = "write-failures"
  DAY_FILE_RE = /\A(\d{4}-\d{2}-\d{2})\.jsonl\z/.freeze
  REGISTRY_PATH = File.expand_path("../telemetry/events.json", __dir__)
  UNIT_SOURCES = %w[explicit env branch branch-name none].freeze

  class RegistryError < StandardError; end
  # A seam or environment value the writer cannot use: a relative store path,
  # a malformed clock or cap. emit counts it as config_invalid.
  class ConfigError < StandardError; end

  # ── DOMAIN ────────────────────────────────────────────────────────────────

  # A label: a short string. At most 120 characters, no newline.
  module Label
    MAX_CHARS = 120

    module_function

    # -> nil when valid, else the drop reason.
    def problem(value)
      return "attr_type" unless value.is_a?(String) && value.valid_encoding?
      return "label_newline" if value.match?(/[\r\n]/)
      return "label_too_long" if value.length > MAX_CHARS

      nil
    end

    def valid?(value)
      problem(value).nil?
    end
  end

  module Event
    SHA_RE = /\A\h{40}\z/.freeze
    CORE_KEYS = %w[v event at duration_s unit unit_source repo head host pid].freeze

    module_function

    # -> [line_hash, drops] or [nil, drops] when the event cannot be written.
    # attrs must already be filtered by the registry.
    def build(name:, at:, duration_s:, unit:, unit_source:, repo:, head:, host:, pid:, attrs:)
      raise ArgumentError, "unit_source #{unit_source.inspect} is not one of #{UNIT_SOURCES.join(', ')}" unless UNIT_SOURCES.include?(unit_source)
      return [nil, ["at_invalid"]] unless at.is_a?(Time)

      duration = duration_value(duration_s)
      return [nil, ["duration_invalid"]] if duration == :invalid

      drops = []
      sha = nil
      if head
        if head.is_a?(String) && SHA_RE.match?(head)
          sha = head.downcase
        else
          drops << "head_invalid"
        end
      end
      unit, repo, host = [unit, repo, host].map do |v|
        next v if v.nil? || Label.valid?(v)

        drops << "label_invalid"
        nil
      end
      line = { "v" => SCHEMA_VERSION, "event" => name, "at" => iso_ms(at), "duration_s" => duration,
               "unit" => unit, "unit_source" => unit.nil? && unit_source != "none" ? "none" : unit_source,
               "repo" => repo, "head" => sha, "host" => host, "pid" => pid, "attrs" => attrs }
      [line, drops]
    end

    def duration_value(value)
      return nil if value.nil?
      return :invalid unless value.is_a?(Numeric) && !value.is_a?(Complex) && value.to_f.finite? && value >= 0

      value.to_f
    end

    def iso_ms(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # -> [line_with_newline, truncated?]. Over max_bytes, attrs are dropped
    # from the last one back and attrs_truncated is set; the core fields are
    # never cut. -> [nil, true] if the core alone does not fit.
    def serialize(hash, max_bytes:)
      line = "#{JSON.generate(hash)}\n"
      return [line, false] if line.bytesize <= max_bytes

      attrs = hash["attrs"].dup
      loop do
        attrs.delete(attrs.keys.last) unless attrs.empty?
        line = "#{JSON.generate(hash.merge('attrs' => attrs, 'attrs_truncated' => true))}\n"
        return [line, true] if line.bytesize <= max_bytes
        return [nil, true] if attrs.empty?
      end
    end
  end

  # The event registry (ai/telemetry/events.json): every event name and its
  # allowed attrs with their types. It is the privacy control: the writer
  # never emits an event or attr nobody declared.
  class Registry
    TYPES = %w[int float bool sha label].freeze
    EVENT_RE = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/.freeze
    ATTR_RE = /\A[a-z][a-z0-9_]*\z/.freeze

    # -> Registry, or raises RegistryError naming the bad key.
    def self.parse(json)
      doc = begin
        JSON.parse(json)
      rescue JSON::ParserError => e
        raise RegistryError, "the registry is not JSON (#{e.message.lines.first.to_s.strip})"
      end
      raise RegistryError, "the registry must be a JSON object" unless doc.is_a?(Hash)
      raise RegistryError, "key v must be #{SCHEMA_VERSION}, got #{doc['v'].inspect}" unless doc["v"] == SCHEMA_VERSION
      raise RegistryError, "key events must be an object" unless doc["events"].is_a?(Hash)

      events = doc["events"].to_h do |name, spec|
        raise RegistryError, "event #{name.inspect} is not a dotted lower-case name (e.g. harness_gate.run)" unless EVENT_RE.match?(name)
        raise RegistryError, "event #{name} must be an object" unless spec.is_a?(Hash)
        raise RegistryError, "event #{name} needs a description string" unless spec["description"].is_a?(String) && !spec["description"].empty?
        raise RegistryError, "event #{name} needs an attrs object" unless spec["attrs"].is_a?(Hash)

        attrs = spec["attrs"].to_h do |attr, type|
          raise RegistryError, "event #{name} attr #{attr.inspect} is not a lower-case name" unless ATTR_RE.match?(attr)
          raise RegistryError, "event #{name} attr #{attr} has type #{type.inspect}; use one of #{TYPES.join(', ')}" unless TYPES.include?(type)

          [attr, type]
        end
        [name, attrs.freeze]
      end
      new(events)
    end

    def initialize(events)
      @events = events.freeze
    end

    def event_names
      @events.keys
    end

    # -> the registered {attr => type} of an event, or nil when it is not
    # registered. Read-only (DND-1474: check-telemetry-registry).
    def attrs_for(name)
      @events[name]
    end

    # -> [kept_attrs, drops]; [nil, ["event_unregistered"]] for an unknown event.
    def filter(name, attrs)
      spec = @events[name]
      return [nil, ["event_unregistered"]] unless spec

      kept = {}
      drops = []
      attrs.each do |key, value|
        key = key.to_s
        type = spec[key]
        if type.nil?
          drops << "attr_unregistered"
          next
        end
        value, problem = check(type, value)
        problem ? drops << problem : kept[key] = value
      end
      [kept, drops]
    end

    # CLI strings -> the registered types, where they convert. A value that
    # does not convert stays a string, so filter drops it as attr_type.
    def coerce(name, attrs)
      spec = @events[name] || {}
      attrs.to_h do |key, value|
        [key, convert(spec[key], value)]
      end
    end

    private

    def check(type, value)
      case type
      when "int" then value.is_a?(Integer) ? [value, nil] : [nil, "attr_type"]
      when "float"
        number = value.is_a?(Numeric) && !value.is_a?(Complex) && value.to_f.finite?
        number ? [value.to_f, nil] : [nil, "attr_type"]
      when "bool" then [true, false].include?(value) ? [value, nil] : [nil, "attr_type"]
      when "sha" then value.is_a?(String) && Event::SHA_RE.match?(value) ? [value.downcase, nil] : [nil, "attr_type"]
      when "label" then (p = Label.problem(value)) ? [nil, p] : [value, nil]
      end
    end

    def convert(type, value)
      return value unless value.is_a?(String)

      case type
      when "int" then value.match?(/\A-?\d+\z/) ? Integer(value, 10) : value
      when "float" then value.match?(/\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/) ? Float(value) : value
      when "bool" then { "true" => true, "false" => false }.fetch(value, value)
      else value
      end
    end
  end

  # The unit of work an event belongs to.
  module Unit
    module_function

    # ticket_ref: a callable branch -> ticket ref or nil (the parser
    # ai/bin/lead-time uses). nil, a :unavailable answer, or a raise means the
    # parser is unavailable: the branch name is the unit, and it is counted.
    # -> [unit, unit_source, drops].
    def parse(branch:, env_unit:, ticket_ref:, explicit: nil)
      drops = []
      [[explicit, "explicit"], [env_unit, "env"]].each do |value, source|
        next if value.nil? || value.empty?
        return [value, source, drops] if Label.valid?(value)

        drops << "unit_invalid"
      end
      return [nil, "none", drops] if branch.nil? || branch.empty? || branch == "HEAD"

      ref = begin
        ticket_ref ? ticket_ref.call(branch) : :unavailable
      rescue StandardError
        :unavailable
      end
      if ref == :unavailable
        drops << "unit_parser_unavailable"
        ref = nil
      end
      return [ref, "branch", drops] if ref
      return [branch, "branch-name", drops] if Label.valid?(branch)

      [nil, "none", drops + ["unit_invalid"]]
    end
  end

  module Retention
    module_function

    # -> the day-file names older than `days` before now's UTC date. Any other
    # file (write-failures, notes) is never expired.
    def expired(filenames, now:, days:)
      cutoff = now.getutc.to_date - days
      filenames.select do |name|
        m = DAY_FILE_RE.match(name)
        date = m && (Date.strptime(m[1], "%Y-%m-%d") rescue nil)
        date && date < cutoff
      end.sort
    end
  end

  # ── SIDE EFFECTS ──────────────────────────────────────────────────────────

  module Clock
    module_function

    # -> Time (UTC). Raises ConfigError on a malformed ATHENA_TELEMETRY_NOW.
    def now(env)
      seam = env["ATHENA_TELEMETRY_NOW"]
      return Time.now.utc if seam.nil? || seam.empty?

      begin
        Time.iso8601(seam).utc
      rescue ArgumentError
        raise ConfigError, "ATHENA_TELEMETRY_NOW is not an ISO 8601 time"
      end
    end
  end

  module Host
    module_function

    # -> the short hostname, or nil when there is none.
    def short
      name = Socket.gethostname.to_s.split(".").first
      name.nil? || name.empty? ? nil : name
    end
  end

  # The store: ${XDG_STATE_HOME:-$HOME/.local/state}/athena/telemetry, 0700,
  # one <UTC date>.jsonl per day (0600) and the write-failures counter.
  module Store
    LOCK_ATTEMPTS = 50
    LOCK_PAUSE_S = 0.01
    COUNTER_LOCK = "#{COUNTER_FILE}.lock".freeze

    module_function

    # -> the store directory. Raises ConfigError when it cannot be resolved.
    def dir(env)
      seam = env["ATHENA_TELEMETRY_DIR"]
      if seam && !seam.empty?
        raise ConfigError, "ATHENA_TELEMETRY_DIR is not an absolute path" unless seam.start_with?("/")

        return seam
      end
      state = env["XDG_STATE_HOME"]
      unless state&.start_with?("/")
        home = env["HOME"]
        raise ConfigError, "neither XDG_STATE_HOME nor HOME is an absolute path" unless home&.start_with?("/")

        state = File.join(home, ".local", "state")
      end
      File.join(state, "athena", "telemetry")
    end

    def day_cap(env)
      raw = env["ATHENA_TELEMETRY_DAY_CAP_BYTES"]
      return DEFAULT_DAY_CAP_BYTES if raw.nil? || raw.empty?
      raise ConfigError, "ATHENA_TELEMETRY_DAY_CAP_BYTES is not a positive integer" unless raw.match?(/\A[1-9]\d*\z/)

      Integer(raw, 10)
    end

    def ensure_dir(dir)
      FileUtils.mkdir_p(File.dirname(dir))
      Dir.mkdir(dir, 0o700)
    rescue Errno::EEXIST
      nil
    end

    # One write(2) with O_APPEND. -> :ok, :day_cap or :short_write. The cap
    # is checked before the write, so concurrent writers can pass it by about
    # one line each. Raises SystemCallError on an I/O failure.
    def append(dir, day, line, cap)
      ensure_dir(dir)
      path = File.join(dir, "#{day}.jsonl")
      return :day_cap if (File.size?(path) || 0) >= cap

      File.open(path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600) do |f|
        return :ok if f.syswrite(line) == line.bytesize

        f.syswrite("\n") rescue nil # end the partial line, so the next one stays parseable
        :short_write
      end
    end

    # Adds reasons (reason => n) to the counter. It holds an exclusive flock
    # on write-failures.lock and replaces the counter by rename, so a reader
    # or a crash never sees a half-written counter. Raises SystemCallError
    # when it cannot, including a lock still held after a bounded wait.
    def count(dir, reasons)
      ensure_dir(dir)
      File.open(File.join(dir, COUNTER_LOCK), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        take(lock)
        path = File.join(dir, COUNTER_FILE)
        data = File.exist?(path) ? parse_counter(File.read(path)) : {}
        reasons.each { |reason, n| data[reason] = data.fetch(reason, 0) + n }
        tmp = "#{path}.tmp.#{Process.pid}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) { |f| f.write(JSON.generate(data)) }
        File.rename(tmp, path)
      end
    end

    # A bounded wait: an emitter is never stalled behind a stuck holder. The
    # lock is held for one read and one rename.
    def take(file)
      LOCK_ATTEMPTS.times do
        return if file.flock(File::LOCK_EX | File::LOCK_NB)

        sleep LOCK_PAUSE_S
      end
      raise Errno::EWOULDBLOCK, "#{COUNTER_LOCK} stayed locked"
    end

    def parse_counter(text)
      return {} if text.nil? || text.strip.empty?

      data = JSON.parse(text)
      return { "counter_corrupt" => 1 } unless data.is_a?(Hash)

      data.select { |_k, v| v.is_a?(Integer) }
    rescue JSON::ParserError
      { "counter_corrupt" => 1 }
    end

    # -> [counter_hash, nil] or [nil, reason]. A missing counter is {}.
    def read_counter(dir)
      path = File.join(dir, COUNTER_FILE)
      return [{}, nil] unless File.exist?(path)

      [parse_counter(File.read(path)), nil]
    rescue SystemCallError => e
      [nil, "could not read #{path} (#{e.class.name.split('::').last})"]
    end

    # -> the store's file names. Raises SystemCallError.
    def list(dir)
      Dir.children(dir)
    end

    # Yields each line of a day file. Raises SystemCallError.
    def each_line(dir, name, &block)
      File.foreach(File.join(dir, name), &block)
    end

    # -> true when removed, false when it was already gone. Raises
    # SystemCallError otherwise.
    def unlink(dir, name)
      File.unlink(File.join(dir, name))
      true
    rescue Errno::ENOENT
      false
    end
  end

  # The git context of a directory, from ONE `git rev-parse`. -> [Context,
  # drop]. Outside a repo it is all nil with no drop. Any other git failure
  # (no git, an old git, an unborn branch) is all nil too, with the drop
  # git_context_unavailable, so it never reads the same as "not a repo".
  #
  # The call is bounded (DND-1494): a git that hangs (an index lock, a pipe or
  # network wait) would stall every in-process emitter. Past GIT_TIMEOUT_S its
  # process group gets TERM, then KILL (BoundedCommand), and the context is all
  # nil with the drop git_context_timeout. The bound sits under the CLI's
  # `timeout -k 1 2`, so a CLI emit normally counts the timeout instead of being
  # killed. Residuals (contract -> Unit of work): a git in uninterruptible sleep
  # survives KILL and the emit waits for it; a git that ignores TERM outlives a
  # CLI emit killed by its outer timeout, uncounted.
  module GitContext
    Context = Struct.new(:branch, :repo, :head, keyword_init: true)
    NONE = Context.new.freeze
    NOT_A_REPO = /not a git repository/i.freeze
    GIT_TIMEOUT_S = 1

    module_function

    def read(dir, git: "git", timeout: GIT_TIMEOUT_S)
      res = BoundedCommand.run([git, "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir",
                                "HEAD", "--abbrev-ref", "HEAD"], timeout: timeout)
      return [NONE, "git_context_timeout"] if res.timed_out

      unless res.success?
        return [NONE, nil] if NOT_A_REPO.match?(res.err)

        return [NONE, "git_context_unavailable"]
      end
      common, head, branch = res.out.lines.map(&:strip)
      return [NONE, "git_context_unavailable"] unless common && head && branch

      [Context.new(branch: branch == "HEAD" ? nil : branch, repo: File.basename(File.dirname(common)), head: head), nil]
    rescue SystemCallError, IOError
      [NONE, "git_context_unavailable"]
    end
  end

  # The ticket-ref parser ai/bin/lead-time uses (LeadTime.ticket_ref): one
  # parser, not two. lead-time is a CLI with top-level helpers (main, usage),
  # so it is loaded WRAPPED in its own module and never touches the caller's
  # namespace. A branch naming a non-DND ref also reads the private overlay's
  # work-ticket prefix, as lead-time does, so a work branch resolves locally.
  module TicketRefs
    LEAD_TIME = File.expand_path("../bin/lead-time", __dir__)

    module_function

    # -> a callable branch -> ref or nil, or nil when the parser cannot load.
    def parser
      return @parser if defined?(@parser)

      @parser = begin
        wrap = Module.new
        load(LEAD_TIME, wrap)
        @lead_time = wrap::LeadTime
        method(:ref_for)
      rescue ScriptError, StandardError, SystemExit
        nil
      end
    end

    def ref_for(branch)
      dnd = ::DispatchTrackers::DND.prefix
      prefixes = [dnd]
      others = @lead_time.refs_in(branch).reject { |r| r.start_with?("#{dnd}-") }
      prefixes << work_prefix if !others.empty? && work_prefix
      @last_overlay_fault = !others.empty? && @overlay_fault == true
      @lead_time.ticket_ref(branch: branch, title: nil, prefixes: prefixes).first
    end

    # The work tracker's prefix from the private overlay, or nil. An ABSENT
    # overlay is this machine's state; a PRESENT one that cannot give the
    # prefix is a fault, which last_overlay_fault? reports for the last
    # ref_for call that needed the overlay.
    def work_prefix
      return @work_prefix if defined?(@work_prefix)

      @overlay_fault = false
      @work_prefix = begin
        require_relative "dispatch_trackers_overlay"
        res = ::DispatchTrackers::Overlay.work
        @overlay_fault = res.fault ? true : false
        res.tracker&.prefix
      rescue ScriptError, StandardError
        @overlay_fault = true
        nil
      end
    end

    def last_overlay_fault?
      @last_overlay_fault == true
    end

    def reset!
      %i[@parser @lead_time @work_prefix @overlay_fault @last_overlay_fault].each do |v|
        remove_instance_variable(v) if instance_variable_defined?(v)
      end
    end
  end

  # ── MANAGER ───────────────────────────────────────────────────────────────

  ReadResult = Struct.new(:status, :events, :failures, :failures_reason, :malformed, :unreadable, :unit, :dir,
                          :reason, keyword_init: true)
  PruneResult = Struct.new(:status, :removed, :dir, :reason, keyword_init: true)

  module_function

  # Emit one event. -> the written line as a Hash, or nil. NEVER raises.
  #   name        a registered event name
  #   at          the start (Time); default now
  #   duration_s  seconds (Numeric), or nil for a point event
  #   unit        an explicit unit of work; default ATHENA_UNIT, then the branch
  #   unit_branch the branch to resolve the unit from in place of the checked-out
  #               one, for a tool that knows the work's branch but does not run
  #               on it (locked-merge: the PR's head branch). Same parser, same
  #               sources (branch / branch-name); nil or "" is no hint (DND-1475).
  #   head        a 40-hex sha; default the repo's HEAD
  #   attrs       a Hash of registered attrs
  #   repo_dir    the directory whose git context applies; default Dir.pwd
  def emit(name, at: nil, duration_s: nil, unit: nil, head: nil, attrs: {}, repo_dir: nil, env: ENV, unit_branch: nil)
    drops = Hash.new(0)
    dir = nil
    begin
      dir = Store.dir(env)
      written = emit_into(dir, drops, name.to_s, at, duration_s, unit, head, attrs || {}, repo_dir, env, unit_branch)
      record(dir, drops)
      written
    rescue ConfigError => e
      drops["config_invalid"] += 1
      record(dir, drops, e)
      nil
    rescue SystemCallError, IOError => e
      drops["write_error"] += 1
      record(dir, drops, e)
      nil
    end
  rescue StandardError => e
    drops["internal_error"] += 1
    record(dir, drops, e)
    nil
  end

  def emit_into(dir, drops, name, at, duration_s, unit, head, attrs, repo_dir, env, unit_branch = nil)
    reg = begin
      registry
    rescue RegistryError, SystemCallError
      drops["registry_unreadable"] += 1
      return nil
    end
    kept, d = reg.filter(name, attrs)
    d.each { |r| drops[r] += 1 }
    return nil unless kept

    now = Clock.now(env)
    cap = Store.day_cap(env)
    ctx, git_drop = GitContext.read(repo_dir || Dir.pwd)
    drops[git_drop] += 1 if git_drop
    overlay_fault = false
    lazy_parser = lambda do |branch|
      p = TicketRefs.parser
      next :unavailable unless p

      ref = p.call(branch)
      overlay_fault = TicketRefs.last_overlay_fault?
      ref
    end
    branch = unit_branch.is_a?(String) && !unit_branch.empty? ? unit_branch : ctx.branch
    unit, source, d = Unit.parse(branch: branch, env_unit: env["ATHENA_UNIT"], explicit: unit, ticket_ref: lazy_parser)
    d.each { |r| drops[r] += 1 }
    drops["unit_overlay_unavailable"] += 1 if source == "branch-name" && overlay_fault
    line, d = Event.build(name: name, at: at || now, duration_s: duration_s, unit: unit, unit_source: source,
                          repo: ctx.repo, head: head || ctx.head, host: Host.short, pid: Process.pid, attrs: kept)
    d.each { |r| drops[r] += 1 }
    return nil unless line

    text, truncated = Event.serialize(line, max_bytes: MAX_LINE_BYTES)
    unless text
      drops["line_too_long"] += 1
      return nil
    end
    drops["attrs_truncated"] += 1 if truncated
    status = Store.append(dir, now.strftime("%Y-%m-%d"), text, cap)
    unless status == :ok
      drops[status.to_s] += 1
      return nil
    end
    JSON.parse(text)
  end

  # Count drops; if that fails too, say so once per process on stderr.
  def record(dir, drops, error = nil)
    return if drops.empty?
    raise ConfigError, "the store directory could not be resolved" if dir.nil?

    Store.count(dir, drops)
  rescue StandardError => e
    warn_once(dir, drops, error || e)
  end

  def warn_once(dir, drops, error)
    return if @warned

    @warned = true
    where = dir ? "#{dir}/#{COUNTER_FILE}" : "the telemetry store"
    $stderr.puts "athena-telemetry: could not record #{drops.keys.join(',')} in #{where} " \
                 "(#{error.class}: #{error.message.to_s.lines.first.to_s.strip}); the caller is unaffected. " \
                 "Fix: make the store a writable 0700 directory of this user, with HOME or XDG_STATE_HOME " \
                 "absolute (ai/contracts/athena-telemetry.md -> Store)."
  rescue StandardError
    nil
  end

  def registry
    @registry ||= Registry.parse(File.read(REGISTRY_PATH))
  end

  # Read events. since/until bound `at` (until exclusive); events and unit
  # filter. Status keeps the cases apart: :no_store (could not look),
  # :incomplete (some day file could not be read), :ok_empty (looked,
  # nothing matched) and :ok. The failures counter comes back every time.
  # Raises ConfigError when the store path cannot be resolved.
  def read(since: nil, until: nil, events: nil, unit: nil, env: ENV)
    until_t = binding.local_variable_get(:until)
    dir = Store.dir(env)
    failures, failures_reason = File.directory?(dir) ? Store.read_counter(dir) : [{}, nil]
    base = { events: [], failures: failures, failures_reason: failures_reason, malformed: 0, unreadable: [],
             unit: unit, dir: dir }
    return ReadResult.new(**base, status: :no_store, reason: "no telemetry store at #{dir}") unless File.directory?(dir)

    names = begin
      Store.list(dir)
    rescue SystemCallError => e
      return ReadResult.new(**base, status: :no_store, reason: "could not list #{dir} (#{e.class.name.split('::').last})")
    end
    found, malformed, unreadable = scan(dir, names, since, until_t, events, unit)
    status = if !unreadable.empty? then :incomplete
             elsif found.empty? then :ok_empty
             else :ok
             end
    reason = unreadable.empty? ? nil : "could not read #{unreadable.join(', ')} in #{dir}"
    ReadResult.new(**base, events: found, malformed: malformed, unreadable: unreadable, status: status, reason: reason)
  end

  # Every day file is read: a file is the WRITE day, and an `at` may lie
  # before or after it, so skipping files by name could miss an event.
  def scan(dir, names, since, until_t, events, unit)
    found = []
    malformed = 0
    unreadable = []
    names.select { |n| DAY_FILE_RE.match?(n) }.sort.each do |name|
      Store.each_line(dir, name) do |raw|
        ev = JSON.parse(raw) rescue nil
        at = ev.is_a?(Hash) && ev["at"].is_a?(String) ? (Time.iso8601(ev["at"]) rescue nil) : nil
        unless at
          malformed += 1
          next
        end
        next if events && !events.include?(ev["event"])
        next if unit && ev["unit"] != unit
        next if since && at < since
        next if until_t && at >= until_t

        found << ev
      end
    rescue SystemCallError
      unreadable << name
    end
    [found.sort_by { |e| e["at"] }, malformed, unreadable]
  end

  # Remove day files older than `days`. -> PruneResult with status :ok,
  # :no_store (nothing to prune) or :error (with reason, and what it removed
  # before the error). Raises ConfigError on a malformed store path or clock.
  def prune(days:, env: ENV)
    dir = Store.dir(env)
    now = Clock.now(env)
    return PruneResult.new(status: :no_store, removed: [], dir: dir) unless File.exist?(dir)

    removed = []
    begin
      Retention.expired(Store.list(dir), now: now, days: days).each do |name|
        removed << name if Store.unlink(dir, name)
      end
    rescue SystemCallError => e
      return PruneResult.new(status: :error, removed: removed, dir: dir,
                             reason: "#{e.class.name.split('::').last} on #{dir}")
    end
    PruneResult.new(status: :ok, removed: removed, dir: dir)
  end

  # Tests only: forget the per-process caches and the stderr-once flag.
  def reset_process_state!
    @registry = nil
    @warned = false
    TicketRefs.reset!
  end
end
