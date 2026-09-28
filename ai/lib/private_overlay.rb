# frozen_string_literal: true

# ai/lib/private_overlay.rb -- the PURE rules of the private work overlay
# (DND-702). Contract: ai/contracts/athena-private-overlay.md.
#
# This file is Domain: it validates keys, the marker, and values, and walks a
# parsed document. It never touches the filesystem or the environment. The
# side-effecting half (env + fs reads) is ai/lib/private_overlay_resolver.rb,
# and ai/bin/private-overlay is the CLI over both.
#
# Nothing here ever puts an overlay VALUE into a reason string: reasons name the
# key, the file, and the rule, so a caller may print them on stderr.
#
# Deliberately gem-free (stdlib only).

require "json"

module PrivateOverlay
  # The five resolver states and their exit codes (contract -> States and exit
  # codes). FOUND is the only zero.
  EXIT = {
    found: 0,
    usage: 2,
    absent: 3,
    malformed: 4,
    key_not_found: 5,
  }.freeze

  STATE_NAME = {
    found: "FOUND",
    usage: "USAGE",
    absent: "ABSENT",
    malformed: "MALFORMED",
    key_not_found: "KEY_NOT_FOUND",
  }.freeze

  ENV_VAR = "ATHENA_PRIVATE_ROOT"
  DEFAULT_REL = ".config/athena/work"
  MARKER = "athena-overlay.json"
  MARKER_KIND = "athena-private-overlay"
  SUPPORTED_SCHEMAS = [1].freeze
  FILE_RE = /\A[a-z0-9-]+\z/.freeze
  SEGMENT_RE = /\A[A-Za-z0-9_-]+\z/.freeze
  PATH_RE = /\A(?:\.[A-Za-z0-9_-]+(?:\[\d+\])*)+\z/.freeze

  # Raised for a key the caller wrote wrongly (exit 2, nothing read).
  class UsageError < StandardError; end

  # One outcome of a resolve. `root` is the validated root (PRESENT/FOUND) or
  # the probed path (ABSENT/MALFORMED). `reason` never carries a value.
  Result = Struct.new(:state, :root, :reason, :value, keyword_init: true) do
    def exit_code
      EXIT.fetch(state)
    end

    def name
      STATE_NAME.fetch(state)
    end
  end

  module_function

  # "<file>" must be one flat name: no "/", no "..", no uppercase.
  def validate_file!(file)
    return file if file.is_a?(String) && FILE_RE.match?(file)

    raise UsageError, "overlay file name #{file.to_s.inspect} is not [a-z0-9-]+ (no '/', no '..')"
  end

  # ".a.b[0].c" -> ["a", "b", 0, "c"]. The path must start with "." and name at
  # least one key; "." alone (the whole document) is refused.
  def parse_path!(path)
    unless path.is_a?(String) && PATH_RE.match?(path)
      raise UsageError, "key path #{path.to_s.inspect} is not of the form .key.key[0] (it must start with '.')"
    end

    path.scan(/\.([A-Za-z0-9_-]+)|\[(\d+)\]/).map { |key, idx| key || Integer(idx, 10) }
  end

  # The default root for a given HOME. A HOME that cannot yield an absolute
  # path is an error, not an empty result.
  def default_root(home)
    return [nil, "HOME is unset or empty, so the default root cannot be computed"] if home.nil? || home.empty?
    return [nil, "HOME (#{home}) is not an absolute path"] unless home.start_with?("/")

    [File.join(home, DEFAULT_REL), nil]
  end

  # nil when the marker text is valid, else the reason (never echoing a value
  # except the schema number, which is not sensitive).
  def marker_problem(text)
    doc = begin
      JSON.parse(text)
    rescue JSON::ParserError, EncodingError
      return "marker #{MARKER} is not valid JSON"
    end
    return "marker #{MARKER} is not a JSON object" unless doc.is_a?(Hash)
    return "marker #{MARKER} has kind other than #{MARKER_KIND.inspect}" unless doc["kind"] == MARKER_KIND

    schema = doc["schema"]
    unless schema.is_a?(Integer) && SUPPORTED_SCHEMAS.include?(schema)
      shown = schema.is_a?(Integer) ? schema.to_s : "missing or not an integer"
      return "marker #{MARKER} schema #{shown} is unsupported (supported: #{SUPPORTED_SCHEMAS.join(', ')})"
    end
    nil
  end

  # Mode bits of the root directory: group/other access is refused.
  def mode_problem(mode, owner_uid, my_uid)
    return "the root is owned by uid #{owner_uid}, not by this user (uid #{my_uid})" unless owner_uid == my_uid
    return nil if (mode & 0o077).zero?

    format("the root has group/other access (mode %04o); the overlay must be 0700", mode & 0o7777)
  end

  # Walk parsed JSON. -> [:found, value] | [:key_not_found, reason] |
  # [:malformed, reason]. Reasons name the path walked so far, never a value.
  def dig(doc, segments, file)
    here = doc
    walked = +""
    segments.each do |seg|
      step = seg.is_a?(Integer) ? "[#{seg}]" : ".#{seg}"
      if seg.is_a?(Integer)
        return [:malformed, "#{file}#{walked} is not an array, so #{step} cannot apply"] unless here.is_a?(Array)
      else
        return [:malformed, "#{file}#{walked.empty? ? ' (the document)' : walked} is not an object, so #{step} cannot apply"] unless here.is_a?(Hash)
      end
      walked << step
      present = seg.is_a?(Integer) ? seg < here.length : here.key?(seg)
      return [:key_not_found, "#{file}#{walked} is not present"] unless present

      here = here[seg]
      return [:key_not_found, "#{file}#{walked} is null"] if here.nil?
    end
    [:found, here]
  end

  # nil when the value may be returned, else the reason. Empty or whitespace
  # strings and empty collections are MALFORMED, never an empty FOUND.
  def value_problem(value, key)
    case value
    when String
      value.strip.empty? ? "#{key} is an empty string" : nil
    when Array, Hash
      value.empty? ? "#{key} is an empty #{value.is_a?(Array) ? 'array' : 'object'}" : nil
    when Integer, Float, TrueClass, FalseClass
      nil
    else
      "#{key} has an unsupported type"
    end
  end

  # Strings print raw; collections print as compact JSON; scalars as JSON.
  def render(value)
    value.is_a?(String) ? value : JSON.generate(value)
  end

  # The one stderr line for a non-zero outcome. `key` is "<file><path>" or nil.
  def failure_line(result, key)
    parts = ["private-overlay: #{result.name}:"]
    parts << "key=#{key}" if key
    parts << "#{result.state == :absent ? 'probed' : 'root'}=#{result.root || '(none)'}."
    parts << "#{result.reason}." if result.reason && !result.reason.empty?
    parts << "Fix: #{fix_for(result, key)}"
    parts.join(" ")
  end

  def fix_for(result, key)
    case result.state
    when :absent
      "the private overlay directory #{result.root} does not exist on this machine, so this feature is " \
        "unavailable here. If this machine should hold the overlay, the owner creates it (mode 0700, " \
        "see ai/contracts/athena-private-overlay.md -> Discovery); otherwise report the feature as unavailable " \
        "and do not guess the value."
    when :malformed
      "correct the named problem in the overlay (or unset/fix #{ENV_VAR}, which is authoritative when set " \
        "and never falls through to the default); see ai/contracts/athena-private-overlay.md -> States and exit codes."
    when :key_not_found
      file, path = split_key(key)
      "add #{path} to overlay/#{file}.json in the private overlay at #{result.root}; never substitute a guessed value."
    when :usage
      "call `private-overlay get <file> <.key.path>` with <file> matching [a-z0-9-]+ and a path starting with '.'; " \
        "see `private-overlay --help`."
    else
      "see ai/contracts/athena-private-overlay.md."
    end
  end

  def split_key(key)
    return ["<file>", "<path>"] if key.nil?

    idx = key.index(/[.\[]/)
    idx ? [key[0...idx], key[idx..]] : [key, "<path>"]
  end
end
