# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "policy_fixture"

class LocalCertificationClockTest < Minitest::Test
  SHIM = File.expand_path("clock.rb", __dir__)

  def setup
    @directory = Dir.mktmpdir("cornerstone-aire-certification.")
    @clock = File.join(@directory, "clock.epoch")
    @fixture = File.join(@directory, "policy.json")
    File.open(@clock, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("1792648800\n") }
    @environment = {
      "RAILS_ENV" => "test", "E2E_TEST_MODE" => "true",
      "TEST_DATABASE_URL" => "postgresql:///aire_cornerstone_certification_20261004_123",
      "CERTIFICATION_CLOCK_FILE" => @clock, "RUBYOPT" => "-r#{SHIM}"
    }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def run_shim(code, overrides = {})
    Open3.capture3(@environment.merge(overrides), RbConfig.ruby, "-e", code)
  end

  def test_runtime_resolves_locked_gems_before_loading_the_clock
    # Model CI's default-gem mismatch without downloads or changing installed gems.
    require "uri"
    uri_file = $LOADED_FEATURES.find { |path| path.end_with?("/uri.rb") }
    locked_uri = File.join(@directory, "locked-uri")
    library = File.join(locked_uri, "lib")
    FileUtils.mkdir_p(library)
    # Default gems may live in rubylibdir instead of a gems/<name>/lib folder.
    FileUtils.cp(uri_file, File.join(library, "uri.rb"))
    FileUtils.cp_r(File.join(File.dirname(uri_file), "uri"), library)
    File.write(File.join(locked_uri, "uri.gemspec"), <<~GEMSPEC)
      Gem::Specification.new do |spec|
        spec.name = "uri"
        spec.version = "99.0.0"
        spec.summary = "Disposable certification boot-order fixture"
        spec.authors = ["Certification test"]
        spec.require_paths = ["lib"]
      end
    GEMSPEC
    gemfile = File.join(@directory, "Gemfile")
    File.write(gemfile, "gem 'uri', path: #{locked_uri.inspect}\n")
    code = <<~'RUBY'
      require "bundler/setup"
      abort "wrong locked uri" unless Gem.loaded_specs.fetch("uri").version.to_s == "99.0.0"
      abort "clock not loaded" unless Time.now.to_i == 1792648800
      print "locked gem and clock loaded"
    RUBY
    environment = @environment.merge(
      "BUNDLE_GEMFILE" => gemfile,
      "ROOT_DIR" => File.expand_path("../..", __dir__),
      "CLOCK_RUNTIME" => File.expand_path("runtime.sh", __dir__),
      "CLOCK_RUBY" => RbConfig.ruby,
      "CLOCK_BOOT_TEST_CODE" => code
    )
    stdout, stderr, status = Open3.capture3(environment, "bash", "-c", <<~'SHELL')
      set -e
      source "$CLOCK_RUNTIME"
      certification_use_clock "$TEST_DATABASE_URL"
      exec "$CLOCK_RUBY" -e "$CLOCK_BOOT_TEST_CODE"
    SHELL
    assert status.success?, "#{stdout} #{stderr}"
    assert_includes stdout, "locked gem and clock loaded"
  end

  def test_reads_shared_atomic_updates_without_changing_monotonic_clock
    code = <<~'CODE'
      first = Time.now.to_i
      monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      replacement = "#{ENV.fetch('CERTIFICATION_CLOCK_FILE')}.replacement"
      File.open(replacement, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("1792648921\n") }
      File.rename(replacement, ENV.fetch('CERTIFICATION_CLOCK_FILE'))
      abort "stale clock" unless first == 1792648800 && Time.now.to_i == 1792648921
      abort "monotonic changed" unless Process.clock_gettime(Process::CLOCK_MONOTONIC) >= monotonic
    CODE
    stdout, stderr, status = run_shim(code)
    assert status.success?, "#{stdout} #{stderr}"
    # A second Ruby/API process observes the exact same advanced value.
    stdout, stderr, status = run_shim("print Time.now.to_i", "TEST_DATABASE_URL" => "postgresql:///cornerstone_aire_certification_20261004_123")
    assert status.success?, stderr
    assert_equal "1792648921", stdout
  end

  def test_refuses_non_test_or_non_disposable_or_remote_environment
    [
      { "RAILS_ENV" => "production" },
      { "E2E_TEST_MODE" => nil },
      { "TEST_DATABASE_URL" => "postgresql:///cornerstone_test" },
      { "TEST_DATABASE_URL" => "postgresql://remote.example/aire_cornerstone_certification_20261004_123" },
      { "TEST_DATABASE_URL" => "postgresql:///aire_cornerstone_certification_20261004_123?host=remote.example" }
    ].each do |override|
      stdout, stderr, status = run_shim("print Time.now", override)
      refute status.success?
      assert_empty stdout
      assert_includes stderr, "Refusing certification clock"
      refute_includes stderr, "remote.example"
    end
  end

  def test_refuses_public_or_symlink_or_invalid_clock
    File.chmod(0o644, @clock)
    refute run_shim("print Time.now").last.success?
    File.chmod(0o600, @clock)
    File.write(@clock, "not an epoch")
    refute run_shim("print Time.now").last.success?
    File.write(@clock, "1792648800\n")
    link = File.join(@directory, "clock.link")
    File.symlink(@clock, link)
    refute run_shim("print Time.now", "CERTIFICATION_CLOCK_FILE" => link).last.success?
    File.chmod(0o755, @directory)
    refute run_shim("print Time.now").last.success?
  end

  def test_policy_has_exact_fixed_paydays_and_guam_cutoff
    fixture = LocalCertificationPolicyFixture.build(now: Time.iso8601("2026-10-04T10:00:00+10:00"))
    assert_equal "2026-09-16", fixture.fetch("start_date")
    assert_equal "2026-09-30", fixture.fetch("end_date")
    assert_equal "2026-09-30", fixture.fetch("previous_regular_pay_date")
    assert_equal "2026-10-15", fixture.fetch("pay_date")
    assert_equal "2026-10-07T17:00:00+10:00", fixture.fetch("cutoff_at")
    cutoff = Time.iso8601(fixture.fetch("cutoff_at")).to_i
    assert_equal cutoff - 120, fixture.fetch("initial_epoch")
    assert_equal cutoff + 1, fixture.fetch("after_cutoff_epoch")
    assert_equal "2026-10-07", fixture.fetch("delivery_date")
  end

  def test_leap_year_and_year_boundary_keep_calendar_dates
    {
      "2028-02-23T00:00:00+10:00" => ["2028-02-16", "2028-02-29", "2028-03-15", "2028-03-07T17:00:00+10:00"],
      "2026-12-23T00:00:00+10:00" => ["2026-12-16", "2026-12-31", "2027-01-15", "2027-01-07T17:00:00+10:00"]
    }.each do |now, expected|
      fixture = LocalCertificationPolicyFixture.build(now: Time.iso8601(now))
      assert_equal expected, fixture.values_at("start_date", "end_date", "pay_date", "cutoff_at")
      assert_equal fixture.fetch("end_date"), fixture.fetch("previous_regular_pay_date")
    end
  end

  def test_imminent_cutoff_is_skipped_to_leave_real_database_revision_margin
    now = Time.iso8601("2026-10-21T18:00:00+10:00")
    fixture = LocalCertificationPolicyFixture.build(now: now)
    assert_equal "2026-11-07T17:00:00+10:00", fixture.fetch("cutoff_at")
    assert_operator Time.iso8601(fixture.fetch("cutoff_at")), :>=, now + 86_400
  end

  def test_prepare_is_private_exclusive_and_advance_is_exactly_once
    File.unlink(@clock)
    LocalCertificationPolicyFixture.prepare(@fixture, @clock)
    assert_equal 0o600, File.stat(@fixture).mode & 0o777
    assert_equal 0o600, File.stat(@clock).mode & 0o777
    fixture = JSON.parse(File.read(@fixture))
    assert_equal fixture.fetch("initial_epoch"), Integer(File.read(@clock), 10)
    assert_raises(Errno::EEXIST) { LocalCertificationPolicyFixture.prepare(@fixture, @clock) }
    LocalCertificationPolicyFixture.advance(@fixture, @clock)
    assert_equal fixture.fetch("after_cutoff_epoch"), Integer(File.read(@clock), 10)
    assert_equal 0o600, File.stat(@clock).mode & 0o777
    assert_raises(RuntimeError) { LocalCertificationPolicyFixture.advance(@fixture, @clock) }
  end

  def test_advance_refuses_unsafe_or_wrong_value
    File.unlink(@clock)
    LocalCertificationPolicyFixture.prepare(@fixture, @clock)
    File.chmod(0o644, @clock)
    assert_raises(RuntimeError) { LocalCertificationPolicyFixture.advance(@fixture, @clock) }
    File.chmod(0o600, @clock)
    File.write(@clock, "1\n")
    assert_raises(RuntimeError) { LocalCertificationPolicyFixture.advance(@fixture, @clock) }
  end
end
