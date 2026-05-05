# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module TimeTracking
  class Client
    TIMEOUT_SECONDS = 15

    def initialize(source)
      @source = source
    end

    def time_summary(start_date:, end_date:)
      uri = URI.join(normalized_base_url, "/api/v1/payroll/time_summary")
      uri.query = URI.encode_www_form(start_date: start_date, end_date: end_date)

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["X-Shared-Secret"] = @source.shared_secret.to_s
      request["X-Payroll-Shared-Secret"] = @source.shared_secret.to_s

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "#{@source.name} returned #{response.code}: #{response.body.to_s.truncate(300)}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "#{@source.name} returned invalid JSON: #{e.message}"
    rescue Timeout::Error, Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Could not reach #{@source.name}: #{e.message}"
    end

    class Error < StandardError; end

    private

    def normalized_base_url
      base = @source.base_url.to_s.strip
      base.end_with?("/") ? base : "#{base}/"
    end
  end
end
