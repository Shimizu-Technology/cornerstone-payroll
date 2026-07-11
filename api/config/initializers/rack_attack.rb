# frozen_string_literal: true

class Rack::Attack
  Rack::Attack.cache.store = Rails.cache

  throttle("api/ip", limit: ENV.fetch("API_THROTTLE_LIMIT", 300).to_i, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/api/")
  end

  throttle("auth/ip", limit: ENV.fetch("AUTH_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    request.ip if request.path.match?(%r{\A/api/(?:v1/)?(?:auth|sessions|invitations)})
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i

    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
      [ { error: "Too many requests", retry_after_seconds: retry_after }.to_json ]
    ]
  end
end

Rails.application.config.middleware.use Rack::Attack
