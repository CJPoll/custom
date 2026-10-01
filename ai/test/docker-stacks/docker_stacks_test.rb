# frozen_string_literal: true

# Deterministic suite for ai/lib/docker_stacks.rb (DND-864): the pure half of
# pool-headroom and teardown-stack. No docker, no git, no network. Run by
# ai/test/docker-stacks/self-test.sh, which harness-gate discovers. Plain
# stdlib assertions (the harness bins are gem-free).

require_relative "../../lib/docker_stacks"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises?(klass)
  yield
  false
rescue klass
  true
end

DS = DockerStacks

# ---- pools_from_info --------------------------------------------------------
pools, source = DS.pools_from_info("null\n")
check("null pools -> docker built-in defaults") { source == :builtin && pools == DS::BUILTIN_POOLS }
check("built-in defaults hold 31 subnets") { DS.pool_capacity(DS::BUILTIN_POOLS) == 31 }

pools, source = DS.pools_from_info('[{"Base":"10.10.0.0/16","Size":24}]')
check("configured pools are read") { source == :configured && pools == [{ base: "10.10.0.0/16", size: 24 }] }
check("configured /16 split into /24 holds 256") { DS.pool_capacity(pools) == 256 }

check("empty output is unreadable, not zero pools") { raises?(DS::Unreadable) { DS.pools_from_info("") } }
check("non-JSON is unreadable") { raises?(DS::Unreadable) { DS.pools_from_info("Cannot connect") } }
check("an empty pool list is unreadable") { raises?(DS::Unreadable) { DS.pools_from_info("[]") } }
check("a pool missing Size is unreadable") { raises?(DS::Unreadable) { DS.pools_from_info('[{"Base":"10.0.0.0/8"}]') } }
check("a pool with Size < prefix is unreadable") { raises?(DS::Unreadable) { DS.pools_from_info('[{"Base":"10.0.0.0/16","Size":8}]') } }

# ---- networks_from_inspect --------------------------------------------------
inspect_json = <<~JSON
  [
    {"Name":"bridge","IPAM":{"Config":[{"Subnet":"172.17.0.0/16"}]},"Labels":{},"Containers":{}},
    {"Name":"host","IPAM":{"Config":[]},"Labels":null,"Containers":{}},
    {"Name":"gen_saas-dnd-1","Id":"n1id","IPAM":{"Config":[{"Subnet":"192.168.16.0/20"},{"Subnet":"fd00::/64"}]},
     "Labels":{"com.docker.compose.project":"dnd-1"},"Containers":{"a":{},"b":{}}},
    {"Name":"custom","IPAM":{"Config":[{"Subnet":"10.99.0.0/24"}]},"Labels":{},"Containers":null}
  ]
JSON
nets = DS.networks_from_inspect(inspect_json)
check("inspect parses every network") { nets.map { |n| n[:name] } == %w[bridge host gen_saas-dnd-1 custom] }
check("inspect keeps only IPv4 subnets") { nets[2][:subnets] == ["192.168.16.0/20"] }
check("inspect reads the compose project label") { nets[2][:project] == "dnd-1" && nets[0][:project].nil? }
check("inspect reads the network id (a marker pins a network by it)") { nets[2][:id] == "n1id" && nets[0][:id].nil? }
check("inspect counts attached containers") { nets[2][:containers] == 2 && nets[3][:containers].zero? }
check("inspect of nothing is unreadable (a daemon always has networks)") do
  raises?(DS::Unreadable) { DS.networks_from_inspect("[]") }
end
check("inspect garbage is unreadable") { raises?(DS::Unreadable) { DS.networks_from_inspect("nope") } }
check("inspect entry without Name is unreadable") { raises?(DS::Unreadable) { DS.networks_from_inspect('[{"IPAM":{}}]') } }

# ---- headroom ---------------------------------------------------------------
h = DS.headroom(DS::BUILTIN_POOLS, nets)
check("headroom counts only pool subnets (bridge + dnd-1, not 10.99)") { h[:used] == 2 }
check("headroom free = capacity - used") { h[:capacity] == 31 && h[:free] == 29 }
check("headroom holders are the pool networks") { h[:holders].map { |n| n[:name] } == %w[bridge gen_saas-dnd-1] }

