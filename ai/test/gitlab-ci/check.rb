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

# The sibling containers (DND-2085). Every `docker` word in the file is a
# call to the `ci` user's rootless daemon, so the checker reads ALL of them
# with an allowlist: each must be a whole command of one known shape, and a
# `docker` word it cannot read as one (behind a wrapper, inside a quoted
# payload or a substitution, glued to a separator) fails. No container may
# widen past what the decision grants (ai/docs/ci-harness-masked-proc.md ->
# The boundary): no flag outside RUN_FLAGS, so no --privileged, host
# namespace, --cap-add, device, extra mount or socket.
SECURITY_OPTS = %w[seccomp=unconfined apparmor=unconfined systempaths=unconfined].freeze
GATE_NAME = "custom-gate-$CI_JOB_ID"
PROBE_NAME = "custom-probe-$CI_JOB_ID"
PREP_NAME = "custom-prep-$CI_JOB_ID"
NAMES = [GATE_NAME, PROBE_NAME, PREP_NAME].freeze
PROBE_CMD = "dockerfiles/ci-harness/boundary-probe.sh"
IMAGE_VAR = "$CI_HARNESS_IMAGE"
IMAGE_DIR = "dockerfiles/ci-harness"
SECOPTS_FILE = "/tmp/ci-security-options"
INFO_CMD = ["docker", "info", "--format", "{{.SecurityOptions}}", ">", SECOPTS_FILE].freeze
BUILD_CMD = ["docker", "build", "--progress=plain", "-t", IMAGE_VAR, IMAGE_DIR].freeze
RM_TAIL = [">/dev/null", "2>&1"].freeze
# docker run flags: those with no value, and those taking the next word.
RUN_BARE = %w[--rm --init].freeze
RUN_VALUED = %w[--name --user -e --security-opt -v -w].freeze
SEPARATORS = %w[&& || ; | &].freeze
# A standalone `docker` word: not part of dockerfiles/, dockerd or docker.sock.
DOCKER_WORD = %r{(?<![\w/.$-])docker(?![\w/.-])}

# Each shell command in a string, as word arrays: backslash-newline
# continuations joined, then split on newlines and on standalone separators.
# A line that does not tokenize is reported.
commands_in = lambda do |text, where|
  text.to_s.gsub("\\\n", " ").split("\n").flat_map do |line|
    begin
      words = Shellwords.split(line)
    rescue ArgumentError => e
      errors << "#{where}: a script line does not parse as shell words (#{e.message}): #{line.strip[0, 80]}"
      next []
    end
    words.slice_when { |a, _b| SEPARATORS.include?(a) }.map { |c| c.reject { |w| SEPARATORS.include?(w) } }.reject(&:empty?)
  end
end

# parse_run WORDS -> [flags, image, command, problems]; flags is a list of
# [flag, value-or-nil]. Every word before the image must be an allowed flag.
parse_run = lambda do |w|
  flags = []
  problems = []
  i = 2
  while i < w.size && w[i].start_with?("-")
    f = w[i]
    if RUN_BARE.include?(f)
      flags << [f, nil]
      i += 1
    elsif RUN_VALUED.include?(f)
      flags << [f, w[i + 1].to_s]
      i += 2
    else
      problems << "flag #{f.inspect} is not allowed (allowed: #{(RUN_BARE + RUN_VALUED).join(' ')}, each spelled as its own word)"
      i += 1
    end
  end
  [flags, w[i], w[(i + 1)..] || [], problems]
end

# The strings a shell may run: every string in the file except image names
# (`image: <name>` or `image: {name: <name>}`); an image's entrypoint is a
# command, so it is still read.
image_values = lambda do |node|
  case node
  when Hash
    node.flat_map do |k, v|
      if k.to_s == "image" && v.is_a?(String) then [v]
      elsif k.to_s == "image" && v.is_a?(Hash) then [v["name"].to_s] + image_values.call(v)
      else image_values.call(v)
      end
    end
  when Array then node.flat_map { |v| image_values.call(v) }
  else []
  end
end
skip = image_values.call(doc)
shell_strings = all_strings.reject { |s| skip.include?(s) }

docker_cmds = []
shell_strings.each do |s|
  cmds = commands_in.call(s, "docker")
  readable = cmds.select { |c| c[0] == "docker" }
  seen = s.gsub("\\\n", " ").scan(DOCKER_WORD).size
  if seen != readable.size
    errors << "docker: a `docker` word the checker cannot read as a whole command (behind a wrapper, inside quotes or $(...), or glued to a separator): #{s.strip.lines.first.to_s.strip[0, 100]}"
  end
  docker_cmds.concat(readable)
end

