# frozen_string_literal: true

# ForgeWire::Request (DND-2025): HTTP/1.1 framing as data. Every malformed
# shape is Unparseable (the proxy refuses it); a request that has not fully
# arrived is Incomplete (the proxy reads more). The two must never be confused:
# an Incomplete read as Unparseable refuses a good request, and an Unparseable
# read as Incomplete hangs.

require "zlib"
require "stringio"
require_relative "helper"
require_relative "../../forge_wire/request"

R = ForgeWire::Request
H = "api.example.test"

def parse(bytes, host: H, max_body: 1024)
  R.parse(bytes, host: host, max_body: max_body)
end

def unparseable?(bytes, msg = nil, **kw)
  raises?(ForgeWire::Unparseable, msg) { parse(bytes, **kw) }
end

def incomplete?(bytes)
  raises?(ForgeWire::Incomplete) { parse(bytes) }
end

# --- the plain cases ---------------------------------------------------------
get = parse(http("GET /repos/o/r?per_page=1 HTTP/1.1", "Host: #{H}", "Accept: */*"))
check("GET method") { get.method == "GET" }
check("GET path is the raw path before ?") { get.path == "/repos/o/r" }
check("GET query is the raw text after ?") { get.query == "per_page=1" }
check("GET host is the caller's host") { get.host == H }
check("GET body is empty") { get.body == "".b }
check("GET consumed is the whole request") { get.consumed == http("GET /repos/o/r?per_page=1 HTTP/1.1", "Host: #{H}", "Accept: */*").bytesize }
check("header lookup is case-insensitive") { get.header("accept") == "*/*" }
check("absent header is nil") { get.header("content-type").nil? }
check("no ? means a nil query") { parse(http("GET /x HTTP/1.1", "Host: #{H}")).query.nil? }
check("an empty query is the empty string, not nil") { parse(http("GET /x? HTTP/1.1", "Host: #{H}")).query == "" }

post = parse(http("POST /graphql HTTP/1.1", "Host: #{H}", "Content-Length: 5", "Content-Type: application/json", body: "hello"))
check("Content-Length body") { post.body == "hello".b }
check("content type") { post.content_type == "application/json" }

check("Host header with :443 matches the CONNECT host") do
  parse(http("GET / HTTP/1.1", "Host: #{H}:443")).host == H
end
check("Host compares case-insensitively") { parse(http("GET / HTTP/1.1", "Host: API.Example.Test")).host == H }

# Trailing bytes are the next request on a keep-alive connection.
two = http("GET /a HTTP/1.1", "Host: #{H}") + http("GET /b HTTP/1.1", "Host: #{H}")
first = parse(two)
check("consumed stops at the end of the first request") { first.path == "/a" && first.consumed < two.bytesize }
check("the rest parses as the next request") { parse(two.byteslice(first.consumed..)).path == "/b" }

# --- chunked -----------------------------------------------------------------
chunked = http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked",
               body: "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n")
check("chunked body is joined") { parse(chunked).body == "hello world".b }
check("chunked consumed is exact") { parse(chunked).consumed == chunked.bytesize }
check("chunked with a trailer field is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked", body: "1\r\na\r\n0\r\nX-T: 1\r\n\r\n"), "trailer")
end
check("chunked with a bad size line is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked", body: "zz\r\nhello\r\n0\r\n\r\n"))
end
check("chunked data not followed by CRLF is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked", body: "2\r\nabc\r\n0\r\n\r\n"))
end
check("chunked, partial, is Incomplete") do
  incomplete?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked", body: "5\r\nhel"))
end
check("Transfer-Encoding other than chunked is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: gzip, chunked", body: "0\r\n\r\n"), "Transfer-Encoding")
end
check("both Content-Length and Transfer-Encoding are refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Length: 5", "Transfer-Encoding: chunked", body: "0\r\n\r\n"))
end
check("two Content-Length headers are refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Length: 1", "Content-Length: 1", body: "a"))
end
check("a Content-Length that is not digits is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Length: +1", body: "a"))
end

# --- incomplete --------------------------------------------------------------
check("no blank line yet is Incomplete") { incomplete?("GET / HTTP/1.1\r\nHost: #{H}\r\n".b) }
check("a short body is Incomplete") do
  incomplete?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Length: 10", body: "abc"))
end
check("empty input is Incomplete") { incomplete?("".b) }
# RFC 9112 2.2 lets a server ignore one empty line before the request line.
# This judge refuses it instead: gh and glab never send one, and a refusal
# fails closed where a tolerance is one more rule two parsers could disagree on.
check("an empty head (CRLF CRLF) is Unparseable, naming the empty request line") { unparseable?("\r\n\r\n".b, "request line is empty") }
check("a leading empty line before a request is Unparseable") do
  unparseable?("\r\n".b + http("GET / HTTP/1.1", "Host: #{H}"), "request line is empty")
