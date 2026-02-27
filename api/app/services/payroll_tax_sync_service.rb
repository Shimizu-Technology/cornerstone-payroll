# frozen_string_literal: true

require "net/http"
require "json"

class PayrollTaxSyncService
  class SyncError < StandardError; end
  class ConfigurationError < StandardError; end

  TIMEOUT_SECONDS = 30

  def initialize(pay_period)
    @pay_period = pay_period
  end

  def sync!
    validate_configuration!
    validate_pay_period!

    @pay_period.generate_idempotency_key!
    @pay_period.save! if @pay_period.tax_sync_idempotency_key_changed?
    @pay_period.mark_syncing!

    payload = PayrollTaxSyncPayloadBuilder.new(@pay_period).build
    response = post_to_cst(payload)

    handle_response(response)
  rescue SyncError, ConfigurationError => e
    @pay_period.mark_sync_failed!(e.message)
    raise
  rescue StandardError => e
    @pay_period.mark_sync_failed!("Unexpected error: #{e.message}")
    raise SyncError, e.message
  end

  private

  def validate_configuration!
    raise ConfigurationError, "CST_INGEST_URL is not configured" if ingest_url.blank?
  end

  def validate_pay_period!
    raise SyncError, "Pay period is not committed" unless @pay_period.committed?
    raise SyncError, "Pay period has no payroll items" unless @pay_period.payroll_items.exists?
  end

  def post_to_cst(payload)
    uri = URI.parse(ingest_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request["Idempotency-Key"] = @pay_period.tax_sync_idempotency_key
    request["Authorization"] = "Bearer #{api_token}" if api_token.present?
    request["X-Shared-Secret"] = shared_secret if shared_secret.present?
    request["X-Source"] = "cornerstone-payroll"
    request.body = payload.to_json

    http.request(request)
  end

  def handle_response(response)
    case response.code.to_i
    when 200, 201, 204
      @pay_period.mark_synced!
    when 409
      # Idempotent duplicate — treat as success
      @pay_period.mark_synced!
    when 400..499
      raise SyncError, "CST rejected payload (#{response.code}): #{response.body.to_s.truncate(500)}"
    when 500..599
      raise SyncError, "CST server error (#{response.code}): #{response.body.to_s.truncate(500)}"
    else
      raise SyncError, "Unexpected response from CST (#{response.code})"
    end
  end

  def ingest_url
    ENV["CST_INGEST_URL"]
  end

  def api_token
    ENV["CST_API_TOKEN"]
  end

  def shared_secret
    ENV["CST_SHARED_SECRET"].presence || ENV["CST_API_TOKEN"].presence
  end
end
