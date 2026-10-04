# frozen_string_literal: true

# gitlab_pipeline_selector -- the DOMAIN of a repo's GitLab post-merge
# pipeline (DND-1952). Pure: every pipeline, trigger job and child pipeline
# arrives as a hash shaped like the GitLab REST answer; nothing here reads the
# forge.
#
# A repo's idle_workflow (ai/lib/lead_time_config.rb) names its post-merge CI.
# On GitHub that is a workflow FILE (post-merge.yml). On GitLab it is this
# selector:
#
#   gitlab:ref=<branch>,source=<pipeline source>[,child=<trigger job name>]
#
#   ref     the branch the post-merge pipeline runs on (main)
#   source  the pipeline source GitLab records (push)
#   child   the trigger (bridge) job whose downstream child pipeline is the
#           deploy (`trigger: include ... strategy: depend`). Its child's
#           successful finish is the deploy's end. Absent: the parent
#           pipeline's own finish is the post-merge CI's end, and no deploy is
#           read.
#
# Keys may come in any order, each once, no spaces. Any other text that
# starts with "gitlab:" is refused with a reason, never read as a file name.
#
# A selector that matches no pipeline, or names a trigger job the pipeline
# does not have, is a named could-not-measure, never an idle or a no-CI read
# (~/.claude/CLAUDE.md -> *A failed lookup must never look like an empty one*).
# A pipeline still waiting or running (waiting_for_resource included: a
# deploy queued on its resource group) is busy, never concluded. One at
# `manual` is could-not-measure: that status can outlive a successful deploy.

