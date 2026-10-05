# frozen_string_literal: true

# ForgeWire::Fields (DND-2025): the text of a write. Every decoded path
# segment, every query key and value, and the body by content type. A field's
# NAME never carries request text (a name that did would print a work value
# in a refusal), so odd JSON keys are named by position.

require "json"
require_relative "helper"
require_relative "../../forge_wire/fields"

F = ForgeWire::Fields
# A JSON \u escape for S, built at run time: an editor that decodes \u escapes
# in source would turn a literal one into a plain S and make these cases vacuous.
ESC_S = "#{92.chr}u0053"

def fields(req)
  F.of(req, F.parse_body(req))
end

def texts(req)
  fields(req).map(&:text)
end

def named(req, name)
  fields(req).select { |f| f.name == name }.map(&:text)
end

# --- path and query ------------------------------------------------------------
r = wire("POST", "/repos/o/r/issues/7/comments?a=1&b=two+words&c=%E2%9C%93")
check("each path segment is a field") { %w[repos o r issues 7 comments].all? { |s| texts(r).include?(s) } }
check("a query value is decoded (+ is a space)") { texts(r).include?("two words") }
check("a query value is UTF-8 decoded") { texts(r).include?("✓") }
check("query keys are fields") { %w[a b c].all? { |k| texts(r).include?(k) } }
check("field names hold no request text") { fields(r).none? { |f| f.name.include?("comments") || f.name.include?("two") } }
enc = wire("POST", "/api/v4/projects/g%2Fp/issues/x%20y", host: GL_HOST)
check("a path segment is decoded") { texts(enc).include?("g/p") && texts(enc).include?("x y") }
check("the raw segment is kept beside the decoded one") { texts(enc).include?("g%2Fp") }
check("a bad percent-escape keeps the raw text") { texts(wire("POST", "/a/%zz")).include?("%zz") }

# --- JSON ----------------------------------------------------------------------
j = wire("POST", "/graphql", body: JSON.generate({ query: "mutation { x }", variables: { input: { body: "line one\nline two", n: 42, ok: true, list: %w[a b] } } }))
check("every JSON string value is a field") { texts(j).include?("line one\nline two") && texts(j).include?("mutation { x }") }
check("JSON numbers are text too") { texts(j).include?("42") }
check("array members are fields") { texts(j).include?("a") && texts(j).include?("b") }
check("JSON keys are fields") { %w[query variables input body n].all? { |k| texts(j).include?(k) } }
check("a JSON field is named by its key path") { named(j, "body.variables.input.body") == ["line one\nline two"] }
check("an array member is named by index") { named(j, "body.variables.input.list[1]") == ["b"] }
escaped = wire("POST", "/x", body: %({"t":"#{ESC_S}YNTH"}))
check("a JSON \\u escape is decoded") { texts(escaped).include?("SYNTH") }
odd = wire("POST", "/x", body: JSON.generate({ "has space and SYNTH-WORK-4242" => "v" }))
check("an odd key is named by position, not by its text") { fields(odd).none? { |f| f.name.include?("SYNTH") } && texts(odd).include?("has space and SYNTH-WORK-4242") }
check("+json media types are JSON") { named(wire("POST", "/x", body: '{"a":"b"}', type: "application/vnd.api+json"), "body.a") == ["b"] }
check("a JSON body that does not parse is refused") do
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: "{nope")) }
end
check("JSON with a charset parameter is JSON") { named(wire("POST", "/x", body: '{"a":"b"}', type: "application/json; charset=utf-8"), "body.a") == ["b"] }
check("deeply nested JSON is refused, not recursed without bound") do
  deep = ("[" * 2000) + ("]" * 2000)
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: deep)) }
end

# --- form ----------------------------------------------------------------------
fm = wire("POST", "/x", body: "title=a+b&body=c%0Ad&flag", type: "application/x-www-form-urlencoded")
check("form values are decoded") { texts(fm).include?("a b") && texts(fm).include?("c\nd") }
check("form keys are fields") { texts(fm).include?("title") && texts(fm).include?("flag") }

# --- multipart -----------------------------------------------------------------
mp_body = "--BND\r\nContent-Disposition: form-data; name=\"notes\"\r\n\r\nrelease text\r\n" \
          "--BND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile text\r\n--BND--\r\n"
mp = wire("POST", "/x", body: mp_body, type: "multipart/form-data; boundary=BND")
check("a multipart part's content is a field") { texts(mp).include?("release text") && texts(mp).include?("file text") }
check("a part's name and filename are fields") { texts(mp).include?("notes") && texts(mp).include?("a.txt") }
check("a quoted boundary works") { texts(wire("POST", "/x", body: mp_body, type: 'multipart/form-data; boundary="BND"')).include?("file text") }
check("multipart with no boundary is refused") do
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: mp_body, type: "multipart/form-data")) }
end
check("multipart with no closing delimiter is refused") do
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: mp_body.sub("--BND--\r\n", ""), type: "multipart/form-data; boundary=BND")) }
end
check("a multipart part with no blank line is refused") do
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: "--BND\r\nX: y\r\n--BND--\r\n", type: "multipart/form-data; boundary=BND")) }
end

