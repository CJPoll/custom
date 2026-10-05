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
# The order of judgement:
#   1. a method override (an X-HTTP-Method-Override-style header, or a
#      `_method` parameter anywhere Fields.param_values reads one: the
#      query, a form, JSON or multipart body, a raw JSON body)
#                                                         REFUSED, exit 3
#   2. a body that does not parse                         REFUSED, exit 3
#   3. a read                                             forwarded, unjudged
#   4. a write to a host outside the forge's list         REFUSED, exit 3
#   5. a GraphQL document this judge cannot read          REFUSED, exit 3
#   6. an operation the table does not name               REFUSED, exit 3
#   7. a `ref` operation (no grant: merge grants are      REFUSED, exit 3
#      build step 5, issued by the merge guards)
#   8. every target reads `private`                       forwarded, unscanned
#   9. a GitLab target whose visibility is unreadable     REFUSED, exit 3
#  10. the scanner WAIVED                                 forwarded, WAIVED
#      the scanner COULD NOT MEASURE (a pattern that      REFUSED, exit 3, except
#      times out mid-scan included)
#        the overlay is ABSENT and the machine unmarked   forwarded, WARNING
#  11. any field line matches a pattern                   REFUSED, exit 1 (HITS)
#  12. otherwise                                          forwarded, CLEAN
#
# A read is GET or HEAD with an empty body to a path that is not
# GraphQL-shaped (its last segment does not start with `graphql`, unless it is
# the forge's GraphQL endpoint), or a GraphQL query. The visibility rules are
# the argv scan's (ai/lib/outbound-text-scan.sh): an unknown target is public;
# GitHub reads an unreadable or unresolved visibility as public; GitLab
# refuses an unreadable one; GitLab `internal` is public. A target missing
# from the map is unreadable: a lookup that did not happen never reads as
# private.
#
# What a refusal prints: the operation's table name or GraphQL field names,
# field names, pattern labels, and a target's kind (with its id when numeric).
# Never a matched value, never a raw path or project path (both are scanned
# text), and a field name, path segment or GraphQL field that itself matches
# a pattern is redacted.

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
                "(ai/bin/forge-wire-capture --help) and add its row to ai/lib/forge_wire/operations.tsv on main."
    DEFECT_FIX = "Fix: this is a defect in the CLI or in forge-wire, not in your text; report it with the CLI version " \
                 "and the command shape (never the text), and do not retry through another route."

    module_function

    # -> Verdict for one request.
    def judge(req, forge:, table:, scan:, visibility:)
      body = Fields.parse_body(req)
      if override?(req, body)
        return refuse(:method_override, "#{describe(req, scan)} carries a method override", DEFECT_FIX)
      end

      op = graphql_op(forge, req, body)
      return read if read?(forge, req, op)
      return refuse(:off_forge, "a write to #{req.host}, which is not a #{forge} API host", DEFECT_FIX) unless Target.hosts(forge).include?(req.host)
      return refuse(:unreadable_graphql, "a GraphQL request whose operation this judge cannot read", DEFECT_FIX) if op&.type == :unreadable

      ops = operations(forge, req, op, table)
      return refuse(:unknown_operation, "#{describe_op(req, op, scan)} is not an operation in the table", TABLE_FIX) if ops.nil?

      if (ref = ops.find { |o| o.klass == :ref })
        return refuse(:ref_without_grant, "#{ref.name} moves a branch or merges, and no grant covers it", GRANT_FIX, ops: ops)
      end

      targets = Target.of(forge, req, body, op)
      judge_text(req, forge, body, ops, targets, scan, visibility)
    rescue Unparseable => e
      unparseable(e.message)
    rescue OutboundScan::Unmeasurable => e
      refuse(:unmeasured, "COULD NOT MEASURE: #{e.message}", OutboundScan.unmeasured_fix(e.message))
    end

    OVERRIDE_HEADERS = %w[x-http-method-override x-http-method x-method-override].freeze

    def override?(req, body)
      return true if OVERRIDE_HEADERS.any? { |h| req.header(h) }

      # Wherever a framework reads params from (Rack::MethodOverride reads the
      # parsed POST body, urlencoded or multipart), the same reader as
      # target_project_id: query, form, JSON, multipart, raw JSON.
      !Fields.param_values(req, body, "_method").empty?
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

    def read?(forge, req, op)
      return op.type == :query if op
      return false if graphql_shaped?(req.path) # not the endpoint, so not judged as GraphQL either

      READ_METHODS.include?(req.method) && req.body.empty?
    end

    def graphql_shaped?(path)
      path.split("/").last.to_s.downcase.start_with?("graphql")
    end

    # -> [Op] or nil when any operation is not in the table.
    def operations(forge, req, op, table)
      if op
        return nil if op.fields.empty?

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
        return refuse(:could_not_look, "COULD NOT LOOK: the visibility of the #{target_label(blind[0])} is unreadable, " \
                                       "so the text cannot be judged",
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

    # A target as a refusal may print it: its kind, and its id only when the
    # id is numeric. A path (owner/repo, group/project) is scanned text.
    def target_label(target)
      _forge, kind, id = target.key.split(":", 3)
      id.to_s.match?(/\A[0-9]+\z/) ? "#{kind} #{id}" : kind.tr("_", " ")
    end

    # An unknown operation: the GraphQL field names (each redacted when it
    # matches a pattern), or the REST method and path.
    def describe_op(req, op, scan)
      return describe(req, scan) unless op

      names = op.fields.map { |f| safe_text?(f, scan) ? f : "<field>" }
      "GraphQL #{op.type} #{names.join(', ')}"
    end

    def safe_text?(text, scan)
      scan.state == :measured && OutboundScan.labels_matching(scan.patterns, text).empty?
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
