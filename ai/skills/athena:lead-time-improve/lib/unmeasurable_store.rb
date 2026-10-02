# frozen_string_literal: true

# LeadTimeUnmeasurableStore -- SIDE EFFECTS: <state>/unmeasurable.json, the
# run count per repo and phase (DND-1806). One JSON document, written whole
# through a temp file, fsync and a rename, mode 0600. #transaction holds an
# flock on <path>.lock across load and every save, so a cron run and a
# directly-spawned run cannot interleave and lose a step's record.
#
# No file is the initial state (nothing counted yet). A file that exists but
# cannot be read, parsed, or holds an entry of the wrong shape is Unreadable,
# never an empty state: reading it as empty would reset every count and hide
# the gap the count exists to surface (~/dev/custom/ai/CLAUDE.md -> A failed
# lookup must never look like an empty one). Only ENOENT is "no file":
# File.exist? also says false on EACCES.

require "json"

class LeadTimeUnmeasurableStore
  class Unreadable < StandardError; end

  VERSION = 1
  TICKET_RE = /\ADND-[1-9][0-9]{0,6}\z/.freeze

  attr_reader :path

  def initialize(path)
    @path = path
  end

  # transaction { |entries, save| ... } -> the block's value. save.call
  # writes entries now; call it after each side effect so a later failure
  # cannot lose the record of an earlier one.
  def transaction
    lock = begin
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
    rescue SystemCallError => e
      raise Unreadable, "cannot open the lock #{path}.lock: #{e.message}"
    end
    begin
      lock.flock(File::LOCK_EX)
      entries = load
      yield entries, -> { save(entries) }
    ensure
      lock.close
    end
  end

  # -> {"<repo>/<phase>" => entry}
  def load
    text = begin
      File.read(path)
    rescue Errno::ENOENT
      return {}
    end
    doc = JSON.parse(text)
    unless doc.is_a?(Hash) && doc["version"] == VERSION && doc["entries"].is_a?(Hash)
      raise Unreadable, "#{path} is not a version #{VERSION} unmeasurable state file"
    end

    doc["entries"].each { |k, e| check_entry(k, e) }
    doc["entries"]
  rescue JSON::ParserError => e
    raise Unreadable, "#{path} is not JSON (#{e.message[0, 80]})"
  rescue SystemCallError => e
    raise Unreadable, "cannot read #{path}: #{e.message}"
  end

  def save(entries)
    dir = File.dirname(path)
    tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.tmp")
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate({ "version" => VERSION, "entries" => entries }))
      f.write("\n")
      f.flush
      f.fsync
    end
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  private

  def check_entry(key, e)
    bad = ->(why) { raise Unreadable, "#{path}: entry #{key.inspect} #{why}" }
    bad.call("is not an object") unless e.is_a?(Hash)
    bad.call("has runs #{e['runs'].inspect}, not a whole number >= 0") unless e["runs"].is_a?(Integer) && e["runs"] >= 0
    bad.call("has ticket #{e['ticket'].inspect}, not null or DND-N") unless e["ticket"].nil? || TICKET_RE.match?(e["ticket"].to_s)
    bad.call("has ticket_landed #{e['ticket_landed'].inspect}, not true or false") unless [true, false].include?(e["ticket_landed"])
    bad.call("has episode #{e['episode'].inspect}, not null or an object") unless e["episode"].nil? || e["episode"].is_a?(Hash)
  end
end
