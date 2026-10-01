# frozen_string_literal: true

# docker_stacks — the pure (side-effect-free) half of ai/bin/pool-headroom and
# ai/bin/teardown-stack (DND-864). It reads text the host adapter
# (docker_stacks_host.rb) fetched and decides; it never runs a process.
#
# The rule it exists to hold: a probe that could not READ must say so. Empty
# docker output, an empty pool list, zero networks, or an unnormalizable
# project name raise Unreadable/Refused. None of them is returned as "no
# networks, all headroom" (~/dev/custom/CLAUDE.md -> "A failed lookup must
# never look like an empty one").

require "json"
require "ipaddr"

module DockerStacks
  # A probe's answer could not be read. Callers exit 3 ("cannot measure").
  class Unreadable < StandardError; end
  # A command ran past its bound and was killed, or was not run because the
  # same executable already timed out this run (DND-1088). `command` is the
  # argv as a shell-readable string, for the caller's Fix: line. It is an
  # Unreadable: a hung lookup is an unanswered one, never an empty answer.
  class TimedOut < Unreadable
    attr_reader :command, :seconds

    def initialize(message, command:, seconds:)
      @command = command
      @seconds = seconds
      super(message)
    end
  end
  # An input is malformed for its type, or attribution is unsafe. Callers exit 2.
  class Refused < StandardError; end

  # libnetwork's local-scope defaults (ipamutils), used when `docker info`
  # reports no configured DefaultAddressPools: fifteen 172.x/16 pools and
  # 192.168.0.0/16 split into /20s. 15 + 16 = 31 subnets.
  BUILTIN_POOLS = ((17..31).map { |o| { base: "172.#{o}.0.0/16", size: 16 } } +
                   [{ base: "192.168.0.0/16", size: 20 }]).freeze

  COMPOSE_FILES = %w[docker-compose.yml docker-compose.yaml compose.yml compose.yaml].freeze
  # A repo's own teardown script (athena:teardown-worktree-stack, tier 1).
  REPO_SCRIPTS = %w[bin/teardown-worktree-stack.sh .claude/teardown-worktree-stack.sh].freeze
  PROJECT_LABEL = "com.docker.compose.project"
  WORKDIR_LABEL = "com.docker.compose.project.working_dir"
  # The compose-file key a volume / network was created for.
  VOLUME_LABEL = "com.docker.compose.volume"
  NETWORK_LABEL = "com.docker.compose.network"

  module_function

  # raw: the text of `docker info --format '{{json .DefaultAddressPools}}'`.
  # -> [pools, :builtin | :configured]
  def pools_from_info(raw)
    parsed = parse_json(raw, "docker info DefaultAddressPools")
    return [BUILTIN_POOLS, :builtin] if parsed.nil?
    raise Unreadable, "DefaultAddressPools is #{parsed.class}, not a list" unless parsed.is_a?(Array)
    raise Unreadable, "DefaultAddressPools is an empty list" if parsed.empty?

    pools = parsed.map do |p|
      base = p.is_a?(Hash) ? (p["Base"] || p["base"]) : nil
      size = p.is_a?(Hash) ? (p["Size"] || p["size"]) : nil
      raise Unreadable, "pool entry #{p.inspect} lacks Base/Size" unless base.is_a?(String) && size.is_a?(Integer)

      { base: base, size: size }
    end
    pool_capacity(pools) # validates each entry
    [pools, :configured]
  end

  # Subnets the pools can hand out. IPv6 pools are not counted: a compose
  # default network is IPv4, and that is the pool that starves.
  def pool_capacity(pools)
    pools.sum do |p|
      addr = ip(p[:base])
      next 0 unless addr.ipv4?

      prefix = addr.prefix
      raise Unreadable, "pool #{p[:base]} size #{p[:size]} is smaller than its prefix" if p[:size] < prefix || p[:size] > 32

      2**(p[:size] - prefix)
    end
  end

  # raw: the JSON of `docker network inspect <every id>`.
  def networks_from_inspect(raw)
    parsed = parse_json(raw, "docker network inspect")
    raise Unreadable, "docker network inspect returned #{parsed.class}, not a list" unless parsed.is_a?(Array)
    raise Unreadable, "docker listed zero networks; a live daemon always has bridge/host/none" if parsed.empty?

    parsed.map do |n|
      raise Unreadable, "network entry without a Name: #{n.inspect[0, 120]}" unless n.is_a?(Hash) && n["Name"].is_a?(String)

      configs = (n.dig("IPAM", "Config") || [])
      subnets = configs.map { |c| c["Subnet"] }.compact.select { |s| ip(s).ipv4? }
      labels = n["Labels"] || {}
      { id: n["Id"], name: n["Name"], key: labels[NETWORK_LABEL], subnets: subnets, project: labels[PROJECT_LABEL],
        containers: (n["Containers"] || {}).size }
    end
  end

  # raw: the JSON of `docker volume inspect <names>`. -> [{ name:, created_at: }]
  def volumes_from_inspect(raw)
    parsed = parse_json(raw, "docker volume inspect")
    raise Unreadable, "docker volume inspect returned #{parsed.class}, not a list" unless parsed.is_a?(Array)

    parsed.map do |v|
      ok = v.is_a?(Hash) && v["Name"].is_a?(String) && v["CreatedAt"].is_a?(String) && !v["CreatedAt"].empty?
      raise Unreadable, "volume entry without a Name and CreatedAt: #{v.inspect[0, 120]}" unless ok

      { name: v["Name"], created_at: v["CreatedAt"], key: (v["Labels"] || {})[VOLUME_LABEL] }
    end
  end

  # ---- the stack marker (DND-1576) -------------------------------------------
  # A captain's `docker compose down` (no -v) removes the containers and keeps
  # the volumes. Volume labels carry the project but no working dir, so with the
  # containers gone nothing on the docker side ties the volumes to a worktree,
  # and the project name (the worktree basename) is shared by any checkout with
  # that basename. The marker is that tie. It is recorded while the containers
  # still prove attribution (attribute -> :ok) and kept in the worktree's OWN
  # git dir (<common>/worktrees/<id>/), which git gives to exactly one worktree
  # and deletes with it. It pins each volume by name AND creation time and each
  # network by id, so a same-named resource re-created by another checkout
  # after ours was removed does not match.
  MARKER_FILE = "athena-stack-marker.json"
  MARKER_SCHEMA = 1

  # -> the marker document. A prior marker for the same worktree and project is
  # merged in: a later record never forgets what an earlier one proved. A prior
  # for anything else is dropped.
  def build_marker(worktree:, project:, volumes:, networks:, prior:, at:)
    raise Refused, "marker worktree #{worktree.inspect} is not absolute" unless worktree.to_s.start_with?("/")
    raise Refused, "marker project is empty" if project.to_s.empty?

    same = prior && prior[:worktree] == worktree && prior[:project] == project
    vols = volumes.map { |v| { name: v[:name], created_at: v[:created_at] } }
    nets = networks.map { |n| { id: n[:id], name: n[:name] } }
    if same
      # This record's view of a volume wins: a volume re-created since the last
      # record is pinned at its new creation time, never at both.
      vols = prior[:volumes].reject { |v| vols.map { |c| c[:name] }.include?(v[:name]) } + vols
      nets = (prior[:networks] + nets).uniq
    end
    { schema: MARKER_SCHEMA, worktree: worktree, project: project, recorded_at: at, volumes: vols, networks: nets }
  end

  # -> [declared, undeclared]: resources whose compose key (VOLUME_LABEL or
  # NETWORK_LABEL) this worktree's compose config declares, and the rest. Only
  # the declared ones are this worktree's to record: the project label alone is
  # shared by any checkout with the same basename, and `down -v` itself only
  # removes what the compose file declares. A resource with no key is undeclared.
  def split_declared(resources, keys)
    resources.partition { |r| r[:key] && keys.include?(r[:key]) }
  end

  # raw: the marker file's text. A marker that cannot be read is Unreadable,
  # never "no marker": a corrupt file must not read as a missing one.
  def parse_marker(raw, path)
    d = parse_json(raw, "stack marker #{path}")
    raise Unreadable, "stack marker #{path}: not a schema-#{MARKER_SCHEMA} object" unless d.is_a?(Hash) && d["schema"] == MARKER_SCHEMA

    wt = d["worktree"]
    project = d["project"]
    raise Unreadable, "stack marker #{path}: worktree is not an absolute path" unless wt.is_a?(String) && wt.start_with?("/")
    raise Unreadable, "stack marker #{path}: project is empty" unless project.is_a?(String) && !project.empty?

    vols = marker_list(d, "volumes", %w[name created_at], path)
    nets = marker_list(d, "networks", %w[id name], path)
    { worktree: wt, project: project, recorded_at: d["recorded_at"],
      volumes: vols.map { |v| { name: v["name"], created_at: v["created_at"] } },
      networks: nets.map { |n| { id: n["id"], name: n["name"] } } }
  end

  def marker_list(doc, key, fields, path)
    list = doc[key]
    raise Unreadable, "stack marker #{path}: #{key} is not a list" unless list.is_a?(Array)

    list.each do |e|
      good = e.is_a?(Hash) && fields.all? { |f| e[f].is_a?(String) && !e[f].empty? }
      raise Unreadable, "stack marker #{path}: a #{key} entry lacks #{fields.join('/')}: #{e.inspect[0, 120]}" unless good
    end
    list
  end

  # May the container-less resources of <project> be removed for worktree <wt>?
  # marker: parse_marker's hash, or nil when none exists. volumes/networks: what
  # docker lists for the project now. containers: how many the project still has.
  #   { verdict: :ok }
  #   { verdict: :refused, reason:, resources: [{ kind:, name:, why: }] }
  # A refusal names EVERY resource, matched or not: the person removing them by
  # hand needs the whole list. One unmatched resource refuses the whole stack.
  def match_marker(marker, wt, project, volumes, networks, containers)
    whole = ->(reason, why) { refuse_all(reason, volumes, networks, why) }
    return whole.call("#{containers} container(s) of #{project} still exist", "not removed: a container holds the project") if containers.positive?
    return whole.call("no stack marker", "no marker records it") if marker.nil?
    if marker[:worktree] != wt
      return whole.call("the stack marker names worktree #{marker[:worktree]}, not #{wt}", "the marker is another worktree's")
    end
    if marker[:project] != project
      return whole.call("the stack marker names project #{marker[:project]}, not #{project}", "the marker is another project's")
    end

    resources = volumes.map { |v| { kind: "volume", name: v[:name], why: volume_mismatch(marker, v) } } +
                networks.map { |n| { kind: "network", name: n[:name], why: network_mismatch(marker, n) } }
    bad = resources.reject { |r| r[:why].nil? }
    return { verdict: :ok } if bad.empty?

    resources.each { |r| r[:why] ||= "recorded" }
    { verdict: :refused, reason: "#{bad.size} resource(s) do not match the stack marker", resources: resources }
  end

  def refuse_all(reason, volumes, networks, why)
    { verdict: :refused, reason: reason,
      resources: volumes.map { |v| { kind: "volume", name: v[:name], why: why } } +
                 networks.map { |n| { kind: "network", name: n[:name], why: why } } }
  end

  def volume_mismatch(marker, vol)
    rec = marker[:volumes].find { |v| v[:name] == vol[:name] }
    return "not recorded" if rec.nil?
    return nil if rec[:created_at] == vol[:created_at]

    "created #{vol[:created_at]}, the marker recorded #{rec[:created_at]} (re-created since)"
  end

  def network_mismatch(marker, net)
    return nil if marker[:networks].any? { |n| n[:id] == net[:id] }

    "id #{net[:id].to_s[0, 12]} not recorded"
  end

  # -> { capacity:, used:, free:, holders: [networks holding a pool subnet] }
  def headroom(pools, networks)
    slots = ->(n) { n[:subnets].sum { |s| pool_slots(pools, s) } }
    holders = networks.select { |n| slots.call(n).positive? }
    used = holders.sum { |n| slots.call(n) }
    capacity = pool_capacity(pools)
    { capacity: capacity, used: used, free: capacity - used, holders: holders }
  end

  # Pool slots one subnet occupies: 0 outside every pool; 1 at the pool's
  # size or narrower; 2^(size - prefix) when wider (a /16 in a /20 pool is 16).
  def pool_slots(pools, subnet)
    net = ip(subnet)
    pool = pools.find { |p| (r = ip(p[:base])).ipv4? && r.include?(net) }
    return 0 if pool.nil?

    net.prefix >= pool[:size] ? 1 : 2**(pool[:size] - net.prefix)
  end

  def low?(headroom, min_free)
    headroom[:free] < min_free
  end

  # docker compose's default project name for a directory basename: lowercase,
  # only [a-z0-9_-], no leading - or _. A name that normalizes to nothing is an
  # error: an empty project name would match nothing and read as "no stack".
  def normalize_project(name)
    out = name.to_s.downcase.gsub(/[^a-z0-9_-]/, "").sub(/\A[-_]+/, "")
    raise Refused, "directory name #{name.inspect} has no valid compose project name" if out.empty?

    out
  end

  def under?(path, root)
    raise Refused, "root #{root.inspect} is not absolute" unless root.start_with?("/")

    root = root.chomp("/")
    path == root || path.start_with?("#{root}/")
  end

  # `git worktree list --porcelain` -> [{ path:, branch: (nil if detached), main: }]
  def parse_worktrees(porcelain)
    blocks = porcelain.split(/\n\n+/).map(&:strip).reject(&:empty?)
    raise Unreadable, "git worktree list printed nothing" if blocks.empty?

    blocks.each_with_index.map do |b, i|
      lines = b.lines.map(&:chomp)
      path = lines.find { |l| l.start_with?("worktree ") }&.delete_prefix("worktree ")
      raise Unreadable, "git worktree list block without a path: #{b[0, 80].inspect}" if path.nil? || path.empty?

      ref = lines.find { |l| l.start_with?("branch ") }&.delete_prefix("branch ")
      { path: path, branch: ref&.delete_prefix("refs/heads/"), main: i.zero? }
    end
  end

  def compose_file?(basename)
    COMPOSE_FILES.include?(basename)
  end

  # Tier-2 attribution: may `docker compose -p <project> down -v` run for
  # worktree <wt>? containers: [{ project:, working_dir: }] for every compose
  # container on the host.
  #   :foreign   a container under <wt> belongs to a non-default-named project
  #              (the repo isolates stacks its own way: tier 1 or 3, never 2)
  #   :collision a container of <project> lives OUTSIDE <wt> (same basename,
  #              another repo): down -v would destroy someone else's volumes
  #   :none      no container of <project> under <wt>: nothing attributable
  #   :ok        every <project> container lives under <wt>
  def attribute(wt, project, containers)
    mine = containers.select { |c| c[:working_dir] && under?(c[:working_dir], wt) }
    foreign = mine.map { |c| c[:project] }.uniq - [project]
    return { verdict: :foreign, projects: foreign } unless foreign.empty?

    named = containers.select { |c| c[:project] == project }
    outside = named.reject { |c| c[:working_dir] && under?(c[:working_dir], wt) }
    return { verdict: :collision, dirs: outside.map { |c| c[:working_dir] }.uniq } unless outside.empty?
    return { verdict: :none } if named.empty?

    { verdict: :ok }
  end

  # :github / :gitlab from an origin URL; nil when neither.
  def forge_of(url)
    return :github if url.to_s.match?(%r{github\.com[:/]})
    return :gitlab if url.to_s.match?(/gitlab/)

    nil
  end

  def parse_json(raw, what)
    text = raw.to_s.strip
    raise Unreadable, "#{what}: empty output" if text.empty?

    JSON.parse(text)
  rescue JSON::ParserError => e
    raise Unreadable, "#{what}: not JSON (#{e.message.lines.first&.strip})"
  end

  def ip(cidr)
    IPAddr.new(cidr)
  rescue IPAddr::Error => e
    raise Unreadable, "bad subnet #{cidr.inspect}: #{e.message}"
  end
end
