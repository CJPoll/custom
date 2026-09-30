# frozen_string_literal: true

# Shared fixtures for the ticket-reclassify suites (DND-1056). Synthetic ids
# and text only; nothing here reaches a network.

require "json"

$failures = []
$checks = 0

def section(name)
  puts "== #{name}"
end

def check(desc)
  $checks += 1
  ok = begin
    yield
  rescue StandardError => e
    $failures << "#{desc} (raised #{e.class}: #{e.message})"
    puts "FAIL #{desc} (raised #{e.class}: #{e.message})"
    return
  end
  if ok
    puts "ok   #{desc}"
  else
    $failures << desc
    puts "FAIL #{desc}"
  end
end

def finish(name)
  puts
  puts "#{name}: #{$checks - $failures.size} passed, #{$failures.size} failed"
  exit($failures.empty? ? 0 : 1)
end

PREFIX_TEXT = "Jev classification: "
VALUES = { "kind" => "Bug", "severity" => "MEDIUM", "security" => "none" }.freeze
VERSIONS = { "kind" => "ticket-kind-v1", "severity" => "ticket-severity-v1", "security" => "ticket-security-v1" }.freeze
MODEL = "jev-1.13.0"
NOW_ON = { "model" => MODEL, "versions" => VERSIONS, "modes" => { "kind" => "on", "severity" => "on", "security" => "on" } }.freeze

def page_id(number)
  format("a0000000-0000-0000-0000-%012d", number)
end

# ticket(...) -> a ticket as the plan's manager builds it from a tracker row.
def ticket(number: 7, status: "Todo", kind: "Bug", severity: "MEDIUM", security: "none", project: "harness",
           title: "Synthetic ticket title", body_read: true, lines: ["Body text."])
  { "ref" => "DND-#{number}", "page_id" => page_id(number), "title" => title, "status" => status, "kind" => kind,
    "severity" => severity, "security" => security, "project" => project, "body_read" => body_read, "blocks_text" => lines }
end

# line(values, mode) -> a provenance line as DND-991 writes it, every
# property in `mode` at the given model and versions.
def line(values, mode, model: MODEL, versions: VERSIONS, reason: nil)
  prop = lambda do |v|
    { "value" => v, "source" => mode == "on" ? "jev" : "filer", "judged" => mode == "off" ? nil : v,
      "confidence" => mode == "off" ? nil : 0.95, "accepted" => mode != "off", "mode" => mode,
      "reason" => reason || (mode == "off" ? "mode_off" : nil) }
  end
  doc = { "kind" => prop.call(values["kind"]), "severity" => prop.call(values["severity"]),
          "security" => prop.call(values["security"]), "model" => model, "versions" => versions }
  PREFIX_TEXT + JSON.generate(doc)
end

# answer(decided, mode, reason:) -> a 200 body as the endpoint answers it.
def answer(decided, mode, reason: nil)
  props = decided.to_h do |k, v|
    r = reason || (mode == "off" ? "mode_off" : nil)
    [k, { "decided" => v, "source" => mode == "on" && reason.nil? ? "jev" : "filer",
          "judged" => mode == "off" ? nil : { "value" => v, "confidence" => 0.95 },
          "accepted" => mode == "on" && reason.nil?, "reason" => r, "mode" => mode }]
  end
  JSON.generate({ "status" => "judged", "properties" => props, "would_decide" => nil,
                  "provenance_line" => line(decided, mode, reason: reason) })
end

def reply(body, status: 200)
  { curl_rc: 0, status: status, body: body }
end
