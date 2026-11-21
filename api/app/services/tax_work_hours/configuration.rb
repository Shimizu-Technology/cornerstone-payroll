# frozen_string_literal: true

module TaxWorkHours
  # Where Cornerstone Tax lives and the shared signing secret. Both come from
  # the server environment; the feature is "not connected" until both are set.
  class Configuration
    URL_ENV = "CORNERSTONE_TAX_API_URL"
    SECRET_ENV = "PAYROLL_WORK_HOURS_SECRET"

    attr_reader :base_url, :secret

    def self.current(env: ENV)
      new(base_url: env[URL_ENV], secret: env[SECRET_ENV])
    end

    def initialize(base_url:, secret:)
      @base_url = base_url.to_s.strip.presence
      @secret = secret.to_s.presence
    end

    def connected?
      missing.empty? && url_problem.nil?
    end

    def missing
      [].tap do |names|
        names << URL_ENV if base_url.nil?
        names << SECRET_ENV if secret.nil?
      end
    end

    def uri
      URI.parse(base_url) if base_url
    rescue URI::InvalidURIError
      nil
    end

    # HTTPS everywhere except a loopback address outside production, which the
    # local walkthrough's stub feed uses.
    def url_problem
      return nil if base_url.nil?

      parsed = uri
      return "#{URL_ENV} isn't a valid web address" unless parsed.is_a?(URI::HTTP) && parsed.host.present?
      return nil if parsed.scheme == "https"
      return nil if !Rails.env.production? && %w[localhost 127.0.0.1 ::1].include?(parsed.host)

      "#{URL_ENV} must start with https://"
    end

    # Never includes the secret, only whether it is present.
    def status_json
      {
        connected: connected?,
        missing: missing,
        problem: url_problem,
        tax_host: uri&.host
      }
    end
  end
end
