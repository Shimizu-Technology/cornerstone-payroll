# frozen_string_literal: true

# RUBYOPT-only test support. Never require this from application initializers.
require "uri"

module LocalCertificationClock
  module_function

  def refuse
    abort "Refusing certification clock outside an isolated private test fixture"
  end

  def validate_environment!
    refuse unless ENV["RAILS_ENV"] == "test" && ENV["E2E_TEST_MODE"] == "true"
    database = URI.parse(ENV.fetch("TEST_DATABASE_URL", ""))
    refuse unless %w[postgres postgresql].include?(database.scheme) &&
                  [nil, "", "localhost", "127.0.0.1", "::1", "[::1]"].include?(database.host) &&
                  database.userinfo.nil? && database.query.nil? && database.fragment.nil? &&
                  database.path.match?(%r{\A/(?:aire_cornerstone|cornerstone_aire)_certification_\d+_\d+\z})
    path = ENV.fetch("CERTIFICATION_CLOCK_FILE", "")
    refuse unless File.absolute_path(path) == path &&
                  File.basename(File.dirname(path)).start_with?("cornerstone-aire-certification.")
    stat = File.lstat(File.dirname(path))
    refuse unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
  rescue URI::InvalidURIError, SystemCallError
    refuse
  end

  def epoch
    # Both API processes reread the same atomically replaced file on every call.
    File.open(ENV.fetch("CERTIFICATION_CLOCK_FILE"), File::RDONLY | File::NOFOLLOW) do |file|
      stat = file.stat
      refuse unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size < 32
      value = file.read
      refuse unless value.match?(/\A\d{1,12}\n?\z/)
      Integer(value, 10)
    end
  rescue KeyError, SystemCallError, ArgumentError
    refuse
  end

  module TimeMethods
    def now
      at(LocalCertificationClock.epoch).getlocal
    end
  end
end

LocalCertificationClock.validate_environment!
LocalCertificationClock.epoch
Time.singleton_class.prepend(LocalCertificationClock::TimeMethods)
