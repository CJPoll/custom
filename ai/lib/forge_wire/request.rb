# frozen_string_literal: true

# ai/lib/forge_wire/request.rb -- one HTTP/1.1 request as data (DND-2025).
# Design: ai/docs/outbound-scan-at-the-wire.md -> Components, by bucket.
#
# Domain only: bytes in, a Request out. No socket, no clock, no environment.
# The proxy (build step 2) is to read bytes from the CLI and hand them here;
# this file decides whether they are one whole, well-framed request.
#
# Two failures, never confused:
#   Incomplete   the bytes so far are a valid prefix; read more.
#   Unparseable  the bytes can never become a request this judge accepts; the
#                proxy refuses. Its message names the rule, never body text.
#
# What is refused, and why (each one is a place where two parsers -- this one
# and the forge's -- could read different requests from the same bytes, and a
# write could pass judged as one thing and land as another):
#   - any version but HTTP/1.1; any request target but origin-form; a fragment;
#     a request line not split by exactly one SP; an empty request line,
#     including the leading empty line RFC 9112 2.2 lets a server skip
#   - bare LF or CR line endings, obs-fold, whitespace before a colon, a header
#     line without a colon, a NUL or control character anywhere in a header
#     value (only SP and HTAB are trimmed), a control character in a chunk
#     extension
#   - a missing or duplicate Host, or a Host that is not the CONNECT host
#     (port 443 or none)
#   - duplicate Content-Length, Transfer-Encoding, Content-Encoding,
#     Content-Type or Expect; both Content-Length and Transfer-Encoding; a
#     Transfer-Encoding other than exactly `chunked`; chunk trailers
#   - Upgrade, Connection: upgrade, an Expect other than 100-continue
#   - a header block over HEAD_CAP; a body (raw or decoded) over max_body
#   - a Content-Encoding other than identity, gzip or deflate, stacked
#     encodings, or a body that does not decode cleanly

require "zlib"

