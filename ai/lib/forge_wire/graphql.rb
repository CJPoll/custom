# frozen_string_literal: true

# ai/lib/forge_wire/graphql.rb -- which operation a GraphQL document selects
# (DND-2025). Design: ai/docs/outbound-scan-at-the-wire.md -> What is judged.
#
# Domain only. A lexer that skips strings, block strings and comments, and a
# reader of the document's top level: each operation's type (query, mutation,
# subscription), its name, and the names of its top-level fields (an alias is
# read through to its field). The fields are the operation names the
# operation table is keyed on.
#
# Anything this reader cannot read is :unreadable, never a guess: a lexer
# error, unbalanced brackets, a fragment spread or inline fragment at an
# operation's root (its fields would hide behind the fragment), no
# operation, two operations without an operationName, or a name that selects
# nothing. The verdict judges :unreadable as a mutation with no known
# operation, so it is refused.
#
# `literal` is true when the document holds any string literal. A target
# named inline (`subjectId: "X"`) cannot be read from variables, so the
# target reader treats such a mutation's target as unknown.

require "strscan"

module ForgeWire
  module GraphQL
    Operation = Struct.new(:type, :name, :fields, :literal, keyword_init: true)

    class Unreadable < StandardError; end

    UNREADABLE = Operation.new(type: :unreadable, name: nil, fields: [], literal: false).freeze
    TYPES = { "query" => :query, "mutation" => :mutation, "subscription" => :subscription }.freeze

    module_function

    # -> Operation. `document` is the request's query string; `name` its
    # operationName (nil when absent).
    def operation(document, name = nil)
      return UNREADABLE unless document.is_a?(String) && (name.nil? || name.is_a?(String))

      tokens, literal = lex(document)
      ops = Reader.new(tokens).definitions
      chosen = name ? ops.select { |o| o.name == name } : ops
      return UNREADABLE unless chosen.length == 1

      chosen.first.literal = literal
      chosen.first
    rescue Unreadable
      UNREADABLE
    end

    PUNCT = /\.\.\.|[!$&()\[\]{}:=@|]/.freeze
    NAME = /[_A-Za-z][_0-9A-Za-z]*/.freeze
    NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.freeze
    IGNORED = /(?:[ \t\r\n,]|﻿|#[^\r\n]*)+/.freeze
    # A string: no raw line break inside; an escape takes the next character.
    STRING = /"(?:[^"\\\r\n]|\\[^\r\n])*"/.freeze
    # A block string: anything up to the first `"""` not escaped as `\"""`.
    BLOCK_STRING = /"""(?:\\"""|(?!""")[\s\S])*"""/.freeze

    # -> [[kind, text], ...], literal?  One pass with StringScanner, so the
    # cost is linear in the document's length.
    def lex(src)
      s = src.dup.force_encoding(Encoding::UTF_8)
      raise Unreadable unless s.valid_encoding?

      sc = StringScanner.new(s)
      tokens = []
      literal = false
      until sc.eos?
        next if sc.skip(IGNORED)

        if sc.check(/"""/)
          raise Unreadable unless sc.skip(BLOCK_STRING)

          tokens << [:string, ""]
          literal = true
        elsif sc.check(/"/)
          raise Unreadable unless sc.skip(STRING)

          tokens << [:string, ""]
          literal = true
        elsif (t = sc.scan(PUNCT))
          tokens << [:punct, t]
        elsif (t = sc.scan(NAME))
          tokens << [:name, t]
        elsif (t = sc.scan(NUMBER))
          tokens << [:number, t]
        else
          raise Unreadable
        end
      end
      [tokens, literal]
    end

    # Reads the top level of a token list.
    class Reader
      CLOSE = { "{" => "}", "(" => ")", "[" => "]" }.freeze

      def initialize(tokens)
        @t = tokens
        @i = 0
      end

      def definitions
        ops = []
        until @i >= @t.length
          op = definition
          ops << op if op
        end
        raise Unreadable if ops.empty?

        ops
      end

      private

      def peek(off = 0)
        @t[@i + off]
      end

      def take
        tok = @t[@i] or raise Unreadable
        @i += 1
        tok
      end

      def punct?(text, off = 0)
        tok = peek(off)
        tok && tok[0] == :punct && tok[1] == text
      end

      def definition
        return Operation.new(type: :query, name: nil, fields: selection_fields) if punct?("{")

        kind, word = take
        raise Unreadable unless kind == :name

        return fragment if word == "fragment"

        type = TYPES[word] or raise Unreadable
        name = peek && peek[0] == :name ? take[1] : nil
        skip_group if punct?("(")
        skip_directives
        Operation.new(type: type, name: name, fields: selection_fields)
      end

      def fragment
        raise Unreadable unless take[0] == :name && take == [:name, "on"] && take[0] == :name

        skip_directives
        raise Unreadable unless punct?("{")

        skip_group
        nil
      end

      # The top-level fields of the selection set at the cursor.
      def selection_fields
        raise Unreadable unless take == [:punct, "{"]

        fields = []
        until punct?("}")
          kind, word = take
          raise Unreadable unless kind == :name # `...`, a literal, or a stray token

          if punct?(":")
            take
            kind, word = take
            raise Unreadable unless kind == :name
          end
          fields << word
          skip_group if punct?("(")
          skip_directives
          skip_group if punct?("{")
        end
        take
        raise Unreadable if fields.empty?

        fields
      end

      def skip_directives
        while punct?("@")
          take
          raise Unreadable unless take[0] == :name

          skip_group if punct?("(")
        end
      end

      # Skips a balanced (), [] or {} group starting at the cursor.
      def skip_group
        stack = [CLOSE.fetch(take[1])]
        until stack.empty?
          kind, text = take
          next unless kind == :punct

          if CLOSE.key?(text)
            stack << CLOSE[text]
          elsif CLOSE.value?(text)
            raise Unreadable unless stack.pop == text
          end
        end
      end
    end
  end
end