full = (17..31).map { |o| { name: "n#{o}", subnets: ["172.#{o}.0.0/16"], project: nil, containers: 1 } } +
       (0..15).map { |i| { name: "m#{i}", subnets: ["192.168.#{i * 16}.0/20"], project: nil, containers: 0 } }
h = DS.headroom(DS::BUILTIN_POOLS, full)
check("a full built-in pool has zero free") { h[:free].zero? && h[:used] == 31 }

wide = [{ name: "wide", subnets: ["192.168.0.0/16"], project: nil, containers: 0 }]
check("a /16 inside the /20 pool holds 16 slots, not 1") { DS.headroom(DS::BUILTIN_POOLS, wide)[:used] == 16 }
check("pool_slots outside every pool is 0") { DS.pool_slots(DS::BUILTIN_POOLS, "10.1.0.0/24").zero? }

check("low? below the bar") { DS.low?({ free: 1 }, 2) }
check("not low? at the bar") { !DS.low?({ free: 2 }, 2) }

# ---- normalize_project ------------------------------------------------------
check("compose default project name: lowercased") { DS.normalize_project("DND-448-Metering") == "dnd-448-metering" }
check("compose default project name: drops disallowed chars") { DS.normalize_project("a.b c:d") == "abcd" }
check("compose default project name: strips leading - and _") { DS.normalize_project("_-x") == "x" }
check("an unnormalizable name is an error, not empty") { raises?(DS::Refused) { DS.normalize_project("...") } }

# ---- under? -----------------------------------------------------------------
check("a dir is under itself") { DS.under?("/w/a", "/w/a") }
check("a subdir is under") { DS.under?("/w/a/backend", "/w/a") }
check("a sibling with a shared prefix is NOT under") { !DS.under?("/w/ab", "/w/a") }
check("a relative root is refused") { raises?(DS::Refused) { DS.under?("/w/a", "w/a") } }

# ---- parse_worktrees --------------------------------------------------------
porcelain = <<~TXT
  worktree /repo
  HEAD 1111111111111111111111111111111111111111
  branch refs/heads/main

  worktree /wt/feat
  HEAD 2222222222222222222222222222222222222222
  branch refs/heads/feat

  worktree /wt/detached
  HEAD 3333333333333333333333333333333333333333
  detached

TXT
wts = DS.parse_worktrees(porcelain)
check("worktree list: three entries") { wts.size == 3 }
check("worktree list: first is the main checkout") { wts[0][:main] && !wts[1][:main] }
check("worktree list: branch names") { wts.map { |w| w[:branch] } == ["main", "feat", nil] }
check("worktree list: empty output is unreadable") { raises?(DS::Unreadable) { DS.parse_worktrees("") } }

# ---- compose files ----------------------------------------------------------
check("compose file names recognised") do
  %w[docker-compose.yml docker-compose.yaml compose.yml compose.yaml].all? { |f| DS.compose_file?(f) }
end
check("override and other yml are not stack roots") do
  !DS.compose_file?("docker-compose.override.yml") && !DS.compose_file?("config.yml")
end

# ---- attribute (tier-2 attribution) -----------------------------------------
wt = "/w/gen_saas/dnd-1-x"
cont = [
  { project: "dnd-1-x", working_dir: wt },
  { project: "dnd-2-y", working_dir: "/w/gen_saas/dnd-2-y" },
]
a = DS.attribute(wt, "dnd-1-x", cont)
check("attribute: own project attributed") { a[:verdict] == :ok }
a = DS.attribute(wt, "dnd-1-x", [{ project: "dnd-2-y", working_dir: "/w/gen_saas/dnd-2-y" }])
check("attribute: no container of ours -> nothing attributable") { a[:verdict] == :none }
a = DS.attribute(wt, "dnd-1-x", cont + [{ project: "dnd-1-x", working_dir: "/w/other/dnd-1-x" }])
check("attribute: same project name from another dir -> collision") { a[:verdict] == :collision }
a = DS.attribute(wt, "dnd-1-x", cont + [{ project: "walt-ui-dnd-1-x", working_dir: "#{wt}/backend" }])
check("attribute: a non-default project under the worktree -> foreign") do
  a[:verdict] == :foreign && a[:projects] == ["walt-ui-dnd-1-x"]
