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
  let(:owner) { create(:user, company: company, organization: organization, role: :super_admin, clerk_id: "user_owner", name: "Olive Owner") }
  let(:database_state) { { phase: "enforced", enforced: true, kill_switch_bypass: false, enforced_tables: 1, protected_tables: 1 } }
  let(:enforced_state) { { phase: "enforced", enforced: true, kill_switch_bypass: false, enforced_tables: 1, protected_tables: 1 } }
  let(:shadow_state) { { phase: "shadow", enforced: false, kill_switch_bypass: false, enforced_tables: 0, protected_tables: 1 } }
  let(:terms_status) { "approved" }
  let(:ready_env) do
    {
      "REQUIRE_MFA" => "true", "CLERK_MFA_ATTESTED_INSTANCE_ID" => "ins_example", "CLERK_MFA_EVIDENCE_REF" => "evidence-ref",
      "CLERK_AUTHORIZED_PARTIES" => "https://payroll.example.com",
      DemoOutbound::ENV_KEY => "demo.worker@demo-mail.example,demo.pending@demo-mail.example"
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
    allow(EmployeeAppSwitch::Enforcement).to receive(:database_state) { database_state }
    # This process stands in for the guarded employee service (a demo under
    # the early-access waiver needs one).
    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
    allow(EmployeeAppSwitch::Readiness).to receive(:ping_employee_service) { @ping }
    observe!
    EmployeeTermsVersion.create!(version: "terms-1", status: terms_status, terms_url: "https://example.com/terms",
      privacy_url: "https://example.com/privacy", published_at: 1.day.ago)
    DeliveryDisclosure::KINDS.each do |kind|
      DeliveryDisclosure.create!(kind: kind, version: "approved-1", title: "#{kind} consent", text: "Approved #{kind} wording.",
        status: "approved", published_at: 1.day.ago)
    end
  end

  # What the employee service's live, signed health answer says.
  def observe!(**overrides)
    observation = EmployeeAppSwitch::ServiceAttestation::Observation.new(**{
      revision: "abc123", process_role: "employee_web", rls_guard_mode: "raise", rls_runtime_role_verified: true,
      rls_kill_switch_bypass: false, require_mfa: true, mfa_evidence_recorded: true, authorized_parties_valid: true,
      dependencies_healthy: true, service_checks_passed: true, failed_checks: [], issued_at: Time.current
    }.merge(overrides))
    @ping = { configured: true, ok: true, observation: observation, attestation_error: nil }
  end

  def unsigned_ping!(error = :bad_signature, ok: true)
    @ping = { configured: true, ok: ok, observation: nil, attestation_error: error }
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

  # A part the switch turned on: the profile value and its activation.
  def turn_on_directly!(target, keys)
    target.with_lock do
      EmployeeAppSwitch::ProfileWriter.apply!(company: target, actor: org_admin, values: keys.index_with(true), reason: "Fixture")
    end
    activate_employee_app!(target, keys, actor: org_admin)
  end

  # A write around the switch: the profile row only, no activation.
  def write_profile_flags!(target, keys, effective_on: PayrollBusinessClock.today)
    attributes = ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(target)
    values = OperatingProfileCatalog.values_for(ClientOperatingProfile.new(attributes)).merge(keys.index_with(true))
    existing = target.client_operating_profiles.order(:effective_on).to_a
    existing.last&.update!(ends_on: effective_on - 1) if existing.any? && effective_on > existing.last.effective_on
    target.client_operating_profiles.create!(**OperatingProfileCatalog.attributes_from(values), effective_on: effective_on,
      version: (existing.map(&:version).max || 0) + 1)
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

    it "requires the fresh second factor and its own readiness checks in the service, whoever calls it" do
      update = ->(claims, changes = { "employee_portal_enabled" => true }) do
        EmployeeAppSwitch::Update.new(company: company, actor: org_admin, changes: changes, reason: "Direct call", session_claims: claims)
      end
      expect { EmployeeAppSwitch::Update.new(company: company, actor: org_admin, changes: {}, reason: "x") }
        .to raise_error(ArgumentError, /session_claims/)
      expect { EmployeeAppSwitch::Update.new(company: company, actor: org_admin, changes: {}, reason: "x", session_claims: nil, readiness: double) }
        .to raise_error(ArgumentError, /readiness/)

      expect { update.call(nil).call }.to raise_error(EmployeeAppSwitch::StepUpRequired)
      expect { update.call({ "fva" => [ 30, 30 ], "two_factor_enabled" => true }).call }.to raise_error(EmployeeAppSwitch::StepUpRequired)
      expect(stored["employee_portal_enabled"]).to be(false)

      @ping = { configured: false, ok: false, observation: nil, attestation_error: :not_configured }
      fresh = { "fva" => [ 1, 1 ], "two_factor_enabled" => true }
      expect { update.call(fresh).call }.to raise_error(EmployeeAppSwitch::NotReady)
      observe!
      expect(update.call(fresh).call).to include(turned_on: [ "employee_portal_enabled" ])

      # Turning off never needs a second factor.
      expect(update.call(nil, { "employee_portal_enabled" => false }).call).to include(turned_off: [ "employee_portal_enabled" ])
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
      "employee kill switch" => [ "The employee service refuses any database read without a company (RLS guard in raise mode)",
        -> { observe!(rls_kill_switch_bypass: true) } ],
      "rls_database" => [ "The database enforces company separation (row-level security on)",
        -> { allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(shadow_state) } ],
      "authorized_parties" => [ "Sign-in accepts only our own web addresses (CLERK_AUTHORIZED_PARTIES set)", -> { ENV["CLERK_AUTHORIZED_PARTIES"] = "" } ],
      "subdomain" => [ "The company's web address (subdomain) is set", -> { company.update_columns(subdomain_slug: nil) } ],
      "employee_service" => [ "The employee service is running and healthy",
        -> { unsigned_ping!(:unreachable, ok: false) } ],
      "unsigned employee service" => [ "The employee service is running and healthy", -> { unsigned_ping!(:bad_signature) } ],
      "stale employee service" => [ "The employee service is running and healthy", -> { unsigned_ping!(:stale) } ],
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
      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(shadow_state.merge(phase: "unknown", kill_switch_bypass: nil))
      @ping = { configured: false, ok: false, observation: nil, attestation_error: :not_configured }
      company.update_columns(subdomain_slug: nil)

      switch!({ "employee_portal_enabled" => false, "subdomain_enabled" => false }, reason: "Pause the pilot", recent: false)
      expect(response).to have_http_status(:ok), response.body
      expect(stored.values).to all(be(false))
      audit = AuditLog.find_by!(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: company.id)
      expect(audit.metadata).to include("reason" => "Pause the pilot", "turned_on" => [],
        "turned_off" => [ "employee_portal_enabled", "subdomain_enabled", "employee_portal.features.stubs", "employee_portal.features.tax_forms" ])
    end

    it "closes or sanitizes a legacy row stored with a now-locked flag on, so the off path never rolls back" do
      legacy = { "employee_portal" => { "features" => { "bank_requests" => true, "w4_requests" => true } }, "time_module_enabled" => true }
      turn_on_directly!(company, %w[employee_portal_enabled])
      current = company.client_operating_profiles.history_order.first
      current.update_columns(options: current.options.deep_merge(legacy))
      # Locked flags read as off whatever the row says.
      expect(CompanyFeatures.for(company).employee_portal_feature?(:bank_requests)).to be(false)
      # Saving the row with a locked flag on that it already had (here, closing its dates) is allowed;
      # turning one on is not.
      probe = ClientOperatingProfile.new(current.attributes.except("id", "created_at", "updated_at", "lock_version"))
      expect(probe).not_to be_valid
      expect(probe.errors.full_messages.to_sentence).to include("locked until its milestone")

      travel_to((PayrollBusinessClock.today + 1).in_time_zone(PayrollBusinessClock::TIME_ZONE).change(hour: 9)) do
        observe!
        switch!({ "employee_portal_enabled" => false }, reason: "Pause", recent: false)
        expect(response).to have_http_status(:ok), response.body
        expect(current.reload.ends_on).to eq(PayrollBusinessClock.today - 1)
        newest = ClientOperatingProfile.for_date(company.id, PayrollBusinessClock.today)
        expect(newest.id).not_to eq(current.id)
        expect(newest.employee_portal_enabled).to be(false)
        expect(CompanyFeatures::LOCKED_OFF.map { |key| newest.option_value(key) }).to all(be(false))
      end
    end

    it "lets the demo kill switch sanitize a legacy demo row in place" do
      turn_on_directly!(demo, %w[employee_portal_enabled])
      current = ClientOperatingProfile.for_date(demo.id, PayrollBusinessClock.today)
      current.update_columns(options: current.options.deep_merge("employee_portal" => { "features" => { "bank_requests" => true } }))

      post "#{path}/demo_stop", params: { reason: "Stop" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(current.reload.employee_portal_enabled).to be(false)
      expect(current.option_value("employee_portal.features.bank_requests")).to be(false)
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
      expect(EmployeeAppActivation.open.where(company_id: company.id)).to be_empty
    end

    it "clears a part that is on only in a future row, and counts it as something to change" do
      turn_on_directly!(company, %w[employee_portal_enabled])
      current = company.client_operating_profiles.history_order.first
      current.update!(ends_on: PayrollBusinessClock.today + 13)
      future = company.client_operating_profiles.create!(current.attributes.except("id", "created_at", "updated_at", "lock_version")
        .merge("effective_on" => PayrollBusinessClock.today + 14, "ends_on" => nil, "version" => current.version + 1,
          "options" => current.options.deep_merge("employee_portal" => { "features" => { "stubs" => true } })))
      expect(stored["employee_portal.features.stubs"]).to be(false)

      switch!({ "employee_portal_enabled" => false }, recent: false)
      expect(response).to have_http_status(:ok), response.body
      expect(future.reload.option_value("employee_portal.features.stubs")).to be(false)
      expect(future.employee_portal_enabled).to be(false)
      audit = AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: company.id).order(:id).last
      expect(audit.metadata["turned_off"]).to eq([ "employee_portal_enabled", "employee_portal.features.stubs" ])

      # Only a future row still had stubs on: that alone is something to turn off.
      future.update!(options: future.options.deep_merge("employee_portal" => { "features" => { "stubs" => true } }))
      switch!({ "employee_portal.features.stubs" => false }, recent: false)
      expect(response).to have_http_status(:ok), response.body
      expect(future.reload.option_value("employee_portal.features.stubs")).to be(false)

      switch!({ "employee_portal.features.stubs" => false }, recent: false)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to start_with("Nothing to change")
    end
  end

  describe "writes around the switch" do
    it "opens nothing from a direct profile write or a future row, and needs the switch's activation" do
      write_profile_flags!(company, %w[employee_portal_enabled subdomain_enabled employee_portal.features.stubs])
      write_profile_flags!(company, %w[employee_portal_enabled employee_portal.features.tax_forms], effective_on: PayrollBusinessClock.today + 3)

      expect(EmployeeAppSwitch.effective_values(company).values).to all(be(false))
      expect(CompanyFeatures.for(company, on: PayrollBusinessClock.today + 5).employee_portal_feature?(:tax_forms)).to be(false)
      expect(EmployeeAccountLink.portal_enabled_for?(company)).to be(false)
      get path, headers: auth
      on = response.parsed_body.dig("data", "switches").to_h { |row| [ row["key"], row["on"] ] }
      expect(on.values).to all(be(false))

      # The switch turns a written flag on only through its checks, and records that.
      switch!({ "employee_portal_enabled" => true })
      expect(response).to have_http_status(:ok), response.body
      activation = EmployeeAppActivation.open.find_by!(company_id: company.id, part: "employee_portal_enabled")
      expect(activation).to have_attributes(activated_by_id: org_admin.id)
      expect(activation.checks).to include({ "key" => "rls_database", "status" => "passed" })
      expect(EmployeeAppSwitch.effective_values(company)).to include("employee_portal_enabled" => true,
        "employee_portal.features.stubs" => false, "subdomain_enabled" => false)

      switch!({ "employee_portal_enabled" => false }, recent: false)
      expect(activation.reload.revoked_at).to be_present
      expect(activation.revoked_by_id).to eq(org_admin.id)
      expect(EmployeeAppSwitch.effective_values(company).values).to all(be(false))

      savepoint = ->(&block) { EmployeeAppActivation.transaction(requires_new: true, &block) }
      expect { savepoint.call { activation.update_columns(revoked_at: nil, revoked_by_id: nil, revoke_reason: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect { savepoint.call { activation.delete } }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "keeps bank changes and the M5/M6 switches off in storage and at read time" do
      profile = write_profile_flags!(company, %w[employee_portal_enabled])
      activate_employee_app!(company)
      options = profile.options.deep_merge("employee_portal" => { "features" => { "bank_requests" => true } })
      expect(profile.update(options: options)).to be(false)
      expect(profile.errors.full_messages.join).to include("locked until its milestone launches")
      expect(profile.update(options: profile.reload.options.merge("time_module_enabled" => true))).to be(false)

      profile.reload.update_columns(options: options.merge("time_module_enabled" => true).deep_merge(
        "employee_portal" => { "features" => { "pto" => true, "documents" => true, "w4_requests" => true } }))
      features = CompanyFeatures.for(company)
      expect(features.employee_portal_enabled?).to be(true)
      %i[bank_requests pto documents w4_requests].each { |feature| expect(features.employee_portal_feature?(feature)).to be(false) }
      expect(features.time_module_enabled?).to be(false)
    end
  end

  describe "the database row-level security check" do
    it "fails while the global kill switch bypasses, even with every table enforced, and when it can't be read" do
      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state)
        .and_return(database_state.merge(phase: "bypassed", enforced: false, kill_switch_bypass: true))
      expect(check("rls_database")).to include("status" => "failed")
      expect(response.parsed_body.dig("data", "readiness", "checks").find { |row| row["key"] == "rls_database" }["detail"])
        .to include("kill switch is bypassing")

      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state)
        .and_return(database_state.merge(phase: "unknown", enforced: false, kill_switch_bypass: nil))
      switch!({ "employee_portal_enabled" => true })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(failing_names).to eq([ "The database enforces company separation (row-level security on)" ])
    end

    it "reads the kill switch itself: enforced only with every table forced and the switch known off" do
      rows = RlsTables::PROTECTED_TABLES.map { |table| { "table" => table, "enabled" => true, "forced" => true, "policy" => true } }
      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_call_original
      allow(RlsDatabase).to receive(:table_status).and_return(rows)
      allow(EmployeeAppSwitch::Enforcement).to receive(:kill_switch_bypass).and_return(false)
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "enforced", enforced: true)

      allow(EmployeeAppSwitch::Enforcement).to receive(:kill_switch_bypass).and_return(true)
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "bypassed", enforced: false)
      allow(EmployeeAppSwitch::Enforcement).to receive(:kill_switch_bypass).and_return(nil)
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "unknown", enforced: false)

      allow(EmployeeAppSwitch::Enforcement).to receive(:kill_switch_bypass).and_return(false)
      allow(RlsDatabase).to receive(:table_status).and_return(rows.map { |row| row.merge("enabled" => false, "forced" => false) })
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "shadow", enforced: false)
      allow(RlsDatabase).to receive(:table_status).and_return(rows.each_with_index.map { |row, index| index.zero? ? row : row.merge("forced" => false) })
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "partial", enforced: false)
      allow(RlsDatabase).to receive(:table_status).and_raise(ActiveRecord::StatementInvalid, "boom")
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "unknown", enforced: false)
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
    let(:database_state) { shadow_state }
    let(:terms_status) { "draft" }

    def open_window!(company_ids: [ demo.id ], expires_on: PayrollBusinessClock.today + 7, user: owner, reason: "Owner approved rehearsal")
      put "#{path}/early_access", params: { expires_on: expires_on.iso8601, company_ids: company_ids, reason: reason },
        as: :json, headers: auth(user, target: demo)
    end

    it "waives only the database check, only for a named demo, only before expiry" do
      open_window!
      expect(response).to have_http_status(:ok), response.body
      window = EmployeeAppEarlyAccessWindow.sole
      expect(window).to have_attributes(company_ids: [ demo.id ], set_by_id: owner.id, approved_by: owner, reason: "Owner approved rehearsal")
      expect(AuditLog.find_by!(action: "employee_app_early_access#set").metadata)
        .to include("company_ids" => [ demo.id ], "approved_by_id" => owner.id)

      expect(check("rls_database", target: demo)).to include("status" => "waived")
      data = response.parsed_body["data"]
      expect(data.dig("readiness", "observed")).to include("rls_guard_mode" => "raise", "rls_runtime_role_verified" => true, "verified" => true)
      expect(data.dig("readiness", "database")).to include("phase" => "shadow", "enforced" => false)

      switch!({ "employee_portal_enabled" => true }, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(stored(demo)["employee_portal_enabled"]).to be(true)
      expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(true)

      # The full gate: an unguarded process (a worker, say) reads it as off,
      # and so does any database state but the intended shadow one.
      allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(false)
      expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(false)
      allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
      [ shadow_state.merge(phase: "partial"), shadow_state.merge(phase: "bypassed", kill_switch_bypass: true),
        shadow_state.merge(kill_switch_bypass: nil), shadow_state.merge(phase: "not_installed") ].each do |state|
        allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(state)
        EmployeeAppSwitch::Enforcement.reset_cache!
        expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(false), state.inspect
      end
      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state) { database_state }
      EmployeeAppSwitch::Enforcement.reset_cache!
      expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(true)

      audit = AuditLog.find_by!(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: demo.id)
      expect(audit.metadata).to include("early_access_window_id" => window.id)
      expect(audit.metadata["readiness"]).to include({ "key" => "rls_database", "status" => "waived" })
      expect(EmployeeAppActivation.open.find_by!(company_id: demo.id, part: "employee_portal_enabled").early_access_window_id).to eq(window.id)

      # A real company never gets the exception, and draft terms never count for it.
      EmployeeTermsVersion.create!(version: "terms-draft-2", status: "draft", terms_url: "https://example.com/terms",
        privacy_url: "https://example.com/privacy", published_at: Time.current)
      switch!({ "employee_portal_enabled" => true })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(failing_names).to contain_exactly("The database enforces company separation (row-level security on)",
        "Employee App Terms and Privacy Notice wording is approved by counsel")

      travel_to((PayrollBusinessClock.today + 8).in_time_zone(PayrollBusinessClock::TIME_ZONE).change(hour: 9)) do
        observe!
        # Expiry closes the demo's app at read time, before any sweep runs.
        expect(stored(demo)["employee_portal_enabled"]).to be(true)
        expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(false)
        expect(EmployeeAccountLink.portal_enabled_for?(demo)).to be(false)
        expect(check("rls_database", target: demo)).to include("status" => "failed")
        expect(check("rls_database", target: demo)["detail"]).to include("window ended on #{window.expires_on.iso8601}")
        switch!({ "subdomain_enabled" => true }, target: demo)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(failing_names).to eq([ "The database enforces company separation (row-level security on)" ])
      end
    end

    it "accepts only the intended shadow state, with the kill switch known off" do
      open_window!
      [ shadow_state.merge(kill_switch_bypass: true, phase: "bypassed"), shadow_state.merge(phase: "partial"),
        shadow_state.merge(phase: "unknown", kill_switch_bypass: nil), shadow_state.merge(phase: "not_installed") ].each do |state|
        allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(state)
        expect(check("rls_database", target: demo)).to include("status" => "failed"), state.inspect
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
      turn_on_directly!(other_demo, %w[employee_portal_enabled])
      expect(EmployeeAppSwitch.effective_values(other_demo)["employee_portal_enabled"]).to be(false)
    end

    it "is set only by the owner, for at most #{EmployeeAppEarlyAccessWindow::MAX_DAYS} days, for demo companies, with a fresh second factor" do
      open_window!(user: org_admin)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to include("Only the owner")

      open_window!(company_ids: [ company.id ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Real companies can't use early access")

      open_window!(expires_on: PayrollBusinessClock.today + 31)
      expect(response).to have_http_status(:unprocessable_entity)
      open_window!(expires_on: PayrollBusinessClock.today - 1)
      expect(response).to have_http_status(:unprocessable_entity)

      put "#{path}/early_access", params: { expires_on: (PayrollBusinessClock.today + 3).iso8601, company_ids: [ demo.id ], reason: "x" },
        as: :json, headers: auth(owner, recent: false, target: demo)
      expect(response).to have_http_status(:forbidden)
      expect(EmployeeAppEarlyAccessWindow.count).to eq(0)

      open_window!(expires_on: PayrollBusinessClock.today + 30)
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("data", "early_access", "can_set")).to be(true)
      get path, headers: auth(target: demo)
      expect(response.parsed_body.dig("data", "early_access", "can_set")).to be(false)
      expect(response.parsed_body.dig("data", "early_access", "windows", 0)).to include("approved_by" => "Olive Owner")
    end

    it "extends only with a new owner approval and reason" do
      open_window!(expires_on: PayrollBusinessClock.today + 3)
      first = EmployeeAppEarlyAccessWindow.sole

      open_window!(expires_on: PayrollBusinessClock.today + 20, reason: " ")
      expect(response).to have_http_status(:unprocessable_entity)
      open_window!(expires_on: PayrollBusinessClock.today + 20, user: org_admin, reason: "Longer rehearsal")
      expect(response).to have_http_status(:forbidden)
      expect(first.reload.ended_at).to be_nil

      open_window!(expires_on: PayrollBusinessClock.today + 20, reason: "Owner extended the rehearsal")
      expect(response).to have_http_status(:ok), response.body
      expect(first.reload).to have_attributes(end_reason: "Replaced by a new early-access window")
      current = EmployeeAppEarlyAccessWindow.current_for(organization.id)
      expect(current).to have_attributes(expires_on: PayrollBusinessClock.today + 20, set_by_id: owner.id, reason: "Owner extended the rehearsal")
      expect(AuditLog.where(action: "employee_app_early_access#set").order(:id).last.metadata)
        .to include("replaced_window_id" => first.id, "extension" => true)
    end

    it "retires for good once the database enforces RLS; a return to shadow mode doesn't revive it" do
      open_window!
      turn_on_directly!(demo, %w[employee_portal_enabled])
      window = EmployeeAppEarlyAccessWindow.sole
      expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(true)

      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(enforced_state)
      EmployeeAppSwitch::Enforcement.reset_cache!
      expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(true)
      expect(window.reload.retired_at).to be_present
      expect(window.status).to eq("retired")

      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(shadow_state)
      EmployeeAppSwitch::Enforcement.reset_cache!
      expect(EmployeeAppEarlyAccessWindow.current_for(organization.id)).to be_nil
      expect(EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"]).to be(false)
      expect(check("rls_database", target: demo)).to include("status" => "failed")

      savepoint = ->(&block) { EmployeeAppEarlyAccessWindow.transaction(requires_new: true, &block) }
      expect { savepoint.call { window.update_columns(retired_at: nil) } }.to raise_error(ActiveRecord::StatementInvalid)

      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(enforced_state)
      open_window!
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("already enforces row-level security")
    end

    it "pauses through the enforcement window within the cache delay, resumes once enforced, and reopens after a rollback " \
       "only with a new owner window" do
      open_window!
      switch!({ "employee_portal_enabled" => true }, target: demo)
      expect(response).to have_http_status(:ok), response.body
      first = EmployeeAppEarlyAccessWindow.sole

      # Each process caches the database state, so a transition shows up only
      # once the cached read is CACHE_SECONDS old. Move the monotonic clock
      # instead of resetting the cache.
      offset = 0.0
      allow(Process).to receive(:clock_gettime).and_wrap_original do |original, id, *args|
        id == Process::CLOCK_MONOTONIC ? original.call(id, *args) + offset : original.call(id, *args)
      end
      age_cache = -> { offset += EmployeeAppSwitch::Enforcement::CACHE_SECONDS }
      app_open = -> { EmployeeAppSwitch.effective_values(demo)["employee_portal_enabled"] }
      EmployeeAppSwitch::Enforcement.reset_cache!
      expect(app_open.call).to be(true)

      # Mid-window (partial) and under the kill switch the waiver closes the
      # app at read time once the shadow read ages out, but the window and
      # the stored switches survive.
      [ shadow_state.merge(phase: "partial"), shadow_state.merge(phase: "bypassed", kill_switch_bypass: true) ].each do |state|
        allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(state)
        expect(app_open.call).to be(true), "still the cached shadow read: #{state.inspect}"
        age_cache.call
        CloseExpiredDemoEarlyAccessJob.perform_now
        expect(app_open.call).to be(false), state.inspect
        expect(stored(demo)["employee_portal_enabled"]).to be(true), state.inspect
        expect(first.reload.status).to eq("in_effect")

        allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(shadow_state)
        age_cache.call
        expect(app_open.call).to be(true), "back in shadow after #{state.inspect}"
      end

      # Verified enforcement needs no waiver: access resumes and the window retires.
      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(enforced_state)
      age_cache.call
      expect(app_open.call).to be(true)
      expect(first.reload.status).to eq("retired")

      # Rolled back to shadow: the verified read keeps the app open until it
      # ages out, then the sweep closes the demo, and a new owner window plus
      # the switch admin turning the app back on restores it.
      allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(shadow_state)
      expect(app_open.call).to be(true)
      age_cache.call
      expect(app_open.call).to be(false)
      CloseExpiredDemoEarlyAccessJob.perform_now
      expect(stored(demo)["employee_portal_enabled"]).to be(false)

      open_window!(reason: "Owner reopened after the RLS rollback")
      expect(response).to have_http_status(:ok), response.body
      expect(EmployeeAppEarlyAccessWindow.current_for(organization.id)).to have_attributes(set_by_id: owner.id)
      expect(first.reload.status).to eq("retired")
      switch!({ "employee_portal_enabled" => true }, reason: "Reopen after the RLS rollback", target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(stored(demo)["employee_portal_enabled"]).to be(true)
      expect(app_open.call).to be(true)
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
      expect { savepoint.call { window.update_columns(retired_at: Time.current) } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { savepoint.call { window.delete } }.to raise_error(ActiveRecord::StatementInvalid)
      expect(AuditLog.find_by!(action: "employee_app_early_access#ended").metadata).to include("reason" => "Rehearsal finished")
    end
  end

  describe "when demo early access stops applying" do
    let(:database_state) { shadow_state }

    def open_window_for(target, expires_on:)
      EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ target.id ], expires_on: expires_on,
        reason: "Owner approved", set_by: owner)
    end

    it "closes a demo's stored switches after the expiry date, revokes them, and never touches a real company" do
      open_window_for(demo, expires_on: PayrollBusinessClock.today + 2)
      turn_on_directly!(demo, %w[employee_portal_enabled employee_portal.features.stubs])
      turn_on_directly!(company, %w[employee_portal_enabled])

      CloseExpiredDemoEarlyAccessJob.perform_now
      expect(stored(demo)["employee_portal_enabled"]).to be(true)

      travel_to((PayrollBusinessClock.today + 3).in_time_zone(PayrollBusinessClock::TIME_ZONE).change(hour: 0, min: 5)) do
        CloseExpiredDemoEarlyAccessJob.perform_now
        expect(stored(demo).values).to all(be(false))
        expect(EmployeeAppActivation.open.where(company_id: demo.id)).to be_empty
        expect(stored(company)["employee_portal_enabled"]).to be(true)
        audit = AuditLog.find_by!(action: EmployeeAppSwitch::DemoExpiry::ACTION, company_id: demo.id)
        expect(audit.metadata).to include("turned_off" => [ "employee_portal_enabled", "employee_portal.features.stubs" ])
        expect(audit.actor_type).to eq("system_job")
      end
    end

    it "closes right away when an admin ends the window, and retires windows once the database enforces RLS" do
      window = open_window_for(demo, expires_on: PayrollBusinessClock.today + 5)
      turn_on_directly!(demo, %w[employee_portal_enabled])
      expect(EmployeeAppSwitch::DemoExpiry.call(database_state: -> { { enforced: true } })).to eq([])
      expect(window.reload.retired_at).to be_present
      expect(AuditLog.find_by!(action: EmployeeAppSwitch::Enforcement::RETIRED_ACTION).record_id).to eq(window.id)

      other = open_window_for(demo, expires_on: PayrollBusinessClock.today + 5)
      delete "#{path}/early_access", params: { reason: "Guard failed" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(other.reload.ended_at).to be_present
      expect(stored(demo)["employee_portal_enabled"]).to be(false)
    end
  end

  describe "the demo kill switch" do
    let(:database_state) { shadow_state }

    it "turns every demo's employee app off, ends early access and support views, keeps data, and leaves real companies alone" do
      EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ demo.id ], expires_on: PayrollBusinessClock.today + 5,
        reason: "Owner approved", set_by: owner)
      turn_on_directly!(demo, %w[employee_portal_enabled subdomain_enabled employee_portal.features.stubs])
      turn_on_directly!(company, %w[employee_portal_enabled])
      staff = create(:user, company: company, organization: organization, role: :super_admin, clerk_id: "user_support")
      grant = ViewAsGrant.create!(company: demo, staff_user: staff, target_employee: create(:employee, company: demo), reason: "Check a view",
        token_digest: "d" * 64, expires_at: 20.minutes.from_now)
      employees_before = demo.employees.count

      post "#{path}/demo_stop", params: { reason: "Leak suspected" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body

      expect(stored(demo).values).to all(be(false))
      expect(EmployeeAppActivation.open.where(company_id: demo.id)).to be_empty
      expect(stored(company)["employee_portal_enabled"]).to be(true)
      expect(EmployeeAppEarlyAccessWindow.sole.ended_at).to be_present
      expect(EmployeeAppEarlyAccessWindow.sole.end_reason).to eq("Demo employee access stopped: Leak suspected")
      expect(grant.reload.ended_at).to be_present
      expect(demo.employees.count).to eq(employees_before)
      expect(response.parsed_body.dig("stopped", "companies")).to contain_exactly(include("company_id" => demo.id,
        "turned_off" => [ "employee_portal_enabled", "subdomain_enabled", "employee_portal.features.stubs" ], "support_views_ended" => 1))
      expect(AuditLog.where(action: "employee_app_switch#demo_stopped", organization_id: organization.id).count).to eq(1)
      expect(AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: demo.id).last.metadata)
        .to include("demo_stop" => true, "reason" => "Leak suspected", "confirmed" => include("support_views_ended" => 1),
          "requested" => include("clerk_session_revocations" => 0))
      expect(AuditLog.where(action: "view_as#ended", company_id: demo.id).count).to eq(1)
    end

    it "turns off a demo part that is on only in a future row" do
      turn_on_directly!(demo, %w[employee_portal_enabled])
      current = demo.client_operating_profiles.history_order.first
      current.update!(ends_on: PayrollBusinessClock.today + 6)
      future = demo.client_operating_profiles.create!(current.attributes.except("id", "created_at", "updated_at", "lock_version")
        .merge("effective_on" => PayrollBusinessClock.today + 7, "ends_on" => nil, "version" => current.version + 1,
          "options" => current.options.deep_merge("subdomain_enabled" => true)))
      EmployeeAppSwitch::ProfileWriter.apply!(company: demo, actor: org_admin, values: { "employee_portal_enabled" => false }, reason: "Fixture")
      future.update!(employee_portal_enabled: true)

      post "#{path}/demo_stop", params: { reason: "Stop" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(future.reload.employee_portal_enabled).to be(false)
      expect(future.option_value("subdomain_enabled")).to be(false)
    end

    it "records Clerk revocations durably, retries them until confirmed, and a repeat stop queues no duplicates" do
      employee = create(:employee, company: demo)
      login = create(:user, company: demo, organization: organization, role: :portal_employee, clerk_id: "user_demo_employee",
        email: "demo.worker@demo-mail.example")
      as_staff_in(demo) do
        EmployeeAccountLink.create!(company: demo, employee: employee, user: login, status: "active", activated_at: Time.current)
      end
      turn_on_directly!(demo, %w[employee_portal_enabled])
      clerk = instance_double(ClerkInvitationService)
      allow(ClerkInvitationService).to receive(:new).and_return(clerk)
      allow(clerk).to receive(:revoke_user_sessions).and_return({ success: false, error: "Clerk down" }, { success: true })

      expect do
        post "#{path}/demo_stop", params: { reason: "Leak" }, as: :json, headers: auth(recent: false, target: demo)
      end.to have_enqueued_job(RevokeEmployeeAppClerkJob).exactly(:once)
      revocation = EmployeeAppClerkRevocation.sole
      expect(revocation).to have_attributes(kind: "sessions", target: login.id.to_s, source: "demo_stop", confirmed_at: nil)

      expect do
        post "#{path}/demo_stop", params: { reason: "Again" }, as: :json, headers: auth(recent: false, target: demo)
      end.not_to have_enqueued_job(RevokeEmployeeAppClerkJob)
      expect(EmployeeAppClerkRevocation.count).to eq(1)
      expect(AuditLog.where(action: EmployeeAppSwitch::AUDIT_ACTION, company_id: demo.id).order(:id).last.metadata["requested"])
        .to include("clerk_session_revocations" => 0, "already_pending" => 1)

      # Only the job the stop queued (the row's owner) acts on it.
      expect(revocation.reload.job_id).to eq(enqueued_jobs.sole.fetch("job_id"))
      expect(RevokeEmployeeAppClerkJob.perform_now(revocation.id)).to be_nil
      expect(revocation.reload.attempts).to eq(0)
      owner = -> { RevokeEmployeeAppClerkJob.new(revocation.id).tap { |job| job.job_id = revocation.job_id } }
      expect { owner.call.perform_now }.not_to raise_error # retry_on reschedules
      expect(revocation.reload).to have_attributes(attempts: 1, last_error: "Clerk down", confirmed_at: nil)
      owner.call.perform_now
      expect(revocation.reload.confirmed_at).to be_present
      expect(AuditLog.where(action: RevokeEmployeeAppClerkJob::CONFIRMED_ACTION, record_id: revocation.id).count).to eq(1)
    end

    it "recovers revocations left without a job: a repeat stop queues pending rows that were never queued" do
      turn_on_directly!(demo, %w[employee_portal_enabled])
      # A stop whose commit landed but whose enqueue failed (or crashed).
      allow(RevokeEmployeeAppClerkJob.queue_adapter).to receive(:enqueue).and_raise(ActiveJob::EnqueueError)
      orphan = TenantScope.as_system(reason: "spec") do
        EmployeeAppClerkRevocation.request!(kind: "invitation", target: "inv_orphan", organization: organization, company: demo,
          source: EmployeeAppClerkRevocation::SOURCE_DEMO_STOP, requested_by: org_admin)
      end
      post "#{path}/demo_stop", params: { reason: "Leak" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(orphan.reload.enqueued_at).to be_nil

      allow(RevokeEmployeeAppClerkJob.queue_adapter).to receive(:enqueue).and_call_original
      expect do
        post "#{path}/demo_stop", params: { reason: "Again" }, as: :json, headers: auth(recent: false, target: demo)
      end.to have_enqueued_job(RevokeEmployeeAppClerkJob).with(orphan.id).exactly(:once)
      expect(orphan.reload.enqueued_at).to be_present
      expect(EmployeeAppClerkRevocation.count).to eq(1)

      # Already queued: a third stop doesn't queue it again (the sweep covers a lost job).
      expect do
        post "#{path}/demo_stop", params: { reason: "Third" }, as: :json, headers: auth(recent: false, target: demo)
      end.not_to have_enqueued_job(RevokeEmployeeAppClerkJob)
    end

    it "revokes pending demo invitations and their Clerk sign-up invitations" do
      employee = create(:employee, company: demo)
      # In shadow mode a demo's app is open only under an early-access window.
      EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ demo.id ], expires_on: PayrollBusinessClock.today + 5,
        reason: "Owner approved", set_by: owner)
      turn_on_directly!(demo, %w[employee_portal_enabled])
      invited = invite!(employee, actor: org_admin, delivery: "code").link
      pending = create(:user, company: demo, organization: organization, role: :portal_employee, invitation_status: "pending",
        clerk_id: nil, clerk_invitation_id: "inv_demo_pending", email: "demo.pending@demo-mail.example")
      invited.update_columns(user_id: pending.id)
      expect(invited.reload).to be_invited

      post "#{path}/demo_stop", params: { reason: "Rehearsal over" }, as: :json, headers: auth(recent: false, target: demo)
      expect(response).to have_http_status(:ok), response.body
      expect(invited.reload).to have_attributes(status: "revoked", revoked_reason: "Demo employee access stopped: Rehearsal over")
      expect(response.parsed_body.dig("stopped", "companies", 0, "invitations_revoked")).to eq(1)
      expect(EmployeeAppClerkRevocation.find_by!(kind: "invitation")).to have_attributes(target: "inv_demo_pending")
    end

    it "is for organization admins only" do
      admin = create(:user, company: company, organization: organization, role: :admin, clerk_id: "user_plain_admin")
      post "#{path}/demo_stop", params: { reason: "Stop" }, as: :json, headers: auth(admin, target: demo)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "invitation issuance during a stop" do
    it "issues a demo invitation only under the company lock with the app still on" do
      employee = create(:employee, company: demo)
      turn_on_directly!(demo, %w[employee_portal_enabled])
      locked = []
      allow(EmployeeLinks).to receive(:lock_for_issuance!).and_wrap_original { |original, company| locked << company.id; original.call(company) }
      invite!(employee, actor: org_admin, delivery: "code")
      expect(locked).to eq([ demo.id ])

      EmployeeAppSwitch::DemoStop.call(organization: organization, actor: org_admin, reason: "Stop")
      other = create(:employee, company: demo)
      expect { invite!(other, actor: org_admin, delivery: "code") }.to raise_error(EmployeeLinks::Error, /isn't turned on/)
    end
  end
end
