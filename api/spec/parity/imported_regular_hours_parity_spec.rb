# frozen_string_literal: true

require "rails_helper"

# The imported payroll register and the combined reports read an imported
# paycheck's regular hours from ImportedPaycheckHours, so they always agree.
RSpec.describe ImportedPaycheckHours do
  let(:company) { create(:company) }

  def imported_paycheck(key, hours_total:, hours_breakdown:)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    period = HistoricalPayPeriod.create!(company: company, historical_import_batch: batch, external_key: "period-#{key}",
      source_label: "Payroll #{key}", period_type: "regular", start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 20), paycheck_count: 1, totals: {})
    employee = create(:employee, company: company)
    worker = HistoricalWorker.create!(company: company, historical_import_batch: batch, employee: employee,
      external_key: "worker-#{key}", source_name: employee.full_name, normalized_name: employee.full_name.downcase,
      source_status: "active", mapping_status: "exact_match")
    HistoricalPaycheck.create!(company: company, historical_import_batch: batch, historical_pay_period: period,
      historical_worker: worker, employee: employee, external_key: "check-#{key}", source_employee_name: employee.full_name,
      source_row_number: 1, source_status: "paid", reconciliation_status: "matched", period_start: period.start_date,
      period_end: period.end_date, pay_date: period.pay_date, gross_pay: 1_000, adjusted_gross: 1_000, net_pay: 850,
      hours_total: hours_total, hours_breakdown: hours_breakdown)
  end

  def views(paycheck)
    register = ImportedPayrollRegister.new(company_id: company.id, historical_pay_period_id: paycheck.historical_pay_period_id).call
    reporting = UnifiedPayrollReporting.new(company_id: company.id,
      period: PayrollReportingPeriod.new(start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 30)))
    paychecks = reporting.historical_paychecks.select { |check| check.id == paycheck.id }
    combined = reporting.add_historical_to_employee_row({}, paychecks)
    {
      register_row: register.fetch(:employees).sole.fetch(:hours_worked).to_d,
      register_summary: register.fetch(:summary).fetch(:worked_hours).to_d,
      pay_history_row: reporting.history_row(paychecks.sole).fetch(:hours_worked).to_d,
      combined_report: combined.fetch(:worked_hours).to_d,
      combined_hours: [ register.dig(:summary, :combined_hours).to_d, combined.fetch(:combined_hours).to_d ]
    }
  end

  it "derives regular hours from the imported total when the source records no regular line, in every view" do
    paycheck = imported_paycheck("no-regular", hours_total: 45, hours_breakdown: [ { "label" => "Overtime", "amount" => "5" } ])

    figures = views(paycheck)

    expect(figures.except(:combined_hours).values).to all(eq(40))
    expect(figures.fetch(:combined_hours)).to eq([ 45, 45 ])
  end

  it "keeps the source's labeled regular hours in every view" do
    # The 2 sick hours aren't a kind the reports split out; the labeled
    # regular line still wins over the derived 38.
    paycheck = imported_paycheck("labeled", hours_total: 45, hours_breakdown: [
      { "label" => "Regular", "amount" => "36" }, { "label" => "Overtime", "amount" => "5" },
      { "label" => "Holiday", "amount" => "2" }, { "label" => "Sick", "amount" => "2" }
    ])

    figures = views(paycheck)

    expect(figures.except(:combined_hours).values).to all(eq(36))
    expect(figures.fetch(:combined_hours)).to eq([ 45, 45 ])
  end

  it "never derives negative regular hours" do
    paycheck = imported_paycheck("over", hours_total: 4, hours_breakdown: [ { "label" => "Overtime", "amount" => "5" } ])

    expect(views(paycheck).except(:combined_hours).values).to all(eq(0))
  end
end
