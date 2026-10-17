# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Connect already committed corrected hours", type: :request do
  include_context "exact source correction fixtures"
  let(:original_payment_state) { "unprepared" }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
      expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1 payment_cancellation_v1], identity_verified_at: Time.current)
  end
  let(:controller_class) { Api::V1::Admin::PayPeriodsController }

  def legacy_committed
    allow_any_instance_of(PayrollItem).to receive(:financial_correction_origin_item=)
    allow_any_instance_of(TimeTracking::FinancialCorrectionService).to receive(:record_commit!).and_return([])
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct saved payroll")
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct saved payroll")
    item = period.payroll_items.first!
    PayrollCalculator.for(employee, item).calculate
    item.save!
    period.update!(status: "calculated")
    service = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    service.approve!
    service.commit!
    allow_any_instance_of(PayrollItem).to receive(:financial_correction_origin_item=).and_call_original
    allow_any_instance_of(TimeTracking::FinancialCorrectionService).to receive(:record_commit!).and_call_original
    [ period, item ]
  end

  before do
    allow_any_instance_of(controller_class).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller_class).to receive(:current_user).and_return(actor)
    allow_any_instance_of(controller_class).to receive(:current_user_id).and_return(actor.id)
  end

  it "previews and connects the honest legacy row once without replaying amounts, checks, YTD or journals" do
    period, item = legacy_committed
    saved = [ period.reload.attributes, item.reload.attributes, EmployeeYtdTotal.find_by!(employee: employee, year: 2026).attributes,
      period.payroll_liability_postings.map(&:attributes), PayPeriodCorrectionEvent.count, CheckEvent.count ]
    get "/api/v1/admin/pay_periods/#{period.id}/corrected_hours"
    expect(response).to have_http_status(:ok)
    preview = response.parsed_body.fetch("corrected_hours")
    expect(preview.fetch("status")).to eq("needs_connection")
    expect(preview.fetch("items").first).to include("original_pay_period_id" => original_period.id, "corrected_pay_period_id" => period.id, "regular_hours" => 4.0)
    2.times do
      post "/api/v1/admin/pay_periods/#{period.id}/connect_corrected_hours", params: { expected_digest: preview.fetch("expected_digest") }, as: :json
      expect(response).to have_http_status(:ok)
    end
    expect(item.time_tracking_financial_correction_links.count).to eq(1)
    expect(item.financial_correction_origin_item_id).to be_nil
    expect([ period.reload.attributes, item.reload.attributes, EmployeeYtdTotal.find_by!(employee: employee, year: 2026).attributes,
      period.payroll_liability_postings.map(&:attributes), PayPeriodCorrectionEvent.count, CheckEvent.count ]).to eq(saved)
  end

  it "returns a meaningful stale-review error without creating technical or financial effects" do
    period, item = legacy_committed
    post "/api/v1/admin/pay_periods/#{period.id}/connect_corrected_hours", params: { expected_digest: "stale" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("review")
    expect(item.time_tracking_financial_correction_links).to be_empty
  end

  it "enforces staff role and tenant ownership on the new catch-up action" do
    period, item = legacy_committed
    actor.update!(role: "employee")
    post "/api/v1/admin/pay_periods/#{period.id}/connect_corrected_hours", params: { expected_digest: "not used" }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(item.time_tracking_financial_correction_links).to be_empty
    actor.update!(role: "admin")
    other = create(:company)
    allow_any_instance_of(controller_class).to receive(:current_company_id).and_return(other.id)
    get "/api/v1/admin/pay_periods/#{period.id}/corrected_hours"
    expect(response).not_to have_http_status(:ok)
    expect(item.time_tracking_financial_correction_links).to be_empty
  end
  it "returns a controlled unsupported-Source commit error with no partial money effects" do
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct saved payroll")
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct saved payroll")
    item = period.payroll_items.first!
    PayrollCalculator.for(employee, item).calculate
    item.save!
    period.update!(status: "calculated")
    PayPeriodLifecycleService.new(pay_period: period, actor: actor).approve!
    source.update!(source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2])
    saved = item.attributes
    post "/api/v1/admin/pay_periods/#{period.id}/commit", as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Test connection")
    expect(period.reload.status).to eq("approved")
    expect(item.reload.attributes).to eq(saved)
    expect(period.payroll_liability_postings).to be_empty
  end
end
