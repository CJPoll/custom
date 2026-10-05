# frozen_string_literal: true

# ForgeWire::Judge (DND-2025): forward or refuse one request, on hand-built
# requests. Every row of the design's Fail-closed behaviour table that the
# Domain decides is a case here; the captured CLI traffic is fixtures_test.rb.

require "json"
require_relative "helper"
require_relative "../../forge_wire/verdict"

J = ForgeWire::Judge
PATTERNS = OutboundScan.parse_patterns("synthetic-work\tSYNTH-WORK-[0-9]{4}\n", "test patterns")
MEASURED = ForgeWire::Scan.measured(PATTERNS)
TABLE = shipped_table
VIS = {
  "github:repo:synth-owner/pub" => "public", "github:repo:synth-owner/priv" => "private",
  "github:node:PR_pub" => "public", "github:node:PR_priv" => "private",
  "gitlab:project:synth-group/pub" => "public", "gitlab:project:synth-group/priv" => "private",
  "gitlab:project:synth-group/int" => "internal", "gitlab:project_id:102" => "private",
}.freeze
PLANT = "SYNTH-WORK-4242"

def judge(req, forge: :github, scan: MEASURED, visibility: VIS, table: TABLE)
  J.judge(req, forge: forge, table: table, scan: scan, visibility: visibility)
end

def issue(repo, title, host: GH_API)
  wire("POST", "/repos/#{repo}/issues", host: host, body: JSON.generate({ title: title }))
end

def note(project, text)
  wire("POST", "/api/v4/projects/#{project}/merge_requests/1/notes", host: GL_HOST, body: JSON.generate({ body: text }))
end

def comment(node, text)
  wire("POST", "/graphql", body: JSON.generate({ query: "mutation($input:AddCommentInput!){addComment(input: $input){clientMutationId}}",
                                                 variables: { input: { subjectId: node, body: text } } }))
end

def all_lines(v)
  v.lines.join("\n")
end

# --- reads ---------------------------------------------------------------------
check("a GET is a read, forwarded") { judge(wire("GET", "/repos/synth-owner/pub")).state == :read }
check("a HEAD is a read") { judge(wire("HEAD", "/repos/synth-owner/pub")).forward? }
check("a GraphQL query is a read") do
  judge(wire("POST", "/graphql", body: JSON.generate({ query: "query { viewer { login } }" }))).state == :read
end
check("a read to a host outside the forge is forwarded") { judge(wire("GET", "/x", host: "objects.example.test")).state == :read }

# --- the scan ------------------------------------------------------------------
check("planted text to a public repo is HITS, exit 1") do
  v = judge(issue("synth-owner/pub", "title #{PLANT}"))
  v.state == :hits && v.exit_code == 1 && !v.forward?
end
check("clean text to a public repo is forwarded CLEAN") { judge(issue("synth-owner/pub", "plain title")).state == :clean }
check("planted text to a private repo is forwarded unscanned") do
  v = judge(issue("synth-owner/priv", "title #{PLANT}"))
  v.forward? && v.state == :private
end
check("a hit names the field and the label, never the value") do
  v = judge(issue("synth-owner/pub", "title #{PLANT}"))
  all_lines(v).include?("body.title:1 label=synthetic-work") && !all_lines(v).include?(PLANT)
end
check("a HITS refusal carries Fix:") { all_lines(judge(issue("synth-owner/pub", PLANT))).include?("Fix:") }
check("a hit on the second line names line 2") do
  all_lines(judge(issue("synth-owner/pub", "one\ntwo #{PLANT}"))).include?("body.title:2 label=synthetic-work")
end
check("text in the path is scanned (DND-2013)") do
  judge(wire("POST", "/repos/synth-owner/pub/issues?label=#{PLANT}", body: "{}")).state == :hits
end
check("text in a path segment is scanned") do
  judge(wire("POST", "/api/v4/projects/synth-group%2Fpub/merge_requests/#{PLANT}/notes", host: GL_HOST, body: "{}"), forge: :gitlab).state == :hits
end
check("a JSON key that matches is redacted in the refusal") do
  v = judge(wire("POST", "/repos/synth-owner/pub/issues", body: JSON.generate({ "#{PLANT}" => "x" })))
  v.state == :hits && !all_lines(v).include?(PLANT)
end
check("an unknown repo is public") do
  judge(issue("synth-owner/other", PLANT)).state == :hits
end
check("a target missing from the visibility map is never private (GitHub: public)") do
  judge(issue("synth-owner/pub", PLANT), visibility: {}).state == :hits
end
check("GitHub unreadable visibility is scanned as public") do
  judge(issue("synth-owner/pub", PLANT), visibility: { "github:repo:synth-owner/pub" => :unreadable }).state == :hits
end
check("an unresolved node id is public") do
  judge(comment("PR_gone", PLANT), visibility: { "github:node:PR_gone" => :unresolved }).state == :hits
