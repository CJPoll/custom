# frozen_string_literal: true

# LeadTimeUnmeasurableStore -- SIDE EFFECTS: <state>/unmeasurable.json, the
# consecutive-run count per repo and phase (DND-1806). One JSON document,
# written whole through a temp file and a rename, mode 0600.
#
# No file is the initial state (nothing counted yet). A file that exists but
# cannot be read or parsed is Unreadable, never an empty state: reading it as
# empty would reset every count and hide the gap the count exists to surface
# (~/dev/custom/ai/CLAUDE.md -> A failed lookup must never look like an empty
# one).

require "json"

class LeadTimeUnmeasurableStore
  class Unreadable < StandardError; end

  VERSION = 1

  attr_reader :path

  def initialize(path)
    @path = path
  end

  # -> {"<repo>/<phase>" => entry}
  def load
    return {} unless File.exist?(path)

    doc = JSON.parse(File.read(path))
    unless doc.is_a?(Hash) && doc["version"] == VERSION && doc["entries"].is_a?(Hash)
      raise Unreadable, "#{path} is not a version #{VERSION} unmeasurable state file"
    end

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
    end
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end
end
