# frozen_string_literal: true

# The capture scenarios (DND-2025). Every name, token and value is synthetic.
# PLANTED is the stand-in for a work-domain value: the Domain suites plant a
# pattern that matches it. GitHub: synth-owner/pub (public) and
# synth-owner/priv (private). GitLab: synth-group/pub and synth-group/priv.

PLANTED = "SYNTH-WORK-4242"
SYNTH_TOKEN = "fixture-token-not-a-credential"

GH_REMOTE_PRIV = "https://github.com/synth-owner/priv.git"
GL_REMOTE_PRIV = "https://gitlab.com/synth-group/priv.git"

GH_IDS = { "pub" => "R_kgDOSynthPub", "priv" => "R_kgDOSynthPriv" }.freeze

def gh_route(body, json, method: "POST", path: "^/graphql$", status: 200)
  { method: method, host: "api.github.com", path: path, body: body, status: status, json: json }
end

def gh_repo(name)
  { id: GH_IDS.fetch(name), name: name, owner: { login: "synth-owner" }, hasIssuesEnabled: true,
    description: "", hasWikiEnabled: false, viewerPermission: "WRITE", defaultBranchRef: { name: "main" },
    parent: nil, mergeCommitAllowed: true, rebaseMergeAllowed: true, squashMergeAllowed: true,
    isPrivate: name == "priv", visibility: name == "priv" ? "PRIVATE" : "PUBLIC" }
end

# The canned GitHub answers every gh scenario shares.
GH_RESPONSES = GH_IDS.keys.flat_map do |name|
  [
    gh_route(["query RepositoryInfo", %("name":"#{name}")], { data: { repository: gh_repo(name) } }),
    gh_route(["query RepositoryFindFork", %("repo":"#{name}")], { data: { repository: { forks: { nodes: [] } } } }),
    gh_route(["PullRequestByNumber", "isCrossRepository,headRefName,id}", %("repo":"#{name}")],
             { data: { repository: { pullRequest: { id: "PR_kwDOSynth#{name.capitalize}1", number: 1, state: "OPEN",
                                                    title: "t", isCrossRepository: false, headRefName: "feature" } } } }),
    gh_route(nil, { id: 77, status: "completed", conclusion: "failure", head_branch: "feature",
                    html_url: "https://github.com/synth-owner/#{name}/actions/runs/77" },
             method: "GET", path: "^/repos/synth-owner/#{name}/actions/runs/77$"),
    gh_route(nil, { id: 0, name: "ci", path: ".github/workflows/ci.yml", state: "active" },
             method: "GET", path: "^/repos/synth-owner/#{name}/actions/workflows/0$"),
    gh_route(["PullRequestByNumber", %("repo":"#{name}")],
             { data: { repository: { pullRequest: { id: "PR_kwDOSynth#{name.capitalize}1", url: "https://github.com/synth-owner/#{name}/pull/1", number: 1 } } } }),
    gh_route(["mutation PullRequestCreate(", GH_IDS.fetch(name)],
             { data: { createPullRequest: { pullRequest: { id: "PR_kwDOSynth#{name.capitalize}1", url: "https://github.com/synth-owner/#{name}/pull/1" } } } }),
    gh_route(["IssueByNumber", %("repo":"#{name}")],
             { data: { repository: { hasIssuesEnabled: true,
                                     issue: { __typename: "Issue", id: "I_kwDOSynth#{name.capitalize}3", number: 3 } } } }),
    gh_route("query LinkedBranchFeature", { data: { LinkedBranch: { fields: [{ name: "id" }, { name: "ref" }] } } }),
    gh_route(["FindRepoBranchID", %("name":"#{name}")],
             { data: { repository: { id: GH_IDS.fetch(name), defaultBranchRef: { target: { oid: "0123456789abcdef0123456789abcdef01234567" } },
                                     ref: { target: { oid: "0123456789abcdef0123456789abcdef01234567" } } } } }),
    gh_route(["RepositoryLabelList", %("name":"#{name}")],
             { data: { repository: { labels: { nodes: [{ id: "LA_kwDOSynthLabel", name: "-t" }],
                                               pageInfo: { hasNextPage: false, endCursor: nil } } } } }),
    gh_route(nil, gh_repo(name).merge(full_name: "synth-owner/#{name}", private: name == "priv"),
             method: "GET", path: "^/repos/synth-owner/#{name}$"),
  ]
end + [
  gh_route(nil, { login: "synth-owner", type: "User" }, method: "GET", path: "^/users/synth-owner$"),
  gh_route(nil, { login: "synth-owner", type: "User" }, method: "GET", path: "^/user$"),
  gh_route("RepositoryCreate", { data: { createRepository: { repository: { id: "R_kgDOSynthFresh", name: "fresh",
                                                                           owner: { login: "synth-owner" },
                                                                           url: "https://github.com/synth-owner/fresh" } } } }),
].freeze

GL_IDS = { "pub" => 101, "priv" => 102 }.freeze

def gl_route(method, path, json, status: 200, body: nil)
  { method: method, host: "gitlab.com", path: path, body: body, status: status, json: json }
