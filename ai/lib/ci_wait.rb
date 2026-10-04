# frozen_string_literal: true

# ci_wait.rb -- DOMAIN shared by the fleet's bounded CI waiters:
# ai/bin/gh-ci-wait (GitHub, DND-1708) and ai/bin/glab-ci-wait (GitLab,
# DND-1940). Pure rules, no I/O: the poll cadence and its floor, the backoff,
# the wait decision, splitting an `api -i` response, and validating the keys
# both tools take. Each forge's own rules stay in its own module.
module CiWait
  # The poll floor. Default-cadence watchers (`gh run watch` 3 s, `gh pr
  # checks --watch` 10 s) exhausted the GitHub API budget (DND-1706);
  # `glab ci status --live` is the same shape on GitLab. No waiter reads more
  # often than this.
  MIN_INTERVAL = 30
  DEFAULT_INTERVAL = 60
  # Fits under a 600 s foreground tool call.
  DEFAULT_MAX = 570
  MAX_BACKOFF = 300

  # A usage error: a key that is malformed for its type. Carries its Fix.
  class Usage < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  # A 2xx body that does not hold what the read asked for. Never read as empty.
  class Unreadable < StandardError; end

  module_function

  # split_http(text) -> [status Integer or nil, headers Hash (downcased keys), body String]
  # for the stdout of `gh api -i` or `glab api -i`.
  def split_http(text)
    head, body = text.to_s.split(/\r?\n\r?\n/, 2)
    first, *lines = head.to_s.split(/\r?\n/)
    m = first.to_s.match(%r{\AHTTP/[\d.]+\s+(\d{3})})
    return [nil, {}, ""] unless m

    headers = {}
    lines.each do |line|
      k, v = line.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip if v
    end
    [m[1].to_i, headers, body.to_s]
  end

  # next_wait(read:, now:, deadline:, interval:, errors_in_row:) ->
  # [:sleep, seconds], [:stop] (deadline reached) or [:give_up] (rate limited
  # past the deadline: polling into it only burns the budget, and the caller
  # must say COULD-NOT-LOOK with the reset time).
  #
  # read responds to kind (:ok, :rate_limited, :error, ...) and reset_at. A
  # :rate_limited read waits to its reset. An :ok read that carries a reset_at
  # (the forge said its budget is spent, RateLimit-Remaining: 0) waits to it
  # too, inside the deadline: the state is known, so it never gives up.
  def next_wait(read:, now:, deadline:, interval:, errors_in_row:)
    if read.kind == :rate_limited
      # Never re-read a limit sooner than MIN_INTERVAL: a Retry-After of 0, or
      # a reset our clock already passed, would otherwise poll into the limit
      # once a second, the failure this exists to stop.
      wait = [(read.reset_at - now).ceil, MIN_INTERVAL].max
      return [:give_up] if now + wait > deadline

      return [:sleep, wait]
    end
    left = (deadline - now).floor
    return [:stop] if left <= 0

    base = interval
    base = [interval * (2**[errors_in_row - 1, 4].min), MAX_BACKOFF].min if read.kind == :error && errors_in_row > 1
    base = [base, (read.reset_at - now).ceil].max if read.kind == :ok && read.reset_at
    [:sleep, [base, left].min]
  end

  # ---- argument validation: a wrongly computed key is an error -------------
  def sha!(value)
    v = value.to_s.downcase
    return v if v.match?(/\A[0-9a-f]{40}\z/)

    raise Usage.new("--sha must be a full 40-hex commit sha, got #{value.to_s.inspect}",
                    "pass the pushed head's full sha (git rev-parse HEAD); a prefix can match the wrong commit")
  end

  def interval!(value)
    n = positive_int(value, "--interval")
    return n if n >= MIN_INTERVAL

    raise Usage.new("--interval #{n} is under the #{MIN_INTERVAL} s floor (DND-1706: fast polls exhaust the API budget)",
                    "pass --interval #{MIN_INTERVAL} or more, or omit it for #{DEFAULT_INTERVAL}")
  end

  def positive_int(value, flag)
    v = value.to_s
    return v.to_i if v.match?(/\A\d+\z/) && v.to_i.positive?

    raise Usage.new("#{flag} must be a positive integer, got #{v.inspect}", "pass #{flag} N with N >= 1")
  end
end
