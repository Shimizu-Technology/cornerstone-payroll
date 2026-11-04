# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::AccountantPaidCategoryAttribution do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0", identity_verified_at: Time.current) }
  let(:mapping) { TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee, source_user_id: "91", source_user_uuid: SecureRandom.uuid) }
  let(:run) { create(:pay_period, :committed, company: company, start_date: "2026-08-16", end_date: "2026-08-31", pay_date: "2026-09-15") }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 3.1, overtime_hours: 0, custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.1, "overtime_hours" => 0 } ] }) }
  let(:flight) { { "id" => "1", "key" => "aire_flight_hours", "name" => "Flight Hours" } }
  let(:solo) { { "id" => "7", "key" => "aire_solo", "name" => "Solo" } }
  let(:lines) { [ { "category" => flight, "total_hours" => "0.6" }, { "category" => nil, "total_hours" => "2.5" } ] }
  def policy(key, label = nil)
    TimeTrackingCategoryMapping.create!(company: company, time_tracking_source: source, source_category_key: key,
      earning_label: label, historical_attribution: true, historical_employee_ids: [ employee.id ], history_through_on: run.end_date,
      reviewed_by: actor, reason: "Reviewed historical category attribution", evidence: "Leon November4 decision and committed register")
  end
  def capture
    described_class.new(source: source, actor: actor).call(batch: { "batch_id" => "FROZEN", "export" => { "checksum" => "a" * 64 } },
      run: run, mapping: mapping, employee: { "adjustments" => lines }, items: (@items || [ item ]), run_checksum: "r" * 64, inventory_checksum: "i" * 64)
  end
  it "attributes retained uncategorized hours to the actual committed remainder without changing source" do
    policy("uncategorized")
    original = lines.deep_dup
    expect(capture).to include("source_total" => "3.1", "paid_total" => "3.1", "reviewer_id" => actor.id)
    expect(capture.fetch("rows")).to include(a_hash_including("source_category" => nil, "source_hours" => "2.5", "paid_component" => "Flight Hours"))
    expect(lines).to eq(original)
  end
  it "retains run61 Other 75.90 and NULL 2.50 only when their combined hours tie" do
    run.update!(id: 61)
    lines.replace([ { "category" => { "key" => "aire_other", "name" => "Other" }, "total_hours" => "75.90" }, { "category" => nil, "total_hours" => "2.50" } ])
    policy("other")
    null_policy = policy("uncategorized")
    null_policy.update!(historical_run_limits: { employee.id.to_s => [ 61 ] })
    item.update_columns(hours_worked: 78.4, custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Regular", "active" => true, "regular_hours" => 78.4, "overtime_hours" => 0 } ] })
    expect(capture).to include("source_total" => "78.4", "paid_total" => "78.4")
    expect(capture.fetch("rows")).to include(a_hash_including("source_category" => nil, "source_hours" => "2.5", "paid_component" => "Regular"))
    item.update_columns(hours_worked: 78.46, custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Regular", "active" => true, "regular_hours" => 78.46, "overtime_hours" => 0 } ] })
    expect(capture).to be_nil
  end

  [ [ "58.57", "42.0", "80.0", "20.6" ], [ "38.3", "61.25", "94.7", "4.85" ] ].each do |maintenance, uncategorized, regular, overtime|
    it "matches the explicitly configured Regular fallback to actual Regular Pay and retains separate overtime components (#{regular}/#{overtime})" do
      lines.replace([ { "category" => { "key" => "aire_maintenance", "name" => "Aircraft Maintenance" }, "total_hours" => maintenance }, { "category" => nil, "total_hours" => uncategorized } ])
      configured = policy("maintenance", "Maintenance")
      configured.update!(fallback_earning_label: "Regular")
      policy("uncategorized")
      item.update_columns(hours_worked: regular, overtime_hours: overtime, custom_columns_data: {})
      item.payroll_item_earnings.create!(category: "regular", label: "Regular Pay", hours: regular, rate: 14.7, amount: regular.to_d * 14.7)
      item.payroll_item_earnings.create!(category: "overtime", label: "Overtime Pay", hours: overtime, rate: 22.05, amount: overtime.to_d * 22.05)
      result = capture
      expect(result).to be_present
      expect(result.fetch("rows").map { |row| row.fetch("paid_component") }.uniq).to contain_exactly("Regular Pay", "Overtime Pay")
      expect(result.fetch("rows").sum { |row| row.fetch("source_hours").to_d }).to eq(maintenance.to_d + uncategorized.to_d)
      configured.update!(fallback_earning_label: nil)
      expect(capture).to be_nil
    end
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
    row.update!(historical_employee_ids: [ employee.id ], history_through_on: run.end_date - 1)
    expect(capture).to be_nil
  end
  it "bounds employee/run totals without netting across people" do
    policy("uncategorized")
    item.update_columns(hours_worked: 3.16, custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.16, "overtime_hours" => 0 } ] })
    expect(capture).to be_nil
    item.update_columns(hours_worked: 3.13, custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.13, "overtime_hours" => 0 } ] })
    expect(capture).to include("signed_difference" => "0.03")
    expect(capture.fetch("rows").sum { |row| row.fetch("rounding_difference").to_d }).to eq(0.03.to_d)
  end
  it "never nets another employee's hours into this employee's committed total" do
    policy("uncategorized")
    item.update_columns(hours_worked: 3.04, custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 3.04, "overtime_hours" => 0 } ] })
    other = create(:employee, company: company)
    other_item = create(:payroll_item, company: company, employee: other, pay_period: run, hours_worked: 0.06, overtime_hours: 0,
      custom_columns_data: { "wage_rate_hours" => [ { "employee_wage_rate_id" => 21, "label" => "Flight Hours", "active" => true, "regular_hours" => 0.06, "overtime_hours" => 0 } ] })
    @items = [ item, other_item ]
    expect(capture).to be_nil
  end

  it "rejects changed or inconsistent committed components" do
    policy("uncategorized")
    item.update_columns(hours_worked: 3.2)
    expect(capture).to be_nil
  end
  it "rejects malformed or noncanonical employee keys instead of dropping run limits" do
    row = policy("uncategorized")
    [ "#{employee.id}extra", "0#{employee.id}" ].each do |key|
      row.historical_run_limits = { key => [ run.id ] }
      expect(row).not_to be_valid
      expect(row.errors[:historical_run_limits]).to be_present
    end
    row.historical_run_limits = { employee.id.to_s => [ run.id ] }
    expect(row).to be_valid
  end

  it "isolates cached attributions, including refusals, between committed runs" do
    policy("uncategorized")
    other_run = create(:pay_period, :committed, company: company, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date)
    other_item = create(:payroll_item, company: company, employee: employee, pay_period: other_run, hours_worked: 3.1, overtime_hours: 0,
      custom_columns_data: item.custom_columns_data)
    service = described_class.new(source: source, actor: actor)
    args = { batch: { "batch_id" => "FROZEN", "export" => { "checksum" => "a" * 64 } }, mapping: mapping,
      employee: { "adjustments" => lines }, inventory_checksum: "i" * 64 }
    expect(service.call(**args, run: run, items: [], run_checksum: "first")).to be_nil
    result = service.call(**args, run: other_run, items: [ other_item ], run_checksum: "second")
    expect(result).to include("run_id" => other_run.id, "run_checksum" => "second")
    expect(service.call(**args, run: run, items: [ item ], run_checksum: "first-present")).to include("run_id" => run.id)
  end

  it "uses the primary paid component before Regular fallback even when Regular Pay was created first" do
    maintenance = { "key" => "aire_maintenance", "name" => "Aircraft Maintenance" }
    lines.replace([ { "category" => maintenance, "total_hours" => "1.1" }, { "category" => nil, "total_hours" => "2.0" } ])
    policy("maintenance", "Maintenance").update!(fallback_earning_label: "Regular")
    policy("uncategorized")
    item.update_columns(custom_columns_data: {})
    item.payroll_item_earnings.create!(category: "regular", label: "Regular Pay", hours: 2, rate: 14.7, amount: 29.4)
    item.payroll_item_earnings.create!(category: "regular", label: "Maintenance", hours: 1.1, rate: 20, amount: 22)
    expect(capture.fetch("rows")).to include(a_hash_including("source_category" => maintenance, "paid_component" => "Maintenance", "attributed_paid_hours" => "1.1"))
  end

  it "honors a fallback-only label instead of using an unrelated sole component" do
    lines.replace([ { "category" => solo, "total_hours" => "3.1" } ])
    row = policy("solo")
    row.update!(fallback_earning_label: "Missing component")
    expect(capture).to be_nil
    row.update!(fallback_earning_label: "Flight Hours")
    expect(capture).to be_present
  end

  it "does not span unrelated components when NULL has a configured primary or fallback" do
    [ :earning_label, :fallback_earning_label ].each do |field|
      row = policy("uncategorized")
      row.update!(field => "Missing component")
      expect(capture).to be_nil
      row.destroy!
    end
  end

  it "keeps a final category's negative rounding remainder on its own source row" do
    lines.replace([ { "category" => flight, "total_hours" => "3.1" }, { "category" => solo, "total_hours" => "0.03" } ])
    policy("solo", "Flight Hours")
    result = capture
    expect(result).to include("signed_difference" => "-0.03")
    expect(result.fetch("rows")).to include(a_hash_including("source_category" => solo, "source_hours" => "0.03", "attributed_paid_hours" => "0.0", "rounding_difference" => "-0.03"))
    expect(result.fetch("rows").find { |row| row["source_category"] == flight }.fetch("source_hours")).to eq("3.1")
  end
end
