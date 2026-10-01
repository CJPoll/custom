# frozen_string_literal: true

# epic_clustering_fixture -- the offline source behind
# `scripts/epic-clustering --from-json FILE` (DND-982). It answers the same
# calls as EpicClusteringNotion from a JSON file, so the self-test and a dry
# run exercise the script end to end with no network:
#
#   {"epics":   [{"page_id","name","status","project"}],
#    "tickets": [{"id","page_id","title","status","kind","severity","security",
#                 "path","area","epic_ids":[page ids],"depends_on":[page ids],
#                 "blocks":[page ids],"created","body"}]}
#
# A body of null reads as unread. Every miss raises
# NextMissionNotion::ReadError, like the real adapter.
require "json"
require_relative "epic_clustering"
require_relative "epic_clustering_notion"

class EpicClusteringFixture
  class FixtureError < StandardError; end

  TICKET_FIELDS = %w[id page_id title status kind severity security path area created body].freeze

  def initialize(path)
    data = JSON.parse(File.read(path))
    raise FixtureError, "top level is not an object" unless data.is_a?(Hash)
    unless data["epics"].is_a?(Array) && data["tickets"].is_a?(Array)
      raise FixtureError, "\"epics\" and \"tickets\" must be arrays"
    end

    @epics = data["epics"].map do |h|
      EpicClustering::Epic.new(page_id: h.fetch("page_id"), name: h.fetch("name"), status: h["status"],
                               project: h["project"])
    end
    @tickets = data["tickets"].map do |h|
      EpicClustering::Ticket.new(**TICKET_FIELDS.to_h { |k| [k.to_sym, h[k]] },
                                 epic_ids: Array(h["epic_ids"]), depends_on: Array(h["depends_on"]),
                                 blocks: Array(h["blocks"]))
    end
  rescue SystemCallError, JSON::ParserError, TypeError, KeyError, NoMethodError => e
    raise FixtureError, "#{path}: #{e.class}: #{e.message}"
  end

  def epic_with_tickets(key)
    e = @epics.find { |x| x.page_id == key || x.name == key }
    raise NextMissionNotion::ReadError, "no epic #{key.inspect} in the fixture" if e.nil?

    [e, @tickets.select { |t| t.epic_ids.include?(e.page_id) }]
  end

  def open_epics = @epics.select { |e| EpicClusteringNotion::OPEN_EPIC_STATUSES.include?(e.status) }
  def all_epics = @epics
  # Bodies come only through #body, as with Notion, so an unreadable body
  # stays nil (unread) and is never judged from a pre-filled value.
  def open_tickets
    @tickets.select { |t| EpicClustering.open?(t) }.map { |t| t.dup.tap { |x| x.body = nil } }
  end

  # ["DND-12", ...] -> {"DND-12" => page id}; a missing id raises, as Notion's does.
  def page_ids(ids)
    ids.to_h do |id|
      t = @tickets.find { |x| x.id == id }
      raise NextMissionNotion::ReadError, "no ticket page for #{id} in the fixture" if t.nil?

      [id, t.page_id]
    end
  end

  def body(page_id)
    t = @tickets.find { |x| x.page_id == page_id }
    raise NextMissionNotion::ReadError, "no ticket page #{page_id} in the fixture" if t.nil?
    raise NextMissionNotion::ReadError, "HTTP 429 (fixture: body unreadable)" if t.body == "__unreadable__"

    t.body
  end
end
