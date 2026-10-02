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
require_relative "notion_retry"

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
  # A harness-lane epic (DND-987, P7) is a DND epic whose title starts with
  # this. The harness lane's scope is every such epic not Done/Cancelled
  # (ai/docs/ticket-lane-action-brief.md -> The harness lane).
  LANE_EPIC_PREFIX    = "Harness lane: "

  Scope = Struct.new(:scope, :external, keyword_init: true)

  # Real transport: Notion REST over Net::HTTP.
  #
  # Retry policy (DND-1519): NotionRetry (ai/lib/notion_retry.rb), the one
  # policy NotionRead shares (DND-1649). A 429 or a 5xx is retried with
  # Retry-After or backoff inside a wait budget; any other 4xx is never
  # retried. An exhausted call raises a ReadError naming the status and the
  # tries. A transport holds one policy object, so after a call exhausts its
  # retries, later calls on this transport are tried once each until one
  # succeeds: a sustained outage costs one budget per run, not one per call.
  # Either way the failure raises; it never reads as an empty answer.
  class HttpTransport
    BASE = URI("https://api.notion.com")

    LOOPBACK_HOSTS = %w[127.0.0.1 localhost].freeze

    # base: the API origin. Only the real one, or a loopback http origin for a
    # test's fake server. wait: called with the seconds to wait before a retry;
    # a test injects a recorder so no test waits on the wall clock (DND-1222).
    def initialize(token, base: BASE, wait: ->(seconds) { sleep(seconds) })
      @token = token
      @base = self.class.checked_base(base)
      @retrier = NotionRetry.new(wait: wait)
    end

    def self.checked_base(base)
      uri = base.is_a?(URI::Generic) ? base : URI(base.to_s)
      return uri if uri == BASE
      return uri if uri.scheme == "http" && LOOPBACK_HOSTS.include?(uri.host) && ["", "/"].include?(uri.path.to_s)

      raise ArgumentError, "Notion base #{uri} is neither #{BASE} nor a loopback http origin. " \
                           "Fix: omit base: (the real API), or pass http://127.0.0.1:PORT in a test."
    end

    def call(method, path, body = nil)
      result = @retrier.run do
        res = request(method, path, body)
        [res.code.to_i, res["Retry-After"], res]
      end
      return parse(result.reply.body, method, path) if result.ok?

      raise ReadError, failure(result, method, path)
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
           IOError => e # IOError covers EOFError: a connection dropped mid-response
      raise ReadError, "#{e.class} on #{method.upcase} #{path}: #{e.message}"
    end

    private

    def failure(result, method, path)
      tries = result.attempts == 1 ? "1 attempt" : "#{result.attempts} attempts"
      note = result.retryable && result.degraded ? " (not retried: an earlier call exhausted its retries)" : ""
      "HTTP #{result.status} on #{method.upcase} #{path} after #{tries}#{note}: #{error_message(result.reply.body)}"
    end

    def request(method, path, body)
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(path)
      req["Authorization"] = "Bearer #{@token}"
      req["Notion-Version"] = NOTION_VERSION
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      Net::HTTP.start(@base.host, @base.port, use_ssl: @base.scheme == "https",
                                              open_timeout: 15, read_timeout: 30) { |h| h.request(req) }
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
  # tickets: ["DND-12", ...]. epics: epic page ids already read from DND Epics
  # (lane_epics), unioned. At least one of the three.
  def load(epic: nil, tickets: nil, epics: nil)
    if epic.nil? && (tickets.nil? || tickets.empty?) && (epics.nil? || epics.empty?)
      raise ArgumentError, "load needs epic:, tickets: or epics:"
    end

    pages = {}
    query_epic(resolve_epic(epic)).each { |p| pages[p["id"]] = p } if epic
    (epics || []).each { |e| query_epic(e).each { |p| pages[p["id"]] = p } }
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

  # The open harness-lane epics -> [[{id:, title:}, ...], [dropped titles]].
  # Notion's starts_with is looser than the convention, so a hit whose title
  # does not start with the exact prefix is dropped and returned for the caller
  # to report. No match is an empty list; the caller says which prefix found
  # nothing. A failed read raises ReadError.
  def lane_epics
    filter = { "and" => [
      { "property" => "Name", "title" => { "starts_with" => LANE_EPIC_PREFIX } },
      { "property" => "Status", "select" => { "does_not_equal" => "Done" } },
      { "property" => "Status", "select" => { "does_not_equal" => "Cancelled" } }
    ] }
    rows = query_all({ "filter" => filter }, EPICS_DATA_SOURCE).map do |p|
      { id: p.fetch("id"), title: prop!(p, "Name", "title")["title"].map { |t| t["plain_text"] }.join }
    end
    kept, dropped = rows.partition { |r| r[:title].start_with?(LANE_EPIC_PREFIX) }
    [kept, dropped.map { |r| r[:title] }]
  rescue KeyError, NoMethodError, TypeError => e
    raise ReadError, "malformed DND Epics row: #{e.class}: #{e.message}"
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

  def query_all(body, data_source = TICKETS_DATA_SOURCE)
    out = []
    cursor = nil
    loop do
      req = body.merge("page_size" => 100)
      req["start_cursor"] = cursor if cursor
      res = @t.call(:post, "/v1/data_sources/#{data_source}/query", req)
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
      # Control (DND-1747): a page without the property is a ReadError, so a
      # schema that lost it never reads as "no control misreports".
      control: select(page, "Control"),
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
