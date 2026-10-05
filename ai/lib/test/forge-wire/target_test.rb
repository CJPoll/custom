# frozen_string_literal: true

# ForgeWire::Target (DND-2025): what repository or project a write reaches,
# read from the wire path (and, for GitHub GraphQL, the node ids in the
# variables). A target this reader cannot name is :unknown, which the verdict
# scans as PUBLIC. A reader that guessed a target could guess a private one.

require "json"
require_relative "helper"
require_relative "../../forge_wire/target"
require_relative "../../forge_wire/fields"
require_relative "../../forge_wire/graphql"

T = ForgeWire::Target

def targets(forge, req)
  body = ForgeWire::Fields.parse_body(req)
  op = nil
  if T.graphql?(forge, req)
    doc = body.value.is_a?(Hash) ? body.value : {}
    op = ForgeWire::GraphQL.operation(doc["query"], doc["operationName"])
  end
  T.of(forge, req, body, op)
end

def keys(forge, req)
  targets(forge, req).map(&:key)
end

def unknown?(forge, req)
  targets(forge, req).any? { |t| t.kind == :unknown }
end

# --- GitHub REST -------------------------------------------------------------
check("repos/{o}/{r}/... names the repo") { keys(:github, wire("POST", "/repos/synth-owner/pub/issues")) == ["github:repo:synth-owner/pub"] }
check("the repo key is lower-cased") { keys(:github, wire("POST", "/repos/Synth-Owner/Pub/issues")) == ["github:repo:synth-owner/pub"] }
check("repos/{o}/{r} alone names the repo") { keys(:github, wire("PATCH", "/repos/synth-owner/pub")) == ["github:repo:synth-owner/pub"] }
check("the uploads host reads the same path") do
  keys(:github, wire("POST", "/repos/synth-owner/pub/releases/1/assets?name=a", host: "uploads.github.com")) == ["github:repo:synth-owner/pub"]
end
check("repositories/{id} names the repository id") { keys(:github, wire("POST", "/repositories/42/issues")) == ["github:repository_id:42"] }
check("repositories/{non-digits} is unknown") { unknown?(:github, wire("POST", "/repositories/x/issues")) }
check("a percent-escape in the owner is unknown") { unknown?(:github, wire("POST", "/repos/synth%2Downer/pub/issues")) }
check("an escaped slash in the repo is unknown") { unknown?(:github, wire("POST", "/repos/synth-owner/a%2Fb/issues")) }
check("a dot segment anywhere is unknown") { unknown?(:github, wire("POST", "/repos/synth-owner/pub/../priv/issues")) }
check("an empty segment is unknown") { unknown?(:github, wire("POST", "/repos//pub/issues")) }
check("a repo named . is unknown") { unknown?(:github, wire("POST", "/repos/synth-owner/./issues")) }
check("a path with no repo is unknown") { unknown?(:github, wire("POST", "/user/repos")) }
check("repos/{o} with no repo is unknown") { unknown?(:github, wire("POST", "/repos/synth-owner")) }

# --- GitHub GraphQL ------------------------------------------------------------
def gql(doc, vars, host: GH_API, path: "/graphql")
  wire("POST", path, host: host, body: JSON.generate({ query: doc, variables: vars }))
end
comment = gql("mutation C($input:AddCommentInput!){addComment(input: $input){clientMutationId}}",
              { input: { subjectId: "PR_kwDOSynthPub1", body: "x" } })
check("a node id in the variables is a node target") { keys(:github, comment) == ["github:node:PR_kwDOSynthPub1"] }
create = gql("mutation($input: CreatePullRequestInput!){createPullRequest(input: $input){pullRequest{id}}}",
             { input: { repositoryId: "R_kgDOSynthPub", headRepositoryId: "R_kgDOSynthPriv", title: "t" } })
check("every *Id value is a target") { keys(:github, create).sort == ["github:node:R_kgDOSynthPriv", "github:node:R_kgDOSynthPub"] }
labels = gql("mutation($i: X!){updatePullRequest(input: $i){clientMutationId}}",
             { i: { pullRequestId: "PR_kwDOSynthPub1", labelIds: %w[LA_a LA_b] } })
check("*Ids arrays are targets too") { keys(:github, labels).sort == %w[github:node:LA_a github:node:LA_b github:node:PR_kwDOSynthPub1] }
check("a bare id key is a target") do
  keys(:github, gql("mutation($id: ID!){closePullRequest(input: {pullRequestId: $id}){clientMutationId}}", { id: "PR_x" })) == ["github:node:PR_x"]
end
check("a string literal in the document makes the target unknown") do
  unknown?(:github, gql('mutation{addComment(input: {subjectId: "PR_x", body: "b"}){clientMutationId}}', {}))
end
check("a node id under a key not named *Id adds an unknown target") do
  r = gql("mutation($i: X!){addComment(input: $i){clientMutationId}}",
          { i: { subjectId: "PR_kwDOSynthPriv1", subject: "PR_kwDOSynthPub1", body: "b" } })
  keys(:github, r).include?("github:node:PR_kwDOSynthPriv1") && unknown?(:github, r)
end
check("a legacy base64 node id under another key adds an unknown target") do
  unknown?(:github, gql("mutation($i: X!){addComment(input: $i){clientMutationId}}",
                        { i: { subjectId: "PR_x123456", other: "MDExOlB1bGxSZXF1ZXN0MQ==" } }))
