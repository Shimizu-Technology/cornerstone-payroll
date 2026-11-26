# frozen_string_literal: true

require "rails_helper"

RSpec.describe ImportedPayrollRegister do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, first_name: "Casey", last_name: "Cruz") }

  it "squishes hour labels before matching OVERTIME_HOURS so extra spaces match UnifiedPayrollReporting" do
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    period = HistoricalPayPeriod.create!(
      company: company,
      historical_import_batch: batch,
      external_key: "period-squish-hours",
      source_label: "Payroll Mar 2026",
      period_type: "regular",
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 20),
      paycheck_count: 1,
      totals: { "gross_pay" => "1000.00", "net_pay" => "850.00" }
    )
    worker = HistoricalWorker.create!(
      company: company,
      historical_import_batch: batch,
      employee: employee,
      external_key: "worker-squish-hours",
      source_name: employee.full_name,
      normalized_name: employee.full_name.downcase,
      source_status: "active",
      mapping_status: "exact_match"
    )
    HistoricalPaycheck.create!(
      company: company,
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      employee: employee,
      external_key: "check-squish-hours",
      source_employee_name: "Cruz, Casey",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      hours_total: 46.5,
      gross_pay: 1_000,
      adjusted_gross: 1_000,
      net_pay: 850,
      hours_breakdown: [
        { "label" => "Regular", "amount" => "40.0" },
        { "label" => "Double  Time", "amount" => "4.5" },
        { "label" => "  Overtime  ", "amount" => "2.0" }
      ]
    )

    register = described_class.new(company_id: company.id, historical_pay_period_id: period.id).call
    row = register.fetch(:employees).sole

    expect(row.fetch(:overtime_hours)).to eq(6.5)

    unified = UnifiedPayrollReporting.new(
      company_id: company.id,
      period: PayrollReportingPeriod.new(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 31))
    )
    paychecks = unified.historical_paychecks
    expect(unified.history_row(paychecks.sole).fetch(:overtime_hours)).to eq(6.5)
    expect(unified.add_historical_to_employee_row({}, paychecks).fetch(:total_overtime_hours).to_f).to eq(6.5)
  end
end
