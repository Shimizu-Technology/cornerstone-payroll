# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client portal alert recipients", :portal_notifications, type: :request do
  let!(:company) { create(:company, name: "Recipient Client") }
  let!(:other_company) { create(:company, organization: company.organization) }
  let!(:admin) { create(:user, company: company, role: "admin", name: "Avery Admin") }
  let!(:reviewer) { create(:user, company: company, role: "org_admin", name: "Riley Reviewer", email: "riley@example.test") }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }
  let(:path) { "/api/v1/admin/portal_notification_recipients" }

  def act_as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
  end

  def save(user_ids: [], emails: [], lead_user_id: nil, backup_user_id: nil, headers: self.headers)
    payload = { user_ids: user_ids, emails: emails }
    payload[:lead_user_id] = lead_user_id unless lead_user_id.nil?
    payload[:backup_user_id] = backup_user_id unless backup_user_id.nil?
    put path, params: payload, headers: headers, as: :json
  end

  before { act_as(admin) }

  it "lists eligible staff and warns when the client has no recipients" do
    create(:user, company: company, role: "admin", active: false)
    create(:user, company: company, role: "client")
    create(:user, role: "admin")

    get path, headers: headers

    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body.fetch("data")
    expect(data.fetch("eligible_users").map { |user| user.fetch("name") }).to eq([ "Avery Admin", "Riley Reviewer" ])
    expect(data).to include("recipient_count" => 0, "extra_emails" => [], "email_delivery_enabled" => false)
  end

  it "replaces the list, normalizes and dedupes addresses, and audits who changed it" do
    save(user_ids: [ reviewer.id, reviewer.id ], lead_user_id: reviewer.id, emails: [ " Owner@Example.TEST ", "owner@example.test", "books@example.test" ])

    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body.fetch("data")
    expect(data.fetch("extra_emails")).to eq([ "books@example.test", "owner@example.test" ])
    expect(data.fetch("eligible_users").select { |user| user["selected"] }.map { |user| user["id"] }).to eq([ reviewer.id ])
    expect(data.fetch("recipient_count")).to eq(3)
    expect(PortalNotificationRecipient.where(company: company).count).to eq(3)

    log = AuditLog.find_by!(action: "portal_notification_recipients#update")
    expect(log).to have_attributes(user_id: admin.id, company_id: company.id, subject_name: "Recipient Client")
    expect(log.metadata).to include("added_users" => [ { "id" => reviewer.id, "name" => "Riley Reviewer" } ],
      "added_emails" => [ "owner@example.test", "books@example.test" ], "removed_emails" => [], "recipient_count" => 3)
    expect(AuditLogPresenter.new(log).headline).to include("updated the Cornerstone account team for", "Recipient Client")

    save(user_ids: [], emails: [ "books@example.test" ])
    expect(PortalNotificationRecipient.where(company: company).pluck(:email)).to eq([ "books@example.test" ])
    removal = AuditLog.where(action: "portal_notification_recipients#update").newest_first.first
    expect(removal.metadata).to include("removed_users" => [ { "id" => reviewer.id, "name" => "Riley Reviewer" } ],
      "removed_emails" => [ "owner@example.test" ])

    expect { save(user_ids: [], emails: [ "BOOKS@example.test" ]) }.not_to change(AuditLog, :count)
  end

  it "rejects invalid addresses, too many addresses and users who cannot view the client" do
    save(emails: [ "not-an-email" ])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("not-an-email")

    save(emails: (1..21).map { |n| "extra#{n}@example.test" })
    expect(response).to have_http_status(:unprocessable_entity)

    [ create(:user, role: "admin"), create(:user, company: company, role: "client"),
      create(:user, company: company, role: "admin", active: false) ].each do |ineligible|
      save(user_ids: [ ineligible.id ])
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(PortalNotificationRecipient.count).to eq(0)
    expect(AuditLog.where(action: "portal_notification_recipients#update")).to be_empty
  end

  it "rejects an extra address that belongs to an account, so that person's own alert setting applies" do
    save(emails: [ "RILEY@example.test" ])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("riley@example.test already has a Cornerstone Payroll account")
    expect(PortalNotificationRecipient.where(company: company)).to be_empty

    save(user_ids: [ reviewer.id ], lead_user_id: reviewer.id, emails: [ "books@example.test" ])
    expect(response).to have_http_status(:ok), response.body
  end

  it "requires a Lead when staff are assigned and flags existing leadless teams with needs_lead" do
    PortalNotificationRecipient.create!(company: company, user: reviewer)
    get path, headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data")).to include("needs_lead" => true, "lead_user_id" => nil)

    save(user_ids: [ reviewer.id ])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Account lead")

    save(user_ids: [ reviewer.id ], backup_user_id: reviewer.id)
    expect(response).to have_http_status(:unprocessable_entity)

    save(user_ids: [ reviewer.id ], lead_user_id: reviewer.id)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data")).to include("needs_lead" => false, "lead_user_id" => reviewer.id)
  end

  it "assigns, swaps, validates, and audits Lead and Backup roles on the account team" do
    save(user_ids: [ admin.id, reviewer.id ], lead_user_id: admin.id, backup_user_id: reviewer.id)
    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body.fetch("data")
    expect(data).to include("lead_user_id" => admin.id, "backup_user_id" => reviewer.id)
    expect(data.fetch("eligible_users").find { |user| user["id"] == admin.id }["team_role"]).to eq("lead")
    expect(data.fetch("eligible_users").find { |user| user["id"] == reviewer.id }["team_role"]).to eq("backup")

    # Swapping Lead and Backup between two existing members works without hitting unique index collisions and writes an audit row.
    expect do
      save(user_ids: [ admin.id, reviewer.id ], lead_user_id: reviewer.id, backup_user_id: admin.id)
    end.to change { AuditLog.where(action: "portal_notification_recipients#update").count }.by(1)
    expect(response).to have_http_status(:ok), response.body
    swapped = response.parsed_body.fetch("data")
    expect(swapped).to include("lead_user_id" => reviewer.id, "backup_user_id" => admin.id)
    audit = AuditLog.where(action: "portal_notification_recipients#update").newest_first.first
    expect(audit.metadata).to include(
      "lead_user_id" => reviewer.id,
      "backup_user_id" => admin.id,
      "lead_user" => {
        "before" => { "id" => admin.id, "name" => "Avery Admin" },
        "after" => { "id" => reviewer.id, "name" => "Riley Reviewer" }
      }
    )

    # Rejects same person as both Lead and Backup or a Lead not included in user_ids.
    save(user_ids: [ admin.id ], lead_user_id: admin.id, backup_user_id: admin.id)
    expect(response).to have_http_status(:unprocessable_entity)
    save(user_ids: [ admin.id ], lead_user_id: reviewer.id)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "keeps each client's list separate" do
    save(emails: [ "first@example.test" ], headers: { "X-Company-Id" => other_company.id.to_s })
    get path, headers: headers
    expect(response.parsed_body.dig("data", "extra_emails")).to eq([])
    expect(PortalNotificationRecipient.find_by!(email: "first@example.test").company_id).to eq(other_company.id)
  end

  describe "access" do
    it "allows an accountant with Client management for this client only" do
      accountant = create(:user, company: company, role: "accountant")
      create(:company_assignment, user: accountant, company: company, client_management: true, granted_by: admin)
      create(:company_assignment, user: accountant, company: other_company)
      act_as(accountant)

      save(emails: [ "delegated@example.test" ])
      expect(response).to have_http_status(:ok), response.body

      save(emails: [ "elsewhere@example.test" ], headers: { "X-Company-Id" => other_company.id.to_s })
      expect(response).to have_http_status(:forbidden)
      get path, headers: { "X-Company-Id" => other_company.id.to_s }
      expect(response).to have_http_status(:forbidden)
    end

    it "allows managers" do
      act_as(create(:user, company: company, role: "manager"))

      get path, headers: headers
      expect(response).to have_http_status(:ok), response.body
      save(emails: [ "manager@example.test" ])
      expect(response).to have_http_status(:ok), response.body
    end

    it "denies accountants without Client management and client users" do
      accountant = create(:user, company: company, role: "accountant")
      create(:company_assignment, user: accountant, company: company)
      client = create(:user, company: company, role: "client")

      [ accountant, client ].each do |user|
        act_as(user)
        get path, headers: headers
        expect(response).to have_http_status(:forbidden)
        save(emails: [ "blocked@example.test" ])
        expect(response).to have_http_status(:forbidden)
      end
      expect(PortalNotificationRecipient.count).to eq(0)
    end
  end
end
