# frozen_string_literal: true

# dispatch_trackers -- which Notion tracker holds a ticket's dispatch stamp
# (DND-1318, DND-1341). DOMAIN: pure rules; it reads nothing. Its only
# environment input is Dir.home, for the token-file path constants, and it
# takes the DND ids from next_mission_notion's constants.
#
# Lead time starts at captain dispatch: the ticket's first move to In Progress,
# stamped in a date property by
# ai/skills/athena:ticket-management/scripts/mark-in-progress and read back by
# ai/bin/lead-time (ai/docs/lead-time-tracking.md -> The START marker). Two
# trackers carry that stamp:
#
#   DND   the personal DND Tickets database. Public, fixed below.
#   work  the work tracker (walt_ui tickets). Its data source, ticket prefix,
#         stamp property and first-dispatch statuses are WORK VALUES: this repo
#         is public, so they live in the private overlay
#         (ai/contracts/athena-private-overlay.md -> Overlay files) and are
#         read by ai/lib/dispatch_trackers_overlay.rb. This file only builds
#         and validates the tracker from those values.
#
# A missing or malformed work value is a named refusal, never a guess
# (~/dev/custom/ai/CLAUDE.md -> A failed lookup must never look like an empty
# one). A refusal names the overlay KEY, never the value it read.

require "json"
require_relative "next_mission_notion"

module DispatchTrackers
  # prefix: the unique_id prefix (DND-12 -> "DND"). label: how messages name
  # the database (never a work value). property: the date property holding the
  # stamp. first_dispatch_from: statuses a move to In Progress from which is a
  # FIRST dispatch, so it may stamp now.
  Tracker = Struct.new(:prefix, :label, :data_source, :property, :token_file, :first_dispatch_from,
                       keyword_init: true)

  # tracker, or nil with reason (a line carrying Fix:). fault: false only when
  # the overlay is ABSENT on this machine (the feature is unavailable here);
  # true when an overlay exists but cannot give a valid tracker.
  Resolution = Struct.new(:tracker, :reason, :fault, keyword_init: true)

  IN_PROGRESS = "In Progress"

  DND = Tracker.new(
    prefix: NextMissionNotion::TICKET_PREFIX,
    label: "DND Tickets",
    data_source: NextMissionNotion::TICKETS_DATA_SOURCE,
    property: "In Progress at",
    token_file: File.join(Dir.home, ".claude", "notion-personal-token"),
    first_dispatch_from: %w[Todo Backlog].freeze,
  ).freeze

  # The notion-work integration token (ai/secrets/registry.json ->
  # notion-work-token). A path, not a work value.
  WORK_TOKEN_FILE = File.join(Dir.home, ".claude", "notion-api-token")

  # overlay/notion.json keys (ai/contracts/athena-private-overlay.md -> Keys in use).
  OVERLAY_FILE = "notion"
  WORK_KEYS = {
    data_source: ".work.tickets_data_source",
    prefix: ".work.ticket_prefix",
    property: ".work.in_progress_property",
    first_dispatch_from: ".work.first_dispatch_from",
  }.freeze

  PREFIX_RE = /\A[A-Z]{2,10}\z/.freeze
  REF_RE = /\A([A-Z]{2,10})-([1-9][0-9]{0,6})\z/.freeze

  module_function

  # values: {data_source:, prefix:, property:, first_dispatch_from:} as the
  # overlay renders them (first_dispatch_from is a JSON array string).
  # -> Resolution.
  def work_from(values)
    prefix = values[:prefix].to_s
    return refuse(:prefix, "is not 2-10 upper-case letters") unless PREFIX_RE.match?(prefix)
    return refuse(:prefix, "is #{DND.prefix}, which would shadow the DND tracker") if prefix == DND.prefix

    ds = values[:data_source].to_s
    return refuse(:data_source, "is not a Notion data source id") unless NextMissionNotion::PAGE_ID_RE.match?(ds)

    property = values[:property].to_s
    return refuse(:property, "is empty") if property.strip.empty?

    from = parse_statuses(values[:first_dispatch_from])
    return refuse(:first_dispatch_from, "is not a JSON array of status names") unless from
    return refuse(:first_dispatch_from, "names #{IN_PROGRESS}, so every re-dispatch would restamp") if from.include?(IN_PROGRESS)

    Resolution.new(tracker: Tracker.new(prefix: prefix, label: "the work tracker", data_source: ds,
                                        property: property, token_file: WORK_TOKEN_FILE,
                                        first_dispatch_from: from.freeze).freeze,
                   reason: nil, fault: false)
  end

  # ref: "DND-12" / "<work prefix>-12". work: -> Resolution, called only for a
  # non-DND ref. -> [tracker, nil, nil] or [nil, reason, exit] (2 usage, 3 the
  # work tracker cannot be resolved).
  def for_ref(ref, work:)
    m = REF_RE.match(ref.to_s)
    unless m
      return [nil, "#{ref.inspect} is not a ticket id like DND-1318. Fix: pass --ref <PREFIX>-<number>.", 2]
    end
    return [DND, nil, nil] if m[1] == DND.prefix

    res = work.call
    unless res.tracker
      return [nil, "#{ref} is not a #{DND.prefix} ticket (check it is not mistyped), and the work tracker " \
                   "could not be resolved: #{res.reason}", 3]
    end
    return [res.tracker, nil, nil] if m[1] == res.tracker.prefix

    [nil, "#{ref} names no known tracker (#{DND.prefix} or #{res.tracker.prefix}). " \
          "Fix: pass a #{DND.prefix}-N or #{res.tracker.prefix}-N ticket id.", 2]
  end

  def parse_statuses(text)
    list = JSON.parse(text.to_s)
    return nil unless list.is_a?(Array) && !list.empty?
    return nil unless list.all? { |s| s.is_a?(String) && !s.strip.empty? }

    list
  rescue JSON::ParserError
    nil
  end

  def refuse(key, why)
    Resolution.new(tracker: nil, fault: true,
                   reason: "the private overlay's #{OVERLAY_FILE}#{WORK_KEYS.fetch(key)} #{why}. " \
                           "Fix: correct #{WORK_KEYS.fetch(key)} in the overlay's overlay/#{OVERLAY_FILE}.json " \
                           "(ai/contracts/athena-private-overlay.md -> Keys in use).")
  end
end
