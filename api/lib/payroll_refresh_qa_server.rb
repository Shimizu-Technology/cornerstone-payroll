# frozen_string_literal: true

# Seed only the issuer's public key. Requests go through normal JWT verification,
# user lookup, authorization and factor-age checks.
abort "Synthetic refresh server requires the authenticated test lane" unless
  ENV.values_at("RAILS_ENV", "E2E_TEST_MODE", "AUTH_ENABLED") == %w[test true true]

require_relative "../config/application"

Rails.application.config.after_initialize do
  key = JSON.parse(ENV.fetch("E2E_REFRESH_PUBLIC_JWK"))
  RequestPathCache.store.write(ClerkTokenVerifier.jwks_cache_key(ENV.fetch("CLERK_ISSUER")), [ key ])
end

load Rails.root.join("bin/rails")
