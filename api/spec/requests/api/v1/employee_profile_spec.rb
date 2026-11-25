# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee profile", :portal_notifications, type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:base) { "/api/v1/employee" }
  let(:company) { create(:company) }
  let(:worker) { create(:user, company: company, role: "portal_employee", clerk_id: "user_profile") }
  let(:employee) do
    create(:employee, company: company, first_name: "Example", last_name: "Worker", email: "original@example.test",
      email_verified_at: 1.day.ago, address_line1: "100 Example Lane", ssn_encrypted: "999-00-0001", payment_delivery_method: "paper_check")
  end
  let(:link) { link_to(worker, employee) }
  let(:reviewer) { create(:user, company: company, role: "client", clerk_id: "user_profile_reviewer") }
  let(:address) { { address_line1: "200 Example Lane", city: "Example City", state: "GU", zip: "96910" } }
  let(:contact) { { name: "Example Contact", relationship: "Family", phone: "6715550100" } }

  around do |example|
    settings = ENV.to_h.slice("REQUIRE_MFA", "EMPLOYEE_PORTAL_URL", "RLS_CONTEXT_GUARD_MODE")
    ENV.update("REQUIRE_MFA" => "true", "EMPLOYEE_PORTAL_URL" => EmployeeLinkHelpers::APP_URL, "RLS_CONTEXT_GUARD_MODE" => "raise")
    example.run
  ensure
    %w[REQUIRE_MFA EMPLOYEE_PORTAL_URL RLS_CONTEXT_GUARD_MODE].each { |key| ENV[key] = settings[key] }
  end

  before do
    @operating_profile = enable_profile(company)
    link
  end

  it "reads only its own profile with verification marks, masked identity and no cache" do
    get "#{base}/profile", headers: employee_headers
    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Cache-Control")).to include("no-store")
    expect(response.parsed_body).to include(
      "legal_name" => "Example Worker", "ssn_last4" => "0001", "email" => employee.email, "email_verified" => true,
      "phone_confirmed" => false, "payment_method" => "paper_check", "emergency_contacts" => [], "address_request" => nil
    )
    expect(response.body).not_to include("999-00-0001")
  end

  it "requires step-up on every write and uses the Clerk first-factor hint for an employee-only login" do
    writes.each do |verb, path|
      public_send(verb, "#{base}/#{path}", headers: employee_headers(fva: [ 11, -1 ]))
      expect(response).to have_http_status(:forbidden), "#{verb} #{path}"
      expect(response.parsed_body.dig("clerk_error", "metadata", "reverification")).to eq(
        "level" => "first_factor", "afterMinutes" => 10
      )
    end
  end

  it "requires a recent second factor for dual-role accounts and matches the web MFA codes" do
    dual_link = link_to(reviewer, create(:employee, company: company))
    patch "#{base}/profile/phone", headers: employee_headers(dual_link, fva: [ 0, 11 ])
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("clerk_error", "metadata", "reverification", "level")).to eq("second_factor")

    headers = bearer(reviewer.clerk_id).merge("X-Employee-Link-Id" => dual_link.id.to_s)
    patch "#{base}/profile/phone", headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("code")).to eq("mfa_required")

    ENV["REQUIRE_MFA"] = "false"
    patch "#{base}/profile/phone", headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("code")).to eq("mfa_enrollment_required")
  end

  it "returns the same empty 404 for all actions when the profile switch is off" do
    @operating_profile.update!(options: { "employee_portal" => { "features" => { "profile_requests" => false } } })
    ([ [ :get, "profile" ] ] + writes).each do |verb, path|
      public_send(verb, "#{base}/#{path}", headers: employee_headers)
      expect_not_found
    end
  end

  it "lets a former link read and gives the same empty 404 on every write" do
    link.update!(status: "former", former_access_until: 1.year.from_now)
    get "#{base}/profile", headers: employee_headers
    expect(response).to have_http_status(:ok)
    writes.each do |verb, path|
      public_send(verb, "#{base}/#{path}", headers: employee_headers)
      expect_not_found
    end
  end

  it "scopes employee reads and resource IDs to the authenticated user's selected link" do
    colleague = create(:user, company: company, role: "portal_employee", clerk_id: "user_profile_colleague")
    colleague_link = link_to(colleague, create(:employee, company: company))
    other_company = create(:company, organization: company.organization)
    enable_profile(other_company)
    other_link = link_to(worker, create(:employee, company: other_company, email: "other-job@example.test"))
    [ colleague_link, other_link ].each do |foreign_link|
      post "#{base}/emergency_contacts", params: contact, headers: employee_headers(foreign_link), as: :json
      foreign_contact_id = response.parsed_body.dig("emergency_contacts", 0, "id")
      expect(response).to have_http_status(:created), response.body
      post "#{base}/address_requests", params: { address: address }, headers: employee_headers(foreign_link), as: :json
      expect(response).to have_http_status(:created), response.body
      foreign_request_id = response.parsed_body.dig("address_request", "id")

      delete "#{base}/emergency_contacts/#{foreign_contact_id}", headers: employee_headers
      expect_not_found
      patch "#{base}/address_requests/#{foreign_request_id}", params: { address: address }, headers: employee_headers, as: :json
      expect_not_found
      delete "#{base}/address_requests/#{foreign_request_id}", headers: employee_headers
      expect_not_found
    end

    get "#{base}/profile", headers: employee_headers(colleague_link, subject: worker.clerk_id)
    expect_not_found
    get "#{base}/profile", headers: employee_headers(other_link)
    expect(response.parsed_body.fetch("email")).to eq("other-job@example.test")
    get "#{base}/profile", headers: employee_headers
    expect(response.parsed_body).to include("email" => employee.email, "emergency_contacts" => [], "address_request" => nil)
  end

  it "applies a phone edit, ignores identity fields, and audits and queues the applied change" do
    patch "#{base}/profile/phone", headers: employee_headers, params: {
      phone: "671-555-0100", first_name: "Changed", ssn: "999-00-0002"
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("phone" => "+16715550100", "phone_confirmed" => true,
      "legal_name" => "Example Worker", "ssn_last4" => "0001")
    expect(employee.reload).to have_attributes(phone: "+16715550100", contact_source: "employee")
    entry = EmployeeContactChangeToConfirm.where(employee: employee).sole
    expect(entry.after_values).to eq("phone" => "+16715550100")
    expect(audits("profile#update_phone").sole.record_id).to eq(employee.id)
  end

  it "adds, reads, edits and removes an emergency contact and records each change" do
    post "#{base}/emergency_contacts", params: contact, headers: employee_headers, as: :json
    expect(response).to have_http_status(:created), response.body
    id = response.parsed_body.dig("emergency_contacts", 0, "id")
    get "#{base}/profile", headers: employee_headers
    expect(response.parsed_body.fetch("emergency_contacts")).to eq([ contact.stringify_keys.merge("id" => id, "phone" => "+16715550100") ])
    patch "#{base}/emergency_contacts/#{id}", params: { relationship: "Friend" }, headers: employee_headers, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("emergency_contacts", 0, "relationship")).to eq("Friend")
    delete "#{base}/emergency_contacts/#{id}x", headers: employee_headers
    expect_not_found
    delete "#{base}/emergency_contacts/#{id}", headers: employee_headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("emergency_contacts")).to be_empty
    expect(EmployeeContactChangeToConfirm.where(employee: employee).order(:id).map { |entry| entry.after_values["emergency_contacts"] })
      .to eq([ [ contact.stringify_keys.merge("id" => id, "phone" => "+16715550100") ],
        [ contact.stringify_keys.merge("id" => id, "phone" => "+16715550100", "relationship" => "Friend") ], nil ])
    expect(%w[create update destroy].map { |action| audits("emergency_contacts##{action}").sole.record_id }).to eq([ id.to_i ] * 3)
  end

  it "requires the emailed code, prevents resend during cooldown, consumes success and leaves the Clerk login alone" do
    with_portal_email(enabled: false) do
      id, code = start_email
      expect(employee.reload.email).to eq("original@example.test")
      post "#{base}/profile/email", headers: employee_headers, params: { email: "another@example.test" }, as: :json
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers.fetch("Retry-After").to_i).to be_positive
      expect(captured_portal_emails.size).to eq(1)
      confirm_email(id, wrong_code(code))
      expect(response).to have_http_status(:unprocessable_entity)
      confirm_email(id, code)
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body).to include("email" => "new@example.test", "email_verified" => true)
      expect(worker.reload.email).not_to eq(employee.reload.email)
      expect(audits("profile#confirm_email").sole.metadata.values).not_to include(code, "new@example.test")
      confirm_email(id, code)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  it "rejects exhausted, expired or superseded codes" do
    with_portal_email do
      id, code = start_email
      5.times { confirm_email(id, wrong_code(code)) }
      confirm_email(id, code)
      expect(response).to have_http_status(:unprocessable_entity)

      travel 1.minute + 1.second
      expired_id, expired_code = start_email
      travel 10.minutes
      confirm_email(expired_id, expired_code)
      expect(response).to have_http_status(:unprocessable_entity)

      id, code = start_email
      travel 1.minute + 1.second
      new_id, new_code = start_email("second@example.test")
      confirm_email(id, code)
      expect(response).to have_http_status(:unprocessable_entity)
      confirm_email(new_id, new_code)
      expect(response).to have_http_status(:ok), response.body
    end
  end

  it "cannot verify a code from another link or overwrite an intervening staff email edit" do
    other_company = create(:company, organization: company.organization)
    enable_profile(other_company)
    other_link = link_to(worker, create(:employee, company: other_company))
    with_portal_email do
      id, code = start_email
      confirm_email(id, code, headers: employee_headers(other_link))
      expect(response).to have_http_status(:unprocessable_entity)

      employee.update!(email: "staff-edit@example.test")
      confirm_email(id, code)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload.email).to eq("staff-edit@example.test")
    end
  end

  it "uses the M4-3 guard and cooldown when a login address is repeatedly rejected" do
    other_login = reviewer
    with_portal_email do
      EmployeeContactLoginRejectionGuard::LOGIN_EMAIL_REJECTION_LIMIT.times do
        post "#{base}/profile/email", headers: employee_headers, params: { email: other_login.email }, as: :json
        expect(response).to have_http_status(:unprocessable_entity), response.body
        expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
      end
      post "#{base}/profile/email", headers: employee_headers, params: { email: "new@example.test" }, as: :json
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.fetch("code")).to eq("contact_email_rate_limited")
      expect(captured_portal_emails).to be_empty
      patch "#{base}/profile/phone", headers: employee_headers, params: { phone: "6715550100" }, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  it "shows a pending client's request without exposing it or accepting a second request" do
    existing = create(:employee_change_request, company: company, employee: employee, requested_by: reviewer)
    get "#{base}/profile", headers: employee_headers
    expect(response.parsed_body).to include("address_request" => nil, "other_request_pending" => true)
    post "#{base}/address_requests", params: { address: address }, headers: employee_headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "A change is already being reviewed")
    delete "#{base}/address_requests/#{existing.id}", headers: employee_headers
    expect_not_found
    expect(existing.reload).to be_pending
  end

  it "lets the owner edit and cancel their pending address request, freeing the single pending slot" do
    id = submit_address
    patch "#{base}/address_requests/#{id}", params: { address: address.merge(address_line2: "Unit 2") },
      headers: employee_headers, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("address_request", "requested", "address_line2")).to eq("Unit 2")
    expect(employee.reload.address_line1).to eq("100 Example Lane")
    delete "#{base}/address_requests/#{id}", headers: employee_headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("address_request" => nil, "other_request_pending" => false)
    expect(EmployeeChangeRequest.exists?(id)).to be(false)
    expect(%w[create update destroy].map { |action| audits("address_requests##{action}").sole.record_id }).to eq([ id.to_i ] * 3)
    expect(submit_address).not_to eq(id)
  end

  it "blocks client payroll changes while the employee request is pending and applies the address on client approval" do
    reviewer
    id = submit_address
    patch "/api/v1/client/employees/#{employee.id}", headers: client_headers,
      params: { employee: { pay_rate: 40 } }, as: :json
    expect(response).to have_http_status(:conflict), response.body
    expect(response.parsed_body).to include("code" => "address_request_pending", "pending_request_id" => id.to_i)

    patch "/api/v1/client/employee_change_requests/#{id}/approve", headers: client_headers
    expect(response).to have_http_status(:ok), response.body
    get "#{base}/profile", headers: employee_headers
    expect(response.parsed_body.fetch("address")).to include(address.stringify_keys)
    expect(response.parsed_body.fetch("address_request")).to include("status" => "approved", "decided_at" => a_kind_of(String))
    expect(EmployeeChangeRequest.find(id)).to have_attributes(requested_by_link_id: link.id, requested_by_id: worker.id)
    expect(EmployeeContactChangeToConfirm.where(employee: employee).sole.change_kind).to eq("address")
    delete "#{base}/address_requests/#{id}", headers: employee_headers
    expect_not_found
  end

  it "keeps the self-approval guard for a dual-role account and shares the rejected decision" do
    own_client = create(:user, company: company, role: "client", clerk_id: "user_profile_own_client")
    own_link = link_to(own_client, create(:employee, company: company))
    id = submit_address(own_link)
    patch "/api/v1/client/employee_change_requests/#{id}/approve", headers: client_headers(own_client)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    patch "/api/v1/client/employee_change_requests/#{id}/reject", headers: client_headers, params: { review_notes: "Check the unit number" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    get "#{base}/profile", headers: employee_headers(own_link)
    expect(response.parsed_body.fetch("address_request")).to include("status" => "rejected", "decision_note" => "Check the unit number")
    event = PortalNotificationEvent.find_by!(subject_id: id, event_type: "employee_address_decided")
    expect(event.deliveries.sole.skip_reason).to eq("no_recipients")
  end

  it "sends address approval, contact-change and decision notices to the right audiences without contact or decision details" do
    reviewer
    staff = create(:user, company: company, role: "manager")
    create(:company_assignment, company: company, user: staff)
    list_portal_recipient!(company, user: staff)
    unlisted = create(:user, company: company, role: "admin")
    with_portal_email do
      patch "#{base}/profile/phone", headers: employee_headers, params: { phone: "6715550100" }, as: :json
      expect(response).to have_http_status(:ok)
      id = submit_address
      matching = ->(type) { PortalNotificationEvent.where(event_type: type).sole.deliveries.order(:id) }
      expect(matching.call("employee_change_submitted").pluck(:user_id)).to eq([ staff.id ])
      expect(matching.call("address_approval_requested").pluck(:user_id)).to eq([ reviewer.id ])
      expect(matching.call("employee_contact_changed").pluck(:user_id)).to eq([ reviewer.id ])
      expect(matching.call("employee_contact_confirmation_requested").pluck(:user_id)).to eq([ staff.id ])
      PortalNotifications::Dispatcher.run!(now: 2.days.from_now)
      expect(captured_portal_emails.pluck(:to).flatten).not_to include(unlisted.email, worker.email)
      expect(captured_portal_emails.pluck(:text).join).to include("/companies/#{company.id}/contact-changes-to-confirm")
      expect(captured_portal_emails.flat_map { |message| message.values_at(:subject, :text, :html) }.join)
        .not_to match(/Example Worker|200 Example Lane|5550100|999-00-0001/)
      PortalNotifications::Transport.clear_captured!

      patch "/api/v1/client/employee_change_requests/#{id}/reject", headers: client_headers,
        params: { review_notes: "Check 200 Example Lane" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(matching.call("employee_address_decided").sole).to have_attributes(user_id: nil, recipient_email: employee.email)
      PortalNotifications::Dispatcher.run!(now: 2.days.from_now)
      expect(captured_portal_emails.sole).to include(to: employee.email)
      expect(captured_portal_emails.sole.fetch(:text)).to include(EmployeeLinkHelpers::APP_URL)
      expect(captured_portal_emails.sole.values_at(:subject, :text, :html).join)
        .not_to match(/Example Worker|200 Example Lane|Check 200|5550100|999-00-0001/)
    end
  end

  def enable_profile(company)
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_portals", hours_source: "manual",
      client_portal_enabled: true, employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "profile_requests" => true } } }
    )
  end

  def link_to(user, employee)
    EmployeeAccountLink.create!(user: user, company: employee.company, employee: employee, status: "active")
  end

  def employee_headers(selected_link = link, subject: selected_link.user.clerk_id, fva: nil)
    employee_only = selected_link.user.portal_employee?
    bearer(subject, fva: fva || (employee_only ? [ 0, -1 ] : [ 0, 0 ]), two_factor_enabled: !employee_only)
      .merge("X-Employee-Link-Id" => selected_link.id.to_s)
  end

  def client_headers(user = reviewer)
    bearer(user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => company.id.to_s)
  end

  def writes
    [ [ :patch, "profile/phone" ], [ :post, "profile/email" ], [ :post, "profile/email/confirm" ],
      [ :post, "emergency_contacts" ], [ :patch, "emergency_contacts/1" ], [ :delete, "emergency_contacts/1" ],
      [ :post, "address_requests" ], [ :patch, "address_requests/1" ], [ :delete, "address_requests/1" ] ]
  end

  def expect_not_found
    expect([ response.status, response.body ]).to eq([ 404, "" ])
  end

  def audits(action)
    AuditLog.where(company: company, action: "employee_portal/#{action}").order(:id)
  end

  def start_email(email = "new@example.test")
    post "#{base}/profile/email", headers: employee_headers, params: { email: email }, as: :json
    expect(response).to have_http_status(:accepted), response.body
    delivery = captured_portal_emails.last
    expect(delivery.fetch(:to)).to eq([ email ])
    expect(delivery.fetch(:text)).not_to include(employee.full_name, employee.email.to_s)
    [ response.parsed_body.fetch("verification_id"), delivery.fetch(:text)[/code is ([0-9]{6})/, 1] ]
  end

  def confirm_email(id, code, headers: employee_headers)
    post "#{base}/profile/email/confirm", headers: headers, params: { verification_id: id, code: code }, as: :json
  end

  def wrong_code(code)
    code == "000000" ? "000001" : "000000"
  end

  def submit_address(selected_link = link)
    post "#{base}/address_requests", params: { address: address.merge(first_name: "Ignore", pay_rate: 90) },
      headers: employee_headers(selected_link), as: :json
    expect(response).to have_http_status(:created), response.body
    request = response.parsed_body.fetch("address_request")
    expect(request).to include("status" => "pending", "requested" => address.stringify_keys.merge("address_line2" => nil))
    request.fetch("id")
  end
end
