# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeServiceObservation, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:check) { Struct.new(:name, :passed) }
  let(:readiness) { double(employee_service_checks: [ check.new("employee_web: pool", true), check.new("employee_web: redis", false) ]) }
  let(:env) do
    { "APP_PROCESS_ROLE" => "employee_web", "RLS_CONTEXT_GUARD_MODE" => "raise", "REQUIRE_MFA" => "true",
      "CLERK_MFA_ATTESTED_INSTANCE_ID" => "ins_example", "CLERK_MFA_EVIDENCE_REF" => "ref",
      "CLERK_AUTHORIZED_PARTIES" => "https://harborfinch.example.com", "RENDER_GIT_COMMIT" => "abc123" }
  end

  it "records what the employee service observes about itself, at most once per interval" do
    freeze_time do
      expect(described_class.record_current_process!(dependencies_healthy: true, env: env, readiness: -> { readiness })).to be(true)
      row = described_class.current
      expect(row).to have_attributes(process_role: "employee_web", rls_guard_mode: "raise", require_mfa: true,
        mfa_evidence_recorded: true, authorized_parties_valid: true, dependencies_healthy: true, revision: "abc123",
        service_checks_passed: false, failed_checks: [ "employee_web: redis" ], observed_at: Time.current)
      # The test database role isn't the restricted runtime role.
      expect(row.rls_runtime_role_verified).to be(false)
      expect(row.rls_guard_raise?).to be(false)
      expect(row).to be_fresh

      expect(described_class.record_current_process!(dependencies_healthy: false, env: env, readiness: -> { readiness })).to be(false)
      travel 31.seconds
      expect(described_class.record_current_process!(dependencies_healthy: false, env: env, readiness: -> { readiness })).to be(true)
      expect(described_class.current.dependencies_healthy).to be(false)
      expect(described_class.count).to eq(1)
      travel 6.minutes
      expect(described_class.current).not_to be_fresh
    end
  end

  it "never records from Payroll web or an all-in-one process" do
    %w[payroll_web all].each do |role|
      expect(described_class.record_current_process!(dependencies_healthy: true, env: env.merge("APP_PROCESS_ROLE" => role),
        readiness: -> { readiness })).to be(false)
    end
    expect(described_class.count).to eq(0)
  end

  it "is written by the health check on the employee service only" do
    allow(DependencyHealth).to receive(:new).and_return(double(run: double(ready?: true)))
    allow(described_class).to receive(:record_current_process!).and_call_original
    get "/health/dependencies"
    expect(described_class).to have_received(:record_current_process!).with(dependencies_healthy: true)
    expect(described_class.count).to eq(0)
  end
end
