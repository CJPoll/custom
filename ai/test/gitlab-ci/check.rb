# frozen_string_literal: true

# check.rb -- the rule checker behind ai/test/gitlab-ci/self-test.sh (DND-1946).
# Usage: ruby check.rb <.gitlab-ci.yml> [DOCKERFILE SETUP]. Prints each violated
# rule; exit 1 if any. DOCKERFILE and SETUP default to dockerfiles/ci-harness/
# beside the file (DND-1998, DND-2085).

require "yaml"
require "shellwords"

path = ARGV.fetch(0) { abort "usage: check.rb FILE [DOCKERFILE SETUP]\n  Fix: pass the .gitlab-ci.yml path." }
unless File.file?(path)
  warn "gitlab-ci check: #{path} is missing\n  Fix: restore .gitlab-ci.yml at the repo root."
  exit 1
end
# The CI image's definition, beside the file by default.
image_dir = File.join(File.dirname(path), "dockerfiles", "ci-harness")
dockerfile = ARGV[1] || File.join(image_dir, "Dockerfile")
setup = ARGV[2] || File.join(image_dir, "setup.sh")

doc = YAML.safe_load_file(path, aliases: true)
errors = []
unless doc.is_a?(Hash)
  warn "gitlab-ci check: #{path} is not a YAML mapping\n  Fix: write a valid .gitlab-ci.yml."
  exit 1
end

RESERVED = %w[workflow default stages variables include image services before_script after_script cache].freeze
jobs = doc.reject { |k, v| RESERVED.include?(k) || k.start_with?(".") || !v.is_a?(Hash) }

# Fork guard: first workflow rule, `when: never`, comparing source and project path.
rules = doc.dig("workflow", "rules")
first = rules.is_a?(Array) ? rules.first : nil
guard = first.is_a?(Hash) ? first["if"].to_s : ""
unless first.is_a?(Hash) && guard.include?("CI_MERGE_REQUEST_SOURCE_PROJECT_PATH") && guard.include?("!= $CI_PROJECT_PATH") && first["when"] == "never"
  errors << "fork guard: workflow:rules must open with an `if` comparing $CI_MERGE_REQUEST_SOURCE_PROJECT_PATH to $CI_PROJECT_PATH, `when: never`"
end
ifs = Array(rules).map { |r| r.is_a?(Hash) ? r["if"].to_s : "" }
# Order matters: fork guard, MR rule, open-MR never-rule, branch rule.
mr_i = ifs.index { |i| i.include?("merge_request_event") }
dup_i = ifs.index { |i| i.include?("CI_OPEN_MERGE_REQUESTS") }
br_i = ifs.index { |i| i.strip == "$CI_COMMIT_BRANCH" }
errors << "workflow: no merge_request_event rule" if mr_i.nil?
errors << "workflow: no rule using $CI_OPEN_MERGE_REQUESTS (CI_OPEN_MERGE_REQUESTS; duplicate branch+MR pipelines)" if dup_i.nil?
errors << "workflow: no branch pipeline rule ($CI_COMMIT_BRANCH)" if br_i.nil?
if mr_i && dup_i && br_i
  errors << "workflow: rules must run in order: fork guard, MR rule, CI_OPEN_MERGE_REQUESTS never-rule, branch rule" unless mr_i < dup_i && dup_i < br_i
  errors << "workflow: the CI_OPEN_MERGE_REQUESTS rule must be `when: never`" unless rules[dup_i]["when"] == "never"
  errors << "workflow: the MR rule and the branch rule must not be `when: never`" if rules[mr_i]["when"] == "never" || rules[br_i]["when"] == "never"
end

# Goal 4 (DND-2067): no pipeline on the default branch. The never-rule must
# exist, be `when: never`, and come before the branch rule that would run it.
def_i = ifs.index { |i| i.include?("$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH") }
if def_i.nil?
  errors << "default branch: workflow:rules needs `$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH`, `when: never` (no pipeline on main)"
else
  errors << "default branch: the $CI_DEFAULT_BRANCH rule must be `when: never`" unless rules[def_i]["when"] == "never"
  errors << "default branch: the $CI_DEFAULT_BRANCH never-rule must come before the branch rule" if br_i && def_i > br_i
end