# --- anything else -------------------------------------------------------------
raw = wire("POST", "/x", body: "plain bytes", type: "application/octet-stream")
check("an octet-stream body is scanned raw") { texts(raw).include?("plain bytes") }
check("a body with no Content-Type is scanned raw") do
  r2 = ForgeWire::Request.parse(http("POST /x HTTP/1.1", "Host: #{GH_API}", "Content-Length: 3", body: "abc"), host: GH_API, max_body: 99)
  texts(r2).include?("abc")
end
sneaky = wire("POST", "/x", body: %({"t":"#{ESC_S}YNTH"}), type: "text/plain")
check("a raw body that parses as JSON is also read as JSON") { texts(sneaky).include?("SYNTH") }
check("an empty body has no body fields") { fields(wire("POST", "/x")).none? { |f| f.name.start_with?("body") } }

# --- every body is also read raw ----------------------------------------------
# Declared JSON with a repeated key is refused (below); a raw body is still
# scanned whole, so the first of two keys cannot hide there either.
dup = wire("POST", "/x", body: '{"body":"first SYNTH","body":"second"}', type: "text/plain")
check("a JSON body that repeats a top-level key (query) is refused") do
  raises?(ForgeWire::Unparseable, "repeats a key") do
    F.parse_body(wire("POST", "/graphql", body: '{"query":"mutation{x}","query":"query{y}"}'))
  end
end
check("a JSON body that repeats a nested key is refused") do
  raises?(ForgeWire::Unparseable, "repeats a key") do
    F.parse_body(wire("POST", "/graphql", body: '{"variables":{"input":{"subjectId":"A","subjectId":"B"}}}'))
  end
end
check("a raw body that is JSON with a repeated target_project_id is refused when read for params") do
  r = wire("POST", "/x", body: '{"target_project_id":1,"target_project_id":2}', type: "text/plain")
  raises?(ForgeWire::Unparseable, "repeats a key") { F.param_values(r, F.parse_body(r), "target_project_id") }
end
check("the same key in two different objects is not a repeat") do
  F.parse_body(wire("POST", "/x", body: '{"a":{"id":"1"},"b":{"id":"2"}}')).kind == :json
end
check("the first of two duplicate JSON keys is still scanned") { texts(dup).any? { |t| t.include?("first SYNTH") } }
dup_esc = wire("POST", "/x", body: %({"body":"#{ESC_S}YNTH-first","body":"second"}), type: "text/plain")
check("an escaped value under a duplicate key is decoded and scanned") { texts(dup_esc).include?("SYNTH-first") }
form_json = wire("POST", "/x", body: %({"t":"#{ESC_S}YNTH"}), type: "application/x-www-form-urlencoded")
check("JSON sent with a form Content-Type is read as JSON too") { texts(form_json).include?("SYNTH") }
check("the raw body is a field whatever the type") { named(j, "body.raw").length == 1 }
check("a JSON string literal anywhere in a raw body is decoded") do
  texts(wire("POST", "/x", body: %(prefix "#{ESC_S}YNTH" suffix), type: "text/plain")).include?("SYNTH")
end

# --- multipart edge cases --------------------------------------------------------
b64 = "--BND\r\nContent-Disposition: form-data; name=\"n\"\r\nContent-Transfer-Encoding: base64\r\n\r\nU1lOVEg=\r\n--BND--\r\n"
check("a multipart part with a base64 transfer encoding is refused") do
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: b64, type: "multipart/form-data; boundary=BND")) }
end
check("a multipart part with an 8bit transfer encoding is read") do
  ok = b64.sub("base64", "8bit").sub("U1lOVEg=", "plain")
  texts(wire("POST", "/x", body: ok, type: "multipart/form-data; boundary=BND")).include?("plain")
end
check("two boundary parameters are refused") do
  raises?(ForgeWire::Unparseable) { F.parse_body(wire("POST", "/x", body: mp_body, type: "multipart/form-data; boundary=BND; boundary=X")) }
end

# --- GitLab's target_project_id, wherever it is sent ---------------------------
check("target_project_id is read from the query") { F.param_values(wire("POST", "/x?target_project_id=7&a=1"), F.parse_body(wire("POST", "/x?target_project_id=7&a=1")), "target_project_id") == ["7"] }
check("target_project_id is read from a multipart part") do
  mp_tp = "--BND\r\nContent-Disposition: form-data; name=\"target_project_id\"\r\n\r\n9\r\n--BND--\r\n"
  r = wire("POST", "/x", body: mp_tp, type: "multipart/form-data; boundary=BND")
  F.param_values(r, F.parse_body(r), "target_project_id") == ["9"]
end
check("target_project_id is read from a raw body that is JSON") do
  r = wire("POST", "/x", body: '{"target_project_id":5}', type: "text/plain")
  F.param_values(r, F.parse_body(r), "target_project_id") == ["5"]
end

finish("forge-wire fields")
