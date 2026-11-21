# frozen_string_literal: true

require "rails_helper"

# The report's total staff cost must equal the Annual Payroll Summary's total
# payroll cost for the same staff payroll client and pay dates.
RSpec.describe "Client profitability reconciles with the Annual Payroll Summary" do
  let(:practice) { create(:company, name: "Cornerstone") }
  let(:organization) { practice.organization }
  let(:user) { create(:user, company: practice, role: "admin") }
  let(:mark) { create(:employee, company: practice, first_name: "Mark", last_name: "Santos") }
  let(:settings) { ClientProfitabilitySetting.create!(organization: organization, practice_company: practice) }

  def historical_paycheck(suffix:, employee:, gross_pay:, pay_date: Date.new(2025, 6, 15))
    batch = create(:historical_import_batch, company: practice, status: "locked", source_label: "QuickBooks #{suffix}",
                   bundle_digest: Digest::SHA256.hexdigest("profitability-#{suffix}"))
    batch.update_columns(locked_at: Time.current, locked_by_id: user.id)
    period = HistoricalPayPeriod.create!(historical_import_batch: batch, company: practice, external_key: "period-#{suffix}",
                                         source_label: "Payroll #{suffix}", start_date: pay_date - 13, end_date: pay_date - 5,
                                         pay_date: pay_date, period_type: "regular", paycheck_count: 1,
                                         totals: { "gross_pay" => gross_pay.to_s, "net_pay" => "1" })
    worker = create(:historical_worker, historical_import_batch: batch, company: practice, employee: employee,
                    external_key: "worker-#{suffix}", source_name: employee&.full_name || "Unlinked Worker",
                    mapping_status: employee ? "exact_match" : "archive_only")
    HistoricalPaycheck.create!(
      historical_import_batch: batch, historical_pay_period: period, historical_worker: worker, company: practice, employee: employee,
      external_key: "paycheck-#{suffix}", source_employee_name: employee&.full_name || "Unlinked Worker", source_row_number: 1,
      source_status: "paid", reconciliation_status: employee ? "matched" : "unmatched", period_start: period.start_date,
      period_end: period.end_date, pay_date: pay_date, hours_total: 40, gross_pay: gross_pay, adjusted_gross: gross_pay - 20,
      pretax_deductions: 20, employee_taxes: 100, federal_income_tax: 40, social_security_tax: 50, medicare_tax: 10,
      after_tax_deductions: 30, net_pay: 1, employer_taxes: 38, employer_contributions: 15, total_payroll_cost: gross_pay + 53
    )
  end

  def adjustment(paycheck, key)
    HistoricalPaycheckAdjustment.create!(
      company: practice, historical_paycheck: paycheck, created_by: user, kind: "correction", effective_pay_date: paycheck.pay_date,
      filing_year: 2025, filing_quarter: 2, reason: "Correct source evidence after review", idempotency_key: "profitability-#{key}",
      hours_total: 2, gross_pay: 100, adjusted_gross: 95, pretax_deductions: 5,
      pretax_deduction_breakdown: [ { "label" => "Health", "amount" => "5" } ], employee_taxes: 10, federal_income_tax: 10,
      employee_tax_breakdown: [ { "label" => "FIT", "amount" => "10" } ], after_tax_deductions: 10,
      after_tax_deduction_breakdown: [ { "label" => "Loan", "amount" => "10" } ], net_pay: 75, employer_taxes: 7,
      employer_tax_breakdown: [ { "label" => "Employer FICA", "amount" => "7" } ], employer_contributions: 5,
      employer_contribution_breakdown: [ { "label" => "Match", "amount" => "5" } ], total_payroll_cost: 112
    )
  end

  before do
    native_period = create(:pay_period, :committed, company: practice, start_date: Date.new(2025, 6, 1), end_date: Date.new(2025, 6, 14),
                                                    pay_date: Date.new(2025, 6, 20))
    create(:payroll_item, company: practice, employee: mark, pay_period: native_period, gross_pay: 1000, non_taxable_pay: 25,
                          employer_social_security_tax: 62, employer_medicare_tax: 14.5, employer_retirement_match: 40)
    linked = historical_paycheck(suffix: "linked", employee: mark, gross_pay: 500)
    unlinked = historical_paycheck(suffix: "unlinked", employee: nil, gross_pay: 250)
    adjustment(linked, "linked")
    expect(unlinked.employee_id).to be_nil

    import = WorkHourImport.create!(organization: organization, range_start: Date.new(2025, 6, 1), range_end: Date.new(2025, 6, 30),
                                    status: "succeeded")
    WorkHourStaffLink.create!(organization: organization, tax_user_id: 12, disposition: "employee", employee: mark, active: true) if settings.persisted?
    WorkHourRow.create!(organization: organization, work_hour_import: import, tax_user_id: 12, work_date: Date.new(2025, 6, 3),
                        tax_client_id: 1, client_name: "Acme", hours: 10, approval_state: "approved")
  end

  it "matches total payroll cost exactly and lists unlinked imported pay outside the totals" do
    period = ClientProfitability::Period.parse("2025-06", "2025-06")
    report = ClientProfitability::Report.new(organization: organization, settings: settings, period: period).call
    summary = AnnualPayrollSummary.new(company: practice)
                                  .period_row(PayrollReportingPeriod.new(start_date: period.start_date, end_date: period.end_date))

    expect(report.dig(:totals, :cost).to_d).to eq(summary.fetch(:total_payroll_cost).to_d)
    expect(summary.fetch(:total_payroll_cost).to_d).to eq(BigDecimal("1806.50")) # 1141.50 native + 553 linked paycheck + 112 adjustment
    expect(report[:imported_pay_not_linked]).to eq(paycheck_count: 1, cost: "303.00")
    expect(summary.fetch(:excluded_unlinked_paycheck_count)).to eq(1)
    expect(report[:unallocated_costs]).to eq([])
    expect(report[:staff].sole).to include(name: "Mark Santos", cost: "1806.50", hours: "10.00")
    csv = CSV.parse(ClientProfitability::CsvExport.new(report).generate)
    expect(csv.find { |row| row.first.to_s.start_with?("Imported pay not linked") }[5]).to eq("303.00")
    expect(csv.find { |row| row.first == "Total" }[5]).to eq("1806.50")
  end

  it "agrees with the yearly Annual Payroll Summary row" do
    report = ClientProfitability::Report.new(organization: organization, settings: settings,
                                             period: ClientProfitability::Period.parse("2025-01", "2025-12")).call
    year = AnnualPayrollSummary.new(company: practice).call.fetch(:years).find { |row| row[:year] == 2025 }
    expect(report.dig(:totals, :cost).to_d).to eq(year.fetch(:total_payroll_cost).to_d)
  end
end
