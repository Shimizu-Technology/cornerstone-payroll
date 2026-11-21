# frozen_string_literal: true

require "net/http"

module TaxWorkHours
  # GET /api/v1/payroll/work_hours, signed per the Work Hours v1 contract.
  # Tax returns one range (at most 62 days after start) per request and does
  # not paginate, so callers ask for one calendar month at a time.
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30
    ATTEMPTS = 3
    RETRY_STATUSES = [ 429, 500, 502, 504 ].freeze
    NETWORK_ERRORS = [ Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                       SocketError, EOFError, OpenSSL::SSL::SSLError, Net::OpenTimeout, Net::ReadTimeout ].freeze
    APPROVAL_STATES = WorkHourRow::APPROVAL_STATES

    def initialize(configuration: Configuration.current, sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now })
      @configuration = configuration
      @sleeper = sleeper
      @clock = clock
    end

    def fetch(start_date:, end_date:)
      raise Error.new("not_connected", @configuration.url_problem) unless @configuration.connected?

      (1..ATTEMPTS).each do |attempt|
        response = begin
          perform(start_date, end_date)
        rescue *NETWORK_ERRORS => e
          raise Error.new("network", e.class.name.demodulize) if attempt == ATTEMPTS

          @sleeper.call(backoff(attempt))
          next
        end
        status = response.code.to_i
        if RETRY_STATUSES.include?(status) && attempt < ATTEMPTS
          @sleeper.call(backoff(attempt))
          next
        end
        return handle(response, status)
      end
    end

    private

    def perform(start_date, end_date)
      base = @configuration.uri
      path = "#{base.path.to_s.chomp('/')}#{Signer::PATH}"
      request_uri, headers = Signer.signed(secret: @configuration.secret, path: path,
                                           query: { start: start_date.iso8601, end: end_date.iso8601 }, now: @clock.call)
      http = Net::HTTP.new(base.host, base.port)
      http.use_ssl = base.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      request = Net::HTTP::Get.new(request_uri, headers.merge("Accept" => "application/json"))
      http.request(request)
    end

    def backoff(attempt)
      0.5 * (2**(attempt - 1))
    end

    def handle(response, status)
      case status
      when 200 then parse(response.body)
      when 401 then raise Error.new("unauthorized")
      when 503 then raise Error.new("tax_not_configured")
      when 400, 422 then raise Error.new("invalid_request", "HTTP #{status}")
      when 500..599 then raise Error.new("server_error", "HTTP #{status}")
      else raise Error.new("bad_response", "HTTP #{status}")
      end
    end

    def parse(body)
      payload = JSON.parse(body.to_s)
      raise Error.new("bad_response", "not a JSON object") unless payload.is_a?(Hash)
      raise Error.new("bad_response", "schema #{payload['schema_version'].inspect}") unless payload["schema_version"].to_s.start_with?("1.")
      raise Error.new("bad_response", "rows missing") unless payload["rows"].is_a?(Array)

      payload["rows"].each_with_index { |row, index| validate_row!(row, index) }
      payload
    rescue JSON::ParserError
      raise Error.new("bad_response", "not JSON")
    end

    def validate_row!(row, index)
      valid = row.is_a?(Hash) && row["tax_user_id"].is_a?(Integer) && iso_date?(row["work_date"]) &&
        row["hours"].is_a?(Numeric) && row["hours"] >= 0 && APPROVAL_STATES.include?(row["approval_state"]) &&
        (row["client_id"].nil? || row["client_id"].is_a?(Integer)) && row["client_name"].is_a?(String) &&
        [ true, false ].include?(row["unassigned"])
      raise Error.new("bad_response", "row #{index + 1} is incomplete") unless valid
    end

    def iso_date?(value)
      value.is_a?(String) && Date.iso8601(value)
    rescue Date::Error
      false
    end
  end
end
