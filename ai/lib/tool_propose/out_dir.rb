# frozen_string_literal: true

# ToolPropose::OutDir -- the pure rule for ai/bin/tool-propose's --out-dir
# (DND-176, PRD R7; adoption-gate state S4). The out-dir is where the recorded
# recommendation lands, so it must be somewhere nothing picks a file up and
# runs or commits it: beneath the temp root or the tool's own state dir, in no
# git work tree, and not under ~/.claude or ~/dev. Checked before anything
# else runs.
#
# Pure: the adapter gathers the facts (realpaths, whether an ancestor holds a
# .git) and passes them in. -> nil when usable, else the reason.
module ToolPropose
  module OutDir
    # facts:
    #   given        the --out-dir argument
    #   realpath     its realpath, or (when absent) its parent's realpath + basename; nil if unresolvable
    #   exists / directory / empty / symlink (the leaf)
    #   private      true when absent, or owned by us with no group/world write bit
    #   git_ancestor the first ancestor (or itself) holding a .git entry, or nil
    #   roots        the allowed roots, as realpaths ([tmp root, state root])
    #   denied       realpaths it must not be under ([~/.claude, ~/dev])
    def self.problem(facts)
      given = facts[:given].to_s
      return "--out-dir #{given.inspect} is not absolute" unless given.start_with?("/")
      return "--out-dir #{given} is a symlink" if facts[:symlink]
      return "--out-dir #{given} exists and is not a directory" if facts[:exists] && !facts[:directory]
      return "--out-dir #{given} exists and is not empty (it must be new or empty)" if facts[:exists] && !facts[:empty]
      unless facts[:private] == true
        return "--out-dir #{given} is not yours alone (another owner, or group/world writable); another user " \
               "could plant a symlink in it"
      end

      real = facts[:realpath]
      return "--out-dir #{given}: its parent does not exist or cannot be resolved" unless real.to_s.start_with?("/")

      denied = Array(facts[:denied]).compact.find { |d| real == d || under?(real, d) }
      return "--out-dir #{given} resolves to #{real}, under #{denied}" if denied

      roots = Array(facts[:roots]).compact
      unless roots.any? { |r| under?(real, r) }
        return "--out-dir #{given} resolves to #{real}, not beneath #{roots.join(' or ')}"
      end
      return "--out-dir #{given} is inside a git work tree (#{facts[:git_ancestor]})" if facts[:git_ancestor]

      nil
    end

    def self.under?(path, root)
      path.start_with?(root.end_with?("/") ? root : "#{root}/")
    end
  end
end
