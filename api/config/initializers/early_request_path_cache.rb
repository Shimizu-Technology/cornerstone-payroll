# frozen_string_literal: true

# Request-path safeguards must remain usable when PostgreSQL is reachable but
# temporarily read-only. This process-local store intentionally backs only
# rate-limit counters and Clerk JWKS; durable application caching stays in
# Solid Cache. The production web service currently runs one Puma process. Use
# a shared Redis/Valkey store before horizontally scaling the web tier.
module RequestPathCache
  STORE = ActiveSupport::Cache::MemoryStore.new(
    size: 16.megabytes,
    namespace: "request-path"
  )

  def self.store
    STORE
  end
end