# No credentials or remote code anywhere, hidden jobs and default included.
walk = lambda do |node, where|
  case node
  when Hash
    node.each do |k, v|
      errors << "#{where}#{k}: id_tokens, secrets, include and trigger are not allowed anywhere (no credentials, no remote YAML)" if %w[id_tokens secrets include trigger].include?(k.to_s)
      walk.call(v, "#{where}#{k}.")
    end
  when Array then node.each { |v| walk.call(v, where) }
  end
end
walk.call(doc, "")

errors << "no jobs found" if jobs.empty?
jobs.each do |name, job|
  tags = job["tags"]
  errors << "#{name}: tags must be exactly [ci] (the role tag; no untagged job, no per-host tag), got #{tags.inspect}" unless tags == ["ci"]
  errors << "#{name}: interruptible must be true" unless job["interruptible"] == true
end

# Variables, anywhere, may not name a credential.
all_vars = [doc["variables"]] + jobs.values.map { |j| j["variables"] }
all_vars.compact.each do |vars|
  vars.each_key do |k|
    errors << "variable #{k}: credential-looking names are not allowed (no secrets in this file)" if k.to_s =~ /TOKEN|SECRET|PASSWORD|KEY|CREDENTIAL/i
  end
end

# Every string in the parsed file, keys included (comments are not values).
yaml_strings = lambda do |node|
  case node
  when Hash then node.flat_map { |k, v| [k.to_s] + yaml_strings.call(v) }
  when Array then node.flat_map { |v| yaml_strings.call(v) }
  else [node.to_s]
  end
end
all_strings = yaml_strings.call(doc)

# No ~/dev/custom link anywhere in the file (job, default or hidden
# before_script): a checkout there marks the machine as an inbox tenant.
errors << "the CI file must not link a checkout at ~/dev/custom (dev/custom); the CI container is not an inbox tenant" if all_strings.any? { |v| v.include?("dev/custom") }

# The sibling containers (DND-2085). A `docker run` anywhere in the file is a
# container on the `ci` user's rootless daemon; none may widen past what the
# decision grants (ai/docs/ci-harness-masked-proc.md -> The boundary).
SECURITY_OPTS = %w[seccomp=unconfined apparmor=unconfined systempaths=unconfined].freeze
GATE_NAME = "custom-gate-$CI_JOB_ID"
PROBE_NAME = "custom-probe-$CI_JOB_ID"
PROBE_CMD = "dockerfiles/ci-harness/boundary-probe.sh"
IMAGE_VAR = "$CI_HARNESS_IMAGE"
IMAGE_DIR = "dockerfiles/ci-harness"

# Each shell command line in a string, split on newlines, `&&`, `||` and `;`
# outside quotes, as word arrays. A line that does not tokenize is reported.
commands_in = lambda do |text, where|
  text.to_s.split("\n").flat_map do |line|
    begin
      words = Shellwords.split(line)
    rescue ArgumentError => e
      errors << "#{where}: a script line does not parse as shell words (#{e.message}): #{line.strip[0, 80]}"
      next []
    end
    words.slice_when { |a, _b| %w[&& || ; |].include?(a) }.map { |c| c.reject { |w| %w[&& || ; |].include?(w) } }.reject(&:empty?)
  end
end

docker_runs = all_strings.flat_map { |s| commands_in.call(s, "docker run") }.select { |w| w[0] == "docker" && w[1] == "run" }

# flag_values WORDS NAME: every value given to a long flag, as `--x v` or `--x=v`.
flag_values = lambda do |words, name|
  vals = []
  words.each_with_index do |w, i|
    if w == name then vals << words[i + 1].to_s
    elsif w.start_with?("#{name}=") then vals << w.split("=", 2)[1]
    end
  end
  vals
end

FORBIDDEN = {
  "--privileged" => ->(w) { w.any? { |x| x == "--privileged" || x.start_with?("--privileged=") } },
  "--pid=host" => ->(w) { flag_values.call(w, "--pid").include?("host") },
  "--network=host" => ->(w) { (flag_values.call(w, "--network") + flag_values.call(w, "--net")).include?("host") },
  "--ipc=host" => ->(w) { flag_values.call(w, "--ipc").include?("host") },
  "--uts=host" => ->(w) { flag_values.call(w, "--uts").include?("host") },
  "--userns=host" => ->(w) { flag_values.call(w, "--userns").include?("host") },
  "--cap-add" => ->(w) { w.any? { |x| x == "--cap-add" || x.start_with?("--cap-add=") } },
  "--device" => ->(w) { w.any? { |x| x == "--device" || x.start_with?("--device=") } },
  "--volumes-from" => ->(w) { w.any? { |x| x == "--volumes-from" || x.start_with?("--volumes-from=") } },
  "a docker.sock bind" => ->(w) { w.any? { |x| x.include?("docker.sock") } },
}.freeze

