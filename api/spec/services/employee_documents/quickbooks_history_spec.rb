# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocuments::QuickbooksHistory do
  let(:employee) { create(:employee) }

  before do
    create(:pay_period, :committed, company: employee.company, start_date: Date.new(2026, 8, 24),
      end_date: Date.new(2026, 9, 6), pay_date: Date.new(2026, 9, 10))
  end

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
    create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 9, 10))
    create(:historical_paycheck, employee: create(:employee, company: employee.company))
    create(:historical_paycheck)

    expect(described_class.review_warnings(employee.company_id)).to eq([
      { employee_id: employee.id, employee_name: employee.full_name, row_count: 2, payday_count: 1, duplicate_groups: 1 }
    ])
    september = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 9, 1))
    rows = described_class.for(employee)
    expect(rows.pluck(:historical_paycheck_id)).to eq([ september.id, second.id, first.id ])
    expect(rows.second).to include(hours_total: 1, net_pay: 900, adjustment_note: nil)
    expect(rows.last).to include(hours_total: 37, net_pay: 930, adjustment_note: "Includes recorded payroll adjustments.")
  end

  it "ignores test copies and record-only promotions when finding the first native payday" do
    native = PayPeriod.find_by!(company: employee.company)
    baseline = create(:pay_period, :committed, company: employee.company, pay_date: Date.new(2026, 7, 15))
    baseline.update_columns(test_workspace_role: "baseline", test_workspace_source_pay_period_id: native.id)
    archive = create(:pay_period, :committed, company: employee.company, pay_date: Date.new(2026, 8, 15))
    archive.update_columns(promotion_source_pay_period_id: native.id, promotion_payment_disposition: "record_only")
    history = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 9, 1))

    expect(described_class.for(employee).pluck(:historical_paycheck_id)).to eq([ history.id ])
  end

  it "ignores voided runs when finding the first native payday" do
    voided = create(:pay_period, :committed, company: employee.company, start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 14), pay_date: Date.new(2026, 5, 15))
    voided.update_columns(correction_status: "voided")
    may = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 5, 20))
    july = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 7, 31))

    expect(described_class.for(employee).pluck(:historical_paycheck_id)).to eq([ july.id, may.id ])
  end

  it "keeps the cutover at a voided first run's committed correction run, whose stubs employees see" do
    original = PayPeriod.find_by!(company: employee.company)
    original.update_columns(correction_status: "voided")
    correction = create(:pay_period, :committed, company: employee.company, start_date: original.start_date,
      end_date: original.end_date, pay_date: original.pay_date)
    correction.update_columns(correction_status: "correction", source_pay_period_id: original.id)
    original.update_columns(superseded_by_id: correction.id)
    august = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 8, 28))
    create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 9, 10))

    expect(described_class.for(employee).pluck(:historical_paycheck_id)).to eq([ august.id ])
  end

  it "shows locked QuickBooks checks before any native run is committed, and earlier years, like staff reports" do
    PayPeriod.where(company: employee.company).delete_all
    create(:pay_period, company: employee.company, status: "calculated", pay_date: Date.new(2026, 8, 15))
    prior_year = create(:historical_paycheck, employee: employee, pay_date: Date.new(2025, 12, 19),
      period_start: Date.new(2025, 12, 1), period_end: Date.new(2025, 12, 14))
    july = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 7, 31))

    expect(described_class.for(employee).pluck(:historical_paycheck_id)).to eq([ july.id, prior_year.id ])
  end
end
