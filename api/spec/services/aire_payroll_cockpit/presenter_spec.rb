# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCockpit::Presenter do
  it "preserves the upstream sequence of tied audit events while decorating settlement employees" do
    source = create(:time_tracking_source, source_type: "aire_services")
    events = [
      { "id" => "ffffffff-ffff-4fff-8fff-ffffffffffff", "event_type" => "opened", "occurred_at" => "2026-10-24T09:00:00Z" },
      { "id" => "00000000-0000-4000-8000-000000000000", "event_type" => "routed", "occurred_at" => "2026-10-24T09:00:00Z" }
    ]
    payload = { "settlement_cases" => [ { "id" => SecureRandom.uuid, "status" => "scheduled", "events" => events,
      "employee" => { "payroll_integration_id" => SecureRandom.uuid } } ] }
    original = payload.deep_dup

    result = described_class.new(source: source).settlement_cases(payload)
    expect(result["settlement_cases"].first["events"]).to eq(events)
    expect(result["settlement_cases"].first.dig("employee", "cornerstone", "status")).to eq("unmapped")
    expect(payload).to eq(original)
  end

  it "suggests by email for a unique real address, and falls back to name when the address is shared" do
    company = create(:company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    unique_emp = create(:employee, company: company, first_name: "Unique", last_name: "Employee", email: "unique.aire@example.com")
    create(:employee, company: company, first_name: "First", last_name: "Shared", email: "shared.family@example.com")
    second_shared = create(:employee, company: company, first_name: "Second", last_name: "Shared", email: "shared.family@example.com")

    presenter = described_class.new(source: source)

    real_suggestions = presenter.send(:suggestions_for, "email" => "unique.aire@example.com", "full_name" => "Different Name")
    expect(real_suggestions).to eq([
      {
        "employee_id" => unique_emp.id,
        "employee_name" => "Unique Employee",
        "email" => "unique.aire@example.com",
        "basis" => "same_email"
      }
    ])

    shared_suggestions = presenter.send(:suggestions_for, "email" => "shared.family@example.com", "full_name" => "Second Shared")
    expect(shared_suggestions).to eq([
      {
        "employee_id" => second_shared.id,
        "employee_name" => "Second Shared",
        "email" => "shared.family@example.com",
        "basis" => "same_name"
      }
    ])
  end

  it "loads organization marked placeholders at most once per presenter instance across multiple employees" do
    company = create(:company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    EmployeePlaceholderEmail.create!(organization: company.organization, email: "office-desk@example.com")
    create(:employee, company: company, first_name: "Alpha", last_name: "One", email: "alpha@example.com")
    create(:employee, company: company, first_name: "Beta", last_name: "Two", email: "beta@example.com")

    expect(EmployeeContactValidator).to receive(:db_marked_placeholder_emails)
      .with(company.organization_id).once.and_call_original

    presenter = described_class.new(source: source)
    presenter.send(:suggestions_for, "email" => "alpha@example.com", "full_name" => "Alpha One")
    presenter.send(:suggestions_for, "email" => "office-desk@example.com", "full_name" => "Beta Two")
    presenter.send(:suggestions_for, "email" => "beta@example.com", "full_name" => "Beta Two")
  end
end
