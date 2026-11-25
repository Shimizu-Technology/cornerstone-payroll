# frozen_string_literal: true

require "rails_helper"
require "base64"
require "stringio"
require "pdf/reader"

RSpec.describe "Employee electronic-delivery consents", :portal_notifications, type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:base) { "/api/v1/employee/delivery_consents" }
  let(:company) { create(:company, name: "Harbor Finch Bistro") }
  let(:worker) { create(:user, company: company, role: "portal_employee", clerk_id: "user_consent_worker") }
  let(:employee) do
    create(:employee, company: company, first_name: "Jordan", last_name: "Reyes", email: "jordan.reyes@example.test",
      email_verified_at: 1.day.ago, address_line1: "100 Harbor Way", city: "Tamuning", state: "GU", zip: "96913")
  end
  let(:link) { link_to(worker, employee) }
  let(:staff_user) { create(:user, company: company, organization: company.organization, role: "admin", clerk_id: "user_consent_staff") }

  around do |example|
    settings = ENV.to_h.slice("REQUIRE_MFA", "EMPLOYEE_PORTAL_URL", "RLS_CONTEXT_GUARD_MODE")
    ENV.update("REQUIRE_MFA" => "true", "EMPLOYEE_PORTAL_URL" => EmployeeLinkHelpers::APP_URL, "RLS_CONTEXT_GUARD_MODE" => "raise")
    example.run
  ensure
    %w[REQUIRE_MFA EMPLOYEE_PORTAL_URL RLS_CONTEXT_GUARD_MODE].each { |key| ENV[key] = settings[key] }
  end

  before do
    DeliveryDisclosures::DraftSeeds.seed!
    @operating_profile = enable_delivery_consent(company)
    link
  end

  def enable_delivery_consent(target_company, enabled: true)
    profile = target_company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today,
      version: 1,
      offering: "payroll_service",
      hours_source: "manual",
      employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "delivery_consent" => enabled } } }
    )
    TenantSubdomainRegistry.invalidate!
    profile
  end

  def link_to(user, target_employee, status: "active")
    EmployeeAccountLink.create!(
      user: user,
      company: target_employee.company,
      employee: target_employee,
      status: status,
      activated_at: Time.current
    )
  end

  def employee_headers(target_link = link, subject: target_link.user.clerk_id, fva: [ 0, -1 ], **claims)
    extra = claims
    if target_link.user && !target_link.user.portal_employee? && !claims.key?(:two_factor_enabled)
      extra = { two_factor_enabled: true }.merge(claims)
      fva = [ 0, 0 ] if fva == [ 0, -1 ]
    end
    bearer(subject, fva: fva, **extra).merge(
      "X-Employee-Link-Id" => target_link.id.to_s,
      "User-Agent" => "TestPhone/1.0"
    )
  end

  def expect_not_found
    expect([ response.status, response.body ]).to eq([ 404, "" ])
  end

  def extract_code_from_pdf(pdf_base64)
    pdf_bytes = Base64.strict_decode64(pdf_base64)
    expect(pdf_bytes.byteslice(0, 5)).to eq("%PDF-")
    reader = PDF::Reader.new(StringIO.new(pdf_bytes))
    text = reader.pages.map(&:text).join("\n")
    expect(text).to include("Form W-2GU PDF Access Check")
    match = text.match(/\b([#{EmployeeAccountLink::CODE_ALPHABET.join}]{6})\b/)
    expect(match).to be_present, "Could not find 6-char access proof code in PDF text:\n#{text}"
    match[1]
  end

  describe "feature gating and non-enumerating 404s" do
    it "returns the same empty 404 for every endpoint when delivery_consent is off" do
      @operating_profile.update!(options: { "employee_portal" => { "features" => { "delivery_consent" => false } } })

      get base, headers: employee_headers
      expect_not_found

      post base, params: { kind: "pay_statements" }, headers: employee_headers, as: :json
      expect_not_found

      post "#{base}/withdraw", params: { kind: "pay_statements" }, headers: employee_headers, as: :json
      expect_not_found

      post "#{base}/w2gu_access_proof/pdf", headers: employee_headers, as: :json
      expect_not_found
    end

    it "defaults delivery_consent to off on companies without an explicit opt-in" do
      fresh_company = create(:company)
      expect(CompanyFeatures.for(fresh_company).employee_portal_feature?(:delivery_consent)).to be(false)
    end
  end

  describe "isolation and former link behavior" do
    it "blocks another employee's link and isolates consent records across companies" do
      colleague = create(:user, company: company, role: "portal_employee", clerk_id: "user_consent_colleague")
      colleague_link = link_to(colleague, create(:employee, company: company))

      other_company = create(:company, organization: company.organization)
      enable_delivery_consent(other_company)
      other_employee = create(:employee, company: other_company)
      other_link = link_to(worker, other_employee)

      # Worker cannot use colleague's link
      get base, headers: employee_headers(colleague_link, subject: worker.clerk_id)
      expect_not_found

      # Consent recorded on other_company does not appear on company
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers(other_link), as: :json
      expect(response).to have_http_status(:created)

      get base, headers: employee_headers
      expect(response).to have_http_status(:ok)
      pay_item = response.parsed_body.fetch("consents").find { |c| c["kind"] == "pay_statements" }
      expect(pay_item["status"]).to eq("not_consented")
    end

    it "allows a former link to read status and withdraw active consent, while blocking opt-in and access proof with 404" do
      PortalNotificationRecipient.create!(company: company, user: staff_user)
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:created)

      link.update!(status: "former", former_access_until: 1.year.from_now)

      get base, headers: employee_headers
      expect(response).to have_http_status(:ok)

      post base, params: { kind: "pay_statements" }, headers: employee_headers, as: :json
      expect_not_found

      post "#{base}/w2gu_access_proof/pdf", headers: employee_headers, as: :json
      expect_not_found

      post "#{base}/withdraw", params: { kind: "pay_statements" }, headers: employee_headers(fva: [ 25, -1 ]), as: :json
      expect(response).to have_http_status(:ok)
      pay_item = response.parsed_body.fetch("consents").find { |c| c["kind"] == "pay_statements" }
      expect(pay_item["status"]).to eq("withdrawn")
      expect(pay_item["active_consent"]).to be_nil

      # Expired former links are still blocked on withdraw with empty 404.
      link.update!(former_access_until: 1.day.ago)
      post "#{base}/withdraw", params: { kind: "pay_statements" }, headers: employee_headers, as: :json
      expect_not_found
    end
  end

  describe "draft wording marker visibility" do
    it "hides the draft marker from regular employees and shows it only to staff or in development" do
      # Regular portal_employee in test env -> draft_marker is false
      get base, headers: employee_headers
      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Cache-Control")).to include("no-store")
      consents = response.parsed_body.fetch("consents")
      expect(consents.map { |c| c["kind"] }).to eq(%w[pay_statements w2gu])
      expect(consents.map { |c| c.dig("disclosure", "draft_marker") }).to eq([ false, false ])

      # Staff user linked to an employee record -> draft_marker is true while status is draft
      staff_employee = create(:employee, company: company)
      staff_link = link_to(staff_user, staff_employee)
      get base, headers: employee_headers(staff_link)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("consents").map { |c| c.dig("disclosure", "draft_marker") }).to eq([ true, true ])

      # In development env -> draft_marker is true even for portal_employee
      allow(Rails.env).to receive(:development?).and_return(true)
      get base, headers: employee_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("consents").map { |c| c.dig("disclosure", "draft_marker") }).to eq([ true, true ])
      allow(Rails.env).to receive(:development?).and_call_original

      # Once an approved disclosure is published, draft_marker becomes false even for staff
      DeliveryDisclosure.create!(
        kind: "pay_statements",
        version: "2027-01-15-approved-1",
        title: "Approved Pay Statements Consent",
        text: "Final counsel-approved pay statement consent text.",
        status: "approved",
        published_at: Time.current
      )
      get base, headers: employee_headers(staff_link)
      expect(response).to have_http_status(:ok)
      by_kind = response.parsed_body.fetch("consents").index_by { |c| c["kind"] }
      expect(by_kind.dig("pay_statements", "disclosure", "draft_marker")).to be(false)
      expect(by_kind.dig("w2gu", "disclosure", "draft_marker")).to be(true)
    end
  end

  describe "step-up verification and pay statements consent" do
    it "requires recent step-up verification when giving consent" do
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers(fva: [ 15, -1 ]), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("clerk_error", "metadata", "reverification")).to eq(
        "level" => "first_factor",
        "afterMinutes" => 10
      )
      expect(DeliveryConsent.count).to eq(0)
    end

    it "records exact disclosure version, digest, IP, user agent, method and keeps paper delivery on" do
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers, as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["paper_delivery_continues"]).to be(true)
      pay_item = body.fetch("consents").find { |c| c["kind"] == "pay_statements" }
      expect(pay_item["status"]).to eq("consented")
      expect(pay_item["paper_continues"]).to be(true)
      expect(pay_item["electronic_only_ready"]).to be(false)

      record = TenantScope.as_system(reason: "Verify consent row") { DeliveryConsent.where(employee: employee, kind: "pay_statements").sole }
      expect(record).to have_attributes(
        company_id: company.id,
        user_id: worker.id,
        employee_id: employee.id,
        employee_account_link_id: link.id,
        delivery_disclosure_id: disclosure.id,
        kind: "pay_statements",
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest,
        user_agent: "TestPhone/1.0",
        method: "employee_portal_checkbox",
        withdrawn_at: nil
      )
      expect(record.ip_address).to be_present
      expect(record.given_at).to be_present

      # Rejects mismatched digest/version
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: "0" * 64
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("disclosure_outdated")
    end
  end

  describe "W-2GU PDF access-proof step" do
    it "requires opening the test PDF and entering its code before recording W-2GU consent" do
      disclosure = DeliveryDisclosure.current_for("w2gu")

      # Missing access proof is rejected
      post base, params: {
        kind: "w2gu",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("access_proof_invalid")

      # Request the test PDF
      post "#{base}/w2gu_access_proof/pdf", headers: employee_headers, as: :json
      expect(response).to have_http_status(:ok)
      proof = response.parsed_body
      expect(proof["access_proof_token"]).to be_present
      expect(proof["filename"]).to eq("w2gu-pdf-access-check.pdf")
      code = extract_code_from_pdf(proof["pdf_base64"])

      # Wrong code is rejected
      post base, params: {
        kind: "w2gu",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest,
        access_proof_token: proof["access_proof_token"],
        access_proof_code: "WRONG1"
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("access_proof_invalid")

      # Token issued to another employee is rejected
      colleague = create(:user, company: company, role: "portal_employee", clerk_id: "user_w2_colleague")
      colleague_link = link_to(colleague, create(:employee, company: company))
      post base, params: {
        kind: "w2gu",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest,
        access_proof_token: proof["access_proof_token"],
        access_proof_code: code
      }, headers: employee_headers(colleague_link), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("access_proof_invalid")

      # Valid code from the PDF succeeds (even lowercase / spaced)
      post base, params: {
        kind: "w2gu",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest,
        access_proof_token: proof["access_proof_token"],
        access_proof_code: "#{code[0, 3]}-#{code[3, 3]}".downcase
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:created)

      w2_item = response.parsed_body.fetch("consents").find { |c| c["kind"] == "w2gu" }
      expect(w2_item["status"]).to eq("consented")
      expect(w2_item["email_notice_locked_on"]).to be(true)
      expect(w2_item["paper_continues"]).to be(true)

      record = TenantScope.as_system(reason: "Verify W-2GU consent row") { DeliveryConsent.where(employee: employee, kind: "w2gu").sole }
      expect(record).to have_attributes(
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest,
        method: "employee_portal_pdf_verified"
      )
      expect(record.access_proof_verified_at).to be_present
    end

    it "rejects an expired PDF access-proof token" do
      disclosure = DeliveryDisclosure.current_for("w2gu")
      post "#{base}/w2gu_access_proof/pdf", headers: employee_headers, as: :json
      proof = response.parsed_body
      code = extract_code_from_pdf(proof["pdf_base64"])

      travel 16.minutes do
        post base, params: {
          kind: "w2gu",
          acknowledged: true,
          disclosure_version: disclosure.version,
          disclosure_digest: disclosure.digest,
          access_proof_token: proof["access_proof_token"],
          access_proof_code: code
        }, headers: employee_headers, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["code"]).to eq("access_proof_invalid")
      end
    end
  end

  describe "one-tap withdrawal -> paper + staff notification + Changes to confirm" do
    it "withdraws in one tap without step-up, notifies Cornerstone staff, and adds to Changes to confirm" do
      PortalNotificationRecipient.create!(company: company, user: staff_user)
      disclosure = DeliveryDisclosure.current_for("pay_statements")

      # Give consent first (with fresh step-up)
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:created)

      # Withdraw in one tap even with an older fva (no step-up gate on withdrawal)
      post "#{base}/withdraw", params: { kind: "pay_statements" }, headers: employee_headers(fva: [ 25, -1 ]), as: :json
      expect(response).to have_http_status(:ok)

      pay_item = response.parsed_body.fetch("consents").find { |c| c["kind"] == "pay_statements" }
      expect(pay_item["status"]).to eq("withdrawn")
      expect(pay_item["active_consent"]).to be_nil
      expect(pay_item["last_withdrawn_at"]).to be_present
      expect(pay_item["paper_continues"]).to be(true)

      # Verify DB consent row
      record = TenantScope.as_system(reason: "Verify withdrawn consent") { DeliveryConsent.where(employee: employee, kind: "pay_statements").sole }
      expect(record.withdrawn_at).to be_present
      expect(record.withdrawn_by_user_id).to eq(worker.id)

      # Verify Changes-to-confirm row
      change_entry = TenantScope.as_system(reason: "Verify change to confirm") do
        EmployeeContactChangeToConfirm.where(company: company, employee: employee, change_kind: "delivery_consent").sole
      end
      expect(change_entry.before_values).to eq("pay_statements_delivery" => "Electronic consent on file (#{disclosure.version})")
      expect(change_entry.after_values).to eq("pay_statements_delivery" => "Paper delivery required (consent withdrawn)")

      # Verify existing Cornerstone staff notification was created
      event = TenantScope.as_system(reason: "Verify staff notification") do
        PortalNotificationEvent.where(company: company, event_type: "employee_contact_confirmation_requested", subject: change_entry).sole
      end
      expect(event.category).to eq("employee_changes")
      expect(event.recipient_status).to eq("recipients")

      # Verify Cornerstone staff can list and confirm the withdrawal even when profile_requests is off
      staff_headers = bearer(staff_user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => company.id.to_s)
      get "/api/v1/admin/employee_contact_changes_to_confirm", headers: staff_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").map { |row| row["id"] }).to eq([ change_entry.id ])

      patch "/api/v1/admin/employee_contact_changes_to_confirm/#{change_entry.id}/confirm", headers: staff_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("confirmed_count" => 1)

      # Repeat withdraw is idempotent: returns 200 with current status and no duplicate notice/queue row
      expect do
        post "#{base}/withdraw", params: { kind: "pay_statements" }, headers: employee_headers, as: :json
      end.not_to change {
        TenantScope.as_system(reason: "Check no duplicate withdrawal row") { EmployeeContactChangeToConfirm.count }
      }
      expect(response).to have_http_status(:ok)
      repeated_item = response.parsed_body.fetch("consents").find { |c| c["kind"] == "pay_statements" }
      expect(repeated_item["status"]).to eq("withdrawn")
    end
  end

  describe "staff employee record view" do
    it "includes ordered delivery consent status on GET /api/v1/admin/employees/:id" do
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      post base, params: {
        kind: "pay_statements",
        acknowledged: true,
        disclosure_version: disclosure.version,
        disclosure_digest: disclosure.digest
      }, headers: employee_headers, as: :json
      expect(response).to have_http_status(:created)

      staff_headers = bearer(staff_user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => company.id.to_s)
      get "/api/v1/admin/employees/#{employee.id}", headers: staff_headers
      expect(response).to have_http_status(:ok)

      summary = response.parsed_body.dig("data", "delivery_consents")
      expect(summary).to include("feature_enabled" => true, "paper_delivery_continues" => true)
      expect(summary["items"].map { |item| item["kind"] }).to eq(%w[pay_statements w2gu])
      pay_summary = summary["items"].first
      expect(pay_summary).to include(
        "kind" => "pay_statements",
        "status" => "consented",
        "disclosure_version" => disclosure.version,
        "disclosure_status" => "draft",
        "method" => "employee_portal_checkbox",
        "electronic_only_ready" => false,
        "paper_continues" => true
      )
      expect(summary["items"].last).to include("kind" => "w2gu", "status" => "not_consented")
    end
  end
end
