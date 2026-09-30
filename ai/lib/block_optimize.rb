# frozen_string_literal: true

# BlockOptimize — the pure domain of ai/bin/block-optimize (DND-528, C4-2).
#
# block-optimize turns ONE labeled admiral failure into ONE human-reviewable
# prose diff, plus a scorecard that claims exactly what the landed noise rule
# supports. This file holds every decision that needs no IO:
#
#   Scope     which paths a candidate may touch (an allowlist derived from
#             origin/main's routing.yml) and which it never may (a denylist
#             that wins).
#   Diff      the candidate patch's file headers, and every header shape that
#             is not a plain in-place text edit (rename, copy, new, delete,
#             mode, binary, symlink, path escapes).
#   Evidence  the target case's row in an `admiral-eval --run` output, and the
#             refusals: absent, not a failure, unsampled, a hook, no subject,
#             stale subject.
#   Label     the one honest label, from variant-eval's JSON (DND-527). It
#             never reclassifies: every flip was set by EvalScore.classify.
#   Reference the DND-225 reference band for the target, when comparable.
#   Proposal  the rendered proposal text.
#
# Pure: no IO, no process execution, stdlib + eval_score only. The bin's
# containment self-test lexes this file and asserts that.
#
# Thresholds are NOT this file's: EvalScore (ai/lib/eval_score.rb) owns the
# rule and the envelope. RUNS mirrors variant-eval's DEFAULT_RUNS and the test
# suite reads that constant from variant-eval's source to prove it.

require "yaml"
require_relative "eval_score"

