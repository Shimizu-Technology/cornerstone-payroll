# frozen_string_literal: true

namespace :production do
  desc "Fail unless the minimum production safety controls are configured"
  task readiness: :environment do
    checks = {
      "RAILS_ENV is production" => Rails.env.production?,
      "authentication is enabled" => ENV.fetch("AUTH_ENABLED", "true") == "true",
      "TLS is forced" => ENV.fetch("FORCE_SSL", "true") == "true",
      "durable Active Storage is selected" => ENV.fetch("ACTIVE_STORAGE_SERVICE", "r2") != "local",
      "durable cache is enabled" => ENV.fetch("USE_SOLID_CACHE", "true") == "true",
      "durable jobs are enabled" => ENV.fetch("USE_SOLID_QUEUE", "true") == "true",
      "durable cable is enabled" => ENV.fetch("USE_SOLID_CABLE", "true") == "true",
      "MFA policy is attested" => ENV["REQUIRE_MFA"] == "true",
      "trusted reverse proxies are configured" => ENV["TRUSTED_PROXY_CIDRS"].present?,
      "allowed frontend origin is configured" => ENV["CORS_ORIGINS"].present?,
      "mailer URL is configured" => ENV["FRONTEND_URL"].present?,
      "Clerk keys are configured" => ENV.values_at("CLERK_PUBLISHABLE_KEY", "CLERK_SECRET_KEY").all?(&:present?),
      "R2 object storage is configured" => ENV.values_at(
        "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ACCOUNT_ID", "R2_BUCKET_NAME"
      ).all?(&:present?),
      "email delivery is configured" => ENV.values_at("RESEND_API_KEY", "MAILER_FROM_EMAIL").all?(&:present?),
      "Active Record encryption is configured" => ENV.values_at(
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
        "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
      ).all?(&:present?)
    }

    checks.each { |name, passed| puts "#{passed ? 'PASS' : 'FAIL'}  #{name}" }
    failures = checks.reject { |_name, passed| passed }
    abort "Production readiness failed (#{failures.length} control(s))." if failures.any?

    puts "Production readiness configuration passed. Complete the manual evidence checklist before release."
  end
end
