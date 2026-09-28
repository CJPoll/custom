# frozen_string_literal: true

# ai/lib/outbound_mark.rb -- the SIDE-EFFECT probe for "is this machine marked
# as one that holds the private overlay?" (DND-699). Contract:
# ai/contracts/athena-private-overlay.md -> The pre-push hook.
#
# The mark is the outbound pre-push hook in the repository's common git dir,
# as `git rev-parse --git-path hooks/pre-push` resolves it (so core.hooksPath
# is honoured, and a linked worktree or lane resolves to its main checkout's
# hooks). The same rule as gos_machine_marked in ai/lib/gh-outbound-scan.sh.
#
# Three outcomes, never two:
#   :marked    the hook file exists and names the outbound scanner
#   :unmarked  the hook path resolved, and it is absent or another hook
#   :unknown   git could not resolve the path, or the hook cannot be read
# A caller treats :unknown as marked: a failed lookup never reads as "not
# marked" (~/dev/custom/CLAUDE.md -> A failed lookup must never look like an
# empty one).
#
# Deliberately gem-free (stdlib only).

require "open3"

module OutboundMark
  HOOK_MARKERS = %w[outbound-scan outbound-pre-push].freeze

  module_function

  # -> [state, detail]; detail is the hook path, or the reason it is unknown.
  def probe(dir)
    out, st = Open3.capture2("git", "-C", dir, "rev-parse", "--path-format=absolute",
                             "--git-path", "hooks/pre-push", err: File::NULL)
    hook = out.to_s.strip
    return [:unknown, "git could not resolve the pre-push hook path in #{dir}"] unless st.success? && !hook.empty?

    classify(hook)
  rescue SystemCallError => e
    [:unknown, "git could not be run (#{e.class.name.split('::').last})"]
  end

  def classify(hook)
    return [:unmarked, hook] unless File.exist?(hook) || File.symlink?(hook)

    text = File.read(hook)
    HOOK_MARKERS.any? { |m| text.include?(m) } ? [:marked, hook] : [:unmarked, hook]
  rescue SystemCallError, IOError
    [:unknown, "the pre-push hook at #{hook} cannot be read"]
  end
end
