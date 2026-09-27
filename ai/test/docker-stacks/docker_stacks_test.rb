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
    {"Name":"gen_saas-dnd-1","IPAM":{"Config":[{"Subnet":"192.168.16.0/20"},{"Subnet":"fd00::/64"}]},
     "Labels":{"com.docker.compose.project":"dnd-1"},"Containers":{"a":{},"b":{}}},
    {"Name":"custom","IPAM":{"Config":[{"Subnet":"10.99.0.0/24"}]},"Labels":{},"Containers":null}
  ]
JSON
nets = DS.networks_from_inspect(inspect_json)
check("inspect parses every network") { nets.map { |n| n[:name] } == %w[bridge host gen_saas-dnd-1 custom] }
check("inspect keeps only IPv4 subnets") { nets[2][:subnets] == ["192.168.16.0/20"] }
check("inspect reads the compose project label") { nets[2][:project] == "dnd-1" && nets[0][:project].nil? }
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
