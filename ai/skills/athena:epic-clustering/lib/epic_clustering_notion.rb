# frozen_string_literal: true

# epic_clustering_notion -- the Notion READ adapter behind
# scripts/epic-clustering (DND-982). It only ever reads; every write in a
# clustering pass is the architect's, made per SKILL.md.
#
# It extends next-mission's adapter (ai/lib/next_mission_notion.rb) rather
# than copying it: the same transport, epic resolution (id or exact title,
# verified against DND Epics), paging, relation paging and property checks.
# What it adds: the Security, Epic and Blocks properties, open-epic and
# open-ticket reads, project names, and page bodies.
#
# Every miss is a ReadError, never a smaller answer.
require "set"
require_relative "../../../lib/next_mission_notion"
require_relative "epic_clustering"

class EpicClusteringNotion < NextMissionNotion
  OPEN_EPIC_STATUSES = ["Todo", "In Progress", "Needs Attention"].freeze

  # key: an epic page id or exact title -> [Epic, [Ticket (any status), ...]]
  def epic_with_tickets(key)
    id = resolve_epic(key)
    epic = parse_epic(@t.call(:get, "/v1/pages/#{id}"))
    [epic, query_epic(id).map { |p| parse_ticket(p) }]
  end

  # Epics whose Status is open (Todo, In Progress, Needs Attention).
  def open_epics
    filter = { "or" => OPEN_EPIC_STATUSES.map { |s| { "property" => "Status", "select" => { "equals" => s } } } }
    query_epics("filter" => filter).map { |p| parse_epic(p) }
  end

  # Every epic, any status: an open ticket may sit under a Done epic.
  def all_epics
    query_epics({}).map { |p| parse_epic(p) }
  end

  # Every ticket that is not Done, Cancelled or Won't Fix.
  def open_tickets
    filter = { "and" => EpicClustering::TERMINAL.map { |s| { "property" => "Status", "status" => { "does_not_equal" => s } } } }
    query_all("filter" => filter).map { |p| parse_ticket(p) }
  end

  # ["DND-12", ...] -> {"DND-12" => page id}. A ticket the tracker does not
  # hold is a ReadError naming it, never a smaller map (c3-feedback, DND-1468).
  def page_ids(ids)
    query_ids(ids).to_h { |p| [parse_page(p).id, p.fetch("id")] }
  end

  # The page body as markdown. A truncated or absent body is an error: a short
  # body would read as a thin ticket.
  #
  # Paced: a digest reads hundreds of bodies, and Notion's average limit is
  # about 3 requests a second per integration, shared with every other agent
  # using the token. BODY_GAP keeps this reader under it.
  BODY_GAP = 0.4

  def body(page_id)
    if @last_body
      wait = BODY_GAP - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_body)
      sleep(wait) if wait.positive?
    end
    @last_body = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = @t.call(:get, "/v1/pages/#{page_id}/markdown")
    raise ReadError, "body of #{page_id} came back truncated; read it in parts" if res["truncated"]

    md = res["markdown"]
    raise ReadError, "body of #{page_id} has no markdown field" unless md.is_a?(String)

    md
  end

  private

  def query_epics(body)
    out = []
    cursor = nil
    loop do
      req = body.merge("page_size" => 100)
      req["start_cursor"] = cursor if cursor
      res = @t.call(:post, "/v1/data_sources/#{EPICS_DATA_SOURCE}/query", req)
      out.concat(res.fetch("results"))
      break unless res["has_more"]

      cursor = res["next_cursor"] or raise ReadError, "epic query reported has_more with no next_cursor"
    end
    out
  rescue KeyError => e
    raise ReadError, "malformed epic query response: #{e.message}"
  end

  def parse_epic(page)
    raise ReadError, "epic page #{page['id']} is in the trash" if page["in_trash"]

    name = prop!(page, "Name", "title")["title"].map { |t| t["plain_text"] }.join
    status = prop!(page, "Status", "select")["select"]&.fetch("name")
    projects = relation_ids(page, "Project").map { |pid| project_name(pid) }
    EpicClustering::Epic.new(page_id: page.fetch("id"), name: name, status: status,
                             project: projects.empty? ? nil : projects.sort.join(" + "))
  rescue KeyError, NoMethodError, TypeError => e
    raise ReadError, "epic page #{page.is_a?(Hash) ? page['id'] : page.inspect} is malformed: #{e.class}: #{e.message}"
  end

  def project_name(pid)
    @projects ||= {}
    @projects[pid] ||= begin
      page = @t.call(:get, "/v1/pages/#{pid}")
      title = page.fetch("properties").values.find { |v| v["type"] == "title" }
      raise ReadError, "project page #{pid} has no title property" if title.nil?

      title["title"].map { |t| t["plain_text"] }.join
    end
  end

  def parse_ticket(page)
    base = parse_page(page)
    security = select(page, "Security")
    EpicClustering::Ticket.new(
      id: base.id, page_id: base.page_id, title: base.title, status: base.status, kind: base.kind,
      severity: base.severity, security: security, path: base.path, area: base.area,
      epic_ids: relation_ids(page, "Epic"), depends_on: relation_ids(page, "Depends On"),
      blocks: relation_ids(page, "Blocks"), created: base.created, body: nil, control: base.control
    )
  end
end
