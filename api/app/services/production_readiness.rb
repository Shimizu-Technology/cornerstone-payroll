# frozen_string_literal: true

require "json"
require "ipaddr"
require "mail"
require "net/http"
require "securerandom"
require "stringio"
require "uri"

class ProductionReadiness
  MFA_SAMPLE_MAX_AGE = 15.minutes
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

  Check = Data.define(:name, :passed, :detail) do
    # An advisory uses nil because it was not verified and does not block release.
    def status
      return "WARN" if passed.nil?

      passed ? "PASS" : "FAIL"
    end
  end

  class Report
    attr_reader :checks, :generated_at, :revision

    def initialize(checks:, connected_payroll: ConnectedPayrollMode.capability, generated_at: Time.current, revision: ENV.fetch("RENDER_GIT_COMMIT", ENV.fetch("GIT_COMMIT", "unknown")))
      @connected_payroll = connected_payroll
      @checks = checks
      @generated_at = generated_at
      @revision = revision
    end

    def passed?
      failures.empty?
    end

    def failures
      checks.select { |check| check.passed == false }
    end

    def as_json(*)
      {
        generated_at: generated_at.iso8601,
        revision: revision,
        passed: passed?,
        checks: checks.map { |check| check.to_h.merge(status: check.status) },
        connected_payroll: @connected_payroll
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
    time_sources: -> { TenantScope.as_system(reason: "Inspect integration destinations for readiness") { TimeTrackingSource.active.to_a } },
    encryption_credentials: Rails.application.credentials,
    encrypted_data_probe: -> { EncryptedDataReadiness.verify! },
    tax_configuration_valid: -> { AnnualTaxConfig.official_2026_configuration? },
    tax_year_readiness: -> {
      TenantScope.as_system(reason: "Check tax table verification across open pay periods") { TaxYearReadiness.new.as_json }
    },
    process_role: -> { ProcessRole.current },
    route_paths: -> { Rails.application.routes.routes.map { |route| route.path.spec.to_s } },
    cable_mount_path: -> { Rails.application.config.action_cable.mount_path },
    primary_pool_size: -> { ActiveRecord::Base.connection_pool.db_config.max_connections },
    rate_limit_store: -> { Rack::Attack.cache.store },
    rate_limit_probe: -> { Rack::Attack.cache.store.shared_round_trip },
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
    @tax_configuration_valid = tax_configuration_valid
    @tax_year_readiness = tax_year_readiness
    @process_role = process_role
    @route_paths = route_paths
    @cable_mount_path = cable_mount_path
    @primary_pool_size = primary_pool_size
    @rate_limit_store = rate_limit_store
    @rate_limit_probe = rate_limit_probe
    @http_get = http_get || method(:default_http_get)
  end

  def run(live: environment.production?)
    return StagingReadiness.new(env: env).run(live: live) if StagingOutboundPolicy.staging?(env)

    checks = configuration_checks
    if live
      checks.concat(live_dependency_checks)
      checks.concat(rls_checks) if RlsConfiguration.runtime_url(env)
    end
    Report.new(checks: checks, connected_payroll: ConnectedPayrollMode.capability(env: env, environment: environment))
  end

  private

  attr_reader :env, :environment, :config, :primary_record, :cache, :cache_record,
    :queue_record, :queue_process, :cable_record, :job_adapter, :cable_adapter,
    :storage_factory, :time_sources, :encryption_credentials, :encrypted_data_probe, :tax_configuration_valid, :http_get,
    :process_role, :route_paths, :cable_mount_path, :primary_pool_size, :rate_limit_store, :rate_limit_probe

  def configuration_checks
    checks = base_configuration_checks + employee_web_checks
    checks << resend_webhook_check unless employee_web?
    checks
  end

  def resend_webhook_check
    configured = env["RESEND_WEBHOOK_SECRET"].present?
    Check.new(
      name: "Resend webhook signing secret is configured",
      passed: configured ? true : nil,
      detail: configured ? "configured" : "Set RESEND_WEBHOOK_SECRET to receive W-2 notice delivery and bounce updates"
    )
  end

  def employee_web?
    env.fetch("APP_PROCESS_ROLE", ProcessRole::ALL) == ProcessRole::EMPLOYEE_WEB
  end

  # Applied only on the employee service. Payroll and `all` processes skip them.
  def employee_web_checks
    return [] unless employee_web?

    [
      check("employee_web: process role booted as employee_web without payroll routes or Cable") { employee_surface_isolated? },
      check("employee_web: database pool is capped at #{ProcessRole::EMPLOYEE_WEB_DB_POOL_MAX}, matches DB_POOL_MAX and runs one Puma process") { employee_pool_capped? },
      check("employee_web: rate-limit counters use the shared Redis store") do
        RackAttackStore.shared_url?(env["RACK_ATTACK_REDIS_URL"]) && rate_limit_store.call.is_a?(RackAttackStore::Failover)
      end,
      check("employee_web: Clerk authorized parties are explicit production HTTPS origins") { clerk_authorized_parties_valid? }
    ]
  end

  def employee_surface_isolated?
    paths = route_paths.call
    process_role.call == ProcessRole::EMPLOYEE_WEB &&
      cable_mount_path.call.nil? &&
      paths.present? &&
      paths.all? { |path| ProcessRole::EMPLOYEE_WEB_ROUTE_PATTERN.match?(path) }
  end

  def employee_pool_setting
    Integer(env["DB_POOL_MAX"].to_s.strip, 10)
  rescue ArgumentError
    nil
  end

  # Puma (config/puma.rb) runs cluster mode only for WEB_CONCURRENCY >= 2, so a
  # larger value multiplies the pool by that many processes. Solid Queue in Puma
  # adds a supervisor, workers and dispatcher that also hold connections.
  PUMA_TRUTHY = %w[1 true t yes y on].freeze

  def employee_single_process?
    env.fetch("WEB_CONCURRENCY", "0").to_s.strip.to_i < 2 &&
      !PUMA_TRUTHY.include?(env.fetch("SOLID_QUEUE_IN_PUMA", "false").to_s.strip.downcase)
  end

  def employee_pool_capped?
    configured = employee_pool_setting
    configured.present? &&
      configured.between?(1, ProcessRole::EMPLOYEE_WEB_DB_POOL_MAX) &&
      primary_pool_size.call == configured &&
      employee_single_process?
  end

  def base_configuration_checks
    [
      check("RAILS_ENV is production") { environment.production? },
      check("authentication is enabled") { env.fetch("AUTH_ENABLED", "true") == "true" },
      check("TLS is effectively forced") { config.force_ssl == true && config.assume_ssl == true },
      check("R2 is the effective Active Storage service") { config.active_storage.service.to_sym == :r2 },
      check("Solid Cache is the effective cache store") { Array(config.cache_store).first.to_sym == :solid_cache_store },
      check("Solid Queue is the effective job adapter") { job_adapter.class.name.include?("SolidQueue") },
      check("Solid Cable is the effective cable adapter") { cable_adapter == "solid_cable" },
      check("MFA enforcement has instance-bound evidence") { mfa_attestation_recorded? },
      check("effective trusted proxies reject arbitrary public clients") { trusted_proxies_are_bounded? },
      check("shared rate-limit store is configured for split or multi-worker web") do
        shared_required = env.fetch("WEB_CONCURRENCY", "1").to_i > 1 ||
          env.fetch("APP_PROCESS_ROLE", ProcessRole::ALL) != ProcessRole::ALL
        !shared_required || RackAttackStore.shared_url?(env["RACK_ATTACK_REDIS_URL"])
      end,
      check("allowed frontend origins are explicit production HTTPS origins") { production_origins_valid? },
      check("mailer URL is a production HTTPS URL") { production_https_url?(env["FRONTEND_URL"]) },
      check("production Clerk keys are configured") { production_clerk_keys? },
      check("Clerk authorized parties are explicit production HTTPS origins") { clerk_authorized_parties_valid? },
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
      end,
      check("official 2026 payroll tax and withholding configuration is loaded") { tax_configuration_valid.call }
    ] + @tax_year_readiness.call.fetch(:warnings).map do |warning|
      Check.new(name: "#{warning.fetch(:tax_year)} payroll tax tables are verified", passed: false, detail: warning.fetch(:message))
    end
  end

  def rls_checks
    [
      check("RLS runtime role and kill switch privileges") do
        primary_record.connection_pool.with_connection { |connection| RlsDatabase.verify_runtime!(connection) }
      end,
      check("RLS policy installation matches the selected phase") do
        primary_record.connection_pool.with_connection do |connection|
          RlsDatabase.expected_phase?(connection, enforced: env["RLS_EXPECT_ENFORCED"] == "true")
        end
      end,
      check("Cross-company login link decision is a restricted SECURITY DEFINER function") do
        primary_record.connection_pool.with_connection { |connection| RlsDatabase.login_link_decision_ready?(connection) }
      end
    ]
  end

  def live_dependency_checks
    jwks_cache = ActiveSupport::Cache::MemoryStore.new
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
      check("Clerk Backend API accepts the configured key and matches MFA evidence") { clerk_ready? },
      check("Clerk session token includes the MFA enrollment claim") { clerk_mfa_sample_ready?(jwks_cache: jwks_cache) },
      check("Pre-flip MFA check: Clerk session token includes boolean two_factor_enabled claim") { clerk_mfa_sample_token_valid?(jwks_cache: jwks_cache) },
      check("time tracking destinations resolve only to public addresses") { time_tracking_destinations_resolve? }
    ] + shared_rate_limit_live_checks
  end

  # The Failover store falls back to process-local counters when Redis is down,
  # so only a direct write and delete on the shared store proves it is reachable.
  def shared_rate_limit_live_checks
    return [] unless employee_web? || RackAttackStore.shared_url?(env["RACK_ATTACK_REDIS_URL"])

    [ check("shared rate-limit store accepts a write and delete round trip") { rate_limit_probe.call } ]
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

  def clerk_authorized_parties_valid?
    parties = env.fetch("CLERK_AUTHORIZED_PARTIES", "").split(",").map(&:strip).reject(&:empty?)
    parties.present? && parties.all? { |party| ClerkTokenVerifier.valid_production_https_origin?(party) }
  end

  def mfa_attestation_recorded?
    raw_instance_id = env["CLERK_MFA_ATTESTED_INSTANCE_ID"].to_s
    raw_evidence_ref = env["CLERK_MFA_EVIDENCE_REF"].to_s
    return false if raw_instance_id.match?(/[\r\n]/) || raw_evidence_ref.match?(/[\r\n]/)

    instance_id = raw_instance_id.strip
    evidence_ref = raw_evidence_ref.strip

    MfaPolicy.enabled?(env: env) &&
      instance_id.match?(/\Ains_[A-Za-z0-9]+\z/) &&
      evidence_ref.present? &&
      evidence_ref.bytesize <= 500
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
    key = StagingStoragePolicy.new_key("production-readiness/#{SecureRandom.uuid}.txt")
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
    status == 200 &&
      body["id"].present? &&
      body["id"] == env["CLERK_MFA_ATTESTED_INSTANCE_ID"].to_s.strip
  end

  def clerk_mfa_sample_ready?(jwks_cache: ActiveSupport::Cache::MemoryStore.new)
    return true unless MfaPolicy.enabled?(env: env)

    clerk_mfa_sample_token_valid?(jwks_cache: jwks_cache)
  end

  def clerk_mfa_sample_token_valid?(jwks_cache: ActiveSupport::Cache::MemoryStore.new)
    path = env["CLERK_MFA_SAMPLE_TOKEN_FILE"].presence
    return false unless path

    verifier = ClerkTokenVerifier.new(env: env, cache: jwks_cache,
      http_get: ->(uri) { http_get.call(uri, nil) })
    # Clerk session tokens live about 60 seconds, which is shorter than the
    # probes that run before this one. A recently issued, correctly signed
    # token still proves what the template outputs, so allow a short window.
    payload = verifier.verify(File.read(path, 16.kilobytes).strip, exp_leeway: MFA_SAMPLE_MAX_AGE.to_i)
    payload && payload["sid"].present? &&
      payload["iat"].is_a?(Integer) && payload["iat"] >= MFA_SAMPLE_MAX_AGE.ago.to_i &&
      [ true, false ].include?(payload[MfaPolicy::ENROLLMENT_CLAIM])
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
