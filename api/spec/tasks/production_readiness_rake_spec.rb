# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "production:readiness" do
  let(:task) { Rake::Task["production:readiness"] }
  let(:service) { instance_double(ProductionReadiness) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("production:readiness")
    task.reenable
    allow(ProductionReadiness).to receive(:new).and_return(service)
  end

  [ 0, 1, 2 ].each do |count|
    it "reports successful readiness with #{count} advisory warnings" do
      warnings = Array.new(count) do
        ProductionReadiness::Check.new(name: "optional probe", passed: false, detail: "not configured", advisory: true)
      end
      report = ProductionReadiness::Report.new(
        checks: [ ProductionReadiness::Check.new(name: "safe probe", passed: true, detail: "verified"), *warnings ],
        generated_at: Time.zone.parse("2026-08-23 12:00:00"),
        revision: "abc123"
      )
      allow(service).to receive(:run).with(live: false).and_return(report)
      lines = [
        "PASS  safe probe (verified)",
        'EVIDENCE {"generated_at":"2026-08-23T12:00:00Z","revision":"abc123","passed":true',
        [
          "Production configuration and live dependency probes passed.",
          "Production configuration and live dependency probes passed (1 warning).",
          "Production configuration and live dependency probes passed (2 warnings)."
        ].fetch(count)
      ]
      lines << "WARN  optional probe (not configured)" if count.positive?

      expect { task.invoke }.to output(a_string_including(*lines)).to_stdout
    end
  end

  it "fails closed while preserving the evidence line when a check fails" do
    report = ProductionReadiness::Report.new(
      checks: [ ProductionReadiness::Check.new(name: "provider probe", passed: false, detail: "IOError while verifying") ],
      generated_at: Time.zone.parse("2026-08-23 12:00:00"),
      revision: "abc123"
    )
    allow(service).to receive(:run).with(live: false).and_return(report)

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(a_string_including("Production readiness failed (1 control(s)).")).to_stderr
      .and output(a_string_including("FAIL  provider probe", '"passed":false')).to_stdout
  end
end
