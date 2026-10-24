# frozen_string_literal: true

# Finite, deliberately slow HTTP response consumption. The real Timeout timer
# must interrupt read_body; no timeout runner or exception is stubbed here.
module CalendarStreamTransport
  class Http
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :verify_hostname, :min_version,
      :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_count, :finished, :request_sent

    def initialize(response, before_response: nil)
      @response = response
      @before_response = before_response
      @request_count = 0
    end

    def use_ssl?
      use_ssl
    end

    def start
      @started = true
    end

    def started?
      @started
    end

    def finish
      @finished = true
      @started = false
    end

    def request(request)
      @request_count += 1
      @request_sent = request
      @before_response&.call
      yield @response
    end
  end

  def streamed_calendar_client(source, payload:, delay: 0, chunks: 20, before_body: nil, before_response: nil)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "application/json"
    consumed = []
    response.define_singleton_method(:read_body) do |&consumer|
      before_body&.call
      chunks.times do
        sleep delay if delay.positive?
        consumed << " "
        consumer.call(" ")
      end
      consumer.call(payload.to_json)
    end
    http = Http.new(response, before_response: before_response)
    policy = TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(*) { [ "8.8.8.8" ] })
    client = TimeTracking::Client.new(source, destination_policy: policy, http_factory: ->(*) { http })
    [ client, http, consumed ]
  end
end
