# frozen_string_literal: true

# ai/lib/notion_read.rb -- a READ-ONLY Notion client (Side Effects) shared by
# triage-corpus and ticket-reclassify. Extracted from ai/bin/triage-corpus
# (DND-714) by DND-1056 so ticket-reclassify reads the tracker through the
# same allowlist instead of a copy.
#
# Callers: ai/bin/triage-corpus, scripts/ticket-classify --epic (DND-1057),
# ai/bin/judgment-feedback scan-tickets (DND-1469), scripts/ticket-provenance-check
# (DND-1354) and
# ai/skills/athena:ticket-management/scripts/ticket-reclassify. Each maps
# NotionRead::Error to its own failure line, which carries the Fix:.
#
# READ ONLY: #read admits a data source query, a block-children list (with an
# optional cursor) and a page retrieve, and refuses any other request BEFORE
# it is sent. There is no write path here.
#
# THE TOKEN NEVER TOUCHES ARGV OR THE ENVIRONMENT: it is read from the file
# the notion-personal MCP entry names and fed to curl on STDIN (`--config -`).
#
# Deliberately gem-free (stdlib only).

require "json"
require "open3"
require "tmpdir"

module NotionRead
  # A read that could not be made or answered. `fix` is the action; the
  # message names the request (never the token). `status` is the HTTP status
  # when Notion answered, else nil.
  class Error < StandardError
    attr_reader :fix, :status

    def initialize(message, fix, status: nil)
      super(message)
      @fix = fix
      @status = status
    end
  end

  NOTION_VERSION = "2025-09-03"
  UUID = "[0-9a-f-]{36}"
  READS = [
    ["POST", %r{\A/v1/data_sources/#{UUID}/query\z}],
    ["GET", %r{\A/v1/blocks/#{UUID}/children\?page_size=\d{1,3}(&start_cursor=#{UUID})?\z}],
    ["GET", %r{\A/v1/pages/#{UUID}\z}]
  ].freeze
  TRIES = 3
  # The harness repo root: this file is ai/lib/notion_read.rb.
  HARNESS = File.expand_path("../..", __dir__)

  module_function

  def read?(method, path)
    READS.any? { |m, re| m == method && re.match?(path) }
  end

  def main_checkout(dir)
    out, status = Open3.capture2e("git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return nil unless status.success?

    common = out.strip
    common.start_with?("/") ? common.delete_suffix("/.git") : nil
  rescue SystemCallError
    nil
  end

  # credentials(api_override) -> [origin, token]. The token is the file the
  # notion-personal MCP entry launches with (its NOTION_ATHENA_TOKEN_FILE);
  # api_override is a loopback URL for tests, or nil for api.notion.com.
  def credentials(api_override)
    path = ENV["FLEET_CLAUDE_JSON"] || File.join(Dir.home, ".claude.json")
    doc = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      raise Error.new("cannot read #{path} to find the notion-personal MCP entry", "register notion-personal (its env names NOTION_ATHENA_TOKEN_FILE)")
    end
    keys = [main_checkout(Dir.pwd), main_checkout(HARNESS)].compact.uniq
    entry = keys.lazy.map { |k| doc.dig("projects", k, "mcpServers", "notion-personal") }.find(&:itself) || doc.dig("mcpServers", "notion-personal")
    token_file = entry.is_a?(Hash) ? entry.dig("env", "NOTION_ATHENA_TOKEN_FILE") : nil
    unless token_file.is_a?(String) && token_file.start_with?("/")
      raise Error.new("the notion-personal MCP entry in #{path} names no absolute NOTION_ATHENA_TOKEN_FILE", "repair that entry (owner-gated credential); this tool only reads it")
    end
    token = begin
      File.read(token_file).strip
    rescue SystemCallError
      nil
    end
    raise Error.new("the Notion token file #{token_file} is missing or empty", "the token is owner-issued; never mint one") if token.nil? || token.empty?

    [api_override ? loopback(api_override) : "https://api.notion.com", token]
  end

  def loopback(url)
    m = %r{\Ahttp://(127\.0\.0\.1|localhost)(:\d{1,5})?/?\z}.match(url)
    raise Error.new("the Notion API override must be a loopback http URL", "unset it (tests only)") unless m

    "http://#{m[1]}#{m[2]}"
  end

  # read(origin, token, method, path, body = nil, pace:) -> parsed JSON, or
  # raises Error. Anything but an allow-listed READ is refused before it is
  # sent. A 429 is retried (TRIES in all), honouring Retry-After up to 10 s.
  def read(origin, token, method, path, body = nil, pace:)
    raise Error.new("refused a Notion #{method} #{path}: this client only reads", "this is a bug in the caller: it asked for a write") unless read?(method, path)

    reply = nil
    TRIES.times do |i|
      sleep(pace) if pace.positive?
      reply = request(method, "#{origin}#{path}", token, body)
      break unless reply[:status] == 429 && i < TRIES - 1

      sleep([reply[:retry_after], 10].min)
    end
    raise Error.new("could not reach Notion (curl exit #{reply[:curl_rc]})", "check the network, then re-run") if reply[:curl_rc] != 0
    unless reply[:status] == 200
      raise Error.new("Notion answered HTTP #{reply[:status]} to #{method} #{path.sub(/\?.*/, '')}",
                      "re-run; on 401/403 the token or the page share is the owner's to fix", status: reply[:status])
    end
    JSON.parse(reply[:body])
  rescue JSON::ParserError
    raise Error.new("Notion answered a body that is not JSON", "re-run")
  end

  def request(method, url, token, body)
    [url, token].each do |value|
      raise Error.new("a request value contains a quote, backslash or control character", "repair the Notion token file or the URL") if /["\\[:cntrl:]]/.match?(value)
    end
    Dir.mktmpdir("notion-read-") do |dir|
      File.chmod(0o700, dir)
      resp = File.join(dir, "resp")
      hdrs = File.join(dir, "hdrs")
      config = +""
      config << %(url = "#{url}"\nrequest = "#{method}"\n)
      config << %(header = "Authorization: Bearer #{token}"\nheader = "Notion-Version: #{NOTION_VERSION}"\nheader = "Accept: application/json"\n)
      if body
        req = File.join(dir, "req.json")
        File.write(req, JSON.generate(body), perm: 0o600)
        config << %(header = "Content-Type: application/json"\ndata-binary = "@#{req}"\n)
      end
      config << %(output = "#{resp}"\ndump-header = "#{hdrs}"\nwrite-out = "%{http_code}"\n)
      config << "connect-timeout = 10\nmax-time = 60\nsilent\n"
      out, _err, status = Open3.capture3("curl", "--config", "-", stdin_data: config)
      config.clear
      retry_after = File.exist?(hdrs) ? File.read(hdrs)[/^retry-after:\s*(\d+)/i, 1].to_i : 0
      text = File.exist?(resp) ? File.binread(resp).force_encoding(Encoding::UTF_8) : +""
      { curl_rc: status.exitstatus, status: out.strip.to_i, body: text, retry_after: [retry_after, 1].max }
    end
  rescue Errno::ENOENT
    raise Error.new("curl is not on PATH", "install curl")
  end

  # query_all(origin, token, data_source, pace:, filter: nil) -> every row
  # (matching `filter`, a Notion data source filter, when given), following
  # the cursor.
  def query_all(origin, token, data_source, pace:, filter: nil)
    rows = []
    cursor = nil
    loop do
      body = { "page_size" => 100 }
      body["filter"] = filter if filter
      body["start_cursor"] = cursor if cursor
      page = read(origin, token, "POST", "/v1/data_sources/#{data_source}/query", body, pace: pace)
      rows.concat(Array(page["results"]))
      break unless page["has_more"] == true

      cursor = page["next_cursor"]
      # A cut-off list must never read as the whole data source.
      raise Error.new("Notion said has_more for data source #{data_source} with no usable next_cursor", "re-run; the rest of the rows could not be reached") unless cursor.is_a?(String) && !cursor.empty?
    end
    rows
  end

  # children_all(origin, token, page_id, pace:) -> every top-level block of
  # the page, following the cursor to the LAST block (a line appended to a
  # long body is on its last page).
  def children_all(origin, token, page_id, pace:)
    blocks = []
    cursor = nil
    loop do
      path = "/v1/blocks/#{page_id}/children?page_size=100"
      path += "&start_cursor=#{cursor}" if cursor
      page = read(origin, token, "GET", path, pace: pace)
      blocks.concat(Array(page["results"]))
      break unless page["has_more"] == true

      cursor = page["next_cursor"]
      raise Error.new("Notion said has_more for #{page_id}'s blocks with no usable next_cursor", "re-run; the last block could not be reached") unless cursor.is_a?(String) && /\A#{UUID}\z/.match?(cursor)
    end
    blocks
  end

  # page(origin, token, page_id, pace:) -> the page object (its properties).
  def page(origin, token, page_id, pace:)
    read(origin, token, "GET", "/v1/pages/#{page_id}", pace: pace)
  end
end
