# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll history review items", type: :request do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: role) }
  let(:role) { "admin" }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }
  let(:path) { "/api/v1/admin/payroll_history_review_items" }
  let!(:run) { create(:pay_period, :voided, company: company, pay_date: "2026-01-16") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollHistoryReviewItemsController).to receive(:current_user).and_return(actor)
  end

  def list
    get path, params: { year: 2026 }, headers: headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def change(item, action, **attributes)
    post "#{path}/#{item.fetch('id')}/#{action}", params: { year: 2026,
      subject_digest: item.fetch("subject_digest"), **attributes }, headers: headers, as: :json
  end

  %w[admin org_admin super_admin].each do |admin_role|
    context "as #{admin_role}" do
      let(:role) { admin_role }

      it "lists, shows, resolves and reopens with attributable audit records" do
        payload = list
        item = payload.fetch("data").sole
        expect(payload.fetch("can_review")).to be(true)
        expect(item).to include("subject_type" => "voided_pay_period", "status" => "open")
        expect(item.fetch("resolution_codes")).to contain_exactly("void_replaced", "void_reissued", "other")

        get "#{path}/#{item.fetch('id')}", params: { year: 2026 }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "facts")).to include("id" => run.id, "void_reason" => run.void_reason)

        change(item, "resolve", resolution_code: "void_replaced", reference: "Replaced before any paycheck went out")
        expect(response).to have_http_status(:ok), response.body
        resolved = response.parsed_body.fetch("data")
        expect(resolved).to include("status" => "resolved", "resolved_by" => actor.name)
        expect(AuditLog.find_by!(action: "payroll_history_review#resolve", record_id: item.fetch("id"))).to have_attributes(
          actor_type: "staff_user", actor_id: actor.id.to_s, company_id: company.id)

        change(resolved, "reopen", reason: "New confirmation received")
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("data")).to include("status" => "open", "resolution_reference" => nil)
        expect(AuditLog.find_by!(action: "payroll_history_review#reopen", record_id: item.fetch("id"))).to have_attributes(actor_id: actor.id.to_s)
      end
    end
  end

  %w[manager accountant].each do |staff_role|
    context "as #{staff_role}" do
      let(:role) { staff_role }

      it "permits reading and denies both review mutations" do
        payload = list
        item = payload.fetch("data").sole
        expect(payload.fetch("can_review")).to be(false)
        change(item, "resolve", resolution_code: "void_replaced", reference: "Reviewed the replacement evidence")
        expect(response).to have_http_status(:forbidden)
        change(item, "reopen", reason: "Review again")
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  it "rejects another company's scope and an item from another year" do
    other = create(:company, organization: create(:organization))
    item = list.fetch("data").sole
    get path, params: { year: 2026 }, headers: { "X-Company-Id" => other.id.to_s }
    expect(response).to have_http_status(:forbidden)
    get "#{path}/#{item.fetch('id')}", params: { year: 2025 }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "rejects a mismatched reason, reserved proof code, and references outside the length limits" do
    employee = create(:employee, company: company)
    period = create(:pay_period, :committed, company: company, pay_date: "2026-01-16")
    create(:payroll_item, employee: employee, company: company, pay_period: period)
    items = list.fetch("data").index_by { |item| item.fetch("subject_type") }
    item = items.fetch("voided_pay_period")
    change(item, "resolve", resolution_code: "reversal_reviewed", reference: "Reviewed all relevant evidence")
    expect(response).to have_http_status(:unprocessable_content)
    gap = items.fetch("legacy_basis_gap")
    expect(gap.fetch("resolution_codes")).to eq([ "legacy_basis_accepted" ])
    change(gap, "resolve", resolution_code: "legacy_basis_proven", reference: "Reviewed all relevant evidence")
    expect(response).to have_http_status(:unprocessable_content)
    [ " too short ", "a" * 1001 ].each do |reference|
      change(item, "resolve", resolution_code: "void_replaced", reference: reference)
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(PayrollHistoryReviewItem.find(item.fetch("id"))).not_to be_resolved
  end

  it "requires the evidence the reviewer actually saw" do
    item = list.fetch("data").sole
    run.update_columns(void_reason: "Newly recorded reason")

    change(item, "resolve", resolution_code: "void_replaced", reference: "Reviewed all relevant evidence")
    expect(response).to have_http_status(:conflict)
    expect(list.fetch("data").sole.fetch("subject_digest")).not_to eq(item.fetch("subject_digest"))
  end
end