runs = []
docker_cmds.each do |c|
  case c[1]
  when "info"
    errors << "docker info: must be exactly `#{INFO_CMD.join(' ')}`, got `#{c.join(' ')}`" unless c == INFO_CMD
  when "build"
    errors << "docker build: must be exactly `#{BUILD_CMD.join(' ')}`, got `#{c.join(' ')}`" unless c == BUILD_CMD
  when "rm"
    names = c[3..].to_a.reject { |x| RM_TAIL.include?(x) }
    errors << "docker rm: must be `docker rm -f` of the sibling names #{NAMES.inspect} only, got `#{c.join(' ')}`" unless c[2] == "-f" && !names.empty? && (names - NAMES).empty?
  when "run"
    flags, image, command, problems = parse_run.call(c)
    name = flags.select { |f, _| f == "--name" }.map(&:last)
    label = name.size == 1 && NAMES.include?(name.first) ? name.first : "an unnamed"
    problems.each { |p| errors << "docker run (#{label} container): #{p}" }
    runs << { label: label, flags: flags, image: image, command: command }
  else
    errors << "docker: only `docker info`, `docker build`, `docker run` and `docker rm` are allowed, each with no global option; got `#{c.join(' ')}`"
  end
end
errors << "docker run: the harness-gate job must start the gate in a sibling container (`docker run`); none found" if runs.empty?

