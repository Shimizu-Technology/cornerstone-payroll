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

  it "prints safe machine-readable evidence and succeeds when every check passes" do
    report = ProductionReadiness::Report.new(
      checks: [ ProductionReadiness::Check.new(name: "safe probe", passed: true, detail: "verified") ],
      generated_at: Time.zone.parse("2026-08-23 12:00:00"),
      revision: "abc123"
    )
    allow(service).to receive(:run).with(live: false).and_return(report)

    expect { task.invoke }.to output(
      a_string_including(
        "PASS  safe probe (verified)",
        'EVIDENCE {"generated_at":"2026-08-23T12:00:00Z","revision":"abc123","passed":true',
        "Production configuration and live dependency probes passed"
      )
    ).to_stdout
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
