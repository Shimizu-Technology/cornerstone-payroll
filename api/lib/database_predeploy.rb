# frozen_string_literal: true

require "uri"

class DatabasePredeploy
  class ConfigurationError < StandardError; end

  DATABASE_KEYS = %w[
    DATABASE_URL
    CACHE_DATABASE_URL
    QUEUE_DATABASE_URL
    CABLE_DATABASE_URL
  ].freeze
  TASKS = [ %w[db:prepare], %w[solid_queue:setup] ].freeze

  def initialize(env: ENV, app_root: File.expand_path("..", __dir__), command_runner: nil)
    @env = env
    @app_root = app_root
    @command_runner = command_runner || method(:run_command)
  end

  def run!
    command_environment = migration_environment
    rails_bin = File.join(@app_root, "bin", "rails")

    TASKS.each do |task|
      @command_runner.call(command_environment, rails_bin, *task)
    end
  end

  def migration_environment
    application_url = value("DATABASE_URL")
    primary_migration_url = value("MIGRATION_DATABASE_URL")

    if production? && primary_migration_url.empty?
      raise ConfigurationError,
        "MIGRATION_DATABASE_URL must be configured with a direct, non-pooler connection in production."
    end

    return {} if primary_migration_url.empty?

    validate_migration_url!("MIGRATION_DATABASE_URL", primary_migration_url)

    overrides = DATABASE_KEYS.each_with_object({}) do |database_key, result|
      migration_key = database_key == "DATABASE_URL" ? "MIGRATION_DATABASE_URL" : "MIGRATION_#{database_key}"
      configured_url = value(database_key)
      migration_url = value(migration_key)

      if migration_url.empty?
        if database_key == "DATABASE_URL" || configured_url.empty? || configured_url == application_url
          migration_url = primary_migration_url
        end
      else
        validate_migration_url!(migration_key, migration_url)
      end

      if production? && pooled_url?(configured_url) && migration_url.empty?
        raise ConfigurationError, "#{migration_key} must be configured with a direct connection URL."
      end

      result[database_key] = migration_url unless migration_url.empty?
    end

    overrides["PGCONNECT_TIMEOUT"] = "10"
    overrides["PGOPTIONS"] =
      "-c lock_timeout=10s -c statement_timeout=15min -c idle_in_transaction_session_timeout=5min"
    overrides
  end

  private

  def value(key)
    @env.fetch(key, "").to_s.strip
  end

  def production?
    value("RAILS_ENV") == "production" || value("RACK_ENV") == "production"
  end

  def pooled_url?(url)
    return false if url.empty?

    uri = URI.parse(url)
    host = uri.host.to_s.downcase
    host.include?("-pooler") || host.include?(".pooler.") || uri.port == 6543
  rescue URI::InvalidURIError
    false
  end

  def validate_migration_url!(key, url)
    uri = URI.parse(url)
    unless %w[postgres postgresql].include?(uri.scheme) && uri.host.to_s != ""
      raise ConfigurationError, "#{key} must be a valid PostgreSQL connection URL."
    end

    return unless pooled_url?(url)

    raise ConfigurationError, "#{key} must use a direct connection, not a pooled connection."
  rescue URI::InvalidURIError
    raise ConfigurationError, "#{key} must be a valid PostgreSQL connection URL."
  end

  def run_command(environment, *command)
    system(environment, *command, exception: true)
  end
end
