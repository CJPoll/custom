# frozen_string_literal: true

# ai/lib/forge_wire/verdict.rb -- forward or refuse one request (DND-2025).
# Design: ai/docs/outbound-scan-at-the-wire.md -> What is judged, The
# operation table, Fail-closed behaviour.
#
# Domain only. Everything the judge needs arrives as a value: the parsed
# request, the forge, the operation table, the scanner's state (its patterns,
# or why it has none), and a visibility map the proxy filled upstream. Nothing
# here reads a socket, a file or the environment.
#
# The order of judgement, for a request that is not a read:
#   1. a write to a host outside the forge's list         REFUSED, exit 3
#   2. a body that does not parse, a method override     REFUSED, exit 3
#   3. an operation the table does not name               REFUSED, exit 3
#   4. a `ref` operation (no grant: merge grants are      REFUSED, exit 3
#      build step 5, issued by the merge guards)
#   5. every target reads `private`                       forwarded, unscanned
#   6. a GitLab target whose visibility is unreadable     REFUSED, exit 3
#   7. the scanner WAIVED                                 forwarded, WAIVED
#      the scanner COULD NOT MEASURE                      REFUSED, exit 3, except
#        the overlay is ABSENT and the machine unmarked   forwarded, WARNING
#   8. any field line matches a pattern                   REFUSED, exit 1 (HITS)
#   9. otherwise                                          forwarded, CLEAN
#
# A read is GET or HEAD with an empty body and no method override, or a
# GraphQL query. A GraphQL document this judge cannot read is a mutation with
# no known operation (step 3). The visibility rules are the argv scan's
# (ai/lib/outbound-text-scan.sh): an unknown target is public; GitHub reads an
# unreadable or unresolved visibility as public; GitLab refuses an unreadable
# one; GitLab `internal` is public. A target missing from the map is
# unreadable: a lookup that did not happen never reads as private.
#
# What a refusal prints: the operation's table name, field names and pattern
# labels. Never a matched value, never the raw path (a path is scanned text),
# and a field name that itself matches a pattern is redacted.

require_relative "request"
require_relative "fields"
require_relative "graphql"
require_relative "target"
require_relative "operations"
require_relative "../outbound_scan"