end

def gl_project(name)
  { id: GL_IDS.fetch(name), path: name, path_with_namespace: "synth-group/#{name}", name: name,
    visibility: name == "priv" ? "private" : "public", default_branch: "main",
    web_url: "https://gitlab.com/synth-group/#{name}", namespace: { full_path: "synth-group" },
    http_url_to_repo: "https://gitlab.com/synth-group/#{name}.git",
    ssh_url_to_repo: "git@gitlab.com:synth-group/#{name}.git", merge_requests_enabled: true, merge_requests_access_level: "enabled",
    permissions: { project_access: { access_level: 40 }, group_access: nil } }
end

# The canned GitLab answers every glab scenario shares.
GL_RESPONSES = GL_IDS.flat_map do |name, id|
  ref = "(synth-group%2F#{name}|#{id})"
  [
    gl_route("GET", "^/api/v4/projects/#{ref}$", gl_project(name)),
    gl_route("GET", "^/api/v4/projects/#{ref}/merge_requests/1$",
             { id: 9001, iid: 1, project_id: id, title: "mr", state: "opened", source_branch: "feature",
               target_branch: "main", sha: "0123456789abcdef0123456789abcdef01234567",
               merge_status: "can_be_merged", detailed_merge_status: "mergeable", user: { can_merge: true },
               web_url: "https://gitlab.com/synth-group/#{name}/-/merge_requests/1" }),
    gl_route("GET", "^/api/v4/projects/#{ref}/issues/7$",
             { id: 7007, iid: 7, project_id: id, title: "issue #{PLANTED}", state: "opened" }),
    gl_route("POST", "^/api/v4/projects/#{ref}/merge_requests$",
             { id: 9002, iid: 2, project_id: id, web_url: "https://gitlab.com/synth-group/#{name}/-/merge_requests/2" },
             status: 201),
  ]
end.freeze

