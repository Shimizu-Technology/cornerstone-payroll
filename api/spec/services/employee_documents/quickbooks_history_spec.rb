# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocuments::QuickbooksHistory do
  let(:employee) { create(:employee) }

  it "keeps each reconciled check, including separate checks on the same date, and applies adjustments" do
    first = create(:historical_paycheck, employee: employee, hours_total: 35, net_pay: 900)
    second = create(:historical_paycheck, employee: employee, historical_import_batch: first.historical_import_batch,
      historical_pay_period: first.historical_pay_period, historical_worker: first.historical_worker, net_pay: 900, hours_total: 1)
    HistoricalPaycheckAdjustment.create!(
      company: employee.company, historical_paycheck: first, kind: "correction",
      created_by: create(:user, company: employee.company, organization: employee.company.organization),
      effective_pay_date: first.pay_date, filing_year: 2026, filing_quarter: 1,
      reason: "Correct recorded earnings", idempotency_key: "history-fix",
      hours_total: 2, gross_pay: 30, adjusted_gross: 30, net_pay: 30
    )
    create(:historical_paycheck, employee: employee, reconciliation_status: "unmatched")
    create(:historical_paycheck, employee: employee, period_type: "opening_summary")
    create(:historical_paycheck, employee: employee, reconciliation_status: "opening_summary")
    create(:historical_paycheck, employee: employee, batch_status: "applied")
    create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 9, 1))
    create(:historical_paycheck, employee: create(:employee, company: employee.company))
    create(:historical_paycheck)

    rows = described_class.for(employee)
    expect(rows.pluck(:historical_paycheck_id)).to eq([ second.id, first.id ])
    expect(rows.first).to include(hours_total: 1, net_pay: 900, adjustment_note: nil)
    expect(rows.last).to include(hours_total: 37, net_pay: 930, adjustment_note: "Includes recorded payroll adjustments.")
  end
end
