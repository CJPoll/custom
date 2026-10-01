# frozen_string_literal: true

# ai/lib/slack_inbox_files.rb -- EFFECTS: read every *-slack.jsonl directly
# under an Athena inbox root, the one reader ai/bin/judgment-eval (a
# slack_routing context, DND-1048) and ai/bin/judgment-label (the root
# snapshot's context, DND-1448) share, so the two never read the inbox
# differently.
#
# A channel's rotated generation, <name>.1 (athena-inbox.md -> Retention),
# holds that channel's earlier lines. It is read WITH its live file as one
# stream, generation first, under the live file's name (DND-1497): a root
# just after a rotation has its context window in the generation, and a
# root that rotated out is still there until the next rotation. Either file
# may be absent (a quiet channel after a rotation has no live file).
#
# A root that is missing, or that holds neither file for any channel, is an
# Error: zero files must never read as "no context before any root". A line
# that is not a JSON object is skipped and COUNTED, never silently dropped.
# Each Error carries its Fix; the bins print it.
#
# Slack text is untrusted inbox content: this returns it as data only.
#
# Deliberately gem-free (stdlib only).

require "json"

module SlackInboxFiles
  # A failure to read the inbox: the message and the fix, which the bin
  # prints as one line with Fix:.
  class Error < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  GENERATION = ".1"

  module_function

  # read(root) -> {files: [{name: live basename, sources: [basename], rows: [Hash]}],
  # unreadable: n}, streams in name order, each stream's sources oldest first
  # (the generation, then the live file). Raises Error naming what could not
  # be read.
  def read(root)
    raise Error.new("the inbox root #{root} does not exist", "pass --inbox-root (or set ATHENA_INBOX_ROOT) to the directory holding the *-slack.jsonl inboxes") unless File.directory?(root)

    found = streams(root)
    if found.empty?
      raise Error.new("no *-slack.jsonl or *-slack.jsonl#{GENERATION} file directly under #{root} (0 files)",
                      "pass --inbox-root to the directory holding walt_ui-slack.jsonl; with no inbox lines no context can be built")
    end

    unreadable = 0
    files = found.map do |name, paths|
      rows = []
      paths.each do |path|
        File.foreach(path, encoding: "UTF-8") do |raw|
          next if raw.strip.empty?

          row = parse(raw)
          row.is_a?(Hash) ? rows << row : unreadable += 1
        end
      rescue SystemCallError => e
        raise Error.new("could not read #{path}: #{e.class}", "check that inbox file's permissions")
      end
      { name: name, sources: paths.map { |p| File.basename(p) }, rows: rows,
        generation: paths.any? { |p| p.end_with?(GENERATION) }, rotated_at: rotated_at(root, name) }
    end
    { files: files, unreadable: unreadable }
  end

  # rotated_at(root, name) -> the rotated_at the channel's reader recorded in
  # <channel>.state.json, as text, or nil when the state file is absent,
  # unreadable, not JSON, or has none. The caller treats nil as "could not
  # tell" (JudgmentEval.never_rotated?), never as "never rotated".
  def rotated_at(root, name)
    state = File.join(root, "#{name.delete_suffix('.jsonl')}.state.json")
    doc = JSON.parse(File.read(state, encoding: "UTF-8"))
    doc.is_a?(Hash) && doc["rotated_at"].is_a?(String) ? doc["rotated_at"] : nil
  rescue SystemCallError, JSON::ParserError, EncodingError
    nil
  end

  # streams(root) -> [[live basename, [paths oldest first]]] in name order.
  def streams(root)
    live = Dir.glob(File.join(root, "*-slack.jsonl"))
    gens = Dir.glob(File.join(root, "*-slack.jsonl#{GENERATION}"))
    names = (live + gens.map { |g| g.delete_suffix(GENERATION) }).map { |p| File.basename(p) }.uniq.sort
    names.map do |name|
      path = File.join(root, name)
      [name, ["#{path}#{GENERATION}", path].select { |p| File.file?(p) }]
    end.reject { |_name, paths| paths.empty? }
  end

  def parse(raw)
    JSON.parse(raw)
  rescue JSON::ParserError, EncodingError
    nil
  end
end