# Per container: a known name, --rm, the built image, the checkout at its own
# path, a user, and the security options and environment its role allows.
runs.each do |r|
  vals = ->(f) { r[:flags].select { |x, _| x == f }.map(&:last) }
  where = "docker run (#{r[:label]} container)"
  errors << "#{where}: must be named one of #{NAMES.inspect} (after_script removes them by name)" unless NAMES.include?(r[:label])
  errors << "#{where}: must be removed on exit (--rm)" unless vals.call("--rm").size == 1
  errors << "#{where}: must run the built image #{IMAGE_VAR}" unless r[:image] == IMAGE_VAR
  errors << "#{where}: must bind only the checkout at its own path (-v \"$CI_PROJECT_DIR:$CI_PROJECT_DIR\") and work there (-w \"$CI_PROJECT_DIR\")" unless vals.call("-v") == ["$CI_PROJECT_DIR:$CI_PROJECT_DIR"] && vals.call("-w") == ["$CI_PROJECT_DIR"]
  errors << "#{where}: --name and --user must each appear exactly once" unless vals.call("--name").size == 1 && vals.call("--user").size == 1
  opts = vals.call("--security-opt")
  unmasked = [GATE_NAME, PROBE_NAME].include?(r[:label])
  if unmasked
    errors << "#{where}: must carry exactly the three --security-opt values #{SECURITY_OPTS.inspect}, each once, got #{opts.inspect}" unless opts.sort == SECURITY_OPTS.sort
  elsif !opts.empty?
    errors << "#{where}: takes no --security-opt (only the gate and the probe run unmasked), got #{opts.inspect}"
  end
  # Environment: only the gate gets one variable, CI_JOB_TOKEN by name, so its
  # git can reach origin for the landed bars. No literal value.
  envs = vals.call("-e")
  allowed_env = r[:label] == GATE_NAME ? ["CI_JOB_TOKEN"] : []
  errors << "#{where}: -e may name only #{allowed_env.inspect} (by name, no value), got #{envs.inspect}" unless (envs - allowed_env).empty? && envs.size == envs.uniq.size
  errors << "#{where}: --init is for the gate only" if !vals.call("--init").empty? && r[:label] != GATE_NAME
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
  # run_with NAME: the parsed `docker run` named NAME, and its script index.
  run_i = ->(name) { first_i.call(->(c) { c[0] == "docker" && c[1] == "run" && c.include?(name) }) }
  run_of = ->(name) { runs.find { |r| r[:label] == name } }

  info_i = first_i.call(->(c) { c == INFO_CMD })
  # The rootless refusal: exactly this test, then exit 1 with a Fix:.
  rootless_i = scripts.index do |s|
    lines = s.strip.lines.map(&:strip)
    lines.first == "if ! grep -qw 'name=rootless' #{SECOPTS_FILE}; then" && lines.last == "fi" &&
      lines.any? { |l| l.include?("Fix:") } && lines[-2] == "exit 1"
  end
  build_i = first_i.call(->(c) { c == BUILD_CMD })
  tag_i = scripts.index { |s| s.match?(/\ACI_HARNESS_IMAGE="custom-ci-harness:\$\(/) && s.include?("find #{IMAGE_DIR} -type f") && s.include?("sha256sum") }
  fetch_i = first_i.call(->(c) { c[0] == "git" && c.include?("fetch") && c.any? { |x| x.include?("refs/remotes/origin/main") } })
  probe_i = run_i.call(PROBE_NAME)
  prep_i = run_i.call(PREP_NAME)
  gate_i = run_i.call(GATE_NAME)

  errors << "harness-gate: script must record the daemon's security options (`#{INFO_CMD.join(' ')}`)" if info_i.nil?
  errors << "harness-gate: script must refuse a daemon that is not rootless (`if ! grep -qw 'name=rootless' #{SECOPTS_FILE}; then` ... with a Fix: ... `exit 1` / `fi`)" if rootless_i.nil?
  errors << "harness-gate: script must set CI_HARNESS_IMAGE to custom-ci-harness:<content hash of #{IMAGE_DIR}> (find #{IMAGE_DIR} -type f ... sha256sum)" if tag_i.nil?
  errors << "harness-gate: script must build the image (`#{BUILD_CMD.join(' ')}`)" if build_i.nil?
  errors << "harness-gate: script must fetch origin/main explicitly (git ... fetch ... refs/remotes/origin/main)" if fetch_i.nil?

  gate_runs = runs.select { |r| r[:command].include?("ai/bin/harness-gate") || r[:command].any? { |x| x.include?("harness-gate") } }
  gate_r = run_of.call(GATE_NAME)
  if gate_runs.size != 1 || gate_r.nil? || !gate_runs.include?(gate_r)
    errors << "harness-gate: script must run `ai/bin/harness-gate` as the command of exactly one `docker run`, the one named #{GATE_NAME}; got #{gate_runs.size}"
  else
    errors << "harness-gate container: its command must be exactly ai/bin/harness-gate, right after the image" unless gate_r[:command] == ["ai/bin/harness-gate"]
    errors << "harness-gate container: must run as the image's non-root user (--user ci)" unless gate_r[:flags].include?(["--user", "ci"])
  end
  errors << "harness-gate: script must run `ai/bin/harness-gate` in the sibling, not in the job container" if cmds.any? { |_i, c| c[0] != "docker" && c.any? { |x| x.end_with?("bin/harness-gate") } }

  probe_r = run_of.call(PROBE_NAME)
  if probe_r.nil?
    errors << "boundary probe: script must run #{PROBE_CMD} in its own container named #{PROBE_NAME}"
  else
    errors << "boundary probe container: must run as the image's root (--user 0), where a denial means the daemon is rootless" unless probe_r[:flags].include?(["--user", "0"])
    errors << "boundary probe container: its command must be exactly #{PROBE_CMD}, with no arguments" unless probe_r[:command] == [PROBE_CMD]
  end

  prep_r = run_of.call(PREP_NAME)
  if prep_r.nil? || prep_r[:command] != ["chown", "-R", "ci:ci", "$CI_PROJECT_DIR"] || !prep_r[:flags].include?(["--user", "0"])
    errors << "harness-gate: script must hand the tree to ci in a container named #{PREP_NAME} (`--user 0` ... `chown -R ci:ci \"$CI_PROJECT_DIR\"`): git refuses a tree another user owns"
  end

  if gate_i
    { "the rootless check" => rootless_i, "the image tag" => tag_i, "the image build" => build_i, "the boundary probe" => probe_i,
      "the origin/main fetch" => fetch_i, "the chown to ci" => prep_i }.each do |what, i|
      errors << "harness-gate: #{what} must come before the gate container" if i && i > gate_i
    end
  end
  errors << "harness-gate: the security options must be recorded before the rootless check" if info_i && rootless_i && info_i > rootless_i
  errors << "harness-gate: the rootless check must come before the first sibling container" if rootless_i && [probe_i, prep_i, gate_i].compact.any? { |i| i < rootless_i }
  errors << "harness-gate: the image tag must be set before the build" if tag_i && build_i && tag_i > build_i
  errors << "harness-gate: the image must be built before the boundary probe" if build_i && probe_i && build_i > probe_i

  after = Array(gate["after_script"]).flatten.map(&:to_s)
  rm = after.flat_map { |s| commands_in.call(s, "harness-gate after_script") }.find { |c| c[0] == "docker" && c[1] == "rm" && c.include?("-f") }
  errors << "harness-gate: after_script must remove every sibling container by name (`docker rm -f` #{NAMES.map { |n| "\"#{n}\"" }.join(' ')}), so a cancelled job leaves none" unless rm && NAMES.all? { |n| rm.include?(n) }

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
  %w[SNAPSHOT GIT_VERSION GIT_SHA256 PACKAGES GEMS].each do |var|
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
  # Gems beyond Ruby's own: each pinned, installed by exactly that list.
  gems = stext[/^GEMS=\(\n(.*?)^\)/m, 1].to_s.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
  errors << "setup.sh: GEMS is empty" if gems.empty?
  gems.reject { |g| g.match?(/\A[a-z0-9][a-z0-9_.-]*:\d+(\.\d+)+\z/) }.each do |g|
    errors << "setup.sh: gem #{g.inspect} must be pinned as name:exact-version"
  end
  gem_lines = stext.lines.grep(/^\s*gem install\b/)
  gem_cmd = %q{gem install --no-document --install-dir "$(ruby -e 'print Gem.default_dir')" "${GEMS[@]}"}
  errors << "setup.sh: gems must be installed by exactly `#{gem_cmd}` (one line, no extra gem, into Ruby's own gem dir)" unless gem_lines.size == 1 && gem_lines.first.strip == gem_cmd
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