end
check("a GraphQL comment on a private node is forwarded") { judge(comment("PR_priv", PLANT)).state == :private }
check("a GraphQL comment on a public node is HITS") { judge(comment("PR_pub", PLANT)).state == :hits }
check("a GraphQL target written inline is unknown, so public") do
  r = wire("POST", "/graphql", body: JSON.generate({ query: %(mutation{addComment(input:{subjectId:"PR_priv", body:"#{PLANT}"}){clientMutationId}}) }))
  judge(r).state == :hits
end
check("one public target among private ones is scanned") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpub/merge_requests", host: GL_HOST,
           body: JSON.generate({ title: PLANT, target_project_id: 102 }))
  judge(r, forge: :gitlab).state == :hits
end
check("an MR on a private project whose query names a public target_project_id is scanned") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpriv/merge_requests?target_project_id=101", host: GL_HOST,
           body: JSON.generate({ title: PLANT }))
  judge(r, forge: :gitlab, visibility: VIS.merge("gitlab:project_id:101" => "public")).state == :hits
end
check("GitLab internal is public"){ judge(note("synth-group%2Fint", PLANT), forge: :gitlab).state == :hits }
check("GitLab private is forwarded") { judge(note("synth-group%2Fpriv", PLANT), forge: :gitlab).state == :private }
check("GitLab unreadable visibility is COULD NOT LOOK, exit 3") do
  v = judge(note("synth-group%2Fpub", "clean"), forge: :gitlab, visibility: { "gitlab:project:synth-group/pub" => :unreadable })
  v.state == :could_not_look && v.exit_code == 3 && all_lines(v).include?("Fix:")
end
check("a GitLab target missing from the map is COULD NOT LOOK") do
  judge(note("synth-group%2Fpub", "clean"), forge: :gitlab, visibility: {}).state == :could_not_look
end

# --- scanner states --------------------------------------------------------------
check("COULD NOT MEASURE refuses, exit 3, with the scanner's Fix:") do
  v = judge(issue("synth-owner/pub", "clean"), scan: ForgeWire::Scan.unmeasured("overlay is MALFORMED: x"))
  v.state == :unmeasured && v.exit_code == 3 && all_lines(v).include?("Fix:")
end
check("ABSENT overlay on an unmarked machine forwards with a WARNING") do
  v = judge(issue("synth-owner/pub", PLANT), scan: ForgeWire::Scan.unmeasured("overlay is ABSENT (probed x)", unmarked_absent: true))
  v.forward? && v.state == :unscanned && all_lines(v).include?("UNSCANNED")
end
check("WAIVED forwards and says it is not clean") do
  v = judge(issue("synth-owner/pub", PLANT), scan: ForgeWire::Scan.waived("owner said so"))
  v.state == :waived && all_lines(v).include?("not a clean result")
end
check("a private target needs no scanner") do
  judge(issue("synth-owner/priv", PLANT), scan: ForgeWire::Scan.unmeasured("overlay is MALFORMED: x")).state == :private
end

# --- fail-closed rows ------------------------------------------------------------
check("an operation not in the table is refused, exit 3, naming the table") do
  v = judge(wire("DELETE", "/repos/synth-owner/pub"))
  v.state == :unknown_operation && v.exit_code == 3 && all_lines(v).include?("operations.tsv")
end
check("an unknown operation's refusal does not print a path segment that matches") do
  v = judge(wire("POST", "/repos/synth-owner/pub/#{PLANT}", body: "{}"))
  v.state == :unknown_operation && !all_lines(v).include?(PLANT)
end
check("an unknown GraphQL mutation is refused") do
  r = wire("POST", "/graphql", body: JSON.generate({ query: "mutation($i: X!){deleteRepository(input: $i){clientMutationId}}", variables: { i: { repositoryId: "R_x" } } }))
  judge(r).state == :unknown_operation
end
check("one unknown field among known ones refuses the whole request") do
  r = wire("POST", "/graphql", body: JSON.generate({ query: "mutation($i: X!, $j: Y!){addComment(input: $i){x} deleteRepository(input: $j){x}}", variables: {} }))
  judge(r).state == :unknown_operation
end
check("an unreadable GraphQL document is judged a write and refused") do
  judge(wire("POST", "/graphql", body: JSON.generate({ query: "mutation { ...F }" }))).state == :unreadable_graphql
end
check("a GraphQL body that is not an object is refused") { judge(wire("POST", "/graphql", body: "[1,2]")).state == :unreadable_graphql }
check("a ref operation is refused without a grant") do
  v = judge(wire("PUT", "/repos/synth-owner/priv/pulls/1/merge", body: JSON.generate({ sha: "abc" })))
  v.state == :ref_without_grant && v.exit_code == 3 && all_lines(v).include?("locked-merge")
end
check("a ref operation is refused even on a private target") do
  judge(wire("PUT", "/api/v4/projects/synth-group%2Fpriv/merge_requests/1/merge", host: GL_HOST, body: "{}"), forge: :gitlab).state == :ref_without_grant