SCENARIOS = [
  # --- GitHub ----------------------------------------------------------------
  { name: "gh-api-read", cli: "gh", responses: GH_RESPONSES, argv: %w[api repos/synth-owner/pub], note: "a plain REST read" },
  { name: "gh-dnd-2007-api-write", cli: "gh", responses: GH_RESPONSES,
    argv: ["api", "-X", "POST", "repos/synth-owner/pub/issues", "-f", "title=#{PLANTED} title", "-f", "body=b"],
    note: "DND-2007: gh api writes to a public repo were not scanned" },
  { name: "gh-dnd-1976-flag-swallow", cli: "gh", responses: GH_RESPONSES,
    argv: ["pr", "create", "-R", "synth-owner/pub", "--title", "pr title", "-l", "-t", "-b", "body #{PLANTED}", "--head", "feature", "--base", "main"],
    note: "DND-1976: -l takes -t as its value, so the body followed an unknown flag" },
  { name: "gh-dnd-2006-gh-repo-fallback", cli: "gh", responses: GH_RESPONSES, env: { "GH_REPO" => "synth-owner/pub" },
    repo: { remote: GH_REMOTE_PRIV },
    argv: ["pr", "comment", "1", "-R", "", "-b", "comment #{PLANTED}"],
    note: "DND-2006: -R '' falls back to GH_REPO, not the private checkout" },
  { name: "gh-dnd-2007-placeholder", cli: "gh", responses: GH_RESPONSES,
    repo: { remote: "https://github.com/synth-owner/pub.git", branch: "#{PLANTED}-topic", commits: ["topic"] },
    argv: ["api", "-X", "POST", "repos/{owner}/{repo}/issues", "-F", "title={branch}"],
    note: "DND-2007: gh fills {owner}, {repo} and {branch} after the argv scan read them" },
  { name: "gh-dnd-2019-pr-create-fill", cli: "gh", responses: GH_RESPONSES,
    repo: { remote: "https://github.com/synth-owner/pub.git", branch: "feature", pushed: true,
            commits: ["fix: #{PLANTED} in the parser", "second line of work"] },
    argv: %w[pr create -R synth-owner/pub --fill --head feature --base main],
    note: "DND-2019: --fill sends text gh builds from commit messages" },
  { name: "gh-dnd-2019-issue-develop", cli: "gh", responses: GH_RESPONSES,
    argv: ["issue", "develop", "3", "-R", "synth-owner/pub", "--name", "#{PLANTED}-branch", "--base", "main"],
    note: "DND-2019: issue develop creates a branch through the API" },
  { name: "gh-pr-comment-private", cli: "gh", responses: GH_RESPONSES,
    argv: ["pr", "comment", "1", "-R", "synth-owner/priv", "-b", "comment #{PLANTED}"],
    note: "a comment on a private repository: forwarded unscanned" },
  { name: "gh-pr-merge", cli: "gh", responses: GH_RESPONSES,
    argv: %w[pr merge 1 -R synth-owner/pub --squash --match-head-commit 0123456789abcdef0123456789abcdef01234567],
    note: "a merge: a ref operation, refused without a grant" },
  { name: "gh-pr-merge-auto", cli: "gh", responses: GH_RESPONSES,
    argv: %w[pr merge 1 -R synth-owner/pub --squash --auto],
    note: "auto-merge: a ref operation, refused without a grant" },
  { name: "gh-pr-close", cli: "gh", responses: GH_RESPONSES, argv: %w[pr close 1 -R synth-owner/pub],
    note: "a harness command shape (plain)" },
  { name: "gh-pr-reopen", cli: "gh", responses: GH_RESPONSES, argv: %w[pr reopen 1 -R synth-owner/pub],
    note: "a harness command shape (plain)" },
  { name: "gh-pr-edit-base", cli: "gh", responses: GH_RESPONSES, argv: %w[pr edit 1 -R synth-owner/pub --base develop],
    note: "a harness command shape (retarget)" },
  { name: "gh-run-rerun", cli: "gh", responses: GH_RESPONSES, argv: %w[run rerun 77 -R synth-owner/pub],
    note: "a harness command shape (plain)" },
  { name: "gh-repo-create", cli: "gh", responses: GH_RESPONSES, argv: %w[repo create synth-owner/fresh --private],
    note: "a harness command shape: the target does not exist yet, so it is unknown" },
  # --- GitLab ----------------------------------------------------------------
  { name: "glab-api-read", cli: "glab", responses: GL_RESPONSES, argv: %w[api projects/synth-group%2Fpub],
    note: "a plain REST read" },
  { name: "glab-dnd-2009-upper-scheme", cli: "glab", responses: GL_RESPONSES,
    argv: ["api", "-X", "POST", "HTTPS://gitlab.com/api/v4/projects/synth-group%2Fpub/issues", "-f", "title=#{PLANTED}"],
    note: "DND-2009: an upper-case scheme skipped the host check" },
  { name: "glab-dnd-2009-placeholder", cli: "glab", responses: GL_RESPONSES,
    repo: { remote: "https://gitlab.com/synth-group/pub.git", branch: "#{PLANTED}-topic", commits: ["topic"] },
    argv: ["api", "-X", "POST", "projects/:fullpath/issues", "-F", "title=:branch"],
    note: "DND-2009: glab fills :branch after the argv scan read it" },
  { name: "glab-dnd-2012-schemeless-url", cli: "glab", responses: GL_RESPONSES,
    repo: { remote: GL_REMOTE_PRIV },
    argv: ["mr", "note", "//gitlab.com/synth-group/pub/-/merge_requests/1", "-m", "note #{PLANTED}"],
    note: "DND-2012: a scheme-less MR URL names the public project, not the private cwd" },
  { name: "glab-dnd-2014-related-issue", cli: "glab", responses: GL_RESPONSES,
    repo: { remote: "https://gitlab.com/synth-group/pub.git", branch: "feature", pushed: true, commits: ["work"] },
    argv: ["mr", "create", "-R", "synth-group/pub", "--related-issue", "7", "-t", "", "-d", "mr body", "-s", "feature", "-b", "main", "--yes"],
    note: "DND-2014: the MR title is copied from an issue title glab fetches" },
  { name: "glab-dnd-2017-hidden-flag", cli: "glab", responses: GL_RESPONSES,
    files: { "notes.md" => "release notes #{PLANTED}\n" },
    argv: %w[release create v1.0.0 -R synth-group/pub --ref main --experimental-notes-text-or-file notes.md],
    note: "DND-2017: a hidden flag sends a file as release notes" },
  { name: "glab-dnd-2018-head-project", cli: "glab", responses: GL_RESPONSES,
    repo: { remote: GL_REMOTE_PRIV, branch: "feature", pushed: true, commits: ["work"],
            remotes: { "head" => "https://gitlab.com/synth-group/pub.git" } },
    argv: ["mr", "create", "-R", "synth-group/priv", "-H", "synth-group/pub", "--create-source-branch",
           "-s", "#{PLANTED}-branch", "-b", "main", "-t", "mr title", "-d", "mr body", "--yes"],
    note: "DND-2018: --create-source-branch creates a branch on the head project" },
  { name: "glab-mr-create", cli: "glab", responses: GL_RESPONSES,
    repo: { remote: "https://gitlab.com/synth-group/pub.git", branch: "feature", pushed: true, commits: ["work"] },
    argv: ["mr", "create", "-R", "synth-group/pub", "-s", "feature", "-b", "main", "-t", "mr title #{PLANTED}",
           "-d", "mr body", "--yes"],
    note: "a harness command shape: an MR with text on a public project" },
  { name: "glab-mr-note-private", cli: "glab", responses: GL_RESPONSES,
    argv: ["mr", "note", "1", "-R", "synth-group/priv", "-m", "note #{PLANTED}"],
    note: "a note on a private project: forwarded unscanned" },
  { name: "glab-mr-merge", cli: "glab", responses: GL_RESPONSES,
    argv: %w[mr merge 1 -R synth-group/pub --squash --sha 0123456789abcdef0123456789abcdef01234567 --yes],
    note: "a merge: a ref operation, refused without a grant" },
]
