# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Portal activity notifications", :portal_notifications, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:company) { create(:company, name: "Notify Client") }
  let!(:department) { create(:department, company: company) }
  let!(:client) { create(:user, company: company, role: "client", email: "client.one@example.test") }
  let!(:second_client) { create(:user, company: company, role: "client", email: "client.two@example.test") }
  let!(:staff) { create(:user, company: company, role: "admin", email: "dafne.synthetic@example.test") }
  let!(:unlisted_staff) { create(:user, company: company, role: "admin") }
  let(:thread) { create(:client_portal_thread, company: company, created_by: client, subject: "Payroll questions") }
  let(:upload_path) { Rails.root.join("spec/fixtures/files/client_portal_upload.txt") }

  before do
    CompanyAssignment.create!(user: client, company: company)
    CompanyAssignment.create!(user: second_client, company: company)
    list_portal_recipient!(company, user: staff)
    list_portal_recipient!(company, email: "outside.owner@example.test")
    allow_any_instance_of(ApplicationController).to receive(:current_company_id).and_return(company.id)
    allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT)
  end

  def act_as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
  end

  def dispatch_later
    travel(3.minutes) { PortalNotifications::Dispatcher.run! }
  end

  it "records a client message for listed staff and extra addresses, then sends the captured generic email" do
    act_as(client)
    with_portal_email do
      post "/api/v1/client/portal_threads/#{thread.id}/messages",
        params: { body: "Private note about Jordan's wages", idempotency_key: "retry-1" }, as: :json
      expect(response).to have_http_status(:created), response.body
      post "/api/v1/client/portal_threads/#{thread.id}/messages",
        params: { body: "Private note about Jordan's wages", idempotency_key: "retry-1" }, as: :json
      expect(response).to have_http_status(:ok)

      event = PortalNotificationEvent.sole
      expect(event).to have_attributes(event_type: "client_message", category: "client_messages", actor_id: client.id,
        recipient_status: "recipients", subject: thread)
      expect(event.metadata.keys).to contain_exactly("message_id", "thread_id", "attachment_count")
      expect(event.deliveries.pluck(:recipient_key, :status)).to contain_exactly(
        [ "user:#{staff.id}", "pending" ], [ "email:outside.owner@example.test", "pending" ])

      dispatch_later
      expect(captured_portal_emails.map { |email| email[:to] }).to contain_exactly(staff.email, "outside.owner@example.test")
      captured_portal_emails.each do |email|
        expect([ email[:subject], email[:text], email[:html] ].join).not_to include("Jordan", "Payroll questions", "Notify Client")
      end
      expect(event.deliveries.pluck(:status).uniq).to eq([ "sent" ])
    end
  end

  it "records a new client conversation with its first message once" do
    act_as(client)
    post "/api/v1/client/portal_threads", params: { subject: "New topic", body: "First message", idempotency_key: "topic-1" }, as: :json
    expect(response).to have_http_status(:created), response.body
    post "/api/v1/client/portal_threads", params: { subject: "New topic", body: "First message", idempotency_key: "topic-1" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(PortalNotificationEvent.where(event_type: "client_message").count).to eq(1)
  end

  it "records one alert for a multi-file client upload" do
    act_as(client)
    with_portal_email do
      post "/api/v1/client/documents", params: {
        category: "payroll_source",
        files: [ Rack::Test::UploadedFile.new(upload_path, "text/plain"), Rack::Test::UploadedFile.new(upload_path, "text/plain") ]
      }
      expect(response).to have_http_status(:created), response.body
      event = PortalNotificationEvent.sole
      expect(event).to have_attributes(event_type: "client_upload", category: "client_uploads")
      expect(event.metadata).to include("document_count" => 2)
      expect(event.deliveries.where(status: "pending").count).to eq(2)

      dispatch_later
      expect(captured_portal_emails.size).to eq(2)
      expect(captured_portal_emails).to all(include(text: include("You have a new message or update in the portal.")))
      expect(captured_portal_emails.map { |email| email[:text] }.join).not_to include("client_portal_upload")
    end
  end

  it "records a staff reply for the client's portal users, not the staff actor" do
    act_as(staff)
    with_portal_email do
      post "/api/v1/admin/portal_threads/#{thread.id}/messages", params: { body: "Reply with private detail" }, as: :json
      expect(response).to have_http_status(:created), response.body
      event = PortalNotificationEvent.sole
      expect(event).to have_attributes(event_type: "staff_reply", category: "portal_replies")
      expect(event.deliveries.map(&:user)).to contain_exactly(client, second_client)

      dispatch_later
      expect(captured_portal_emails.map { |email| email[:to] }).to contain_exactly(client.email, second_client.email)
      expect(captured_portal_emails.first[:text]).to include("https://payroll.example.test/documents")
    end
  end

  it "records a skipped no-recipients row when the client has nobody configured" do
    PortalNotificationRecipient.where(company: company).delete_all
    act_as(client)
    post "/api/v1/client/portal_threads/#{thread.id}/messages", params: { body: "Anyone there?" }, as: :json
    expect(response).to have_http_status(:created)

    event = PortalNotificationEvent.sole
    expect(event.recipient_status).to eq("no_recipients")
    expect(event.deliveries.sole).to have_attributes(user_id: nil, recipient_key: "none", status: "skipped", skip_reason: "no_recipients")
    expect(PortalNotificationEvent.without_staff_recipients).to eq([ event ])
  end

  it "rolls back the alert with the message when the audit write fails" do
    act_as(client)
    allow(PortalActivity).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
    post "/api/v1/client/portal_threads/#{thread.id}/messages", params: { body: "Will not save" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ClientPortalMessage.count).to eq(0)
    expect(PortalNotificationEvent.count).to eq(0)
  end

  describe "employee change requests" do
    let!(:employee) { create(:employee, company: company, department: department, pay_rate: 18.0) }

    it "alerts reviewers on submission and the requester on the decision" do
      act_as(client)
      allow_any_instance_of(ApplicationController).to receive(:current_company).and_return(company)
      with_portal_email do
        patch "/api/v1/client/employees/#{employee.id}", params: { employee: { pay_rate: 21.75 } }
      end
      expect(response).to have_http_status(:ok), response.body

      submitted = PortalNotificationEvent.find_by!(event_type: "employee_change_submitted")
      expect(submitted.deliveries.where.not(user_id: nil).sole).to have_attributes(user_id: staff.id, delivery_mode: "digest")
      expect(submitted.deliveries.find_by!(recipient_email: "outside.owner@example.test").delivery_mode).to eq("digest")
      expect(submitted.deliveries.first.deliver_after.in_time_zone("Pacific/Guam").hour).to eq(7)

      act_as(staff)
      with_portal_email do
        patch "/api/v1/admin/employee_change_requests/#{EmployeeChangeRequest.sole.id}/approve", params: { review_notes: "OK" }
        expect(response).to have_http_status(:ok), response.body
        decided = PortalNotificationEvent.find_by!(event_type: "employee_change_decided")
        expect(decided.metadata).to include("decision" => "approved")
        delivery = decided.deliveries.sole
        expect(delivery).to have_attributes(user_id: client.id, status: "pending", delivery_mode: "digest")

        travel_to(delivery.deliver_after + 1.minute) { PortalNotifications::Dispatcher.run! }
        expect(delivery.reload.status).to eq("sent")
        expect(captured_portal_emails.map { |email| email[:to] }).to include(client.email)
      end
    end

    %w[approve reject].each do |decision|
      it "keeps no #{decision} decision or alert when its audit write fails" do
        request = create(:employee_change_request, company: company, employee: employee, requested_by: client,
          proposed_changes: { pay_rate: 23.5 }, original_values: { pay_rate: 18.0 })
        act_as(staff)
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(action: "employee_change_requests##{decision}"))
          .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

        patch "/api/v1/admin/employee_change_requests/#{request.id}/#{decision}", params: { review_notes: "Synthetic review" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(request.reload).to have_attributes(status: "pending", reviewed_by_id: nil, reviewed_at: nil)
        expect(employee.reload.pay_rate.to_f).to eq(18.0)
        expect(PortalNotificationEvent.where(event_type: "employee_change_decided")).to be_empty
        expect(PortalNotificationDelivery.joins(:portal_notification_event)
          .where(portal_notification_events: { event_type: "employee_change_decided" })).to be_empty
      end
    end
  end
end
