# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollTelemetry do
  def clock(*times)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(*times)
  end

  describe PayrollTelemetry::Requests do
    [ [ 503, 0.001, true ], [ 200, 0.5, true ], [ 200, 0.499, false ] ].each do |status, duration, should_log|
      it "handles status #{status} at #{duration * 1000} ms" do
        clock(0.0, duration)
        allow(Rails.logger).to receive(:warn).and_call_original
        response = [ status, {}, [ "response" ] ]
        app = described_class.new(->(_env) { response })

        expect(app.call({ "action_dispatch.request_id" => "demo", "PATH_INFO" => "/private" })).to eq(response)
        event = JSON.generate(event: "http.request", process_role: ProcessRole.current,
          status: status, duration_ms: (duration * 1000).round(2), request_id: "demo")
        if should_log
          expect(Rails.logger).to have_received(:warn).with(event).once
        else
          expect(Rails.logger).not_to have_received(:warn).with(event)
        end
      end
    end
  end

  describe PayrollTelemetry::PoolCheckout do
    let(:pool) do
      Class.new do
        prepend PayrollTelemetry::PoolCheckout

        private

        def acquire_connection(*) = :connection
        def db_config = Struct.new(:name).new("primary")
      end.new
    end

    it "logs waits of at least 50 ms and returns the acquired connection" do
      clock(0.0, 0.050)
      expect(Rails.logger).to receive(:warn).with(a_string_including('"event":"db.pool_checkout"', '"pool":"primary"', '"wait_ms":50.0')).once
      expect(pool.send(:acquire_connection, 10)).to eq(:connection)
    end

    it "skips shorter waits" do
      clock(0.0, 0.049)
      expect(Rails.logger).not_to receive(:warn)
      expect(pool.send(:acquire_connection, 10)).to eq(:connection)
    end
  end

  it "logs only uncached SQL over one second without the statement or bind values" do
    payload = { name: "Query", sql: "SELECT 'private'", binds: [] }
    expect(Rails.logger).to receive(:warn).with(JSON.generate(
      event: "db.slow_query", process_role: ProcessRole.current, duration_ms: 1001.0
    )).once

    ActiveSupport::Notifications.publish("sql.active_record", 0.0, 1.0, "test", payload)
    ActiveSupport::Notifications.publish("sql.active_record", 0.0, 1.001, "test", payload)
    ActiveSupport::Notifications.publish("sql.active_record", 0.0, 1.1, "test", payload.merge(cached: true))
  end
end
