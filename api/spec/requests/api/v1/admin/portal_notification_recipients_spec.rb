# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client portal alert recipients", :portal_notifications, type: :request do
  include ActiveSupport::Testing::TimeHelpers

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

  it "rejects an extra address (including Gmail/Googlemail aliases) that belongs to a same-organization account" do
    reviewer.update!(email: "riley.staff@gmail.com")
    [ "RILEY.STAFF@gmail.com", "rileystaff+alerts@gmail.com", "r.i.l.e.y.staff+payroll@googlemail.com" ].each do |variant|
      save(emails: [ variant ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("already has a Cornerstone Payroll account")
    end
    expect(PortalNotificationRecipient.where(company: company)).to be_empty

    save(user_ids: [ reviewer.id ], lead_user_id: reviewer.id, emails: [ "books@example.test" ])
    expect(response).to have_http_status(:ok), response.body
  end

  it "deduplicates canonical Gmail aliases on save and counts distinct canonical identities" do
    save(emails: [ "alice.books@gmail.com", "alicebooks+alerts@gmail.com", "a.l.i.c.e.books@googlemail.com" ])
    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body.fetch("data")
    expect(data.fetch("extra_emails")).to eq([ "alice.books@gmail.com" ])
    expect(data.fetch("recipient_count")).to eq(1)
    expect(PortalNotificationRecipient.where(company: company).count).to eq(1)

    # Even if two legacy Gmail alias rows exist in DB, recipient_count counts distinct canonical identities.
    PortalNotificationRecipient.create!(company: company, email: "alicebooks+legacy@googlemail.com")
    get path, headers: headers
    expect(response.parsed_body.dig("data", "recipient_count")).to eq(1)
  end

  it "makes foreign-organization extra addresses indistinguishable from unregistered addresses across every tenant-visible field while suppressing delivery" do
    ensure_verified_test_tax_years(2026)
    company_unreg = create(:company, organization: company.organization, name: "Unreg Client", client_payroll_approval_required: true)
    company_foreign = create(:company, organization: company.organization, name: "Foreign Match Client", client_payroll_approval_required: true)
    client_unreg = create(:user, company: company_unreg, organization: company.organization, role: "client", client_access_level: "manager")
    client_foreign = create(:user, company: company_foreign, organization: company.organization, role: "client", client_access_level: "manager")
    create(:company_assignment, user: client_unreg, company: company_unreg)
    create(:company_assignment, user: client_foreign, company: company_foreign)

    foreign_org = create(:organization)
    foreign_company = create(:company, organization: foreign_org)
    create(:user, company: foreign_company, organization: foreign_org, role: "admin", email: "outsidepartner+ops@googlemail.com")

    unreg_email = "never.registered@gmail.com"
    foreign_email = "outside.partner@gmail.com"

    save(emails: [ unreg_email ], headers: { "X-Company-Id" => company_unreg.id.to_s })
    expect(response).to have_http_status(:ok), response.body
    save_unreg = response.parsed_body.fetch("data").except("company_id", "extra_emails")

    save(emails: [ foreign_email ], headers: { "X-Company-Id" => company_foreign.id.to_s })
    expect(response).to have_http_status(:ok), response.body
    save_foreign = response.parsed_body.fetch("data").except("company_id", "extra_emails")
    expect(save_foreign).to eq(save_unreg)

    # Trigger both a client message and a payroll review approval in each company with email enabled.
    emp_u = create(:employee, company: company_unreg)
    period_u = create(:pay_period, :calculated, company: company_unreg,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
    create(:payroll_item, company: company_unreg, pay_period: period_u, employee: emp_u, gross_pay: 1_000, net_pay: 850)
    PayPeriodLifecycleService.new(pay_period: period_u, actor: admin).approve!

    emp_f = create(:employee, company: company_foreign)
    period_f = create(:pay_period, :calculated, company: company_foreign,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
    create(:payroll_item, company: company_foreign, pay_period: period_f, employee: emp_f, gross_pay: 1_000, net_pay: 850)
    PayPeriodLifecycleService.new(pay_period: period_f, actor: admin).approve!

    with_portal_email do
      thread_u = create(:client_portal_thread, company: company_unreg, created_by: client_unreg)
      PortalNotifications.message_created!(create(:client_portal_message, company: company_unreg, client_portal_thread: thread_u, author: client_unreg))
      thread_f = create(:client_portal_thread, company: company_foreign, created_by: client_foreign)
      PortalNotifications.message_created!(create(:client_portal_message, company: company_foreign, client_portal_thread: thread_f, author: client_foreign))

      pkg_u = period_u.payroll_review_packages.current.first!
      PayrollReview::RevisionService.new(pay_period: period_u, actor: client_unreg).approve!(
        approver: client_unreg, recorded_by: client_unreg, method: "client_portal",
        revision_id: pkg_u.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )
      pkg_f = period_f.payroll_review_packages.current.first!
      PayrollReview::RevisionService.new(pay_period: period_f, actor: client_foreign).approve!(
        approver: client_foreign, recorded_by: client_foreign, method: "client_portal",
        revision_id: pkg_f.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )

      # Immediately after approval: every tenant-visible field matches identically.
      get path, headers: { "X-Company-Id" => company_unreg.id.to_s }
      get_unreg = response.parsed_body.fetch("data").except("company_id", "extra_emails")
      get path, headers: { "X-Company-Id" => company_foreign.id.to_s }
      get_foreign = response.parsed_body.fetch("data").except("company_id", "extra_emails")
      expect(get_foreign).to eq(get_unreg)
      expect(get_foreign["unnotified_event_count"]).to eq(0)

      get "/api/v1/notification_settings"
      missing_ids = response.parsed_body.dig("data", "administration", "clients_without_recipients").map { |row| row["company_id"] }
      expect(missing_ids).not_to include(company_unreg.id, company_foreign.id)

      expect(PayrollReview::PackagePresenter.decision_notification_status(pkg_f.reload))
        .to eq(PayrollReview::PackagePresenter.decision_notification_status(pkg_u.reload))
      expect(PayrollReview::PackagePresenter.decision_notification_queued?(pkg_f))
        .to eq(PayrollReview::PackagePresenter.decision_notification_queued?(pkg_u))
      expect(PayrollReview::PackagePresenter.decision_notification_status(pkg_f)).to eq("queued")

      # After dispatch window: only the unregistered extra actually receives email, yet both show "sent".
      travel_to(3.minutes.from_now) do
        PortalNotifications::Dispatcher.run!
        expect(captured_portal_emails.map { |mail| mail[:to] }).to include(unreg_email)
        expect(captured_portal_emails.map { |mail| mail[:to] }).not_to include(foreign_email, "outsidepartner+ops@googlemail.com")
        expect(PayrollReview::PackagePresenter.decision_notification_status(pkg_f.reload))
          .to eq(PayrollReview::PackagePresenter.decision_notification_status(pkg_u.reload))
        expect(PayrollReview::PackagePresenter.decision_notification_status(pkg_f)).to eq("sent")
      end
    end
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