module ForgeWire
  # The scanner's state for one invocation.
  Scan = Struct.new(:state, :patterns, :reason, :unmarked_absent, keyword_init: true) do
    def self.measured(patterns)
      new(state: :measured, patterns: patterns)
    end

    # `unmarked_absent`: the overlay is ABSENT and this machine is not marked
    # as one that holds it (ai/lib/outbound-text-scan.sh -> COULD NOT MEASURE).
    def self.unmeasured(reason, unmarked_absent: false)
      new(state: :unmeasured, patterns: [], reason: reason, unmarked_absent: unmarked_absent)
    end

    def self.waived(reason)
      new(state: :waived, patterns: [], reason: reason)
    end
  end

  # action: :forward | :refuse. exit_code: 0 forward, 1 HITS, 3 any other
  # refusal. state names the rule that decided. lines: what the wrapper prints.
  Verdict = Struct.new(:action, :state, :exit_code, :lines, :hits, :operations, :targets, keyword_init: true) do
    def forward?
      action == :forward
    end
  end

  module Judge
    READ_METHODS = %w[GET HEAD].freeze
    PREFIX = "forge-wire"
    GRANT_FIX = "Fix: merge and move refs only through `integration-gate` then `locked-merge`; the merge guard " \
                "issues the grant this request needs (ai/docs/outbound-scan-at-the-wire.md -> Merges and ref moves at the wire)."
    TABLE_FIX = "Fix: if the harness needs this operation, capture the CLI making it " \
                "(ai/lib/test/forge-wire/capture/capture --help) and add its row to ai/lib/forge_wire/operations.tsv on main."
    DEFECT_FIX = "Fix: this is a defect in the CLI or in forge-wire, not in your text; report it with the CLI version " \
                 "and the command shape (never the text), and do not retry through another route."

    module_function

    # -> Verdict for one request.
    def judge(req, forge:, table:, scan:, visibility:)
      write = req.header("x-http-method-override") || req.header("x-http-method") || req.header("x-method-override")
      return refuse(:method_override, "#{describe(req, scan)} carries a method-override header", DEFECT_FIX) if write

      body = Fields.parse_body(req)
      op = graphql_op(forge, req, body)
      return read if read?(req, op)
      return refuse(:off_forge, "a write to #{req.host}, which is not a #{forge} API host", DEFECT_FIX) unless Target.hosts(forge).include?(req.host)

      ops = operations(forge, req, op, table)
      return refuse(:unknown_operation, "#{describe(req, scan)} is not an operation in the table", TABLE_FIX) if ops.nil?

      if (ref = ops.find { |o| o.klass == :ref })
        return refuse(:ref_without_grant, "#{ref.name} moves a branch or merges, and no grant covers it", GRANT_FIX, ops: ops)
      end

      targets = Target.of(forge, req, body, op)
      judge_text(req, forge, body, ops, targets, scan, visibility)
    rescue Unparseable => e
      unparseable(e.message)
    end

    # The verdict for bytes Request.parse refused.
    def unparseable(message)
      refuse(:unparseable, "the request does not parse (#{message})", DEFECT_FIX)
    end

    def graphql_op(forge, req, body)
      return nil unless Target.graphql?(forge, req)

      doc = graphql_document(req, body)
      GraphQL.operation(doc["query"], doc["operationName"])
    end

    def graphql_document(req, body)
      if READ_METHODS.include?(req.method) && body.kind == :none
        Fields.form_pairs(req.query.to_s).to_h
      elsif body.kind == :json && body.value.is_a?(Hash)
        body.value
      else
        {}
      end
    end

    def read?(req, op)
      return op.type == :query if op

      READ_METHODS.include?(req.method) && req.body.empty?
    end

    # -> [Op] or nil when any operation is not in the table.
    def operations(forge, req, op, table)
      if op
        return nil if op.type == :unreadable || op.fields.empty?

        ops = op.fields.map { |f| table.graphql(forge, f) }
        ops.include?(nil) ? nil : ops.uniq
      else
        found = table.rest(forge, req.method, req.path)
        found && [found]
      end
    end

    def judge_text(req, forge, body, ops, targets, scan, visibility)
      seen = targets.map { |t| [t, look(forge, t, visibility)] }
      if seen.all? { |_, v| v == :private }
        return forward(:private, "#{ops_names(ops)} to a private target: not scanned", ops, targets)
      end
      blind = seen.find { |_, v| v == :could_not_look }
      if blind
        return refuse(:could_not_look, "COULD NOT LOOK: the visibility of #{blind[0].key} is unreadable, so the text cannot be judged",
                      "Fix: check that the token can read that project (glab-athena api projects/<id>), then retry.",
                      ops: ops, targets: targets)
      end

      case scan.state
      when :waived
        return forward(:waived, "WAIVED - NOT SCANNED (reason: #{scan.reason}); this is not a clean result", ops, targets)
      when :unmeasured
        if scan.unmarked_absent
          return forward(:unscanned, "WARNING: the text went out UNSCANNED: #{scan.reason}, and this machine is not " \
                                     "marked as one that holds the overlay", ops, targets)
        end
        return refuse(:unmeasured, "COULD NOT MEASURE: #{scan.reason}", OutboundScan.unmeasured_fix(scan.reason),
                      ops: ops, targets: targets)
      end

      hits = scan_fields(req, body, scan.patterns)
      return forward(:clean, "#{ops_names(ops)}: CLEAN", ops, targets) if hits.empty?

      lines = ["#{PREFIX}: REFUSED (HITS): #{ops_names(ops)} to a target that is not private: #{hits.length} match(es) " \
               "of work-domain patterns. The matched text is never printed."]
      lines += hits.map { |h| "  #{render(h, scan.patterns)} label=#{h.label}" }
      lines << OutboundScan::HIT_FIX
      Verdict.new(action: :refuse, state: :hits, exit_code: OutboundScan::EXIT[:hits], lines: lines, hits: hits,
                  operations: ops, targets: targets)
    end

    # -> :private | :public | :could_not_look
    def look(forge, target, visibility)
      return :public if target.kind == :unknown

      v = visibility.fetch(target.key, :unreadable)
      return :private if v == "private"
      return :public if %w[public internal].include?(v)

      forge == :gitlab && v != :unresolved ? :could_not_look : :public
    end

    def scan_fields(req, body, patterns)
      Fields.of(req, body).flat_map do |f|
        f.text.each_line.with_index(1).flat_map do |line, n|
          loc = OutboundScan::Location.new(kind: :field, field: f.name, line: n)
          OutboundScan.scan_line(patterns, loc, line)
        end
      end
    end

    def render(hit, patterns)
      loc = hit.location
      name = OutboundScan.labels_matching(patterns, loc.field.to_s).empty? ? loc.field : "<field name redacted: it matches a pattern>"
      OutboundScan.render_location(OutboundScan::Location.new(kind: :field, field: name, line: loc.line), patterns)
    end

    # The method and the path with every segment that could carry text shown
    # only when patterns are known and none matches it.
    def describe(req, scan)
      segs = req.path.split("/", -1).drop(1).map do |s|
        safe = scan.state == :measured && OutboundScan.labels_matching(scan.patterns, Fields.pct_decode(s)).empty? &&
               OutboundScan.labels_matching(scan.patterns, s).empty?
        safe ? s : "<segment>"
      end
      "#{req.method} /#{segs.join('/')}"
    rescue OutboundScan::Unmeasurable
      "#{req.method} <path not shown>"
    end

    def ops_names(ops)
      ops.map(&:name).join(", ")
    end

    def read
      Verdict.new(action: :forward, state: :read, exit_code: 0, lines: [], hits: [], operations: [], targets: [])
    end

    def forward(state, message, ops, targets)
      Verdict.new(action: :forward, state: state, exit_code: 0, lines: ["#{PREFIX}: #{message}"], hits: [],
                  operations: ops, targets: targets)
    end

    def refuse(state, message, fix, ops: [], targets: [])
      Verdict.new(action: :refuse, state: state, exit_code: OutboundScan::EXIT[:unmeasured],
                  lines: ["#{PREFIX}: REFUSED: #{message}.", fix], hits: [], operations: ops, targets: targets)
    end
  end
end
