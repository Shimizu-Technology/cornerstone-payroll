# frozen_string_literal: true

module HistoricalFilingFixtureHelper
  def create_historical_filing_source(
    company:, employee:, pay_date:, gross_pay:, federal_income_tax:, social_security_tax:, medicare_tax:,
    employer_social_security_tax:, employer_medicare_tax:, reported_tips: 0, retirement: 0,
    roth_retirement: 0, non_taxable_pay: 0, social_security_taxable_wages: nil,
    social_security_taxable_tips: nil, medicare_taxable_wages: nil, period_type: "regular",
    period_start: nil, period_end: nil
  )
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    batch = create(:historical_import_batch, company: company, status: "locked")
    batch.update_columns(locked_at: Time.current, locked_by_id: actor.id)

    period_end ||= pay_date - 4.days
    period_start ||= period_type == "opening_summary" ? Date.new(pay_date.year, 1, 1) : period_end - 13.days
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "filing-period-#{batch.id}",
      source_label: "Imported payroll #{pay_date}",
      start_date: period_start,
      end_date: period_end,
      pay_date: pay_date,
      period_type: period_type,
      paycheck_count: 1,
      totals: { "gross_pay" => gross_pay.to_s }
    )
    worker = create(
      :historical_worker,
      historical_import_batch: batch,
      company: company,
      employee: employee,
      mapping_status: "exact_match"
    )
    fica_wages = medicare_taxable_wages || gross_pay - non_taxable_pay
    ss_tips = social_security_taxable_tips || [ reported_tips, fica_wages ].min
    ss_wages = social_security_taxable_wages || fica_wages - ss_tips
    paycheck = HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "filing-paycheck-#{batch.id}",
      source_employee_name: employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: period_type == "opening_summary" ? "opening_summary" : "matched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: pay_date,
      gross_pay: gross_pay,
      adjusted_gross: gross_pay,
      employee_taxes: federal_income_tax + social_security_tax + medicare_tax,
      federal_income_tax: federal_income_tax,
      social_security_tax: social_security_tax,
      medicare_tax: medicare_tax,
      net_pay: gross_pay - federal_income_tax - social_security_tax - medicare_tax - retirement - roth_retirement,
      pretax_deductions: retirement,
      pretax_deduction_breakdown: retirement.zero? ? [] : [ { "label" => "401(k) pre-tax", "amount" => retirement.to_s } ],
      after_tax_deductions: roth_retirement,
      after_tax_deduction_breakdown: roth_retirement.zero? ? [] : [ { "label" => "Roth 401(k)", "amount" => roth_retirement.to_s } ],
      earnings_breakdown: reported_tips.zero? ? [] : [ { "label" => "Pay Tips", "amount" => reported_tips.to_s } ],
      employer_taxes: employer_social_security_tax + employer_medicare_tax,
      employer_tax_breakdown: [
        { "label" => "Social Security Employer", "amount" => employer_social_security_tax.to_s },
        { "label" => "Medicare Employer", "amount" => employer_medicare_tax.to_s }
      ],
      total_payroll_cost: gross_pay + employer_social_security_tax + employer_medicare_tax
    )

    bootstrap = create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      status: "applied"
    )
    ledger = HistoricalPayroll::Ledger.new(batch: batch)
    bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: Digest::SHA256.hexdigest("filing-bridge-#{batch.id}"),
      preview_summary: {
        "through_period_end" => period.end_date.iso8601,
        "through_pay_date" => pay_date.iso8601,
        "adjustment_digest" => ledger.adjustment_digest
      },
      reconciliation_summary: { "passed" => true },
      applied_at: Time.current,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
    balance = HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: company,
      employee: employee,
      tax_year: pay_date.year,
      through_period_end: period.end_date,
      through_pay_date: pay_date,
      gross_pay: gross_pay,
      net_pay: paycheck.net_pay,
      federal_income_tax: federal_income_tax,
      social_security_tax: social_security_tax,
      medicare_tax: medicare_tax,
      employee_taxes: paycheck.employee_taxes,
      pretax_deductions: retirement,
      after_tax_deductions: roth_retirement,
      non_taxable_pay: non_taxable_pay,
      reported_tips: reported_tips,
      tips_paid_out: reported_tips,
      retirement: retirement,
      roth_retirement: roth_retirement,
      fit_taxable_wages: gross_pay - retirement - non_taxable_pay,
      social_security_taxable_wages: ss_wages,
      social_security_taxable_tips: ss_tips,
      medicare_taxable_wages: fica_wages,
      employer_social_security_tax: employer_social_security_tax,
      employer_medicare_tax: employer_medicare_tax,
      employer_taxes: paycheck.employer_taxes,
      source_breakdown: {
        "earnings_breakdown" => reported_tips.zero? ? {} : { "Pay Tips" => reported_tips.to_s },
        "pretax_deduction_breakdown" => retirement.zero? ? {} : { "401(k) pre-tax" => retirement.to_s },
        "after_tax_deduction_breakdown" => roth_retirement.zero? ? {} : { "Roth 401(k)" => roth_retirement.to_s }
      }
    )

    { batch: batch, period: period, paycheck: paycheck, bridge: bridge, balance: balance }
  end
end

RSpec.configure do |config|
  config.include HistoricalFilingFixtureHelper
end
