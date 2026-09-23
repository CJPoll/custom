# frozen_string_literal: true

# A stand-in for the LV-1 inbox client, for the capture and watchdog suites.
#
# It is RUBY on purpose: inbox-client-capture asserts the client's executable is
# ruby and its cmdline names athena-inbox-client.rb (this file's name does), so
# the suites exercise the real identity check rather than a loosened test seam.
# It opens no socket and touches nothing outside the paths its environment
# names.
#
#   MOCK_MODE       dump   -> on SIGQUIT, after MOCK_DUMP_DELAY s, write an
#                             LV-1-shaped dump into MOCK_DUMP_DIR and log
#                             "diagnostics: wrote <path>" (the real handshake)
#                   ignore -> SIGQUIT is ignored (a handler that cannot run)
#                   exit   -> SIGQUIT makes it exit at once (it dies mid-capture)
#   MOCK_DUMP_DIR   where the dump goes (the client's dump dir)
#   MOCK_LOG        the client log to append the "diagnostics: wrote" line to
#   MOCK_READY      written with this pid once the traps are installed
#   MOCK_TERM_FILE  written with the epoch-ms at which SIGTERM arrived
#   MOCK_TOKEN      embedded in the dump, so redaction can be asserted
#   MOCK_LINE       the line number in the top frame (signature must ignore it)
#   MOCK_STEP       the dump's current_step (default tls)
#   MOCK_FLIGHT_LINES  flight-recorder lines in the dump (default 1); a large
#                   value makes the dump the capture's largest file, so the
#                   size cap truncates it -- and, the recorder coming before
#                   the threads, cuts the frames (DND-334 verify case)

mode = ENV.fetch("MOCK_MODE", "dump")
dump_dir = ENV.fetch("MOCK_DUMP_DIR")
log = ENV.fetch("MOCK_LOG")
term_file = ENV.fetch("MOCK_TERM_FILE")
token = ENV.fetch("MOCK_TOKEN", "")
line = ENV.fetch("MOCK_LINE", "804")
step = ENV.fetch("MOCK_STEP", "tls")
delay = ENV.fetch("MOCK_DUMP_DELAY", "1").to_f

write_dump = lambda do
  now = Time.now.utc
  path = File.join(dump_dir, "#{now.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.txt")
  body = +"== athena-inbox-client diagnostics dump ==\n"
  body << "at: #{now.strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
  body << "pid: #{Process.pid}\n"
  body << "current_step: #{step}\n"
  body << "socket:\n  (no active socket)\n"
  flight = ENV.fetch("MOCK_FLIGHT_LINES", "1").to_i
  body << "flight recorder (#{flight} lines):\n  #{now.strftime('%Y-%m-%dT%H:%M:%S.000Z')} step #{step} begin auth=#{token}\n"
  (flight - 1).times { |i| body << "  #{now.strftime('%Y-%m-%dT%H:%M:%S.000Z')} pad #{i} ................................................\n" }
  body << "threads (3):\n"
  body << "  thread 0x100 status=\"sleep\" name=nil\n"
  body << "    /home/x/athena-inbox-client.rb:#{line}:in `join'\n"
  body << "    /home/x/athena-inbox-client.rb:549:in `with_deadline'\n"
  body << "    /home/x/athena-inbox-client.rb:518:in `timed_step'\n"
  body << "  thread 0x200 status=\"sleep\" name=nil\n"
  body << "    /home/x/athena-inbox-client.rb:#{line}:in `connect_nonblock'\n"
  body << "    /home/x/athena-inbox-client.rb:870:in `tls_handshake'\n"
  body << "    /home/x/athena-inbox-client.rb:804:in `block in open_transport'\n"
  body << "    /home/x/athena-inbox-client.rb:793:in `block in step'\n"
  body << "    /home/x/athena-inbox-client.rb:544:in `block in with_deadline'\n"
  body << "    /home/x/athena-inbox-client.rb:999:in `beyond_top_five'\n"
  body << "  thread 0x300 status=\"run\" name=nil\n"
  body << "    /home/x/athena-inbox-client.rb:600:in `dumper_loop'\n"
  File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |io| io.write(body) }
  File.open(log, "a") { |io| io.puts("#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')} INFO diagnostics: wrote #{path} (#{body.bytesize} bytes)") }
end

case mode
when "dump"
  Signal.trap("QUIT") { Thread.new { sleep(delay); write_dump.call } }
when "ignore"
  Signal.trap("QUIT", "IGNORE")
when "exit"
  # The client dies during the capture window (its pid may then be reused).
  Signal.trap("QUIT") { exit!(1) }
end
Signal.trap("TERM") do
  File.write(term_file, (Time.now.to_f * 1000).round.to_s)
  # MOCK_IGNORE_TERM=1: record the SIGTERM and keep running (a client that
  # does not stop), so the watchdog's SIGKILL escalation can be proven.
  exit!(143) unless ENV["MOCK_IGNORE_TERM"] == "1"
end

File.write(ENV["MOCK_READY"], Process.pid.to_s) if ENV["MOCK_READY"]
sleep
