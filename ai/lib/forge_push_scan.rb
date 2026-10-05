# frozen_string_literal: true

# forge_push_scan.rb -- the pure rules behind ai/lib/forge-push-scan (DND-2023):
# read what git asks the route's forge transport to push, in either remote-helper
# form, and state it as git's pre-push ref lines, so the transport can hand
# them to the same outbound scan the pre-push hook runs.
#
# Bucket: Domain. No IO, no process, no git. The Manager/Side Effects half is
# ai/lib/forge-push-scan, which resolves refs and runs the scan.
#
# The two forms git uses to push through a remote helper
# (gitremote-helpers(7), transport-helper.c):
#   * the `push` capability (git's own git-remote-https): `list for-push`
#     answers "<oid> <ref>" lines, then git sends "push [+]<src>:<dst>" lines
#     and a blank line. <src> is a local ref name or an object id; an empty
#     <src> deletes <dst>.
#   * the `connect` capability for git-receive-pack: after the server's ref
#     advertisement git sends pkt-lines "<old> <new> <ref>[\0<caps>]\n", then a
#     flush (0000). "shallow <oid>" lines may come first; a "push-cert" line
#     starts a signed push, whose commands this module does not read.
module ForgePushScan
  ZERO = "0" * 40
  OID = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  # A ref update as the pre-push hook reads it.
  Update = Struct.new(:local_ref, :local_oid, :remote_ref, :remote_oid, keyword_init: true)
  # A `push` spec: <src> empty means delete.
  Spec = Struct.new(:force, :src, :dst, keyword_init: true)

  class Unreadable < StandardError; end

  module_function

  # "push [+]<src>:<dst>" (the command word already removed) -> Spec.
  def parse_spec(text)
    force = text.start_with?("+")
    body = force ? text[1..] : text
    src, sep, dst = body.partition(":")
    raise Unreadable, "a push spec with no ':' (#{body.length} bytes)" if sep.empty?
    raise Unreadable, "a push spec with no destination ref" if dst.empty?

    Spec.new(force: force, src: src, dst: dst)
  end

  # `list for-push` answer lines -> {ref => oid}. Attribute lines (":object-format
  # sha1"), symref lines ("@refs/heads/main HEAD") and unknown-value lines
  # ("? <ref>") carry no tip and are skipped.
  def parse_list(lines)
    lines.each_with_object({}) do |line, refs|
      oid, ref = line.chomp.split(" ", 3)
      next unless ref && OID.match?(oid.to_s)

      refs[ref] = oid
    end
  end

  # A `push` spec, its local object id (nil for a delete) and the remote tips
  # -> Update. A remote ref the listing does not name is new: zero.
  def update_for_spec(spec, local_oid, remote_refs)
    zero = zero_like(remote_refs.values.first || local_oid)
    if spec.src.empty?
      Update.new(local_ref: "(delete)", local_oid: zero, remote_ref: spec.dst, remote_oid: remote_refs.fetch(spec.dst, zero))
    else
      raise Unreadable, "the local object for #{spec.dst} is not an object id" unless OID.match?(local_oid.to_s)

      Update.new(local_ref: spec.src, local_oid: local_oid, remote_ref: spec.dst, remote_oid: remote_refs.fetch(spec.dst, zero))
    end
  end

  # One receive-pack command pkt-line payload -> Update, :shallow (skip), or
  # raise Unreadable (a push certificate, or a line that is not a command).
  def parse_command(payload)
    line = payload.split("\0", 2).first.to_s.chomp
    return :shallow if line.start_with?("shallow ")
    raise Unreadable, "a signed push (push-cert), whose commands are not read" if line.start_with?("push-cert")

    old, new, ref = line.split(" ", 3)
    unless OID.match?(old.to_s) && OID.match?(new.to_s) && ref && !ref.empty?
      raise Unreadable, "a receive-pack command that is not '<old> <new> <ref>'"
    end

    deleted = new.match?(/\A0+\z/)
    Update.new(local_ref: deleted ? "(delete)" : new, local_oid: new, remote_ref: ref, remote_oid: old)
  end

  # A 4-byte pkt-line header -> [:flush] / [:delim] / [:end] / [:data, payload_length].
  def pkt_header(hdr)
    raise Unreadable, "a pkt-line header that is not 4 hex digits" unless hdr.is_a?(String) && hdr.match?(/\A[0-9a-f]{4}\z/)

    len = hdr.to_i(16)
    case len
    when 0 then [:flush]
    when 1 then [:delim]
    when 2 then [:end]
    when 3 then raise Unreadable, "a pkt-line of length 3"
    else [:data, len - 4]
    end
  end

  # Updates -> the stdin git gives a pre-push hook.
  def pre_push_stdin(updates)
    updates.map { |u| "#{u.local_ref} #{u.local_oid} #{u.remote_ref} #{u.remote_oid}\n" }.join
  end

  def zero_like(oid)
    oid.to_s.length == 64 ? "0" * 64 : ZERO
  end
end
