# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe ProductionReadiness do
  class FakeSolidQueueAdapter; end

  let(:environment) { ActiveSupport::EnvironmentInquirer.new("production") }
  let(:encryption) do
    Struct.new(:primary_key, :deterministic_key, :key_derivation_salt).new("primary", "deterministic", "salt")
  end
  let(:config) do
    OpenStruct.new(
      force_ssl: true,
      assume_ssl: true,
      active_storage: OpenStruct.new(service: :r2),
      cache_store: :solid_cache_store,
      action_dispatch: OpenStruct.new(trusted_proxies: [ IPAddr.new("10.0.0.0/8") ]),
      active_record: OpenStruct.new(encryption: encryption)
    )
  end
  let(:env) do
    {
      "AUTH_ENABLED" => "true",
      "REQUIRE_MFA" => "true",
      "CLERK_MFA_ATTESTED_INSTANCE_ID" => "ins_live",
      "CLERK_MFA_EVIDENCE_REF" => "security-evidence/cornerstone-mfa-cutover-2026-09-14",
      "CORS_ORIGINS" => "https://payroll.example.com",
      "FRONTEND_URL" => "https://payroll.example.com",
      "CLERK_PUBLISHABLE_KEY" => "pk_live_publishable",
      "CLERK_SECRET_KEY" => "sk_live_secret",
      "CLERK_AUTHORIZED_PARTIES" => "https://payroll.example.com",
      "R2_ACCESS_KEY_ID" => "r2-access",
      "R2_SECRET_ACCESS_KEY" => "r2-secret",
      "R2_ACCOUNT_ID" => "r2-account",
      "R2_BUCKET_NAME" => "payroll-documents",
      "RESEND_API_KEY" => "re_secret",
      "RESEND_FROM_EMAIL" => "direct@example.com",
      "MAILER_FROM_EMAIL" => "payroll@example.com"
    }
  end
  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, select_value: 1) }
  let(:record_class) { class_double(ActiveRecord::Base, connection: connection) }
  let(:cache) do
    Class.new do
      attr_reader :values, :deleted

      def initialize
        @values = {}
        @deleted = []
      end

      def write(key, value, **)
        values[key] = value
      end

      def read(key)
        values[key]
      end

      def delete(key)
        deleted << key
        values.delete(key)
      end
    end.new
  end
  let(:queue_relation) { instance_double(ActiveRecord::Relation, exists?: true) }
  let(:queue_process) { class_double(SolidQueue::Process, where: queue_relation) }
  let(:encryption_credentials) { ActiveSupport::InheritableOptions.new }
  let(:encrypted_data_probe) { -> { true } }
  let(:tax_configuration_valid) { -> { true } }
  let(:storage) do
    Class.new do
      attr_reader :objects, :deleted

      def initialize
        @objects = {}
        @deleted = []
      end

      def upload(key, data, content_type:)
        raise "wrong content type" unless content_type == "text/plain"

        objects[key] = data.read
      end

      def download(key)
        objects[key]
      end

      def delete(key)
        deleted << key
        objects.delete(key)
      end
    end.new
  end
  let(:http_get) do
    lambda do |uri, _token|
      case uri.host
      when "api.resend.com"
        [ 200, { "data" => [ { "name" => "example.com", "status" => "verified", "capabilities" => { "sending" => "enabled" } } ] } ]
      when "api.clerk.com"
        [ 200, { "id" => "ins_live" } ]
      else
        raise "unexpected host"
      end
    end
  end

  subject(:readiness) do
    described_class.new(
      env: env,
      environment: environment,
      config: config,
      primary_record: record_class,
      cache: cache,
      cache_record: record_class,
      queue_record: record_class,
      queue_process: queue_process,
      cable_record: record_class,
      job_adapter: FakeSolidQueueAdapter.new,
      cable_adapter: "solid_cable",
      storage_factory: -> { storage },
      time_sources: -> { [] },
      encryption_credentials: encryption_credentials,
      encrypted_data_probe: encrypted_data_probe,
      tax_configuration_valid: tax_configuration_valid,
      tax_year_readiness: -> { { warnings: [] } },
      http_get: http_get
    )
  end

  before do
    allow(ActiveRecord::Migration).to receive(:check_all_pending!).and_return(nil)
  end

  it "checks real open pay-period tax years in strict guard mode", :rls do
    TenantScope.as_system(reason: "Create readiness fixture") do
      create(:pay_period, start_date: Date.new(2070, 1, 1), end_date: Date.new(2070, 1, 14),
        pay_date: Date.new(2070, 1, 17), status: "draft")
    end

    report = described_class.new(env: env, environment: environment, config: config,
      time_sources: -> { [] }, tax_configuration_valid: -> { true }).run(live: false)
    expect(report.failures.map(&:name)).to include("2070 payroll tax tables are verified")
  end

  it "checks runtime role and the staged policy phase when RLS is configured" do
    env["RLS_CONTEXT_GUARD_MODE"] = "raise"
    env["RLS_DATABASE_URL"] = "postgres://payroll_app@localhost/test"
    allow(record_class).to receive(:connection_pool).and_return(ActiveRecord::Base.connection_pool)

    results = readiness.run(live: true).checks.to_h { |check| [ check.name, check.passed ] }
    expect(results).to include(
      "RLS runtime role and kill switch privileges" => false,
      "RLS policy installation matches the selected phase" => true
    )
    env["RLS_EXPECT_ENFORCED"] = "true"
    expect(readiness.run(live: true).failures.map(&:name)).to include("RLS policy installation matches the selected phase")
  end

  it "passes effective configuration and every safe live dependency probe" do
    report = readiness.run(live: true)

    expect(report).to be_passed
    expect(report.checks.length).to eq(31)
    expect(cache.values).to be_empty
    expect(cache.deleted.length).to eq(1)
    expect(storage.objects).to be_empty
    expect(storage.deleted.length).to eq(1)
    expect(queue_process).to have_received(:where).with(kind: "Worker", last_heartbeat_at: instance_of(Range))
  end

  [
    { "WEB_CONCURRENCY" => "2" },
    { "APP_PROCESS_ROLE" => "payroll_web" },
    { "APP_PROCESS_ROLE" => "employee_web" }
  ].each do |settings|
    it "requires a configured shared rate-limit store with #{settings.inspect}" do
      env.merge!(settings)
      name = "shared rate-limit store is configured for split or multi-worker web"
      expect(readiness.run(live: false).failures.map(&:name)).to include(name)

      env["RACK_ATTACK_REDIS_URL"] = "http://wrong-scheme.example"
      expect(readiness.run(live: false).failures.map(&:name)).to include(name)

      env["RACK_ATTACK_REDIS_URL"] = "rediss://cache.example:6379"
      expect(readiness.run(live: false).failures.map(&:name)).not_to include(name)
    end
  end

  it "can run configuration-only checks outside a live release" do
    expect(http_get).not_to receive(:call)

    report = readiness.run(live: false)

    expect(report).to be_passed
    expect(report.checks.length).to eq(20)
  end

  it "fails closed when complete production encryption sources conflict" do
    encryption_credentials[:active_record_encryption] = ActiveSupport::InheritableOptions.new(
      primary_key: "credential-primary",
      deterministic_key: "credential-deterministic",
      key_derivation_salt: "credential-salt"
    )
    env.merge!(
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "environment-primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "environment-deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "environment-salt"
    )

    report = readiness.run(live: false)

    expect(report.failures.map(&:name)).to include("Active Record encryption sources do not conflict")
  end

  it "fails closed when persisted ciphertext cannot be decrypted" do
    allow(encrypted_data_probe).to receive(:call)
      .and_raise(ActiveRecord::Encryption::Errors::Decryption)

    report = readiness.run(live: true)

    failure = report.failures.find { |check| check.name == "persisted encrypted data can be decrypted" }
    expect(failure.detail).to eq("ActiveRecord::Encryption::Errors::Decryption while verifying")
  end

  it "fails closed for non-production Clerk keys and unsafe wildcard origins" do
    env["CLERK_SECRET_KEY"] = "sk_test_secret"
    env["CORS_ORIGINS"] = "*"

    report = readiness.run(live: false)

    expect(report.failures.map(&:name)).to contain_exactly(
      "allowed frontend origins are explicit production HTTPS origins",
      "production Clerk keys are configured"
    )
  end

  it "fails closed when CLERK_AUTHORIZED_PARTIES is unset or blank in production" do
    [ nil, "", "   " ].each do |value|
      if value.nil?
        env.delete("CLERK_AUTHORIZED_PARTIES")
      else
        env["CLERK_AUTHORIZED_PARTIES"] = value
      end

      report = readiness.run(live: false)

      expect(report.failures.map(&:name)).to include(
        "Clerk authorized parties are explicit production HTTPS origins"
      )
    end
  end

  it "rejects invalid, wildcard, HTTP, path, or non-standard-port CLERK_AUTHORIZED_PARTIES values" do
    [
      "*",
      "http://payroll.example.com",
      "https://payroll.example.com/admin",
      "https://payroll.example.com:8443",
      "https://payroll.example.com, http://insecure.example.com"
    ].each do |value|
      env["CLERK_AUTHORIZED_PARTIES"] = value

      report = readiness.run(live: false)

      expect(report.failures.map(&:name)).to include(
        "Clerk authorized parties are explicit production HTTPS origins"
      )
    end
  end

  it "accepts multiple explicit HTTPS origins in CLERK_AUTHORIZED_PARTIES including mixed-case and default :443" do
    env["CLERK_AUTHORIZED_PARTIES"] = "https://Payroll.Shimizu-Technology.com:443, https://mosa.shimizu-technology.com"

    report = readiness.run(live: false)

    expect(report).to be_passed
  end

  it "reports live production Clerk keys and authorized parties passing when REQUIRE_MFA is false while keeping MFA attestation failing" do
    env["REQUIRE_MFA"] = "false"

    report = readiness.run(live: false)

    expect(report.checks.find { |check| check.name == "production Clerk keys are configured" }.passed).to be(true)
    expect(report.checks.find { |check| check.name == "Clerk authorized parties are explicit production HTTPS origins" }.passed).to be(true)
    expect(report.failures.map(&:name)).to contain_exactly("MFA enforcement has instance-bound evidence")
  end

  it "shares runtime MFA switch parsing while retaining the attestation requirement" do
    env["REQUIRE_MFA"] = "on"
    expect(readiness.run(live: false)).to be_passed

    env.delete("REQUIRE_MFA")
    expect(readiness.run(live: false).failures.map(&:name)).to contain_exactly("MFA enforcement has instance-bound evidence")
  end

  it "requires instance-bound MFA evidence in addition to the attestation flag" do
    env.delete("CLERK_MFA_EVIDENCE_REF")

    report = readiness.run(live: false)

    expect(report.failures.map(&:name)).to include("MFA enforcement has instance-bound evidence")
  end

  it "rejects malformed or multiline MFA evidence bindings" do
    invalid_bindings = [
      [ "not-a-clerk-instance", "security-evidence/cornerstone" ],
      [ "ins_live", "security-evidence/cornerstone\nforged" ],
      [ "\nins_live", "security-evidence/cornerstone" ],
      [ "ins_live\r\n", "security-evidence/cornerstone" ],
      [ "ins_live", "\nsecurity-evidence/cornerstone" ],
      [ "ins_live", "security-evidence/cornerstone\r\n" ]
    ]

    invalid_bindings.each do |instance_id, evidence_ref|
      env["CLERK_MFA_ATTESTED_INSTANCE_ID"] = instance_id
      env["CLERK_MFA_EVIDENCE_REF"] = evidence_ref

      report = readiness.run(live: false)

      expect(report.failures.map(&:name)).to include("MFA enforcement has instance-bound evidence")
    end
  end

  it "requires the authenticated Clerk instance to match the MFA evidence" do
    allow(http_get).to receive(:call).and_wrap_original do |original, uri, token|
      next [ 200, { "id" => "ins_different" } ] if uri.host == "api.clerk.com"

      original.call(uri, token)
    end

    report = readiness.run(live: true)

    expect(report.failures.map(&:name)).to include(
      "Clerk Backend API accepts the configured key and matches MFA evidence"
    )
  end

  it "fails closed when the stored 2026 payroll tax constants drift" do
    allow(tax_configuration_valid).to receive(:call).and_return(false)

    report = readiness.run(live: false)

    expect(report.failures.map(&:name)).to include("official 2026 payroll tax and withholding configuration is loaded")
  end

  it "rejects broad and narrowly scoped public trusted-proxy ranges" do
    [ "0.0.0.0/0", "203.0.113.0/24" ].each do |network|
      config.action_dispatch.trusted_proxies = [ IPAddr.new(network) ]

      report = readiness.run(live: false)

      expect(report.failures.map(&:name)).to include("effective trusted proxies reject arbitrary public clients")
    end
  end

  it "rejects production origins with paths or non-standard ports" do
    [ "https://payroll.example.com/admin", "https://payroll.example.com:8443" ].each do |origin|
      env["CORS_ORIGINS"] = origin

      report = readiness.run(live: false)

      expect(report.failures.map(&:name)).to include("allowed frontend origins are explicit production HTTPS origins")
    end
  end

  it "requires the configured Resend sender domain to be verified for sending" do
    env["MAILER_FROM_EMAIL"] = "payroll@unverified.example"

    report = readiness.run(live: true)

    expect(report.failures.map(&:name)).to include("Resend API key and every application sender domain are ready")
  end

  it "requires every effective sender domain when direct Resend and mailer delivery differ" do
    env["RESEND_FROM_EMAIL"] = "direct@verified.example"
    env["MAILER_FROM_EMAIL"] = "invites@unverified.example"

    report = readiness.run(live: true)

    expect(report.failures.map(&:name)).to include("Resend API key and every application sender domain are ready")
  end

  it "accepts standards-compliant sender display names for verified domains" do
    env["RESEND_FROM_EMAIL"] = "Cornerstone Payroll <direct@example.com>"
    env["MAILER_FROM_EMAIL"] = "Cornerstone Invitations <invites@example.com>"

    report = readiness.run(live: true)

    expect(report).to be_passed
  end

  it "fails closed for an invalid application sender address" do
    env["MAILER_FROM_EMAIL"] = "not an email address"

    report = readiness.run(live: false)

    expect(report.failures.map(&:name)).to include("Resend credentials and sender are configured")
  end

  it "does not expose provider error messages in evidence" do
    secret_error = "provider rejected sk_live_do-not-print-this"
    allow(http_get).to receive(:call).and_raise(StandardError, secret_error)

    report = readiness.run(live: true)
    details = report.failures.map(&:detail).join(" ")

    expect(details).to include("StandardError while verifying")
    expect(details).not_to include(secret_error)
    expect(details).not_to include("sk_live_do-not-print-this")
  end

  it "cleans its exact R2 probe object when the read-back does not match" do
    allow(storage).to receive(:download).and_return("wrong payload")

    report = readiness.run(live: true)

    expect(report.failures.map(&:name)).to include("R2 upload/read/delete round trip succeeds")
    expect(storage.objects).to be_empty
    expect(storage.deleted.length).to eq(1)
  end

  it "attempts exact R2 cleanup even when the upload call raises" do
    allow(storage).to receive(:upload).and_raise(IOError, "simulated lost upload response")

    report = readiness.run(live: true)

    expect(report.failures.map(&:name)).to include("R2 upload/read/delete round trip succeeds")
    expect(storage.deleted.length).to eq(1)
  end

  describe "employee_web service checks" do
    let(:employee_env) do
      env.merge(
        "APP_PROCESS_ROLE" => "employee_web",
        "DB_POOL_MAX" => "3",
        "RACK_ATTACK_REDIS_URL" => "rediss://cache.example:6379"
      )
    end
    let(:employee_paths) do
      %w[/up(.:format) /health/dependencies(.:format) /api/v1/public/tenant_branding
         /api/v1/employee/context(.:format) /api/v1/auth/me(.:format)]
    end
    let(:probes) do
      {
        process_role: -> { "employee_web" },
        route_paths: -> { employee_paths },
        cable_mount_path: -> { nil },
        primary_pool_size: -> { 3 },
        rate_limit_store: -> { shared_store },
        rate_limit_probe: -> { true }
      }
    end

    let(:shared_store) { RackAttackStore::Failover.new(ActiveSupport::Cache::MemoryStore.new, RackAttackStore::MEMORY) }

    def employee_report(env_values = employee_env, live: false, **overrides)
      described_class.new(
        env: env_values, environment: environment, config: config, time_sources: -> { [] },
        job_adapter: FakeSolidQueueAdapter.new, cable_adapter: "solid_cable",
        tax_configuration_valid: -> { true }, tax_year_readiness: -> { { warnings: [] } },
        **probes, **overrides
      ).run(live: live)
    end

    def employee_failures(...)
      employee_report(...).failures.map(&:name).grep(/\Aemployee_web:/)
    end

    let(:rate_limit_probe_name) { "shared rate-limit store accepts a write and delete round trip" }
    let(:live_probes) do
      { primary_record: record_class, cache: cache, cache_record: record_class, queue_record: record_class,
        queue_process: queue_process, cable_record: record_class, storage_factory: -> { storage }, http_get: http_get,
        encrypted_data_probe: -> { true } }
    end

    it "adds four employee checks and passes with the planned settings" do
      report = employee_report

      expect(report).to be_passed
      expect(report.checks.length).to eq(24)
      expect(report.checks.map(&:name).grep(/\Aemployee_web:/).length).to eq(4)
    end

    it "does not apply to payroll_web or all processes" do
      %w[payroll_web all].each do |role|
        names = employee_report(employee_env.merge("APP_PROCESS_ROLE" => role)).checks.map(&:name)
        expect(names.grep(/\Aemployee_web:/)).to be_empty
      end
    end

    it "fails when payroll routes are mounted" do
      expect(employee_failures(employee_env, route_paths: -> { employee_paths + [ "/api/v1/admin/companies(.:format)" ] }))
        .to contain_exactly(/payroll routes or Cable/)
      expect(employee_failures(employee_env, route_paths: -> { employee_paths + [ "/cable" ] })).not_to be_empty
    end

    it "fails when Cable is mounted, the process booted with another role, or no routes exist" do
      expect(employee_failures(employee_env, cable_mount_path: -> { "/cable" })).not_to be_empty
      expect(employee_failures(employee_env, process_role: -> { "all" })).not_to be_empty
      expect(employee_failures(employee_env, route_paths: -> { [] })).not_to be_empty
    end

    it "requires DB_POOL_MAX of at most 3 that matches the effective primary pool" do
      expect(employee_failures(employee_env.except("DB_POOL_MAX"))).to contain_exactly(/database pool/)
      expect(employee_failures(employee_env.merge("DB_POOL_MAX" => "4"), primary_pool_size: -> { 4 })).to contain_exactly(/database pool/)
      expect(employee_failures(employee_env.merge("DB_POOL_MAX" => "0"), primary_pool_size: -> { 0 })).to contain_exactly(/database pool/)
      expect(employee_failures(employee_env.merge("DB_POOL_MAX" => "three"))).to contain_exactly(/database pool/)
      expect(employee_failures(employee_env, primary_pool_size: -> { 5 })).to contain_exactly(/database pool/)
      expect(employee_failures(employee_env.merge("DB_POOL_MAX" => "2"), primary_pool_size: -> { 2 })).to be_empty
    end

    it "requires a single Puma process and no Solid Queue supervisor inside Puma" do
      [ "2", "4" ].each do |workers|
        expect(employee_failures(employee_env.merge("WEB_CONCURRENCY" => workers))).to contain_exactly(/database pool/)
      end
      %w[true 1 on yes].each do |value|
        expect(employee_failures(employee_env.merge("SOLID_QUEUE_IN_PUMA" => value))).to contain_exactly(/database pool/)
      end
      [ {}, { "WEB_CONCURRENCY" => "1" }, { "WEB_CONCURRENCY" => "0" }, { "SOLID_QUEUE_IN_PUMA" => "false" } ].each do |settings|
        expect(employee_failures(employee_env.merge(settings))).to be_empty
      end
    end

    it "reads the primary pool size from the effective connection pool" do
      expect(ActiveRecord::Base.connection_pool.db_config.max_connections).to be_a(Integer)
    end

    it "requires a Redis URL and the effective shared Failover store" do
      expect(employee_failures(employee_env.except("RACK_ATTACK_REDIS_URL"))).to contain_exactly(/rate-limit counters/)
      expect(employee_failures(employee_env.merge("RACK_ATTACK_REDIS_URL" => "http://wrong-scheme.example")))
        .to contain_exactly(/rate-limit counters/)
      [ -> { RackAttackStore::MEMORY }, -> { Object.new }, -> { nil }, -> { ActiveSupport::Cache::MemoryStore.new } ].each do |store|
        expect(employee_failures(employee_env, rate_limit_store: store)).to contain_exactly(/rate-limit counters/)
      end
    end

    it "probes the shared store with a live round trip for employee_web" do
      expect(employee_report(live: true, **live_probes).checks.map(&:name)).to include(rate_limit_probe_name)
      failed = employee_report(live: true, **live_probes, rate_limit_probe: -> { false })
      expect(failed.failures.map(&:name)).to include(rate_limit_probe_name)
      raised = employee_report(live: true, **live_probes, rate_limit_probe: -> { raise "redis down sk_live_hidden" })
      expect(raised.failures.find { |check| check.name == rate_limit_probe_name }.detail).to eq("RuntimeError while verifying")
    end

    it "probes the shared store for any role once a shared URL is configured, and skips it otherwise" do
      payroll_env = employee_env.merge("APP_PROCESS_ROLE" => "payroll_web")
      expect(employee_report(payroll_env, live: true, **live_probes).checks.map(&:name)).to include(rate_limit_probe_name)
      expect(employee_report(payroll_env.except("RACK_ATTACK_REDIS_URL"), live: true, **live_probes).checks.map(&:name))
        .not_to include(rate_limit_probe_name)
    end

    it "round-trips the real Failover store through its shared side only" do
      shared = ActiveSupport::Cache::MemoryStore.new
      expect(RackAttackStore::Failover.new(shared, RackAttackStore::MEMORY).shared_round_trip).to be(true)
      expect(shared.instance_variable_get(:@data)).to be_empty

      down = instance_double(ActiveSupport::Cache::RedisCacheStore, write: nil, read: nil, delete: nil)
      expect(RackAttackStore::Failover.new(down, RackAttackStore::MEMORY).shared_round_trip).to be_falsey
      expect(down).to have_received(:delete)
    end

    it "requires CLERK_AUTHORIZED_PARTIES to be explicit production HTTPS origins" do
      expect(employee_failures(employee_env.merge("CLERK_AUTHORIZED_PARTIES" => " "))).to contain_exactly(/Clerk authorized parties/)
      expect(employee_failures(employee_env.except("CLERK_AUTHORIZED_PARTIES"))).to contain_exactly(/Clerk authorized parties/)
      [ "*", "http://payroll.example.com", "https://payroll.example.com,*", "https://payroll.example.com/path" ].each do |value|
        expect(employee_failures(employee_env.merge("CLERK_AUTHORIZED_PARTIES" => value))).to contain_exactly(/Clerk authorized parties/)
      end
    end

    it "reports probe errors as failures without leaking the error text" do
      report = employee_report(employee_env, route_paths: -> { raise "secret sk_live_hidden" })
      failure = report.failures.find { |check| check.name.start_with?("employee_web: process role") }

      expect(failure.detail).to eq("RuntimeError while verifying")
    end
  end
end
