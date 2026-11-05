# frozen_string_literal: true

# Render supplies the canonical X-Forwarded-For chain. These alternative headers
# are client-controlled and must be removed before logging, audits or throttles.
class CanonicalProxyHeaders
  def initialize(app)
    @app = app
  end

  def call(env)
    env.delete("HTTP_FORWARDED")
    env.delete("HTTP_CLIENT_IP")
    @app.call(env)
  end
end
