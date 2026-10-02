# frozen_string_literal: true

# LeadTimeObserveMarkers -- SIDE EFFECTS: the per-run observe record
# (DND-1820), one file per run and repo: <runs>/<run>.observe.<repo>.json.
# `unmeasurable observe` and `unmeasurable ingest-failed` write it; the cron
# runner reads it back through `unmeasurable check` after the session.
#
# Written whole through a temp file, fsync and a rename, mode 0600. The
# record's content is the domain's (LeadTimeUnmeasurable.observed_marker,
# .ingest_failed_marker, .read_marker); this class only stores bytes.
#
# Only ENOENT is "no record": a file or directory that cannot be opened, or
# a file that is not JSON, is Unreadable, never "not recorded"
# (~/dev/custom/ai/CLAUDE.md -> A failed lookup must never look like an
# empty one). The caller has already checked the run id and repo name
# (LeadTimeUnmeasurable.run_id, .repo_name), so neither can hold a "/".

require "json"

class LeadTimeObserveMarkers
  class Unreadable < StandardError; end

  attr_reader :runs_dir

  def initialize(runs_dir)
    @runs_dir = runs_dir
  end

  def path(run, repo) = File.join(runs_dir, "#{run}.observe.#{repo}.json")

  # -> the parsed record, or nil when there is none.
  def read(run, repo)
    file = path(run, repo)
    text = begin
      File.read(file)
    rescue Errno::ENOENT
      return nil
    end
    JSON.parse(text)
  rescue JSON::ParserError => e
    raise Unreadable, "#{file} is not JSON (#{e.message[0, 80]})"
  rescue SystemCallError => e
    raise Unreadable, "cannot read #{file}: #{e.message}"
  end

  def write(run, repo, doc)
    Dir.mkdir(runs_dir, 0o700) unless Dir.exist?(runs_dir)
    file = path(run, repo)
    tmp = File.join(runs_dir, ".#{File.basename(file)}.#{Process.pid}.tmp")
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.generate(doc))
      f.write("\n")
      f.flush
      f.fsync
    end
    File.chmod(0o600, tmp)
    File.rename(tmp, file)
    file
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end
end
