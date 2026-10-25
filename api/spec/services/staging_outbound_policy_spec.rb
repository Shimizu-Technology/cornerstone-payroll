# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagingOutboundPolicy do
  let(:env) { { "DEPLOYMENT_ENV" => "staging", "STAGING_INTEGRATION_HOSTS" => "aire-staging.example.test", "PRODUCTION_INTEGRATION_HOSTS" => "aire.example.test", "STAGING_TESTER_BINDINGS" => '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"},{"user_id":2,"email":"chels@example.test","clerk_subject":"user_chels"}]' } }

  it "denies unknown, AI, tax, geocoding and production integration destinations" do
    %w[https://openrouter.ai/api/v1/chat/completions https://nominatim.openstreetmap.org/search https://maps.googleapis.com/maps/api/place https://tax.example.test/ingest https://aire.example.test/api].each do |url|
      expect { described_class.integration!(url, env: env) }.to raise_error(StagingOutboundPolicy::Blocked)
    end
  end

  it "allows only the exact staging HTTPS origin without alternate ports or credentials" do
    expect(described_class.integration!("https://aire-staging.example.test/api", env: env)).to be_truthy
    %w[http://aire-staging.example.test/api https://aire-staging.example.test:444/api https://aire-staging.example.test.evil/api https://user@aire-staging.example.test/api].each do |url|
      expect { described_class.integration!(url, env: env) }.to raise_error(StagingOutboundPolicy::Blocked)
    end
  end

  it "rejects a production host even if it was also added to the staging allowlist" do
    env["STAGING_INTEGRATION_HOSTS"] = "aire.example.test"
    expect { described_class.integration!("https://aire.example.test/api", env: env) }.to raise_error(StagingOutboundPolicy::Blocked)
  end

  it "does not change non-staging environments" do
    %w[production test development].each do |environment|
      expect(described_class.integration!("http://production.invalid", env: { "DEPLOYMENT_ENV" => environment })).to be_truthy
    end
  end

  it "defaults mail to capture-only and filters exact addresses in every recipient field" do
    expect(described_class.mail_payload({ to: [ "real@example.test" ], subject: "Payroll" }, env: env)).to be_nil
    env["STAGING_MAIL_ALLOWLIST"] = "leon@example.test,chels@example.test"
    payload = described_class.mail_payload({ to: [ "Leon <leon@example.test>", "real@example.test" ], cc: [ "chels@example.test", "real@example.test" ], bcc: [ "outsider@example.test" ], reply_to: "real@example.test", subject: "Payroll", attachments: [ { content: "private" } ] }, env: env)
    expect(payload).to include(to: [ "leon@example.test" ], cc: [ "chels@example.test" ], subject: "[STAGING] Payroll")
    expect(payload.values_at(:bcc, :reply_to, :attachments)).to eq([ nil, nil, nil ])
  end

  it "does not accept a suffix or display-name impersonation in its mail allowlist" do
    env["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
    expect(described_class.mail_payload({ to: "leon@example.test.evil", subject: "x" }, env: env)).to be_nil
    expect(described_class.mail_payload({ to: "leon@example.test <real@example.test>", subject: "x" }, env: env)).to be_nil
  end

  it "blocks Clerk mutations unless their target is a named tester" do
    expect { described_class.clerk_target!(email: "real@example.test", env: env) }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { described_class.clerk_target!(id: "user_real", env: env) }.to raise_error(StagingOutboundPolicy::Blocked)
    expect(described_class.clerk_target!(email: "chels@example.test", env: env)).to be_truthy
  end

  it "fails closed on incomplete staging boot settings without printing their values" do
    expect { described_class.validate!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /DATABASE/)
  end

  context "complete boot contract" do
    let(:safe) do
      env.merge(
        "DATABASE_URL" => "postgresql://127.0.0.1/synthetic",
        "CORNERSTONE_PAYROLL_EVENTS_URL" => "https://aire-staging.example.test/api/v1/integrations/aire/events",
        "STAGING_AIRE_BASE_URL" => "https://aire-staging.example.test",
        "STAGING_FRONTEND_ORIGIN" => "https://web-staging.example.test",
        "STAGING_AIRE_FRONTEND_ORIGIN" => "https://aire-web-staging.example.test",
        "STAGING_PAYROLL_FRONTEND_ORIGIN" => "https://web-staging.example.test",
        "FRONTEND_URL" => "https://web-staging.example.test", "STAGING_ACCESS_GATE_ASSERTED" => "true",
        "STAGING_DATABASE_HOSTS" => "127.0.0.1",
        "PRODUCTION_DATABASE_HOSTS" => "production-db.example.test",
        "STAGING_STORAGE_BUCKET" => "synthetic-staging-bucket",
        "PRODUCTION_STORAGE_BUCKET" => "synthetic-live-bucket",
        "AWS_S3_BUCKET" => "synthetic-staging-bucket",
        "AWS_ACCOUNT_ID" => "111122223333",
        "AWS_REGION" => "us-east-1",
        "STAGING_STORAGE_ACCOUNT_ID" => "111122223333",
        "PRODUCTION_STORAGE_ACCOUNT_ID" => "999988887777",
        "STAGING_STORAGE_ENDPOINT" => "https://s3.us-east-1.amazonaws.com",
        "PRODUCTION_STORAGE_ENDPOINT" => "https://s3.us-west-2.amazonaws.com",
        "STAGING_STORAGE_REGION" => "us-east-1",
        "AWS_ACCESS_KEY_ID" => "synthetic-staging-key",
        "AWS_SECRET_ACCESS_KEY" => "synthetic-only",
        "STAGING_STORAGE_ACCESS_KEY_SHA256" => Digest::SHA256.hexdigest("synthetic-staging-key"),
        "PRODUCTION_STORAGE_ACCESS_KEY_SHA256" => Digest::SHA256.hexdigest("synthetic-live-key"),
        "CLERK_ISSUER" => "https://synthetic-staging.clerk.accounts.dev",
        "STAGING_CLERK_ISSUER" => "https://synthetic-staging.clerk.accounts.dev",
        "PRODUCTION_CLERK_ISSUER" => "https://synthetic-live.clerk.accounts.dev",
        "CLERK_SECRET_KEY" => "sk_test_synthetic",
        "AUTH_ENABLED" => "true", "SECRET_KEY_BASE" => "s" * 64,
        "STAGING_PAYROLL_SHARED_SECRET" => "n" * 64,
        "PRODUCTION_SECRET_KEY_BASE_SHA256" => Digest::SHA256.hexdigest("p" * 64),
        "PRODUCTION_PAYROLL_SHARED_SECRET_SHA256" => Digest::SHA256.hexdigest("q" * 64)
      )
    end

    context "shared production Clerk" do
      before do
        safe.merge!("STAGING_SHARES_PRODUCTION_CLERK" => "true", "STAGING_SHARES_PRODUCTION_STORAGE" => "true", "STAGING_STORAGE_WRITE_PREFIX" => "staging/2026-10-25/")
        safe["CLERK_ISSUER"] = safe["STAGING_CLERK_ISSUER"] = safe["PRODUCTION_CLERK_ISSUER"]
        safe["CLERK_JWKS_URL"] = "#{safe.fetch('CLERK_ISSUER')}/.well-known/jwks.json"
      end

      it "accepts the exact shared issuer and JWKS only when explicitly enabled" do
        expect(described_class.validate!(env: safe)).to eq(true)
        safe.delete("STAGING_SHARES_PRODUCTION_CLERK")
        safe.delete("STAGING_SHARES_PRODUCTION_STORAGE")
        safe.delete("STAGING_STORAGE_WRITE_PREFIX")
        expect { described_class.validate!(env: safe) }.to raise_error(described_class::ConfigurationError, /CLERK_ISSUER/)
      end

      it "still rejects a different JWKS authority" do
        safe["CLERK_JWKS_URL"] = "https://other.example.test/.well-known/jwks.json"
        expect { described_class.validate!(env: safe) }.to raise_error(described_class::ConfigurationError, /JWKS/)
      end

      it "blocks named tester mutations at both application and final HTTP boundaries" do
        expect { described_class.clerk_target!(email: "chels@example.test", env: safe) }.to raise_error(described_class::Blocked)
        http = Net::HTTP.new("api.clerk.com", 443)
        http.use_ssl = true
        patch = Net::HTTP::Patch.new("/v1/users/user_chels")
        expect { described_class.http_request!(http, patch, env: safe) }.to raise_error(described_class::Blocked)
        invite = Net::HTTP::Post.new("/v1/invitations")
        invite.body = { email_address: "chels@example.test" }.to_json
        expect { described_class.http_request!(http, invite, env: safe) }.to raise_error(described_class::Blocked)
        expect(described_class.http_request!(http, Net::HTTP::Get.new("/v1/users/user_chels"), env: safe)).to eq(true)
      end
    end

    it "accepts isolated staging settings without a mail or AI key" do
      expect(described_class.validate!(env: safe)).to eq(true)
    end

    %w[DATABASE_URL MIGRATION_DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL].each do |setting|
      it "rejects a production #{setting}" do
        safe[setting] = "postgresql://production-db.example.test/synthetic"
        expect { described_class.validate!(env: safe) }.to raise_error(described_class::ConfigurationError, /#{setting}/)
      end
    end

    %w[STAGING_STORAGE_BUCKET AWS_S3_BUCKET AWS_ACCESS_KEY_ID CLERK_ISSUER CLERK_SECRET_KEY].each do |setting|
      it "rejects production-looking #{setting} without exposing it" do
        safe[setting] = "production-looking-private-value"
        expect { described_class.validate!(env: safe) }.to raise_error(described_class::ConfigurationError) { |error| expect(error.message).not_to include("production-looking-private-value") }
      end
    end

    %w[CST_INGEST_URL OPENROUTER_API_KEY WORKOS_API_KEY].each do |setting|
      it "refuses copied #{setting}" do
        safe[setting] = "private-copied-value"
        expect { described_class.validate!(env: safe) }.to raise_error(described_class::ConfigurationError, /#{setting}/)
      end
    end

    it "rejects copied signing and integration secrets" do
      safe["PRODUCTION_SECRET_KEY_BASE_SHA256"] = Digest::SHA256.hexdigest(safe["SECRET_KEY_BASE"])
      expect { described_class.validate!(env: safe) }.to raise_error(described_class::ConfigurationError, /SECRET_KEY_BASE/)
    end

    it "blocks an unrecognized HTTP transport before opening a connection" do
      http = Net::HTTP.new("openrouter.ai", 443)
      http.use_ssl = true
      expect(http).not_to receive(:connect)
      expect { described_class.http_request!(http, Net::HTTP::Post.new("/api/v1/chat/completions"), env: safe) }.to raise_error(described_class::Blocked)
    end

    it "blocks direct Resend bypass and redirects outside the integration allowlist" do
      http = Net::HTTP.new("api.resend.com", 443)
      http.use_ssl = true
      expect { described_class.http_request!(http, Net::HTTP::Post.new("/emails"), env: safe) }.to raise_error(described_class::Blocked, /StagingMailTransport/)
      expect { described_class.http_host!("aire.example.test", 443, true, env: safe) }.to raise_error(described_class::Blocked)
    end
    it "rejects an independently configured queue/cache/cable clone" do
      safe["STAGING_DATABASE_HOSTS"] = "127.0.0.1,other-clone.example.test"
      %w[QUEUE_DATABASE_URL CACHE_DATABASE_URL CABLE_DATABASE_URL].each do |setting|
        changed = safe.merge(setting => "postgresql://other-clone.example.test/synthetic")
        expect { described_class.validate!(env: changed) }.to raise_error(described_class::ConfigurationError, /Separate/)
      end
    end
  end
end
