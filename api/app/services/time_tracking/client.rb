# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"
require "timeout"

module TimeTracking
  class Client
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 15
    WRITE_TIMEOUT_SECONDS = 15
    MAX_RESPONSE_BYTES = 1.megabyte
    MAX_REMOTE_ERROR_BYTES = 300
    MAX_COCKPIT_EMPLOYEES_PER_PAGE = 100
    MAX_COCKPIT_ENTRIES_PER_PAGE = 250

    def initialize(source, delegation: nil, destination_policy: DestinationPolicy.new, http_factory: nil, monotonic_clock: nil, timeout_runner: nil)
      @source = source
      @delegation = delegation
      @destination_policy = destination_policy
      @http_factory = http_factory || ->(host, port) { Net::HTTP.new(host, port, nil) }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @timeout_runner = timeout_runner || ->(seconds, &block) { Timeout.timeout(seconds, Net::OpenTimeout, &block) }
    end

    def time_summary(start_date:, end_date:)
      request_json(time_summary_uri(start_date: start_date, end_date: end_date), validate_source: true)
    end

    def payroll_batches(start_date:, end_date:)
      payload = request_json(payroll_batches_uri(start_date: start_date, end_date: end_date), validate_source: false)
      raise Error, "#{@source.name} returned an invalid payroll batch list" unless payload["payroll_batches"].is_a?(Array)

      payload
    end

    def payroll_batch(batch_id:)
      request_json(payroll_batch_uri(batch_id), validate_source: true)
    end

    def publish_payroll_calendar_period(external_pay_period_id:, payload:, idempotency_key:)
      request_json(
        payroll_calendar_period_uri(external_pay_period_id),
        validate_source: false,
        method: :put,
        body: payload,
        headers: { "Idempotency-Key" => idempotency_key }
      )
    end

    def payroll_calendar_period(external_pay_period_id:)
      request_json(payroll_calendar_period_uri(external_pay_period_id), validate_source: false)
    end

    def payroll_cockpit_period(external_pay_period_id:)
      request_json(payroll_cockpit_period_uri(external_pay_period_id), validate_source: false, surface_remote_error: true)
    end

    def payroll_cockpit_employees(page: 1, per_page: 100, active: nil)
      query = bounded_pagination(page, per_page, maximum: MAX_COCKPIT_EMPLOYEES_PER_PAGE)
      query[:active] = active unless active.nil?
      request_json(payroll_cockpit_uri("/employees", query), validate_source: false, surface_remote_error: true)
    end

    def payroll_cockpit_time_entries(external_pay_period_id:, page: 1, per_page: 250, employee_id: nil, approval_status: nil)
      query = {
        external_pay_period_id: normalize_external_pay_period_id(external_pay_period_id)
      }.merge(bounded_pagination(page, per_page, maximum: MAX_COCKPIT_ENTRIES_PER_PAGE))
      query[:employee_id] = employee_id if employee_id.present?
      query[:approval_status] = approval_status if approval_status.present?
      request_json(payroll_cockpit_uri("/time_entries", query), validate_source: false, surface_remote_error: true)
    end

    def payroll_cockpit_exceptions(external_pay_period_id:, page: 1, per_page: 250, leave_page: 1, leave_per_page: 100)
      query = {
        external_pay_period_id: normalize_external_pay_period_id(external_pay_period_id)
      }.merge(bounded_pagination(page, per_page, maximum: MAX_COCKPIT_ENTRIES_PER_PAGE))
        .merge(
          bounded_pagination(leave_page, leave_per_page, maximum: MAX_COCKPIT_EMPLOYEES_PER_PAGE)
            .transform_keys { |key| "leave_#{key}".to_sym }
        )
      request_json(payroll_cockpit_uri("/exceptions", query), validate_source: false, surface_remote_error: true)
    end

    def approve_payroll_time_entry(entry_id:, command_id:, expected_version:, decision:, reason:)
      delegated_request_json(
        payroll_cockpit_time_entry_approval_uri(entry_id),
        body: {
          command_id: command_id,
          expected_version: expected_version,
          decision: decision,
          reason: reason
        }
      )
    end

    def finalize_payroll_cockpit_period(external_pay_period_id:, command_id:, expected_version:, reason:)
      delegated_request_json(
        payroll_cockpit_finalize_uri(external_pay_period_id),
        body: {
          command_id: command_id,
          expected_version: expected_version,
          reason: reason
        }
      )
    end

    def record_payroll_batch_processing_event(batch_id:, event_id:, status:, occurred_at:, external_pay_period_id:, metadata: {})
      request_json(
        payroll_batch_processing_events_uri(batch_id),
        validate_source: false,
        method: :post,
        body: {
          event_id: event_id,
          status: status,
          occurred_at: occurred_at,
          external_system: "cornerstone_payroll",
          external_pay_period_id: external_pay_period_id,
          metadata: metadata
        }
      )
    end

    def record_payroll_entry_processing_event(batch_id:, event_id:, status:, occurred_at:, external_pay_period_id:, external_payroll_item_id:, source_time_entry_id:, source_user_uuid: nil, payment_method: nil, payment_reference: nil, metadata: {})
      request_json(
        payroll_batch_processing_events_uri(batch_id),
        validate_source: false,
        method: :post,
        body: {
          event_id: event_id,
          status: status,
          occurred_at: occurred_at,
          external_system: "cornerstone_payroll",
          external_pay_period_id: external_pay_period_id,
          external_payroll_item_id: external_payroll_item_id,
          source_time_entry_id: source_time_entry_id,
          source_user_uuid: source_user_uuid,
          payment_method: payment_method,
          payment_reference: payment_reference,
          metadata: metadata
        }.compact
      )
    end

    class Error < StandardError
      attr_reader :response_status

      def initialize(message, response_status: nil)
        @response_status = response_status
        super(message)
      end
    end

    private

    def request_json(uri, validate_source:, method: :get, body: nil, headers: {}, surface_remote_error: false)
      request = case method
      when :get then Net::HTTP::Get.new(uri)
      when :post then Net::HTTP::Post.new(uri)
      when :put then Net::HTTP::Put.new(uri)
      else raise ArgumentError, "Unsupported HTTP method"
      end
      request["Accept"] = "application/json"
      request["Accept-Encoding"] = "identity"
      request["X-Shared-Secret"] = @source.shared_secret.to_s
      request["X-Payroll-Shared-Secret"] = @source.shared_secret.to_s
      headers.each { |key, value| request[key] = value }
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      connection_deadline = @monotonic_clock.call + OPEN_TIMEOUT_SECONDS
      pinned_ips = resolve_public_addresses(uri, connection_deadline)
      response, body = perform_request(uri, request, pinned_ips, connection_deadline)

      unless response.is_a?(Net::HTTPSuccess)
        message = surface_remote_error ? remote_error_message(response, body) : nil
        raise Error.new(message || "#{@source.name} returned HTTP #{response.code}", response_status: response.code.to_i)
      end
      content_type = response["Content-Type"].to_s.downcase
      raise Error, "#{@source.name} returned a non-JSON response" unless content_type.start_with?("application/json")

      payload = JSON.parse(body)
      raise Error, "#{@source.name} returned an invalid payload" unless payload.is_a?(Hash)

      validate_source_identity!(payload) if validate_source
      payload
    rescue JSON::ParserError
      raise Error, "#{@source.name} returned invalid JSON"
    rescue DestinationPolicy::Error => e
      raise Error, "#{@source.name} destination rejected: #{e.message}"
    rescue Timeout::Error, SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout,
           OpenSSL::SSL::SSLError
      raise Error, "Could not securely reach #{@source.name}"
    end

    def time_summary_uri(start_date:, end_date:)
      uri = source_uri("/api/v1/payroll/time_summary")
      uri.query = URI.encode_www_form(start_date: start_date, end_date: end_date)
      uri
    end

    def payroll_batches_uri(start_date:, end_date:)
      uri = source_uri("/api/v1/payroll/batches")
      uri.query = URI.encode_www_form(start_date: start_date, end_date: end_date)
      uri
    end

    def payroll_batch_uri(batch_id)
      normalized_id = batch_id.to_s
      unless normalized_id.match?(/\A[A-Za-z0-9._-]+\z/) && normalized_id.match?(/[A-Za-z0-9_-]/)
        raise Error, "Invalid payroll batch ID"
      end

      source_uri("/api/v1/payroll/batches/#{normalized_id}")
    end

    def payroll_batch_processing_events_uri(batch_id)
      uri = payroll_batch_uri(batch_id)
      uri.path = "#{uri.path}/processing_events"
      uri
    end

    def payroll_calendar_period_uri(external_pay_period_id)
      source_uri("/api/v1/payroll/calendar_periods/#{normalize_external_pay_period_id(external_pay_period_id)}")
    end

    def payroll_cockpit_period_uri(external_pay_period_id)
      source_uri("/api/v1/payroll/cockpit/periods/#{normalize_external_pay_period_id(external_pay_period_id)}")
    end

    def payroll_cockpit_finalize_uri(external_pay_period_id)
      uri = payroll_cockpit_period_uri(external_pay_period_id)
      uri.path = "#{uri.path}/finalize"
      uri
    end

    def payroll_cockpit_time_entry_approval_uri(entry_id)
      normalized_id = entry_id.to_s
      raise Error, "Invalid AIRE time entry ID" unless normalized_id.match?(/\A[1-9]\d*\z/)

      source_uri("/api/v1/payroll/cockpit/time_entries/#{normalized_id}/approval")
    end

    def payroll_cockpit_uri(path, query = nil)
      uri = source_uri("/api/v1/payroll/cockpit#{path}")
      uri.query = URI.encode_www_form(query) if query.present?
      uri
    end

    def bounded_pagination(page, per_page, maximum:)
      {
        page: [ page.to_i, 1 ].max,
        per_page: per_page.to_i.clamp(1, maximum)
      }
    end

    def normalize_external_pay_period_id(value)
      normalized_id = value.to_s.downcase
      unless normalized_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
        raise Error, "Invalid payroll calendar period ID"
      end

      normalized_id
    end

    def delegated_request_json(uri, body:)
      token = @delegation&.token.to_s
      raise Error, "Your AIRE payroll delegation is not configured" if token.blank?

      request_json(
        uri,
        validate_source: false,
        method: :post,
        body: body,
        headers: { "X-Aire-Delegation-Token" => token },
        surface_remote_error: true
      )
    end

    def source_uri(suffix)
      uri = URI.parse(@source.base_url.to_s.strip)
      base_path = uri.path.to_s.chomp("/")
      uri.path = "#{base_path}#{suffix}"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def resolve_public_addresses(uri, connection_deadline)
      @timeout_runner.call(remaining_timeout!(connection_deadline)) do
        @destination_policy.resolve_public_addresses!(uri)
      end
    end

    def perform_request(uri, request, pinned_ips, connection_deadline)
      last_connection_error = nil

      pinned_ips.each do |pinned_ip|
        remaining_open_timeout = remaining_timeout(connection_deadline)
        break unless remaining_open_timeout&.positive?

        http = build_http(uri, pinned_ip, open_timeout: remaining_open_timeout)
        begin
          http.start
        rescue SystemCallError, SocketError, Net::OpenTimeout, OpenSSL::SSL::SSLError => e
          last_connection_error = e
          next
        end

        begin
          return read_response(http, request)
        ensure
          http.finish if http.started?
        end
      end

      raise last_connection_error || Error.new("#{@source.name} has no reachable inspected address")
    end

    def remaining_timeout(connection_deadline)
      connection_deadline - @monotonic_clock.call
    end

    def remaining_timeout!(connection_deadline)
      remaining = remaining_timeout(connection_deadline)
      raise Net::OpenTimeout unless remaining.positive?

      remaining
    end

    def build_http(uri, pinned_ip, open_timeout:)
      # Pass nil as the proxy address so HTTP_PROXY cannot reroute a request
      # carrying the shared integration secret. `ipaddr` pins the connection
      # to the address that the destination policy inspected, while `address`
      # remains the hostname used for Host and TLS verification.
      http = @http_factory.call(uri.host, uri.port)
      http.ipaddr = pinned_ip
      http.use_ssl = uri.scheme == "https"
      if http.use_ssl?
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      end
      http.open_timeout = open_timeout
      http.read_timeout = READ_TIMEOUT_SECONDS
      http.write_timeout = WRITE_TIMEOUT_SECONDS
      http.max_retries = 0
      http
    end

    def read_response(http, request)
      response = nil
      body = +""
      http.request(request) do |streamed_response|
        response = streamed_response
        declared_size = streamed_response["Content-Length"].presence&.to_i
        raise Error, "#{@source.name} response exceeded #{MAX_RESPONSE_BYTES} bytes" if declared_size&.>(MAX_RESPONSE_BYTES)

        streamed_response.read_body do |chunk|
          body << chunk
          raise Error, "#{@source.name} response exceeded #{MAX_RESPONSE_BYTES} bytes" if body.bytesize > MAX_RESPONSE_BYTES
        end
      end

      [ response, body ]
    end

    def remote_error_message(response, body)
      return unless response["Content-Type"].to_s.downcase.start_with?("application/json")

      payload = JSON.parse(body)
      return unless payload.is_a?(Hash)

      message = payload["error"]
      return unless message.is_a?(String) && message.present?

      normalized = message.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
      return if normalized.bytesize > MAX_REMOTE_ERROR_BYTES

      "#{@source.name}: #{normalized}"
    rescue JSON::ParserError
      nil
    end

    def validate_source_identity!(payload)
      return if @source.source_type == "custom"

      raise Error, "#{@source.name} response omitted source identity" if payload["source"].blank?

      returned_source = payload["source"].to_s
      return if returned_source == @source.source_type

      raise Error, "#{@source.name} responded as #{returned_source.presence || 'an unknown source'}, expected #{@source.source_type}"
    end
  end
end
