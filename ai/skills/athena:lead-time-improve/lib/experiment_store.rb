# frozen_string_literal: true

# experiment_store -- the SIDE EFFECT half of scripts/experiment (DND-1478):
# <state>/experiments.jsonl, append-only, one JSON object per line. A record
# row per experiment, then a status row per judgement whose verdict changed
# (latest wins; lib/experiment.rb folds them).
#
# A missing file reads as `exist? == false` with no rows: no experiment has
# been recorded yet. The caller says so in words, so "none recorded" never
# reads the same as "recorded, none pending". An unreadable file raises
# SystemCallError, which the caller reports with Fix:.

require "json"
require "fileutils"

class LeadTimeExperimentStore
  attr_reader :path

  def initialize(path)
    @path = path
  end

  def exist? = File.exist?(path)

  # -> [rows, malformed line count]
  def read
    return [[], 0] unless File.exist?(path)

    rows = []
    bad = 0
    File.foreach(path) do |line|
      next if line.strip.empty?

      r = JSON.parse(line) rescue nil
      r.is_a?(Hash) ? rows << r : bad += 1
    end
    [rows, bad]
  end

  # Append rows under an exclusive lock. When a block is given it is called
  # with the rows read UNDER the lock and returns the rows to append, so a
  # check-then-append (a duplicate id, an admit? refusal) cannot race another
  # writer. -> the rows appended.
  def append(rows = nil)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, File::RDWR | File::CREAT | File::APPEND, 0o600) do |f|
      f.flock(File::LOCK_EX)
      out = block_given? ? yield(read.first) : rows
      out.each { |r| f.write("#{JSON.generate(r)}\n") }
      f.flush
      out
    end
  end
end
