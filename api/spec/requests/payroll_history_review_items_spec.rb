# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll history review items", type: :request do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: role) }
  let(:role) { "admin" }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }
  let(:path) { "/api/v1/admin/payroll_history_review_items" }
  let!(:run) { create(:pay_period, :voided, company: company, pay_date: "2026-01-16") }
  let!(:employee) { create(:employee, company: company) }
  let!(:check) { create(:payroll_item, company: company, employee: employee, pay_period: run) }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollHistoryReviewItemsController).to receive(:current_user).and_return(actor)
  end

  def list
    get path, params: { year: 2026 }, headers: headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def post_decision(item, action, **attributes)
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

        post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Replaced before any paycheck went out")
        expect(response).to have_http_status(:ok), response.body
        resolved = response.parsed_body.fetch("data")
        expect(resolved).to include("status" => "resolved", "resolved_by" => actor.name)
        expect(AuditLog.find_by!(action: "payroll_history_review#resolve", record_id: PayrollHistoryReviewItem.find_by!(pay_period: run).id)).to have_attributes(
          actor_type: "staff_user", actor_id: actor.id.to_s, company_id: company.id)

        post_decision(resolved, "reopen", reason: "New confirmation received")
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("data")).to include("status" => "open", "resolution_reference" => nil)
        expect(AuditLog.find_by!(action: "payroll_history_review#reopen", record_id: PayrollHistoryReviewItem.find_by!(pay_period: run).id)).to have_attributes(actor_id: actor.id.to_s)
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
        post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Reviewed the replacement evidence")
        expect(response).to have_http_status(:forbidden)
        post_decision(item, "reopen", reason: "Review again")
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
    post_decision(item, "resolve", resolution_code: "reversal_reviewed", reference: "Reviewed all relevant evidence")
    expect(response).to have_http_status(:unprocessable_content)
    gap = items.fetch("legacy_basis_gap")
    expect(gap.fetch("resolution_codes")).to eq([ "legacy_basis_accepted" ])
    post_decision(gap, "resolve", resolution_code: "legacy_basis_proven", reference: "Reviewed all relevant evidence")
    expect(response).to have_http_status(:unprocessable_content)
    [ " too short ", "a" * 1001 ].each do |reference|
      post_decision(item, "resolve", resolution_code: "void_replaced", reference: reference)
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(PayrollHistoryReviewItem.find_by(pay_period: run)).to be_nil
  end

  it "requires the evidence the reviewer actually saw" do
    item = list.fetch("data").sole
    run.update_columns(void_reason: "Newly recorded reason")

    post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Reviewed all relevant evidence")
    expect(response).to have_http_status(:conflict)
    expect(list.fetch("data").sole.fetch("subject_digest")).not_to eq(item.fetch("subject_digest"))
  end
  it "projects new and digest-mismatched items without writing or locking on GET" do
    sql = []
    observe = ->(_name, _start, _finish, _id, event) { sql << event.fetch(:sql) }
    item = nil
    expect do
      ActiveSupport::Notifications.subscribed(observe, "sql.active_record") do
        item = list.fetch("data").sole
        get "#{path}/#{item.fetch('id')}", params: { year: 2026 }, headers: headers
        expect(response).to have_http_status(:ok)
      end
    end.not_to change(PayrollHistoryReviewItem, :count)
    expect(sql.grep(/FOR UPDATE|INSERT INTO|UPDATE "|DELETE FROM/i)).to be_empty

    post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Replaced without issuing payment")
    expect(response).to have_http_status(:ok)
    recorded = PayrollHistoryReviewItem.find_by!(pay_period: run)
    run.update_columns(void_reason: "Corrected source evidence")
    reader = create(:user, company: company, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::PayrollHistoryReviewItemsController).to receive(:current_user).and_return(reader)
    expect do
      expect(list.fetch("data").sole).to include("status" => "open", "resolved_by" => nil)
      get "#{path}/#{item.fetch('id')}", params: { year: 2026 }, headers: headers
      expect(response.parsed_body.dig("data", "status")).to eq("open")
    end.not_to change(AuditLog, :count)
    expect(recorded.reload).to be_resolved

    allow_any_instance_of(Api::V1::Admin::PayrollHistoryReviewItemsController).to receive(:current_user).and_return(actor)
    fresh = list.fetch("data").sole
    post_decision(fresh, "resolve", resolution_code: "void_replaced", reference: "Replacement checked against updated evidence")
    expect(response).to have_http_status(:ok)
    expect(AuditLog.find_by!(action: "payroll_history_review#reopen", record_id: recorded.id)).to have_attributes(
      actor_type: "system_job", actor_name: "Payroll history detection")
  end

  it "displays computed items in maintenance while denying both writes" do
    allow(WriteMaintenance).to receive(:enabled?).and_return(true)
    payload = list
    expect(payload.fetch("can_review")).to be(false)
    item = payload.fetch("data").sole

    expect do
      post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Replacement checked against the records")
      expect(response).to have_http_status(:service_unavailable)
      post_decision(item, "reopen", reason: "Review again")
      expect(response).to have_http_status(:service_unavailable)
    end.not_to change(PayrollHistoryReviewItem, :count)
  end

  it "allows sealed workspace reads without allowing review writes" do
    company.update_columns(payroll_environment: "migration_rehearsal", migration_rehearsal_status: "ready",
      test_workspace_purpose: "sandbox", migration_source_company_id: create(:company).id, test_workspace_sealed_at: Time.current)
    payload = list
    expect(payload.fetch("can_review")).to be(false)
    item = payload.fetch("data").sole

    expect do
      post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Replacement checked against the records")
      expect(response).to have_http_status(:forbidden)
      post_decision(item, "reopen", reason: "Review again")
      expect(response).to have_http_status(:forbidden)
    end.not_to change(PayrollHistoryReviewItem, :count)
  end

  context "with delegated client management" do
    let(:role) { "accountant" }

    it "still denies resolve and reopen" do
      assignment = create(:company_assignment, company: company, user: actor)
      assignment.update!(client_management: true, granted_by: create(:user, company: company))
      payload = list
      expect(payload.fetch("can_review")).to be(false)
      item = payload.fetch("data").sole
      post_decision(item, "resolve", resolution_code: "void_replaced", reference: "Replacement checked against the records")
      expect(response).to have_http_status(:forbidden)
      post_decision(item, "reopen", reason: "Review again")
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "as a client" do
    let(:role) { "client" }

    it "denies reading payroll history review" do
      get path, params: { year: 2026 }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "denies another company's item under an accessible company header" do
    other = create(:company)
    foreign_run = create(:pay_period, :voided, company: other, pay_date: "2026-01-16")
    create(:payroll_item, company: other, employee: create(:employee, company: other), pay_period: foreign_run)
    foreign = { "id" => "voided_pay_period-#{foreign_run.id}", "subject_digest" => "b" * 64 }

    get "#{path}/#{foreign.fetch('id')}", params: { year: 2026 }, headers: headers
    expect(response).to have_http_status(:not_found)
    expect do
      post_decision(foreign, "resolve", resolution_code: "void_replaced", reference: "Replacement checked against the records")
      expect(response).to have_http_status(:not_found)
      post_decision(foreign, "reopen", reason: "Review again")
      expect(response).to have_http_status(:not_found)
    end.not_to change(PayrollHistoryReviewItem, :count)
  end

  it "accepts the documented other resolution for unresolved legacy dispositions" do
    prior = create(:pay_period, :committed, company: company, pay_date: "2026-01-16")
    row = create(:payroll_item, company: company, employee: employee, pay_period: prior)
    PayrollItemLegacyDisposition.insert_all!([ { payroll_item_id: row.id, company_id: company.id,
      created_by_id: actor.id, reason: "retired_legacy_reason", evidence_digest: "a" * 64 } ])
    item = list.fetch("data").find { |entry| entry["subject_type"] == "legacy_disposition" }
    expect(item.fetch("resolution_codes")).to eq([ "other" ])

    post_decision(item, "resolve", resolution_code: "other", reference: "Traced disposition to archived adjustment notes")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include("status" => "resolved", "resolution_code" => "other")
  end
end
