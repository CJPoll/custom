# frozen_string_literal: true

# A stand-in for a CLI that emits telemetry in-process (harness-gate,
# critic-review, mark-in-progress): it defines its own top-level main, usage
# and parse_cli, then loads the writer and resolves a unit from a branch. It
# prints what its own helpers return afterwards, and which of lead-time's
# classes the load brought in. telemetry_test.rb runs it in a fresh process
# (DND-1488). ARGV[0]: the path to ai/lib/athena_telemetry.rb.

require "json"

def main(_argv = [])
  "caller-main"
end

def usage
  "caller-usage"
end

def parse_cli(_argv = [])
  "caller-parse_cli"
end

require ARGV.fetch(0)

parser = AthenaTelemetry::TicketRefs.parser
puts JSON.generate(
  "parser" => !parser.nil?,
  "ref" => parser&.call("dnd-1463-receipt-base"),
  "main" => main([]),
  "usage" => usage,
  "parse_cli" => parse_cli([]),
  # The modules ai/bin/lead-time itself defines, at the top level or under a
  # wrapping module (a `load(path, Module.new)` names them
  # "#<Module:0x...>::LeadTime"). NextMissionNotion is not one:
  # ai/lib/dispatch_trackers.rb, which the writer needs for the DND prefix,
  # requires it.
  "lead_time_loaded" => ObjectSpace.each_object(Module).filter_map do |m|
    short = m.name.to_s.split("::").last
    m.name if %w[LeadTime ProbeFailures GitHubForge GitLabForge NotionStart TicketStarts].include?(short)
  end.sort,
)
