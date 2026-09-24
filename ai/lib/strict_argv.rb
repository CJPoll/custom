# frozen_string_literal: true

# strict_argv — the one argv parser for ai/bin tools that must REFUSE an
# argument they do not recognise rather than ignore it (DND-505).
#
# Why: the ad-hoc `ARGV.index(flag)` / `arg_value` idiom looks up only the
# flags a tool knows about, so everything else is silently dropped. A typo
# (`--rnus 5`, `--corpus-full`) or a value-taking flag with no value
# (`--baseline` at the end of the line) then runs the DEFAULT path and exits 0.
# That is ~/dev/custom/ai/CLAUDE.md -> "A failed lookup must never look like an
# empty one" applied to a command line: a key that matches nothing must be an
# error, never the default.
#
# Contract:
#   * Every argument must be a declared flag. There are no positional
#     arguments; a bare word is refused too.
#   * A value flag takes the NEXT argument as its value. A missing value, or a
#     next argument that starts with "-", is an error naming the flag. So is
#     `--flag=value` (unsupported, and refused rather than guessed at).
#   * An :integer flag's value must be a base-10 integer.
#   * A flag given twice is an error (which one wins would be a guess).
#   * Flag ORDER never matters (~/dev/custom/CLAUDE.md -> Integration).
#
# Pure: no I/O, no process execution. variant-eval's structural-containment
# self-test lexes this file and asserts exactly that.
module StrictArgv
  # Raised with a one-line reason naming the offending argument.
  class UsageError < StandardError; end

  KINDS = %i[switch value integer].freeze

  # spec: { "--flag" => :switch | :value | :integer, ... }
  # -> Hash of the flags present: a switch maps to true, a value flag to its
  #    String, an integer flag to its Integer. Raises UsageError otherwise.
  def self.parse(argv, spec)
    bad = spec.values.uniq - KINDS
    raise ArgumentError, "unknown StrictArgv kind(s) #{bad.inspect}" unless bad.empty?

    opts = {}
    i = 0
    while i < argv.length
      arg = argv[i]
      kind = spec[arg]
      if kind.nil?
        raise UsageError, unknown_reason(arg, spec)
      elsif opts.key?(arg)
        raise UsageError, "#{arg} given more than once"
      elsif kind == :switch
        opts[arg] = true
        i += 1
      else
        opts[arg] = value_for(arg, argv[i + 1], kind)
        i += 2
      end
    end
    opts
  end

  def self.unknown_reason(arg, spec)
    flag, eq, = arg.partition("=")
    if !eq.empty? && spec.key?(flag) && spec[flag] != :switch
      return "#{flag}=VALUE is not supported; pass the value as the next argument (`#{flag} VALUE`)"
    end
    return "unexpected argument #{arg.inspect} (this tool takes no positional arguments)" unless arg.start_with?("-")

    "unknown flag #{arg.inspect}"
  end

  def self.value_for(flag, raw, kind)
    raise UsageError, "#{flag} needs a value" if raw.nil? || raw.empty? || raw.start_with?("-")
    return raw unless kind == :integer
    raise UsageError, "#{flag} needs an integer, got #{raw.inspect}" unless raw.match?(/\A\d+\z/)

    Integer(raw, 10)
  end
end
