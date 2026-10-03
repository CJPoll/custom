# frozen_string_literal: true

# dispatch_trackers_overlay -- EFFECTS: read the work tracker's values from the
# private overlay (DND-1341) and hand them to DispatchTrackers.work_from.
#
# Reads in-process through PrivateOverlay::Resolver, the same rules as
# `ai/bin/private-overlay get`. The first key that does not resolve ends the
# read; its resolver line (state, key, root, Fix:) is the reason. The one
# exception is an OPTIONAL key that is not present (DND-1838's
# .work.restart_dispatch_from): it reads as undeclared, and mark-in-progress
# names it when that matters. A value is never logged or echoed.

require_relative "dispatch_trackers"
require_relative "private_overlay_resolver"

module DispatchTrackers
  module Overlay
    module_function

    # -> DispatchTrackers::Resolution. fault is false only for ABSENT.
    def work(env: ENV)
      values = {}
      WORK_KEYS.each do |name, path|
        r = PrivateOverlay::Resolver.get(OVERLAY_FILE, path, env: env)
        unless r.state == :found
          return Resolution.new(tracker: nil, fault: r.state != :absent,
                                reason: PrivateOverlay.failure_line(r, "#{OVERLAY_FILE}#{path}"))
        end

        values[name] = r.value
      end
      # An optional key that is not present is undeclared (nil). Any other
      # miss (a malformed file, say) is the same fault as a required key's.
      OPTIONAL_WORK_KEYS.each do |name, path|
        r = PrivateOverlay::Resolver.get(OVERLAY_FILE, path, env: env)
        next if r.state == :key_not_found
        unless r.state == :found
          return Resolution.new(tracker: nil, fault: true,
                                reason: PrivateOverlay.failure_line(r, "#{OVERLAY_FILE}#{path}"))
        end

        values[name] = r.value
      end
      DispatchTrackers.work_from(values)
    end
  end
end