module BlockOptimize
  # N per side: variant-eval's DEFAULT_RUNS (DND-225), which the DND-528 spec
  # pins. Not a new constant; the domain suite asserts the two are equal.
  RUNS = 10
  SCHEMA_ID = "variant-eval/proposal@1"
  ADMIRAL_TEMPLATE = "ai/agents/athena-admiral.md.in"
  ADMIRAL_RENDER = "ai/agents/athena-admiral.md"
  ADMIRAL_CONSUMER = "admiral"
  SAFETY_BLOCK = "ops/safety-checks"

  # Every command string variant-eval's MUTATION_COMMAND_STRINGS names (the
  # suite asserts this is a superset of that list), plus the word this tool's
  # text must never use. Proposal.render redacts any of them that arrives in an
  # untrusted fragment, so the invariant holds structurally.
  MUTATION_COMMAND_STRINGS = [
    "git merge", "git commit", "git push", "git rebase", "git reset",
    "gh pr merge", "gh merge", "glab mr merge", "--update-baseline"
  ].freeze
  FORBIDDEN_WORDS = ["adopted"].freeze

  class Error < StandardError; end
  class ScopeError < Error; end
  class EvidenceError < Error; end

  # -------------------------------------------------------------------------
  # Scope
  # -------------------------------------------------------------------------
  module Scope
    # A path under one of these can hold executable code, a check, a bar, the
    # corpus, the rule, or a registry. The denylist wins over the allowlist.
    DENY_PREFIXES = %w[ai/bin/ ai/hooks/ ai/eval/ ai/lib/ ai/tools/ ai/inbox/ ai/blast-radius/].freeze
    DENY_EXACT = {
      "ai/blocks/ops/safety-checks.md" => "safety-checks (the safety-check bar)",
      "ai/blocks/routing.yml" => "routing.yml (it defines the allowlist)",
      "ai/guard-classification.tsv" => "guard-classification.tsv (a check's table)"
    }.freeze
    RENDER = %r{\Aai/agents/[^/]+\.md\z}
    DENY = (DENY_PREFIXES.map { |p| "#{p}**" } + DENY_EXACT.keys + ["ai/agents/*.md", "**/registry.json"]).freeze
    BLOCK_NAME = %r{\A[a-z0-9_-]+(?:/[a-z0-9_-]+)*\z}

    module_function

    # The admiral template plus ai/blocks/<b>.md for every block routing.yml
    # routes to `admiral`, minus ops/safety-checks. A routing text that does not
    # parse or routes nothing to the admiral RAISES: a failed lookup is never an
    # empty allowlist.
    def allowed_paths(routing_yml_text)
      data = begin
        YAML.safe_load(routing_yml_text.to_s)
      rescue Psych::Exception => e
        raise ScopeError, "routing.yml does not parse (#{e.message.lines.first.to_s.strip}). Fix: block-optimize " \
                          "reads origin/main's ai/blocks/routing.yml; repair it on main (build-agents enforces it)."
      end
      blocks = data.is_a?(Hash) ? data["blocks"] : nil
      unless blocks.is_a?(Hash)
        raise ScopeError, "routing.yml has no `blocks:` map. Fix: origin/main's ai/blocks/routing.yml must map " \
                          "each block to its consumers; block-optimize derives its allowlist from it."
      end
      names = blocks.select { |_b, consumers| consumers.is_a?(Array) && consumers.include?(ADMIRAL_CONSUMER) }.keys
      bad = names.reject { |b| b.is_a?(String) && b.match?(BLOCK_NAME) }
      unless bad.empty?
        raise ScopeError, "routing.yml names block(s) #{bad.inspect} that are not plain block paths. Fix: block " \
                          "names are lowercase path segments such as ops/forge-identity."
      end
      names -= [SAFETY_BLOCK]
      if names.empty?
        raise ScopeError, "routing.yml has no block routed to `admiral` (other than #{SAFETY_BLOCK}). Fix: " \
                          "check origin/main's ai/blocks/routing.yml; an empty allowlist is a failed lookup, " \
                          "not a scope."
      end
      ([ADMIRAL_TEMPLATE] + names.sort.map { |b| "ai/blocks/#{b}.md" }).freeze
    end

    # The denylist family a path falls in, or nil.
    def denied(path)
      prefix = DENY_PREFIXES.find { |p| path.start_with?(p) }
      return "denylisted: under #{prefix}" if prefix
      return "denylisted: #{DENY_EXACT[path]}" if DENY_EXACT.key?(path)
      return "denylisted: a rendered agent (generated by build-agents; edit its .md.in)" if render?(path)
      return "denylisted: a registry.json" if File.basename(path) == "registry.json"

      nil
    end

    def render?(path)
      path.match?(RENDER)
    end

    # [] when every path is allowed, else [[path, reason], ...]. The denylist
    # is checked first, so a denied path injected into `allowed` still fails.
    def violations(paths, allowed)
      paths.filter_map do |path|
        why = denied(path)
        next [path, why] if why
        next [path, "not in the allowlist (#{allowed.join(', ')})"] unless allowed.include?(path)

        nil
      end
    end
  end

  # -------------------------------------------------------------------------
  # Diff
  # -------------------------------------------------------------------------
  module Diff
    FENCE = /^```[ \t]*(?:diff|patch)?[ \t]*\r?\n(.*?)^```[ \t]*$/m
    GIT_LINE = %r{\Adiff --git a/(\S+) b/(\S+)\z}
    HUNK = /\A@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/
    INDEX = /\Aindex [0-9a-f]+\.\.[0-9a-f]+(?: (\d{6}))?\z/
    EXT_VIOLATIONS = [
      [/\Anew file mode/, "a new file (only in-place edits are allowed)"],
      [/\Adeleted file mode/, "a deleted file (only in-place edits are allowed)"],
      [/\A(?:rename (?:from|to)|similarity index)/, "a rename (only in-place edits are allowed)"],
      [/\Acopy (?:from|to)/, "a copy (only in-place edits are allowed)"],
      [/\Adissimilarity index/, "a rewrite (only in-place edits are allowed)"],
      [/\A(?:old|new) mode/, "a mode change (only in-place edits are allowed)"],
      [/\A(?:Binary files|GIT binary patch)/, "a binary patch (only text edits are allowed)"]
    ].freeze

    module_function

    # The patch body, or nil when there is none. fenced: true (the proposer)
    # requires exactly one ```diff fence; fenced: false (--diff FILE) takes the
    # text as the patch. More than one fence returns :many.
    def extract(text, fenced: true)
      return nil if text.nil? || text.strip.empty?
      return text.end_with?("\n") ? text : "#{text}\n" unless fenced

      bodies = text.scan(FENCE).map(&:first)
      return nil if bodies.empty?
      return :many if bodies.size > 1

      body = bodies.first
      body.strip.empty? ? "" : body
    end

    # :no_proposal for blank text or no fenced diff (distinct from a patch with
    # zero files), else { files: [path, ...], violations: [[path, reason], ...] }.
    def headers(text, fenced: true)
      body = extract(text, fenced: fenced)
      return :no_proposal if body.nil?
      return { files: [], violations: [["(patch)", "more than one fenced diff (exactly one candidate per run)"]] } \
        if body == :many

      sections, violations = sections(body.lines.map(&:chomp))
      files = []
      sections.each do |sec|
        path, why = section_path(sec)
        violations.concat(why.map { |w| [path || "(unknown)", w] })
        next unless path

        violations << [path, "the file appears twice in the patch"] if files.include?(path)
        files << path unless files.include?(path)
      end
      violations << ["(patch)", "no file header (`--- a/<path>` / `+++ b/<path>`) in the patch"] if sections.empty?
      { files: files, violations: violations }
    end

    # Split the patch into per-file sections, consuming each hunk by its
    # declared line counts so a removed line that begins "-- " is never read as
    # a file header.
    def sections(lines)
      secs = []
      violations = []
      cur = nil
      i = 0
      while i < lines.size
        l = lines[i]
        if l.start_with?("diff --git ")
          cur = { git: l, ext: [], minus: nil, plus: nil }
          secs << cur
          i += 1
        elsif l.start_with?("--- ") && lines[i + 1].to_s.start_with?("+++ ")
          unless cur && cur[:git] && cur[:minus].nil?
            cur = { git: nil, ext: [], minus: nil, plus: nil }
            secs << cur
          end
          cur[:minus] = l.sub(/\A--- /, "").split("\t").first.to_s
          cur[:plus] = lines[i + 1].sub(/\A\+\+\+ /, "").split("\t").first.to_s
          i += 2
        elsif (m = l.match(HUNK))
          violations << ["(patch)", "a hunk before any file header"] unless cur && cur[:minus]
          i = consume_hunk(lines, i + 1, (m[1] || "1").to_i, (m[2] || "1").to_i, violations)
        elsif cur && cur[:minus].nil?
          cur[:ext] << l
          i += 1
        elsif l.strip.empty?
          i += 1
        else
          violations << ["(patch)", "an unrecognised line outside any hunk: #{l[0, 80].inspect}"]
          i += 1
        end
      end
      [secs, violations]
    end

    def consume_hunk(lines, i, old_left, new_left, violations)
      while (old_left.positive? || new_left.positive?) && i < lines.size
        l = lines[i]
        case l[0]
        when " " then old_left -= 1; new_left -= 1
        when "-" then old_left -= 1
        when "+" then new_left -= 1
        when "\\" then nil
        when nil then old_left -= 1; new_left -= 1 # a blank context line whose space was stripped
        else break
        end
        i += 1
      end
      violations << ["(patch)", "a hunk shorter than its @@ header declares"] if old_left.positive? || new_left.positive?
      i += 1 while i < lines.size && lines[i].start_with?("\\")
      i
    end

    # -> [path_or_nil, [reason, ...]]
    def section_path(sec)
      why = []
      sec[:ext].each do |e|
        next if e.strip.empty?

        idx = e.match(INDEX)
        if (e.start_with?("index ") && idx && idx[1] == "120000") || e.match?(/\A(?:new file|deleted file|old|new) mode 120000/)
          why << "a symlink (only regular text files are allowed)"
          next
        end
        next if idx

        hit = EXT_VIOLATIONS.find { |re, _| e.match?(re) }
        why << (hit ? hit[1] : "an unrecognised extended header #{e[0, 80].inspect}")
      end
      why.uniq!

      git = nil
      if sec[:git]
        git = sec[:git].match(GIT_LINE)
        why << "an unparseable `diff --git` line (paths must be a/<path> b/<path> with no spaces)" unless git
        why << "a/ b/ path mismatch in the `diff --git` line" if git && git[1] != git[2]
      end

      if sec[:minus].nil?
        why << "no `--- a/<path>` / `+++ b/<path>` header" if why.empty?
        return [git && git[2], why]
      end

      why << "a new file (--- /dev/null; only in-place edits are allowed)" if sec[:minus] == "/dev/null"
      why << "a deleted file (+++ /dev/null; only in-place edits are allowed)" if sec[:plus] == "/dev/null"
      old = strip_prefix(sec[:minus], "a/", why)
      new = strip_prefix(sec[:plus], "b/", why)
      why << "a/ b/ path mismatch (#{old} vs #{new})" if old && new && old != new
      why << "the `diff --git` paths disagree with the ---/+++ paths" if git && new && git[2] != new
      path = new || old || (git && git[2])
      [old, new].compact.uniq.each { |p| path_problems(p).each { |w| why << w } }
      [path, why.uniq]
    end

    def strip_prefix(raw, prefix, why)
      return nil if raw == "/dev/null"

      unless raw.start_with?(prefix)
        why << "path #{raw.inspect} is not #{prefix}<repo-relative path> (absolute or unprefixed paths are refused)"
        return nil
      end
      raw.delete_prefix(prefix)
    end

    def path_problems(path)
      probs = []
      probs << "an absolute path" if path.start_with?("/")
      segs = path.split("/", -1)
      probs << "a `..` path segment" if segs.include?("..")
      probs << "a `.` path segment" if segs.include?(".")
      probs << "an empty path segment" if segs.include?("")
      probs
    end
  end

  # -------------------------------------------------------------------------
  # Evidence
  # -------------------------------------------------------------------------
  module Evidence
    # The same `subject:` shape variant-eval's confirm_t2_subject! requires.
    SUBJECT = /^subject: .* sha ([0-9a-f]{12}) \(loaded inline via --agents/
    ROW = %r{\A(PASS|FAIL)\s+(\S+)\s+(\d+)/(\d+)\b(?:\s+\[([^\]]+)\])?\s*(.*)\z}
    T1_MODE = "hook-stdin"
    # admiral-eval (DND-1359) prints this line on every run, 0 included, and
    # marks a row that left a failed model call out of its score.
    FAILURES_LINE = /^admiral-eval: invocation failures: (\d+) model call\(s\)/
    ROW_FAILURE_NOTE = /\d+ invocation failure\(s\)/
    FIX_RUN = "Fix: pass --evidence the saved stdout of `ai/bin/admiral-eval --run --runs 10 --only <case>` run " \
              "at origin/main (with the rendered admiral origin/main carries)."

    module_function

    # -> { case_name:, k:, n:, mode:, detail:, subject_sha12: } or raises
    # EvidenceError with one distinct reason per refusal.
    def parse(text, case_name, runs: RUNS)
      raise EvidenceError, "the evidence file is empty. #{FIX_RUN}" if text.nil? || text.strip.empty?

      shas = text.scan(SUBJECT).flatten.uniq
      raise EvidenceError, "the evidence has no `subject:` line, so it cannot prove which admiral it measured. #{FIX_RUN}" \
        if shas.empty?
      raise EvidenceError, "the evidence has more than one `subject:` sha (#{shas.join(', ')}); it mixes runs. #{FIX_RUN}" \
        if shas.size > 1

      refuse_unmeasured_run!(text)
      rows = text.each_line.filter_map { |l| l.chomp.match(ROW) }
      name = resolve_name(rows.map { |m| m[2] }.uniq, case_name)
      mine = rows.select { |m| m[2] == name }
      raise EvidenceError, "the evidence has more than one row for #{name}; it mixes runs. #{FIX_RUN}" if mine.size > 1

      m = mine.first
      k = m[3].to_i
      n = m[4].to_i
      mode = m[5]
      raise EvidenceError, "#{name}'s row has no [mode] tag, so it is neither T1 nor T2. #{FIX_RUN}" unless mode
      if mode == T1_MODE
        raise EvidenceError, "#{name} is a [#{T1_MODE}] case: a hook's verdict, not admiral prose. Fix: " \
                             "block-optimize edits prose only; fix a hook case in the hook with a normal PR."
      end
      raise EvidenceError, "#{name} scored 0/0: it was never sampled (an unsampled case is not a failure). #{FIX_RUN}" \
        if n.zero?
      if m[6].to_s.match?(ROW_FAILURE_NOTE)
        raise EvidenceError, "#{name}'s row reports model invocation failure(s) (#{m[6].to_s.strip[0, 120]}): " \
                             "the failed samples were not scored, so the row is not a measurement. #{FIX_RUN}"
      end
      if n < runs
        raise EvidenceError, "#{name} scored #{k}/#{n} but the run asked for #{runs} samples per case (#{n} of " \
                             "#{runs}): a sample was left out, so this is a partly unmeasured run, not a " \
                             "measurement. #{FIX_RUN}"
      end
      if k == n
        raise EvidenceError, "#{name} passed #{k}/#{n}: not a failure, nothing to optimize. Fix: pick a case with " \
                             "k < n; if you expected a failure, re-run the evidence (variant-eval re-samples the " \
                             "baseline independently, so a fresh evidence run is legitimate)."
      end
      { case_name: name, k: k, n: n, mode: mode, detail: m[6].to_s.strip, subject_sha12: shas.first }
    end

    # A run that reports failed model calls, or never counted them, measured the
    # invocation (auth, quota, network), not the admiral. Refused for the whole
    # file: DND-1359 leaves a failed call out of the score, so the target row
    # can look clean while the run is partly unmeasured.
    def refuse_unmeasured_run!(text)
      counts = text.scan(FAILURES_LINE).flatten.map(&:to_i)
      if counts.empty?
        raise EvidenceError, "the evidence has no `admiral-eval: invocation failures: N` line, so it cannot prove " \
                             "no model call failed (an uncounted run is not a 0). #{FIX_RUN}"
      end
      return if counts.all?(&:zero?)

      raise EvidenceError, "the evidence reports invocation failures (#{counts.sum} model call(s) failed and were " \
                           "left out of the score): an unmeasured run is not evidence. #{FIX_RUN}"
    end

    # An exact case name, else the unique fixture that starts "<case>-".
    def resolve_name(names, case_name)
      return case_name if names.include?(case_name)

      hits = names.select { |n| n.start_with?("#{case_name}-") }
      return hits.first if hits.size == 1

      if hits.size > 1
        raise EvidenceError, "--case #{case_name} is ambiguous in the evidence (#{hits.join(', ')}). Fix: pass the " \
                             "full fixture name."
      end
      raise EvidenceError, "the evidence has no row for case #{case_name}. #{FIX_RUN}"
    end

    # nil when the evidence measured the render origin/main carries; raises STALE
    # otherwise. render_sha256 is the full sha256 of base:ai/agents/athena-admiral.md.
    def check_subject!(parsed, render_sha256)
      want = render_sha256.to_s[0, 12]
      return nil if parsed[:subject_sha12] == want

      raise EvidenceError, "STALE evidence: it measured admiral sha #{parsed[:subject_sha12]}, but origin/main renders " \
                           "sha #{want}. #{FIX_RUN}"
    end
  end

  # -------------------------------------------------------------------------
  # Label
  # -------------------------------------------------------------------------
  module Label
    class Malformed < StandardError; end

    VERDICTS = %w[keep inconclusive revert blocked unmeasured].freeze
    FLIPS = %w[improved inconclusive regressed missing new n_a].freeze
    REGRESSION_FLIPS = %w[regressed missing].freeze

    module_function

    # -> { label: :rejected | :improvement | :unproven, reason:, target_row:,
    #      others_improved:, headroom:, unmeasured_renders: }
    # Never reclassifies: every flip is variant-eval's, from EvalScore.classify.
    def decide(json, target:, variant_sha:, baseline_sha:, renders_changed:)
      base = { label: :rejected, reason: nil, target_row: nil, others_improved: [], headroom: nil,
               unmeasured_renders: unmeasured_renders(renders_changed) }
      base.merge(judge(json, target, variant_sha, baseline_sha))
    rescue Malformed, EvalScore::InvalidCounts => e
      base.merge(label: :rejected, reason: "malformed variant-eval JSON: #{e.message}")
    end

    def unmeasured_renders(renders_changed)
      Array(renders_changed).select { |p| Scope.render?(p) && p != ADMIRAL_RENDER }
                            .map { |p| File.basename(p, ".md") }.sort
    end

    def judge(json, target, variant_sha, baseline_sha)
      header!(json, variant_sha, baseline_sha)
      case json["verdict"]
      when "blocked"
        return { reason: "BLOCKED: the candidate's harness-gate is red (see scorecard.txt)" }
      when "unmeasured"
        un = json["unmeasured"].is_a?(Hash) ? json["unmeasured"] : {}
        return { reason: "UNMEASURED: the #{un['side'] || '?'} side's #{un['part'] || '?'} run did not measure " \
                         "(see scorecard.txt)" }
      end

      scored!(json)
      if json["verdict"] == "revert"
        raise Malformed, "verdict revert with an empty regressions list" if json["regressions"].empty?

        return { reason: "REVERT: regressions #{json['regressions'].join(', ')}" }
      end
      consistent!(json)
      subj = json["t2_subjects"]
      if subj["base"]["sha256"] == subj["var"]["sha256"]
        return { reason: "the admiral render is unchanged (T2 subjects equal): nothing the corpus can measure" }
      end

      row = json["t2"].find { |r| r["name"] == target }
      raise Malformed, "the target row #{target} is absent from t2" unless row

      target_decision(json, target, row)
    end

    def header!(json, variant_sha, baseline_sha)
      raise Malformed, "not a JSON object" unless json.is_a?(Hash)
      raise Malformed, "schema is #{json['schema'].inspect}, want #{SCHEMA_ID}" unless json["schema"] == SCHEMA_ID
      raise Malformed, "unknown verdict #{json['verdict'].inspect}" unless VERDICTS.include?(json["verdict"])
      raise Malformed, "variant_sha #{json['variant_sha'].inspect} is not this run's candidate #{variant_sha}" \
        unless json["variant_sha"] == variant_sha
      raise Malformed, "baseline_sha #{json['baseline_sha'].inspect} is not this run's base #{baseline_sha}" \
        unless json["baseline_sha"] == baseline_sha
      raise Malformed, "corpus #{json['corpus'].inspect}, want full" unless json["corpus"] == "full"
      raise Malformed, "runs #{json['runs'].inspect}, want #{RUNS}" unless json["runs"] == RUNS
    end

    def scored!(json)
      %w[regressions improvements t2].each do |k|
        raise Malformed, "#{k} is #{json[k].inspect} under verdict #{json['verdict']}" unless json[k].is_a?(Array)
      end
      raise Malformed, "a regressions/improvements entry is not a string" \
        unless (json["regressions"] + json["improvements"]).all?(String)
      det = json["deterministic"]
      raise Malformed, "deterministic is #{det.inspect}" unless det.is_a?(Hash) && %w[regressed fixed].all? { |k| det[k].is_a?(Array) }

      subj = json["t2_subjects"]
      ok = subj.is_a?(Hash) && %w[base var].all? { |s| subj[s].is_a?(Hash) && subj[s]["sha256"].is_a?(String) }
      raise Malformed, "t2_subjects is #{subj.inspect}" unless ok

      json["t2"].each do |r|
        raise Malformed, "a t2 row is #{r.inspect}" unless r.is_a?(Hash) && r["name"].is_a?(String) && FLIPS.include?(r["flip"])
      end
    end

    # A keep/inconclusive verdict whose parts say otherwise is not trusted.
    def consistent!(json)
      raise Malformed, "verdict #{json['verdict']} with regressions #{json['regressions'].inspect}" \
        unless json["regressions"].empty?
      raise Malformed, "verdict #{json['verdict']} with deterministic regressions" unless json["deterministic"]["regressed"].empty?
      bad = json["t2"].select { |r| REGRESSION_FLIPS.include?(r["flip"]) }.map { |r| r["name"] }
      raise Malformed, "a regression flip under a #{json['verdict']} verdict: #{bad.join(', ')}" unless bad.empty?
      if (json["verdict"] == "keep") == json["improvements"].empty?
        raise Malformed, "verdict #{json['verdict']} disagrees with improvements #{json['improvements'].inspect}"
      end
    end

    def target_decision(json, target, row)
      raise Malformed, "the target's baseline side is unmeasured (#{row['base'].inspect})" unless row["base"].is_a?(Hash)
      raise Malformed, "the target's variant side is unmeasured (#{row['var'].inspect})" unless row["var"].is_a?(Hash)

      base = EvalScore.case_score(EvalScore.counts(row["base"]["k"], row["base"]["n"]))
      var = EvalScore.case_score(EvalScore.counts(row["var"]["k"], row["var"]["n"]))
      improved = json["verdict"] == "keep" && row["flip"] == "improved"
      headroom = 1.0 - base[:p]
      {
        label: improved ? :improvement : :unproven,
        reason: nil,
        target_row: { name: target, base: base, var: var, flip: row["flip"] },
        others_improved: json["improvements"] - ["t2:#{target}"],
        headroom: { value: headroom, envelope: EvalScore::PILOT_ENVELOPE,
                    cannot_confirm: headroom - EvalScore::PILOT_ENVELOPE <= EvalScore::ENVELOPE_EPS }
      }
    end
  end

  # -------------------------------------------------------------------------
  # Reference band (DND-225's ai/eval/noise-band.json)
  # -------------------------------------------------------------------------
  module Reference
    module_function

    # -> { k:, n:, p:, lo:, hi: } or [:n_a, why]. Comparable only at the same
    # subject sha; a case the band does not list is a stated miss.
    def band(noise_band, case_name, subject_sha256)
      return [:n_a, "no ai/eval/noise-band.json at the baseline"] if noise_band.nil?
      return [:n_a, "noise-band.json is not a JSON object"] unless noise_band.is_a?(Hash)

      sha = noise_band.dig("comparability", "subject", "sha256")
      return [:n_a, "the band records no subject sha"] unless sha.is_a?(String)
      unless sha == subject_sha256
        return [:n_a, "the band was measured on subject #{sha[0, 8]}, the baseline render is " \
                      "#{subject_sha256.to_s[0, 8]}; re-measure the band after an admiral change"]
      end

      pooled = pooled_for(noise_band["per_case"], case_name)
      return [:n_a, "case not in the band"] unless pooled

      c = EvalScore.parse_rate(pooled)
      return [:n_a, "the band's pooled rate for #{case_name} is 0/0"] unless c

      lo, hi = EvalScore.wilson(c)
      { k: c.k, n: c.n, p: c.k.to_f / c.n, lo: lo, hi: hi }
    rescue EvalScore::InvalidCounts
      [:n_a, "the band's pooled rate for #{case_name} does not parse"]
    end

    def pooled_for(per_case, name)
      return nil unless per_case.is_a?(Hash)

      %w[stochastic deterministic_fail].each do |sec|
        entry = per_case.dig(sec, name)
        return entry["pooled"] if entry.is_a?(Hash) && entry["pooled"]
      end
      stable = per_case["stable_pass"]
      return nil unless stable.is_a?(Hash)
      return stable.dig("each", "pooled") if stable["cases"].is_a?(Array) && stable["cases"].include?(name)

      stable[name].is_a?(Hash) ? stable[name]["pooled"] : nil
    end

    # A MEASURED IMPROVEMENT whose baseline sample lies below the reference
    # band's lower bound is most likely the baseline under-reading.
    def luck_warning?(decision, band)
      decision[:label] == :improvement && band.is_a?(Hash) && decision.dig(:target_row, :base, :p) < band[:lo]
    end
  end

  # -------------------------------------------------------------------------
  # Proposer prompt (the model's output is untrusted data; this is only input)
  # -------------------------------------------------------------------------
  module Prompt
    module_function

    # files: { path => text } for exactly the allowlisted paths.
    def build(case_name:, meta:, scenario:, evidence:, files:, render_lines:)
      observed = if evidence
                   "The admiral passed #{evidence[:k]}/#{evidence[:n]} samples of this case. Failure detail from " \
                     "the scorer: #{evidence[:detail].to_s.empty? ? '(none)' : evidence[:detail]}"
                 else
                   "No evidence run was supplied."
                 end
      parts = []
      parts << "You are improving the PROSE of an AI agent definition, the athena-admiral, so that it handles one " \
               "failing evaluation case correctly without changing how it handles any other case."
      parts << "## The failing case: #{case_name}\n\nThe case's meta (its mode, the actions it forbids and expects):\n" \
               "~~~~\n#{meta}~~~~\n\nThe scenario the admiral is given:\n~~~~\n#{scenario}~~~~\n\n#{observed}"
      parts << "## The files you may edit (ONLY these, in place)\n\n" +
               # A tilde fence, so a block's own ``` fences cannot close it early.
               files.map { |path, text| "### #{path}\n~~~~\n#{text}~~~~" }.join("\n\n")
      parts << "## Constraints\n\n" \
               "- The rendered admiral is #{render_lines} lines and a size check caps it; the budget will not be " \
               "raised. Make the change NET-ZERO lines: pay for every added line by removing or merging one in " \
               "the files above.\n" \
               "- Edit only the files above, in place. No new, deleted, renamed, binary or mode-changed files.\n" \
               "- Some of these blocks are shared with other agents. Keep every edit correct for them too.\n" \
               "- Never weaken a safety rule, a check, or a gate. Make the admiral's instruction clearer; do not " \
               "special-case the scenario's names or ids."
      parts << "## Output\n\nOutput exactly ONE fenced unified diff (```diff ... ```) in git style: a/ and b/ path " \
               "prefixes, correct @@ line counts, enough context lines to apply. Output nothing else."
      "#{parts.join("\n\n")}\n"
    end
  end

  # -------------------------------------------------------------------------
  # Proposal text
  # -------------------------------------------------------------------------
  module Proposal
    LABELS = {
      improvement: "PROPOSED — MEASURED IMPROVEMENT",
      unproven: "PROPOSED — NO MEASURED REGRESSION; IMPROVEMENT UNPROVEN"
    }.freeze
    LUCK = "baseline sample below the reference band — likely sampling luck; re-run before believing it"

    module_function

    # ctx: a Label.decide result (or a cheap-gate rejection) merged with
    # case_name:, base_sha:, variant_sha:, evidence:, out_dir:.
    def render(ctx, band:)
      lines = ["block-optimize: proposal for #{ctx[:case_name]} (propose-only; a human decides)", ""]
      lines << (ctx[:label] == :rejected ? "REJECTED: #{ctx[:reason]}" : LABELS.fetch(ctx[:label]))
      lines << ""
      lines << "baseline:  origin/main #{ctx[:base_sha]}" if ctx[:base_sha]
      if ctx[:variant_sha]
        lines << "candidate: #{ctx[:variant_sha]} (an unreachable commit object; no ref points at it)"
      end
      ev = ctx[:evidence]
      if ev
        lines << "evidence:  #{ev[:case_name]} #{ev[:k]}/#{ev[:n]} [#{ev[:mode]}] on subject #{ev[:subject_sha12]}"
      end
      lines.concat(measured_lines(ctx, band)) unless ctx[:label] == :rejected
      lines << ""
      lines.concat(next_step(ctx))
      redact(lines.join("\n") + "\n")
    end

    def measured_lines(ctx, band)
      t = ctx[:target_row]
      h = ctx[:headroom]
      out = [""]
      out << "target #{t[:name]}: base #{EvalScore.format_score(t[:base])} -> var " \
             "#{EvalScore.format_score(t[:var])}; flip #{t[:flip]}"
      verdict = h[:cannot_confirm] ? "at or below the envelope: the rule cannot confirm a gain for this case at this baseline" : "above the envelope: a gain is confirmable in principle"
      out << format("headroom:  1 - p_base = %.2f vs EvalScore::PILOT_ENVELOPE %.2f, %s", h[:value], h[:envelope], verdict)
      others = ctx[:others_improved]
      out << "other improved cases (not credited to #{t[:name]}): #{others.empty? ? 'none' : others.join(', ')}"
      out << band_line(band)
      out << "WARNING: #{LUCK}" if Reference.luck_warning?(ctx, band)
      renders = ctx[:unmeasured_renders]
      out << (renders.empty? ? "blast radius: none" : "blast radius (non-admiral renders this build changed):")
      renders.each { |r| out << "  UNMEASURED (no behavioral corpus): #{r}" }
      out << ""
      out << "The no-regression gate is a tripwire for large regressions, not a proof: at N=#{RUNS} a small drop " \
             "usually reads inconclusive. Human PR review stays the gate for subtle ones (DND-175, Honest signal)."
      out
    end

    def band_line(band)
      return "reference band: n/a (#{band[1]})" if band.is_a?(Array)
      return "reference band: n/a (not computed)" unless band.is_a?(Hash)

      format("reference band: p=%.2f [%.2f,%.2f] (%d/%d pooled, ai/eval/noise-band.json)",
             band[:p], band[:lo], band[:hi], band[:k], band[:n])
    end

    def next_step(ctx)
      if ctx[:label] == :rejected
        return ["Nothing to review. block-optimize changed no ref and wrote only under #{ctx[:out_dir]}."]
      end

      ["Next step (a human): review #{ctx[:out_dir]}/proposal.diff and the scorecard. To take it, apply the diff",
       "in your own worktree (`git apply #{ctx[:out_dir]}/proposal.diff`) and open a normal PR; the PR runs the",
       "critic and harness-gate. block-optimize changed no ref and wrote only under #{ctx[:out_dir]}."]
    end

    # Untrusted fragments (reasons, evidence detail) can carry any text; the
    # rendered proposal never carries a mutation command or the forbidden word.
    def redact(text)
      (MUTATION_COMMAND_STRINGS + FORBIDDEN_WORDS).reduce(text) { |t, s| t.gsub(s, "[redacted]") }
    end
  end
end