end

# ---- stack marker (DND-1576) --------------------------------------------------
# A container-less stack is attributed only by the marker recorded while its
# containers proved it: same worktree, same project, and every resource matched
# exactly (a volume by name AND creation time, a network by id).
vols = [{ name: "dnd-1-x_build", created_at: "2026-10-01T10:00:00Z" },
        { name: "dnd-1-x_pg", created_at: "2026-10-01T10:00:01Z" }]
nets = [{ id: "a" * 64, name: "dnd-1-x_default" }]
doc = DS.build_marker(worktree: wt, project: "dnd-1-x", volumes: vols, networks: nets, prior: nil, at: "2026-10-01T11:00:00Z")
round = DS.parse_marker(JSON.dump(doc), "/g/marker.json")
check("marker: round-trips through JSON") do
  round[:worktree] == wt && round[:project] == "dnd-1-x" && round[:volumes] == vols && round[:networks] == nets
end
check("marker: a relative worktree is refused where it is built") do
  raises?(DS::Refused) { DS.build_marker(worktree: "rel/wt", project: "p", volumes: [], networks: [], prior: nil, at: "t") }
end
later = DS.build_marker(worktree: wt, project: "dnd-1-x", volumes: [{ name: "dnd-1-x_deps", created_at: "2026-10-01T12:00:00Z" }],
                       networks: [], prior: round, at: "2026-10-01T12:00:00Z")
check("marker: a later record keeps what an earlier one proved") do
  later[:volumes].map { |v| v[:name] }.sort == %w[dnd-1-x_build dnd-1-x_deps dnd-1-x_pg] && later[:networks] == nets
end
foreign_prior = round.merge(worktree: "/w/other/dnd-1-x")
fresh = DS.build_marker(worktree: wt, project: "dnd-1-x", volumes: [], networks: [], prior: foreign_prior, at: "t")
check("marker: a prior record for another worktree is dropped, never merged") { fresh[:volumes].empty? && fresh[:networks].empty? }

check("marker: empty text is unreadable") { raises?(DS::Unreadable) { DS.parse_marker("", "/g/m.json") } }
check("marker: wrong schema is unreadable") { raises?(DS::Unreadable) { DS.parse_marker('{"schema":9}', "/g/m.json") } }
check("marker: a volume without created_at is unreadable") do
  raises?(DS::Unreadable) do
    DS.parse_marker(JSON.dump(doc.merge(volumes: [{ name: "v" }])), "/g/m.json")
  end
end

m = DS.match_marker(round, wt, "dnd-1-x", vols, nets, 0)
check("match: every resource recorded for this worktree -> ok") { m[:verdict] == :ok }
m = DS.match_marker(nil, wt, "dnd-1-x", vols, [], 0)
check("match: no marker -> refused, every resource named") do
  m[:verdict] == :refused && m[:reason].include?("no stack marker") &&
    m[:resources].map { |r| r[:name] } == %w[dnd-1-x_build dnd-1-x_pg]
end
m = DS.match_marker(round.merge(worktree: "/w/other/dnd-1-x"), wt, "dnd-1-x", vols, nets, 0)
check("match: marker for another worktree -> refused, names it") do
  m[:verdict] == :refused && m[:reason].include?("/w/other/dnd-1-x") && m[:resources].size == 3