module ForgeWire
  class Unparseable < StandardError; end
  class Incomplete < StandardError; end

  # A parsed request. `body` is decoded (Content-Encoding removed); `raw_body`
  # is the de-chunked bytes as sent. `path` and `query` are raw (still
  # percent-encoded); `query` is nil when the target has no `?`.
  Request = Struct.new(:method, :host, :path, :query, :headers, :body, :raw_body, :consumed, keyword_init: true) do
    # The last value of a header, by case-insensitive name; nil when absent.
    def header(name)
      key = name.downcase
      pair = headers.reverse.find { |k, _| k == key }
      pair && pair[1]
    end

    def content_type
      header("content-type")
    end

    # The media type, lower-cased, without parameters ("application/json").
    def media_type
      ct = content_type
      ct && ct.split(";", 2).first.strip.downcase
    end
  end

  class Request
    # bytes -> Request. `host` is the CONNECT host (lower case); `max_body`
    # caps the raw and the decoded body.
    def self.parse(bytes, host:, max_body:)
      Parser.new(bytes.b, host.downcase, max_body).parse
    end
  end

  # The framing rules. Private to this file; callers use Request.parse.
  class Request::Parser
    HEAD_CAP = 64 * 1024
    CHUNK_LINE_CAP = 1024
    TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/.freeze
    # Visible ASCII, no space, no `#`: an origin-form target.
    TARGET = %r{\A/[\x21-\x22\x24-\x7e]*\z}.freeze
    SINGLE = %w[host content-length transfer-encoding content-encoding content-type expect].freeze
    CRLF = "\r\n"

    def initialize(bytes, host, max_body)
      @b = bytes
      @host = host
      @max = max_body
    end

    def parse
      head_end = locate_head_end
      lines = @b.byteslice(0, head_end).split(CRLF, -1)
      method, path, query = request_line(lines.first)
      headers = header_fields(lines.drop(1))
      check_host(headers)
      check_connection(headers)
      raw, consumed = body(headers, head_end + 4)
      Request.new(method: method, host: @host, path: path, query: query, headers: headers,
                  body: decode(raw, headers), raw_body: raw, consumed: consumed)
    end

    private

    def unparseable(msg)
      raise Unparseable, msg
    end

    # The index of "\r\n\r\n". A bare LF or CR anywhere in the head is
    # Unparseable even before the head is complete: no more bytes can fix it.
    def locate_head_end
      # RFC 9112 2.2 lets a server skip one empty line before the request
      # line; this judge refuses it (gh and glab never send one, and a
      # tolerance is one more rule two parsers could read differently).
      unparseable("the request line is empty (a leading CRLF is refused)") if @b.start_with?("\r\n")
      idx = @b.index("\r\n\r\n")
      head = idx ? @b.byteslice(0, idx + 4) : @b
      unparseable("a line ending is not CRLF") if head.match?(/(?<!\r)\n|\r(?!\n|\z)/n)
      unparseable("the header block is over the #{HEAD_CAP}-byte cap") if (idx || @b.bytesize) > HEAD_CAP
      raise Incomplete, "the header block has not ended" unless idx

      idx
    end

    def request_line(line)
      unparseable("the request line is empty") if line.nil? || line.empty?
      parts = line.split(/ /, -1)
      unparseable("the request line is not METHOD SP TARGET SP VERSION") unless parts.length == 3
      method, target, version = parts
      unparseable("the version is #{version.inspect}, not HTTP/1.1") unless version == "HTTP/1.1"
      unparseable("the method is not a token") unless TOKEN.match?(method)
      unparseable("the request target is not origin-form (/path?query, no fragment)") unless TARGET.match?(target)
      path, sep, query = target.partition("?")
      [method, path, sep.empty? ? nil : query]
    end

    def header_fields(lines)
      fields = lines.map { |l| header_field(l) }
      SINGLE.each do |name|
        unparseable("#{name} appears more than once") if fields.count { |k, _| k == name } > 1
      end
      fields
    end

    def header_field(line)
      unparseable("a header line is folded (obs-fold)") if line.start_with?(" ", "\t")
      name, colon, value = line.partition(":")
      unparseable("a header line has no colon") if colon.empty?
      unparseable("a header name is not a token") unless TOKEN.match?(name)
      # Trim only SP and HTAB: String#strip also drops NUL, VT, FF, CR and LF,
      # which would accept `Content-Length: 5\0` as 5.
      value = value.gsub(/\A[ \t]+|[ \t]+\z/, "")
      unparseable("a header value holds a control character") if value.match?(/[\x00-\x08\x0a-\x1f\x7f]/n)
      [name.downcase, value]
    end

    def check_host(headers)
      hosts = headers.select { |k, _| k == "host" }
      unparseable("the Host header is missing") if hosts.empty?
      name, port = hosts.first[1].downcase.split(":", 2)
      ok = name == @host && (port.nil? || port == "443")
      unparseable("the Host header is not the CONNECT host #{@host}") unless ok
    end

    def check_connection(headers)
      names = headers.map(&:first)
      unparseable("an Upgrade header is present") if names.include?("upgrade")
      conn = headers.select { |k, _| k == "connection" }.flat_map { |_, v| v.downcase.split(",").map(&:strip) }
      unparseable("Connection asks for an Upgrade") if conn.include?("upgrade")
      expect = headers.find { |k, _| k == "expect" }
      unparseable("Expect is #{expect[1].inspect}, not 100-continue") if expect && expect[1].downcase != "100-continue"
    end

    # -> [raw body, bytes consumed through the end of the body]
    def body(headers, start)
      cl = headers.find { |k, _| k == "content-length" }
      te = headers.find { |k, _| k == "transfer-encoding" }
      unparseable("both Content-Length and Transfer-Encoding are present") if cl && te
      return chunked(start) if te && te[1].downcase == "chunked"
      unparseable("Transfer-Encoding #{te[1].inspect} is not chunked") if te
      return ["".b, start] unless cl

      unparseable("Content-Length is not digits") unless cl[1].match?(/\A[0-9]{1,15}\z/)
      n = cl[1].to_i
      unparseable("the body (#{n} bytes) is over the #{@max}-byte cap") if n > @max
      raise Incomplete, "the body has not fully arrived" if @b.bytesize < start + n

      [@b.byteslice(start, n), start + n]
    end

    def chunked(pos)
      out = +"".b
      loop do
        line_end = @b.index(CRLF, pos)
        unless line_end
          unparseable("a chunk size line is over the cap") if @b.bytesize - pos > CHUNK_LINE_CAP
          raise Incomplete, "the chunk size line has not ended"
        end
        size = chunk_size(@b.byteslice(pos, line_end - pos))
        pos = line_end + 2
        return chunk_end(out, pos) if size.zero?

        unparseable("the chunked body is over the #{@max}-byte cap") if out.bytesize + size > @max
        raise Incomplete, "a chunk has not fully arrived" if @b.bytesize < pos + size + 2

        out << @b.byteslice(pos, size)
        unparseable("chunk data is not followed by CRLF") unless @b.byteslice(pos + size, 2) == CRLF
        pos += size + 2
      end
    end

    def chunk_size(line)
      unparseable("a chunk size line is over the cap") if line.bytesize > CHUNK_LINE_CAP
      hex, _, ext = line.partition(";")
      unparseable("a chunk size is not hex") unless hex.match?(/\A[0-9a-fA-F]{1,8}\z/)
      unparseable("a chunk extension holds a control character") if ext.match?(/[^\x20-\x7e\t]/n)
      hex.to_i(16)
    end

    # After the last chunk: an empty line, or a trailer (refused).
    def chunk_end(out, pos)
      raise Incomplete, "the chunked body has not ended" if @b.bytesize < pos + 2
      unparseable("the chunked body has a trailer field") unless @b.byteslice(pos, 2) == CRLF

      [out, pos + 2]
    end

    def decode(raw, headers)
      enc = headers.find { |k, _| k == "content-encoding" }
      return raw if enc.nil? || enc[1].downcase == "identity"

      case enc[1].downcase
      when "gzip", "x-gzip" then inflate(raw, Zlib::MAX_WBITS + 16)
      when "deflate" then inflate(raw, Zlib::MAX_WBITS)
      else unparseable("Content-Encoding #{enc[1].inspect} is not identity, gzip or deflate")
      end
    end

    # Inflate with the decoded size capped while it is produced, so a small
    # body cannot expand without bound. Trailing bytes or a truncated stream
    # are refused.
    def inflate(raw, wbits)
      z = Zlib::Inflate.new(wbits)
      out = +"".b
      z.inflate(raw) do |chunk|
        out << chunk
        unparseable("the decoded body is over the #{@max}-byte cap") if out.bytesize > @max
      end
      unparseable("the encoded body is truncated") unless z.finished?
      unparseable("the encoded body has bytes after its end") unless z.total_in == raw.bytesize

      out
    rescue Zlib::Error
      unparseable("the encoded body does not decode")
    ensure
      z&.close
    end
  end
end
