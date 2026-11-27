# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe ImportedPayrollRegister do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, first_name: "Casey", last_name: "Cruz") }

  def imported_period(key, paychecks)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    period = HistoricalPayPeriod.create!(company: company, historical_import_batch: batch, external_key: "period-#{key}",
      source_label: "Payroll Apr 2026", period_type: "regular", start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 20), paycheck_count: paychecks.size, totals: {})
    paychecks.each_with_index do |attributes, index|
      worker = create(:employee, company: company)
      historical_worker = HistoricalWorker.create!(company: company, historical_import_batch: batch, employee: worker,
        external_key: "worker-#{key}-#{index}", source_name: worker.full_name, normalized_name: worker.full_name.downcase,
        source_status: "active", mapping_status: "exact_match")
      HistoricalPaycheck.create!(company: company, historical_import_batch: batch, historical_pay_period: period,
        historical_worker: historical_worker, employee: worker, external_key: "check-#{key}-#{index}",
        source_employee_name: worker.full_name, source_row_number: index + 1, source_status: "paid", reconciliation_status: "matched",
        period_start: period.start_date, period_end: period.end_date, pay_date: period.pay_date,
        gross_pay: 1_000, adjusted_gross: 1_000, net_pay: 850, **attributes)
    end
    period
  end

  it "returns regular and combined hours with the native register's summary keys" do
    period = imported_period("hours", [
      { hours_total: 85, hours_breakdown: [ { "label" => "Regular", "amount" => "80.0" }, { "label" => "Overtime", "amount" => "5.0" } ] },
      # No regular line: the hours not recorded as another kind are regular.
      { hours_total: 40, hours_breakdown: [ { "label" => "Holiday", "amount" => "8.0" } ] }
    ])

    register = described_class.new(company_id: company.id, historical_pay_period_id: period.id).call

    expect(register.fetch(:employees).map { |row| row.values_at(:hours_worked, :overtime_hours, :holiday_hours, :combined_hours) })
      .to contain_exactly([ 80.0, 5.0, 0.0, 85.0 ], [ 32.0, 0.0, 8.0, 40.0 ])
    expect(register.fetch(:summary)).to include(worked_hours: 112.0, combined_hours: 125.0, total_hours: 125.0, total_overtime_hours: 5.0)

    text = PDF::Reader.new(StringIO.new(PayrollRegisterPdfGenerator.new(register).generate)).pages.map(&:text).join("\n")
    expect(text).to match(/Regular Hours\s+112\.00/).and match(/Combined Hours \(Regular \+ OT \+ Holiday \+ PTO\)\s+125\.00/)
    expect(text.lines.grep(/\A\s*TOTALS\s+\d/).first.split.drop(1).first(2)).to eq(%w[112.00 5.00])
  end

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