errors << "docker run: the harness-gate job must start the gate in a sibling container (`docker run`); none found" if docker_runs.empty?
docker_runs.each do |w|
  label = w.include?(GATE_NAME) ? "gate" : (w.include?(PROBE_NAME) ? "probe" : "a")
  FORBIDDEN.each do |flag, hit|
    errors << "docker run (#{label} container): #{flag} is not allowed in any sibling container (it reaches past the ci user's namespace; ai/docs/ci-harness-masked-proc.md -> The boundary)" if hit.call(w)
  end
  extra = flag_values.call(w, "--security-opt") - SECURITY_OPTS
  errors << "docker run (#{label} container): --security-opt #{extra.inspect} is not one of #{SECURITY_OPTS.inspect}" unless extra.empty?
end

# check_unmasked WORDS LABEL: the gate's three --security-opt values, each once.
check_unmasked = lambda do |w, label|
  opts = flag_values.call(w, "--security-opt")
  errors << "#{label}: must carry exactly the three --security-opt values #{SECURITY_OPTS.inspect}, each once, got #{opts.inspect}" unless opts.sort == SECURITY_OPTS.sort
  errors << "#{label}: must bind the checkout at its own path (-v \"$CI_PROJECT_DIR:$CI_PROJECT_DIR\") and work there (-w \"$CI_PROJECT_DIR\")" unless flag_values.call(w, "-v") == ["$CI_PROJECT_DIR:$CI_PROJECT_DIR"] && flag_values.call(w, "-w") == ["$CI_PROJECT_DIR"]
  errors << "#{label}: must run the built image #{IMAGE_VAR}" unless w.include?(IMAGE_VAR)
  errors << "#{label}: must be removed on exit (--rm)" unless w.include?("--rm")
end

gate = jobs["harness-gate"]
if gate.nil?
  errors << "harness-gate: job is missing"
