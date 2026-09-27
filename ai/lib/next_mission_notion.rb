# frozen_string_literal: true

# next_mission_notion -- the Notion READ adapter behind ai/bin/next-mission
# (DND-985). It turns a scope (an epic, and/or a list of ticket ids) into
# NextMission::Ticket values, plus the status of every dependency that lies
# outside the scope. It only ever reads.
#
# Transport: an object answering call(method, path, body) -> parsed JSON Hash,
# raising ReadError on any failure. HttpTransport is the real one (Notion REST,
# in-process Net::HTTP, so the token never reaches argv); the self-test injects
# a fake.
#
# Every miss is an error, never a smaller answer (~/dev/custom/ai/CLAUDE.md ->
# "A failed lookup must never look like an empty one"): an HTTP failure, an
# epic name that matches no epic (or several), a requested ticket id that
# matches no page, and a page missing a property the selector reads.
require "json"
require "net/http"
require "uri"
require_relative "next_mission"

class NextMissionNotion
  class ReadError < StandardError; end

  # DND Tickets and DND Epics (notion-personal workspace).
  TICKETS_DATA_SOURCE = "219349da-87fb-8063-8f36-000b362fbd60"
  EPICS_DATA_SOURCE   = "f4231817-18f3-4c2d-ac5b-b1151a5bb020"
  NOTION_VERSION      = "2025-09-03"
  PAGE_ID_RE          = /\A\h{8}-?\h{4}-?\h{4}-?\h{4}-?\h{12}\z/.freeze
  # The DND Tickets unique_id prefix. --tickets ids must carry it, because the
  # unique_id filter matches the number alone.
  TICKET_PREFIX       = "DND"

  Scope = Struct.new(:scope, :external, keyword_init: true)

  # Real transport: Notion REST over Net::HTTP. Retries 429/5xx a bounded
  # number of times, honouring Retry-After.
  class HttpTransport
    BASE = URI("https://api.notion.com")
    ATTEMPTS = 3

    def initialize(token)
      @token = token
    end

    def call(method, path, body = nil)
      attempt = 0
      loop do
        attempt += 1
        res = request(method, path, body)
        code = res.code.to_i
        return parse(res.body, method, path) if code.between?(200, 299)

        if (code == 429 || code >= 500) && attempt < ATTEMPTS
          sleep([[res["Retry-After"].to_f, 1.0].max, 10.0].min)
          next
        end
        raise ReadError, "HTTP #{code} on #{method.upcase} #{path}: #{error_message(res.body)}"
      end
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
           IOError => e # IOError covers EOFError: a connection dropped mid-response
      raise ReadError, "#{e.class} on #{method.upcase} #{path}: #{e.message}"
    end

    private

    def request(method, path, body)
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(path)
      req["Authorization"] = "Bearer #{@token}"
      req["Notion-Version"] = NOTION_VERSION
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      Net::HTTP.start(BASE.host, BASE.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |h| h.request(req) }
    end

    def parse(raw, method, path)
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise ReadError, "unparseable JSON from #{method.upcase} #{path}: #{e.message}"
    end

    def error_message(raw)
      JSON.parse(raw)["message"].to_s
    rescue StandardError
      raw.to_s[0, 200]
    end
  end

  def initialize(transport)
    @t = transport
  end

  # epic: an epic page id (32 hex, dashes optional) or an exact epic title.
  # tickets: ["DND-12", ...]. At least one of the two.
  def load(epic: nil, tickets: nil)
    raise ArgumentError, "load needs epic: or tickets:" if epic.nil? && (tickets.nil? || tickets.empty?)

    pages = {}
    query_epic(resolve_epic(epic)).each { |p| pages[p["id"]] = p } if epic
    query_ids(tickets).each { |p| pages[p["id"]] = p } if tickets && !tickets.empty?

    scope_rows = pages.values.map { |p| [p, parse_page(p)] }
    id_of = scope_rows.to_h { |p, tk| [p["id"], tk.id] }
    external = []
    scope_rows.each do |p, tk|
      tk.depends_on = relation_ids(p, "Depends On").map do |dep_page|
        id_of[dep_page] ||= begin
          dep = @t.call(:get, "/v1/pages/#{dep_page}")
          # A trashed dependency keeps its last status, so a trashed Todo would
          # block its dependent forever with no sign of why.
          raise ReadError, "#{tk.id} depends on page #{dep_page}, which is in the trash" if dep["in_trash"]

          ext = parse_page(dep, external: true)
          external << ext
          ext.id
        end
      end
    end
    Scope.new(scope: scope_rows.map(&:last), external: external)
  end

  private

  def resolve_epic(key)
    return verified_epic_id(dashed(key)) if key.match?(PAGE_ID_RE)

    body = { "filter" => { "property" => "Name", "title" => { "equals" => key } }, "page_size" => 10 }
    hits = @t.call(:post, "/v1/data_sources/#{EPICS_DATA_SOURCE}/query", body).fetch("results")
    raise ReadError, "no epic titled #{key.inspect} in the DND Epics data source" if hits.empty?
    raise ReadError, "#{hits.size} epics are titled #{key.inspect}; pass the epic page id instead" if hits.size > 1

    hits.first.fetch("id")
  end

  # A well-formed id is still only a key: a typo, a ticket's page id, or an
  # epic from another workspace would make the Epic filter match nothing and
  # read as an empty epic. So the id must name a live page in DND Epics.
  def verified_epic_id(id)
    page = @t.call(:get, "/v1/pages/#{id}")
    parent = page.dig("parent", "data_source_id")
    unless parent == EPICS_DATA_SOURCE
      raise ReadError, "page #{id} is not a DND epic (its parent is #{page['parent'].inspect}); " \
                       "pass an epic page id or an exact epic title"
    end
    raise ReadError, "epic page #{id} is in the trash" if page["in_trash"]

    id
  end

  def dashed(key)
    h = key.delete("-").downcase
    [h[0, 8], h[8, 4], h[12, 4], h[16, 4], h[20, 12]].join("-")
  end

  def query_epic(epic_id)
    query_all("filter" => { "property" => "Epic", "relation" => { "contains" => epic_id } })
  end

  def query_ids(ids)
    nums = ids.map { |i| i.split("-").last.to_i }
    found = []
    nums.each_slice(100) do |slice|
      filter = { "or" => slice.map { |n| { "property" => "ID", "unique_id" => { "equals" => n } } } }
      found.concat(query_all("filter" => filter))
    end
    got = found.map { |p| parse_page(p).id }
    missing = ids - got
    raise ReadError, "no ticket page for #{missing.join(', ')} in the DND Tickets data source" unless missing.empty?

    found
  end

  def query_all(body)
    out = []
    cursor = nil
    loop do
      req = body.merge("page_size" => 100)
      req["start_cursor"] = cursor if cursor
      res = @t.call(:post, "/v1/data_sources/#{TICKETS_DATA_SOURCE}/query", req)
      out.concat(res.fetch("results"))
      break unless res["has_more"]

      cursor = res["next_cursor"] or raise ReadError, "query reported has_more with no next_cursor"
    end
    out
  rescue KeyError => e
    raise ReadError, "malformed query response: #{e.message}"
  end

  # All related page ids, paging the property endpoint when the page object
  # truncated the relation (has_more: true, over 25 entries).
  def relation_ids(page, name)
    prop = prop!(page, name, "relation")
    return prop["relation"].map { |r| r.fetch("id") } unless prop["has_more"]

    ids = []
    path = "/v1/pages/#{page['id']}/properties/#{prop.fetch('id')}"
    cursor = nil
    loop do
      res = @t.call(:get, cursor ? "#{path}?start_cursor=#{URI.encode_www_form_component(cursor)}" : path)
      ids.concat(res.fetch("results").map { |item| item.fetch("relation").fetch("id") })
      break unless res["has_more"]

      cursor = res["next_cursor"] or raise ReadError, "#{name} on #{page['id']} reported has_more with no next_cursor"
    end
    ids
  rescue KeyError => e
    raise ReadError, "malformed #{name} relation on page #{page['id']}: #{e.message}"
  end

  def parse_page(page, external: false)
    uid = prop!(page, "ID", "unique_id")["unique_id"]
    id = "#{uid['prefix']}-#{uid['number']}"
    status = prop!(page, "Status", "status")["status"]&.fetch("name")
    return NextMission::Ticket.new(id: id, page_id: page["id"], status: status, depends_on: []) if external

    NextMission::Ticket.new(
      id: id, page_id: page["id"],
      title: prop!(page, "Name", "title")["title"].map { |t| t["plain_text"] }.join,
      status: status,
      kind: select(page, "Kind"), severity: select(page, "Severity"),
      path: select(page, "Path"), area: select(page, "Area"),
      depends_on: [], created: page["created_time"]
    )
  rescue KeyError, NoMethodError, TypeError => e
    # A null unique_id, title, or status name: the page is not shaped as the
    # selector reads it. Name it rather than crash (a crash would exit 1).
    raise ReadError, "page #{page.is_a?(Hash) ? page['id'] : page.inspect} is malformed: #{e.class}: #{e.message}"
  end

  def select(page, name)
    prop!(page, name, "select")["select"]&.fetch("name")
  end

  def prop!(page, name, type)
    prop = page.fetch("properties", {})[name]
    raise ReadError, "page #{page['id']} has no #{name.inspect} property (DND Tickets schema changed?)" if prop.nil?
    raise ReadError, "page #{page['id']} property #{name.inspect} is #{prop['type']}, expected #{type}" unless prop["type"] == type

    prop
  end
end
