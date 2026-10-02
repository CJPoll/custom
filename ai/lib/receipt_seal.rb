# frozen_string_literal: true

# receipt_seal -- the ONE implementation of how a merge-bar receipt proves who
# wrote it (DND-1814). Both receipt kinds use it:
#   critic       <git dir>/critic-verdicts/<sha>.json, written by
#                ai/bin/critic-review, read by `critic-review --verdict-for`
#                (integration-gate's critic bar, the admiral's merge bar).
#   integration  <git common dir>/integration-receipts/<head>.json, written by
#                integration-gate, read through ai/lib/integration-receipt.sh
#                (locked-merge, gh-athena's merge and push guards, main-health,
#                ready-and-idle) via ai/bin/receipt-seal.
#
# THE DEFECT. Both were plain JSON files that any process could write. A
# receipt hand-written for a head no judge ever ran on read `VERDICT PASS`,
# exit 0 (probe, 2026-10-02). integration-gate runs the branch's own gate
# unsandboxed, so branch code could write one mid-gate, and the gate then read
# it as the judge's.
#
# THE MECHANISM. A writer SEALS its receipt; a reader VERIFIES it, and a
# receipt that does not verify is a refusal, never a pass.
#   producer  {path => git blob sha} of the judge files that wrote it, read
#             from the sealing tree itself (this file's own tree), never from
#             argv: KINDS below names the files per kind.
#   seal      HMAC-SHA256 over the canonical body (every key but "seal",
#             sorted, so field order never matters), under this machine's
#             receipt-seal key, a per-machine secret
#             (ai/contracts/athena-machine-secrets.md; registry entry
#             receipt-seal-key). `ai/bin/receipt-seal init-key` mints it
#             (the installer, run once per machine); the first sealing run
#             mints it where that has not run.
# verify accepts a receipt only when ALL hold:
#   1. it carries a well-formed seal, and this machine's key reproduces it
#      (so a hand-written file, a file edited after sealing, and one sealed on
#      another machine are each refused, each with its own reason);
#   2. every producer blob is the reader's own copy of that file, or a version
#      of it that landed: it appears in the history of refs/remotes/origin/main
#      of the harness repo (the repo this file lives in, else the current
#      repo when this file is a landed copy read out of git into a temp dir).
#      So a receipt written by a branch's edited copy of the judge is refused
#      by every landed reader.
# A state it cannot read (no key, an unsafe key, a git history it cannot
# read) is COULD NOT LOOK: also a refusal, worded apart from "unverified"
# (~/.claude/CLAUDE.md -> "A failed lookup must never look like an empty one").
#
# WHAT IT CLOSES, AND WHAT IT DOES NOT. It closes every receipt that is merely
# WRITTEN: by hand, by a test fixture, by branch code during a gate, copied
# from another head, edited after sealing, or recorded by a branch's edited
# copy of the judge. It does not close DELIBERATE forgery by code running as
# this user. The sealer is an oracle: any such process, a gate step included,
# can run `ai/bin/receipt-seal seal` (or load this file) with the landed tree's
# blobs and this machine's key, and get a receipt every reader accepts. It
# needs no read of the key file to do so. Reading the key and computing the
# HMAC (a machine-secret violation: athena-machine-secrets.md -> "Inspect by
# metadata only"), editing the landed harness code, or moving
# refs/remotes/origin/main by hand do the same. Removing the CLI would not
# change that, since this library is loadable too. Closing it needs a
# privilege boundary that branch code cannot cross: a sealer under another
# uid, or branch code (the gate's own steps and a captain's runs alike) run in
# a sandbox with no access to the key. That is DND-1808, not this file.
#
# OPEN (both are DND-1808's, which stays open; this seal is DND-1814 and does
# not fix DND-1808):
#   (a) the sealer is an oracle to any same-uid process, so deliberate
#       forgery is not closed (above);
#   (b) gen_saas's declared gate needs the docker socket and the network, so
#       it cannot be sandboxed: its branch code runs with full access to the
#       key and the receipt stores.
#
# Also not closed: a sealed receipt can be REPLAYED onto the same head (an
# older PASS restored over a later BLOCK for that exact head); a sealed
# receipt never verifies for a different head, because the head is inside
# the sealed body.

require "json"
require "openssl"
require "digest"
require "fileutils"
require "securerandom"
require "open3"

