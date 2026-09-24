# frozen_string_literal: true

module HistoricalYtdBridgeFixtureHelper
  def apply_historical_ytd_balance(
    company:,
    employee:,
    through_pay_date:,
    through_period_end: through_pay_date,
    source_breakdown: {},
    **attributes
  )
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      status: "applied"
    )
    bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: SecureRandom.hex(16),
      applied_at: Time.current,
      applied_by: create(:user, company: company),
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT,
      preview_summary: {
        "through_period_end" => through_period_end.iso8601,
        "through_pay_date" => through_pay_date.iso8601
      }
    )

    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: company,
      employee: employee,
      tax_year: through_pay_date.year,
      through_period_end: through_period_end,
      through_pay_date: through_pay_date,
      source_breakdown: source_breakdown,
      **attributes
    )
  end
end
