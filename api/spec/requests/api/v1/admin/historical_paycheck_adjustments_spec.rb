# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::HistoricalPaycheckAdjustments", type: :request do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:employee) { create(:employee, company: company) }
  let!(:batch) { create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current, locked_by: admin) }
  let!(:period) do
    HistoricalPayPeriod.create!(
      historical_import_batch: batch, company: company, external_key: "request-period",
      source_label: "QuickBooks request payroll", start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 1, 14), pay_date: Date.new(2026, 1, 20), paycheck_count: 1
    )
  end
  let!(:worker) do
    create(:historical_worker, historical_import_batch: batch, company: company, employee: employee,
                               mapping_status: "exact_match")
  end
  let!(:paycheck) do
    HistoricalPaycheck.create!(
      historical_import_batch: batch, historical_pay_period: period, historical_worker: worker,
      company: company, employee: employee, external_key: "request-paycheck",
      source_employee_name: employee.full_name, source_row_number: 1, source_status: "paid",
      reconciliation_status: "matched", period_start: period.start_date, period_end: period.end_date,
      pay_date: period.pay_date, gross_pay: 1_000, adjusted_gross: 1_000, employee_taxes: 100,
      employee_tax_breakdown: [ { "label" => "Taxes", "amount" => "100.0" } ], net_pay: 900,
      total_payroll_cost: 1_000
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::HistoricalPaycheckAdjustmentsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::HistoricalPaycheckAdjustmentsController).to receive(:current_company_id).and_return(company.id)
  end

  def input
    {
      kind: "correction",
      effective_pay_date: paycheck.pay_date.iso8601,
      reason: "Correct source evidence",
      idempotency_key: "request-adjustment",
      gross_pay: 50,
      federal_income_tax: 5
    }
  end

  it "previews, records, lists, and reviews an immutable adjustment" do
    post "/api/v1/admin/historical_paychecks/#{paycheck.id}/adjustments/preview", params: { adjustment: input }
    expect(response).to have_http_status(:ok), response.body
    preview = response.parsed_body.fetch("data")
    expect(preview).to include("ready" => true, "downstream_pay_period_ids" => [])

    post "/api/v1/admin/historical_paychecks/#{paycheck.id}/adjustments", params: {
      adjustment: input,
      preview_digest: preview.fetch("digest"),
      acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:created), response.body
    adjustment_id = response.parsed_body.dig("data", "id")

    post "/api/v1/admin/historical_paycheck_adjustments/#{adjustment_id}/event", params: {
      event_type: "filing_reviewed_no_amendment",
      note: "Reviewed against the filed quarter",
      metadata: { "review_ticket" => "TAX-42" }
    }
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("data", "metadata")).to eq("review_ticket" => "TAX-42")

    get "/api/v1/admin/historical_paychecks/#{paycheck.id}/adjustments"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole).to include(
      "id" => adjustment_id,
      "filing_review_state" => "no_amendment_required",
      "downstream_impact_required" => false,
      "reason" => "Correct source evidence"
    )

    post "/api/v1/admin/historical_paycheck_adjustments/#{adjustment_id}/reverse", params: {
      reason: "The correction evidence was superseded",
      idempotency_key: "request-reversal",
      acknowledgement: HistoricalPayroll::AdjustmentReversalService::ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.fetch("data")).to include(
      "kind" => "reversal",
      "reverses_adjustment_id" => adjustment_id
    )
    expect(response.parsed_body.dig("data", "values", "gross_pay").to_f).to eq(-50)
  end

  it "allows accountants to read but not mutate the ledger" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::HistoricalPaycheckAdjustmentsController).to receive(:current_user).and_return(accountant)

    get "/api/v1/admin/historical_paychecks/#{paycheck.id}/adjustments"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/historical_paychecks/#{paycheck.id}/adjustments/preview", params: { adjustment: input }
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects malformed financial input with the API error contract" do
    post "/api/v1/admin/historical_paychecks/#{paycheck.id}/adjustments/preview", params: {
      adjustment: input.merge(gross_pay: "1O0")
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq(
      "error" => "Gross pay must be a number",
      "details" => {}
    )
  end

  it "returns not found for another client's source paycheck and adjustment" do
    other = create(:company, historical_payroll_enabled: true)
    other_admin = create(:user, company: other, organization: other.organization, role: "admin")
    other_batch = create(:historical_import_batch, company: other, status: "locked", locked_at: Time.current, locked_by: other_admin)
    other_period = HistoricalPayPeriod.create!(
      historical_import_batch: other_batch, company: other, external_key: "other-period",
      source_label: "Other", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 14),
      pay_date: Date.new(2026, 1, 20), paycheck_count: 0
    )
    other_worker = create(:historical_worker, historical_import_batch: other_batch, company: other)
    other_paycheck = HistoricalPaycheck.create!(
      historical_import_batch: other_batch, historical_pay_period: other_period, historical_worker: other_worker,
      company: other, external_key: "other-paycheck", source_employee_name: "Other Worker",
      source_row_number: 1, source_status: "paid", reconciliation_status: "matched",
      period_start: other_period.start_date, period_end: other_period.end_date, pay_date: other_period.pay_date
    )

    get "/api/v1/admin/historical_paychecks/#{other_paycheck.id}/adjustments"
    expect(response).to have_http_status(:not_found)
  end
end
