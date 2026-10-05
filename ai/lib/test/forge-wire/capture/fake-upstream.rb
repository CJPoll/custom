# frozen_string_literal: true

# fake-upstream.rb -- the capture half of the forge-wire fixtures (DND-2025).
#
# A local stand-in for api.github.com, uploads.github.com and gitlab.com. It
# is an HTTPS proxy (CONNECT) that terminates TLS itself with a throwaway CA,
# answers every request from a scenario's canned responses, and records each
# request's exact bytes. It NEVER connects anywhere: there is no upstream
# socket in this file. Run only by ai/bin/forge-wire-capture (see its --help).
#
# Usage: ruby fake-upstream.rb <work dir> <responses.json> <out dir>
#   writes <work dir>/ca.pem, then <work dir>/port (the ready signal);
#   writes <out dir>/NN-<host>.http, one file per request, in arrival order.
#
# responses.json: [{"method":"POST","host":"gitlab.com","path":"regex",
#   "body":"substring, [substrings] (all must appear) or null","status":201,"json":{...}}, ...]; the first
#   match wins. No match: GET/HEAD 404, a GraphQL POST 200 with
#   {"data":{}}, any other method 201 with {}.

require "openssl"
require "socket"
require "json"
require_relative "../../../forge_wire/request"

work, responses_file, out = ARGV
abort "usage: fake-upstream.rb <work dir> <responses.json> <out dir>. Fix: run it through ai/bin/forge-wire-capture." unless out

ROUTES = JSON.parse(File.read(responses_file))
FORGE_HOSTS = %w[api.github.com uploads.github.com gitlab.com].freeze

ca_key = OpenSSL::PKey::EC.generate("prime256v1")
ca = OpenSSL::X509::Certificate.new
ca.version = 2
ca.serial = 1
ca.subject = ca.issuer = OpenSSL::X509::Name.parse("/CN=forge-wire fixture CA")
ca.public_key = ca_key
ca.not_before = Time.now - 60
ca.not_after = Time.now + 3600
ef = OpenSSL::X509::ExtensionFactory.new(ca, ca)
ca.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
ca.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
ca.sign(ca_key, OpenSSL::Digest.new("SHA256"))
File.write(File.join(work, "ca.pem"), ca.to_pem)

LEAVES = {}
LOCK = Mutex.new
def leaf(host, ca, ca_key)
  LOCK.synchronize do
    LEAVES[host] ||= begin
      k = OpenSSL::PKey::EC.generate("prime256v1")
      c = OpenSSL::X509::Certificate.new
      c.version = 2
      c.serial = rand(1 << 64)
      c.subject = OpenSSL::X509::Name.parse("/CN=#{host}")
      c.issuer = ca.subject
      c.public_key = k
      c.not_before = Time.now - 60
      c.not_after = Time.now + 3600
      f = OpenSSL::X509::ExtensionFactory.new(c, ca)
      c.add_extension(f.create_extension("subjectAltName", "DNS:#{host}", false))
      c.add_extension(f.create_extension("extendedKeyUsage", "serverAuth", false))
      c.sign(ca_key, OpenSSL::Digest.new("SHA256"))
      [c, k]
    end
  end
end

$seq = 0
def record(out, host, bytes)
  n = LOCK.synchronize { $seq += 1 }
  File.binwrite(File.join(out, format("%02d-%s.http", n, host)), bytes)
end

def respond(req)
  route = ROUTES.find do |r|
    r["method"] == req.method && r["host"] == req.host && Regexp.new(r["path"]).match?(req.path) &&
      Array(r["body"]).all? { |part| req.body.include?(part) }
  end
  return [route["status"], JSON.generate(route["json"])] if route
  return [404, '{"message":"Not Found"}'] if %w[GET HEAD].include?(req.method)
  return [200, '{"data":{}}'] if req.path.end_with?("/graphql")

  [201, "{}"]
end

def read_head(io)
  lines = []
  while (l = io.gets("\r\n"))
    l = l.chomp("\r\n")
    break if l.empty?

    lines << l
  end
  lines
end

def serve(tls, host, out)
  buf = +"".b
  loop do
    begin
      req = ForgeWire::Request.parse(buf, host: host, max_body: 16 * 1024 * 1024)
    rescue ForgeWire::Incomplete
      chunk = tls.readpartial(65_536)
      buf << chunk
      next
    end
    record(out, host, buf.byteslice(0, req.consumed))
    buf = buf.byteslice(req.consumed..)
    status, body = respond(req)
    tls.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
  end
rescue EOFError, IOError, OpenSSL::SSL::SSLError, Errno::ECONNRESET
  nil
rescue ForgeWire::Unparseable => e
  warn "fake-upstream: unparseable request on #{host}: #{e.message}"
end

srv = TCPServer.new("127.0.0.1", 0)
File.write(File.join(work, "port"), srv.addr[1].to_s)

loop do
  sock = srv.accept
  Thread.new(sock) do |s|
    head = read_head(s)
    target = head.first.to_s.split(" ")[1].to_s
    host = target.split(":").first.to_s.downcase
    unless head.first.to_s.start_with?("CONNECT ") && FORGE_HOSTS.include?(host)
      warn "fake-upstream: refused #{head.first.inspect}"
      s.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
      next
    end
    s.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    cert, key = leaf(host, ca, ca_key)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = cert
    ctx.key = key
    ctx.alpn_protocols = ["http/1.1"]
    ctx.alpn_select_cb = ->(protos) { protos.include?("http/1.1") ? "http/1.1" : nil }
    tls = OpenSSL::SSL::SSLSocket.new(s, ctx)
    tls.sync_close = true
    tls.accept
    serve(tls, host, out)
  rescue StandardError => e
    warn "fake-upstream: #{e.class}: #{e.message}"
  ensure
    s.close rescue nil
  end
end
