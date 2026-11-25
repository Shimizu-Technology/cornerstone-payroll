# frozen_string_literal: true

require "rails_helper"

# M4-11: Route-generated isolation matrix covering EVERY mounted employee
# endpoint under RLS guard `raise` with real signed Clerk JWT verification
# (no auth stubs).
#
# A route-completeness check fails automatically whenever a new employee route
# is added without isolation coverage here.
RSpec.describe "Employee endpoint isolation matrix", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  # Every mounted route under /api/v1/employee (or api/v1/employee_portal/*)
  # must appear here with its scope, feature gate, and write classification.
  # Adding a route without classifying it fails the completeness check below.
  ENDPOINT_MANIFEST = {
    [ "GET",    "/api/v1/employee/context" ] =>
      { kind: :link, access: :read, feature: :portal },
    [ "GET",    "/api/v1/employee/help" ] =>
      { kind: :link, access: :read, feature: :portal },
    [ "GET",    "/api/v1/employee/profile" ] =>
      { kind: :link, access: :read, feature: :profile_requests, profile_window: true },
    [ "PATCH",  "/api/v1/employee/profile/phone" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true },
    [ "POST",   "/api/v1/employee/profile/email" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true },
    [ "POST",   "/api/v1/employee/profile/email/confirm" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true },
    [ "POST",   "/api/v1/employee/emergency_contacts" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true },
    [ "PATCH",  "/api/v1/employee/emergency_contacts/:id" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true, resource: :emergency_contact },
    [ "PUT",    "/api/v1/employee/emergency_contacts/:id" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true, resource: :emergency_contact },
    [ "DELETE", "/api/v1/employee/emergency_contacts/:id" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true, resource: :emergency_contact },
    [ "POST",   "/api/v1/employee/address_requests" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true },
    [ "PATCH",  "/api/v1/employee/address_requests/:id" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true, resource: :address_request },
    [ "PUT",    "/api/v1/employee/address_requests/:id" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true, resource: :address_request },
    [ "DELETE", "/api/v1/employee/address_requests/:id" ] =>
      { kind: :link, access: :write, feature: :profile_requests, profile_window: true, resource: :address_request },
    [ "GET",    "/api/v1/employee/delivery_consents" ] =>
      { kind: :link, access: :read, feature: :delivery_consent },
    [ "POST",   "/api/v1/employee/delivery_consents" ] =>
      { kind: :link, access: :write, feature: :delivery_consent },
    [ "POST",   "/api/v1/employee/delivery_consents/withdraw" ] =>
      { kind: :link, access: :write, feature: :delivery_consent, former_writable: true },
    [ "POST",   "/api/v1/employee/delivery_consents/w2gu_access_proof/pdf" ] =>
      { kind: :link, access: :write, feature: :delivery_consent },
    [ "GET",    "/api/v1/employee/statements" ] =>
      { kind: :link, access: :read, feature: :stubs },
    [ "GET",    "/api/v1/employee/statements/:id" ] =>
      { kind: :link, access: :read, feature: :stubs, resource: :statement },
    [ "GET",    "/api/v1/employee/statements/:id/pdf" ] =>
      { kind: :link, access: :read, feature: :stubs, resource: :statement },
    [ "GET",    "/api/v1/employee/tax_forms" ] =>
      { kind: :link, access: :read, feature: :tax_forms },
    [ "GET",    "/api/v1/employee/tax_forms/:id" ] =>
      { kind: :link, access: :read, feature: :tax_forms, resource: :tax_form },
    [ "GET",    "/api/v1/employee/tax_forms/:id/pdf" ] =>
      { kind: :link, access: :read, feature: :tax_forms, resource: :tax_form },
    [ "GET",    "/api/v1/employee/links" ] =>
      { kind: :account, access: :read, feature: :portal },
    [ "POST",   "/api/v1/employee/links/claim" ] =>
      { kind: :account, access: :write, feature: :portal },
    [ "POST",   "/api/v1/employee/links/reactivate" ] =>
      { kind: :account, access: :write, feature: :portal },
    [ "POST",   "/api/v1/employee/activation" ] =>
      { kind: :public, access: :write, feature: :portal }
  }.freeze

  # Non-link routes (:account and :public) cannot be exercised generically via
  # `link_routes`. Each dimension example wraps its assertions in
  # `require_all_non_link_routes_exercised!(dimension)`, which observes every
  # real HTTP request processed by Rails and fails if any non-link route in
  # `ENDPOINT_MANIFEST` was not actually requested in that dimension. Adding a
  # new :account or :public route therefore requires real HTTP tests in every
  # dimension, not just a manifest entry.
  def require_all_non_link_routes_exercised!(dimension)
    exercised = Set.new
    subscriber = lambda do |*, payload|
      verb = payload[:method].to_s.upcase
      path = payload[:path].to_s.split("?", 2).first
      exercised << [ verb, path ]
    end
    ActiveSupport::Notifications.subscribed(subscriber, "process_action.action_controller") { yield }

    expected = ENDPOINT_MANIFEST.select { |_, meta| meta[:kind] != :link }.keys.to_set
    missing = (expected - exercised).to_a.sort
    expect(missing).to be_empty,
      "Non-link employee route(s) not actually exercised in #{dimension} dimension: #{missing.inspect}"
  end

  def self.mounted_employee_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      controller = route.defaults[:controller].to_s
      next unless path.start_with?("/api/v1/employee") || controller.start_with?("api/v1/employee_portal/")

      verb = route.verb.to_s.gsub(/\A\^|\$\z/, "")
      next if verb.blank?

      [ verb, path ]
    end.uniq.sort
  end

  let(:organization) { create(:organization) }
  let(:alpha) { create(:company, organization: organization, name: "Alpha Grill", subdomain_slug: "alpha-iso") }
  let(:bravo) { create(:company, organization: organization, name: "Bravo Cafe", subdomain_slug: "bravo-iso") }
  let(:alpha_origin) { "https://alpha-iso.shimizu-technology.com" }
  let(:bravo_origin) { "https://bravo-iso.shimizu-technology.com" }

  let(:staff) do
    create(:user, company: alpha, organization: organization, role: :super_admin, view_as_allowed: true,
      clerk_id: "user_iso_staff", name: "Support Admin")
  end
  let(:worker_a) do
    create(:user, company: alpha, organization: organization, role: :portal_employee, clerk_id: "user_iso_a",
      name: "Jordan Reyes", email: "jordan.a@example.net")
  end
  let(:worker_b) do
    create(:user, company: alpha, organization: organization, role: :portal_employee, clerk_id: "user_iso_b",
      name: "Casey Cruz", email: "casey.b@example.net")
  end

  let(:emp_a) do
    create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", email: "jordan.emp@example.net",
      date_of_birth: Date.new(1992, 6, 30), address_line1: "100 Main St", city: "Tamuning", state: "GU", zip: "96913")
  end
  let(:emp_b) do
    create(:employee, company: alpha, first_name: "Casey", last_name: "Cruz", email: "casey.emp@example.net",
      date_of_birth: Date.new(1991, 3, 15), address_line1: "200 Oak Ave", city: "Hagatna", state: "GU", zip: "96910")
  end
  let(:emp_bravo) do
    create(:employee, company: bravo, first_name: "Jordan", last_name: "Reyes", email: "jordan.bravo@example.net",
      date_of_birth: Date.new(1992, 6, 30), address_line1: "300 Palm Dr", city: "Dededo", state: "GU", zip: "96929")
  end

  let(:link_a) do
    EmployeeAccountLink.create!(user: worker_a, company: alpha, employee: emp_a, status: "active", activated_at: 2.days.ago)
  end
  let(:link_b) do
    EmployeeAccountLink.create!(user: worker_b, company: alpha, employee: emp_b, status: "active", activated_at: 2.days.ago)
  end
  let(:link_bravo) do
    EmployeeAccountLink.create!(user: worker_a, company: bravo, employee: emp_bravo, status: "active", activated_at: 2.days.ago)
  end

  let(:stub_pdf_bytes) { "%PDF-1.4 isolation-stub" }
  let(:w2_pdf_bytes) { "%PDF-1.4 isolation-w2gu" }
  let(:storage) { instance_double(R2StorageService) }

  around do |example|
    saved = ENV.to_h.slice("RLS_CONTEXT_GUARD_MODE", "AUTH_ENABLED", "REQUIRE_MFA", DemoOutbound::ENV_KEY)
    ENV.update(
      "RLS_CONTEXT_GUARD_MODE" => "raise",
      "AUTH_ENABLED" => "true",
      "REQUIRE_MFA" => "true",
      DemoOutbound::ENV_KEY => "demo.worker@demo-iso.example,demo.employee@demo-iso.example"
    )
    example.run
  ensure
    %w[RLS_CONTEXT_GUARD_MODE AUTH_ENABLED REQUIRE_MFA].push(DemoOutbound::ENV_KEY).each { |key| ENV[key] = saved[key] }
  end

  before do
    DeliveryDisclosures::DraftSeeds.seed!
    @alpha_profile = enable_all_employee_features!(alpha)
    @bravo_profile = enable_all_employee_features!(bravo)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:download) do |key|
      key.include?("w2gu") ? w2_pdf_bytes : stub_pdf_bytes
    end
    allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
    allow(PortalNotifications::Transport).to receive(:from_email).and_return("noreply@example.test")
    allow(PortalNotifications::Transport).to receive(:deliver).and_return("id" => "msg_iso_1")
    CompanyHelpContact.create!(company: alpha, position: 1, name: "Alpha Manager", phone: "671-555-0101")
    CompanyHelpContact.create!(company: bravo, position: 1, name: "Bravo Manager", phone: "671-555-0102")
  end

  def enable_all_employee_features!(company, enabled: true, features: {})
    defaults = { "stubs" => true, "tax_forms" => true, "profile_requests" => true, "delivery_consent" => true }
    profile = company.client_operating_profiles.create!(
      effective_on: Date.new(2026, 1, 1), version: 1, offering: "payroll_service", hours_source: "manual",
      employee_portal_enabled: enabled,
      options: { "subdomain_enabled" => true, "employee_portal" => { "features" => defaults.merge(features) } }
    )
    # A profile flag alone opens nothing (M4-9d): turn it on the way the switch does.
    activate_employee_app!(company) if enabled
    TenantSubdomainRegistry.invalidate!
    profile
  end

  def seed_employee_resources(employee, link, pay_date: Date.new(2026, 6, 15))
    period = create(:pay_period, :committed, company: employee.company,
      start_date: pay_date - 13.days, end_date: pay_date - 1.day, pay_date: pay_date)
    item = create(:payroll_item, pay_period: period, employee: employee)
    statement = EmployeeDocument.create!(
      company: employee.company, payroll_item: item, revision: 1, status: "posted",
      storage_key: "employee_documents/iso/stub-#{employee.id}-#{period.id}.pdf",
      sha256: Digest::SHA256.hexdigest(stub_pdf_bytes), posted_at: Time.current
    )
    tax_form = EmployeeDocument.create!(
      company: employee.company, employee: employee, tax_year: 2026, revision: 1, status: "posted",
      storage_key: "employee_documents/iso/w2gu-#{employee.id}.pdf",
      sha256: Digest::SHA256.hexdigest(w2_pdf_bytes), posted_at: Time.current
    )
    contact = EmployeeEmergencyContact.create!(
      company: employee.company, employee: employee, name: "Emergency #{employee.id}", relationship: "Sibling", phone: "+16715550111"
    )
    address_request = EmployeeChangeRequest.create!(
      company: employee.company, employee: employee, requested_by: link.user, requested_by_link: link,
      request_kind: "update", status: :pending,
      proposed_changes: { "address_line1" => "999 Proposed Way", "city" => "Tamuning", "state" => "GU", "zip" => "96913" },
      original_values: employee.slice(*EmployeeChangeRequest::ADDRESS_FIELDS)
    )
    { statement: statement, tax_form: tax_form, emergency_contact: contact, address_request: address_request }
  end

  def resolve_path(template, resources)
    meta = ENDPOINT_MANIFEST.fetch(template)
    path = template.last
    return path unless meta[:resource]

    record = resources.fetch(meta[:resource])
    path.sub(":id", record.id.to_s)
  end

  def payload_for(template, email_override: nil)
    verb, path = template
    return nil if verb == "GET" || verb == "DELETE"

    case path
    when "/api/v1/employee/profile/phone"
      { phone: "671-555-0199" }
    when "/api/v1/employee/profile/email"
      { email: email_override || "verified.new@example.net" }
    when "/api/v1/employee/profile/email/confirm"
      { verification_id: "0" * 32, code: "123456" }
    when "/api/v1/employee/emergency_contacts", "/api/v1/employee/emergency_contacts/:id"
      { name: "Sam Santos", relationship: "Spouse", phone: "671-555-0188" }
    when "/api/v1/employee/address_requests", "/api/v1/employee/address_requests/:id"
      { address: { address_line1: "450 Updated Ln", city: "Hagatna", state: "GU", zip: "96910" } }
    when "/api/v1/employee/delivery_consents"
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      { kind: "pay_statements", acknowledged: true, disclosure_version: disclosure.version, disclosure_digest: disclosure.digest }
    when "/api/v1/employee/delivery_consents/withdraw"
      { kind: "pay_statements" }
    when "/api/v1/employee/delivery_consents/w2gu_access_proof/pdf"
      {}
    else
      {}
    end
  end

  def send_employee_request(template, path:, headers:, body: nil)
    verb = template.first.downcase.to_sym
    req_headers = headers.dup
    if body
      req_headers["CONTENT_TYPE"] = "application/json"
      public_send(verb, path, params: body.to_json, headers: req_headers)
    else
      public_send(verb, path, headers: req_headers)
    end
  end

  # REQUIRE_MFA is on here, so every login, employee-only ones included, has
  # an enrolled, freshly verified second factor unless a test says otherwise.
  def bearer(subject, **options)
    super(subject, fva: [ 0, 0 ], two_factor_enabled: true, **options)
  end

  def link_headers(link, subject: link.user.clerk_id, azp: alpha_origin, **claims)
    bearer(subject, azp: azp, **claims).merge("X-Employee-Link-Id" => link.id.to_s)
  end

  def link_routes
    self.class.mounted_employee_routes.select { |route| ENDPOINT_MANIFEST.fetch(route)[:kind] == :link }
  end

  def seed_active_consent!(employee, link, kind: "pay_statements")
    disclosure = DeliveryDisclosure.current_for(kind)
    DeliveryConsent.create!(
      company: employee.company, user: link.user, employee: employee, employee_account_link: link,
      delivery_disclosure: disclosure, kind: kind, disclosure_version: disclosure.version,
      disclosure_digest: disclosure.digest, given_at: 1.hour.ago, method: "employee_portal_checkbox"
    )
  end

  # Everything an employee-app write can change for one employee and link.
  def employee_write_snapshot(employee, link)
    employee.reload
    {
      employee: employee.attributes.except("updated_at"),
      link: link.reload.attributes.except("updated_at"),
      emergency_contacts: EmployeeEmergencyContact.where(employee_id: employee.id).order(:id).map { |c| c.attributes.except("updated_at") },
      change_requests: EmployeeChangeRequest.where(employee_id: employee.id).order(:id).map { |r| r.attributes.except("updated_at") },
      delivery_consents: DeliveryConsent.where(employee_id: employee.id).order(:id).map { |c| c.attributes.except("updated_at") },
      changes_to_confirm: EmployeeContactChangeToConfirm.where(employee_id: employee.id).order(:id).pluck(:id)
    }
  end

  def expect_empty_not_found(context_label)
    expect(response).to have_http_status(:not_found), "#{context_label}: expected 404, got #{response.status} (#{response.body.inspect})"
    expect(response.body).to eq(""), "#{context_label}: expected empty body, got #{response.body.inspect}"
    expect(response.headers["Cache-Control"]).to eq("no-store"), "#{context_label}: expected Cache-Control: no-store"
  end

  # 1. Fail-closed route coverage guard: CI fails if a new employee route is
  # added without isolation coverage in ENDPOINT_MANIFEST. Link-scoped routes
  # are exercised automatically via `link_routes`; non-link routes are enforced
  # at runtime in every dimension via `require_all_non_link_routes_exercised!`.
  it "fails if any mounted employee route is missing from the isolation matrix" do
    expect(RlsContextGuard.mode).to eq("raise")
    mounted = self.class.mounted_employee_routes
    expect(mounted).not_to be_empty

    uncovered = mounted - ENDPOINT_MANIFEST.keys
    stale = ENDPOINT_MANIFEST.keys - mounted
    expect(uncovered).to be_empty, "Uncovered employee routes missing isolation tests: #{uncovered.inspect}"
    expect(stale).to be_empty, "Stale routes in ENDPOINT_MANIFEST no longer mounted: #{stale.inspect}"
  end

  # Positive baseline: confirm every link-scoped endpoint is actually reachable
  # (never a routing/fixture 404) under valid real authentication.
  it "reaches every link-scoped employee endpoint under valid real auth and RLS raise" do
    resources = seed_employee_resources(emp_a, link_a)
    headers = link_headers(link_a, azp: alpha_origin)

    link_routes.each do |route|
      # Keep an active pending address request for update/delete, and clear before create.
      if route == [ "POST", "/api/v1/employee/address_requests" ]
        EmployeeChangeRequest.where(employee_id: emp_a.id, status: :pending).delete_all
      elsif route.last == "/api/v1/employee/address_requests/:id"
        current_pending = EmployeeChangeRequest.where(employee_id: emp_a.id, status: :pending).last
        resources[:address_request] = current_pending || EmployeeChangeRequest.create!(
          company: alpha, employee: emp_a, requested_by: worker_a, requested_by_link: link_a,
          request_kind: "update", status: :pending,
          proposed_changes: { "address_line1" => "888 Reset St", "city" => "Tamuning", "state" => "GU", "zip" => "96913" },
          original_values: emp_a.slice(*EmployeeChangeRequest::ADDRESS_FIELDS)
        )
      elsif route.last == "/api/v1/employee/emergency_contacts/:id" && resources[:emergency_contact].reload.deleted_at.present?
        resources[:emergency_contact] = EmployeeEmergencyContact.create!(
          company: alpha, employee: emp_a, name: "Emergency Reset", relationship: "Sibling", phone: "+16715550111"
        )
      end

      path = resolve_path(route, resources)
      send_employee_request(route, path: path, headers: headers, body: payload_for(route))
      if route.last == "/api/v1/employee/profile/email/confirm"
        # The dummy verification_id reaches the code check itself, so this
        # specific error proves auth, link, feature, and step-up all passed.
        expect(response).to have_http_status(:unprocessable_content), "Baseline confirm returned #{response.status} (#{response.body})"
        expect(response.parsed_body).to eq("error" => "The verification code is invalid or expired.")
      else
        expect([ 200, 201, 202 ]).to include(response.status),
          "Baseline #{route.join(' ')} returned #{response.status} (#{response.body})"
      end
    end
  end

  # 2. Cross-company isolation across EVERY employee endpoint.
  it "enforces cross-company isolation across every employee endpoint" do
    require_all_non_link_routes_exercised!(:cross_company) do
    resources_a = seed_employee_resources(emp_a, link_a)
    resources_bravo = seed_employee_resources(emp_bravo, link_bravo)

    # Link-scoped routes:
    # (a) bravo link presented on alpha's subdomain -> 404
    # (b) bravo resource IDs requested through alpha link -> 404
    # (c) spoofed X-Company-Id header never exposes bravo data
    link_routes.each do |route|
      bravo_path = resolve_path(route, resources_bravo)
      send_employee_request(route, path: bravo_path, headers: link_headers(link_bravo, azp: alpha_origin), body: payload_for(route))
      expect_empty_not_found("cross-company subdomain #{route.join(' ')}")

      if ENDPOINT_MANIFEST.fetch(route)[:resource]
        send_employee_request(route, path: bravo_path, headers: link_headers(link_a, azp: alpha_origin), body: payload_for(route))
        expect_empty_not_found("cross-company resource #{route.join(' ')}")
      end

      if ENDPOINT_MANIFEST.fetch(route)[:access] == :read && !ENDPOINT_MANIFEST.fetch(route)[:resource]
        alpha_path = resolve_path(route, resources_a)
        send_employee_request(route, path: alpha_path,
          headers: link_headers(link_a, azp: alpha_origin).merge("X-Company-Id" => bravo.id.to_s))
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Bravo Manager", "300 Palm Dr", "jordan.bravo@example.net")
        if route.last == "/api/v1/employee/statements"
          expect(response.parsed_body.fetch("statements").pluck("id")).not_to include(resources_bravo[:statement].id.to_s)
        elsif route.last == "/api/v1/employee/tax_forms"
          expect(response.parsed_body.fetch("tax_forms").pluck("id")).not_to include(resources_bravo[:tax_form].id.to_s)
        end
      end
    end

    # GET /api/v1/employee/links on alpha subdomain hides bravo link.
    get "/api/v1/employee/links", headers: bearer("user_iso_a", azp: alpha_origin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links").pluck("id")).to eq([ link_a.id ])

    # POST /api/v1/employee/links/claim rejects bravo invite from alpha subdomain and cross-org invite.
    bravo_invite = invite!(create(:employee, company: bravo, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30)),
      actor: create(:user, role: :admin, company: bravo, organization: organization), delivery: "code")
    post "/api/v1/employee/links/claim",
      params: activation_params(bravo_invite.link.employee, code: bravo_invite.code).except(:email).to_json,
      headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    expect(bravo_invite.link.reload).to be_invited

    other_org_company = create(:company, name: "Other Org Co")
    enable_all_employee_features!(other_org_company)
    other_org_emp = create(:employee, company: other_org_company, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30))
    other_org_invite = invite!(other_org_emp, actor: create(:user, role: :admin, company: other_org_company), delivery: "code")
    post "/api/v1/employee/links/claim",
      params: activation_params(other_org_emp, code: other_org_invite.code).except(:email).to_json,
      headers: bearer("user_iso_a").merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    expect(other_org_invite.link.reload).to be_invited

    # POST /api/v1/employee/links/reactivate rejects bravo invite from alpha subdomain.
    rehire_user = create(:user, company: bravo, organization: organization, role: :portal_employee, clerk_id: "user_iso_rehire",
      active: false, deactivated_at: 20.minutes.ago, deactivation_reason: "last_employee_link_closed", invitation_status: "accepted")
    EmployeeAccountLink.create!(user: rehire_user, company: bravo, employee: bravo_invite.link.employee, status: "revoked", revoked_at: 20.minutes.ago)
    clerk_session!("sess_user_iso_rehire", user_id: "user_iso_rehire", created_at: 10.minutes.ago)
    post "/api/v1/employee/links/reactivate",
      params: activation_params(bravo_invite.link.employee, code: bravo_invite.code).except(:email).to_json,
      headers: bearer("user_iso_rehire", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    expect(rehire_user.reload).not_to be_active

    # POST /api/v1/employee/activation refuses an Alpha employee's details against Bravo's invite.
    # (Bravo's own details from Alpha's subdomain are covered by the example below.)
    post_activation(activation_params(emp_a, code: bravo_invite.code, ssn_last4: emp_a.ssn_digits.last(4)), origin: alpha_origin)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => Api::V1::EmployeePortal::ActivationsController::FAILED, "code" => "activation_failed")
    expect(bravo_invite.link.reload).to have_attributes(status: "invited", user_id: nil)
    end
  end

  # Sign-up itself does not read the browser Origin: Bravo's own invitee with
  # Bravo's correct DOB and SSN-4 starts a sign-up from any page. The subdomain
  # binding is that the sign-up returns to Bravo's subdomain only, and Bind
  # (/auth/me) refuses a token whose azp names another company's subdomain.
  it "binds an activation from another company's subdomain only on the invite company's own subdomain" do
    bravo_emp = create(:employee, company: bravo, first_name: "Riley", last_name: "Santos", date_of_birth: Date.new(1990, 4, 12))
    bravo_invite = invite!(bravo_emp, actor: create(:user, role: :admin, company: bravo, organization: organization), delivery: "code")

    post_activation(activation_params(bravo_emp, code: bravo_invite.code), origin: alpha_origin)
    expect_sign_up_started
    link = bravo_invite.link.reload
    expect(link).to have_attributes(status: "invited", company_id: bravo.id)
    expect(link.user).to have_attributes(company_id: bravo.id, clerk_id: nil)
    expect(clerk_invitations.last.fetch(:redirect_url)).to eq("#{bravo_origin}/sign-up")

    metadata = { "payroll_employee_link_id" => link.id, "payroll_invite_generation" => link.invite_generation }
    bind = lambda do |azp|
      TenantScope.as_system(reason: "Check the employee bind subdomain rule") do
        ApplicationRecord.transaction { EmployeeLinks::Bind.lock_link(link.user, metadata, azp: azp) }
      end
    end
    expect(bind.call(alpha_origin)).to be_nil
    expect(bind.call(bravo_origin)).to eq(link)
    expect(link.reload).to have_attributes(status: "invited", user_id: link.user_id)
  end

  # 3. Cross-employee isolation (same company) across EVERY employee endpoint.
  it "enforces cross-employee isolation within the same company across every employee endpoint" do
    require_all_non_link_routes_exercised!(:cross_employee) do
    resources_a = seed_employee_resources(emp_a, link_a)
    resources_b = seed_employee_resources(emp_b, link_b)
    headers_a = link_headers(link_a, azp: alpha_origin)

    link_routes.each do |route|
      if ENDPOINT_MANIFEST.fetch(route)[:resource]
        b_path = resolve_path(route, resources_b)
        send_employee_request(route, path: b_path, headers: headers_a, body: payload_for(route))
        expect_empty_not_found("cross-employee resource #{route.join(' ')}")
      elsif ENDPOINT_MANIFEST.fetch(route)[:access] == :read
        a_path = resolve_path(route, resources_a)
        send_employee_request(route, path: a_path, headers: headers_a)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Casey", "casey.emp@example.net", "200 Oak Ave", "Emergency #{emp_b.id}")
        if route.last == "/api/v1/employee/statements"
          expect(response.parsed_body.fetch("statements").pluck("id")).not_to include(resources_b[:statement].id.to_s)
        elsif route.last == "/api/v1/employee/tax_forms"
          expect(response.parsed_body.fetch("tax_forms").pluck("id")).not_to include(resources_b[:tax_form].id.to_s)
        end
      end
    end

    # GET /api/v1/employee/links never returns another employee's links.
    get "/api/v1/employee/links", headers: bearer("user_iso_a", azp: alpha_origin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links").pluck("id")).to eq([ link_a.id ])

    # Claim, reactivate, activation reject another employee's invite/details.
    stranger_emp = create(:employee, company: alpha, first_name: "Taylor", last_name: "Ng", date_of_birth: Date.new(1985, 8, 20))
    stranger_invite = invite!(stranger_emp, actor: staff, delivery: "code")

    post "/api/v1/employee/links/claim",
      params: activation_params(stranger_emp, code: stranger_invite.code).except(:email).to_json,
      headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    expect(stranger_invite.link.reload).to be_invited

    deactivated_a = create(:user, company: alpha, organization: organization, role: :portal_employee, clerk_id: "user_iso_deact_a",
      active: false, deactivated_at: 20.minutes.ago, deactivation_reason: "last_employee_link_closed", invitation_status: "accepted")
    clerk_session!("sess_user_iso_deact_a", user_id: "user_iso_deact_a", created_at: 10.minutes.ago)
    post "/api/v1/employee/links/reactivate",
      params: activation_params(stranger_emp, code: stranger_invite.code).except(:email).to_json,
      headers: bearer("user_iso_deact_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    expect(deactivated_a.reload).not_to be_active

    post_activation(activation_params(emp_a, code: stranger_invite.code))
    expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # 3b. Writes without a resource ID take their employee from the link alone:
  # with A's link, each one changes A and never B, even when the body names B.
  it "applies same-company writes without a resource ID to the presenting link's employee only" do
    seed_employee_resources(emp_a, link_a)
    seed_employee_resources(emp_b, link_b)
    seed_active_consent!(emp_b, link_b)
    EmployeeChangeRequest.where(employee_id: emp_a.id, status: :pending).delete_all
    headers_a = link_headers(link_a, azp: alpha_origin)
    a_before = employee_write_snapshot(emp_a, link_a)
    b_before = employee_write_snapshot(emp_b, link_b)
    consent_audits = ->(link, event) { AuditLog.where(action: "employee_delivery_consents##{event}", record_id: link.id) }

    # Ordered: consent is given before it is withdrawn.
    effects = {
      [ "PATCH", "/api/v1/employee/profile/phone" ] => lambda {
        expect(emp_a.reload.phone).not_to eq(a_before[:employee]["phone"])
        expect(emp_a.phone).to end_with("5550199")
      },
      [ "POST", "/api/v1/employee/profile/email" ] => lambda {
        expect(link_a.reload.profile_email_challenge).to be_present
        expect(a_before[:link]["profile_email_challenge"]).to be_nil
      },
      [ "POST", "/api/v1/employee/profile/email/confirm" ] => lambda {
        expect(response.parsed_body).to eq("error" => "The verification code is invalid or expired.")
        expect(emp_a.reload.email).to eq(a_before[:employee]["email"])
      },
      [ "POST", "/api/v1/employee/emergency_contacts" ] => lambda {
        expect(EmployeeEmergencyContact.where(employee_id: emp_a.id, name: "Sam Santos").count).to eq(1)
      },
      [ "POST", "/api/v1/employee/address_requests" ] => lambda {
        expect(EmployeeChangeRequest.where(employee_id: emp_a.id, status: :pending).sole.proposed_changes)
          .to include("address_line1" => "450 Updated Ln")
      },
      [ "POST", "/api/v1/employee/delivery_consents" ] => lambda {
        expect(DeliveryConsent.active.where(employee_id: emp_a.id, kind: "pay_statements").count).to eq(1)
      },
      [ "POST", "/api/v1/employee/delivery_consents/w2gu_access_proof/pdf" ] => lambda {
        expect(response.parsed_body["access_proof_token"]).to be_present
        expect(consent_audits.call(link_a, "w2gu_access_proof").count).to eq(1)
        expect(consent_audits.call(link_b, "w2gu_access_proof")).to be_empty
      },
      [ "POST", "/api/v1/employee/delivery_consents/withdraw" ] => lambda {
        expect(DeliveryConsent.where(employee_id: emp_a.id, kind: "pay_statements").sole.withdrawn_at).to be_present
      }
    }
    no_id_writes = link_routes.select { |route| ENDPOINT_MANIFEST.fetch(route).values_at(:access, :resource) == [ :write, nil ] }
    expect(effects.keys.sort).to eq(no_id_writes.sort), "Every link-scoped write without a resource ID needs an effect check here"

    effects.each do |route, expect_effect_on_a|
      # None of these routes takes a target selector; the body names B anyway.
      body = payload_for(route).merge(employee_id: emp_b.id, employee_account_link_id: link_b.id)
      send_employee_request(route, path: route.last, headers: headers_a, body: body)
      expected = route.last == "/api/v1/employee/profile/email/confirm" ? [ 422 ] : [ 200, 201, 202 ]
      expect(expected).to include(response.status), "#{route.join(' ')} returned #{response.status} (#{response.body})"
      expect_effect_on_a.call
      expect(employee_write_snapshot(emp_b, link_b)).to eq(b_before), "#{route.join(' ')} with A's link changed Employee B"
    end
  end

  # 4. Cross-link isolation across EVERY employee endpoint.
  it "enforces cross-link isolation across every employee endpoint" do
    require_all_non_link_routes_exercised!(:cross_link) do
    resources_b = seed_employee_resources(emp_b, link_b)
    resources_bravo = seed_employee_resources(emp_bravo, link_bravo)

    link_routes.each do |route|
      # Worker A presenting Worker B's link header -> 404.
      b_path = resolve_path(route, resources_b)
      send_employee_request(route, path: b_path,
        headers: link_headers(link_b, subject: worker_a.clerk_id, azp: alpha_origin), body: payload_for(route))
      expect_empty_not_found("cross-link other user #{route.join(' ')}")

      # Worker A presenting own alpha link header with own bravo link's resource ID -> 404.
      if ENDPOINT_MANIFEST.fetch(route)[:resource]
        bravo_path = resolve_path(route, resources_bravo)
        send_employee_request(route, path: bravo_path,
          headers: link_headers(link_a, azp: alpha_origin), body: payload_for(route))
        expect_empty_not_found("cross-link own second company resource #{route.join(' ')}")
      end
    end

    # Account routes ignore spoofed X-Employee-Link-Id and refuse claiming a link routed to another user.
    get "/api/v1/employee/links", headers: bearer("user_iso_a").merge("X-Employee-Link-Id" => link_b.id.to_s)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links").pluck("id")).not_to include(link_b.id)

    routed_emp = create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", email: "routed.client@example.net",
      date_of_birth: Date.new(1992, 6, 30))
    routed_user = create(:user, company: alpha, organization: organization, role: :client, name: "Jordan Reyes",
      email: "routed.client@example.net", clerk_id: "user_iso_routed")
    routed_invite = invite!(routed_emp, actor: staff, confirm_same_person_email: true)
    expect(routed_invite.link.claim_user_id).to eq(routed_user.id)

    post "/api/v1/employee/links/claim",
      params: activation_params(routed_emp, token: routed_invite.token).except(:email).to_json,
      headers: bearer("user_iso_a").merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)

    post "/api/v1/employee/links/reactivate",
      params: activation_params(routed_emp, token: routed_invite.token).except(:email).to_json,
      headers: bearer("user_iso_a").merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)

    post_activation(activation_params(routed_emp, token: routed_invite.token, email: "hijack@example.net"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["next"]).to eq("sign_in")
    end
  end

  # 5. Former employee (read-only and correct window) across EVERY employee endpoint.
  it "enforces former-employee read-only rules and access windows across every employee endpoint" do
    require_all_non_link_routes_exercised!(:former) do
    cutoff = Time.find_zone!("Pacific/Guam").local(2026, 7, 1, 23, 59, 59)
    travel_to(Time.find_zone!("Pacific/Guam").local(2026, 6, 20, 12)) do
      resources_before = seed_employee_resources(emp_a, link_a, pay_date: Date.new(2026, 6, 15))
      # Statement dated AFTER former_access_until must never be visible.
      future_period = create(:pay_period, :committed, company: alpha,
        start_date: Date.new(2026, 7, 2), end_date: Date.new(2026, 7, 15), pay_date: Date.new(2026, 7, 16))
      future_item = create(:payroll_item, pay_period: future_period, employee: emp_a)
      future_statement = EmployeeDocument.create!(
        company: alpha, payroll_item: future_item, revision: 1, status: "posted",
        storage_key: "employee_documents/iso/stub-future.pdf",
        sha256: Digest::SHA256.hexdigest(stub_pdf_bytes), posted_at: Time.current
      )

      # Consent given while active, so the former-window withdrawal has a real record to withdraw.
      prior_consent = seed_active_consent!(emp_a, link_a)
      link_a.update!(status: "former", former_at: Time.current, former_access_until: cutoff, former_profile_access_until: cutoff)
      headers = link_headers(link_a, azp: alpha_origin)

      # Phase A: Open former window -> reads allowed (within window), writes refused (404),
      # except one-tap delivery consent withdrawal (allowed per §8a).
      link_routes.each do |route|
        meta = ENDPOINT_MANIFEST.fetch(route)
        path = resolve_path(route, resources_before)
        send_employee_request(route, path: path, headers: headers, body: payload_for(route))
        if meta[:access] == :read || meta[:former_writable]
          expect(response).to have_http_status(:ok), "Open former #{route.join(' ')} returned #{response.status}: #{response.body}"
        else
          expect_empty_not_found("open former write #{route.join(' ')}")
        end
      end

      # The one-tap withdrawal in the open window actually withdrew the consent.
      expect(prior_consent.reload).to have_attributes(withdrawn_by_user_id: worker_a.id)
      expect(prior_consent.withdrawn_at).to be_present
      expect(DeliveryConsent.active.where(employee_id: emp_a.id)).to be_empty
      expect(EmployeeContactChangeToConfirm.where(employee_id: emp_a.id, change_kind: "delivery_consent").count).to eq(1)

      # Post-cutoff statement is hidden from list, detail, and PDF.
      get "/api/v1/employee/statements", headers: headers
      expect(response.parsed_body.fetch("statements").pluck("id")).to eq([ resources_before[:statement].id.to_s ])
      get "/api/v1/employee/statements/#{future_statement.id}", headers: headers
      expect_empty_not_found("former post-cutoff statement show")
      get "/api/v1/employee/statements/#{future_statement.id}/pdf", headers: headers
      expect_empty_not_found("former post-cutoff statement pdf")

      # Phase B: Profile cutoff passed while W-2GU retention keeps former_access_until open.
      link_a.update!(former_profile_access_until: 1.day.ago, former_access_until: 30.days.from_now)
      get "/api/v1/employee/profile", headers: headers
      expect_empty_not_found("former past profile cutoff")
      get "/api/v1/employee/tax_forms", headers: headers
      expect(response).to have_http_status(:ok)

      # Phase C: Past former_access_until -> EVERY link-scoped endpoint (including withdraw) is 404,
      # and GET /links excludes it.
      link_a.update!(former_access_until: 1.minute.ago)
      link_routes.each do |route|
        path = resolve_path(route, resources_before)
        send_employee_request(route, path: path, headers: headers, body: payload_for(route))
        expect_empty_not_found("expired former #{route.join(' ')}")
      end

      get "/api/v1/employee/links", headers: bearer("user_iso_a", azp: alpha_origin)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("links")).to be_empty

      # Activation / claim / reactivate refuse a terminated/former employee's invite.
      emp_a.update!(status: "terminated", termination_date: Date.new(2026, 6, 1))
      stale_invite = EmployeeAccountLink.create!(company: alpha, employee: emp_a, status: "invited",
        invite_token_digest: EmployeeAccountLink.token_digest("terminated-token"), invite_expires_at: 7.days.from_now)
      post_activation(activation_params(emp_a, token: "terminated-token"))
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/employee/links/claim",
        params: activation_params(emp_a, token: "terminated-token").except(:email).to_json,
        headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
      expect(response).to have_http_status(:not_found)
      post "/api/v1/employee/links/reactivate",
        params: activation_params(emp_a, token: "terminated-token").except(:email).to_json,
        headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
      expect(response).to have_http_status(:not_found)
      expect(stale_invite.reload).to be_invited
    end
    end
  end

  # 6. Revoked link across EVERY employee endpoint.
  it "blocks revoked links across every employee endpoint" do
    require_all_non_link_routes_exercised!(:revoked) do
    resources_a = seed_employee_resources(emp_a, link_a)
    link_a.update!(status: "revoked", revoked_at: Time.current, revoked_reason: "Lost device")
    headers = link_headers(link_a, azp: alpha_origin)

    link_routes.each do |route|
      path = resolve_path(route, resources_a)
      send_employee_request(route, path: path, headers: headers, body: payload_for(route))
      expect_empty_not_found("revoked #{route.join(' ')}")
    end

    get "/api/v1/employee/links", headers: bearer("user_iso_a", azp: alpha_origin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links")).to be_empty

    # Revoked invite cannot activate, claim, or reactivate.
    inv = invite!(create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30)),
      actor: staff, delivery: "code")
    inv.link.update!(status: "revoked", revoked_at: Time.current, revoked_reason: "Cancelled")

    post_activation(activation_params(inv.link.employee, code: inv.code))
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/employee/links/claim",
      params: activation_params(inv.link.employee, code: inv.code).except(:email).to_json,
      headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    post "/api/v1/employee/links/reactivate",
      params: activation_params(inv.link.employee, code: inv.code).except(:email).to_json,
      headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    end
  end

  # 7. Locked link across EVERY employee endpoint.
  it "blocks locked links across every employee endpoint" do
    require_all_non_link_routes_exercised!(:locked) do
    resources_a = seed_employee_resources(emp_a, link_a)
    link_a.update!(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)
    headers = link_headers(link_a, azp: alpha_origin)

    link_routes.each do |route|
      path = resolve_path(route, resources_a)
      send_employee_request(route, path: path, headers: headers, body: payload_for(route))
      expect_empty_not_found("locked #{route.join(' ')}")
    end

    get "/api/v1/employee/links", headers: bearer("user_iso_a", azp: alpha_origin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links")).to be_empty

    # Locked invite cannot activate, claim, or reactivate.
    inv = invite!(create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30)),
      actor: staff, delivery: "code")
    inv.link.update!(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)

    post_activation(activation_params(inv.link.employee, code: inv.code))
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/employee/links/claim",
      params: activation_params(inv.link.employee, code: inv.code).except(:email).to_json,
      headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    post "/api/v1/employee/links/reactivate",
      params: activation_params(inv.link.employee, code: inv.code).except(:email).to_json,
      headers: bearer("user_iso_a", azp: alpha_origin).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    end
  end

  # 7b. The activation-lock checks that run after the write transaction
  # reloads the link (profile writes, consent create, consent withdrawal).
  # No supported path puts an activation lock on an active link: locks are
  # written only while a link is invited and are cleared on bind/claim
  # (EmployeeAppRollout#status_of). These guards are therefore defensive, so
  # this example simulates a concurrent lock landing between admission (which
  # saw the link unlocked) and the transactional reload (which sees it locked).
  it "refuses employee writes when the link is locked between admission and the transactional reload" do
    seed_employee_resources(emp_a, link_a)
    EmployeeChangeRequest.where(employee_id: emp_a.id, status: :pending).delete_all
    consent = seed_active_consent!(emp_a, link_a)
    headers = link_headers(link_a, azp: alpha_origin)
    lock_columns = %w[failed_activation_attempts activation_locked_at activation_locked_until]
    unlock = -> { link_a.update_columns(failed_activation_attempts: 0, activation_locked_at: nil, activation_locked_until: nil) }
    guarded = [
      [ "PATCH", "/api/v1/employee/profile/phone" ],
      [ "POST", "/api/v1/employee/profile/email" ],
      [ "POST", "/api/v1/employee/emergency_contacts" ],
      [ "POST", "/api/v1/employee/address_requests" ],
      [ "POST", "/api/v1/employee/delivery_consents/withdraw" ],
      [ "POST", "/api/v1/employee/delivery_consents" ]
    ]

    # Success control: an unchanged, unlocked link passes the same reload.
    send_employee_request(guarded.first, path: guarded.first.last, headers: headers, body: payload_for(guarded.first))
    expect(response).to have_http_status(:ok), response.body
    emp_a.update_columns(phone: "+16715550100")

    locked_at_reload = 0
    allow_any_instance_of(EmployeeAccountLink).to receive(:lock!).and_wrap_original do |original, *args|
      if original.receiver.id == link_a.id
        locked_at_reload += 1
        EmployeeAccountLink.where(id: link_a.id)
          .update_all(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)
      end
      original.call(*args)
    end

    guarded.each do |route|
      unlock.call
      before = employee_write_snapshot(emp_a, link_a)
      expect do
        send_employee_request(route, path: route.last, headers: headers, body: payload_for(route))
      end.to change { locked_at_reload }.by(1)
      expect_empty_not_found("locked at reload #{route.join(' ')}")
      after = employee_write_snapshot(emp_a, link_a)
      expect(after.except(:link)).to eq(before.except(:link)), "#{route.join(' ')} changed state after the reload saw a lock"
      expect(after[:link].except(*lock_columns)).to eq(before[:link].except(*lock_columns))
    end
    expect(consent.reload.withdrawn_at).to be_nil
  end

  # 8. Feature off (404) across EVERY employee endpoint.
  it "returns 404 when the portal or individual feature switch is off across every employee endpoint" do
    require_all_non_link_routes_exercised!(:feature_off) do
    resources_a = seed_employee_resources(emp_a, link_a)
    headers = link_headers(link_a, azp: alpha_origin)

    # First: portal on, individual sub-features off -> every gated endpoint returns empty 404.
    @alpha_profile.update!(options: {
      "subdomain_enabled" => true,
      "employee_portal" => {
        "features" => { "stubs" => false, "tax_forms" => false, "profile_requests" => false, "delivery_consent" => false }
      }
    })
    TenantSubdomainRegistry.invalidate!

    link_routes.each do |route|
      meta = ENDPOINT_MANIFEST.fetch(route)
      next if meta[:feature] == :portal

      path = resolve_path(route, resources_a)
      send_employee_request(route, path: path, headers: headers, body: payload_for(route))
      expect_empty_not_found("sub-feature off #{route.join(' ')}")
    end

    # Second: master employee_portal_enabled off -> EVERY link-scoped endpoint returns 404,
    # GET /links hides it, claim/reactivate return 404, activation returns generic 422.
    inv = invite!(create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30)),
      actor: staff, delivery: "code")
    @alpha_profile.update!(employee_portal_enabled: false)
    TenantSubdomainRegistry.invalidate!

    link_routes.each do |route|
      path = resolve_path(route, resources_a)
      send_employee_request(route, path: path, headers: headers, body: payload_for(route))
      expect_empty_not_found("portal off #{route.join(' ')}")
    end

    get "/api/v1/employee/links", headers: bearer("user_iso_a")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links")).to be_empty

    post "/api/v1/employee/links/claim",
      params: activation_params(inv.link.employee, code: inv.code).except(:email).to_json,
      headers: bearer("user_iso_a").merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)

    post "/api/v1/employee/links/reactivate",
      params: activation_params(inv.link.employee, code: inv.code).except(:email).to_json,
      headers: bearer("user_iso_a").merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)

    post_activation(activation_params(inv.link.employee, code: inv.code))
    expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # 9. Demo versus live identity boundary across EVERY employee endpoint.
  it "enforces the demo versus live identity boundary across every employee endpoint" do
    require_all_non_link_routes_exercised!(:demo_boundary) do
    demo = create_demo_company(organization: organization, name: "Demo Diner", subdomain_slug: "demo-iso")
    demo_user = create(:user, company: demo, organization: organization, role: :client,
      email: "demo.worker@demo-iso.example", name: "Jordan Reyes", clerk_id: "user_iso_demo")
    CompanyAssignment.create!(user: demo_user, company: demo)

    # Even if a row linking a demo identity to a live company exists, every link-scoped endpoint refuses it.
    crossing_emp = create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30))
    crossing_link = EmployeeAccountLink.create!(user: demo_user, company: alpha, employee: crossing_emp, status: "active", activated_at: 1.day.ago)
    resources_cross = seed_employee_resources(crossing_emp, crossing_link)
    demo_headers = link_headers(crossing_link, subject: demo_user.clerk_id, azp: alpha_origin, fva: [ 0, 0 ], two_factor_enabled: true)

    link_routes.each do |route|
      path = resolve_path(route, resources_cross)
      send_employee_request(route, path: path, headers: demo_headers, body: payload_for(route))
      expect_empty_not_found("demo-to-live #{route.join(' ')}")
    end

    get "/api/v1/employee/links", headers: bearer(demo_user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("links")).to be_empty

    # Demo user cannot claim or reactivate a live invite.
    live_emp = create(:employee, company: alpha, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30))
    live_invite = invite!(live_emp, actor: staff, delivery: "code")
    post "/api/v1/employee/links/claim",
      params: activation_params(live_emp, code: live_invite.code).except(:email).to_json,
      headers: bearer(demo_user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)
    expect(live_invite.link.reload).to have_attributes(status: "invited", failed_activation_attempts: 0)

    post "/api/v1/employee/links/reactivate",
      params: activation_params(live_emp, code: live_invite.code).except(:email).to_json,
      headers: bearer(demo_user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:not_found)

    # Activation with the existing demo user's email never creates or attaches a new live login.
    post_activation(activation_params(live_emp, code: live_invite.code, email: demo_user.email))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["next"]).to eq("sign_in")
    expect(live_invite.link.reload.user_id).to be_nil

    # Since #585 a demo company holds employee links like a live client, for
    # demo logins only. The boundary is the login's home company, checked on
    # every use (EmployeeLinks.demo_boundary_allows? via openable?, Bind,
    # claim), not on the stored row, so a live login's link into a demo
    # company is refused by every endpoint, the same as the reverse above.
    # M4-9d: a demo link opens only behind the demo gate (database RLS
    # enforced, stubbed here) and only from the demo's own subdomain (session
    # and browser Origin), so these requests come from there.
    allow(EmployeeAppSwitch::Enforcement).to receive(:database_state)
      .and_return({ phase: "enforced", enforced: true, kill_switch_bypass: false, enforced_tables: 1, protected_tables: 1 })
    EmployeeAppSwitch::Enforcement.reset_cache!
    demo_origin = "https://demo-iso.#{TenantSubdomainRegistry::ROOT_DOMAIN}"
    enable_all_employee_features!(demo)
    demo_worker = create(:user, company: demo, organization: organization, role: :portal_employee,
      email: "demo.employee@demo-iso.example", name: "Kit Wren", clerk_id: "user_iso_demo_employee")
    own_demo_link = EmployeeAccountLink.create!(user: demo_worker, company: demo, employee: create(:employee, company: demo),
      status: "active", activated_at: 1.day.ago)
    get "/api/v1/employee/context",
      headers: link_headers(own_demo_link, azp: demo_origin).merge("Origin" => demo_origin)
    expect(response).to have_http_status(:ok), "demo login's own demo link: #{response.status} #{response.body}"

    demo_emp = create(:employee, company: demo)
    live_into_demo = EmployeeAccountLink.create!(user: worker_a, company: demo, employee: demo_emp, status: "active", activated_at: 1.day.ago)
    resources_live_into_demo = seed_employee_resources(demo_emp, live_into_demo)
    live_into_demo_headers = link_headers(live_into_demo, azp: demo_origin).merge("Origin" => demo_origin)
    link_routes.each do |route|
      path = resolve_path(route, resources_live_into_demo)
      send_employee_request(route, path: path, headers: live_into_demo_headers, body: payload_for(route))
      expect_empty_not_found("live-to-demo #{route.join(' ')}")
    end
    [ bearer(worker_a.clerk_id), bearer(worker_a.clerk_id, azp: demo_origin).merge("Origin" => demo_origin) ].each do |headers|
      get "/api/v1/employee/links", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("links").pluck("id")).not_to include(live_into_demo.id)
    end

    expect(EmployeeLinks.demo_boundary_allows?(worker_a, demo)).to be(false)
    expect(EmployeeLinks.demo_boundary_allows?(demo_user, alpha)).to be(false)
    expect(EmployeeLinks.demo_boundary_allows?(demo_worker, demo)).to be(true)

    # A practice copy (non-demo test workspace) still can't hold a link at all.
    practice = create(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: alpha, migration_rehearsal_status: "ready")
    expect(EmployeeAccountLink.new(company: practice, employee: create(:employee, company: practice))).not_to be_valid
    end
  end

  # 10. View-only support grant across EVERY employee endpoint (no writes, scoped reads).
  it "enforces view-only support grants across every employee endpoint with zero writes" do
    require_all_non_link_routes_exercised!(:view_only) do
    resources_a = seed_employee_resources(emp_a, link_a)
    resources_b = seed_employee_resources(emp_b, link_b)

    post "/api/v1/auth/view_as",
      params: { target_type: "employee", target_id: emp_a.id, reason: "Verify isolation matrix" }, as: :json,
      headers: bearer(staff.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => alpha.id.to_s)
    expect(response).to have_http_status(:created)
    grant_token = response.parsed_body.fetch("token")
    grant = ViewAsGrant.last

    view_headers = bearer(staff.clerk_id, azp: alpha_origin, fva: [ 0, 0 ], two_factor_enabled: true)
      .merge(ViewAsGrant::HEADER => grant_token)
    a_before = employee_write_snapshot(emp_a, link_a)
    b_before = employee_write_snapshot(emp_b, link_b)

    self.class.mounted_employee_routes.each do |route|
      meta = ENDPOINT_MANIFEST.fetch(route)
      path = resolve_path(route, resources_a)

      if meta[:access] == :write
        expect do
          send_employee_request(route, path: path, headers: view_headers, body: payload_for(route))
        end.not_to have_enqueued_job
        expect(response).to have_http_status(:forbidden),
          "view-only write #{route.join(' ')} returned #{response.status}: #{response.body}"
        # A rejected write must not have changed anything before answering 403.
        expect(employee_write_snapshot(emp_a, link_a)).to eq(a_before), "view-only write #{route.join(' ')} changed Employee A"
        expect(employee_write_snapshot(emp_b, link_b)).to eq(b_before), "view-only write #{route.join(' ')} changed Employee B"
      elsif meta[:kind] == :account
        # GET /api/v1/employee/links is not part of an employee support view surface.
        send_employee_request(route, path: path, headers: view_headers)
        expect(response).to have_http_status(:not_found),
          "view-only account route #{route.join(' ')} returned #{response.status}"
      else
        # Read endpoint allowed for target employee, and cannot read another employee's resource.
        send_employee_request(route, path: path, headers: view_headers.merge("X-Employee-Link-Id" => link_b.id.to_s))
        expect(response).to have_http_status(:ok),
          "view-only read #{route.join(' ')} returned #{response.status}: #{response.body}"
        expect(response.body).not_to include("Casey", "casey.emp@example.net", "200 Oak Ave")
        if route.last == "/api/v1/employee/statements"
          expect(response.parsed_body.fetch("statements").pluck("id")).not_to include(resources_b[:statement].id.to_s)
        elsif route.last == "/api/v1/employee/tax_forms"
          expect(response.parsed_body.fetch("tax_forms").pluck("id")).not_to include(resources_b[:tax_form].id.to_s)
        end

        if meta[:resource]
          b_path = resolve_path(route, resources_b)
          send_employee_request(route, path: b_path, headers: view_headers)
          expect(response).to have_http_status(:not_found),
            "view-only cross-employee #{route.join(' ')} returned #{response.status}"
        end
      end
    end

    expect(DeliveryConsent.count).to eq(0)
    expect(PortalNotificationEvent.count).to eq(0)
    expect(AuditLog.where(user_id: worker_a.id)).to be_empty
    expect(AuditLog.where(view_as_grant_id: grant.id).distinct.pluck(:user_id, :real_user_id)).to eq([ [ staff.id, staff.id ] ])
    end
  end
end
