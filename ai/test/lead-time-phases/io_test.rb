# frozen_string_literal: true

# IO suite for ai/lib/lead_time_phases_io.rb (DND-1477). Every case runs in a
# temp dir; no real store, ledger or repo is read. Functional only (DND-1222).
# Each reader has a MISS case: "could not look" must read differently from
# "looked, found nothing". Ids are synthetic.

require "json"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../lib/lead_time_phases_io"

IO_ = LeadTimePhasesIO

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

HEAD = "c" * 40

Dir.mktmpdir("ltp-io-") do |tmp|
  # ── LedgerStore ──
  ledger = IO_::LedgerStore.new(File.join(tmp, "state", "ledger.jsonl"))
  row = { "repo" => "custom", "landed_commit" => HEAD, "ticket" => "DND-9001", "x" => 1 }
  check("I1 a missing ledger reads as no rows") { ledger.read == [[], 0] }
  check("I1 the first append adds the row") { ledger.append([row]) == [1, 0] }
  check("I1 the same (landed_commit, ticket) twice gives one line") { ledger.append([row.merge("x" => 2)]) == [0, 1] }
  check("I1 the ledger holds one line") { File.readlines(ledger.path).size == 1 }
  check("I1 another ticket on the same commit is its own row") { ledger.append([row.merge("ticket" => "DND-9002")]) == [1, 0] }
  File.write(ledger.path, "not json\n", mode: "a")
  check("I1 a malformed line is counted, not dropped silently") { ledger.read[1] == 1 }

  # ── LedgerStore#replace (DND-1490 --rejoin) ──
  rj = IO_::LedgerStore.new(File.join(tmp, "rejoin", "ledger.jsonl"))
  archive = File.join(tmp, "rejoin", "ledger-replaced.jsonl")
  sq = { "repo" => "custom", "mode" => "improve", "landed_via" => "merge", "landed_commit" => HEAD, "ticket" => "DND-9001" }
  done = sq.merge("ticket" => "DND-9002", "gated_head" => "d" * 40)
  push = sq.merge("ticket" => "DND-9003", "landed_via" => "push", "gated_head" => HEAD)
  unlisted = sq.merge("ticket" => "DND-9005")
  headless = sq.merge("ticket" => "DND-9006")
  measured = sq.merge("ticket" => "DND-9007", "phases" => { "implement" => { "s" => 60 } })
  other_repo = sq.merge("repo" => "gen_saas")
  rj.append([sq, done, push, unlisted, headless, measured, other_repo])
  File.write(rj.path, "not json\n", mode: "a")
  joined = sq.merge("gated_head" => "d" * 40, "phases" => { "merge" => { "s" => 1 } })
  replacements = { %w[custom] + [HEAD, "DND-9001"] => joined,
                   %w[custom] + [HEAD, "DND-9002"] => done.merge("x" => 2),
                   %w[custom] + [HEAD, "DND-9003"] => push.merge("landed_via" => "merge", "x" => 3),
                   %w[custom] + [HEAD, "DND-9006"] => headless.merge("gated_head" => nil, "gated_head_na" => "no head"),
                   %w[custom] + [HEAD, "DND-9007"] => measured.merge("gated_head" => "d" * 40,
                                                                     "phases" => { "implement" => { "s" => nil } }) }
  outcomes = rj.replace(replacements, archive, repo: "custom")
  by = outcomes.to_h { |v, row, _| [row["ticket"], v] }
  check("J3 every rejoinable row of the repo gets a verdict") do
    by == { "DND-9001" => :replace, "DND-9005" => :not_in_scan, "DND-9006" => :no_head, "DND-9007" => :would_lose }
  end
  lines = File.readlines(rj.path)
  check("J3 the ledger keeps every line, in order") { lines.size == 8 && lines[7] == "not json\n" }
  check("J3 the replaced row now carries its head") { JSON.parse(lines[0]) == joined }
  check("J3 every other row is untouched") do
    lines[1..6].map { |l| JSON.parse(l) } == [done, push, unlisted, headless, measured, other_repo]
  end
  check("J3 the replaced original is archived, never dropped") do
    File.readlines(archive).map { |l| JSON.parse(l) } == [sq]
  end
  again = rj.replace(replacements, archive, repo: "custom")
  check("J3 a second rejoin replaces nothing (idempotent)") { again.none? { |v, _, _| v == :replace } }
  check("J3 and archives nothing more") { File.readlines(archive).size == 1 }
  check("J3 an empty plan writes nothing") do
    rj.replace({}, archive, repo: "custom").all? { |v, _, _| v == :not_in_scan } && File.readlines(rj.path).size == 8
  end
  check("J3 the ledger keeps its mode, and no temp file is left") do
    (File.stat(rj.path).mode & 0o777) == 0o644 && Dir.children(File.dirname(rj.path)).none? { |n| n.include?(".tmp.") }
  end

  # A writer that opened the ledger before a rename locks the unlinked old
  # file: it must see that and reopen, or its append is lost.
  rl = IO_::LedgerStore.new(File.join(tmp, "race", "ledger.jsonl"))
  rl.append([sq])
  stale = File.open(rl.path, File::RDWR | File::APPEND)
  check("J4 an open ledger is live before a rename") { rl.live?(stale) }
  rl.replace({ %w[custom] + [HEAD, "DND-9001"] => joined }, File.join(tmp, "race", "ledger-replaced.jsonl"), repo: "custom")
  check("J4 after replace renames, the old handle is not live") { !rl.live?(stale) }
  opens = 0
  rl.define_singleton_method(:open_ledger) do
    opens += 1
    opens == 1 ? stale : super()
  end
  check("J4 an append holding the stale handle reopens and lands in the live ledger") do
    rl.append([sq.merge("ticket" => "DND-9004")]) == [1, 0] && opens == 2 &&
      File.readlines(rl.path).any? { |l| l.include?("DND-9004") }
  end
  check("J4 the stale handle was closed") { stale.closed? }

  # ── CursorStore ──
  cur = IO_::CursorStore.new(File.join(tmp, "state"), "custom")
  check("I2 no cursor reads nil without an error") { cur.read == [nil, nil] }
  cur.write("2026-10-01T05:00:00Z")
  check("I2 a written cursor reads back") { cur.read == ["2026-10-01T05:00:00Z", nil] }
  File.write(cur.path, "yesterday\n")
  check("I2 a malformed cursor is an error, never 'no cursor'") { v, why = cur.read; v.nil? && why.include?("not an RFC 3339 time") }

  # ── ReceiptReader ──
  common = File.join(tmp, "repo.git")
  FileUtils.mkdir_p(common)
  check("I3 a missing store dir: could not look") { IO_::ReceiptReader.read(common, HEAD).status == :could_not_look }
  FileUtils.mkdir_p(File.join(common, "integration-receipts"))
  check("I3 a store without that head: empty") { IO_::ReceiptReader.read(common, HEAD).status == :empty }
  File.write(File.join(common, "integration-receipts", "#{HEAD}.json"), JSON.generate("recorded_at" => "2026-10-01T04:00:00Z"))
  check("I3 the head's receipt is read") { IO_::ReceiptReader.read(common, HEAD).items.first["recorded_at"] == "2026-10-01T04:00:00Z" }
  File.write(File.join(common, "integration-receipts", "#{'d' * 40}.json"), "{")
  check("I3 an unreadable receipt: could not look") { IO_::ReceiptReader.read(common, "d" * 40).status == :could_not_look }

  # ── VerdictReader ──
  check("I4 a relative common dir: could not look") { IO_::VerdictReader.read("repo.git", HEAD).status == :could_not_look }
  check("I4 no receipt in any store: empty, naming the stores searched") do
    s = IO_::VerdictReader.read(common, HEAD)
    s.status == :empty && s.reason.include?("1 store(s)")
  end
  wt = File.join(common, "worktrees", "wt-a", "critic-verdicts")
  FileUtils.mkdir_p(wt)
  File.write(File.join(wt, "#{HEAD}.json"), JSON.generate("verdict" => "pass", "at" => "2026-10-01T03:00:00Z"))
  check("I4 a verdict in a worktree store is found") { IO_::VerdictReader.read(common, HEAD).items.map { |v| v["verdict"] } == ["pass"] }
  main = File.join(common, "critic-verdicts")
  FileUtils.mkdir_p(main)
  other = "e" * 40
  File.write(File.join(main, "#{other}.json"), JSON.generate("verdict" => "block", "at" => "2026-10-01T03:00:00Z"))
  check("I4 a verdict in the main store is found") { IO_::VerdictReader.read(common, other).items.map { |v| v["verdict"] } == ["block"] }

  # ── TimingsReader ──
  tfile = File.join(tmp, "timings.jsonl")
  check("I5 no timings file: could not look") { IO_::TimingsReader.read(tfile, [HEAD])[0][HEAD].status == :could_not_look }
  File.write(tfile, "#{JSON.generate('head' => HEAD, 'label' => 'x', 'wall_s' => 1.0)}\n#{JSON.generate('head' => other, 'label' => 'y', 'wall_s' => 2.0)}\nnot json\n")
  got, bad = IO_::TimingsReader.read(tfile, [HEAD, "f" * 40])
  check("I5 a malformed timings line is counted") { bad == 1 }
  check("I5 rows are filtered by head") { got[HEAD].items.map { |r| r["label"] } == ["x"] }
  check("I5 a head with no rows: empty") { got["f" * 40].status == :empty }
  check("I5 the default path honours XDG_STATE_HOME") do
    IO_::TimingsReader.path("XDG_STATE_HOME" => "/s", "HOME" => "/h") == "/s/athena/harness-gate/timings.jsonl"
  end

  # ── TelemetryReader ──
  src, = IO_::TelemetryReader.read("ATHENA_TELEMETRY_DIR" => File.join(tmp, "no-store"), "HOME" => tmp)
  check("I6 no telemetry store: could not look") { src.status == :could_not_look && src.reason.include?("no telemetry store") }
  store = File.join(tmp, "tel")
  FileUtils.mkdir_p(store, mode: 0o700)
  src, = IO_::TelemetryReader.read("ATHENA_TELEMETRY_DIR" => store, "HOME" => tmp)
  check("I6 an empty store: ok with no events (looked, found nothing)") { src.status == :ok && src.items.empty? }
  File.write(File.join(store, "2026-10-01.jsonl"),
             "#{JSON.generate('event' => 'telemetry.probe', 'at' => '2026-10-01T01:00:00Z')}\n" \
             "#{JSON.generate('event' => 'harness_gate.run', 'at' => '2026-10-01T01:00:00Z', 'unit' => 'DND-9001')}\n")
  src, = IO_::TelemetryReader.read("ATHENA_TELEMETRY_DIR" => store, "HOME" => tmp)
  check("I6 telemetry.probe is never read as a phase event") { src.items.map { |e| e["event"] } == ["harness_gate.run"] }
  # DND-1531: the origin check reads every kind.
  all, = IO_::TelemetryReader.read_all("ATHENA_TELEMETRY_DIR" => store, "HOME" => tmp)
  check("I10 read_all keeps every kind") { all.items.map { |e| e["event"] } == %w[telemetry.probe harness_gate.run] }
  check("I10 MISS: read_all of no store is could not look") do
    IO_::TelemetryReader.read_all("ATHENA_TELEMETRY_DIR" => File.join(tmp, "no-store"), "HOME" => tmp)[0].could_not_look?
  end

  locked = File.join(store, "2026-10-02.jsonl")
  File.write(locked, "#{JSON.generate('event' => 'harness_gate.run', 'at' => '2026-10-02T01:00:00Z')}\n")
  File.chmod(0o000, locked)
  src, = IO_::TelemetryReader.read("ATHENA_TELEMETRY_DIR" => store, "HOME" => tmp)
  check("I6 a partial read keeps no events: could not look, never a partial count") do
    src.status == :could_not_look && src.items.empty? && src.reason.include?("could not read")
  end
  File.chmod(0o600, locked)

  # ── TicketFor ──
  check("I7 a push row's own ticket wins, even nil") { IO_::TicketFor.call("ticket" => nil, "branch" => "dnd-9001-x") == [nil, nil] }
  check("I7 a PR row's ticket comes from its branch") { IO_::TicketFor.call("branch" => "dnd-9001-some-change", "title" => "x") == ["DND-9001", nil] }
  check("I7 then from its title") { IO_::TicketFor.call("branch" => "fix-things", "title" => "DND-9002: a title") == ["DND-9002", nil] }
  check("I7 none named: nil, and no fault") { IO_::TicketFor.call("branch" => "fix-things", "title" => "a title") == [nil, nil] }
  refs = AthenaTelemetry::TicketRefs.singleton_class
  refs.alias_method(:real_parser, :parser)
  refs.define_method(:parser) { nil }
  begin
    check("I7 a parser that cannot load is could-not-look, never unticketed") do
      t, why = IO_::TicketFor.call("branch" => "dnd-9001-x", "title" => "x")
      t.nil? && why.include?("did not load")
    end
  ensure
    refs.alias_method(:parser, :real_parser)
  end

  # ── LeadTimeLib ──
  check("I8 --since uses lead-time's own rule") { IO_::LeadTimeLib.parse_since("2026-10-01") == ["2026-10-01T00:00:00Z", nil] }
  check("I8 an impossible date is refused with a reason") { v, why = IO_::LeadTimeLib.parse_since("2026-02-30"); v.nil? && why.include?("not a date") }

  # ── RevertCounter ──
  repo = File.join(tmp, "gitrepo")
  check("I9 a path with no repo: could not look") { IO_::RevertCounter.count(repo, "2026-01-01", "2027-01-01").status == :could_not_look }
  FileUtils.mkdir_p(repo)
  genv = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.invalid",
           "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.invalid",
           "GIT_AUTHOR_DATE" => "2026-10-01T02:00:00Z", "GIT_COMMITTER_DATE" => "2026-10-01T02:00:00Z" }
  Open3.capture3(genv, "git", "-C", repo, "init", "-q", "-b", "main")
  ["DND-9001: a change", 'Revert "DND-9001: a change"'].each do |msg|
    Open3.capture3(genv, "git", "-C", repo, "commit", "-q", "--allow-empty", "-m", msg)
  end
  check("I9 a revert on main in the window is counted") do
    IO_::RevertCounter.count(repo, "2026-10-01T00:00:00Z", "2026-10-01T05:00:00Z").items.size == 1
  end
  check("I9 outside the window: zero, looked") do
    s = IO_::RevertCounter.count(repo, "2026-10-02T00:00:00Z", "2026-10-03T00:00:00Z")
    s.status == :ok && s.items.empty?
  end
end

if $failures.empty?
  puts "lead-time-phases io: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "lead-time-phases io: #{$failures.size} of #{$checks} checks failed"
exit 1
