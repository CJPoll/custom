# frozen_string_literal: true

# ai/lib/private_overlay_resolver.rb -- the SIDE-EFFECT half of the private
# work overlay (DND-702): it reads the environment and the filesystem, and
# hands every decision to the pure rules in ai/lib/private_overlay.rb.
#
# Discovery (contract -> Discovery), one rule, no scanning:
#   1. ATHENA_PRIVATE_ROOT set (even to "") is authoritative. Set-but-invalid
#      is MALFORMED; it never falls through to the default.
#   2. Otherwise $HOME/.config/athena/work. Missing is ABSENT; present but
#      invalid is MALFORMED.
#
# Callers: ai/bin/private-overlay, and ai/bin/outbound-scan (DND-699), which
# needs only the validated root.
#
# Deliberately gem-free (stdlib only).

require "json"
require_relative "private_overlay"

module PrivateOverlay
  module Resolver
    module_function

    # -> Result with state :found (root validated), :absent or :malformed.
    def root(env: ENV)
      if env.key?(ENV_VAR)
        explicit_root(env[ENV_VAR])
      else
        default_root(env["HOME"])
      end
    end

    # -> Result :found with the rendered value, or the failing state.
    # Raises PrivateOverlay::UsageError for a malformed key (nothing is read).
    def get(file, path, env: ENV)
      PrivateOverlay.validate_file!(file)
      segments = PrivateOverlay.parse_path!(path)
      r = root(env: env)
      return r unless r.state == :found

      read_key(r.root, file, path, segments)
    end

    def explicit_root(raw)
      return bad(raw.to_s, "#{ENV_VAR} is set but empty") if raw.nil? || raw.empty?
      return bad(raw, "#{ENV_VAR} is not an absolute path") unless raw.start_with?("/")
      return bad(raw, "#{ENV_VAR} names a path that does not exist") unless File.exist?(raw)

      validate_dir(raw)
    end

    def default_root(home)
      path, why = PrivateOverlay.default_root(home)
      return bad(nil, why) if path.nil?
      return Result.new(state: :absent, root: path, reason: "the default overlay directory does not exist") unless File.exist?(path) || File.symlink?(path)

      validate_dir(path)
    end

    def validate_dir(path)
      return bad(path, "the root is not a directory") unless File.directory?(path)

      real = File.realpath(path)
      st = File.stat(real)
      problem = PrivateOverlay.mode_problem(st.mode, st.uid, Process.uid)
      return bad(real, problem) if problem

      marker = File.join(real, MARKER)
      return bad(real, "marker #{MARKER} is missing") unless File.file?(marker)

      text = read_text(marker)
      return bad(real, "marker #{MARKER} is unreadable") if text.nil?

      problem = PrivateOverlay.marker_problem(text)
      return bad(real, problem) if problem

      Result.new(state: :found, root: real)
    rescue SystemCallError => e
      bad(path, "the root could not be read (#{e.class.name.split('::').last})")
    end

    def read_key(root, file, path, segments)
      rel = "overlay/#{file}.json"
      abs = File.join(root, rel)
      key = "#{file}#{path}"
      return Result.new(state: :key_not_found, root: root, reason: "#{rel} does not exist") unless File.exist?(abs)
      return bad(root, "#{rel} is not a regular file") unless File.file?(abs)

      text = read_text(abs)
      return bad(root, "#{rel} is unreadable") if text.nil?

      doc = begin
        JSON.parse(text)
      rescue JSON::ParserError, EncodingError
        return bad(root, "#{rel} is not valid JSON")
      end

      state, got = PrivateOverlay.dig(doc, segments, file)
      return Result.new(state: state, root: root, reason: got) unless state == :found

      problem = PrivateOverlay.value_problem(got, key)
      return bad(root, problem) if problem

      Result.new(state: :found, root: root, value: PrivateOverlay.render(got))
    end

    def read_text(path)
      File.read(path, mode: "rb").force_encoding(Encoding::UTF_8)
    rescue SystemCallError
      nil
    end

    def bad(root, reason)
      Result.new(state: :malformed, root: root, reason: reason)
    end
  end
end
