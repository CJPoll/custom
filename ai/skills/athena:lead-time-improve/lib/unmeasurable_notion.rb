# frozen_string_literal: true

# LeadTimeUnmeasurableNotion -- SIDE EFFECTS: the Notion port of the
# unmeasurable-phase escalation (DND-1806). Three calls, nothing else:
#
#   ticket(ref)          POST  /v1/data_sources/<DND Tickets>/query (by ID)
#   promote(page_id)     PATCH /v1/pages/<id>  body: Path = Promoted, only
#   note(page_id, text)  PATCH /v1/blocks/<id>/children  one paragraph
#
# The read goes through NotionRead (its allowlist and retry policy), the
# note through NotionWrite.append, and the promotion through NotionRead's
# curl transport with a body this file builds and nothing else may widen.
# The token is NotionRead's: the file the notion-personal MCP entry names,
# fed to curl on stdin, never argv or the environment.
#
# LEADTIME_UNMEASURABLE_NOTION_API: a loopback URL for tests (a fake Notion);
# unset, api.notion.com.

require "json"
require_relative "../../../lib/notion_read"
require_relative "../../../lib/notion_write"
require_relative "../../../lib/next_mission_notion"
require_relative "unmeasurable_manager"

class LeadTimeUnmeasurableNotion
  # DND Tickets, from its one home.
  DATA_SOURCE = NextMissionNotion::TICKETS_DATA_SOURCE
  PREFIX = NextMissionNotion::TICKET_PREFIX
  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze
  PortError = LeadTimeUnmeasurableManager::PortError

  def initialize(env: ENV)
    @api = env["LEADTIME_UNMEASURABLE_NOTION_API"]
    @creds = nil
  end

  # -> {id:, status:, path:}. The page found must carry the ID asked for:
  # both sides of the lookup are checked.
  def ticket(ref)
    number = Integer(ref.split("-", 2).last, 10)
    body = { "filter" => { "property" => "ID", "unique_id" => { "equals" => number } }, "page_size" => 2 }
    res = NotionRead.read(*creds, "POST", "/v1/data_sources/#{DATA_SOURCE}/query", body, pace: 0)
    pages = Array(res["results"])
    raise PortError, "there is no #{ref} in DND Tickets" if pages.empty?
    raise PortError, "#{pages.size} pages in DND Tickets answer to #{ref}" if pages.size > 1

    facts(pages.first, ref, number)
  rescue NotionRead::Error => e
    raise PortError, "#{e.message} (#{e.fix})"
  end

  def promote(page_id)
    page_id = uuid(page_id)
    origin, token = creds
    body = { "properties" => { "Path" => { "select" => { "name" => LeadTimeUnmeasurable::PROMOTED } } } }
    reply = NotionRead.request("PATCH", "#{origin}/v1/pages/#{page_id}", token, body)
    raise PortError, "no answer from Notion to the Path PATCH (curl exit #{reply[:curl_rc]})" unless reply[:curl_rc].zero?
    raise PortError, "Notion answered HTTP #{reply[:status]} to the Path PATCH on #{page_id}" unless reply[:status] == 200

    true
  rescue NotionRead::Error => e
    raise PortError, "#{e.message} (#{e.fix})"
  end

  def note(page_id, text)
    block = { "object" => "block", "type" => "paragraph",
              "paragraph" => { "rich_text" => [{ "type" => "text", "text" => { "content" => text[0, 1900] } }] } }
    NotionWrite.append(*creds, uuid(page_id), [block])
    true
  rescue NotionRead::Error => e
    raise PortError, "#{e.message} (#{e.fix})"
  end

  private

  def creds
    @creds ||= NotionRead.credentials(@api)
  end

  def uuid(id)
    raise PortError, "page id #{id.inspect} is not a Notion page id" unless UUID_RE.match?(id.to_s)

    id
  end

  def facts(page, ref, number)
    props = page["properties"] || {}
    uid = props.dig("ID", "unique_id") || {}
    unless uid["prefix"] == PREFIX && uid["number"] == number
      raise PortError, "the page Notion returned for #{ref} carries ID #{uid['prefix']}-#{uid['number']}"
    end
    raise PortError, "#{ref} has no Status property of type status" unless props.dig("Status", "type") == "status"
    raise PortError, "#{ref} has no Path property of type select" unless props.dig("Path", "type") == "select"

    { id: uuid(page["id"]), status: props.dig("Status", "status", "name"), path: props.dig("Path", "select", "name") }
  end
end