end
check("a lone CRLF is Unparseable, not Incomplete (no more bytes can fix it)") { unparseable?("\r\n".b, "request line is empty") }

# --- refused shapes ----------------------------------------------------------
check("HTTP/1.0 is refused") { unparseable?(http("GET / HTTP/1.0", "Host: #{H}"), "HTTP/1.1") }
check("the HTTP/2 preface is refused") { unparseable?("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".b) }
check("absolute-form target is refused") { unparseable?(http("GET https://#{H}/x HTTP/1.1", "Host: #{H}")) }
check("a fragment in the target is refused") { unparseable?(http("GET /x#y HTTP/1.1", "Host: #{H}")) }
check("a method that is not a token is refused") { unparseable?(http("G(T / HTTP/1.1", "Host: #{H}")) }
check("bare LF line endings are refused") { unparseable?("GET / HTTP/1.1\nHost: #{H}\n\n".b) }
check("a missing Host is refused") { unparseable?(http("GET / HTTP/1.1", "Accept: x")) }
check("two Host headers are refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}", "Host: #{H}")) }
check("a Host that is not the CONNECT host is refused") { unparseable?(http("GET / HTTP/1.1", "Host: other.test"), "Host") }
check("a Host on another port is refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}:8443")) }
check("an obs-fold header line is refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}", "X-A: 1", " folded")) }
check("a header line with no colon is refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}", "nocolon")) }
check("whitespace before the colon is refused") { unparseable?(http("GET / HTTP/1.1", "Host : #{H}")) }
check("Upgrade is refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}", "Upgrade: websocket"), "Upgrade") }
check("Connection: upgrade is refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}", "Connection: Upgrade")) }
check("Expect: 100-continue is accepted") do
  parse(http("POST /x HTTP/1.1", "Host: #{H}", "Expect: 100-continue", "Content-Length: 1", body: "a")).body == "a"
end
check("another Expect is refused") { unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Expect: x", "Content-Length: 0")) }
check("a body over the cap is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Length: 2000", body: "a" * 2000), "cap")
end
check("a chunked body over the cap is refused") do
  big = "800\r\n#{"a" * 0x800}\r\n0\r\n\r\n"
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked", body: big), "cap")
end
check("a header block over the cap is refused, not Incomplete forever") do
  raises?(ForgeWire::Unparseable) { R.parse(("GET / HTTP/1.1\r\nX: " + "a" * 70_000).b, host: H, max_body: 10) }
end
check("a NUL in a header value is refused") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}", "X: a\0b")) }
check("a NUL at the end of a header value is refused, not stripped") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Length: 1\0", body: "a"))
end
check("a vertical tab after the Host is refused, not stripped") { unparseable?(http("GET / HTTP/1.1", "Host: #{H}\v")) }
check("a header value's spaces and tabs are trimmed") { parse(http("GET / HTTP/1.1", "Host: \t#{H} \t")).host == H }
check("a tab between request-line parts is refused") { unparseable?(http("GET\t/ HTTP/1.1", "Host: #{H}")) }
check("two spaces between request-line parts are refused") { unparseable?(http("GET  / HTTP/1.1", "Host: #{H}")) }
check("a leading space on the request line is refused") { unparseable?(http(" GET / HTTP/1.1", "Host: #{H}")) }
check("a control byte in a chunk extension is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Transfer-Encoding: chunked", body: "1;a\x01b\r\na\r\n0\r\n\r\n"))
end

# --- Content-Encoding ---------------------------------------------------------
gz = StringIO.new("".b)
w = Zlib::GzipWriter.new(gz)
w.write("zipped text")
w.close
gzbody = gz.string
check("gzip request body is decoded") do
  parse(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: gzip", "Content-Length: #{gzbody.bytesize}", body: gzbody)).body == "zipped text"
end
dfl = Zlib::Deflate.deflate("deflated text")
check("deflate request body is decoded") do
  parse(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: deflate", "Content-Length: #{dfl.bytesize}", body: dfl)).body == "deflated text"
end
check("identity encoding is accepted") do
  parse(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: identity", "Content-Length: 1", body: "a")).body == "a"
end
check("br encoding is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: br", "Content-Length: 1", body: "a"), "Content-Encoding")
end
check("stacked encodings are refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: gzip, gzip", "Content-Length: 1", body: "a"))
end
check("a corrupt gzip body is refused") do
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: gzip", "Content-Length: 3", body: "abc"))
end
check("a gzip body that inflates past the cap is refused") do
  io = StringIO.new("".b)
  z = Zlib::GzipWriter.new(io)
  z.write("a" * 5000)
  z.close
  unparseable?(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: gzip", "Content-Length: #{io.string.bytesize}", body: io.string), "cap")
end

check("the raw body is kept beside the decoded one") do
  r = parse(http("POST /x HTTP/1.1", "Host: #{H}", "Content-Encoding: deflate", "Content-Length: #{dfl.bytesize}", body: dfl))
  r.raw_body == dfl
end

finish("forge-wire request")
