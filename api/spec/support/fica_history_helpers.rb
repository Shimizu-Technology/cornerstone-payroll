# frozen_string_literal: true

# Synthetic source fixtures shared by FICA recovery and disclosure regressions.
module FicaHistoryHelpers
  def imported(person = employee, gross: 1000, tips: 0, employer: true, company: self.company, batch: self.batch)
    period = HistoricalPayPeriod.create!(historical_import_batch: batch, company: company,
      external_key: SecureRandom.uuid, source_label: "Synthetic import", start_date: "2026-01-01",
      end_date: "2026-01-14", pay_date: "2026-01-16", paycheck_count: 1, totals: {})
    worker = create(:historical_worker, company: company, historical_import_batch: batch, employee: person, mapping_status: "exact_match")
    ss = (gross.to_d * "0.062".to_d).round(2)
    med = (gross.to_d * "0.0145".to_d).round(2)
    HistoricalPaycheck.create!(historical_import_batch: batch, historical_pay_period: period, historical_worker: worker,
      company: company, employee: person, external_key: SecureRandom.uuid, source_employee_name: "Synthetic worker",
      source_row_number: 1, reconciliation_status: "matched", period_start: period.start_date, period_end: period.end_date,
      pay_date: period.pay_date, gross_pay: gross, adjusted_gross: gross, social_security_tax: ss, medicare_tax: med,
      earnings_breakdown: [ { label: "Regular", amount: (gross.to_d - tips.to_d).to_s("F") }, { label: "PayTip", amount: tips.to_s } ],
      employee_tax_breakdown: [ { label: "SS", amount: ss.to_s("F") }, { label: "Med", amount: med.to_s("F") } ],
      employer_tax_breakdown: employer ? [ { label: "SS", amount: ss.to_s("F") }, { label: "Med", amount: med.to_s("F") } ] : [])
  end

  def opening(gross:)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(company: company, historical_import_batch: batch,
      status: "applied", plan_digest: "source-bootstrap", applied_at: Time.current, applied_by: actor)
    bridge = HistoricalYtdBridge.create!(company: company, historical_import_batch: batch,
      historical_client_bootstrap: bootstrap, status: "applied", plan_digest: "source-bridge",
      preview_summary: { "through_period_end" => "2025-12-31", "through_pay_date" => "2026-01-01" },
      applied_at: Time.current, applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT)
    HistoricalEmployeeYtdBalance.create!(historical_ytd_bridge: bridge, company: company, employee: employee,
      tax_year: 2026, through_period_end: "2025-12-31", through_pay_date: "2026-01-01",
      gross_pay: gross, medicare_taxable_wages: gross, reported_tips: 0,
      social_security_taxable_wages: gross, social_security_taxable_tips: 0,
      social_security_tax: (gross.to_d * "0.062".to_d).round(2), medicare_tax: (gross.to_d * "0.0145".to_d).round(2))
  end
end