else
  scripts = Array(gate["script"]).flatten.map(&:to_s)
  cmds = scripts.each_with_index.flat_map { |s, i| commands_in.call(s, "harness-gate script").map { |c| [i, c] } }
  errors << "harness-gate: variables must set GIT_DEPTH \"0\" (landed bars read origin/main)" unless gate.dig("variables", "GIT_DEPTH").to_s == "0"
  img = gate["image"].to_s
  errors << "harness-gate: image must be an exact tag pinned by @sha256 digest, got #{img.inspect}" unless img =~ /\A[^:@\s]+:\d+\.\d+\.\d+[^@\s]*@sha256:[0-9a-f]{64}\z/

  # first_i PRED: the script index of the first command matching PRED.
  first_i = ->(pred) { cmds.find { |_i, c| pred.call(c) }&.first }

  rootless_i = scripts.index { |s| s.include?("docker info") && s.include?("name=rootless") && s.include?("exit 1") && s.include?("Fix:") }
  build_i = first_i.call(->(c) { c[0] == "docker" && c[1] == "build" && flag_values.call(c, "-t") == [IMAGE_VAR] && c.last == IMAGE_DIR })
  tag_i = scripts.index { |s| s.match?(/\ACI_HARNESS_IMAGE="custom-ci-harness:\$\(/) && s.include?("find #{IMAGE_DIR} -type f") && s.include?("sha256sum") }
  probe_i = first_i.call(->(c) { c[0] == "docker" && c[1] == "run" && c.include?(PROBE_NAME) })
  fetch_i = first_i.call(->(c) { c[0] == "git" && c[1] == "fetch" && c.any? { |x| x.include?("refs/remotes/origin/main") } })
  chown_i = first_i.call(->(c) { c[0] == "docker" && c[1] == "run" && c.each_cons(3).any? { |a, b, d| a == "chown" && b == "-R" && d == "ci:ci" } })
  gate_lines = cmds.select { |_i, c| c[0] == "docker" && c[1] == "run" && c.any? { |x| x.include?("ai/bin/harness-gate") } }
  gate_i = gate_lines.first&.first

  errors << "harness-gate: script must check the socket reaches a rootless daemon (`docker info` ... name=rootless ... exit 1, with a Fix:)" if rootless_i.nil?
  errors << "harness-gate: script must set CI_HARNESS_IMAGE to custom-ci-harness:<content hash of #{IMAGE_DIR}> (find #{IMAGE_DIR} -type f ... sha256sum)" if tag_i.nil?
  errors << "harness-gate: script must build the image (`docker build -t \"#{IMAGE_VAR}\" #{IMAGE_DIR}`)" if build_i.nil?
  errors << "harness-gate: script must fetch origin/main explicitly (git fetch ... refs/remotes/origin/main)" if fetch_i.nil?
  errors << "harness-gate: script must hand the tree to ci (`docker run ... chown -R ci:ci ...`): git refuses a tree another user owns" if chown_i.nil?

  if gate_lines.size != 1
    errors << "harness-gate: script must run `ai/bin/harness-gate` as the command of exactly one `docker run` (the sibling gate container), got #{gate_lines.size}"
  else
    w = gate_lines.first.last
    check_unmasked.call(w, "harness-gate container")
    errors << "harness-gate container: its command must be exactly ai/bin/harness-gate, right after the image" unless w.last == "ai/bin/harness-gate" && w[-2] == IMAGE_VAR
    errors << "harness-gate container: must be named #{GATE_NAME} (after_script removes it by name)" unless flag_values.call(w, "--name") == [GATE_NAME]
    errors << "harness-gate container: must run as the image's non-root user (--user ci)" unless flag_values.call(w, "--user") == ["ci"] && flag_values.call(w, "-u").empty?
  end

  probe_w = cmds.find { |_i, c| c[0] == "docker" && c[1] == "run" && c.include?(PROBE_NAME) }&.last
  if probe_w.nil?
    errors << "boundary probe: script must run #{PROBE_CMD} in its own container named #{PROBE_NAME}"
  else
    check_unmasked.call(probe_w, "boundary probe container")
    errors << "boundary probe container: must run as the image's root (--user 0), where a denial means the daemon is rootless" unless flag_values.call(probe_w, "--user") == ["0"] && flag_values.call(probe_w, "-u").empty?
    errors << "boundary probe container: its command must be exactly #{PROBE_CMD}, with no arguments" unless probe_w.last == PROBE_CMD && probe_w[-2] == IMAGE_VAR
  end

  if gate_i
    { "the rootless check" => rootless_i, "the image tag" => tag_i, "the image build" => build_i, "the boundary probe" => probe_i,
      "the origin/main fetch" => fetch_i, "the chown to ci" => chown_i }.each do |what, i|
      errors << "harness-gate: #{what} must come before the gate container" if i && i > gate_i
    end
  end
  errors << "harness-gate: the image tag must be set before the build" if tag_i && build_i && tag_i > build_i
  errors << "harness-gate: the image must be built before the boundary probe" if build_i && probe_i && build_i > probe_i

  after = Array(gate["after_script"]).flatten.map(&:to_s)
  rm = after.flat_map { |s| commands_in.call(s, "harness-gate after_script") }.find { |c| c[0] == "docker" && c[1] == "rm" && c.include?("-f") }
  errors << "harness-gate: after_script must remove the sibling containers by name (`docker rm -f \"#{GATE_NAME}\" \"#{PROBE_NAME}\" ...`), so a cancelled job leaves none" unless rm && rm.include?(GATE_NAME) && rm.include?(PROBE_NAME)

  # The image the gate runs: one FROM, pinned; it runs setup.sh.
  if File.file?(dockerfile)
    dtext = File.read(dockerfile)
    froms = dtext.scan(/^FROM\s+(\S+)/i).flatten
    errors << "Dockerfile: must have exactly one FROM (a later stage would be the image), got #{froms.size}" unless froms.size == 1
    from = froms.first.to_s
    errors << "Dockerfile: FROM must be an exact tag pinned by @sha256 digest, got #{from.inspect}" unless from =~ /\A[^:@\s]+:\d+\.\d+\.\d+[^@\s]*@sha256:[0-9a-f]{64}\z/
    errors << "Dockerfile: must COPY setup.sh and RUN it" unless dtext.match?(/^COPY\s+setup\.sh\s+(\S+)\s*$/) && dtext.match?(/^RUN\s+#{Regexp.escape(dtext[/^COPY\s+setup\.sh\s+(\S+)/, 1].to_s)}\s*$/)
  else
    errors << "Dockerfile: #{dockerfile} is missing"
  end
end

# setup.sh pins every input: one snapshot, exact package versions, a checked git.
if File.file?(setup)
  stext = File.read(setup)
  # Each pin is assigned exactly once: a later reassignment would win.
  %w[SNAPSHOT GIT_VERSION GIT_SHA256 PACKAGES].each do |var|
    n = stext.scan(/^\s*#{var}=/).size
    errors << "setup.sh: #{var} must be assigned exactly once, got #{n}" unless n == 1
  end
  # apt reads only the snapshot: the base image's sources are removed, and no
  # other source is written.
  errors << "setup.sh: must remove the base image's apt sources (`rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*`) so apt reads only snapshot.debian.org" unless stext.match?(%r{^rm -f /etc/apt/sources\.list /etc/apt/sources\.list\.d/\*$})
  errors << "setup.sh: apt must read only snapshot.debian.org; a one-line `deb ` source is not allowed" if stext.match?(/\bdeb(-src)?[ \t]+[^\n]*https?:/)
  srcs = stext.scan(%r{/etc/apt/sources\.list(?:\.d/[^\s"']*)?}).uniq
  extra = srcs - ["/etc/apt/sources.list", "/etc/apt/sources.list.d/*", "/etc/apt/sources.list.d/snapshot.sources"]
  errors << "setup.sh: apt must read only snapshot.debian.org; it writes other sources #{extra.inspect}" unless extra.empty?
  errors << "setup.sh: the install must name exactly \"${PACKAGES[@]}\" (no extra, unpinned package)" unless stext.match?(/install -y -qq --no-install-recommends "\$\{PACKAGES\[@\]\}"; then$/)
  snap = stext[/^SNAPSHOT=(\S+)$/, 1].to_s
  errors << "setup.sh: SNAPSHOT must be a snapshot.debian.org timestamp (YYYYMMDDTHHMMSSZ), got #{snap.inspect}" unless snap.match?(/\A\d{8}T\d{6}Z\z/)
  uris = stext.scan(/^URIs:\s*(\S+)$/).flatten
  errors << "setup.sh: apt must read only snapshot.debian.org at ${SNAPSHOT}, got #{uris.inspect}" if uris.empty? || uris.any? { |u| !u.match?(%r{\Ahttps://snapshot\.debian\.org/archive/[a-z-]+/\$\{SNAPSHOT\}\z}) }
  pkgs = stext[/^PACKAGES=\(\n(.*?)^\)/m, 1].to_s.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
  errors << "setup.sh: PACKAGES is empty" if pkgs.empty?
  pkgs.reject { |p| p.match?(/\A[a-z0-9][a-z0-9.+-]*=[0-9][0-9A-Za-z.+~:-]*\z/) }.each do |p|
    errors << "setup.sh: package #{p.inspect} must be pinned as name=exact-version"
  end
  errors << "setup.sh: GIT_VERSION must be an exact x.y.z release" unless stext.match?(/^GIT_VERSION=\d+\.\d+\.\d+$/)
  errors << "setup.sh: GIT_SHA256 must be the tarball's 64-hex sha256" unless stext.match?(/^GIT_SHA256=[0-9a-f]{64}$/)
  errors << "setup.sh: the git tarball must be checked with sha256sum -c against GIT_SHA256" unless stext.include?('echo "${GIT_SHA256}  ${src}/git.tar.xz" | sha256sum -c')
else
  errors << "setup.sh: #{setup} is missing"
end

if errors.empty?
  puts "gitlab-ci check: OK (#{jobs.size} job(s))"
else
  errors.each { |e| warn "gitlab-ci check: FAIL -- #{e}" }
  warn "  Fix: restore the rule in .gitlab-ci.yml or dockerfiles/ci-harness/ (see ai/test/gitlab-ci/self-test.sh)."
  exit 1
end
