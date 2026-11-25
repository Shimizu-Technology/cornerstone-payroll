# frozen_string_literal: true

require "rails_helper"

# M4-11: Enumeration checks across sign-up (activation), claim, reactivate, and
# employee portal error paths. Every failure kind in a path must return the
# exact same HTTP status, response body, and normalized response headers.
RSpec.describe "Employee enumeration resistance", type: :request do
  include EmployeeLinkHelpers

  # Per-request headers that naturally vary between HTTP responses.
  EPHEMERAL_HEADERS = %w[x-request-id x-runtime date].freeze

  let(:organization) { create(:organization) }
  let(:alpha) { create(:company, organization: organization, name: "Alpha Grill", subdomain_slug: "alpha-enum") }
  let(:bravo) { create(:company, organization: organization, name: "Bravo Cafe", subdomain_slug: "bravo-enum") }
  let(:alpha_origin) { "https://alpha-enum.shimizu-technology.com" }
  let(:bravo_origin) { "https://bravo-enum.shimizu-technology.com" }
  let(:staff) { create(:user, company: alpha, organization: organization, role: :admin, clerk_id: "user_enum_staff") }

  let(:employee) do
    create(:employee, company: alpha, first_name: "Riley", last_name: "Santos", email: "riley.enum@example.net",
      date_of_birth: Date.new(1990, 4, 12))
  end

  around do |example|
    saved = ENV.to_h.slice("RLS_CONTEXT_GUARD_MODE", "AUTH_ENABLED", "REQUIRE_MFA", DemoOutbound::ENV_KEY)
    ENV.update(
      "RLS_CONTEXT_GUARD_MODE" => "raise",
      "AUTH_ENABLED" => "true",
      "REQUIRE_MFA" => "true",
      DemoOutbound::ENV_KEY => "allowed.demo@demo-enum.example"
    )
    example.run
  ensure
    %w[RLS_CONTEXT_GUARD_MODE AUTH_ENABLED REQUIRE_MFA].push(DemoOutbound::ENV_KEY).each { |key| ENV[key] = saved[key] }
  end

  before do
    @alpha_profile = enable_features!(alpha)
    @bravo_profile = enable_features!(bravo)
  end

  def enable_features!(company)
    profile = company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service", hours_source: "manual",
      employee_portal_enabled: true,
      options: {
        "subdomain_enabled" => true,
        "employee_portal" => { "features" => { "stubs" => true, "tax_forms" => true, "profile_requests" => true, "delivery_consent" => true } }
      }
    )
    # A profile flag alone opens nothing (M4-9d): turn it on the way the switch does.
    activate_employee_app!(company)
    TenantSubdomainRegistry.invalidate!
    profile
  end

  def response_signature
    headers = response.headers.to_h.transform_keys(&:downcase).reject { |k, _| EPHEMERAL_HEADERS.include?(k) }.sort.to_h
    { status: response.status, body: response.body, headers: headers }
  end

  def expect_identical_signatures!(labelled_signatures, expected_status:)
    baseline_label, baseline = labelled_signatures.first
    expect(baseline[:status]).to eq(expected_status), "#{baseline_label} had status #{baseline[:status]} (expected #{expected_status})"

    labelled_signatures.each do |label, sig|
      expect(sig[:status]).to eq(baseline[:status]), "Status mismatch between #{baseline_label} (#{baseline[:status]}) and #{label} (#{sig[:status]})"
      expect(sig[:body]).to eq(baseline[:body]), "Body mismatch between #{baseline_label} and #{label}:\n  #{baseline[:body]}\n  vs\n  #{sig[:body]}"
      expect(sig[:headers]).to eq(baseline[:headers]), "Header mismatch between #{baseline_label} and #{label}:\n  #{baseline[:headers]}\n  vs\n  #{sig[:headers]}"
    end
  end

  describe "POST /api/v1/employee/activation" do
    it "returns identical status, body, and headers for every failure kind" do
      valid_invite = invite!(employee, actor: staff)
      code_emp = create(:employee, company: alpha, first_name: "Avery", last_name: "Cruz", date_of_birth: Date.new(1988, 1, 2))
      code_invite = invite!(code_emp, actor: staff, delivery: "code")

      expired_emp = create(:employee, company: alpha, date_of_birth: Date.new(1986, 5, 6))
      expired_invite = invite!(expired_emp, actor: staff, delivery: "code")
      expired_invite.link.update_columns(invite_expires_at: 1.minute.ago)

      revoked_emp = create(:employee, company: alpha, date_of_birth: Date.new(1987, 5, 6))
      revoked_invite = invite!(revoked_emp, actor: staff, delivery: "code")
      revoked_invite.link.update_columns(status: "revoked", revoked_at: 1.minute.ago)

      locked_emp = create(:employee, company: alpha, date_of_birth: Date.new(1989, 5, 6))
      locked_invite = invite!(locked_emp, actor: staff, delivery: "code")
      locked_invite.link.update_columns(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)

      inactive_emp = create(:employee, company: alpha, date_of_birth: Date.new(1984, 5, 6))
      inactive_invite = invite!(inactive_emp, actor: staff, delivery: "code")
      inactive_emp.update_columns(status: "inactive")

      reset_emp = create(:employee, company: alpha, date_of_birth: Date.new(1983, 5, 6))
      reset_invite = invite!(reset_emp, actor: staff, delivery: "code")
      reset_invite.link.update_columns(sign_up_reset_requested_at: Time.current, sign_up_reset_reason: "Pending")

      off_company = create(:company, organization: organization)
      off_profile = enable_features!(off_company)
      off_emp = create(:employee, company: off_company, date_of_birth: Date.new(1982, 5, 6))
      off_invite = invite!(off_emp, actor: create(:user, company: off_company, organization: organization, role: :admin), delivery: "code")
      off_profile.update_columns(employee_portal_enabled: false)

      cases = {
        unknown_token: activation_params(employee, token: "not-a-real-token"),
        unknown_code: activation_params(employee, code: "ACDEFGHJKM"),
        wrong_dob: activation_params(employee, token: valid_invite.token, date_of_birth: "1990-04-13"),
        wrong_ssn4: activation_params(employee, token: valid_invite.token, ssn_last4: "0000"),
        malformed_dob: activation_params(employee, token: valid_invite.token, date_of_birth: "04/12/1990"),
        malformed_ssn4: activation_params(employee, token: valid_invite.token, ssn_last4: "abcd"),
        malformed_email: activation_params(employee, token: valid_invite.token, email: "not-an-email"),
        wrong_dob_on_code: activation_params(code_emp, code: code_invite.code, date_of_birth: "1988-01-03"),
        expired_invite: activation_params(expired_emp, code: expired_invite.code),
        revoked_invite: activation_params(revoked_emp, code: revoked_invite.code),
        locked_invite: activation_params(locked_emp, code: locked_invite.code),
        inactive_employee: activation_params(inactive_emp, code: inactive_invite.code),
        reset_pending: activation_params(reset_emp, code: reset_invite.code),
        portal_off: activation_params(off_emp, code: off_invite.code)
      }

      results = cases.map do |label, params|
        post_activation(params)
        [ label, response_signature ]
      end

      expect_identical_signatures!(results, expected_status: 422)
      expect(results.first.last[:headers]["cache-control"]).to eq("no-store")
    end

    it "returns identical status, body, and headers for every sign-in-redirect kind" do
      invite = invite!(employee, actor: staff)
      create(:user, company: alpha, organization: organization, role: :client, email: "taken.enum@example.net")

      routed_client = create(:user, company: alpha, organization: organization, role: :client, name: "Morgan Lee",
        email: "morgan.lee@example.net", clerk_id: "user_enum_routed")
      routed_emp = create(:employee, company: alpha, first_name: "Morgan", last_name: "Lee", email: "morgan.lee@example.net",
        date_of_birth: Date.new(1993, 7, 1))
      routed_invite = invite!(routed_emp, actor: staff, confirm_same_person_email: true)
      expect(routed_invite.link.claim_user_id).to eq(routed_client.id)

      results = []
      post_activation(activation_params(employee, token: invite.token, email: "taken.enum@example.net"))
      results << [ :existing_payroll_login, response_signature ]

      post_activation(activation_params(employee, token: invite.token, email: "noreply@example.net"))
      results << [ :structural_placeholder, response_signature ]

      post_activation(activation_params(routed_emp, token: routed_invite.token, email: "fresh.unused@example.net"))
      results << [ :routed_to_claim_user, response_signature ]

      allow(clerk).to receive(:create_invitation).and_return(success: false, error: "Email address is taken.", status_code: 422)
      post_activation(activation_params(employee, token: invite.token, email: "clerk.taken@example.net"))
      results << [ :clerk_existing_email, response_signature ]

      expect_identical_signatures!(results, expected_status: 200)
      expect(JSON.parse(results.first.last[:body])).to include("next" => "sign_in", "sign_up_url" => nil)
    end
  end

  describe "POST /api/v1/employee/links/claim" do
    it "returns identical status, body, and headers for every authenticated failure kind" do
      claimant = create(:user, company: alpha, organization: organization, role: :portal_employee,
        name: "Riley Santos", email: "riley.claim@example.net", clerk_id: "user_enum_claimant")
      stranger = create(:user, company: alpha, organization: organization, role: :portal_employee,
        name: "Different Person", email: "diff.claim@example.net", clerk_id: "user_enum_stranger")
      demo = create_demo_company(organization: organization)
      demo_user = create(:user, company: demo, organization: organization, role: :client,
        name: "Riley Santos", email: "allowed.demo@demo-enum.example", clerk_id: "user_enum_demo")
      CompanyAssignment.create!(user: demo_user, company: demo)

      valid_invite = invite!(employee, actor: staff, delivery: "code")

      expired_emp = create(:employee, company: alpha, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
      expired_invite = invite!(expired_emp, actor: staff, delivery: "code")
      expired_invite.link.update_columns(invite_expires_at: 1.minute.ago)

      revoked_emp = create(:employee, company: alpha, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
      revoked_invite = invite!(revoked_emp, actor: staff, delivery: "code")
      revoked_invite.link.update_columns(status: "revoked", revoked_at: 1.minute.ago)

      locked_emp = create(:employee, company: alpha, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
      locked_invite = invite!(locked_emp, actor: staff, delivery: "code")
      locked_invite.link.update_columns(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)

      bravo_emp = create(:employee, company: bravo, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
      bravo_invite = invite!(bravo_emp, actor: create(:user, company: bravo, organization: organization, role: :admin), delivery: "code")

      other_org_co = create(:company)
      enable_features!(other_org_co)
      other_org_emp = create(:employee, company: other_org_co, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
      other_org_invite = invite!(other_org_emp, actor: create(:user, company: other_org_co, role: :admin), delivery: "code")

      claim_call = lambda do |user, params, origin: alpha_origin|
        claims = user.portal_employee? ? { fva: [ 0, -1 ] } : { fva: [ 0, 0 ], two_factor_enabled: true }
        post "/api/v1/employee/links/claim", params: params.except(:email).to_json,
          headers: bearer(user.clerk_id, azp: origin, **claims).merge("CONTENT_TYPE" => "application/json")
        response_signature
      end

      results = [
        [ :unknown_code, claim_call.call(claimant, activation_params(employee, code: "ACDEFGHJKM")) ],
        [ :wrong_dob, claim_call.call(claimant, activation_params(employee, code: valid_invite.code, date_of_birth: "1990-04-13")) ],
        [ :wrong_ssn4, claim_call.call(claimant, activation_params(employee, code: valid_invite.code, ssn_last4: "0000")) ],
        [ :expired_invite, claim_call.call(claimant, activation_params(expired_emp, code: expired_invite.code)) ],
        [ :revoked_invite, claim_call.call(claimant, activation_params(revoked_emp, code: revoked_invite.code)) ],
        [ :locked_invite, claim_call.call(claimant, activation_params(locked_emp, code: locked_invite.code)) ],
        [ :wrong_subdomain, claim_call.call(claimant, activation_params(bravo_emp, code: bravo_invite.code), origin: alpha_origin) ],
        [ :other_organization, claim_call.call(claimant, activation_params(other_org_emp, code: other_org_invite.code), origin: EmployeeLinkHelpers::PAYROLL_ORIGIN) ],
        [ :name_mismatch, claim_call.call(stranger, activation_params(employee, code: valid_invite.code)) ],
        [ :demo_identity, claim_call.call(demo_user, activation_params(employee, code: valid_invite.code), origin: EmployeeLinkHelpers::PAYROLL_ORIGIN) ]
      ]

      expect_identical_signatures!(results, expected_status: 404)
      expect(JSON.parse(results.first.last[:body])).to eq(
        "error" => Api::V1::EmployeePortal::AccountController::CLAIM_FAILED, "code" => "claim_failed"
      )
      expect(results.first.last[:headers]["cache-control"]).to eq("no-store")
    end
  end

  describe "POST /api/v1/employee/links/reactivate" do
    it "returns identical status, body, and headers for every authenticated failure kind" do
      closed_at = 20.minutes.ago
      rehire_user = create(:user, company: alpha, organization: organization, role: :portal_employee,
        name: "Riley Santos", email: "riley.rehire@example.net", clerk_id: "user_enum_rehire",
        active: false, deactivated_at: closed_at, deactivation_reason: "last_employee_link_closed", invitation_status: "accepted")
      EmployeeAccountLink.create!(user: rehire_user, company: alpha, employee: employee, status: "revoked", revoked_at: closed_at)
      clerk_session!("sess_user_enum_rehire", user_id: "user_enum_rehire", created_at: 10.minutes.ago)

      active_user = create(:user, company: alpha, organization: organization, role: :portal_employee,
        name: "Riley Santos", email: "riley.active@example.net", clerk_id: "user_enum_active", invitation_status: "accepted")

      invite = invite!(employee, actor: staff, delivery: "code")
      stranger_emp = create(:employee, company: alpha, first_name: "Sam", last_name: "Lim", date_of_birth: Date.new(1987, 3, 4))
      stranger_invite = invite!(stranger_emp, actor: staff, delivery: "code")

      bravo_emp = create(:employee, company: bravo, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
      bravo_invite = invite!(bravo_emp, actor: create(:user, company: bravo, organization: organization, role: :admin), delivery: "code")

      reactivate_call = lambda do |user, params, origin: alpha_origin|
        post "/api/v1/employee/links/reactivate", params: params.except(:email).to_json,
          headers: bearer(user.clerk_id, azp: origin, fva: [ 0, -1 ]).merge("CONTENT_TYPE" => "application/json")
        response_signature
      end

      results = [
        [ :unknown_code, reactivate_call.call(rehire_user, activation_params(employee, code: "ACDEFGHJKM")) ],
        [ :wrong_dob, reactivate_call.call(rehire_user, activation_params(employee, code: invite.code, date_of_birth: "1990-04-13")) ],
        [ :wrong_ssn4, reactivate_call.call(rehire_user, activation_params(employee, code: invite.code, ssn_last4: "0000")) ],
        [ :stranger_employee, reactivate_call.call(rehire_user, activation_params(stranger_emp, code: stranger_invite.code)) ],
        [ :wrong_subdomain, reactivate_call.call(rehire_user, activation_params(bravo_emp, code: bravo_invite.code), origin: alpha_origin) ],
        [ :active_user, reactivate_call.call(active_user, activation_params(employee, code: invite.code)) ]
      ]

      expect_identical_signatures!(results, expected_status: 404)
      expect(JSON.parse(results.first.last[:body])).to eq(
        "error" => Api::V1::EmployeePortal::AccountController::CLAIM_FAILED, "code" => "claim_failed"
      )
      expect(results.first.last[:headers]["cache-control"]).to eq("no-store")
    end
  end

  describe "Employee portal 404 error paths" do
    it "returns identical 404 status, empty body, and headers across auth, link, feature, and record failures" do
      worker = create(:user, company: alpha, organization: organization, role: :portal_employee, clerk_id: "user_enum_w1")
      colleague = create(:user, company: alpha, organization: organization, role: :portal_employee, clerk_id: "user_enum_w2")
      active_link = EmployeeAccountLink.create!(user: worker, company: alpha, employee: employee, status: "active", activated_at: 1.day.ago)
      colleague_emp = create(:employee, company: alpha)
      colleague_link = EmployeeAccountLink.create!(user: colleague, company: alpha, employee: colleague_emp, status: "active", activated_at: 1.day.ago)
      # Each restricted link starts as an ordinary active link to its own employee.
      revoked_link, locked_link, expired_link = Array.new(3) do
        EmployeeAccountLink.create!(user: worker, company: alpha, employee: create(:employee, company: alpha), status: "active",
          activated_at: 1.day.ago)
      end

      # Every link's own employee has a posted document, so each probe asks for
      # a record that link could read but for the restriction under test.
      posted_form = lambda do |emp|
        EmployeeDocument.create!(company: alpha, employee: emp, tax_year: 2026, revision: 1, status: "posted",
          storage_key: "employee_documents/enum/w2-#{emp.id}.pdf", sha256: "a" * 64, posted_at: Time.current)
      end
      own_form = posted_form.call(employee)
      colleague_form = posted_form.call(colleague_emp)
      revoked_form, locked_form, expired_form = [ revoked_link, locked_link, expired_link ].map { |link| posted_form.call(link.employee) }

      form_path = ->(form) { "/api/v1/employee/tax_forms/#{form.id}" }
      link_auth = ->(user, link, azp: alpha_origin) { bearer(user.clerk_id, azp: azp).merge("X-Employee-Link-Id" => link.id.to_s) }
      probe = lambda do |path, headers|
        get path, headers: headers
        response_signature
      end

      # Access works before any restriction is applied.
      [
        [ worker, active_link, own_form ], [ colleague, colleague_link, colleague_form ], [ worker, revoked_link, revoked_form ],
        [ worker, locked_link, locked_form ], [ worker, expired_link, expired_form ]
      ].each do |user, link, form|
        expect(probe.call(form_path.call(form), link_auth.call(user, link))[:status]).to eq(200),
          "link #{link.id} could not read its own employee's document before the restriction"
      end

      revoked_link.update_columns(status: "revoked", revoked_at: 1.minute.ago)
      locked_link.update_columns(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)
      expired_link.update_columns(status: "former", former_at: 2.days.ago, former_access_until: 1.day.ago)

      results = [
        [ :missing_auth, probe.call(form_path.call(own_form), {}) ],
        [ :invalid_token, probe.call(form_path.call(own_form), { "Authorization" => "Bearer bad.jwt.token", "X-Employee-Link-Id" => active_link.id.to_s }) ],
        [ :unknown_clerk_user, probe.call(form_path.call(own_form), bearer("user_nobody", azp: alpha_origin).merge("X-Employee-Link-Id" => active_link.id.to_s)) ],
        [ :missing_link_header, probe.call(form_path.call(own_form), bearer(worker.clerk_id, azp: alpha_origin)) ],
        [ :malformed_link_header, probe.call(form_path.call(own_form), bearer(worker.clerk_id, azp: alpha_origin).merge("X-Employee-Link-Id" => "abc")) ],
        [ :other_user_link, probe.call(form_path.call(colleague_form), link_auth.call(worker, colleague_link)) ],
        [ :wrong_subdomain_link, probe.call(form_path.call(own_form), link_auth.call(worker, active_link, azp: bravo_origin)) ],
        [ :revoked_link, probe.call(form_path.call(revoked_form), link_auth.call(worker, revoked_link)) ],
        [ :locked_link, probe.call(form_path.call(locked_form), link_auth.call(worker, locked_link)) ],
        [ :expired_former_link, probe.call(form_path.call(expired_form), link_auth.call(worker, expired_link)) ],
        [ :other_employee_record, probe.call(form_path.call(colleague_form), link_auth.call(worker, active_link)) ],
        [ :nonexistent_record, probe.call("/api/v1/employee/tax_forms/999999999", link_auth.call(worker, active_link)) ]
      ]

      # Feature-off 404 must ALSO have identical status, body, and headers (no Cache-Control oracle).
      features = { "stubs" => true, "tax_forms" => true, "profile_requests" => true, "delivery_consent" => true }
      @alpha_profile.update!(options: { "subdomain_enabled" => true, "employee_portal" => { "features" => features.merge("tax_forms" => false) } })
      TenantSubdomainRegistry.invalidate!
      results << [ :feature_off, probe.call(form_path.call(own_form), link_auth.call(worker, active_link)) ]

      # Portal off: every feature back on, only the master switch off.
      @alpha_profile.update!(options: { "subdomain_enabled" => true, "employee_portal" => { "features" => features } })
      TenantSubdomainRegistry.invalidate!
      expect(probe.call(form_path.call(own_form), link_auth.call(worker, active_link))[:status]).to eq(200)
      @alpha_profile.update!(employee_portal_enabled: false)
      TenantSubdomainRegistry.invalidate!
      results << [ :portal_off, probe.call(form_path.call(own_form), link_auth.call(worker, active_link)) ]

      expect_identical_signatures!(results, expected_status: 404)
      expect(results.first.last[:body]).to eq("")
      expect(results.first.last[:headers]["cache-control"]).to eq("no-store")
    end
  end
end
