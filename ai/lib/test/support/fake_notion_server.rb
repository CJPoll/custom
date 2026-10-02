# frozen_string_literal: true

# A fake Notion for the retry suites (DND-1519, DND-1649): a one-connection-
# at-a-time HTTP/1.1 server on 127.0.0.1. Each request takes the next
# scripted reply; once the script is spent, the last reply repeats. Bodies are
# written as raw bytes, so a raw UTF-8 JSON body reaches the client unescaped
# and a locale-dependent read cannot hide behind it (DND-1054).
#
# Shared by ai/test/lead-time/notion_retry_test.rb (NextMissionNotion's
# HttpTransport, over Net::HTTP) and ai/lib/test/notion-read/notion_read_test.rb
# (NotionRead, over curl), so both clients are proven against one server.

require "socket"

class FakeNotionServer
  Reply = Struct.new(:status, :body, :headers, keyword_init: true)

  attr_reader :requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @script = []
    @requests = []
    @lock = Mutex.new
    @thread = Thread.new { serve }
  end

  def base
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def script(*replies)
    @lock.synchronize do
      @script = replies
      @requests = []
    end
  end

  def close
    @server.close
    @thread.join(5)
  end

  private

  def serve
    loop do
      client = @server.accept
      begin
        handle(client)
      rescue IOError, SystemCallError
        nil # one dropped connection must not stop the server
      ensure
        client.close
      end
    end
  rescue IOError, SystemCallError
    nil # the server was closed
  end

  def handle(client)
    line = client.gets or return
    headers = {}
    while (h = client.gets) && h != "\r\n"
      k, v = h.split(":", 2)
      headers[k.downcase] = v.to_s.strip
    end
    body = client.read(headers["content-length"].to_i)
    reply = @lock.synchronize do
      @requests << { line: line.strip, headers: headers, body: body }
      @script.size > 1 ? @script.shift : @script.first
    end
    payload = reply.body.b
    head = +"HTTP/1.1 #{reply.status} Scripted\r\n"
    head << "Content-Type: application/json; charset=utf-8\r\n"
    head << "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n"
    (reply.headers || {}).each { |k, v| head << "#{k}: #{v}\r\n" }
    client.write(head, "\r\n", payload)
  end
end
