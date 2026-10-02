# frozen_string_literal: true

# ai/lib/notion_write.rb -- the narrow Notion WRITE client (Side Effects)
# behind scripts/ticket-file (DND-1669) and athena:lead-time-improve's
# scripts/unmeasurable (DND-1806): create a page, append blocks to a page,
# and set one allow-listed select property on a page. Nothing else.
#
# #write admits exactly three requests and refuses any other BEFORE it is sent:
#   POST  /v1/pages                     create a page
#   PATCH /v1/blocks/<uuid>/children    append blocks
#   PATCH /v1/pages/<uuid>              set ONE select property, only to a
#                                       value SELECTS lists (today: Path =
#                                       Promoted); any other body is refused
# None is retried. The first two are non-idempotent: a 5xx after Notion
# stored the page would file it twice. A failure raises NotionRead::Error and
# the caller says what may already exist.
#
# It shares NotionRead's transport (curl, the token on STDIN, never argv or
# the environment) and its credentials (the file the notion-personal MCP entry
# names). Reads stay on NotionRead, which refuses every write.
#
# Deliberately gem-free (stdlib only).

require "json"
require_relative "notion_read"

module NotionWrite
  PAGE_PATCH = %r{\A/v1/pages/#{NotionRead::UUID}\z}.freeze
  WRITES = [
    ["POST", %r{\A/v1/pages\z}],
    ["PATCH", %r{\A/v1/blocks/#{NotionRead::UUID}/children\z}],
    ["PATCH", PAGE_PATCH]
  ].freeze
  # The select properties a page PATCH may set, and the values it may set
  # them to. Path = Promoted is the lead-time improver's escalation (DND-1806).
  SELECTS = { "Path" => ["Promoted"].freeze }.freeze

  # A request this client refused before sending it: nothing reached Notion.
  class Refused < NotionRead::Error; end

  module_function

  def write?(method, path, body = nil)
    return false unless WRITES.any? { |m, re| m == method && re.match?(path) }
    return select_patch?(body) if method == "PATCH" && PAGE_PATCH.match?(path)

    true
  end

  # A page PATCH body sets exactly one allow-listed select to an allowed
  # value, and nothing else (no archive, no other property, no other type).
  def select_patch?(body)
    return false unless body.is_a?(Hash) && body.keys == ["properties"]

    props = body["properties"]
    return false unless props.is_a?(Hash) && props.size == 1

    name, value = props.first
    value.is_a?(Hash) && value.keys == ["select"] && value["select"].is_a?(Hash) &&
      value["select"].keys == ["name"] && SELECTS.fetch(name, []).include?(value["select"]["name"])
  end

  # write(origin, token, method, path, body) -> parsed JSON, or raises
  # Refused (nothing sent) or NotionRead::Error (status set when Notion
  # answered).
  def write(origin, token, method, path, body)
    raise Refused.new("refused a Notion #{method} #{path}: this client only creates pages and appends blocks, and sets one allow-listed select value (SELECTS)", "this is a bug in the caller") unless write?(method, path, body)

    reply = NotionRead.request(method, "#{origin}#{path}", token, body)
    if reply[:curl_rc] != 0
      raise NotionRead::Error.new("no answer from Notion to #{method} #{path} (curl exit #{reply[:curl_rc]}: unreachable, or timed out after the request was sent)",
                                  "check the network")
    end
    unless reply[:status] == 200
      message = begin
        JSON.parse(reply[:body])["message"].to_s
      rescue JSON::ParserError, TypeError
        ""
      end
      raise NotionRead::Error.new("Notion answered HTTP #{reply[:status]} to #{method} #{path}: #{message[0, 200]}",
                                  "read the message; on 401/403 the token or the data source share is the owner's to fix", status: reply[:status])
    end
    JSON.parse(reply[:body])
  rescue JSON::ParserError
    raise NotionRead::Error.new("Notion answered a body that is not JSON to #{method} #{path}", "check the tracker before re-running")
  end

  # create_page(origin, token, data_source, properties, children) -> the page.
  def create_page(origin, token, data_source, properties, children)
    body = { "parent" => { "type" => "data_source_id", "data_source_id" => data_source }, "properties" => properties, "children" => children }
    write(origin, token, "POST", "/v1/pages", body)
  end

  # append(origin, token, page_id, children) -> Notion's answer.
  def append(origin, token, page_id, children)
    write(origin, token, "PATCH", "/v1/blocks/#{page_id}/children", { "children" => children })
  end

  # set_select(origin, token, page_id, property, value) -> the page. Only a
  # property and value SELECTS allows; anything else is Refused unsent.
  def set_select(origin, token, page_id, property, value)
    write(origin, token, "PATCH", "/v1/pages/#{page_id}", { "properties" => { property => { "select" => { "name" => value } } } })
  end
end
