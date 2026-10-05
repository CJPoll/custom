# frozen_string_literal: true

# ai/lib/forge_wire/fields.rb -- the text of a write (DND-2025).
# Design: ai/docs/outbound-scan-at-the-wire.md -> What is judged.
#
# Domain only. Two jobs:
#   parse_body  the body by Content-Type: JSON (application/json, */*+json),
#               form-urlencoded, multipart/form-data, or raw bytes. A body
#               declared JSON or multipart that does not parse is Unparseable
#               (refused): a body the judge cannot read is never read as clean.
#   of          every piece of text the write carries, as named fields: each
#               path segment (raw and decoded), each query key and value, and
#               the body's keys, strings and numbers. A raw body that happens
#               to parse as JSON is read both ways, so a \u escape cannot hide
#               text from the scan.
#
# A field NAME never carries request text: names are positions (path[2],
# query[0].value) or JSON key paths whose keys are plain identifiers; any
# other key is named by its position. A refusal prints names, so a name that
# held text could print a work value.

require "json"
require_relative "request"

module ForgeWire
  module Fields
    Field = Struct.new(:name, :text, keyword_init: true)
    Body = Struct.new(:kind, :value, keyword_init: true)

    JSON_MAX_NESTING = 64
    PLAIN_KEY = /\A[A-Za-z0-9_]{1,40}\z/.freeze

    module_function

    def parse_body(req)
      return Body.new(kind: :none, value: nil) if req.body.empty?

      type = req.media_type.to_s
      if json_type?(type)
        Body.new(kind: :json, value: json(req.body))
      elsif type == "application/x-www-form-urlencoded"
        Body.new(kind: :form, value: form_pairs(req.body))
      elsif type == "multipart/form-data"
        Body.new(kind: :multipart, value: multipart(req.body, boundary(req.content_type)))
      else
        Body.new(kind: :raw, value: req.body)
      end
    end

    def json_type?(type)
      type == "application/json" || type.match?(%r{\Aapplication/[a-z0-9.+-]*\+json\z})
    end

    def json(bytes)
      JSON.parse(utf8(bytes), max_nesting: JSON_MAX_NESTING)
    rescue JSON::ParserError, JSON::NestingError, EncodingError
      raise Unparseable, "the JSON body does not parse"
    end

    # -> [Field]
    def of(req, body)
      out = []
      path_fields(req.path, out)
      query_fields(req.query, out)
      body_fields(body, out)
      out
    end

    def path_fields(path, out)
      path.split("/").each_with_index do |seg, i|
        next if seg.empty?

        out << Field.new(name: "path[#{i}]", text: seg)
        dec = pct_decode(seg)
        out << Field.new(name: "path[#{i}].decoded", text: dec) if dec != seg
      end
    end

    def query_fields(query, out)
      return if query.nil? || query.empty?

      form_pairs(query).each_with_index do |(k, v), i|
        out << Field.new(name: "query[#{i}].key", text: k)
        out << Field.new(name: "query[#{i}].value", text: v) unless v.nil?
      end
      out << Field.new(name: "query.raw", text: query)
    end

    def body_fields(body, out)
      case body.kind
      when :json then json_fields(body.value, "body", out)
      when :form
        body.value.each_with_index do |(k, v), i|
          out << Field.new(name: "body[#{i}].key", text: k)
          out << Field.new(name: "body[#{i}].value", text: v) unless v.nil?
        end
      when :multipart then multipart_fields(body.value, out)
      when :raw then raw_fields(body.value, "body", out)
      end
    end

    def raw_fields(bytes, name, out)
      out << Field.new(name: name, text: utf8(bytes))
      begin
        value = JSON.parse(utf8(bytes), max_nesting: JSON_MAX_NESTING)
      rescue JSON::ParserError, JSON::NestingError, EncodingError
        return
      end
      json_fields(value, "#{name}~json", out)
    end

    def json_fields(value, name, out)
      case value
      when Hash
        value.each_with_index do |(k, v), i|
          child = PLAIN_KEY.match?(k) ? "#{name}.#{k}" : "#{name}{#{i}}"
          out << Field.new(name: "#{child}#key", text: k)
          json_fields(v, child, out)
        end
      when Array
        value.each_with_index { |v, i| json_fields(v, "#{name}[#{i}]", out) }
      when String then out << Field.new(name: name, text: value)
      when Numeric then out << Field.new(name: name, text: value.to_s)
      end
    end

    def multipart_fields(parts, out)
      parts.each_with_index do |part, i|
        out << Field.new(name: "part[#{i}].name", text: part[:name]) if part[:name]
        out << Field.new(name: "part[#{i}].filename", text: part[:filename]) if part[:filename]
        part[:headers].each_with_index do |h, j|
          out << Field.new(name: "part[#{i}].header[#{j}]", text: h)
        end
        raw_fields(part[:content], "part[#{i}]", out)
      end
    end

    # "a=1&b=two+words" -> [["a", "1"], ["b", "two words"]]; "flag" -> [["flag", nil]]
    def form_pairs(text)
      utf8(text).split("&").reject(&:empty?).map do |pair|
        k, eq, v = pair.partition("=")
        [form_decode(k), eq.empty? ? nil : form_decode(v)]
      end
    end

    def form_decode(s)
      pct_decode(s.tr("+", " "))
    end

    # Percent-decoding that keeps a malformed escape as written.
    def pct_decode(s)
      utf8(s.b.gsub(/%([0-9A-Fa-f]{2})/n) { [Regexp.last_match(1)].pack("H2") })
    end

    def utf8(bytes)
      s = bytes.dup.force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : s.scrub("?")
    end

    def boundary(content_type)
      m = content_type.to_s.match(/;\s*boundary=(?:"([^"]{1,70})"|([^\s;"]{1,70}))/i)
      raise Unparseable, "multipart/form-data has no boundary" unless m

      m[1] || m[2]
    end

    # -> [{name:, filename:, headers:, content:}]
    def multipart(bytes, boundary)
      delim = "--#{boundary}".b
      body = bytes.b
      raise Unparseable, "multipart body does not start with its boundary" unless body.start_with?(delim)

      chunks = body.split("\r\n#{delim}".b, -1)
      first = chunks.shift.byteslice(delim.bytesize..)
      chunks.unshift(first)
      last = chunks.pop
      raise Unparseable, "multipart body has no closing delimiter" unless last && last.start_with?("--")

      chunks.map { |c| multipart_part(c) }
    end

    def multipart_part(chunk)
      raise Unparseable, "a multipart delimiter is not followed by CRLF" unless chunk.start_with?("\r\n")

      head, sep, content = chunk.byteslice(2..).partition("\r\n\r\n")
      raise Unparseable, "a multipart part has no blank line after its headers" if sep.empty?

      headers = head.split("\r\n").map { |h| utf8(h) }
      disp = headers.find { |h| h.downcase.start_with?("content-disposition:") }.to_s
      { name: disp[/;\s*name="([^"]*)"/, 1], filename: disp[/;\s*filename="([^"]*)"/, 1], headers: headers, content: content }
    end
  end
end
