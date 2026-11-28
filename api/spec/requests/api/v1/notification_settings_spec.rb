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
    expect(data.fetch("categories").to_h { |category| category.values_at("key", "delivery_mode") }).to eq(
      "admin_override_staff" => "immediate", "payroll_corrections_staff" => "immediate", "contact_confirmations" => "digest", "employee_app_follow_ups" => "digest",
      "w2_posting" => "immediate", "tax_form_paper_copies" => "immediate", "client_messages" => "immediate",
      "client_uploads" => "immediate", "employee_changes" => "digest", "employee_verifications" => "immediate",
      "payroll_submissions" => "immediate"
    )
    expect(data).not_to have_key("administration")
    patch path, params: { preferences: { payroll_super_admin: "off" } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "hides profile request categories while the feature is off" do
    act_as(client)
    get path
    expect(response.parsed_body.dig("data", "categories").map { |category| category["key"] }).to eq(
      %w[payroll_finalized payroll_corrections portal_replies employee_change_decisions payroll_updates])
    patch path, params: { preferences: { address_approvals: "off" } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PortalNotifications::Preferences.mode_for(client, "address_approvals")).to eq("immediate")
  end

  it "shows returned employee updates only to client managers of a client-managed company" do
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: Time.current
      )
    )
    viewer = create(:user, company: company, role: "client", client_access_level: "viewer")
    [ client, viewer ].each { |user| create(:company_assignment, user: user, company: company) }

    expect(PortalNotifications::Preferences.categories_for(client).keys).to include("employee_verification_followups")
    expect(PortalNotifications::Preferences.categories_for(viewer).keys).not_to include("employee_verification_followups")
  end

  it "shows viewers their payroll digest categories and rejects manager-only settings" do
    viewer = create(:user, :with_client_assignment, company: company, role: "client", client_access_level: "viewer")
    act_as(viewer)
    get path
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("data", "categories").to_h { |category| category.values_at("key", "delivery_mode") }).to eq(
      "payroll_finalized" => "digest", "payroll_viewer_updates" => "digest", "portal_replies" => "immediate",
      "employee_change_decisions" => "digest", "payroll_updates" => "immediate"
    )

    patch path, params: { preferences: { address_approvals: "off" } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "shows and saves profile request preferences when an assigned company enables them" do
    enabled_company = create(:company, organization: company.organization)
    ClientOperatingProfile.create!(company: enabled_company, effective_on: Date.new(2026, 1, 1),
      version: 1, offering: "payroll_portals", hours_source: "manual", client_portal_enabled: true, employee_portal_enabled: true, options: { "employee_portal" => { "features" => { "profile_requests" => true } } })
    activate_employee_app!(enabled_company)
    act_as(client)

    get path
    expect(response.parsed_body.dig("data", "categories").pluck("key")).not_to include("address_approvals", "contact_changes")

    create(:company_assignment, user: client, company: enabled_company)
    client.reload
    get path
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("data", "categories").pluck("key")).to include("address_approvals", "contact_changes")

    patch path, params: { preferences: { address_approvals: "off", contact_changes: "immediate" } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("data", "categories").to_h { |row| row.values_at("key", "delivery_mode") })
      .to include("address_approvals" => "off", "contact_changes" => "immediate")
    expect(PortalNotifications::Preferences.mode_for(client, "address_approvals")).to eq("off")
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
    expect(alerts.sole).to include("label" => "Client messages", "status" => "skipped", "skip_reason" => "email_delivery_disabled",
      "company_name" => "Settings Client")
    expect(response.body).not_to include("Hidden subject", "Hidden body")
  end

  it "leaves out alerts from companies the person can no longer open" do
    former = create(:company, organization: company.organization, name: "Former Client")
    CompanyAssignment.create!(user: staff, company: former)
    list_portal_recipient!(former, user: staff)
    thread = create(:client_portal_thread, company: former, created_by: client)
    PortalNotifications.message_created!(create(:client_portal_message, client_portal_thread: thread, company: former, author: client))
    expect(staff.portal_notification_deliveries.where(company: former)).to exist
    CompanyAssignment.where(user: staff, company: former).delete_all

    act_as(User.find(staff.id))
    get path
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("data", "recent_alerts")).to be_empty
    expect(response.body).not_to include("Former Client")
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
