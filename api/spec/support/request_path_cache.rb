# frozen_string_literal: true

RSpec.configure do |config|
  # RequestPathCache is intentionally process-local and therefore is not reset
  # by transactional fixtures. Isolate rate-limit and JWKS state per example.
  config.after do
    RequestPathCache::STORE.clear
  end
end
