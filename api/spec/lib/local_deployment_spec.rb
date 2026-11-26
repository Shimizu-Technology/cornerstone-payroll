# frozen_string_literal: true

require "rails_helper"

RSpec.describe LocalDeployment do
  let(:local_env) do
    {
      "DEPLOYMENT_ENV" => "local",
      "RAILS_ENV" => "production",
      "AUTH_ENABLED" => "true",
      "CLERK_SECRET_KEY" => "sk_test_local",
      "CLERK_PUBLISHABLE_KEY" => "pk_test_local",
      "CLERK_ISSUER" => "https://example-local-1.clerk.accounts.dev",
      "ACTIVE_STORAGE_SERVICE" => "local",
      "R2_STORAGE_BACKEND" => "local",
      "LOCAL_MAIL_CAPTURE_DIR" => "/tmp/local-prod/mail",
      "TENANT_ROOT_DOMAIN" => "cornerstone.localhost",
      "LOCAL_HTTPS_PORT" => "8443",
      "DATABASE_URL" => "postgres://payroll@127.0.0.1:55432/payroll",
      "RLS_DATABASE_URL" => "postgres://payroll_app@localhost:55432/payroll",
      "RACK_ATTACK_REDIS_URL" => "redis://127.0.0.1:56379/0",
      "FRONTEND_URL" => "https://payroll.cornerstone.localhost:8443",
      "CORS_ORIGINS" => "https://payroll.cornerstone.localhost:8443",
      "CLERK_AUTHORIZED_PARTIES" => "https://payroll.cornerstone.localhost:8443,https://harborfinch.cornerstone.localhost:8443"
    }
  end

  def with_env(values)
    old = ENV.to_h
    ENV.replace(old.except(*LocalDeployment::HOSTED_MARKERS).merge(values))
    yield
  ensure
    ENV.replace(old)
  end

  describe ".validate!" do
    it "does nothing outside local mode" do
      expect(described_class.validate!(env: { "DEPLOYMENT_ENV" => "production", "RENDER" => "true" })).to be(true)
      expect(described_class.validate!(env: {})).to be(true)
    end

    it "accepts a contained local environment" do
      expect(described_class.validate!(env: local_env)).to be(true)
    end

    it "accepts a Unix socket database" do
      expect(described_class.validate!(env: local_env.merge("DATABASE_URL" => "postgres:///payroll?host=/tmp/local-prod/pg"))).to be(true)
    end

    it "refuses a hosted platform or CI" do
      %w[RENDER RENDER_SERVICE_ID NETLIFY CI GITHUB_ACTIONS].each do |marker|
        expect { described_class.validate!(env: local_env.merge(marker => "true")) }
          .to raise_error(LocalDeployment::ConfigurationError, /hosted platform or CI \(#{marker}\)/)
      end
    end

    it "refuses live keys in any setting without printing them" do
      expect { described_class.validate!(env: local_env.merge("SOME_COPIED_KEY" => "sk_live_secret")) }
        .to raise_error(LocalDeployment::ConfigurationError) { |error| expect(error.message).to include("SOME_COPIED_KEY").and(satisfy { |message| !message.include?("sk_live_secret") }) }
    end

    it "refuses remote credentials" do
      %w[RESEND_API_KEY R2_ACCESS_KEY_ID OPENROUTER_API_KEY].each do |name|
        expect { described_class.validate!(env: local_env.merge(name => "x")) }.to raise_error(LocalDeployment::ConfigurationError, /Remove #{name}/)
      end
    end

    it "refuses a non-development Clerk instance" do
      expect { described_class.validate!(env: local_env.merge("CLERK_ISSUER" => "https://clerk.shimizu-technology.com")) }
        .to raise_error(LocalDeployment::ConfigurationError, /Clerk development CLERK_ISSUER/)
      expect { described_class.validate!(env: local_env.merge("CLERK_PUBLISHABLE_KEY" => "pk_other")) }
        .to raise_error(LocalDeployment::ConfigurationError, /pk_test_/)
    end

    it "refuses a database or Redis that is not on loopback" do
      expect { described_class.validate!(env: local_env.merge("DATABASE_URL" => "postgres://u@db.example.com:5432/payroll")) }
        .to raise_error(LocalDeployment::ConfigurationError, /DATABASE_URL must point at a loopback service/)
      expect { described_class.validate!(env: local_env.merge("RACK_ATTACK_REDIS_URL" => "rediss://cache.example.com:6379")) }
        .to raise_error(LocalDeployment::ConfigurationError, /RACK_ATTACK_REDIS_URL/)
    end

    it "requires DATABASE_URL" do
      expect { described_class.validate!(env: local_env.except("DATABASE_URL")) }.to raise_error(LocalDeployment::ConfigurationError, /requires DATABASE_URL/)
    end

    it "refuses libpq routing settings" do
      %w[PGHOST PGHOSTADDR PGSERVICE PGSERVICEFILE PGSYSCONFDIR PGPORT PGDATABASE PGTARGETSESSIONATTRS PGLOADBALANCEHOSTS].each do |name|
        expect { described_class.validate!(env: local_env.merge(name => "ep-prod.neon.tech")) }
          .to raise_error(LocalDeployment::ConfigurationError, /Remove #{name}/)
      end
      expect { described_class.validate!(env: local_env.merge("PGOPTIONS" => "-c search_path=x")) }.to raise_error(LocalDeployment::ConfigurationError, /PGOPTIONS/)
      expect(described_class.validate!(env: local_env.merge("PGOPTIONS" => DatabaseConnectionTimeouts::PG_OPTIONS))).to be(true)
    end

    it "refuses a socket URL that leaves the host to libpq settings" do
      expect { described_class.validate!(env: local_env.merge("DATABASE_URL" => "postgres:///payroll", "PGHOST" => "ep-prod.neon.tech")) }
        .to raise_error(LocalDeployment::ConfigurationError, /PGHOST/)
      expect(described_class.loopback_url?("postgres:///payroll")).to be(false)
    end

    it "refuses URL parameters that route libpq elsewhere" do
      [
        "postgres://u@127.0.0.1:5432/payroll?hostaddr=54.1.2.3",
        "postgres://u@127.0.0.1:5432/payroll?service=production",
        "postgres://u@127.0.0.1:5432/payroll?servicefile=/tmp/x",
        "postgres://u@127.0.0.1:5432/payroll?target_session_attrs=read-write",
        "postgres://u@127.0.0.1:5432/payroll?load_balance_hosts=random",
        "postgres://u@127.0.0.1:5432/payroll?replication=database",
        "postgres://u@127.0.0.1:5432/payroll?HOSTADDR=54.1.2.3",
        "postgres://u@127.0.0.1:5432/payroll?host=prod.example.com",
        "postgres:///payroll?host=/tmp/pg,prod.example.com",
        "postgres:///payroll?host=prod.example.com",
        "postgres:///payroll?host=/tmp/pg&host=prod.example.com",
        "postgres:///payroll?host=prod.example.com&host=/tmp/pg",
        "postgres://127.0.0.1,prod.example.com/payroll",
        "mysql://127.0.0.1/payroll",
        "http://127.0.0.1/payroll"
      ].each do |url|
        expect(described_class.loopback_url?(url)).to be(false), url
        expect { described_class.validate!(env: local_env.merge("DATABASE_URL" => url)) }.to raise_error(LocalDeployment::ConfigurationError), url
      end
      expect(described_class.loopback_url?("postgres://u@127.0.0.1:5432/payroll?sslmode=disable&options=#{CGI.escape(DatabaseConnectionTimeouts::PG_OPTIONS)}")).to be(true)
    end

    it "checks Redis URLs as Redis" do
      expect { described_class.validate!(env: local_env.merge("RACK_ATTACK_REDIS_URL" => "postgres://127.0.0.1/payroll")) }
        .to raise_error(LocalDeployment::ConfigurationError, /RACK_ATTACK_REDIS_URL/)
      expect { described_class.validate!(env: local_env.merge("DATABASE_URL" => "redis://127.0.0.1:6379")) }
        .to raise_error(LocalDeployment::ConfigurationError, /DATABASE_URL/)
      expect(described_class.validate!(env: local_env.merge("RACK_ATTACK_REDIS_URL" => "rediss://localhost:56379/0"))).to be(true)
    end

    it "requires a .localhost tenant root domain and local origins" do
      expect { described_class.validate!(env: local_env.merge("TENANT_ROOT_DOMAIN" => "shimizu-technology.com")) }
        .to raise_error(LocalDeployment::ConfigurationError, /TENANT_ROOT_DOMAIN/)
      expect { described_class.validate!(env: local_env.merge("FRONTEND_URL" => "https://payroll.shimizu-technology.com")) }
        .to raise_error(LocalDeployment::ConfigurationError, /FRONTEND_URL/)
      expect { described_class.validate!(env: local_env.merge("CLERK_AUTHORIZED_PARTIES" => "https://payroll.cornerstone.localhost")) }
        .to raise_error(LocalDeployment::ConfigurationError, /CLERK_AUTHORIZED_PARTIES/)
      expect { described_class.validate!(env: local_env.merge("LOCAL_HTTPS_PORT" => "80")) }
        .to raise_error(LocalDeployment::ConfigurationError, /LOCAL_HTTPS_PORT/)
    end

    it "requires disk storage and a mail capture directory" do
      expect { described_class.validate!(env: local_env.merge("ACTIVE_STORAGE_SERVICE" => "r2")) }.to raise_error(LocalDeployment::ConfigurationError, /ACTIVE_STORAGE_SERVICE/)
      expect { described_class.validate!(env: local_env.except("LOCAL_MAIL_CAPTURE_DIR")) }.to raise_error(LocalDeployment::ConfigurationError, /LOCAL_MAIL_CAPTURE_DIR/)
    end

    it "runs from the deployment check that production boot uses" do
      expect(StagingOutboundPolicy.validate_deployment!(env: local_env, environment: "production")).to be(true)
      expect { StagingOutboundPolicy.validate_deployment!(env: local_env.merge("RENDER" => "true"), environment: "production") }
        .to raise_error(LocalDeployment::ConfigurationError)
      expect(StagingOutboundPolicy.staging?(local_env)).to be(false)
    end
  end

  describe "tenant domain and port" do
    it "keeps the production domain and port outside local mode, whatever the settings say" do
      env = local_env.merge("DEPLOYMENT_ENV" => "production")
      expect(described_class.tenant_root_domain(env)).to be_nil
      expect(described_class.https_port(env)).to eq(443)
      expect(described_class.port_suffix(env)).to eq("")
    end

    it "serves tenants under the local root domain and port in local mode" do
      with_env(local_env) do
        expect(TenantSubdomainRegistry.root_domain).to eq("cornerstone.localhost")
        expect(TenantSubdomainRegistry.tenant_origin("harborfinch")).to eq("https://harborfinch.cornerstone.localhost:8443")
        expect(TenantSubdomainRegistry.tenant_shaped_origin?("https://harborfinch.cornerstone.localhost:8443")).to be(true)
        expect(TenantSubdomainRegistry.tenant_shaped_origin?("https://harborfinch.cornerstone.localhost")).to be(false)
        expect(TenantSubdomainRegistry.tenant_shaped_origin?("https://harborfinch.shimizu-technology.com")).to be(false)
        expect(TenantSubdomainRegistry.client_origin?("https://harborfinch.cornerstone.localhost:8443")).to be(true)
        expect(TenantSubdomainRegistry.https_url("https://employee.cornerstone.localhost:8443")).to eq("https://employee.cornerstone.localhost:8443")
      end
    end

    it "uses the production domain when TENANT_ROOT_DOMAIN is set outside local mode" do
      with_env("DEPLOYMENT_ENV" => "production", "TENANT_ROOT_DOMAIN" => "cornerstone.localhost", "LOCAL_HTTPS_PORT" => "8443") do
        expect(TenantSubdomainRegistry.tenant_origin("harborfinch")).to eq("https://harborfinch.shimizu-technology.com")
        expect(TenantSubdomainRegistry.tenant_shaped_origin?("https://harborfinch.shimizu-technology.com")).to be(true)
        expect(TenantSubdomainRegistry.tenant_shaped_origin?("https://harborfinch.cornerstone.localhost:8443")).to be(false)
        expect(TenantSubdomainRegistry.https_url("https://employee.cornerstone.localhost")).to be_nil
      end
    end

    it "reserves the employee API host" do
      expect(TenantSubdomainRegistry::RESERVED_SLUGS).to include("employee-api")
      expect(TenantSubdomainRegistry.client_origin?("https://employee-api.#{TenantSubdomainRegistry::DEFAULT_ROOT_DOMAIN}")).to be(false)
    end

    it "accepts local origins as Clerk authorized parties only in local mode" do
      expect(ClerkTokenVerifier.valid_production_https_origin?("https://payroll.cornerstone.localhost:8443")).to be(false)
      with_env(local_env) do
        expect(ClerkTokenVerifier.valid_production_https_origin?("https://payroll.cornerstone.localhost:8443")).to be(true)
        expect(ClerkTokenVerifier.valid_production_https_origin?("https://payroll.shimizu-technology.com")).to be(false)
        expect(RolloutEnvironment.clerk_authorized_parties_valid?(ENV)).to be(true)
        expect(ClerkTokenVerifier.valid_production_https_origin?("https://example-local-1.clerk.accounts.dev")).to be(true)
      end
    end

    it "reads the environment it is given, not the process environment" do
      expect(ENV["DEPLOYMENT_ENV"]).not_to eq("local")
      expect(ClerkTokenVerifier.valid_production_https_origin?("https://payroll.cornerstone.localhost:8443", env: local_env)).to be(true)
      expect(RolloutEnvironment.clerk_authorized_parties_valid?(local_env)).to be(true)
      readiness = ProductionReadiness.new(env: local_env)
      expect(readiness.send(:clerk_authorized_parties_valid?)).to be(true)
      expect(readiness.send(:production_origins_valid?)).to be(true)
      expect(readiness.send(:production_https_url?, local_env["FRONTEND_URL"])).to be(true)

      hosted = ProductionReadiness.new(env: local_env.merge("DEPLOYMENT_ENV" => "production"))
      expect(hosted.send(:clerk_authorized_parties_valid?)).to be(false)
      expect(hosted.send(:production_https_url?, local_env["FRONTEND_URL"])).to be(false)

      preflight = ClerkCutover::PreflightService.new(env: local_env).send(:check_authorized_parties)
      expect(preflight.passed).to be(true)
    end
  end

  describe ".outbound_allowed?" do
    it "allows loopback and the Clerk development instance only" do
      expect(described_class.outbound_allowed?("127.0.0.1", 55_432, false, env: local_env)).to be(true)
      expect(described_class.outbound_allowed?("employee-api.cornerstone.localhost", 8443, true, env: local_env)).to be(true)
      expect(described_class.outbound_allowed?("api.clerk.com", 443, true, env: local_env)).to be(true)
      expect(described_class.outbound_allowed?("example-local-1.clerk.accounts.dev", 443, true, env: local_env)).to be(true)
      expect(described_class.outbound_allowed?("api.clerk.com", 80, false, env: local_env)).to be(false)
      expect(described_class.outbound_allowed?("api.resend.com", 443, true, env: local_env)).to be(false)
      expect(described_class.outbound_allowed?("cornerstone-payroll.onrender.com", 443, true, env: local_env)).to be(false)
    end

    it "blocks real Net::HTTP requests before opening a socket" do
      # WebMock replaces Net::HTTP after boot; exercise the guarded class.
      WebMock.disable!
      with_env(local_env) do
        http = Net::HTTP.new("api.resend.com", 443)
        http.use_ssl = true
        expect(http).not_to receive(:connect)
        expect { http.request(Net::HTTP::Post.new("/emails")) }.to raise_error(StagingOutboundPolicy::Blocked, /local deployment policy/)
      end
    ensure
      WebMock.enable!
    end

    it "checks each request's destination too" do
      http = Net::HTTP.new("api.resend.com", 443)
      http.use_ssl = true
      expect { StagingOutboundPolicy.http_request!(http, Net::HTTP::Post.new("/emails"), env: local_env) }
        .to raise_error(StagingOutboundPolicy::Blocked, /local deployment policy/)
      expect(StagingOutboundPolicy.http_request!(Net::HTTP.new("127.0.0.1", 3000), Net::HTTP::Get.new("/up"), env: local_env)).to be(true)
    end

    it "is enforced by the outbound network guard" do
      expect { StagingOutboundPolicy.http_host!("api.resend.com", 443, true, env: local_env) }
        .to raise_error(StagingOutboundPolicy::Blocked, /local deployment policy/)
      expect(StagingOutboundPolicy.http_host!("localhost", 3000, false, env: local_env)).to be(true)
      expect(StagingOutboundPolicy.http_host!("api.resend.com", 443, true, env: {})).to be(true)
    end
  end

  describe "mail" do
    it "writes every message to the capture directory instead of sending it" do
      Dir.mktmpdir do |dir|
        with_env(local_env.merge("LOCAL_MAIL_CAPTURE_DIR" => dir)) do
          expect(Resend::Emails).not_to receive(:send)
          expect(StagingMailTransport.available?).to be(true)
          response = StagingMailTransport.deliver({ from: "Payroll <payroll@example.test>", to: [ "employee@example.test" ], subject: "Invite", html: "<p>Hi</p>", attachments: [ { filename: "stub.pdf", content: "PDF" } ] },
            options: { idempotency_key: "key-1" })
          expect(response).to include("local_captured" => true)

          files = Dir.children(dir)
          expect(files).to eq([ "#{response.fetch('id')}.json" ])
          path = File.join(dir, files.first)
          expect(File.stat(path).mode & 0o777).to eq(0o600)
          message = JSON.parse(File.read(path))
          expect(message).to include("to" => [ "employee@example.test" ], "subject" => "Invite", "html" => "<p>Hi</p>", "idempotency_key" => "key-1")
          expect(message["attachments"]).to eq([ { "filename" => "stub.pdf", "bytes" => 3 } ])
        end
      end
    end

    it "counts byte-array attachments by length" do
      Dir.mktmpdir do |dir|
        response = described_class.capture_mail!({ to: [ "a@example.test" ], attachments: [ { filename: "w2.pdf", content: "PDF!".bytes } ] }, env: local_env.merge("LOCAL_MAIL_CAPTURE_DIR" => dir))
        expect(JSON.parse(File.read(File.join(dir, "#{response['id']}.json")))["attachments"]).to eq([ { "filename" => "w2.pdf", "bytes" => 4 } ])
      end
    end

    it "captures Action Mailer messages through the same transport, unredacted" do
      Dir.mktmpdir do |dir|
        with_env(local_env.merge("LOCAL_MAIL_CAPTURE_DIR" => dir)) do
          mail = Mail.new { to "employee@example.test"; from "payroll@example.test"; subject "Your W-2"; body "Ready" }
          expect(Resend::Emails).not_to receive(:send)
          mail.deliver
          message = JSON.parse(File.read(File.join(dir, Dir.children(dir).first)))
          expect(message).to include("to" => [ "employee@example.test" ], "subject" => "Your W-2", "text" => "Ready")
        end
      end
    end

    it "ignores local capture and disk settings on a hosted deployment" do
      Dir.mktmpdir do |dir|
        with_env("DEPLOYMENT_ENV" => "production", "LOCAL_MAIL_CAPTURE_DIR" => dir, "R2_STORAGE_BACKEND" => "local", "ACTIVE_STORAGE_SERVICE" => "local", "RESEND_API_KEY" => "re_test") do
          expect(Resend::Emails).to receive(:send).and_return({ "id" => "sent" })
          expect(StagingMailTransport.deliver(to: [ "employee@example.test" ], subject: "Hi", text: "Hi")).to eq({ "id" => "sent" })
          expect(Dir.children(dir)).to be_empty
          expect(R2StorageService.new.send(:staging_local_storage?)).to be(false)
          expect(StagingMailInterceptor.delivering_email(Mail.new { to "e@example.test" })).to be_nil
        end
      end
    end

    it "treats portal notifications as configured with a sender and no Resend key" do
      with_env(local_env.merge("RESEND_FROM_EMAIL" => "payroll@example.test")) do
        expect(PortalNotifications::Transport.configured?).to be(true)
      end
    end

    it "keeps requiring a Resend key outside local and staging" do
      with_env("DEPLOYMENT_ENV" => "production", "RESEND_API_KEY" => "") do
        expect(StagingMailTransport.available?).to be(false)
      end
    end
  end

  it "keeps local objects on disk instead of R2" do
    with_env(local_env) do
      service = R2StorageService.new
      expect(service.send(:configured?)).to be(false)
      expect(service.send(:local_storage_root)).to eq(R2StorageService::STAGING_STORAGE_ROOT)
    end
  end

  it "fails production readiness on a local copy" do
    check = ProductionReadiness.new(env: local_env).send(:base_configuration_checks).find { |item| item.name.include?("not a local production copy") }
    expect(check.passed).to be(false)
  end
end
