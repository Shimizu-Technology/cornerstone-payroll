# frozen_string_literal: true

require "json"
require "ipaddr"
require "mail"
require "net/http"
require "securerandom"
require "stringio"
require "uri"

class ProductionReadiness
  MAX_PROVIDER_RESPONSE_BYTES = 1.megabyte
  PRIVATE_PROXY_NETWORKS = [
    IPAddr.new("127.0.0.0/8"),
    IPAddr.new("::1/128"),
    IPAddr.new("fc00::/7"),
    IPAddr.new("10.0.0.0/8"),
    IPAddr.new("172.16.0.0/12"),
    IPAddr.new("192.168.0.0/16"),
    IPAddr.new("169.254.0.0/16"),
    IPAddr.new("fe80::/10")
  ].freeze

  Check = Data.define(:name, :passed, :detail)

  class Report
    attr_reader :checks, :generated_at, :revision

    def initialize(checks:, generated_at: Time.current, revision: ENV.fetch("RENDER_GIT_COMMIT", ENV.fetch("GIT_COMMIT", "unknown")))
      @checks = checks
      @generated_at = generated_at
      @revision = revision
    end

    def passed?
      checks.all?(&:passed)
    end

    def failures
      checks.reject(&:passed)
    end

    def as_json(*)
      {
        generated_at: generated_at.iso8601,
        revision: revision,
        passed: passed?,
        checks: checks.map { |check| { name: check.name, passed: check.passed, detail: check.detail } }
      }
    end
  end

  def initialize(
    env: ENV,
    environment: Rails.env,
    config: Rails.application.config,
    primary_record: ActiveRecord::Base,
    cache: Rails.cache,
    cache_record: SolidCache::Record,
    queue_record: SolidQueue::Record,
    queue_process: SolidQueue::Process,
    cable_record: SolidCable::Record,
    job_adapter: ActiveJob::Base.queue_adapter,
    cable_adapter: ActionCable.server.config.cable.fetch("adapter", nil),
    storage_factory: -> { R2StorageService.new },
    time_sources: -> { TimeTrackingSource.active.to_a },
    encryption_credentials: Rails.application.credentials,
    encrypted_data_probe: -> { EncryptedDataReadiness.verify! },
    http_get: nil
  )
    @env = env
    @environment = environment
    @config = config
    @primary_record = primary_record
    @cache = cache
    @cache_record = cache_record
    @queue_record = queue_record
    @queue_process = queue_process
    @cable_record = cable_record
    @job_adapter = job_adapter
    @cable_adapter = cable_adapter
    @storage_factory = storage_factory
    @time_sources = time_sources
    @encryption_credentials = encryption_credentials
    @encrypted_data_probe = encrypted_data_probe
    @http_get = http_get || method(:default_http_get)
  end

  def run(live: environment.production?)
    checks = configuration_checks
    checks.concat(live_dependency_checks) if live
    Report.new(checks: checks)
  end

  private

  attr_reader :env, :environment, :config, :primary_record, :cache, :cache_record,
    :queue_record, :queue_process, :cable_record, :job_adapter, :cable_adapter,
    :storage_factory, :time_sources, :encryption_credentials, :encrypted_data_probe, :http_get

  def configuration_checks
    [
      check("RAILS_ENV is production") { environment.production? },
      check("authentication is enabled") { env.fetch("AUTH_ENABLED", "true") == "true" },
      check("TLS is effectively forced") { config.force_ssl == true && config.assume_ssl == true },
      check("R2 is the effective Active Storage service") { config.active_storage.service.to_sym == :r2 },
      check("Solid Cache is the effective cache store") { Array(config.cache_store).first.to_sym == :solid_cache_store },
      check("Solid Queue is the effective job adapter") { job_adapter.class.name.include?("SolidQueue") },
      check("Solid Cable is the effective cable adapter") { cable_adapter == "solid_cable" },
      check("MFA enforcement is attested") { env["REQUIRE_MFA"] == "true" },
      check("effective trusted proxies reject arbitrary public clients") { trusted_proxies_are_bounded? },
      check("allowed frontend origins are explicit production HTTPS origins") { production_origins_valid? },
      check("mailer URL is a production HTTPS URL") { production_https_url?(env["FRONTEND_URL"]) },
      check("production Clerk keys are configured") { production_clerk_keys? },
      check("R2 credentials and bucket are configured") { r2_configuration_present? },
      check("Resend credentials and sender are configured") { resend_configuration_present? },
      check("time tracking destinations are allowlisted") { time_tracking_configuration_valid? },
      check("Active Record encryption is effectively configured") do
        ActiveRecordEncryptionConfiguration.configured?(config.active_record.encryption)
      end,
      check("Active Record encryption sources do not conflict") do
        !ActiveRecordEncryptionConfiguration.sources_conflict?(
          environment: environment,
          env: env,
          credentials: encryption_credentials
        )
      end
    ]
  end

  def live_dependency_checks
    [
      check("primary database accepts a query") { select_one(primary_record) },
      check("persisted encrypted data can be decrypted") { encrypted_data_probe.call },
      check("all database migrations are current") { ActiveRecord::Migration.check_all_pending!; true },
      check("Solid Cache round trip succeeds") { cache_round_trip },
      check("Solid Queue database accepts a query") { select_one(queue_record) },
      check("a Solid Queue worker has a recent heartbeat") do
        queue_process.where(kind: "Worker", last_heartbeat_at: 5.minutes.ago..).exists?
      end,
      check("Solid Cable database accepts a query") { select_one(cable_record) },
      check("R2 upload/read/delete round trip succeeds") { r2_round_trip },
      check("Resend API key and every application sender domain are ready") { resend_ready? },
      check("Clerk Backend API accepts the configured key") { clerk_ready? },
      check("time tracking destinations resolve only to public addresses") { time_tracking_destinations_resolve? }
    ]
  end

  def check(name)
    passed = yield == true
    Check.new(name: name, passed: passed, detail: passed ? "verified" : "not verified")
  rescue StandardError => e
    Check.new(name: name, passed: false, detail: "#{e.class.name} while verifying")
  end

  def trusted_proxies_are_bounded?
    proxies = config.action_dispatch.trusted_proxies.presence || ActionDispatch::RemoteIp::TRUSTED_PROXIES
    proxies.present? && proxies.all? { |proxy| private_proxy_network?(proxy) }
  end

  def private_proxy_network?(proxy)
    return false unless proxy.is_a?(IPAddr)

    first = proxy.to_range.first
    last = proxy.to_range.last
    PRIVATE_PROXY_NETWORKS.any? do |private_network|
      private_network.include?(first) && private_network.include?(last)
    end
  end

  def production_origins_valid?
    origins = env.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    origins.present? && origins.all? { |origin| production_https_url?(origin) }
  end

  def production_https_url?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) &&
      uri.host.present? &&
      uri.port == 443 &&
      uri.userinfo.blank? &&
      [ "", "/" ].include?(uri.path) &&
      uri.query.blank? &&
      uri.fragment.blank?
  rescue URI::InvalidURIError
    false
  end

  def production_clerk_keys?
    env["CLERK_PUBLISHABLE_KEY"].to_s.start_with?("pk_live_") &&
      env["CLERK_SECRET_KEY"].to_s.start_with?("sk_live_")
  end

  def r2_configuration_present?
    env.values_at("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ACCOUNT_ID").all?(&:present?) &&
      (env["R2_BUCKET_NAME"].presence || env["R2_BUCKET"].presence).present?
  end

  def resend_configuration_present?
    env["RESEND_API_KEY"].present? &&
      env["MAILER_FROM_EMAIL"].present? &&
      sender_emails.present? &&
      sender_emails.all? { |email| sender_domain(email).present? }
  end

  def sender_emails
    action_mailer_sender = env["MAILER_FROM_EMAIL"].presence
    direct_resend_sender = env["RESEND_FROM_EMAIL"].presence || action_mailer_sender
    [ action_mailer_sender, direct_resend_sender ].compact.uniq
  end

  def sender_domain(email)
    Mail::Address.new(email).domain.to_s.downcase.presence
  rescue Mail::Field::ParseError
    nil
  end

  def time_tracking_configuration_valid?
    TimeTracking::DestinationPolicy.production_configuration_valid?(sources: time_sources.call, env: env)
  end

  def select_one(record_class)
    record_class.connection.select_value("SELECT 1").to_i == 1
  end

  def cache_round_trip
    key = "production-readiness/#{SecureRandom.uuid}"
    value = SecureRandom.hex(24)
    cache.write(key, value, expires_in: 5.minutes)
    cache.read(key) == value
  ensure
    cache.delete(key) if key
  end

  def r2_round_trip
    storage = storage_factory.call
    key = "production-readiness/#{SecureRandom.uuid}.txt"
    payload = "cornerstone-payroll-readiness-#{SecureRandom.hex(24)}"

    storage.upload(key, StringIO.new(payload), content_type: "text/plain")
    storage.download(key) == payload
  ensure
    original_error = $!
    begin
      storage&.delete(key) if key
    rescue StandardError => cleanup_error
      raise cleanup_error unless original_error
    end
  end

  def resend_ready?
    status, body = http_get.call(URI("https://api.resend.com/domains"), env.fetch("RESEND_API_KEY"))
    return false unless status == 200

    ready_domains = Array(body["data"]).filter_map do |domain|
      next unless domain["status"] == "verified" && domain.dig("capabilities", "sending") == "enabled"

      domain["name"].to_s.downcase
    end
    sender_emails.all? { |email| ready_domains.include?(sender_domain(email)) }
  end

  def clerk_ready?
    status, body = http_get.call(URI("https://api.clerk.com/v1/instance"), env.fetch("CLERK_SECRET_KEY"))
    status == 200 && body["id"].present?
  end

  def time_tracking_destinations_resolve?
    policy = TimeTracking::DestinationPolicy.new(environment: "production", env: env)
    time_sources.call.all? do |source|
      policy.resolve_public_addresses!(URI.parse(source.base_url.to_s)).present?
    end
  end

  def default_http_get(uri, bearer_token)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{bearer_token}"
    request["Accept"] = "application/json"

    response = nil
    body = +""
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: true,
      open_timeout: 5,
      read_timeout: 10
    ) do |http|
      http.request(request) do |provider_response|
        response = provider_response
        provider_response.read_body do |chunk|
          body << chunk
          raise IOError, "Provider response exceeded readiness limit" if body.bytesize > MAX_PROVIDER_RESPONSE_BYTES
        end
      end
    end

    [ response.code.to_i, JSON.parse(body) ]
  end
end
