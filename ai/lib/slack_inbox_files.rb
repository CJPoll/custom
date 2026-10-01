# frozen_string_literal: true

# ai/lib/slack_inbox_files.rb -- EFFECTS: read every *-slack.jsonl directly
# under an Athena inbox root, the one reader ai/bin/judgment-eval (a
# slack_routing context, DND-1048) and ai/bin/judgment-label (the root
# snapshot's context, DND-1448) share, so the two never read the inbox
# differently.
#
# A root that is missing, or that holds no *-slack.jsonl, is an Error: zero
# files must never read as "no context before any root". A line that is not
# a JSON object is skipped and COUNTED, never silently dropped. Each Error
# carries its Fix; the bins print it.
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

  module_function

  # read(root) -> {files: [{name: basename, rows: [Hash]}], unreadable: n},
  # files in name order. Raises Error naming what could not be read.
  def read(root)
    raise Error.new("the inbox root #{root} does not exist", "pass --inbox-root (or set ATHENA_INBOX_ROOT) to the directory holding the *-slack.jsonl inboxes") unless File.directory?(root)

    paths = Dir.glob(File.join(root, "*-slack.jsonl")).sort
    raise Error.new("no *-slack.jsonl file directly under #{root} (0 files)", "pass --inbox-root to the directory holding walt_ui-slack.jsonl; with no inbox lines no context can be built") if paths.empty?

    unreadable = 0
    files = paths.map do |path|
      rows = []
      begin
        File.foreach(path, encoding: "UTF-8") do |raw|
          next if raw.strip.empty?

          row = parse(raw)
          row.is_a?(Hash) ? rows << row : unreadable += 1
        end
      rescue SystemCallError => e
        raise Error.new("could not read #{path}: #{e.class}", "check that inbox file's permissions")
      end
      { name: File.basename(path), rows: rows }
    end
    { files: files, unreadable: unreadable }
  end

  def parse(raw)
    JSON.parse(raw)
  rescue JSON::ParserError, EncodingError
    nil
  end
end