end
m = DS.match_marker(round.merge(project: "dnd-9-z"), wt, "dnd-1-x", vols, nets, 0)
check("match: marker for another project -> refused") { m[:verdict] == :refused && m[:reason].include?("dnd-9-z") }
recreated = [vols[0], { name: "dnd-1-x_pg", created_at: "2026-10-02T00:00:00Z" }]
m = DS.match_marker(round, wt, "dnd-1-x", recreated, nets, 0)
check("match: a volume re-created since the record -> refused, that one says why") do
  m[:verdict] == :refused && m[:resources].find { |r| r[:name] == "dnd-1-x_pg" }[:why].include?("2026-10-02T00:00:00Z")
end
m = DS.match_marker(round, wt, "dnd-1-x", vols + [{ name: "dnd-1-x_new", created_at: "t" }], nets, 0)
check("match: one unrecorded volume -> the whole stack is refused") do
  m[:verdict] == :refused && m[:resources].map { |r| r[:name] }.include?("dnd-1-x_new") && m[:resources].size == 4
end
m = DS.match_marker(round, wt, "dnd-1-x", vols, [{ id: "b" * 64, name: "dnd-1-x_default" }], 0)
check("match: a network re-created under the same name -> refused") { m[:verdict] == :refused }
m = DS.match_marker(round, wt, "dnd-1-x", vols, nets, 1)
check("match: a container of the project still exists -> refused") { m[:verdict] == :refused }

ins = DS.volumes_from_inspect('[{"Name":"v1","CreatedAt":"2026-10-01T10:00:00-06:00","Labels":{}}]')
check("volume inspect: name and creation time") { ins == [{ name: "v1", created_at: "2026-10-01T10:00:00-06:00", key: nil }] }
ins = DS.volumes_from_inspect('[{"Name":"p_pg","CreatedAt":"t","Labels":{"com.docker.compose.volume":"pg"}}]')
check("volume inspect: the compose key") { ins.first[:key] == "pg" }

re1 = DS.build_marker(worktree: wt, project: "dnd-1-x", volumes: [{ name: "dnd-1-x_pg", created_at: "T1" }], networks: [], prior: nil, at: "t")
re2 = DS.build_marker(worktree: wt, project: "dnd-1-x", volumes: [{ name: "dnd-1-x_pg", created_at: "T2" }], networks: [], prior: re1, at: "t")
check("marker: a volume re-created and re-recorded is pinned once, at its new time") do
  re2[:volumes] == [{ name: "dnd-1-x_pg", created_at: "T2" }] &&
    DS.match_marker(re2, wt, "dnd-1-x", [{ name: "dnd-1-x_pg", created_at: "T2" }], [], 0)[:verdict] == :ok
end
check("marker: the compose key is not stored") do
  DS.build_marker(worktree: wt, project: "p", volumes: [{ name: "v", created_at: "t", key: "k" }], networks: [], prior: nil, at: "t")[:volumes] ==
    [{ name: "v", created_at: "t" }]
end

mine, theirs = DS.split_declared([{ name: "p_pg", key: "pg" }, { name: "p_other", key: "other" }, { name: "x", key: nil }], %w[pg])
check("split_declared: only keys this compose config declares are this worktree's") do
  mine.map { |r| r[:name] } == ["p_pg"] && theirs.map { |r| r[:name] } == %w[p_other x]
end
check("volume inspect: an entry without CreatedAt is unreadable") do
  raises?(DS::Unreadable) { DS.volumes_from_inspect('[{"Name":"v1"}]') }
end
check("volume inspect: empty output is unreadable") { raises?(DS::Unreadable) { DS.volumes_from_inspect("") } }

# ---- forge_of ---------------------------------------------------------------
check("forge_of github ssh") { DS.forge_of("git@github.com:CJPoll/custom.git") == :github }
check("forge_of gitlab https") { DS.forge_of("https://gitlab.com/a/b.git") == :gitlab }
check("forge_of unknown is nil") { DS.forge_of("/srv/git/x.git").nil? }

puts "docker_stacks: #{$checks - $failures.size}/#{$checks} checks passed"
unless $failures.empty?
  $failures.each { |f| puts "  FAIL #{f}" }
  puts "Fix: repair ai/lib/docker_stacks.rb so each failing case above holds; a probe that cannot read must raise Unreadable, never return empty."
  exit 1
end
