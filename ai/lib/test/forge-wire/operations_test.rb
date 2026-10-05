# frozen_string_literal: true

# ForgeWire::Operations (DND-2025): the wire operation table. A write is
# forwarded only when the table names its operation; an operation it does not
# name is refused. A table that does not parse is an error naming the line,
# never an empty table (an empty table read as "nothing to judge" would be
# the failed-lookup-looks-empty class).

require_relative "helper"
require_relative "../../forge_wire/operations"

O = ForgeWire::Operations

TABLE = <<~TSV
  # comment
  github\tPOST\t/repos/{o}/{r}/issues/{n}/comments\ttext
  github\tPUT\t/repos/{o}/{r}/pulls/{n}/merge\tref
  github\tgraphql\taddComment\ttext
  github\tgraphql\tmergePullRequest\tref
  gitlab\tPOST\t/api/v4/projects/{p}/merge_requests\ttext
  gitlab\tPOST\t/api/v4/projects/{p}/pipelines/{id}/retry\tplain
TSV

t = O.parse(TABLE, "test table")

def rest(t, forge, method, path)
  t.rest(forge, method, path)
end

check("a REST route matches with its placeholders filled") do
  op = rest(t, :github, "POST", "/repos/o/r/issues/7/comments")
  op && op.klass == :text && op.name == "github POST /repos/{o}/{r}/issues/{n}/comments"
end
check("the method must match") { rest(t, :github, "PATCH", "/repos/o/r/issues/7/comments").nil? }
check("the forge must match") { rest(t, :gitlab, "POST", "/repos/o/r/issues/7/comments").nil? }
check("a longer path does not match") { rest(t, :github, "POST", "/repos/o/r/issues/7/comments/9").nil? }
check("a shorter path does not match") { rest(t, :github, "POST", "/repos/o/r/issues/7").nil? }
check("a placeholder does not match an empty segment") { rest(t, :github, "POST", "/repos/o//issues/7/comments").nil? }
check("a placeholder matches one raw segment (an encoded project)") do
  rest(t, :gitlab, "POST", "/api/v4/projects/synth-group%2Fpub/merge_requests")&.klass == :text
end
check("literal segments are case-sensitive") { rest(t, :github, "POST", "/repos/o/r/Issues/7/comments").nil? }
check("a trailing slash does not match") { rest(t, :github, "POST", "/repos/o/r/issues/7/comments/").nil? }
check("ref class is read") { rest(t, :github, "PUT", "/repos/o/r/pulls/1/merge")&.klass == :ref }
check("plain class is read") { rest(t, :gitlab, "POST", "/api/v4/projects/1/pipelines/2/retry")&.klass == :plain }
check("a GraphQL mutation field is looked up by name") { t.graphql(:github, "addComment")&.klass == :text }
check("an unknown mutation is nil") { t.graphql(:github, "deleteRepository").nil? }
check("GraphQL names are per forge") { t.graphql(:gitlab, "addComment").nil? }
check("the table counts its rows") { t.size == 6 }

def table_error?(text, msg = nil)
  raises?(O::TableError, msg) { O.parse(text, "t") }
end
check("an empty table is an error, not an empty table") { table_error?("# only comments\n", "no rows") }
check("a row with three columns is an error naming its line") { table_error?("github\tPOST\t/x\n", "line 1") }
check("an unknown forge is an error") { table_error?("gitea\tPOST\t/x\ttext\n") }
check("an unknown class is an error") { table_error?("github\tPOST\t/x\tmaybe\n") }
check("GET is not a write method") { table_error?("github\tGET\t/x\ttext\n") }
check("a route not starting with / is an error") { table_error?("github\tPOST\tx\ttext\n") }
check("a GraphQL name that is not a name is an error") { table_error?("github\tgraphql\tadd comment\ttext\n") }
check("a duplicate row is an error") { table_error?("github\tPOST\t/x\ttext\ngithub\tPOST\t/x\tref\n", "line 2") }
check("a placeholder that is not {name} is an error") { table_error?("github\tPOST\t/x/{a\ttext\n") }
check("a table error never quotes the row") do
  O.parse("github\tPOST\t/secret-row\tbogus\n", "t")
  false
rescue O::TableError => e
  !e.message.include?("secret-row")
end

# The shipped table parses, and every row in it is reachable.
shipped = O.load_default
check("the shipped table parses") { shipped.size.positive? }
check("the shipped table holds a GitHub merge as ref") { shipped.graphql(:github, "mergePullRequest")&.klass == :ref }
check("the shipped table holds a GitLab merge as ref") { shipped.rest(:gitlab, "PUT", "/api/v4/projects/1/merge_requests/2/merge")&.klass == :ref }
check("the shipped table holds a GitLab branch create as ref") do
  shipped.rest(:gitlab, "POST", "/api/v4/projects/1/repository/branches")&.klass == :ref
end
check("the shipped table holds createLinkedBranch as ref") { shipped.graphql(:github, "createLinkedBranch")&.klass == :ref }

finish("forge-wire operations")
