# frozen_string_literal: true

require "time"

# since_rule -- the ONE `--since WHEN` rule (DND-1524).
#
# Which WHEN a lead-time tool accepts. Required by ai/bin/lead-time and
# ai/lib/lead_time_phases_io.rb, so the two tools accept exactly the same
# value without one loading the other's CLI. Pure Domain: no I/O, and nothing
# at the top level but the SinceRule module.
module SinceRule
  # A stamp must carry its zone: Notion returns a start with no offset when the
  # date has a time_zone set, and Time.iso8601 would read that as this
  # machine's local time.
  ZONED_RE = /(Z|[+-]\d\d:?\d\d)\z/.freeze

  DATE_ONLY_RE = /\A(\d{4})-(\d{2})-(\d{2})\z/.freeze
  SINCE_FORMS = "YYYY-MM-DD (00:00:00Z that day) or RFC 3339 with a zone (2026-09-30T22:00:00Z)"

  module_function

  # --since WHEN (DND-1009). -> [utc_iso, nil] or [nil, reason]. A date alone
  # is 00:00:00Z that day. A time must carry its zone: without one, Ruby reads
  # it as this machine's local time. An impossible date is refused rather than
  # rolled over into the next month.
  def parse_since(text)
    s = text.to_s
    if (m = DATE_ONLY_RE.match(s))
      t = Time.utc(m[1].to_i, m[2].to_i, m[3].to_i)
      return [t.iso8601, nil] if t.strftime("%Y-%m-%d") == s
    elsif s.include?("T") && s.match?(ZONED_RE)
      return [Time.iso8601(s).utc.iso8601, nil]
    end
    [nil, "--since #{s.inspect} is not a date or time; it takes #{SINCE_FORMS}"]
  rescue ArgumentError
    [nil, "--since #{s.inspect} is not a date or time; it takes #{SINCE_FORMS}"]
  end
end
