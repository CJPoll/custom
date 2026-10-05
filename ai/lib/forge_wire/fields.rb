# frozen_string_literal: true

# ai/lib/forge_wire/fields.rb -- the text of a write (DND-2025).
# Design: ai/docs/outbound-scan-at-the-wire.md -> What is judged.
#
# Domain only. Three jobs:
#   parse_body    the body by Content-Type: JSON (application/json,
#                 */*+json), form-urlencoded, multipart/form-data, or raw
#                 bytes. A body declared JSON or multipart that does not
#                 parse, or JSON that repeats a key in one object, is Unparseable (refused): a body the judge cannot read
#                 is never read as clean. A multipart part with a transfer
#                 encoding other than 7bit, 8bit or binary is refused too: its
#                 text would be scanned still encoded.
#   of            every piece of text the write carries, as named fields: each
#                 path segment (raw and decoded), each query key and value, the
#                 typed body's keys, strings and numbers, and, for every body
#                 whatever its type, the raw bytes plus every JSON string
#                 literal in them, decoded. So a duplicate JSON key (the parser
#                 keeps the last), JSON sent under another Content-Type, or a
#                 \u escape cannot hide text from the scan.
#   param_values  a named parameter wherever a forge reads parameters from:
#                 the query, a form body, a JSON body's top level, a
#                 multipart part, or a raw body that parses as a JSON object
#                 (GitLab's API merges them all into one params hash).
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

    # JSON.parse keeps the last of two equal keys in one object; a forge's
    # parser may keep the first. Where the judge reads a decision from the body
    # (query, operationName, variables, an id, target_project_id, _method), two
    # readings of one body are the duplicate-header ambiguity again, so any
    # repeat anywhere is refused, the same rule as a repeated framing header.
    # The json gem refuses with `allow_duplicate_key: false`. A gem too old to
    # know that option would ignore it and parse last-wins, so this file checks
    # at load that the option bites, and refuses to load otherwise.
    DUP_KEY = /duplicate key/i.freeze
    begin
      JSON.parse('{"a":1,"a":2}', allow_duplicate_key: false)
      raise LoadError, "forge_wire/fields.rb: json #{JSON::VERSION} parses a repeated key instead of refusing it. " \
                       "Fix: run with a json gem that supports allow_duplicate_key (Ruby 3.4's stdlib json does)."
    rescue JSON::ParserError
      nil
    end

    PLAIN_KEY = /\A[A-Za-z0-9_]{1,40}\z/.freeze
    # A JSON string literal: no raw control character, only JSON's escapes.
    JSON_STRING = /"(?:[^"\\\x00-\x1f]|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*"/.freeze
    PLAIN_CTE = %w[7bit 8bit binary].freeze

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

    # JSON text -> value. A repeated key is Unparseable; anything else that
    # does not parse raises JSON::ParserError (or NestingError) to the caller.
    def strict_json(bytes)
      JSON.parse(utf8(bytes), max_nesting: JSON_MAX_NESTING, allow_duplicate_key: false)
    rescue JSON::ParserError => e
      raise Unparseable, "the JSON body repeats a key" if DUP_KEY.match?(e.message) && !e.is_a?(JSON::NestingError)

      raise
    end

    def json(bytes)
      strict_json(bytes)
    rescue JSON::ParserError, JSON::NestingError, EncodingError
      raise Unparseable, "the JSON body does not parse"
    end

    # The value or nil when the bytes are not JSON: a raw body is only maybe
    # JSON. JSON that repeats a key is still Unparseable.
    def maybe_json(bytes)
      strict_json(bytes)
    rescue JSON::ParserError, JSON::NestingError, EncodingError
      nil
    end

    # -> [Field]
    def of(req, body)
      out = []
      path_fields(req.path, out)
      query_fields(req.query, out)
      body_fields(body, out)
      raw_fields(req.body, "body.raw", out) unless req.body.empty?
      out
    end

    # -> [String] every value of parameter `name`, from every place a forge
    # reads parameters. A non-scalar JSON value is returned as its JSON text,
    # so a caller expecting an id sees something that is not one.
    def param_values(req, body, name)
      vals = form_pairs(req.query.to_s).select { |k, _| k == name }.map { |_, v| v.to_s }
      case body.kind
      when :form then vals += body.value.select { |k, _| k == name }.map { |_, v| v.to_s }
      when :json then vals += json_param(body.value, name)
      when :raw then vals += json_param(maybe_json(body.value), name)
      when :multipart
        vals += body.value.select { |p| p[:name] == name }.map { |p| utf8(p[:content]) }
      end
      vals
    end

    def json_param(value, name)
      return [] unless value.is_a?(Hash) && value.key?(name)

      v = value[name]
      [v.is_a?(String) || v.is_a?(Numeric) ? v.to_s : JSON.generate(v)]
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
      end
    end

    # The bytes as text, and every JSON string literal in them, decoded.
    def raw_fields(bytes, name, out)
      text = utf8(bytes)
      out << Field.new(name: name, text: text)
      text.scan(JSON_STRING).each_with_index do |lit, i|
        decoded = begin
          JSON.parse("[#{lit}]").first
        rescue JSON::ParserError, EncodingError
          next
        end
        out << Field.new(name: "#{name}.string[#{i}]", text: decoded) if decoded != lit[1..-2]
      end
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
      found = content_type.to_s.scan(/;\s*boundary=(?:"([^"]{1,70})"|([^\s;"]{1,70}))/i)
      raise Unparseable, "multipart/form-data has no boundary" if found.empty?
      raise Unparseable, "multipart/form-data names its boundary more than once" if found.length > 1

      found.first.compact.first
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
      cte = headers.find { |h| h.downcase.start_with?("content-transfer-encoding:") }
      if cte && !PLAIN_CTE.include?(cte.split(":", 2).last.strip.downcase)
        raise Unparseable, "a multipart part has a transfer encoding other than 7bit, 8bit or binary"
      end

      disp = headers.find { |h| h.downcase.start_with?("content-disposition:") }.to_s
      { name: disp[/;\s*name="([^"]*)"/, 1], filename: disp[/;\s*filename="([^"]*)"/, 1], headers: headers, content: content }
    end
  end
end