end
check("a write to a host outside the forge is refused") do
  judge(wire("POST", "/repos/synth-owner/pub/issues", host: "objects.example.test", body: "{}")).state == :off_forge
end
check("a GitLab host is outside the GitHub forge") { judge(note("synth-group%2Fpub", "x"), forge: :github).state == :off_forge }
check("a method-override header is refused") do
  judge(wire("GET", "/repos/synth-owner/pub", headers: ["X-HTTP-Method-Override: DELETE"])).state == :method_override
end
check("a GET with a body is a write (and not in the table)") do
  judge(wire("GET", "/repos/synth-owner/pub/issues", body: JSON.generate({ title: PLANT }))).state == :unknown_operation
end
check("a declared-JSON body that does not parse is refused") do
  v = judge(wire("POST", "/repos/synth-owner/pub/issues", body: "{nope"))
  v.state == :unparseable && v.exit_code == 3
end
check("a GraphQL body with two `query` keys is refused, not judged a read") do
  v = judge(wire("POST", "/graphql", body: '{"query":"mutation{deleteRepository(input:{}){x}}","query":"query{viewer{login}}"}'))
  v.state == :unparseable && v.exit_code == 3
end
check("unparseable bytes have a verdict too") { J.unparseable("a line ending is not CRLF").state == :unparseable }
check("a GitLab GraphQL GET with a mutation in the query string is a write") do
  r = wire("GET", "/api/graphql?query=mutation%7BcreateNote(input%3A%7B%7D)%7Bnote%7Bid%7D%7D%7D", host: GL_HOST)
  judge(r, forge: :gitlab).state == :unknown_operation
end
check("a COULD NOT LOOK refusal does not print the project path") do
  v = judge(note("synth-group%2Fpub", "clean"), forge: :gitlab, visibility: {})
  v.state == :could_not_look && !all_lines(v).include?("synth-group") && all_lines(v).include?("project")
end
check("a COULD NOT LOOK refusal names a numeric project id") do
  r = wire("POST", "/api/v4/projects/101/merge_requests/1/notes", host: GL_HOST, body: JSON.generate({ body: "x" }))
  all_lines(judge(r, forge: :gitlab, visibility: {})).include?("project_id 101")
end
check("a pattern that times out mid-scan is COULD NOT MEASURE, not an exception") do
  slow = OutboundScan::Pattern.new(label: "slow", source: "x", regex: Object.new.tap do |o|
    def o.match?(_text) = raise(Regexp::TimeoutError)
  end)
  v = judge(issue("synth-owner/pub", "clean"), scan: ForgeWire::Scan.measured([slow]))
  v.state == :unmeasured && v.exit_code == 3 && all_lines(v).include?("Fix:")
end
check("a _method parameter in the query is a method override") do
  judge(wire("POST", "/repos/synth-owner/pub/issues?_method=DELETE", body: "{}")).state == :method_override
end
check("a _method parameter in a form body is a method override") do
  judge(wire("POST", "/repos/synth-owner/pub/issues", body: "_method=DELETE&title=x", type: "application/x-www-form-urlencoded")).state == :method_override
end
check("a _method part in a multipart body is a method override") do
  mp = "--BND\r\nContent-Disposition: form-data; name=\"_method\"\r\n\r\nPUT\r\n--BND--\r\n"
  judge(wire("POST", "/repos/synth-owner/pub/issues", body: mp, type: "multipart/form-data; boundary=BND")).state == :method_override
end
check("a _method key in a JSON body is a method override") do
  judge(wire("POST", "/repos/synth-owner/pub/issues", body: JSON.generate({ _method: "PUT", title: "x" }))).state == :method_override
end
check("a GET to a GraphQL-looking path that is not the endpoint is not a read") do
  !judge(wire("GET", "/graphql/?query=mutation%7Bx%7D")).forward? &&
    !judge(wire("GET", "/api/graphql.json?query=mutation%7Bx%7D", host: GL_HOST), forge: :gitlab).forward?
end
check("an unknown GraphQL mutation's refusal names the field") do
  r = wire("POST", "/graphql", body: JSON.generate({ query: "mutation($i: X!){deleteRepository(input: $i){clientMutationId}}", variables: { i: { repositoryId: "R_x" } } }))
  all_lines(judge(r)).include?("deleteRepository")
end
check("an unreadable GraphQL document has its own state and a defect Fix:") do
  v = judge(wire("POST", "/graphql", body: JSON.generate({ query: "mutation { ...F }" })))
  v.state == :unreadable_graphql && v.exit_code == 3 && !all_lines(v).include?("operations.tsv") && all_lines(v).include?("Fix:")
end
check("every refusal carries Fix:") do
  [judge(wire("DELETE", "/repos/synth-owner/pub")), judge(wire("PUT", "/repos/synth-owner/pub/pulls/1/merge", body: "{}")),
   judge(issue("synth-owner/pub", "x", host: "objects.example.test")), J.unparseable("x")].all? { |v| all_lines(v).include?("Fix:") }
end

finish("forge-wire verdict")
