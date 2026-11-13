# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::WageRateChoice do
  let(:source) { create(:company) }
  let(:workspace) { create(:company, organization: source.organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox", migration_source_company: source, migration_rehearsal_status: "pending") }
  let(:employee) { create(:employee, company: workspace, pay_rate: 15.50) }
  let!(:primary) { create(:employee_wage_rate, employee: employee, label: "Hourly rate", rate: 15.50, is_primary: true) }
  let!(:joint) { create(:employee_wage_rate, employee: employee, label: "Joint Kitchen", rate: 16.50) }
  let!(:vacation) { create(:employee_wage_rate, employee: employee, label: "Vacation", rate: 16.50) }
  let(:period) { create(:pay_period, company: workspace, start_date: "2026-10-19", end_date: "2026-11-01", pay_date: "2026-11-05") }
  let!(:baseline) do
    original = create(:pay_period, :committed, company: source, start_date: "2026-10-05", end_date: "2026-10-18", pay_date: "2026-10-22")
    copied = create(:pay_period, company: workspace, start_date: original.start_date, end_date: original.end_date, pay_date: original.pay_date,
      status: "approved", test_workspace_role: "baseline", test_workspace_source_pay_period: original)
    create(:payroll_item, company: workspace, employee: employee, pay_period: copied, hours_worked: 61.09,
      custom_columns_data: { "wage_rate_hours" => [ { employee_wage_rate_id: 9_999_999, label: "Joint Kitchen", rate: 16.50, regular_hours: 61.09 } ] })
    workspace.update_columns(migration_rehearsal_status: "ready")
    copied
  end

  it "uses the copied locked job by label and rate without reusing the source job id" do
    expect(described_class.new(employee: employee, pay_period: period).preview).to include(
      selected_wage_rate_id: joint.id, wage_rate_default_pay_period_id: baseline.id,
      wage_rate_default_source: "Copied locked payroll, paid 2026-10-22")
  end

  it "does not treat a newer calculated practice run as authoritative history" do
    other = create(:pay_period, company: workspace, start_date: "2026-10-10", end_date: "2026-10-20", pay_date: "2026-10-25", status: "calculated")
    create(:payroll_item, company: workspace, employee: employee, pay_period: other,
      custom_columns_data: { "wage_rate_hours" => [ { employee_wage_rate_id: primary.id, label: primary.label, rate: 15.50, regular_hours: 30 } ] })
    expect(described_class.new(employee: employee, pay_period: period).preview[:selected_wage_rate_id]).to eq(joint.id)
  end

  it "requires a reviewed choice if the copied job rate changed" do
    joint.update!(rate: 18)
    expect(described_class.new(employee: employee, pay_period: period).preview[:selected_wage_rate_id]).to be_nil
  end
end
