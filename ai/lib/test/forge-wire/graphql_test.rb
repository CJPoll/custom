# frozen_string_literal: true

# ForgeWire::GraphQL (DND-2025): which operation a document selects, its type,
# and its top-level fields. A document this reader cannot read is :unreadable,
# which the verdict judges as a mutation with no known operation (refused).

require_relative "helper"
require_relative "../../forge_wire/graphql"

G = ForgeWire::GraphQL

def op(doc, name = nil)
  G.operation(doc, name)
end

# --- types -------------------------------------------------------------------
check("an anonymous selection set is a query") { op("{ viewer { login } }").type == :query }
check("a named query is a query") { op("query Q { viewer { login } }").type == :query }
check("a mutation is a mutation") { op("mutation M { addComment(input: {}) { clientMutationId } }").type == :mutation }
check("a subscription is a subscription") { op("subscription S { x }").type == :subscription }
check("keywords are case-sensitive: Mutation is not a keyword") { op("Mutation { x }").type == :unreadable }

# --- fields ------------------------------------------------------------------
gh = "mutation CommentCreate($input:AddCommentInput!){addComment(input: $input){commentEdge{node{url}}}}"
check("gh's CommentCreate selects addComment") { op(gh).fields == ["addComment"] }
check("an alias names the field, not the alias") { op("mutation { a: mergePullRequest(input:{}) { x } }").fields == ["mergePullRequest"] }
check("every top-level field is listed") do
  op("mutation { addComment(input: $a) { x } b: mergePullRequest(input: $b) { y } }").fields == %w[addComment mergePullRequest]
end
check("nested fields are not top-level") { op("mutation { createIssue(input: $i) { issue { id title } } }").fields == ["createIssue"] }
check("a directive on a field is skipped") { op("mutation { addComment(input: $i) @include(if: true) { x } }").fields == ["addComment"] }
check("a fragment spread at the root is unreadable") { op("mutation { ...F } fragment F on Mutation { addComment(input: $i) { x } }").type == :unreadable }
check("an inline fragment at the root is unreadable") { op("mutation { ... on Mutation { addComment(input: $i) { x } } }").type == :unreadable }
check("a mutation with no fields is unreadable") { op("mutation { }").type == :unreadable }

# --- selection by operationName ----------------------------------------------
two = "query Q { viewer { login } } mutation M { addComment(input: $i) { x } }"
check("operationName selects the mutation") { op(two, "M").type == :mutation }
check("operationName selects the query") { op(two, "Q").type == :query }
check("two operations and no operationName is unreadable") { op(two).type == :unreadable }
check("an operationName that names nothing is unreadable") { op(two, "Z").type == :unreadable }
check("a fragment definition beside one operation is fine") do
  o = op("fragment repo on Repository { id } query RepositoryInfo($o: String!) { repository(owner: $o) { ...repo } }")
  o.type == :query
end
check("gh's RepositoryInfo (fragment first, tabs, newlines) is a query") do
  op("\n\tfragment repo on Repository {\n\t\tid\n\t}\n\n\tquery RepositoryInfo($owner: String!) {\n\t\trepository(owner: $owner) {\n\t\t\t...repo\n\t\t}\n\t}").type == :query
end

# --- the lexer -----------------------------------------------------------------
check("a brace inside a string does not end the selection") do
  op('mutation { addComment(input: {body: "}"}) { x } }').fields == ["addComment"]
end
check("a keyword inside a string is not a keyword") { op('query { search(q: "mutation { x }") { id } }').type == :query }
check("a block string is skipped") { op('mutation { addComment(input: {body: """ } mutation """}) { x } }').fields == ["addComment"] }
check("an escaped quote stays inside the string") { op('mutation { addComment(input: {body: "a\\"}"}) { x } }').fields == ["addComment"] }
check("a comment is skipped") { op("# mutation { x }\nquery { viewer { id } }").type == :query }
check("commas are insignificant") { op("mutation{,addComment(input:$i){x},}").fields == ["addComment"] }
check("an unterminated string is unreadable") { op('mutation { addComment(input: {body: "x}) { x } }').type == :unreadable }
check("unbalanced braces are unreadable") { op("mutation { addComment(input: $i) { x }").type == :unreadable }
check("a character outside GraphQL is unreadable") { op("mutation { addComment ^ }").type == :unreadable }
check("a non-string document is unreadable") { op(nil).type == :unreadable }
check("an empty document is unreadable") { op("").type == :unreadable }

# --- literals (a target cannot be read from an inline value) -------------------
check("a string literal anywhere in the document is reported"){ op('mutation { addComment(input: {subjectId: "X"}) { x } }').literal }
check("variables only: no literal") { !op("mutation($i: AddCommentInput!) { addComment(input: $i) { x } }").literal }
check("an enum or number argument is not a string literal") { !op("mutation { a(n: 3, e: SQUASH) { x } }").literal }

finish("forge-wire graphql")
