# frozen_string_literal: true

# Clerk JWKS and tenant branding must remain usable while PostgreSQL is
# read-only. Rate-limit counters have their own store.
module RequestPathCache
  STORE = ActiveSupport::Cache::MemoryStore.new(
    size: 16.megabytes,
    namespace: "request-path"
  )

  def self.store
    STORE
  end
end
