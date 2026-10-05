# frozen_string_literal: true

# ai/lib/forge_wire/operations.rb -- the wire operation table (DND-2025).
# Design: ai/docs/outbound-scan-at-the-wire.md -> The operation table.
#
# Domain only: parse the table's text and look operations up. The table is
# data, ai/lib/forge_wire/operations.tsv; `load_default` reads that file
# beside this one. (The proxy, ticket 2, loads the main checkout's copy, so a
# branch cannot widen the table it is judged by; the self-tests load the
# branch copy.)
#
# One row per operation, TAB-separated:
#   forge   github | gitlab
#   method  POST | PUT | PATCH | DELETE, or `graphql` for a mutation field
#   route   a REST path template (`{name}` matches one raw, non-empty path
#           segment; everything else matches literally, case-sensitive), or
#           the mutation's top-level field name
#   class   text   scanned under What is judged
#           ref    moves a branch or merges; forwarded only under a grant
#           plain  carries no free text; scanned all the same
# `#` starts a comment line. A table with no rows, or a malformed row, is a
# TableError naming the line number and never quoting it.

module ForgeWire
  module Operations
    class TableError < StandardError; end

    Op = Struct.new(:forge, :method, :route, :klass, keyword_init: true) do
      def name
        "#{forge} #{method} #{route}"
      end
    end

    FORGES = %w[github gitlab].freeze
    METHODS = %w[POST PUT PATCH DELETE graphql].freeze
    CLASSES = %w[text ref plain].freeze
    GRAPHQL_NAME = /\A[_A-Za-z][_0-9A-Za-z]*\z/.freeze
    SEGMENT = /\A(?:\{[a-z]+\}|[A-Za-z0-9_.~-]+)\z/.freeze
    DEFAULT = File.join(__dir__, "operations.tsv")

    # A parsed table.
    class Table
      def initialize(ops)
        @rest = ops.reject { |o| o.method == "graphql" }
        @graphql = ops.select { |o| o.method == "graphql" }.to_h { |o| [[o.forge, o.route], o] }
      end

      def size
        @rest.size + @graphql.size
      end

      # -> Op or nil. `path` is the raw request path (no query).
      def rest(forge, method, path)
        segs = path.split("/", -1)
        @rest.find do |o|
          o.forge == forge.to_s && o.method == method && match?(o.route.split("/", -1), segs)
        end
      end

      # -> Op or nil.
      def graphql(forge, field)
        @graphql[[forge.to_s, field]]
      end

      private

      def match?(template, segs)
        return false unless template.length == segs.length

        template.zip(segs).all? do |t, s|
          t.start_with?("{") ? !s.empty? : t == s
        end
      end
    end

    module_function

    def load_default
      parse(File.read(DEFAULT), DEFAULT)
    rescue SystemCallError => e
      raise TableError, "the operation table #{DEFAULT} is unreadable (#{e.class.name.split('::').last})"
    end

    def parse(text, origin)
      seen = {}
      ops = text.each_line.with_index(1).filter_map do |raw, n|
        line = raw.chomp
        next nil if line.strip.empty? || line.lstrip.start_with?("#")

        op = row(line.split("\t", -1), origin, n)
        key = [op.forge, op.method, op.route]
        raise TableError, "#{origin} line #{n} repeats the operation on line #{seen[key]}" if seen[key]

        seen[key] = n
        op
      end
      raise TableError, "#{origin} has no rows" if ops.empty?

      Table.new(ops)
    end

    def row(cols, origin, n)
      bad = ->(why) { raise TableError, "#{origin} line #{n} #{why}" }
      bad.call("does not have 4 TAB-separated columns") unless cols.length == 4
      forge, method, route, klass = cols
      bad.call("names a forge that is not github or gitlab") unless FORGES.include?(forge)
      bad.call("names a method that is not POST, PUT, PATCH, DELETE or graphql") unless METHODS.include?(method)
      bad.call("names a class that is not text, ref or plain") unless CLASSES.include?(klass)
      if method == "graphql"
        bad.call("names a mutation that is not a GraphQL name") unless GRAPHQL_NAME.match?(route)
      else
        segs = route.split("/", -1)
        ok = route.start_with?("/") && segs.drop(1).all? { |s| SEGMENT.match?(s) }
        bad.call("has a route that is not /segment/{name}/...") unless ok
      end
      Op.new(forge: forge, method: method, route: route, klass: klass.to_sym)
    end
  end
end
