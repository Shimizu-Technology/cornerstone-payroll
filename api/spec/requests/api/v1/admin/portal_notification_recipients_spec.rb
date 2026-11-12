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

  def save(user_ids: [], emails: [], headers: self.headers)
    put path, params: { user_ids: user_ids, emails: emails }, headers: headers, as: :json
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
    save(user_ids: [ reviewer.id, reviewer.id ], emails: [ " Owner@Example.TEST ", "owner@example.test", "books@example.test" ])

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
    expect(AuditLogPresenter.new(log).headline).to include("updated portal alert recipients for", "Recipient Client")

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

    it "denies managers, accountants without Client management and client users" do
      manager = create(:user, company: company, role: "manager")
      accountant = create(:user, company: company, role: "accountant")
      create(:company_assignment, user: accountant, company: company)
      client = create(:user, company: company, role: "client")

      [ manager, accountant, client ].each do |user|
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
