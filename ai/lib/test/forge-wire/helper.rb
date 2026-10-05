# frozen_string_literal: true

# Shared assertions for the forge-wire Domain suites (DND-2025). Plain stdlib,
# like the other ai/lib suites: no gem, no network, no clock.

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# True when the block raises `klass` (or a subclass); false when it returns.
def raises?(klass, message = nil)
  yield
  false
rescue klass => e
  message.nil? || e.message.include?(message)
end

def finish(name)
  if $failures.empty?
    puts "#{name}: #{$checks} passed, 0 failed"
    exit 0
  end
  $failures.each { |f| puts "FAIL  #{f}" }
  puts "#{name}: #{$checks - $failures.size} passed, #{$failures.size} failed"
  exit 1
end

# A request as CRLF-joined lines plus a body.
def http(*lines, body: "")
  (lines.join("\r\n") + "\r\n\r\n" + body).b
end

GH_API = "api.github.com"
GL_HOST = "gitlab.com"

# A parsed ForgeWire::Request built from parts. `target` is "/path?query".
def wire(method, target, host: GH_API, body: "", type: "application/json", headers: [])
  require_relative "../../forge_wire/request"
  lines = ["#{method} #{target} HTTP/1.1", "Host: #{host}"] + headers
  lines << "Content-Type: #{type}" if type && !body.empty?
  lines << "Content-Length: #{body.bytesize}" unless body.empty?
  ForgeWire::Request.parse(http(*lines, body: body), host: host, max_body: 1 << 20)
end

FIXTURE_DIR = File.expand_path("fixtures", __dir__)

# -> [[file name, ForgeWire::Request], ...] for one captured scenario.
def fixture(name)
  require_relative "../../forge_wire/request"
  dir = File.join(FIXTURE_DIR, name)
  files = Dir.children(dir).grep(/\.http\z/).sort
  raise "fixture #{name} has no requests" if files.empty?

  files.map do |f|
    host = f[/\A\d+-(.+)\.http\z/, 1]
    bytes = File.binread(File.join(dir, f))
    req = ForgeWire::Request.parse(bytes, host: host, max_body: 1 << 20)
    raise "fixture #{name}/#{f} holds trailing bytes" unless req.consumed == bytes.bytesize

    [f, req]
  end
end

def fixture_names
  Dir.children(FIXTURE_DIR).select { |d| File.directory?(File.join(FIXTURE_DIR, d)) }.sort
end

# The operation table as shipped (the branch copy: a self-test judges the
# branch's own table; the proxy loads the main checkout's).
def shipped_table
  require_relative "../../forge_wire/operations"
  ForgeWire::Operations.parse(File.read(ForgeWire::Operations::DEFAULT), ForgeWire::Operations::DEFAULT)
end
