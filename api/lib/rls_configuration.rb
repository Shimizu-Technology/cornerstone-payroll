# frozen_string_literal: true

require "uri"

module RlsConfiguration
  MODES = %w[off log raise].freeze
  # Session advisory lock shared by rls:enforce and rls:disable, so a
  # rollback waits for a running enforcement to stop instead of racing it.
  OWNER_TASK_LOCK = 7_301_337

  def self.mode(env = ENV)
    env.fetch("RLS_CONTEXT_GUARD_MODE", "off")
  end

  def self.runtime_url(env = ENV)
    return if mode(env) == "off"

    env["RLS_DATABASE_URL"].presence
  end

  def self.verify_boot!(environment:, env: ENV)
    unless MODES.include?(mode(env))
      raise ArgumentError, "RLS_CONTEXT_GUARD_MODE must be off, log, or raise"
    end
    return unless environment.production? && mode(env) != "off"

    url = runtime_url(env)
    unless url
      raise ArgumentError, "Set RLS_DATABASE_URL to the direct payroll_app endpoint before enabling the guard"
    end

    direct_url!(url, "RLS_DATABASE_URL")
    yield
  end

  def self.direct_url!(url, name)
    error_message = "#{name} must point to a direct PostgreSQL endpoint"
    uri = URI.parse(url.to_s)
    query_keys = URI.decode_www_form(uri.query.to_s).map { |key, _value| key.downcase }
    if %w[postgres postgresql].include?(uri.scheme) && uri.hostname.present? && !uri.hostname.include?(",") &&
        !uri.hostname.match?(/-pooler|\.pooler\./i) && uri.port != 6543 && uri.fragment.nil? &&
        (query_keys & %w[host hostaddr port dbname service servicefile]).empty?
      return url
    end
    raise ArgumentError, error_message
  rescue URI::InvalidURIError, ArgumentError
    raise ArgumentError, error_message, cause: nil
  end
end
