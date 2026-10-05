# frozen_string_literal: true

# ai/lib/forge_wire/target.rb -- what a write reaches (DND-2025).
# Design: ai/docs/outbound-scan-at-the-wire.md -> What is judged (The target).
#
# Domain only. A request's targets, read from the wire, never from argv:
#   GitHub REST     /repos/{o}/{r}/...             -> repo o/r
#                   /repositories/{id}/...         -> repository id
#                   (api.github.com and uploads.github.com alike)
#   GitHub GraphQL  every string under a key named `id`, `*Id` or `*Ids` in
#                   the variables                  -> node, resolved upstream;
#                   a node-id-shaped string under any other key -> :unknown
#                   (it may name a target the id keys do not)
#   GitLab REST     /api/v4/projects/{id|path}/... -> project
#                   /api/v4/groups/{id|path}/...   -> group
#                   plus each `target_project_id` param, from the query or
#                   the body (Fields.param_values) -> a further project (an
#                   MR created on a head project lands in the target project;
#                   measured in the DND-2018 fixture)
#   anything else   -> :unknown
#
# :unknown is scanned as PUBLIC. So is a path segment that is not spelled
# plainly (a percent-escape in a GitHub owner or repo, a dot or empty
# segment, a GitLab project whose decoded path is not plain): two readers of
# one unplain path can name two different repositories, and the forge's
# reading is the one that counts. A GraphQL mutation whose document holds a
# string literal is :unknown too, because a target written inline is not in
# the variables.
#
# A Target's key is what the visibility map is keyed on (verdict.rb). Keys
# are lower-cased: GitHub and GitLab names are case-insensitive.

require_relative "fields"

module ForgeWire
  module Target
    Target = Struct.new(:kind, :key, keyword_init: true)

    FORGES = {
      github: { hosts: %w[api.github.com uploads.github.com], graphql: ["api.github.com", "/graphql"] },
      gitlab: { hosts: %w[gitlab.com], graphql: ["gitlab.com", "/api/graphql"] },
    }.freeze

    PLAIN = /\A[A-Za-z0-9_.-]+\z/.freeze
    DOTS = /\A\.+\z/.freeze
    ID_KEY = /\A(?:id|.*Ids?)\z/.freeze
    # A GitHub global node id: `PR_kwDO...` (prefix, underscore, base64url)
    # or the legacy base64 form (`MDEwOlJlcG9zaXRvcnkx...`).
    NODE_SHAPE = %r{\A(?:[A-Z][A-Za-z]{0,15}_[A-Za-z0-9_-]{6,}|MD[A-Za-z0-9+/]{10,}={0,2})\z}.freeze

    module_function

    def hosts(forge)
      FORGES.fetch(forge)[:hosts]
    end

    def graphql?(forge, req)
      host, path = FORGES.fetch(forge)[:graphql]
      req.host == host && req.path == path
    end

    def unknown(why)
      Target.new(kind: :unknown, key: "unknown:#{why}")
    end

    # -> [Target], never empty. `op` is the GraphQL operation (or nil).
    def of(forge, req, body, op)
      list =
        if graphql?(forge, req)
          forge == :github ? github_graphql(body, op) : [unknown("gitlab-graphql")]
        elsif forge == :github
          [github_rest(req.path)]
        else
          [gitlab_rest(req.path)] + gitlab_params(req, body)
        end
      list.uniq
    end

    def segments(path)
      segs = path.split("/", -1).drop(1)
      plain = !segs.empty? && segs.none? { |s| s.empty? || DOTS.match?(Fields.pct_decode(s)) }
      [segs, plain]
    end

    def plain_name?(seg)
      PLAIN.match?(seg) && !DOTS.match?(seg)
    end

    def github_rest(path)
      segs, plain = segments(path)
      return unknown("path-not-plain") unless plain

      case segs.first
      when "repos"
        o, r = segs[1], segs[2]
        return unknown("repo-not-plain") unless o && r && plain_name?(o) && plain_name?(r)

        Target.new(kind: :repo, key: "github:repo:#{o.downcase}/#{r.downcase}")
      when "repositories"
        id = segs[1].to_s
        return unknown("repository-id-not-digits") unless id.match?(/\A[0-9]{1,20}\z/)

        Target.new(kind: :repo_id, key: "github:repository_id:#{id}")
      else
        unknown("no-repository-in-path")
      end
    end

    def github_graphql(body, op)
      return [unknown("graphql-literal")] if op.nil? || op.literal
      return [unknown("graphql-body-not-an-object")] unless body.kind == :json && body.value.is_a?(Hash)

      ids = []
      bad = false
      stray = false
      walk_ids(body.value["variables"], false) do |v, under_id|
        if !under_id then stray ||= v.is_a?(String) && NODE_SHAPE.match?(v)
        elsif v.is_a?(String) && !v.empty? then ids << v
        else bad = true
        end
      end
      return [unknown("graphql-id-not-a-string")] if bad
      return [unknown("graphql-no-node-id")] if ids.empty?

      found = ids.uniq.map { |id| Target.new(kind: :node, key: "github:node:#{id}") }
      stray ? found + [unknown("graphql-node-id-under-another-key")] : found
    end

    # Yields every non-nil scalar with whether it sits under an id-named key
    # (arrays under such a key included).
    def walk_ids(value, under_id, &blk)
      case value
      when Hash
        value.each { |k, v| walk_ids(v, ID_KEY.match?(k.to_s), &blk) }
      when Array
        value.each { |v| walk_ids(v, under_id, &blk) }
      else
        blk.call(value, under_id) unless value.nil?
      end
    end

    def gitlab_rest(path)
      segs, plain = segments(path)
      return unknown("path-not-plain") unless plain
      return unknown("not-api-v4") unless segs[0] == "api" && segs[1] == "v4"

      kind = { "projects" => "project", "groups" => "group" }[segs[2]]
      return unknown("no-project-in-path") unless kind && segs[3]

      gitlab_named(kind, segs[3])
    end

    def gitlab_named(kind, seg)
      return Target.new(kind: :"#{kind}_id", key: "gitlab:#{kind}_id:#{seg}") if seg.match?(/\A[0-9]{1,20}\z/)

      raw = seg.gsub(/%2F/i, "/")
      parts = raw.split("/", -1)
      ok = parts.all? { |p| plain_name?(p) } && (kind == "group" || parts.length >= 2)
      return unknown("#{kind}-not-plain") unless ok

      Target.new(kind: kind.to_sym, key: "gitlab:#{kind}:#{parts.join('/').downcase}")
    end

    # Every `target_project_id`, wherever GitLab reads params from (query,
    # form, JSON, multipart, a raw body that is JSON). One that is not a plain
    # id makes the target unknown.
    def gitlab_params(req, body)
      Fields.param_values(req, body, "target_project_id").map do |v|
        next unknown("target-project-id-not-an-id") unless v.match?(/\A[0-9]{1,20}\z/)

        Target.new(kind: :project_id, key: "gitlab:project_id:#{v}")
      end
    end
  end
end