module GitLabPipelineSelector
  PREFIX = "gitlab:"
  KEYS = %w[ref source child].freeze
  REQUIRED = %w[ref source].freeze
  # GitLab's pipeline sources (the REST `source` field). An unknown one is
  # refused, so a typo can never match nothing in silence.
  SOURCES = %w[push web trigger schedule api external pipeline chat webide merge_request_event
               external_pull_request_event parent_pipeline ondemand_dast_scan ondemand_dast_validation
               security_orchestration_policy container_registry_push].freeze
  REF_RE = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}.freeze
  CHILD_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze

  SUCCESS = %w[success].freeze
  BUSY = %w[created waiting_for_resource preparing pending running scheduled canceling].freeze
  BLOCKED = %w[manual].freeze
  FAILED = %w[failed canceled skipped].freeze

  Selector = Struct.new(:ref, :source, :child, :text, keyword_init: true)

  # state: :concluded (deploy_at / pipeline_at are what succeeded, each nil
  # when it did not), :busy (not concluded yet; reason says what is waiting),
  # :unmeasured (reason says why nothing can be read).
  Outcome = Struct.new(:state, :deploy_at, :pipeline_at, :reason, keyword_init: true)

  module_function

  # The prefix alone decides "this is a GitLab selector", so a malformed one
  # is refused by parse, never mistaken for a workflow file.
  def selector?(value) = value.is_a?(String) && value.start_with?(PREFIX)

  # -> [Selector, nil] or [nil, reason]
  def parse(value)
    return [nil, "a GitLab idle pipeline selector must be a string, got #{value.inspect}"] unless value.is_a?(String)
    return [nil, "#{value.inspect} does not start with #{PREFIX.inspect}"] unless selector?(value)

    pairs, why = pairs_of(value)
    return [nil, why] if why

    missing = REQUIRED - pairs.keys
    return [nil, "#{value.inspect} names no #{missing.join(' or ')} (#{form})"] unless missing.empty?

    bad = value_error(pairs)
    return [nil, "#{value.inspect}: #{bad} (#{form})"] if bad

    [Selector.new(ref: pairs["ref"], source: pairs["source"], child: pairs["child"], text: value), nil]
  end

  def form = "the form is gitlab:ref=<branch>,source=<pipeline source>[,child=<trigger job>]"

  # -> [{key => value}, nil] or [nil, reason]
  def pairs_of(value)
    body = value.delete_prefix(PREFIX)
    pairs = {}
    body.split(",", -1).each do |part|
      key, val = part.split("=", 2)
      return [nil, "#{value.inspect}: #{part.inspect} is not key=value (#{form})"] if val.nil?
      return [nil, "#{value.inspect}: unknown key #{key.inspect} (known: #{KEYS.join(', ')})"] unless KEYS.include?(key)
      return [nil, "#{value.inspect}: #{key} is given twice"] if pairs.key?(key)

      pairs[key] = val
    end
    [pairs, nil]
  end

  def value_error(pairs)
    ref = pairs["ref"]
    return "ref #{ref.inspect} is not a branch name" unless REF_RE.match?(ref) && !ref.include?("..")
    return "source #{pairs['source'].inspect} is not a GitLab pipeline source" unless SOURCES.include?(pairs["source"])
    return "child #{pairs['child'].inspect} is not a job name" if pairs.key?("child") && !CHILD_RE.match?(pairs["child"])

    nil
  end

  # :success, :busy, :blocked (waiting on a person: a manual job), :failed, or
  # :unknown (a status this code does not know: never read as concluded).
  def status_class(status)
    return :success if SUCCESS.include?(status)
    return :busy if BUSY.include?(status)
    return :blocked if BLOCKED.include?(status)
    return :failed if FAILED.include?(status)

    :unknown
  end

  # A forge read the selector needed failed. The reader records the failed
  # probe, so the scan reports SCAN INCOMPLETE; the row says so too.
  def read_failed(what) = Outcome.new(state: :unmeasured, reason: "could not measure: the #{what} read failed (see SCAN INCOMPLETE)")

  # The landing's post-merge pipeline. shas: the landing's candidate commits,
  # in the caller's order of preference. Both sides are filtered here even
  # when the query already filtered them. -> [pipeline, nil] or [nil, reason]
  def pick_pipeline(sel, shas, pipelines)
    shas = Array(shas).compact.uniq
    return [nil, "could not measure: no commit to look up a post-merge pipeline for (#{sel.text})"] if shas.empty?

    shas.each do |sha|
      hits = pipelines.select { |p| p["sha"] == sha && p["ref"] == sel.ref && p["source"] == sel.source }
      return [hits.max_by { |p| p["id"].to_i }, nil] unless hits.empty?
    end
    [nil, "could not measure: the idle pipeline selector #{sel.text} matched no pipeline for " \
          "#{shas.map { |s| s.to_s[0, 12] }.join(', ')} (#{pipelines.size} pipeline(s) read)"]
  end

  # The trigger job named by child=. -> [bridge, nil] or [nil, reason]
  def pick_bridge(sel, pipeline, bridges)
    hits = bridges.select { |b| b["name"] == sel.child }
    return [hits.max_by { |b| b["id"].to_i }, nil] unless hits.empty?

    [nil, "could not measure: pipeline #{pipeline['id']} has no trigger job named #{sel.child.inspect} " \
          "(#{bridges.size} trigger job(s); selector #{sel.text})"]
  end

  # What the parent's trigger jobs decide, before any child read. parent: the
  # parent pipeline as read by id. -> [Outcome, nil, nil] when they decide it,
  # or [nil, bridge, child_id] when the child pipeline must be read. A child
  # in another project is decided here, from the URLs GitLab gives, because
  # reading it as this project's pipeline would fail.
  def after_bridges(sel, parent, bridges)
    bridge, why = pick_bridge(sel, parent, bridges)
    return [unmeasured(why), nil, nil] unless bridge

    down = bridge["downstream_pipeline"]
    return [judge(sel, pipeline: parent, bridge: bridge), nil, nil] unless down

    id = down["id"]
    return [unmeasured("could not measure: trigger job #{sel.child.inspect} names a child with no id"), nil, nil] unless id

    mine, theirs = project_of(parent["web_url"]), project_of(down["web_url"])
    unless mine && theirs
      return [unmeasured("could not measure: cannot tell which project child pipeline #{id} is in (no pipeline web_url)"), nil, nil]
    end
    unless mine == theirs
      return [unmeasured("could not measure: #{sel.child.inspect}'s child pipeline #{id} is in another project (#{theirs})"), nil, nil]
    end

    [nil, bridge, id]
  end

  # "https://host/group/repo/-/pipelines/77" -> "https://host/group/repo";
  # nil when it is not a pipeline URL.
  def project_of(url)
    m = %r{\A(https?://.+)/-/pipelines/\d+\z}.match(url.to_s)
    m && m[1]
  end

  def unmeasured(reason) = Outcome.new(state: :unmeasured, reason: reason)

  # The landing's post-merge end. pipeline: the parent as read by id (with
  # finished_at); bridge: the trigger job named by child= (required when the
  # selector names one); child: the downstream pipeline read by id (nil when
  # the trigger job started none).
  def judge(sel, pipeline:, bridge: nil, child: nil)
    parent = parent_end(pipeline)
    return parent if parent.is_a?(Outcome)
    return parent_only(pipeline, parent) unless sel.child
    raise ArgumentError, "judge: #{sel.text} names a child but no trigger job was given" unless bridge

    return trigger_only(sel, pipeline, bridge, parent) unless bridge["downstream_pipeline"]

    child_end(sel, pipeline, bridge, child, parent)
  end

  # -> the parent's finish (or nil when it did not succeed), or an Outcome
  # when the parent alone decides it.
  def parent_end(pipeline)
    status = pipeline["status"]
    case status_class(status)
    when :unknown
      unmeasured("could not measure: pipeline #{pipeline['id']} has status #{status.inspect}, which this tool does not know")
    when :success
      pipeline["finished_at"] || unmeasured("could not measure: pipeline #{pipeline['id']} succeeded with no finished_at")
    end
  end

  def parent_only(pipeline, parent_at)
    status = pipeline["status"]
    case status_class(status)
    when :busy then Outcome.new(state: :busy, reason: "post-merge CI not concluded: pipeline #{pipeline['id']} is #{status}")
    when :blocked then unmeasured(blocked_reason("pipeline #{pipeline['id']}"))
    else Outcome.new(state: :concluded, deploy_at: nil, pipeline_at: parent_at)
    end
  end

  def trigger_only(sel, pipeline, bridge, parent_at)
    status = bridge["status"]
    case status_class(status)
    when :busy then Outcome.new(state: :busy, reason: "deploy not concluded: trigger job #{sel.child.inspect} is #{status}")
    when :blocked then unmeasured(blocked_reason("trigger job #{sel.child.inspect}"))
    when :failed then no_deploy(pipeline, parent_at)
    else unmeasured("could not measure: trigger job #{sel.child.inspect} is #{status.inspect} with no downstream pipeline")
    end
  end

  def child_end(sel, pipeline, bridge, child, parent_at)
    id = bridge.dig("downstream_pipeline", "id")
    return unmeasured("could not measure: child pipeline #{id} was not read") unless child
    unless child["project_id"] && child["project_id"] == pipeline["project_id"]
      return unmeasured("could not measure: #{sel.child.inspect}'s child pipeline #{id} is not in this project")
    end

    status = child["status"]
    case status_class(status)
    when :success
      return Outcome.new(state: :concluded, deploy_at: child["finished_at"], pipeline_at: parent_at) if child["finished_at"]

      unmeasured("could not measure: child pipeline #{id} succeeded with no finished_at")
    when :busy then Outcome.new(state: :busy, reason: "deploy not concluded: child pipeline #{id} is #{status}")
    when :blocked then unmeasured(blocked_reason("child pipeline #{id}"))
    when :failed then no_deploy(pipeline, parent_at)
    else unmeasured("could not measure: child pipeline #{id} has status #{status.inspect}, which this tool does not know")
    end
  end

  # A deploy that did not succeed ends no deploy, as on GitHub. While the
  # parent still runs, its trigger job can be retried, so that is busy.
  def no_deploy(pipeline, parent_at)
    if status_class(pipeline["status"]) == :busy
      return Outcome.new(state: :busy, reason: "deploy not concluded: pipeline #{pipeline['id']} is still " \
                                               "#{pipeline['status']}, and its trigger job can be retried")
    end

    Outcome.new(state: :concluded, deploy_at: nil, pipeline_at: parent_at)
  end

  # A pipeline at `manual` can stay there after its deploy succeeded, so its
  # status says nothing about the deploy (ai/docs/lead-time-tracking.md ->
  # *Why GitLab reads the deploy job*). It is never busy and never concluded.
  def blocked_reason(what)
    "could not measure: #{what} is blocked on a manual job, and a selector reads pipeline status, " \
      "which cannot say whether the deploy finished"
  end
end
