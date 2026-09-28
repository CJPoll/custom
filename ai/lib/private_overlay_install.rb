# frozen_string_literal: true

# ai/lib/private_overlay_install.rb -- the pure rules of the private overlay
# installer, scripts/setup-private-overlay (DND-703). No I/O: the adapter
# (ai/lib/private_overlay_install_host.rb) observes the machine, and these
# functions turn an observation into verdicts, a plan, or text.
#
# Three things are installed, each judged on its own:
#   marketplace  the local plugin marketplace `custom-work`, whose source is
#                the overlay root;
#   plugin       `work@custom-work`, installed and enabled at user scope;
#   hook         the main checkout's git pre-push hook, a small wrapper that
#                execs the main checkout's ai/git-hooks/outbound-pre-push.sh.
#
# Every verdict keeps "missing" and "could not look" apart
# (~/dev/custom/CLAUDE.md -> "A failed lookup must never look like an empty
# one"): a `claude` list that does not parse is UNMEASURED, never MISSING.
#
# Deliberately gem-free (stdlib only).

require "json"
require "shellwords"

module PrivateOverlayInstall
  MARKETPLACE = "custom-work"
  PLUGIN = "work"
  PLUGIN_ID = "#{PLUGIN}@#{MARKETPLACE}".freeze

  # The first line after the shebang of every hook this installer writes. It
  # is how the installer recognises its own hook (to refresh or remove it) and
  # tells it from a hook someone else wrote, which it never overwrites.
  HOOK_MARKER = "# athena-outbound-pre-push: installed by scripts/setup-private-overlay (DND-703)."
  HOOK_SCRIPT = "ai/git-hooks/outbound-pre-push.sh"
  SCANNER = "ai/bin/outbound-scan"

  EXIT = { ok: 0, usage: 1, gap: 1, absent: 3, unmeasured: 3, malformed: 4, conflict: 5 }.freeze

  # One component's verdict. state is a symbol; detail is printable text that
  # never carries an overlay value (only paths, ids and states).
  Verdict = Struct.new(:component, :state, :detail, keyword_init: true) do
    def ok?
      state == :ok
    end

    def unmeasured?
      state == :unmeasured
    end
  end

  module_function

  # --- parsing `claude ... --json` output -------------------------------------

  # -> [Array, nil] or [nil, reason]. A list that is not a JSON array of
  # objects is unreadable, never an empty list.
  def parse_list(text, what)
    doc = JSON.parse(text.to_s)
    return [nil, "#{what} did not print a JSON array"] unless doc.is_a?(Array)
    return [nil, "#{what} printed an array holding a non-object"] unless doc.all? { |e| e.is_a?(Hash) }

    [doc, nil]
  rescue JSON::ParserError, EncodingError
    [nil, "#{what} did not print valid JSON"]
  end

  # --- verdicts ---------------------------------------------------------------

  # overlay: a PrivateOverlay::Result from the resolver.
  def overlay_verdict(result)
    case result.state
    when :found then Verdict.new(component: "overlay", state: :ok, detail: "root=#{result.root}")
    when :absent then Verdict.new(component: "overlay", state: :absent, detail: "probed=#{result.root}")
    else Verdict.new(component: "overlay", state: :malformed, detail: "reason=#{result.reason}")
    end
  end

  # marketplaces: parsed `claude plugin marketplace list --json`, or nil with
  # a reason. root: the validated overlay root, or nil when there is none.
  def marketplace_verdict(marketplaces, reason, root)
    return Verdict.new(component: "marketplace", state: :unmeasured, detail: reason) if marketplaces.nil?

    entry = marketplaces.find { |m| m["name"] == MARKETPLACE }
    return Verdict.new(component: "marketplace", state: :missing, detail: "#{MARKETPLACE} is not registered") if entry.nil?

    path = entry["path"] || entry["installLocation"]
    if entry["source"] != "directory" || path.nil?
      return Verdict.new(component: "marketplace", state: :conflict,
                         detail: "#{MARKETPLACE} is registered from source #{entry['source'].inspect}, not the overlay directory")
    end
    # With no validated root there is nothing to compare the path with, so the
    # marketplace cannot be vouched for as ours. That is UNVERIFIED, never OK:
    # an OK here would let --remove delete a marketplace it may not have added.
    if root.nil?
      return Verdict.new(component: "marketplace", state: :unverified,
                         detail: "#{MARKETPLACE} is registered from #{path}, but with no valid overlay root it cannot be confirmed as this overlay's")
    end
    unless same_path?(path, root)
      return Verdict.new(component: "marketplace", state: :conflict,
                         detail: "#{MARKETPLACE} is registered from #{path}, not the overlay root #{root}")
    end

    Verdict.new(component: "marketplace", state: :ok, detail: "#{MARKETPLACE} -> #{path}")
  end

  # plugins: parsed `claude plugin list --json`, or nil with a reason.
  def plugin_verdict(plugins, reason)
    return Verdict.new(component: "plugin", state: :unmeasured, detail: reason) if plugins.nil?

    # This installer manages the USER-scope install only; a project- or
    # local-scope copy is someone else's and does not count as installed.
    matches = plugins.select { |p| p["id"] == PLUGIN_ID }
    entry = matches.find { |p| p["scope"] == "user" }
    if entry.nil?
      other = matches.map { |p| p["scope"].to_s }.uniq
      detail = other.empty? ? "#{PLUGIN_ID} is not installed" : "#{PLUGIN_ID} is not installed at user scope (only at: #{other.join(', ')})"
      return Verdict.new(component: "plugin", state: :missing, detail: detail)
    end
    return Verdict.new(component: "plugin", state: :disabled, detail: "#{PLUGIN_ID} is installed but disabled") unless entry["enabled"] == true

    Verdict.new(component: "plugin", state: :ok, detail: "#{PLUGIN_ID} enabled (scope #{entry['scope'] || 'unknown'})")
  end

  # hook: the observed hook file. obs keys:
  #   :path     resolved hook path, or nil (then :why says why)
  #   :content  file content, :none when absent, :unreadable when it cannot be read
  #   :main     the main checkout directory
  #   :scanner  { ready: true/false, detail: "..." } from the scanner probe
  def hook_verdict(obs)
    return Verdict.new(component: "hook", state: :unmeasured, detail: obs[:why]) if obs[:path].nil?

    path = obs[:path]
    case classify_hook(obs[:content], obs[:main])
    when :absent
      Verdict.new(component: "hook", state: :missing, detail: "NOT ACTIVE: no pre-push hook at #{path}")
    when :unreadable
      Verdict.new(component: "hook", state: :unmeasured, detail: "#{path} exists but cannot be read")
    when :foreign
      Verdict.new(component: "hook", state: :conflict, detail: "NOT ACTIVE: #{path} holds a pre-push hook this installer did not write")
    when :stale
      Verdict.new(component: "hook", state: :stale, detail: "NOT ACTIVE: #{path} is this installer's hook but targets another checkout")
    else
      scanner = obs[:scanner] || { ready: false, detail: "the scanner was not probed" }
      if scanner[:ready]
        Verdict.new(component: "hook", state: :ok, detail: "#{path} -> #{File.join(obs[:main], HOOK_SCRIPT)}")
      else
        Verdict.new(component: "hook", state: :inert,
                    detail: "NOT ACTIVE: #{path} is installed but the scanner cannot measure, so every push is refused: #{scanner[:detail]}")
      end
    end
  end

  # -> :absent, :unreadable, :ours, :stale (ours, other target) or :foreign.
  def classify_hook(content, main)
    return :absent if content == :none
    return :unreadable if content == :unreadable
    return :foreign unless content.to_s.lines.any? { |l| l.chomp == HOOK_MARKER }

    content == hook_body(main) ? :ours : :stale
  end

  # The scanner probe: the main checkout's scanner run on an empty file. Only
  # a CLEAN line with exit 0 means it can measure; a waiver, COULD NOT
  # MEASURE, or anything else is not ready.
  def scanner_ready(status, stdout)
    first = stdout.to_s.lines.first.to_s.strip
    return { ready: true, detail: first } if status.zero? && first.include?(": CLEAN ")

    { ready: false, detail: first.empty? ? "the scanner printed nothing (exit #{status})" : "#{first} (exit #{status})" }
  end

  # --- the hook --------------------------------------------------------------

  def hook_body(main)
    target = File.join(main, HOOK_SCRIPT)
    <<~SH
      #!/bin/sh
      #{HOOK_MARKER}
      # Runs the main checkout's landed outbound-pre-push.sh, which runs
      # ai/bin/outbound-scan --pre-push. If the target is missing, exec fails
      # and git refuses the push. Remove with scripts/setup-private-overlay --remove.
      exec #{Shellwords.escape(target)} "$@"
    SH
  end

  # --- check ------------------------------------------------------------------

  CHECK_LABEL = {
    ok: "OK", absent: "ABSENT", malformed: "MALFORMED", missing: "MISSING",
    disabled: "DISABLED", conflict: "CONFLICT", stale: "STALE", inert: "INERT", unverified: "UNVERIFIED",
    unmeasured: "COULD NOT MEASURE"
  }.freeze

  def check_line(verdict)
    label = verdict.component == "hook" && !verdict.ok? && !verdict.unmeasured? ? "NOT ACTIVE" : CHECK_LABEL.fetch(verdict.state)
    detail = verdict.detail.to_s.sub(/\ANOT ACTIVE: /, "")
    "#{verdict.component}: #{label}#{detail.empty? ? '' : " (#{detail})"}"
  end

  # -> exit code for --check: 0 all OK, 3 any unmeasured, else 1.
  def check_exit(verdicts)
    return EXIT[:ok] if verdicts.all?(&:ok?)
    return EXIT[:unmeasured] if verdicts.any?(&:unmeasured?)

    EXIT[:gap]
  end

  # The one Fix line per non-OK verdict. `installer` is the command to name.
  def fix_for(verdict, installer:)
    case [verdict.component, verdict.state]
    in ["overlay", :absent]
      "Fix: the overlay directory is missing, so work-domain features are unavailable on this machine. The owner creates it with `#{installer} --init`."
    in ["overlay", :malformed]
      "Fix: correct the overlay per ai/contracts/athena-private-overlay.md -> Discovery and Marker; `ai/bin/private-overlay status` names the defect."
    in ["marketplace", :missing] | ["plugin", :missing] | ["plugin", :disabled]
      "Fix: run `#{installer} --install`."
    in ["marketplace", :conflict]
      "Fix: another marketplace named #{MARKETPLACE} is registered. Remove it with `claude plugin marketplace remove #{MARKETPLACE}`, then run `#{installer} --install`."
    in ["marketplace", :unverified]
      "Fix: restore the overlay first (see the overlay line); or, if #{MARKETPLACE} should go regardless, run `claude plugin uninstall #{PLUGIN_ID}` and `claude plugin marketplace remove #{MARKETPLACE}` yourself."
    in ["plugin", :conflict]
      "Fix: this installer did not install it from this overlay; if it should go, run `claude plugin uninstall #{PLUGIN_ID}` yourself."
    in ["hook", :missing] | ["hook", :stale]
      "Fix: run `#{installer} --install` once the scanner can measure (at least one pattern committed in the overlay's outbound/patterns.tsv)."
    in ["hook", :inert]
      "Fix: commit at least one pattern to the overlay's outbound/patterns.tsv, or remove the hook with `#{installer} --remove`."
    in ["hook", :conflict]
      "Fix: the existing pre-push hook is not this installer's; merge it by hand or move it aside, then run `#{installer} --install`."
    in [_, :unmeasured]
      "Fix: make the named read work (install the `claude` CLI on PATH, run inside the ~/dev/custom checkout), then re-run `#{installer} --check`."
    else
      "Fix: run `#{installer} --check` and follow its output."
    end
  end

  # --- install plan ------------------------------------------------------------

  # -> array of [action, *args]. :refuse entries name a gap the installer will
  # not close by itself; everything else is a change it makes.
  def install_plan(marketplace:, plugin:, hook:, root:, hook_ready:)
    plan = []
    case marketplace.state
    when :missing then plan << [:marketplace_add, root]
    when :conflict, :unmeasured, :unverified then plan << [:refuse, marketplace]
    end

    # The plugin is installed only from OUR marketplace. When custom-work is
    # registered from elsewhere (or could not be read), installing
    # work@custom-work would pull a plugin from a source this installer did not
    # vouch for; the marketplace refusal above already names the gap.
    marketplace_usable = %i[ok missing].include?(marketplace.state)
    case plugin.state
    when :missing then plan << [:plugin_install, PLUGIN_ID] if marketplace_usable
    when :disabled then plan << [:plugin_enable, PLUGIN_ID] if marketplace_usable
    when :unmeasured then plan << [:refuse, plugin]
    end

    case hook.state
    when :missing, :stale
      plan << (hook_ready[:ready] ? [:hook_write, hook.state == :stale ? :replace : :create] :[:refuse, Verdict.new(component: "hook", state: :inert, detail: "NOT ACTIVE: the hook is not installed because the scanner cannot measure: #{hook_ready[:detail]}")])
    when :conflict, :unmeasured, :inert then plan << [:refuse, hook]
    end
    plan
  end

  # --- remove plan -------------------------------------------------------------

  def remove_plan(marketplace:, plugin:, hook:)
    plan = []
    plan << [:hook_delete] if %i[ok inert stale].include?(hook.state)
    plan << [:refuse, hook] if %i[conflict unmeasured].include?(hook.state)
    # Uninstall the plugin only when it came from OUR marketplace. From a
    # custom-work registered elsewhere (or one that could not be read), it is
    # not this installer's to remove.
    if %i[ok disabled].include?(plugin.state)
      plan << (marketplace.state == :ok ? [:plugin_uninstall, PLUGIN_ID] : [:refuse, Verdict.new(component: "plugin", state: :conflict, detail: "#{PLUGIN_ID} is installed, but #{MARKETPLACE} is not this overlay's marketplace (#{CHECK_LABEL.fetch(marketplace.state)}), so it is left in place")])
    end
    plan << [:refuse, plugin] if plugin.unmeasured?
    # Keep the marketplace while the plugin list is unreadable: removing it
    # could strand an installed plugin whose source no longer exists.
    plan << [:marketplace_remove, MARKETPLACE] if marketplace.state == :ok && !plugin.unmeasured?
    plan << [:refuse, marketplace] if %i[conflict unmeasured unverified].include?(marketplace.state)
    plan
  end

  def same_path?(a, b)
    File.expand_path(a.to_s).chomp("/") == File.expand_path(b.to_s).chomp("/")
  end
end