module ReceiptSeal
  module_function

  ALG = "hmac-sha256"

  # The files whose code decides a receipt of each kind. receipt_seal.rb is in
  # both: it computes the producer and the seal. The integration list is the
  # gate's own judge set, IG_JUDGE_PATHS in integration-gate (the files it
  # materialises from the target before it judges), so a receipt written while
  # any of them was a branch's edit never verifies. The receipt-seal suite
  # asserts the two lists stay equal. Changing either list changes the
  # producer of every new receipt; a receipt sealed under the old list then
  # names the wrong producer files and reads UNVERIFIED, so re-gate open heads.
  KINDS = {
    "critic" => %w[ai/bin/critic-review ai/lib/critic_prompt.rb ai/lib/critic_carry.rb
                   ai/lib/critic_verdict_stores.rb ai/lib/receipt_seal.rb],
    "integration" => %w[ai/skills/athena:merge-boarding/scripts/integration-gate
                        ai/lib/integration-receipt.sh ai/lib/proc-stat.sh ai/lib/telemetry-emit.sh
                        ai/bin/blast-radius ai/blast-radius/surfaces.json ai/lib/owner_turn.rb
                        ai/lib/owner_click.rb ai/bin/critic-review ai/bin/receipt-seal ai/lib/receipt_seal.rb],
  }.freeze

  LANDED_REF = "refs/remotes/origin/main"
  KEY_REL = File.join("harness", "receipt-seal-key")
  SHA40 = /\A[0-9a-f]{40}\z/
  HEX64 = /\A[0-9a-f]{64}\z/
  KEY_ID = /\A[0-9a-f]{16}\z/

  # This file's own tree: <top>/ai/lib/receipt_seal.rb.
  OWN_TOP = File.expand_path("../..", __dir__)

  # A verify outcome. status: :ok, :unverified, or :could_not_look.
  Result = Struct.new(:status, :why, :fix, keyword_init: true) do
    def ok? = status == :ok
  end

  REJUDGE = {
    "critic" => "re-run ~/dev/custom/ai/bin/critic-review at that head in the Mission's worktree " \
                "(integration-gate --with-critic does it for you); it records a sealed verdict",
    "integration" => "re-run ~/dev/custom/ai/bin/integration-gate in the Mission's worktree; " \
                     "it records a sealed receipt on INTEGRATION OK",
  }.freeze

  # --- the key ---------------------------------------------------------------

  # -> [path, nil] or [nil, why]. ${ATHENA_SECRETS_ROOT:-~/.config/athena-secrets}
  # per athena-machine-secrets.md -> "Where". A root that is set but not
  # absolute, or a HOME that cannot be expanded, is an error, never a guess.
  def key_path(env = ENV)
    root = env["ATHENA_SECRETS_ROOT"].to_s
    if root.empty?
      home = env["HOME"].to_s
      return [nil, "HOME is unset or not absolute (#{home.inspect}), so the receipt-seal key cannot be located"] unless home.start_with?("/")

      root = File.join(home, ".config", "athena-secrets")
    end
    return [nil, "ATHENA_SECRETS_ROOT #{root.inspect} is not absolute"] unless root.start_with?("/")

    [File.join(root, KEY_REL), nil]
  end

  # -> [key_bytes, nil] or [nil, why]. The file must be a regular file this
  # user owns, mode 0600 or 0400, in a directory no one else can write, holding
  # 64 hex characters. Its value is never printed, only its metadata.
  def read_key(path)
    st = File.lstat(path)
    return [nil, "the receipt-seal key #{path} is not a regular file"] unless st.file?
    return [nil, "the receipt-seal key #{path} is owned by uid #{st.uid}, not #{Process.uid}"] unless st.uid == Process.uid
    return [nil, format("the receipt-seal key %s has mode %04o, not 0600 or 0400", path, st.mode & 0o7777)] unless [0o600, 0o400].include?(st.mode & 0o7777)

    dst = File.stat(File.dirname(path))
    return [nil, format("the receipt-seal key's directory %s has mode %04o; group or other can write it", File.dirname(path), dst.mode & 0o7777)] unless (dst.mode & 0o022).zero?

    hex = File.read(path).strip
    return [nil, "the receipt-seal key #{path} is malformed (#{hex.size} characters, expected 64 hex)"] unless hex.match?(HEX64)

    [[hex].pack("H*"), nil]
  rescue Errno::ENOENT
    [nil, "no receipt-seal key at #{path}"]
  rescue SystemCallError => e
    [nil, "the receipt-seal key #{path} cannot be read (#{e.class.name.split('::').last})"]
  end

  # Mint the key if it is absent. Exclusive: a key another run minted first is
  # kept. -> [key_bytes, nil] or [nil, why]. `receipt-seal init-key` (the
  # installer) calls this when a person runs it, once per machine after the
  # seal lands; nothing runs it automatically. A sealing run calls it too, as
  # a fallback on a machine where the installer has not run yet. A key planted first by another
  # same-uid process is the same residual as the sealer oracle (see the
  # header): that process could seal directly.
  def ensure_key(path)
    unless File.exist?(path) || File.symlink?(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
      # A random name, so a stale temp file left by a killed run (whose pid
      # was reused) never blocks the mint.
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(8)}"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write("#{SecureRandom.hex(32)}\n") }
        File.link(tmp, path)
      rescue Errno::EEXIST
        nil
      ensure
        FileUtils.rm_f(tmp)
      end
    end
    read_key(path)
  rescue SystemCallError => e
    [nil, "the receipt-seal key #{path} could not be created (#{e.class.name.split('::').last})"]
  end

  def key_id(key) = Digest::SHA256.hexdigest(key)[0, 16]

  # --- the body -----------------------------------------------------------------

  def deep_sort(v)
    case v
    when Hash then v.keys.sort.to_h { |k| [k, deep_sort(v[k])] }
    when Array then v.map { |e| deep_sort(e) }
    else v
    end
  end

  # Every key but "seal", sorted: what the seal covers.
  def canonical(body)
    JSON.generate(deep_sort(body.reject { |k, _| k == "seal" }))
  end

  def mac(key, body) = OpenSSL::HMAC.hexdigest("SHA256", key, canonical(body))

  # git's blob id for a file's bytes, computed without git.
  def blob_sha(path)
    data = File.binread(path)
    Digest::SHA1.hexdigest("blob #{data.bytesize}\0#{data}")
  end

  # -> [{path => blob}, nil] or [nil, why], read from <top>.
  def producer(kind, top = OWN_TOP)
    paths = KINDS[kind] or return [nil, "unknown receipt kind #{kind.inspect}"]
    [paths.to_h { |p| [p, blob_sha(File.join(top, p))] }, nil]
  rescue SystemCallError => e
    [nil, "the producer files under #{top} cannot be read (#{e.message})"]
  end

  # --- seal and verify ------------------------------------------------------------

  # -> [sealed_body, nil] or [nil, why]. The producer is this file's own tree.
  def seal(body, kind, env: ENV, top: OWN_TOP)
    return [nil, "a receipt body must be a JSON object"] unless body.is_a?(Hash)

    prod, why = producer(kind, top)
    return [nil, why] if why

    path, why = key_path(env)
    return [nil, why] if why

    key, why = ensure_key(path)
    return [nil, why] if why

    out = body.reject { |k, _| k == "seal" }.merge("producer" => prod)
    [out.merge("seal" => { "alg" => ALG, "key_id" => key_id(key), "mac" => mac(key, out) }), nil]
  end

  def verify(body, kind, env: ENV, top: OWN_TOP, cwd: Dir.pwd)
    rejudge = REJUDGE.fetch(kind) { return Result.new(status: :could_not_look, why: "unknown receipt kind #{kind.inspect}", fix: "pass --kind critic or --kind integration") }
    unver = ->(why) { Result.new(status: :unverified, why: why, fix: "#{rejudge}. A receipt that does not verify is never a pass.") }
    return unver.call("it is not a JSON object") unless body.is_a?(Hash)

    s = body["seal"]
    unless s.is_a?(Hash) && s["alg"] == ALG && s["key_id"].to_s.match?(KEY_ID) && s["mac"].to_s.match?(HEX64)
      return unver.call("UNSEALED: it carries no #{ALG} seal, so nothing shows a judge wrote it " \
                        "(written by hand, by other code, or before DND-1814)")
    end

    path, why = key_path(env)
    key, why = read_key(path) unless why
    if why
      return Result.new(status: :could_not_look,
                        why: "#{why}, so the seal cannot be checked",
                        fix: "for a missing key, run ~/dev/custom/ai/bin/receipt-seal init-key (it mints this machine's key, " \
                             "and prints only its path, mode and key id); for an unsafe one, fix what is named. Then #{rejudge}. " \
                             "A seal that cannot be checked is never a pass.")
    end
    if s["key_id"] != key_id(key)
      return unver.call("SEALED UNDER ANOTHER KEY (key id #{s['key_id']}, this machine's #{key_id(key)}): " \
                        "another machine's receipt, or one sealed before the key was rotated")
    end
    unless OpenSSL.fixed_length_secure_compare(s["mac"], mac(key, body))
      return unver.call("FORGED OR EDITED: its seal does not match its content")
    end

    producer_result(body["producer"], kind, top, cwd, unver)
  end

  # Is every producer blob the reader's own copy or a landed version?
  def producer_result(prod, kind, top, cwd, unver)
    want = KINDS[kind]
    unless prod.is_a?(Hash) && prod.keys.sort == want.sort && prod.values.all? { |v| v.to_s.match?(SHA40) }
      return unver.call("it names no well-formed producer for #{want.join(', ')}")
    end

    git_dir = nil
    want.each do |p|
      own = begin
        blob_sha(File.join(top, p))
      rescue SystemCallError
        nil
      end
      next if own == prod[p]

      git_dir, why = harness_git_dir(top, cwd) if git_dir.nil?
      landed, why = landed_blobs(git_dir, p) unless why
      if why
        return Result.new(status: :could_not_look,
                          why: "#{p} in its producer is #{prod[p][0, 12]}, not this reader's copy, and whether that version landed is unknown: #{why}",
                          fix: "fetch origin in the harness repo (git fetch origin), then retry; if it still fails, #{REJUDGE[kind]}.")
      end
      next if landed.include?(prod[p])

      return unver.call("PRODUCED BY A JUDGE THAT NEVER LANDED: its #{p} is blob #{prod[p][0, 12]}, " \
                        "neither this reader's copy (#{own ? own[0, 12] : 'unreadable'}) nor any version on " \
                        "#{LANDED_REF} (a branch's edited copy wrote it)")
    end
    Result.new(status: :ok, why: nil, fix: nil)
  end

  CLEAN_GIT_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
                     GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES].to_h { |k| [k, nil] }.freeze

  def git(dir, *args)
    Open3.capture3(CLEAN_GIT_ENV, "git", "-C", dir, *args)
  end

  # The repo whose history says what landed: this file's own checkout, else
  # (a landed copy read out of git into a temp dir) the current repo.
  # -> [git_common_dir, nil] or [nil, why]
  def harness_git_dir(top, cwd)
    [top, cwd].each do |d|
      out, _e, st = git(d, "rev-parse", "--show-toplevel")
      next unless st.success?
      next if d == top && File.realpath(out.strip) != File.realpath(top)

      common, _e, st2 = git(d, "rev-parse", "--path-format=absolute", "--git-common-dir")
      return [common.strip, nil] if st2.success? && common.strip.start_with?("/")
    end
    [nil, "neither #{top} nor #{cwd} is a readable git checkout"]
  rescue SystemCallError => e
    [nil, "git could not be run (#{e.message})"]
  end

  @landed_cache = {}
  class << self
    attr_reader :landed_cache
  end

  # Every blob <path> has had on LANDED_REF's history. -> [Set-like Array, nil] or [nil, why]
  def landed_blobs(git_dir, path)
    key = [git_dir, path]
    return [ReceiptSeal.landed_cache[key], nil] if ReceiptSeal.landed_cache.key?(key)

    _o, _e, st = Open3.capture3(CLEAN_GIT_ENV, "git", "--git-dir=#{git_dir}", "rev-parse", "--verify", "-q", "#{LANDED_REF}^{commit}")
    return [nil, "#{LANDED_REF} does not resolve in #{git_dir}"] unless st.success?

    out, err, st = Open3.capture3(CLEAN_GIT_ENV, "git", "--git-dir=#{git_dir}", "log", "--format=", "--raw",
                                  "--no-abbrev", "--no-renames", LANDED_REF, "--", path)
    return [nil, "git log #{LANDED_REF} -- #{path} failed in #{git_dir} (#{err.strip})"] unless st.success?

    blobs = out.each_line.flat_map { |l| l.split("\t", 2).first.to_s.split(" ")[2, 2] || [] }
               .select { |b| b.match?(SHA40) && b != "0" * 40 }.uniq
    # A judge file with NO history on the landed ref means this is not the
    # harness repo (the cwd fallback found another repo) or the file never
    # landed at all: the search could not answer, so it is never read as
    # "that version never landed".
    return [nil, "#{path} has no history on #{LANDED_REF} in #{git_dir}, so it is not the harness repo's landed history"] if blobs.empty?

    ReceiptSeal.landed_cache[key] = blobs
    [blobs, nil]
  rescue SystemCallError => e
    [nil, "git could not be run (#{e.message})"]
  end
end
