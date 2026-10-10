# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriodComparisonBuilder do
  let(:company) { create(:company) }
  let(:first) { create(:employee, company: company) }
  let(:second) { create(:employee, company: company) }
  let(:previous) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 9, 30)) }
  let(:current) { create(:pay_period, :calculated, company: company, pay_date: Date.new(2026, 10, 10)) }

  before do
    create(:payroll_item, pay_period: previous, employee: first, gross_pay: 1000, net_pay: 800)
    create(:payroll_item, pay_period: previous, employee: second, gross_pay: 500, net_pay: 400)
    create(:payroll_item, pay_period: current, employee: first, gross_pay: 1000, net_pay: 800)
  end

  it "preserves missing-employee warnings for a regular payroll" do
    payload = described_class.new(current).call
    expect(payload[:review_flags][:warning_count]).to eq(1)
    expect(payload[:summary][:employee_count][:delta]).to eq(-1)
  end

  it "compares only participating employees on an adjustment" do
    current.update_columns(run_purpose: "adjustment", includes_base_salary: false, includes_recurring_items: false)
    payload = described_class.new(current).call
    expect(payload[:comparison_kind]).to eq("selected_employees")
    expect(payload[:employee_changes]).to be_empty
    expect(payload[:review_flags][:warning_count]).to eq(0)
    expect(payload[:summary][:employee_count][:delta]).to eq(0)
    expect(payload[:summary][:gross_pay][:previous]).to eq(1000)
  end

  it "compares a correction to the original earned source rows after check retirement" do
    previous.update!(correction_status: "voided", voided_at: Time.current, void_reason: "Original checks retired")
    previous.payroll_items.update_all(voided: true)
    current.update_columns(correction_status: "correction", source_pay_period_id: previous.id, run_purpose: "correction")
    payload = described_class.new(current).call
    expect(payload[:previous_pay_period][:id]).to eq(previous.id)
    expect(payload[:summary][:gross_pay][:previous]).to eq(1000)
    expect(payload[:review_flags][:warning_count]).to eq(0)
  end

  it "uses a prior correction of a regular payroll as the regular baseline" do
    previous.update!(correction_status: "voided", voided_at: Time.current, void_reason: "Original checks retired")
    revised = create(:pay_period, :committed, :correction_run, company: company, source_pay_period: previous, run_purpose: "correction", status: "committed", pay_date: previous.pay_date)
    create(:payroll_item, pay_period: revised, employee: first, gross_pay: 1000, net_pay: 800)
    expect(described_class.new(current).call[:previous_pay_period][:id]).to eq(revised.id)
  end
end
