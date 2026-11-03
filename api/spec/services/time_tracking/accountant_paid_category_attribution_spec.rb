# frozen_string_literal: true
require "rails_helper"

RSpec.describe TimeTracking::AccountantPaidCategoryAttribution do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0", identity_verified_at: Time.current) }
  let(:mapping) { create(:time_tracking_employee_mapping, company: company, time_tracking_source: source, employee: employee, source_user_id: "91", source_user_uuid: SecureRandom.uuid) }
  let(:run) { create(:pay_period, :committed, company: company, start_date: "2026-08-16", end_date: "2026-08-31", pay_date: "2026-09-15") }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 3.1, overtime_hours: 0, custom_columns_data: { "wage_rate_hours" => [{ "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.1, "overtime_hours" => 0 }] }) }
  let(:flight) { { "id" => "1", "key" => "aire_flight_hours", "name" => "Flight Hours" } }
  let(:solo) { { "id" => "7", "key" => "aire_solo", "name" => "Solo" } }
  let(:lines) { [{ "category" => flight, "total_hours" => "0.6" }, { "category" => nil, "total_hours" => "2.5" }] }
  def policy(key, label = nil)
    TimeTrackingCategoryMapping.create!(company: company, time_tracking_source: source, source_category_key: key,
      earning_label: label, historical_attribution: true, historical_employee_ids: [employee.id], history_through_on: run.end_date,
      reviewed_by: actor, reason: "Reviewed historical category attribution", evidence: "Leon November4 decision and committed register")
  end
  def capture
    described_class.new(source: source, actor: actor).call(batch: { "batch_id" => "FROZEN", "export" => { "checksum" => "a" * 64 } },
      run: run, mapping: mapping, employee: { "adjustments" => lines }, items: [item], run_checksum: "r" * 64, inventory_checksum: "i" * 64)
  end
  it "attributes retained uncategorized hours to the actual committed remainder without changing source" do
    policy("uncategorized")
    original = lines.deep_dup
    expect(capture).to include("source_total" => "3.1", "paid_total" => "3.1", "reviewer_id" => actor.id)
    expect(capture.fetch("rows")).to include(a_hash_including("source_category" => nil, "source_hours" => "2.5", "paid_component" => "Flight Hours"))
    expect(lines).to eq(original)
  end
  it "requires explicit company Solo configuration and a component present in the committed run" do
    lines.last["category"] = solo
    expect(capture).to be_nil
    row = policy("solo", "Flight Hours")
    expect(capture).to be_present
    row.update!(earning_label: "Missing component")
    expect(capture).to be_nil
  end
  it "rejects out-of-scope employees, periods and unconfigured source categories" do
    row = policy("uncategorized")
    row.update!(historical_employee_ids: [])
    expect(capture).to be_nil
    row.update!(historical_employee_ids: [employee.id], history_through_on: run.end_date - 1)
    expect(capture).to be_nil
  end
  it "bounds employee/run totals without netting across people" do
    policy("uncategorized")
    item.update_columns(hours_worked: 3.16, custom_columns_data: { "wage_rate_hours" => [{ "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.16, "overtime_hours" => 0 }] })
    expect(capture).to be_nil
    item.update_columns(hours_worked: 3.13, custom_columns_data: { "wage_rate_hours" => [{ "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.13, "overtime_hours" => 0 }] })
    expect(capture).to include("signed_difference" => "0.03")
    expect(capture.fetch("rows").sum { |row| row.fetch("rounding_difference").to_d }).to eq(0.03.to_d)
  end
  it "rejects changed or inconsistent committed components" do
    policy("uncategorized")
    item.update_columns(hours_worked: 3.2)
    expect(capture).to be_nil
  end
end
