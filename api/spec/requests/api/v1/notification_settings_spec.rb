# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Personal portal notification settings", :portal_notifications, type: :request do
  let!(:company) { create(:company, name: "Settings Client") }
  let!(:staff) { create(:user, company: company, role: "manager") }
  let!(:client) { create(:user, company: company, role: "client") }
  let(:path) { "/api/v1/notification_settings" }

  def act_as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
  end

  it "shows staff categories with the recommended defaults and email off" do
    act_as(staff)
    get path
    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body.fetch("data")
    expect(data.fetch("email_delivery_enabled")).to be(false)
    expect(data.fetch("digest_time_label")).to eq("7:00 AM Chamorro Time")
    expect(data.fetch("categories").map { |category| [ category["key"], category["delivery_mode"] ] }).to eq(
      [ [ "client_messages", "immediate" ], [ "client_uploads", "immediate" ], [ "employee_changes", "digest" ] ])
    expect(data).not_to have_key("administration")
  end

  it "shows client categories only to client users" do
    act_as(client)
    get path
    expect(response.parsed_body.dig("data", "categories").map { |category| category["key"] }).to eq(
      %w[portal_replies employee_change_decisions])
  end

  it "saves a preference with an audit record and rejects other audiences' categories or modes" do
    act_as(staff)
    patch path, params: { preferences: { employee_changes: "off", client_messages: "digest" } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(PortalNotifications::Preferences.modes_for(staff)).to include("employee_changes" => "off", "client_messages" => "digest")
    log = AuditLog.find_by!(action: "notification_settings#update")
    expect(log.metadata.fetch("changes")).to include("employee_changes" => %w[digest off])

    patch path, params: { preferences: { portal_replies: "off" } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch path, params: { preferences: { client_messages: "weekly" } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch path, params: { preferences: "off" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch path, params: { preferences: { not_a_category: "off" } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PortalNotifications::Preferences.mode_for(staff, "client_messages")).to eq("digest")
  end

  it "lists only the person's own recent alerts with generic labels" do
    other = create(:user, company: company, role: "admin")
    list_portal_recipient!(company, user: staff)
    list_portal_recipient!(company, user: other)
    thread = create(:client_portal_thread, company: company, created_by: client, subject: "Hidden subject")
    PortalNotifications.message_created!(create(:client_portal_message, client_portal_thread: thread, company: company, author: client, body: "Hidden body"))

    act_as(staff)
    get path
    alerts = response.parsed_body.dig("data", "recent_alerts")
    expect(alerts.size).to eq(1)
    expect(alerts.sole).to include("label" => "Client messages", "status" => "pending", "company_name" => "Settings Client")
    expect(response.body).not_to include("Hidden subject", "Hidden body")
  end

  it "shows administrators the clients whose portal work had nobody to notify" do
    admin = create(:user, company: company, role: "admin")
    thread = create(:client_portal_thread, company: company, created_by: client)
    PortalNotifications.message_created!(create(:client_portal_message, client_portal_thread: thread, company: company, author: client))

    act_as(admin)
    get path
    warning = response.parsed_body.dig("data", "administration", "clients_without_recipients").sole
    expect(warning).to include("company_id" => company.id, "company_name" => "Settings Client", "event_count" => 1)
  end

  it "is unavailable to employee-role accounts" do
    act_as(create(:user, company: company, role: "employee"))
    get path
    expect(response).to have_http_status(:forbidden)
  end
end
