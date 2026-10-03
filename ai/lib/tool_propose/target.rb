# frozen_string_literal: true

require "json"

# ToolPropose::Target -- the pure domain of ai/bin/tool-propose's target
# selection (DND-176). A target is a set of committed harness-eval `bin-stdin`
# fixtures, read at origin/main's sha (never the working tree), that name ONE
# new tool and include at least one `expect=fires` and one `expect=clean` case.
# The pair is what defeats a no-op tool (it cannot fire) and an always-deny
# tool (it cannot stay clean).
#
# Pure: no IO, no git. The adapter reads the fixture list, each meta and input
# at the sha, and whether ai/bin/<guard> exists there, and passes the facts in.
# Results are [:ok, value] or [:error, reason]; the manager prints the reason
# as `REJECTED: target: <reason>` and the Fix: line ToolPropose::Label.fix_for
# names.
module ToolPropose
  module Target
    # harness-eval's own patterns (ai/bin/harness-eval, DND-1427); the domain
    # test asserts the two copies are identical.
    GUARD_NAME_RE = /\A[a-z0-9][a-z0-9-]{1,62}\z/
    INPUT_NAME_RE = /\A(?!\.\.?\z)[A-Za-z0-9._-]+\z/
    # A --case value: a fixture directory name or a prefix of one. Never a path.
    CASE_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    EXPECTS = %w[fires clean].freeze
    MODE = "bin-stdin"

    module_function

    # harness-eval's parse_meta, on text.
    def parse_meta(text)
      text.to_s.each_line.with_object({}) do |line, meta|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        k, _, v = line.partition("=")
        meta[k.strip] = v.strip
      end
    end

    # prefixes: the --case values. names: the fixture directory names at sha.
    # -> [:ok, [name, ...]] in --case order, or [:error, reason].
    def resolve(prefixes, names, sha:)
      return [:error, "no --case given; pass at least one fires and one clean bin-stdin fixture"] if prefixes.empty?

      picked = []
      prefixes.each do |prefix|
        return [:error, "a --case value is empty"] if prefix.to_s.empty?
        return [:error, "bad case #{prefix.inspect}: a fixture name or prefix, not a path"] unless CASE_RE.match?(prefix)

        hit = names.include?(prefix) ? [prefix] : names.select { |n| n.start_with?(prefix) }
        if hit.empty?
          return [:error, "case #{prefix} matches no fixture under ai/eval/fixtures (not on origin/main at #{sha}); " \
                          "a target is committed on origin/main before a run"]
        end
        if hit.size > 1
          return [:error, "case #{prefix} matches several fixtures (#{hit.sort.join(', ')}); pass a longer prefix"]
        end
        return [:error, "fixture #{hit.first} is named twice"] if picked.include?(hit.first)

        picked << hit.first
      end
      [:ok, picked]
    end

    # metas: [{ name:, meta: Hash, input: String or nil }, ...], in --case order.
    # existing: { bin: bool, self_test: bool } for ai/bin/<guard> and its
    # ai/test/tool-propose/<guard>/self-test.sh at the sha. A missing fact is
    # an error, never read as "absent".
    # -> [:ok, { guard:, cases: [{ name:, regression:, expect:, args:, input: }] }]
    def validate(metas, existing:)
      return [:error, "no target fixtures"] if metas.empty?

      cases = []
      metas.each do |m|
        c, why = one_case(m)
        return [:error, why] if why

        cases << c
      end
      guards = metas.map { |m| m[:meta]["guard"] }.uniq
      return [:error, "the targets name #{guards.size} tools (#{guards.join(', ')}); one tool per run"] if guards.size > 1

      expects = cases.map { |c| c[:expect] }
      return [:error, "the target set needs >=1 clean case (only fires given)"] unless expects.include?("clean")
      return [:error, "the target set needs >=1 fires case (only clean given)"] unless expects.include?("fires")

      guard = guards.first
      unless existing.key?(:bin) && existing.key?(:self_test)
        return [:error, "no existence facts were gathered for ai/bin/#{guard}; cannot tell it is new"]
      end
      if existing[:bin] || existing[:self_test]
        return [:error, "ai/bin/#{guard} (or its tool-propose self-test) already exists at the sha; new tools only, " \
                        "tool-propose never replaces a tool"]
      end

      [:ok, { guard: guard, cases: cases }]
    end

    # -> [case, nil] or [nil, reason]
    def one_case(entry)
      name = entry[:name]
      meta = entry[:meta] || {}
      return [nil, "#{name}: mode is #{meta['mode'].inspect}, not #{MODE}"] unless meta["mode"] == MODE

      guard = meta["guard"].to_s
      return [nil, "#{name}: bad guard name #{guard.inspect}"] unless GUARD_NAME_RE.match?(guard)
      return [nil, "#{name}: bad expect #{meta['expect'].inspect} (fires or clean)"] unless EXPECTS.include?(meta["expect"])

      input = meta["input"].to_s
      return [nil, "#{name}: bad input name #{input.inspect}"] unless INPUT_NAME_RE.match?(input)
      return [nil, "#{name}: input #{input} is missing at the sha"] unless entry[:input].is_a?(String)

      args, why = parse_args(meta["args"])
      return [nil, "#{name}: #{why}"] if why

      [{ name: name, regression: meta["regression"].to_s, expect: meta["expect"], args: args, input: entry[:input] }, nil]
    end

    def parse_args(raw)
      return [[], nil] if raw.nil? || raw.empty?

      args = JSON.parse(raw)
      return [nil, "bad args: not a JSON array of strings: #{raw}"] unless args.is_a?(Array) && args.all?(String)

      [args, nil]
    rescue JSON::ParserError
      [nil, "bad args: not JSON: #{raw}"]
    end
  end
end
