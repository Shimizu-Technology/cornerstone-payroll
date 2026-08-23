# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module TimeTracking
  class Client
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 15
    WRITE_TIMEOUT_SECONDS = 15
    MAX_RESPONSE_BYTES = 1.megabyte

    def initialize(source, destination_policy: DestinationPolicy.new, http_factory: nil)
      @source = source
      @destination_policy = destination_policy
      @http_factory = http_factory || ->(host, port) { Net::HTTP.new(host, port, nil) }
    end

    def time_summary(start_date:, end_date:)
      uri = time_summary_uri(start_date: start_date, end_date: end_date)

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Accept-Encoding"] = "identity"
      request["X-Shared-Secret"] = @source.shared_secret.to_s
      request["X-Payroll-Shared-Secret"] = @source.shared_secret.to_s

      pinned_ips = @destination_policy.resolve_public_addresses!(uri)
      response, body = perform_request(uri, request, pinned_ips)

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "#{@source.name} returned HTTP #{response.code}"
      end
      content_type = response["Content-Type"].to_s.downcase
      raise Error, "#{@source.name} returned a non-JSON response" unless content_type.start_with?("application/json")

      payload = JSON.parse(body)
      raise Error, "#{@source.name} returned an invalid payload" unless payload.is_a?(Hash)

      validate_source_identity!(payload)
      payload
    rescue JSON::ParserError
      raise Error, "#{@source.name} returned invalid JSON"
    rescue DestinationPolicy::Error => e
      raise Error, "#{@source.name} destination rejected: #{e.message}"
    rescue Timeout::Error, SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout,
           OpenSSL::SSL::SSLError
      raise Error, "Could not securely reach #{@source.name}"
    end

    class Error < StandardError; end

    private

    def time_summary_uri(start_date:, end_date:)
      uri = URI.parse(@source.base_url.to_s.strip)
      base_path = uri.path.to_s.chomp("/")
      uri.path = "#{base_path}/api/v1/payroll/time_summary"
      uri.query = URI.encode_www_form(start_date: start_date, end_date: end_date)
      uri.fragment = nil
      uri
    end

    def perform_request(uri, request, pinned_ips)
      last_connection_error = nil

      pinned_ips.each do |pinned_ip|
        http = build_http(uri, pinned_ip)
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

    def build_http(uri, pinned_ip)
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
      http.open_timeout = OPEN_TIMEOUT_SECONDS
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

    def validate_source_identity!(payload)
      return if @source.source_type == "custom"

      raise Error, "#{@source.name} response omitted source identity" if payload["source"].blank?

      returned_source = payload["source"].to_s
      return if returned_source == @source.source_type

      raise Error, "#{@source.name} responded as #{returned_source.presence || 'an unknown source'}, expected #{@source.source_type}"
    end
  end
end
