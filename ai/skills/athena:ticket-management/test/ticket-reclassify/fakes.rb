# frozen_string_literal: true

# The ticket-reclassify fakes (DND-1056): a tracker, a classification server
# and a clock, shared by manager_test.rb and e2e_test.rb. Loads the script
# (it runs main only when it IS the program). Synthetic ids only.

require "json"
require_relative "helper"

SCRIPT = File.expand_path("../../scripts/ticket-reclassify", __dir__)
load SCRIPT

EPIC = "e0000000-0000-0000-0000-000000000001"

# The fake tracker: tickets by number, each with its body lines; pages as
# they read after an apply. Every call is recorded.
class FakeNotion
  attr_reader :calls, :tickets, :pages, :bodies
  attr_accessor :unreadable

  def initialize(tickets)
    @tickets = tickets
    @bodies = tickets.to_h { |t| [t["page_id"], t["blocks_text"]] }
    @pages = tickets.to_h { |t| [t["page_id"], Reclassify.current(t)] }
    @calls = []
    @unreadable = []
  end

  def query(data_source)
    @calls << [:query, data_source]
    return project_rows if data_source == Effects::PROJECTS_DATA_SOURCE

    @tickets.map { |t| row(t) }
  end

  def children(page_id)
    @calls << [:children, page_id]
    raise NotionRead::Error.new("Notion answered HTTP 404 to GET /v1/blocks/#{page_id}/children", "re-run", status: 404) if @unreadable.include?(page_id)

    @bodies.fetch(page_id).map { |text| { "type" => "paragraph", "paragraph" => { "rich_text" => [{ "plain_text" => text }] } } }
  end

  def page(page_id)
    @calls << [:page, page_id]
    raise NotionRead::Error.new("Notion answered HTTP 404 to GET /v1/pages/#{page_id}", "re-run", status: 404) if @unreadable.include?(page_id)

    v = @pages.fetch(page_id)
    { "properties" => Reclassify::PROPS.to_h { |k, name| [name, { "select" => v[k] && { "name" => v[k] } }] } }
  end

  # apply(entry) -> what the captain does: the properties, then one paragraph.
  def apply(entry)
    @pages[entry["page_id"]] = entry["decided"].dup
    @bodies[entry["page_id"]] = @bodies[entry["page_id"]] + [entry["provenance_line"]]
  end

  def project_rows
    TriageCorpus::REPO_APPS.values.flatten.map do |app|
      { "properties" => { "Repo / App" => { "select" => { "name" => app } },
                          "Epics" => { "relation" => app == "~/dev/custom" ? [{ "id" => EPIC }] : [], "has_more" => false } } }
    end
  end

  def row(t)
    number = t["ref"].delete_prefix("DND-").to_i
    sel = ->(v) { { "select" => v && { "name" => v } } }
    { "id" => t["page_id"], "created_time" => "2026-09-28T01:00:00.000Z",
      "properties" => {
        "ID" => { "unique_id" => { "prefix" => "DND", "number" => number } },
        "Name" => { "title" => [{ "plain_text" => t["title"] }] },
        "Status" => { "status" => { "name" => t["status"] } },
        # No epic and Area Harness is the harness project (TriageCorpus.project_of),
        # so a ticket with no project carries another Area.
        "Area" => { "select" => { "name" => t["project"] ? "Harness" : "Product" } },
        "Kind" => sel.call(t["kind"]), "Severity" => sel.call(t["severity"]), "Security" => sel.call(t["security"]),
        "Epic" => { "relation" => t["project"] ? [{ "id" => EPIC }] : [], "has_more" => false },
        "Depends On" => { "relation" => [], "has_more" => false }, "Blocks" => { "relation" => [], "has_more" => false },
        "Found while" => { "relation" => [], "has_more" => false }
      } }
  end
end

# The fake server: decides by a block (body, filer) -> [decided, mode, reason].
class FakeServer
  attr_reader :bodies

  def initialize(&decide)
    @decide = decide
    @bodies = []
  end

  def post(body)
    @bodies << body
    decided, mode, reason = @decide.call(body)
    { curl_rc: 0, status: 200, body: answer(decided, mode, reason: reason) }
  end
end

class FakeClock
  attr_reader :calls

  def initialize
    @t = 0.0
  end

  def now = @t
  def sleep(seconds) = (@t += seconds)
  def advance(seconds) = (@t += seconds)
end

def filer_of(body) = { "kind" => body["filer"]["kind"], "severity" => body["filer"]["severity"], "security" => body["filer"]["security"] }
