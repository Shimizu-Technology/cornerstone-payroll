# frozen_string_literal: true

require "date"
require "json"
require "time"
require "tempfile"

module LocalCertificationPolicyFixture
  module_function

  def build(now: Time.now)
    # Pick a genuine future cutoff with at least a day's margin. PostgreSQL's
    # revision clock remains real, so initial revision writes precede this cutoff.
    today = now.getlocal("+10:00").to_date
    month = Date.new(today.year, today.month, 1)
    previous_payday, cutoff = (-1..3).flat_map do |offset|
      first = month >> offset
      [Date.new(first.year, first.month, 15), first.next_month - 1]
    end.sort.filter_map do |payday|
      date = payday + 7
      time = Time.new(date.year, date.month, date.day, 17, 0, 0, "+10:00")
      [payday, time] if time >= now + 86_400
    end.first
    raise "No future certification cutoff" unless cutoff

    start_date = previous_payday.day == 15 ? Date.new(previous_payday.year, previous_payday.month, 1) :
      Date.new(previous_payday.year, previous_payday.month, 16)
    target_payday = scheduled_payday(previous_payday)
    {
      "schema_version" => 1,
      "start_date" => start_date.iso8601,
      "end_date" => previous_payday.iso8601,
      "pay_date" => target_payday.iso8601,
      "previous_regular_pay_date" => previous_payday.iso8601,
      "cutoff_at" => cutoff.iso8601,
      "initial_epoch" => cutoff.to_i - 120,
      "after_cutoff_epoch" => cutoff.to_i + 1,
      "delivery_date" => cutoff.to_date.iso8601
    }
  end

  def scheduled_payday(period_end)
    period_end.day == 15 ? Date.new(period_end.year, period_end.month, -1) :
      Date.new(period_end.next_month.year, period_end.next_month.month, 15)
  end

  def prepare(fixture_path, clock_path)
    fixture = build
    File.open(fixture_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(fixture))
    end
    File.open(clock_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write("#{fixture.fetch('initial_epoch')}\n")
    end
  end

  def advance(fixture_path, clock_path)
    # Validate the same private file policy as the shim before replacing it.
    stat = File.lstat(clock_path)
    raise "Unsafe certification clock" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
    fixture = JSON.parse(File.read(fixture_path))
    cutoff = Time.iso8601(fixture.fetch("cutoff_at"))
    epoch = fixture.fetch("after_cutoff_epoch")
    raise "Invalid certification clock advance" unless epoch == cutoff.to_i + 1 &&
      Integer(File.read(clock_path), 10) == fixture.fetch("initial_epoch")
    Tempfile.create(["clock-advance-", ".tmp"], File.dirname(clock_path)) do |file|
      file.write("#{epoch}\n")
      file.flush
      file.fsync
      File.rename(file.path, clock_path)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  operation, fixture_path, clock_path = ARGV
  abort "Usage: policy_fixture.rb prepare|advance FIXTURE CLOCK" unless ARGV.size == 3 && %w[prepare advance].include?(operation)
  LocalCertificationPolicyFixture.public_send(operation, fixture_path, clock_path)
end
