# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Published payroll review loop", type: :request do
  let!(:company) { create(:company, client_payroll_approval_required: true) }
  let!(:staff) { create(:user, company: company, role: "manager") }
  let!(:client) { create(:user, company: company, role: "client") }
  let!(:period) { create(:pay_period, :calculated, company: company) }
  let!(:employee) { create(:employee, company: company) }
  let!(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 1_200, net_pay: 1_100) }
  let(:base) { "/api/v1/client/pay_periods/#{period.id}" }
  let(:admin) { "/api/v1/admin/pay_periods/#{period.id}" }
  def review
    period.payroll_review_packages.current.first!
  end

  before do
    ensure_verified_test_tax_years(2024)
    create(:company_assignment, user: client, company: company)
    create(:company_assignment, user: staff, company: company)
    PortalNotificationRecipient.create!(company: company, user: staff)
    @actor = staff
    allow_any_instance_of(ApplicationController).to receive(:current_user) { @actor }
    allow_any_instance_of(ApplicationController).to receive(:current_company_id).and_return(company.id)
    PayrollReview::RevisionService.new(pay_period: period, actor: staff).issue!
  end

  def staff_approve
    @actor = staff
    post "#{admin}/approve"
    expect(response).to have_http_status(:ok), response.body
  end

  def client_approve(id = review.id)
    @actor = client
    post "#{base}/approve_review", params: { revision_id: id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT, notes: "Reviewed preview" }
  end

  it "publishes at staff approval, audits preview access, notifies both ways and commits only after exact client approval" do
    @actor = client
    get base
    expect(response).to have_http_status(:not_found)
    staff_approve
    expect(review.published_at).to be_present
    expect(PortalNotificationEvent.find_by!(event_type: "payroll_review_published").deliveries.pluck(:user_id)).to include(client.id)
    @actor = client
    expect { get "#{base}/preview_pdf", params: { revision_id: review.id } }
      .to change { AuditLog.where(action: "client_payroll_review#preview_pdf").count }.by(1)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join
    expect(text).to include("PREVIEW", employee.full_name)
    @actor = staff
    post "#{admin}/commit"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload).to be_approved
    client_approve
    expect(response).to have_http_status(:ok), response.body
    event = PortalNotificationEvent.find_by!(event_type: "payroll_review_decided")
    expect(event.deliveries.pluck(:user_id)).to include(staff.id)
    expect(event.metadata).to include("decision" => "approved", "revision" => 1)
    @actor = staff
    post "#{admin}/commit"
    expect(response).to have_http_status(:ok), response.body
    expect(period.reload).to be_committed
    @actor = client
    get "#{base}/preview_pdf", params: { revision_id: review.id }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "retains the required change note, withdraws, recalculates and publishes a new review" do
    staff_approve
    first = review
    @actor = client
    post "#{base}/request_changes", params: { revision_id: first.id, note: " " }
    expect(response).to have_http_status(:unprocessable_entity)
    post "#{base}/request_changes", params: { revision_id: first.id, note: "Add two hours" }
    expect(response).to have_http_status(:ok), response.body
    expect(first.reload).to have_attributes(changes_requested_by: client, change_request_note: "Add two hours", changes_requested_at: be_present)
    expect(PortalNotificationEvent.find_by!(event_type: "payroll_review_decided").metadata["decision"]).to eq("changes_requested")
    client_approve(first.id)
    expect(response).to have_http_status(:unprocessable_entity)
    @actor = staff
    post "#{admin}/unapprove"
    expect(response).to have_http_status(:ok)
    expect(first.reload).to be_superseded
    post "#{admin}/run_payroll", params: { employee_ids: [ employee.id ], hours: { employee.id.to_s => { regular: 82, overtime: 0 } } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    staff_approve
    expect(review.revision).to eq(2)
    client_approve(first.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect { get "#{base}/preview_pdf", params: { revision_id: first.id } }.not_to change(AuditLog, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    client_approve
    expect(response).to have_http_status(:ok)
    get base
    expect(response.parsed_body.dig("pay_period", "payroll_review_history").map { |row| row["revision"] }).to eq([ 2, 1 ])
    expect(response.body).to include("Add two hours")
    expect(PortalNotificationEvent.where(event_type: "payroll_review_published").count).to eq(2)
  end

  it "withdraws an approval on unapprove even if calculation amounts stay the same" do
    staff_approve
    first = review
    client_approve
    @actor = staff
    post "#{admin}/unapprove"
    expect(response).to have_http_status(:ok)
    expect(first.reload).to have_attributes(status: "superseded", approved_by: client, approval_notes: "Reviewed preview")
    expect(AuditLog.where(action: "payroll_review#withdrawn", record_id: first.id)).to exist
    staff_approve
    expect(review).to have_attributes(revision: 2, status: "pending")
    post "#{admin}/commit"
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "requires no client gate with the setting off" do
    company.update!(client_payroll_approval_required: false)
    staff_approve
    @actor = staff
    post "#{admin}/commit"
    expect(response).to have_http_status(:ok), response.body
  end

  it "rejects a different company's run and stale calculations without exposing PDFs or decisions" do
    staff_approve
    @actor = client
    foreign = create(:pay_period, :approved)
    get "/api/v1/client/pay_periods/#{foreign.id}/preview_pdf", params: { revision_id: review.id }
    expect(response).to have_http_status(:not_found)
    item.update!(net_pay: 1_101)
    get "#{base}/preview_pdf", params: { revision_id: review.id }
    expect(response).to have_http_status(:unprocessable_entity)
    client_approve
    expect(response).to have_http_status(:unprocessable_entity)
    expect(review).to be_pending
  end

  it "rolls back publication if its audit fails" do
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordNotSaved)
    expect { PayPeriodLifecycleService.new(pay_period: period, actor: staff).approve! }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(period.reload).to be_calculated
    expect(review.published_at).to be_nil
  end
  it "rolls back a client decision when its audit fails" do
    staff_approve
    package = review
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordNotSaved)
    service = PayrollReview::RevisionService.new(pay_period: period.reload, actor: client)
    expect { service.request_changes!(revision_id: package.id, note: "Add two hours") }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(package.reload.changes_requested_at).to be_nil
    expect(PortalNotificationEvent.where(event_type: "payroll_review_decided")).to be_empty
  end
end
