# frozen_string_literal: true

require "uri"

module RlsConfiguration
  MODES = %w[off log raise].freeze

  def self.mode(env = ENV)
    env.fetch("RLS_CONTEXT_GUARD_MODE", "off")
  end

  def self.runtime_url(env = ENV)
    return if mode(env) == "off"

    env["RLS_DATABASE_URL"].presence
  end

  def self.direct_url!(url, name)
    uri = URI.parse(url.to_s)
    if %w[postgres postgresql].include?(uri.scheme) && uri.host.present? &&
        !uri.host.match?(/-pooler|\.pooler\./i) && uri.port != 6543 && !uri.query.to_s.match?(/(?:^|&)host(?:addr)?=/i)
      return url
    end
    raise ArgumentError, "#{name} must point to a direct PostgreSQL endpoint"
  rescue URI::InvalidURIError
    raise ArgumentError, "#{name} must point to a direct PostgreSQL endpoint"
  end
end
