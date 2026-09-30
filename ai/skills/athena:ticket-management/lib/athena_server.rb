# frozen_string_literal: true

# athena_server.rb -- how this skill's scripts reach the Athena server
# (DND-1054). Extracted from finding-triage (DND-713) so ticket-classify does
# not copy it. Side Effects only: files, the MCP registry, and curl.
#
# Callers: scripts/finding-triage, scripts/ticket-classify and
# scripts/ticket-reclassify (DND-1056). Each maps the
# two exceptions below to its own unavailable line, which carries the `Fix:`.
#
# TOKENS NEVER TOUCH ARGV OR THE ENVIRONMENT. Every header value, the token
# included, is written into a curl config that curl reads on STDIN
# (`--config -`). No token is ever printed or put in an exception message.
#
# Deliberately gem-free (stdlib only).

require "json"
require "open3"
require "tmpdir"

module AthenaServer
  # The server (or the way to it) cannot be used. The message is the reason,
  # safe to print: it names a path or an exit code, never a token.
  class Unreachable < StandardError; end

  # A request value holds a quote, backslash or control character, which a
  # curl config line cannot carry safely. Refused before anything is sent.
  class UnsafeValue < StandardError; end

  # The harness repo root: lib/ sits at the same depth as scripts/.
  HARNESS = File.expand_path("../../../..", __dir__)

  module_function

  # claude_json -> the parsed ~/.claude.json (or FLEET_CLAUDE_JSON), or nil.
  def claude_json
    path = ENV["FLEET_CLAUDE_JSON"] || File.join(Dir.home, ".claude.json")
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def main_checkout(dir)
    out, status = Open3.capture2e("git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return nil unless status.success?

    common = out.strip
    common.start_with?("/") ? common.delete_suffix("/.git") : nil
  rescue SystemCallError
    nil
  end

  # mcp_entry(doc, name) -> the MCP entry: local scope for this repo, then the
  # harness repo, then user scope.
  def mcp_entry(doc, name)
    keys = [main_checkout(Dir.pwd), main_checkout(HARNESS)].compact.uniq
    keys.lazy.map { |k| doc.dig("projects", k, "mcpServers", name) }.find(&:itself) || doc.dig("mcpServers", name)
  end

  # safe_origin(url) -> scheme://authority; https, or http only to loopback.
  def safe_origin(url)
    m = %r{\A(https?)://([^/?#@]*)(?:[/?#]|\z)}.match(url.to_s)
    return nil unless m
    return nil if m[1] == "http" && !/\A(127\.0\.0\.1|localhost|\[::1\])(:\d{1,5})?\z/.match?(m[2])

    "#{m[1]}://#{m[2]}"
  end

  # endpoint -> [origin, token], or raises Unreachable with the reason.
  def endpoint
    doc = claude_json
    raise Unreachable, "no readable ~/.claude.json (or FLEET_CLAUDE_JSON)" if doc.nil?

    entry = mcp_entry(doc, "athena")
    origin = entry.is_a?(Hash) ? safe_origin(entry["url"]) : nil
    raise Unreachable, "no athena MCP entry with an https URL (register it with scripts/add-athena-mcp)" if origin.nil?

    [origin, token]
  end

  # token -> the machine token, or raises Unreachable naming the path read.
  def token
    path = ENV["ATHENA_INBOX_CLIENT_CONFIG"] || File.join(ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config"), "athena-inbox-client", "config.json")
    value = begin
      JSON.parse(File.read(path))["token"]
    rescue JSON::ParserError, SystemCallError, TypeError, NoMethodError
      nil
    end
    raise Unreachable, "no machine token in #{path} (the inbox client config is owner-issued)" unless value.is_a?(String) && !value.empty?

    value
  end

  # max_time(env_name) -> the per-request curl max-time in seconds (1..9999),
  # from that environment variable, else 60.
  def max_time(env_name)
    value = ENV[env_name].to_s
    /\A[1-9]\d{0,3}\z/.match?(value) ? value : "60"
  end

  # request(method, url, headers, body, max_time:) -> {curl_rc:, status:, body:}.
  # Every header value (the token included) goes into a curl config on STDIN.
  # Raises UnsafeValue before sending a value a config line cannot carry, and
  # Unreachable when curl itself is missing.
  def request(method, url, headers, body, max_time:)
    ([url] + headers).each do |value|
      raise UnsafeValue, "a request value contains a quote, backslash or control character" if /["\\[:cntrl:]]/.match?(value)
    end
    Dir.mktmpdir("athena-server-") do |dir|
      File.chmod(0o700, dir)
      resp = File.join(dir, "resp")
      config = +""
      config << %(url = "#{url}"\n)
      config << %(request = "#{method}"\n)
      headers.each { |h| config << %(header = "#{h}"\n) }
      if body
        req = File.join(dir, "req.json")
        File.write(req, JSON.generate(body), perm: 0o600)
        config << %(data-binary = "@#{req}"\n)
      end
      config << %(output = "#{resp}"\n)
      config << %(write-out = "%{http_code}"\n)
      config << "connect-timeout = 10\nmax-time = #{max_time}\nsilent\n"
      out, _err, status = Open3.capture3("curl", "--config", "-", stdin_data: config)
      config.clear
      # The answer is read as UTF-8 whatever the locale: under LANG=C the
      # default external encoding is US-ASCII, and JSON.parse then raises on
      # the first non-ASCII byte (DND-1054 review round).
      body = File.exist?(resp) ? File.binread(resp).force_encoding(Encoding::UTF_8) : +""
      { curl_rc: status.exitstatus, status: out.strip.to_i, body: body }
    end
  rescue Errno::ENOENT
    raise Unreachable, "curl is not on PATH"
  end

  # post_json(origin, token, path, body, max_time:) -> request's result, for a
  # JSON POST to the Athena server with the machine token.
  def post_json(origin, token, path, body, max_time:)
    headers = ["Authorization: Bearer #{token}", "Accept: application/json", "Content-Type: application/json"]
    request("POST", "#{origin}#{path}", headers, body, max_time: max_time)
  end
end
