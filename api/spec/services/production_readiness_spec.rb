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
      "CORS_ORIGINS" => "https://payroll.example.com",
      "FRONTEND_URL" => "https://payroll.example.com",
      "CLERK_PUBLISHABLE_KEY" => "pk_live_publishable",
      "CLERK_SECRET_KEY" => "sk_live_secret",
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
      http_get: http_get
    )
  end

  before do
    allow(ActiveRecord::Migration).to receive(:check_all_pending!).and_return(nil)
  end

  it "passes effective configuration and every safe live dependency probe" do
    report = readiness.run(live: true)

    expect(report).to be_passed
    expect(report.checks.length).to eq(26)
    expect(cache.values).to be_empty
    expect(cache.deleted.length).to eq(1)
    expect(storage.objects).to be_empty
    expect(storage.deleted.length).to eq(1)
    expect(queue_process).to have_received(:where).with(kind: "Worker", last_heartbeat_at: instance_of(Range))
  end

  it "can run configuration-only checks outside a live release" do
    expect(http_get).not_to receive(:call)

    report = readiness.run(live: false)

    expect(report).to be_passed
    expect(report.checks.length).to eq(16)
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
end