end
check("ordinary text under other keys adds nothing") do
  r = gql("mutation($i: X!){addComment(input: $i){clientMutationId}}",
          { i: { subjectId: "PR_kwDOSynthPriv1", body: "SYNTH-WORK-4242 and main", mergeMethod: "SQUASH" } })
  !unknown?(:github, r)
end
check("a mutation with no id at all is unknown"){ unknown?(:github, gql("mutation($t: String!){createRepository(input: {name: $t}){repository{id}}}", { t: "x" })) }
check("an id value that is not a string is unknown") do
  unknown?(:github, gql("mutation($i: X!){addComment(input: $i){clientMutationId}}", { i: { subjectId: 7, body: "b" } }))
end
check("an empty id is unknown") do
  unknown?(:github, gql("mutation($i: X!){addComment(input: $i){clientMutationId}}", { i: { subjectId: "", body: "b" } }))
end

# --- GitLab REST -------------------------------------------------------------
check("projects/{encoded path} names the project") do
  keys(:gitlab, wire("POST", "/api/v4/projects/synth-group%2Fpub/issues", host: GL_HOST)) == ["gitlab:project:synth-group/pub"]
end
check("a subgroup path is one project") do
  keys(:gitlab, wire("POST", "/api/v4/projects/synth-group%2Fsub%2Fpub/issues", host: GL_HOST)) == ["gitlab:project:synth-group/sub/pub"]
end
check("lower-case %2f decodes the same") do
  keys(:gitlab, wire("POST", "/api/v4/projects/Synth-Group%2fPub/issues", host: GL_HOST)) == ["gitlab:project:synth-group/pub"]
end
check("projects/{id} names the project id") { keys(:gitlab, wire("POST", "/api/v4/projects/101/issues", host: GL_HOST)) == ["gitlab:project_id:101"] }
check("groups/{path} names the group") { keys(:gitlab, wire("POST", "/api/v4/groups/synth-group/labels", host: GL_HOST)) == ["gitlab:group:synth-group"] }
check("a project with no namespace is unknown") { unknown?(:gitlab, wire("POST", "/api/v4/projects/pub/issues", host: GL_HOST)) }
check("a dot segment inside the encoded project is unknown") do
  unknown?(:gitlab, wire("POST", "/api/v4/projects/synth-group%2F..%2Fpub/issues", host: GL_HOST))
end
check("a double-encoded slash is unknown") { unknown?(:gitlab, wire("POST", "/api/v4/projects/synth-group%252Fpub/issues", host: GL_HOST)) }
check("a path outside /api/v4 is unknown") { unknown?(:gitlab, wire("POST", "/synth-group/pub/-/issues", host: GL_HOST)) }
check("another api/v4 resource is unknown") { unknown?(:gitlab, wire("POST", "/api/v4/snippets", host: GL_HOST)) }
check("target_project_id in a JSON body is a second target") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpub/merge_requests", host: GL_HOST,
           body: JSON.generate({ title: "t", target_project_id: 102 }))
  keys(:gitlab, r) == ["gitlab:project:synth-group/pub", "gitlab:project_id:102"]
end
check("target_project_id in a form body is a second target") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpub/merge_requests", host: GL_HOST,
           body: "title=t&target_project_id=102", type: "application/x-www-form-urlencoded")
  keys(:gitlab, r) == ["gitlab:project:synth-group/pub", "gitlab:project_id:102"]
end
check("target_project_id in the query is a second target") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpriv/merge_requests?target_project_id=101", host: GL_HOST,
           body: JSON.generate({ title: "t" }))
  keys(:gitlab, r) == ["gitlab:project:synth-group/priv", "gitlab:project_id:101"]
end
check("target_project_id in a raw JSON body is a second target") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpriv/merge_requests", host: GL_HOST,
           body: JSON.generate({ target_project_id: 101 }), type: "text/plain")
  keys(:gitlab, r) == ["gitlab:project:synth-group/priv", "gitlab:project_id:101"]
end
check("two target_project_id values are both targets") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpriv/merge_requests?target_project_id=101", host: GL_HOST,
           body: JSON.generate({ target_project_id: 102 }))
  keys(:gitlab, r) == ["gitlab:project:synth-group/priv", "gitlab:project_id:101", "gitlab:project_id:102"]
end
check("a target_project_id that is not an id is unknown") do
  r = wire("POST", "/api/v4/projects/synth-group%2Fpub/merge_requests", host: GL_HOST,
           body: JSON.generate({ target_project_id: "synth-group/pub" }))
  unknown?(:gitlab, r)
end
check("GitLab GraphQL is unknown") do
  unknown?(:gitlab, gql("mutation($i: X!){createNote(input: $i){note{id}}}", { i: { noteableId: "gid://gitlab/MergeRequest/1" } },
                        host: GL_HOST, path: "/api/graphql"))
end

# --- the request is GraphQL or not -------------------------------------------
check("GitHub GraphQL is POST /graphql on api.github.com") { T.graphql?(:github, wire("POST", "/graphql")) }
check("GitLab GraphQL is /api/graphql") { T.graphql?(:gitlab, wire("POST", "/api/graphql", host: GL_HOST)) }
check("/graphql on the uploads host is not GraphQL") { !T.graphql?(:github, wire("POST", "/graphql", host: "uploads.github.com")) }
check("/api/v4/graphql is not GraphQL") { !T.graphql?(:gitlab, wire("POST", "/api/v4/graphql", host: GL_HOST)) }

finish("forge-wire target")
