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

  it "exposes decision access on the list and detail and denies a preparer deciding their own preview" do
    staff_approve
    @actor = client
    get "/api/v1/client/pay_periods", params: { status: "approved" }
    expect(response.parsed_body.fetch("pay_periods")).to contain_exactly(
      include("id" => period.id, "client_review_status" => "pending", "can_decide_payroll_review" => true)
    )

    review.update_column(:generated_by_id, client.id)
    get base
    expect(response.parsed_body.fetch("pay_period")).to include("can_decide_payroll_review" => false)
    client_approve
    expect(response).to have_http_status(:unprocessable_entity)
    expect(review).to be_pending
  end

  it "filters each client preview part and audits the exact selection" do
    deposit = create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company, first_name: "Dina", last_name: "Deposit"),
      payment_delivery_method: "direct_deposit", gross_pay: 200, net_pay: 180)
    zero = create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company, first_name: "Zoe", last_name: "Zero"), gross_pay: 50, net_pay: 0)
    PayrollReview::RevisionService.new(pay_period: period.reload, actor: staff).issue!
    staff_approve
    @actor = client
    { nil => 3, "checks" => 1, "stubs" => 2, "all_stubs" => 3 }.each do |part, count|
      get "#{base}/preview_pdf", params: { revision_id: review.id, part: part }.compact
      expect(response).to have_http_status(:ok), response.body
      pages = PDF::Reader.new(StringIO.new(response.body)).pages
      expect(pages.size).to eq(count)
      expect(response.headers["Content-Disposition"]).to include("_#{part}.pdf") if part
      text = pages.map(&:text).join
      if part == "stubs"
        expect(text).to include(deposit.employee.full_name, zero.employee.full_name)
        expect(text).not_to include(employee.full_name)
      end
      expect(AuditLog.where(action: "client_payroll_review#preview_pdf").last.metadata["part"]).to eq(part || "combined")
    end
  end

  it "regenerates preview amounts and advances the filename revision after hours change and reapproval" do
    change_compensation!(employee, pay_rate: 20, payment_delivery_method: "direct_deposit")
    period.update!(status: "draft")
    amounts = []
    filenames = []
    [ 40, 60 ].each_with_index do |hours, index|
      if index.positive?
        post "#{admin}/unapprove"
        expect(response).to have_http_status(:ok), response.body
      end
      post "#{admin}/run_payroll", params: { employee_ids: [ employee.id ], hours: { employee.id.to_s => { regular: hours, overtime: 0 } } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors")).to eq([])
      staff_approve
      get "/api/v1/admin/pay_periods/#{period.id}/checks/preview_pdf", params: { part: "stubs" }
      expect(response).to have_http_status(:ok), response.body
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join
      amounts << employee.payroll_items.find_by!(pay_period: period).gross_pay
      expect(amounts.last).to eq(hours * 20)
      expect(text.delete(",")).to include(format("%0.2f", amounts.last))
      expect(text.delete(",")).not_to include(format("%0.2f", amounts.first)) if index.positive?
      filenames << response.headers["Content-Disposition"]
    end
    expect(filenames.last[/_rev(\d+)/, 1].to_i).to be > filenames.first[/_rev(\d+)/, 1].to_i
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
    expect(review.published_at).to be_nil
    expect(PortalNotificationEvent.where(event_type: "payroll_review_published")).to be_empty
    @actor = client
    get base
    expect(response).to have_http_status(:not_found)
    @actor = staff
    post "#{admin}/commit"
    expect(response).to have_http_status(:ok), response.body
    @actor = client
    get base
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("pay_period", "payroll_review")).to be_nil
    expect(response.parsed_body.dig("pay_period", "payroll_review_history")).to eq([])
  end

  it "blocks commit over a current change request even when the setting is disabled" do
    staff_approve
    @actor = client
    post "#{base}/request_changes", params: { revision_id: review.id, note: "Add two hours" }
    expect(response).to have_http_status(:ok)
    company.update!(client_payroll_approval_required: false)
    @actor = staff
    post "#{admin}/commit"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("#{client.name} requested changes: Add two hours. Unapprove to make changes.")
    expect(period.reload).to be_approved
  end

  it "keeps staff approval and the client decision when notification recording fails" do
    allow(PortalNotifications).to receive(:record!).and_wrap_original do |original, **args|
      original.call(**args)
      raise ActiveRecord::StatementInvalid, "notification failure"
    end
    staff_approve
    expect(period.reload).to be_approved
    expect(review.published_at).to be_present
    expect(PortalNotificationEvent.where(event_type: "payroll_review_published")).to be_empty
    client_approve
    expect(response).to have_http_status(:ok), response.body
    expect(review).to be_approved
    expect(PortalNotificationEvent.where(event_type: "payroll_review_decided")).to be_empty
  end

  it "recovers a missing publication event when staff open the approved run" do
    allow(PortalNotifications).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "notification failure")
    staff_approve
    package = review
    events = PortalNotificationEvent.where(dedupe_key: "payroll_review_published:#{package.id}")
    expect(events).to be_empty
    get admin
    expect(response).to have_http_status(:ok), response.body
    expect(events).to be_empty

    allow(PortalNotifications).to receive(:record!).and_call_original
    company.update!(client_payroll_approval_required: false)
    get admin
    expect(response).to have_http_status(:ok), response.body
    expect(events).to be_empty
    company.update!(client_payroll_approval_required: true)
    2.times do
      get admin
      expect(response).to have_http_status(:ok), response.body
    end
    expect(events.count).to eq(1)
    expect(events.first.deliveries.pluck(:user_id)).to include(client.id)
    expect(period.reload).to be_approved
    expect(package.reload.published_at).to be_present
  end

  it "renders outside the period lock and rejects a changed checksum without auditing or serving the PDF" do
    staff_approve
    @actor = client
    allow(PayrollPreviewPdf).to receive(:generate).and_wrap_original do |original, **args|
      expect(PayPeriod.connection.transaction_open?).to be(true) # request spec fixture transaction only
      expect(PayPeriod.connection.open_transactions).to eq(1)
      pdf = original.call(**args)
      item.update!(net_pay: 1_101)
      pdf
    end
    expect { get "#{base}/preview_pdf", params: { revision_id: review.id } }
      .not_to change { AuditLog.where(action: "client_payroll_review#preview_pdf").count }
    expect(response).to have_http_status(:conflict)
    expect(response.media_type).to eq("application/json")
  end

  it "returns the stale revision response when staff unapprove during preview generation" do
    staff_approve
    package = review
    @actor = client
    allow(PayrollPreviewPdf).to receive(:generate).and_wrap_original do |original, **args|
      pdf = original.call(**args)
      PayPeriodLifecycleService.new(pay_period: period.reload, actor: staff).unapprove!
      pdf
    end

    expect { get "#{base}/preview_pdf", params: { revision_id: package.id } }
      .not_to change { AuditLog.where(action: "client_payroll_review#preview_pdf").count }

    expect(response).to have_http_status(:conflict)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body["code"]).to eq("stale_payroll_review_revision")
    expect(response.headers["Content-Disposition"]).to be_nil
    expect(period.reload).to be_calculated
    expect(package.reload).to be_superseded
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
  it "treats a published review as unavailable while disabled, including stale services, without decision notifications" do
    staff_approve
    package = review
    service = PayrollReview::RevisionService.new(pay_period: period, actor: client)
    period.company # prime the old enabled setting
    company.update!(client_payroll_approval_required: false)
    @actor = client
    get base
    expect(response).to have_http_status(:not_found)
    get "/api/v1/client/pay_periods"
    expect(response.parsed_body.fetch("pay_periods").map { |row| row["id"] }).not_to include(period.id)
    expect do
      expect { service.request_changes!(revision_id: package.id, note: "Add hours") }.to raise_error(PayrollReview::RevisionService::Error, /disabled/)
      expect { service.approve!(approver: client, recorded_by: client, method: "client_portal", revision_id: package.id,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT) }.to raise_error(PayrollReview::RevisionService::Error, /disabled/)
      client_approve(package.id)
      expect(response).to have_http_status(:not_found)
      post "#{base}/request_changes", params: { revision_id: package.id, note: "Add hours" }
      expect(response).to have_http_status(:not_found)
    end.not_to change { PortalNotificationEvent.where(event_type: "payroll_review_decided").count }
    expect(package.reload).to have_attributes(status: "pending", changes_requested_at: nil, published_at: be_present)
    @actor = staff
    post "#{admin}/commit"
    expect(response).to have_http_status(:ok), response.body
    @actor = client
    get base
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("pay_period", "payroll_review")).to be_nil
    expect(response.parsed_body.dig("pay_period", "payroll_review_history")).to eq([])
  end

  it "reports honest notification_status and notification_queued on client approval and change requests" do
    staff_approve
    # With email delivery disabled (default in specs), no email is queued.
    @actor = client
    post "#{base}/request_changes", params: { revision_id: review.id, note: "Need update" }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("payroll_review")).to include("notification_queued" => false, "notification_status" => "not_sent")
    get base
    expect(response.parsed_body.dig("pay_period", "payroll_review")).to include("notification_queued" => false, "notification_status" => "not_sent")

    # Unapprove and publish a fresh revision, then enable email with an account team assigned.
    @actor = staff
    post "#{admin}/unapprove"
    expect(response).to have_http_status(:ok)
    staff_approve
    with_portal_email do
      client_approve
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("payroll_review")).to include("notification_queued" => true, "notification_status" => "queued")
      get base
      expect(response.parsed_body.dig("pay_period", "payroll_review")).to include("notification_queued" => true, "notification_status" => "queued")

      # Once the dispatcher sends the email, status transitions from queued to sent.
      PortalNotifications::Dispatcher.run!(now: 3.minutes.from_now)
      get base
      expect(response.parsed_body.dig("pay_period", "payroll_review")).to include("notification_queued" => false, "notification_status" => "sent")
    end

    # When email is enabled but transport is unconfigured (no sender / API key), notification stays not_sent.
    @actor = staff
    post "#{admin}/unapprove"
    staff_approve
    with_portal_email(transport: nil, from: nil) do
      client_approve
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("payroll_review")).to include("notification_queued" => false, "notification_status" => "not_sent")
      get base
      expect(response.parsed_body.dig("pay_period", "payroll_review")).to include("notification_queued" => false, "notification_status" => "not_sent")
    end

    # When no account team is assigned, notification stays not_sent even with email enabled.
    @actor = staff
    post "#{admin}/unapprove"
    staff_approve
    PortalNotificationRecipient.where(company: company).delete_all
    with_portal_email do
      client_approve
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("payroll_review")).to include("notification_queued" => false, "notification_status" => "not_sent")
    end
  end

  it "excludes client viewers from payroll_review_published notifications" do
    viewer = create(:user, company: company, role: "client", client_access_level: "viewer")
    create(:company_assignment, user: viewer, company: company)

    staff_approve

    event = PortalNotificationEvent.find_by!(event_type: "payroll_review_published")
    expect(event.deliveries.pluck(:user_id)).to eq([ client.id ])
    expect(event.deliveries.pluck(:user_id)).not_to include(viewer.id)
  end

  it "codes stale revisions separately from validation errors" do
    staff_approve
    @actor = client
    post "#{base}/request_changes", params: { revision_id: review.id, note: " " }
    expect(response.parsed_body).not_to have_key("code")
    post "#{base}/request_changes", params: { revision_id: -1, note: "Add hours" }
    expect(response.parsed_body["code"]).to eq("stale_payroll_review_revision")
    get "#{base}/preview_pdf", params: { revision_id: -1 }
    expect(response.parsed_body["code"]).to eq("stale_payroll_review_revision")
    client_approve(-1)
    expect(response.parsed_body["code"]).to eq("stale_payroll_review_revision")
  end
end
