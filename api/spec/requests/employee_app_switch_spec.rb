# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee app switch (M4-9d)", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:path) { "/api/v1/admin/employee_app_switch" }
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Example Grill", subdomain_slug: "example-grill") }
  let(:demo) { create_demo_company(organization: organization, subdomain_slug: "harborfinch") }
  let(:org_admin) { create(:user, company: company, organization: organization, role: :org_admin, clerk_id: "user_org_admin", name: "Avery Admin") }
  let(:database_state) { { phase: "enforced", enforced: true, enforced_tables: 1, protected_tables: 1 } }
  let(:ping) { { configured: true, ok: true } }
  let(:terms_status) { "approved" }
  let(:ready_env) do
    {
      "REQUIRE_MFA" => "true", "CLERK_MFA_ATTESTED_INSTANCE_ID" => "ins_example", "CLERK_MFA_EVIDENCE_REF" => "evidence-ref",
      "CLERK_AUTHORIZED_PARTIES" => "https://payroll.example.com"
    }
  end

  around do |example|
    saved = ready_env.keys.index_with { |key| ENV[key] }
    ready_env.each { |key, value| ENV[key] = value }
    example.run
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  before do
    allow(EmployeeAppSwitch::Readiness).to receive(:database_state) { database_state }
    allow(EmployeeAppSwitch::Readiness).to receive(:ping_employee_service) { ping }
    observe!
    EmployeeTermsVersion.create!(version: "terms-1", status: terms_status, terms_url: "https://example.com/terms",
      privacy_url: "https://example.com/privacy", published_at: 1.day.ago)
    DeliveryDisclosure::KINDS.each do |kind|
      DeliveryDisclosure.create!(kind: kind, version: "approved-1", title: "#{kind} consent", text: "Approved #{kind} wording.",
        status: "approved", published_at: 1.day.ago)
    end
  end

  def observe!(**overrides)
    EmployeeServiceObservation.where(service: "employee_web").delete_all
    EmployeeServiceObservation.create!({
      service: "employee_web", observed_at: Time.current, revision: "abc123", process_role: "employee_web",
      rls_guard_mode: "raise", rls_runtime_role_verified: true, require_mfa: true, mfa_evidence_recorded: true,
      authorized_parties_valid: true, dependencies_healthy: true, service_checks_passed: true, failed_checks: []
    }.merge(overrides))
  end

  def auth(user = org_admin, recent: true, target: company)
    fva = recent ? [ 1, 1 ] : [ 30, 30 ]
    bearer(user.clerk_id, fva: fva, two_factor_enabled: true).merge("X-Company-Id" => target.id.to_s)
  end

  def switch!(changes, reason: "Pilot ready", user: org_admin, recent: true, target: company)
    patch path, params: { changes: changes, reason: reason }, as: :json, headers: auth(user, recent: recent, target: target)
  end

  def stored(target = company)
    EmployeeAppSwitch.stored_values(target)
  end

  def failing_names
    response.parsed_body.fetch("failing_checks").map { |check| check.fetch("name") }
  end

  def check(key, target: company)
    get path, headers: auth(target: target)
    response.parsed_body.dig("data", "readiness", "checks").find { |row| row["key"] == key }
  end

  def turn_on_directly!(target, keys)
    target.with_lock do
      EmployeeAppSwitch::ProfileWriter.apply!(company: target, actor: org_admin, values: keys.index_with(true), reason: "Fixture")
    end
  end

  describe "who can use it" do
    it "is for organization and platform admins only" do
      get path, headers: auth
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "company", "name")).to eq("Example Grill")

      %i[admin manager accountant].each do |role|
        user = create(:user, company: company, organization: organization, role: role, clerk_id: "user_#{role}")
        CompanyAssignment.create!(user: user, company: company) unless role == :admin
        get path, headers: auth(user)
        expect(response).to have_http_status(:forbidden), "#{role} should be refused"
        switch!({ "employee_portal_enabled" => false }, user: user)
        expect(response).to have_http_status(:forbidden)
      end

      other_org = create(:organization)
      outsider = create(:user, company: create(:company, organization: other_org), organization: other_org, role: :org_admin, clerk_id: "user_outsider")
      get path, headers: auth(outsider)
      expect(response).to have_http_status(:forbidden)
      expect(AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION)).to be_empty
    end
  end

  describe "turning on" do
    it "turns on a ready company one part at a time, with a reason, and audits the checks" do
      switch!({ "employee_portal_enabled" => true }, reason: "MoSa's pilot week 1")
      expect(response).to have_http_status(:ok), response.body
      expect(stored).to include("employee_portal_enabled" => true, "subdomain_enabled" => false)
      expect(EmployeeAppSwitch.effective_values(company)).to include("employee_portal_enabled" => true)

      switch!({ "subdomain_enabled" => true, "employee_portal.features.stubs" => true })
      expect(response).to have_http_status(:ok), response.body
      expect(stored).to include("subdomain_enabled" => true, "employee_portal.features.stubs" => true,
        "employee_portal.features.tax_forms" => false)

      audit = AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: company.id).order(:id).first
      expect(audit.user_id).to eq(org_admin.id)
      expect(audit.metadata).to include("reason" => "MoSa's pilot week 1", "turned_on" => [ "employee_portal_enabled" ], "turned_off" => [])
      expect(audit.metadata.fetch("readiness").map { |row| row["key"] }).to include("mfa", "rls_guard", "rls_database",
        "authorized_parties", "subdomain", "employee_service", "terms")
      expect(audit.metadata.fetch("readiness")).to all(include("status" => "passed"))
    end

    it "keeps operating_profiles:parity explaining every version it writes" do
      switch!({ "employee_portal_enabled" => true })
      switch!({ "employee_portal.features.stubs" => true })
      switch!({ "employee_portal_enabled" => false }, recent: false)
      expect(response).to have_http_status(:ok), response.body

      result = ClientOperatingProfiles::ParityChecker.call(companies: Company.where(id: company.id))
      expect(result.differences.map(&:field)).to eq([])
      versions = company.client_operating_profiles.order(:effective_on).pluck(:version)
      expect(versions).to eq(versions.sort)
      expect(AuditLog.where(action: ClientOperatingProfiles::UpdateService::AUDIT_ACTION, company_id: company.id).pluck(:metadata))
        .to all(include("source" => "employee_app_switch"))
    end

    it "won't turn on ahead of a scheduled profile version, but still turns off" do
      turn_on_directly!(company, %w[subdomain_enabled])
      travel_to(1.day.from_now) do
        current = company.client_operating_profiles.history_order.first
        current.update!(ends_on: PayrollBusinessClock.today + 13)
        company.client_operating_profiles.create!(current.attributes.except("id", "created_at", "updated_at", "lock_version")
          .merge("effective_on" => PayrollBusinessClock.today + 14, "ends_on" => nil, "version" => current.version + 1))
        observe!

        switch!({ "employee_portal_enabled" => true })
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("scheduled for #{(PayrollBusinessClock.today + 14).iso8601}")

        switch!({ "subdomain_enabled" => false }, recent: false)
        expect(response).to have_http_status(:ok), response.body
        expect(EmployeeAppSwitch.stored_values(company, today: PayrollBusinessClock.today + 20)["subdomain_enabled"]).to be(false)
      end
    end

    it "needs a reason and a fresh second factor" do
      switch!({ "employee_portal_enabled" => true }, reason: " ")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Enter a reason for the change.")

      switch!({ "employee_portal_enabled" => true }, recent: false)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("clerk_error", "reason")).to eq("reverification-error")
      expect(stored["employee_portal_enabled"]).to be(false)
    end

    it "keeps bank changes off and features under the employee app" do
      switch!({ "employee_portal.features.bank_requests" => true })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Bank account changes stays off")

      switch!({ "employee_portal.features.stubs" => true })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Turn on the employee app before turning on its features.")
    end

    {
      "mfa" => [ "Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim)", -> { ENV["REQUIRE_MFA"] = "false" } ],
      "employee mfa" => [ "Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim)", -> { observe!(require_mfa: false) } ],
      "rls_guard" => [ "The employee service refuses any database read without a company (RLS guard in raise mode)", -> { observe!(rls_guard_mode: "log") } ],
      "rls_database" => [ "The database enforces company separation (row-level security on)",
        -> { allow(EmployeeAppSwitch::Readiness).to receive(:database_state).and_return(phase: "shadow", enforced: false, enforced_tables: 0, protected_tables: 1) } ],
      "authorized_parties" => [ "Sign-in accepts only our own web addresses (CLERK_AUTHORIZED_PARTIES set)", -> { ENV["CLERK_AUTHORIZED_PARTIES"] = "" } ],
      "subdomain" => [ "The company's web address (subdomain) is set", -> { company.update_columns(subdomain_slug: nil) } ],
      "employee_service" => [ "The employee service is running and healthy",
        -> { allow(EmployeeAppSwitch::Readiness).to receive(:ping_employee_service).and_return(configured: true, ok: false) } ],
      "stale employee service" => [ "The employee service is running and healthy", -> { observe!(observed_at: 10.minutes.ago) } ],
      "terms" => [ "Employee App Terms and Privacy Notice wording is approved by counsel", -> { } ],
      "company" => [ "This is a live client or a demo company", -> { company.update_columns(active: false) } ]
    }.each do |label, (name, break_it)|
      it "refuses to turn on while the #{label} check fails, and names it" do
        allow(EmployeeTermsVersion).to receive(:current).and_return(nil) if label == "terms"
        instance_exec(&break_it)
        switch!({ "employee_portal_enabled" => true })

        expect(response).to have_http_status(:unprocessable_entity), response.body
        expect(response.parsed_body["code"]).to eq("not_ready")
        expect(failing_names).to include(name)
        expect(stored["employee_portal_enabled"]).to be(false)
        expect(AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION)).to be_empty
      end
    end

    it "lists the failing check on the screen before anyone tries" do
      observe!(rls_guard_mode: "off")
      row = check("rls_guard")
      expect(row).to include("status" => "failed", "detail" => "The employee service's guard is set to off, not raise.")
      blocked = response.parsed_body.dig("data", "switches").find { |switch| switch["key"] == "employee_portal_enabled" }
      expect(blocked["blocked_by"]).to eq([ "rls_guard" ])
    end

    it "requires approved consent wording for a real company's consent screens" do
      turn_on_directly!(company, %w[employee_portal_enabled])
      DeliveryDisclosure.create!(kind: "w2gu", version: "draft-2", title: "W-2GU consent", text: "Draft wording.",
        status: "draft", published_at: Time.current)
      allow(DeliveryDisclosure).to receive(:current_for).and_call_original
      allow(DeliveryDisclosure).to receive(:current_for).with("w2gu").and_return(DeliveryDisclosure.find_by!(version: "draft-2"))

      switch!({ "employee_portal.features.delivery_consent" => true })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(failing_names).to eq([ "Electronic delivery consent wording is approved by counsel" ])
      expect(response.parsed_body["failing_checks"].first["detail"]).to include("W-2GU consent wording is still a draft")

      # Stubs show no consent screen, so draft consent wording doesn't block them.
      switch!({ "employee_portal.features.stubs" => true })
      expect(response).to have_http_status(:ok)
    end
  end

  describe "turning off" do
    it "always works, even with every check failing and no fresh second factor, and cascades to features" do
      turn_on_directly!(company, %w[employee_portal_enabled subdomain_enabled employee_portal.features.stubs employee_portal.features.tax_forms])
      ENV["REQUIRE_MFA"] = "false"
      ENV["CLERK_AUTHORIZED_PARTIES"] = ""
      EmployeeServiceObservation.delete_all
      allow(EmployeeAppSwitch::Readiness).to receive(:database_state).and_return(phase: "shadow", enforced: false, enforced_tables: 0, protected_tables: 1)
      allow(EmployeeAppSwitch::Readiness).to receive(:ping_employee_service).and_return(configured: false, ok: false)
      company.update_columns(subdomain_slug: nil)

      switch!({ "employee_portal_enabled" => false, "subdomain_enabled" => false }, reason: "Pause the pilot", recent: false)
      expect(response).to have_http_status(:ok), response.body
      expect(stored.values).to all(be(false))
      audit = AuditLog.find_by!(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: company.id)
      expect(audit.metadata).to include("reason" => "Pause the pilot", "turned_on" => [],
        "turned_off" => [ "employee_portal_enabled", "subdomain_enabled", "employee_portal.features.stubs", "employee_portal.features.tax_forms" ])
    end

    it "turns off later scheduled versions too" do
      turn_on_directly!(company, %w[employee_portal_enabled])
      current = company.client_operating_profiles.history_order.first
      current.update!(ends_on: PayrollBusinessClock.today + 13)
      later = company.client_operating_profiles.create!(current.attributes.except("id", "created_at", "updated_at", "lock_version")
        .merge("effective_on" => PayrollBusinessClock.today + 14, "ends_on" => nil, "version" => current.version + 1))

      switch!({ "employee_portal_enabled" => false }, recent: false)
      expect(response).to have_http_status(:ok), response.body
      expect(later.reload.employee_portal_enabled).to be(false)
      expect(EmployeeAppSwitch.stored_values(company, today: PayrollBusinessClock.today + 20)["employee_portal_enabled"]).to be(false)
    end
  end

  describe "the operating profile editor" do
    it "keeps a switched-on value through other edits but can't turn one on" do
      turn_on_directly!(company, %w[employee_portal_enabled])
      latest = company.client_operating_profiles.history_order.first
      service = ->(changes) do
        ClientOperatingProfiles::UpdateService.new(company: company, actor: org_admin, effective_on: PayrollBusinessClock.today.iso8601,
          changes: changes, reason: "Edit", lock_version: latest.reload.lock_version)
      end
      expect { service.call("subdomain_enabled" => true).call }
        .to raise_error(ClientOperatingProfiles::UpdateService::Invalid, /Employee app switch screen/)

      start = PayrollBusinessClock.today + 7
      create(:pay_period, company: company, start_date: start, end_date: start + 13, pay_date: start + 17, status: "draft")
      edited = ClientOperatingProfiles::UpdateService.new(company: company, actor: org_admin, effective_on: start.iso8601,
        changes: { "client_portal_enabled" => true }, reason: "Open the client portal", lock_version: latest.reload.lock_version).call
      expect(edited).to have_attributes(client_portal_enabled: true, employee_portal_enabled: true)

      ClientOperatingProfiles::UpdateService.new(company: company, actor: org_admin, effective_on: start.iso8601,
        changes: { "employee_portal_enabled" => false }, reason: "Off from the editor", lock_version: edited.reload.lock_version).call
      expect(EmployeeAppSwitch.stored_values(company, today: start)["employee_portal_enabled"]).to be(false)
    end
  end

  describe "the demo early-access rule" do
    let(:shadow) { { phase: "shadow", enforced: false, enforced_tables: 0, protected_tables: 1 } }
    let(:database_state) { shadow }

    def open_window!(company_ids: [ demo.id ], expires_on: PayrollBusinessClock.today + 7)
      put "#{path}/early_access", params: { expires_on: expires_on.iso8601, company_ids: company_ids, reason: "Owner approved rehearsal" },
        as: :json, headers: auth(target: demo)
    end

    let(:terms_status) { "draft" }

    it "waives only the database check, only for a named demo, only before expiry" do
      open_window!
      expect(response).to have_http_status(:ok), response.body
      window = EmployeeAppEarlyAccessWindow.sole
      expect(window).to have_attributes(company_ids: [ demo.id ], set_by_id: org_admin.id, reason: "Owner approved rehearsal")
      expect(AuditLog.find_by!(action: "employee_app_early_access#set").metadata).to include("company_ids" => [ demo.id ])

      expect(check("rls_database", target: demo)).to include("status" => "waived")
      data = response.parsed_body["data"]
      expect(data.dig("readiness", "observed")).to include("rls_guard_mode" => "raise", "rls_runtime_role_verified" => true)
      expect(data.dig("readiness", "database")).to include("phase" => "shadow", "enforced" => false)

      switch!({ "employee_portal_enabled" => true }, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(stored(demo)["employee_portal_enabled"]).to be(true)
      audit = AuditLog.find_by!(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: demo.id)
      expect(audit.metadata).to include("early_access_window_id" => window.id)
      expect(audit.metadata["readiness"]).to include({ "key" => "rls_database", "status" => "waived" })

      # A real company never gets the exception, and draft terms never count for it.
      EmployeeTermsVersion.create!(version: "terms-draft-2", status: "draft", terms_url: "https://example.com/terms",
        privacy_url: "https://example.com/privacy", published_at: Time.current)
      switch!({ "employee_portal_enabled" => true })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(failing_names).to contain_exactly("The database enforces company separation (row-level security on)",
        "Employee App Terms and Privacy Notice wording is approved by counsel")

      travel_to((PayrollBusinessClock.today + 8).in_time_zone(PayrollBusinessClock::TIME_ZONE).change(hour: 9)) do
        observe!
        expect(check("rls_database", target: demo)).to include("status" => "failed")
        expect(check("rls_database", target: demo)["detail"]).to include("window ended on #{window.expires_on.iso8601}")
        switch!({ "subdomain_enabled" => true }, target: demo)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(failing_names).to eq([ "The database enforces company separation (row-level security on)" ])
      end
    end

    it "keeps every other check required and needs the employee guard in raise mode" do
      open_window!
      ENV["REQUIRE_MFA"] = "false"
      observe!(rls_guard_mode: "log")
      switch!({ "subdomain_enabled" => true }, target: demo)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(failing_names).to include("Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim)",
        "The employee service refuses any database read without a company (RLS guard in raise mode)",
        "The database enforces company separation (row-level security on)")
    end

    it "doesn't cover a demo the window doesn't name" do
      other_demo = create_demo_company(organization: organization, name: "Harbor Finch Catering", fixture_key: "harbor-finch-catering",
        subdomain_slug: "harborfinch-catering")
      open_window!
      expect(check("rls_database", target: other_demo)["detail"]).to include("No demo early-access window covers this company")
    end

    it "accepts only demo companies and an expiry within #{EmployeeAppEarlyAccessWindow::MAX_DAYS} days, with a fresh second factor" do
      open_window!(company_ids: [ company.id ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Real companies can't use early access")

      open_window!(expires_on: PayrollBusinessClock.today + 32)
      expect(response).to have_http_status(:unprocessable_entity)
      open_window!(expires_on: PayrollBusinessClock.today - 1)
      expect(response).to have_http_status(:unprocessable_entity)

      put "#{path}/early_access", params: { expires_on: (PayrollBusinessClock.today + 3).iso8601, company_ids: [ demo.id ], reason: "x" },
        as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:forbidden)
      expect(EmployeeAppEarlyAccessWindow.count).to eq(0)
    end

    it "ends a window with a reason, and the row can't be edited afterwards" do
      open_window!
      delete "#{path}/early_access", params: { reason: "Rehearsal finished" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      window = EmployeeAppEarlyAccessWindow.sole
      expect(window).to have_attributes(ended_by_id: org_admin.id, end_reason: "Rehearsal finished")
      expect(window.ended_at).to be_present
      savepoint = ->(&block) { EmployeeAppEarlyAccessWindow.transaction(requires_new: true, &block) }
      expect { savepoint.call { window.update_columns(expires_on: PayrollBusinessClock.today + 3) } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { savepoint.call { window.update_columns(end_reason: "Rewritten") } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { savepoint.call { window.delete } }.to raise_error(ActiveRecord::StatementInvalid)
      expect(AuditLog.find_by!(action: "employee_app_early_access#ended").metadata).to include("reason" => "Rehearsal finished")
    end
  end

  describe "when demo early access stops applying" do
    let(:database_state) { { phase: "shadow", enforced: false, enforced_tables: 0, protected_tables: 1 } }
    let(:shadow) { -> { database_state } }

    def open_window_for(target, expires_on:)
      EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ target.id ], expires_on: expires_on,
        reason: "Owner approved", set_by: org_admin)
    end

    it "closes a demo's switches automatically after the expiry date, and never a real company's" do
      open_window_for(demo, expires_on: PayrollBusinessClock.today + 2)
      turn_on_directly!(demo, %w[employee_portal_enabled employee_portal.features.stubs])
      turn_on_directly!(company, %w[employee_portal_enabled])

      CloseExpiredDemoEarlyAccessJob.perform_now
      expect(stored(demo)["employee_portal_enabled"]).to be(true)

      travel_to((PayrollBusinessClock.today + 3).in_time_zone(PayrollBusinessClock::TIME_ZONE).change(hour: 0, min: 5)) do
        CloseExpiredDemoEarlyAccessJob.perform_now
        expect(stored(demo).values).to all(be(false))
        expect(stored(company)["employee_portal_enabled"]).to be(true)
        audit = AuditLog.find_by!(action: EmployeeAppSwitch::DemoExpiry::ACTION, company_id: demo.id)
        expect(audit.metadata).to include("turned_off" => [ "employee_portal_enabled", "employee_portal.features.stubs" ])
        expect(audit.actor_type).to eq("system_job")
      end
    end

    it "closes right away when an admin ends the window, and does nothing once the database enforces RLS" do
      open_window_for(demo, expires_on: PayrollBusinessClock.today + 5)
      turn_on_directly!(demo, %w[employee_portal_enabled])
      expect(EmployeeAppSwitch::DemoExpiry.call(database_state: -> { { enforced: true } })).to eq([])

      delete "#{path}/early_access", params: { reason: "Guard failed" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(stored(demo)["employee_portal_enabled"]).to be(false)
    end
  end

  describe "the demo kill switch" do
    let(:database_state) { { phase: "shadow", enforced: false, enforced_tables: 0, protected_tables: 1 } }

    it "turns every demo's employee app off, ends early access and support views, keeps data, and leaves real companies alone" do
      EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ demo.id ], expires_on: PayrollBusinessClock.today + 5,
        reason: "Owner approved", set_by: org_admin)
      turn_on_directly!(demo, %w[employee_portal_enabled subdomain_enabled employee_portal.features.stubs])
      turn_on_directly!(company, %w[employee_portal_enabled])
      staff = create(:user, company: company, organization: organization, role: :super_admin, clerk_id: "user_support")
      grant = ViewAsGrant.create!(company: demo, staff_user: staff, target_employee: create(:employee, company: demo), reason: "Check a view",
        token_digest: "d" * 64, expires_at: 20.minutes.from_now)
      employees_before = demo.employees.count

      post "#{path}/demo_stop", params: { reason: "Leak suspected" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body

      expect(stored(demo).values).to all(be(false))
      expect(stored(company)["employee_portal_enabled"]).to be(true)
      expect(EmployeeAppEarlyAccessWindow.sole.ended_at).to be_present
      expect(EmployeeAppEarlyAccessWindow.sole.end_reason).to eq("Demo employee access stopped: Leak suspected")
      expect(grant.reload.ended_at).to be_present
      expect(demo.employees.count).to eq(employees_before)
      expect(response.parsed_body.dig("stopped", "companies")).to contain_exactly(include("company_id" => demo.id,
        "turned_off" => [ "employee_portal_enabled", "subdomain_enabled", "employee_portal.features.stubs" ], "support_views_ended" => 1))
      expect(AuditLog.where(action: "employee_app_switch#demo_stopped", organization_id: organization.id).count).to eq(1)
      expect(AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: demo.id).last.metadata)
        .to include("demo_stop" => true, "reason" => "Leak suspected")
      expect(AuditLog.where(action: "view_as#ended", company_id: demo.id).count).to eq(1)
    end

    it "revokes pending demo invitations and ends employee-only demo sign-ins" do
      employee = create(:employee, company: demo)
      probe = EmployeeAccountLink.new(company: demo, employee: employee, status: "invited")
      skip "Needs demo employee links (demo D6, PR #585)" unless probe.valid?

      turn_on_directly!(demo, %w[employee_portal_enabled])
      invited = invite!(employee, actor: org_admin, delivery: "code").link
      expect(invited.reload).to be_invited

      post "#{path}/demo_stop", params: { reason: "Rehearsal over" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(invited.reload).to have_attributes(status: "revoked", revoked_reason: "Demo employee access stopped: Rehearsal over")
      expect(response.parsed_body.dig("stopped", "companies", 0, "invitations_revoked")).to eq(1)
    end

    it "is for organization admins only" do
      admin = create(:user, company: company, organization: organization, role: :admin, clerk_id: "user_plain_admin")
      post "#{path}/demo_stop", params: { reason: "Stop" }, as: :json, headers: auth(admin, target: demo)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
