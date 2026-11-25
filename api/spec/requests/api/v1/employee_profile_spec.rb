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

  it "reads only its own profile with verification marks, no SSN fields and no cache" do
    get "#{base}/profile", headers: employee_headers
    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Cache-Control")).to include("no-store")
    expect(response.parsed_body).to include(
      "legal_name" => "Example Worker", "email" => employee.email, "email_verified" => true,
      "phone_confirmed" => false, "payment_method" => "paper_check", "emergency_contacts" => [], "address_request" => nil
    )
    expect(response.parsed_body).not_to have_key("ssn_last4")
    expect(response.body).not_to include("999-00-0001")
  end

  it "requires a second-factor step-up on every write for an employee-only login when MFA is on" do
    writes.each do |verb, path|
      public_send(verb, "#{base}/#{path}", headers: employee_headers(fva: [ 0, 11 ]))
      expect(response).to have_http_status(:forbidden), "#{verb} #{path}"
      expect(response.parsed_body.dig("clerk_error", "metadata", "reverification")).to eq(
        "level" => "second_factor", "afterMinutes" => 10
      )
    end
  end

  it "sends an employee-only login with no second factor to enrollment when MFA is on" do
    get "#{base}/profile", headers: employee_headers(fva: [ 0, -1 ], two_factor_enabled: false)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("code")).to eq("mfa_enrollment_required")
  end

  it "asks an enrolled employee login that skipped the second step to finish it" do
    get "#{base}/profile", headers: employee_headers(fva: [ 0, -1 ], two_factor_enabled: true)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("code")).to eq("mfa_required")
  end

  it "uses the Clerk first-factor hint on every write while MFA is off" do
    ENV["REQUIRE_MFA"] = "false"
    writes.each do |verb, path|
      public_send(verb, "#{base}/#{path}", headers: employee_headers(fva: [ 11, -1 ], two_factor_enabled: false))
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
    expect(response.parsed_body.fetch("code")).to eq("mfa_enrollment_required")

    patch "#{base}/profile/phone", headers: bearer(reviewer.clerk_id, two_factor_enabled: true).merge("X-Employee-Link-Id" => dual_link.id.to_s)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("code")).to eq("mfa_required")

    # With MFA off nobody is sent to enrollment; a fresh password is the step-up.
    ENV["REQUIRE_MFA"] = "false"
    patch "#{base}/profile/phone", headers: bearer(reviewer.clerk_id, fva: [ 11, -1 ]).merge("X-Employee-Link-Id" => dual_link.id.to_s)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("clerk_error", "metadata", "reverification", "level")).to eq("first_factor")
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
      "legal_name" => "Example Worker")
    expect(employee.reload).to have_attributes(phone: "+16715550100", contact_source: "employee")
    entry = EmployeeContactChangeToConfirm.where(employee: employee).sole
    expect(entry.after_values).to eq("phone" => "+16715550100")
    expect(audits("profile#update_phone").sole.record_id).to eq(employee.id)
  end

  it "soft-deletes an emergency contact and retains its change history and audit" do
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
    expect(EmployeeEmergencyContact.find(id)).to have_attributes(deleted_at: be_present, relationship: "Friend")
    get "#{base}/profile", headers: employee_headers
    expect(response.parsed_body.fetch("emergency_contacts")).to be_empty
    patch "#{base}/emergency_contacts/#{id}", params: { relationship: "Family" }, headers: employee_headers, as: :json
    expect_not_found
    delete "#{base}/emergency_contacts/#{id}", headers: employee_headers
    expect_not_found
    expect(EmployeeContactChangeToConfirm.where(employee: employee).order(:id).map { |entry| entry.after_values["emergency_contacts"] })
      .to eq([ [ contact.stringify_keys.merge("id" => id, "phone" => "+16715550100") ],
        [ contact.stringify_keys.merge("id" => id, "phone" => "+16715550100", "relationship" => "Friend") ], nil ])
    expect(%w[create update destroy].map { |action| audits("emergency_contacts##{action}").sole.record_id }).to eq([ id.to_i ] * 3)
  end

  it "caps emergency contacts at five and frees a slot when an employee removes one" do
    5.times do
      post "#{base}/emergency_contacts", params: contact, headers: employee_headers, as: :json
      expect(response).to have_http_status(:created), response.body
    end
    first_id = response.parsed_body.fetch("emergency_contacts").first.fetch("id")

    post "#{base}/emergency_contacts", params: contact, headers: employee_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("You can save up to five emergency contacts.")
    expect(EmployeeEmergencyContact.where(employee: employee).count).to eq(5)

    delete "#{base}/emergency_contacts/#{first_id}", headers: employee_headers
    expect(response).to have_http_status(:ok)
    post "#{base}/emergency_contacts", params: contact, headers: employee_headers, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("emergency_contacts").size).to eq(5)
    expect(EmployeeEmergencyContact.where(employee: employee).count).to eq(6)
  end

  it "keeps emergency contact changes in client activity and the audit without adding staff work or alerts" do
    reviewer
    staff = create(:user, company: company, role: "admin", clerk_id: "user_profile_staff")
    list_portal_recipient!(company, user: staff)
    with_portal_email do
      post "#{base}/emergency_contacts", params: contact, headers: employee_headers, as: :json
      expect(response).to have_http_status(:created), response.body
      entry = EmployeeContactChangeToConfirm.where(employee: employee).sole
      expect(audits("emergency_contacts#create")).to exist
      event = PortalNotificationEvent.where(subject: entry).sole
      expect(event).to have_attributes(category: "contact_changes", audience: "client")
      expect(event.deliveries.pluck(:user_id)).to eq([ reviewer.id ])
      legacy_staff_event = PortalNotificationEvent.new(
        company: company, subject: entry, event_type: "employee_contact_confirmation_requested"
      )
      expect(PortalNotifications::Recipients).not_to be_subject_available(legacy_staff_event)
      expect(EmployeeContactChangeToConfirm.unconfirmed_count(company)).to eq(0)

      get "/api/v1/admin/employee_contact_changes_to_confirm", headers: client_headers(staff)
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("data")).to be_empty
      patch "/api/v1/admin/employee_contact_changes_to_confirm/#{entry.id}/confirm", headers: client_headers(staff)
      expect_not_found

      get "/api/v1/client/employee_change_requests/contact_changes", headers: client_headers
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("data").pluck("id")).to eq([ entry.id ])
    end
  end

  it "persists the challenge before delivery, then clears it in a separate transaction after a timeout" do
    transport = PortalNotifications::Transport
    connection = ActiveRecord::Base.connection
    transaction_depth = connection.open_transactions
    allow(transport).to receive(:configured?).and_return(true)
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout).with(10.seconds, Timeout::Error).and_call_original
    expect(transport).to receive(:deliver) do |_, idempotency_key:|
      expect(connection.open_transactions).to eq(transaction_depth)
      saved_id = JSON.parse(link.reload.profile_email_challenge).fetch("id")
      expect(idempotency_key).to eq("employee-profile-email:#{saved_id}")
      raise Net::ReadTimeout
    end

    post "#{base}/profile/email", headers: employee_headers, params: { email: "new@example.test" }, as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(link.reload.profile_email_challenge).to be_nil
    expect(link.profile_email_daily_codes).to eq(1)
  end

  it "allows five codes per link per Guam day, including confirmation of the fifth code" do
    travel_to guam_late_evening
    other_link = link_to(worker, create(:employee, company: company))
    with_portal_email do
      4.times do
        start_email
        travel 1.minute + 1.second
      end
      id, code = start_email
      travel 1.minute + 1.second
      [ "another@example.test", "invalid address" ].each do |email|
        post "#{base}/profile/email", headers: employee_headers, params: { email: email }, as: :json
        expect_daily_limit
      end
      expect(captured_portal_emails.size).to eq(5)
      confirm_email(id, code)
      expect(response).to have_http_status(:ok), response.body

      post "#{base}/profile/email", headers: employee_headers(other_link), params: { email: "other-link@example.test" }, as: :json
      expect(response).to have_http_status(:accepted), response.body

      travel_to guam_late_evening.tomorrow.beginning_of_day
      start_email("tomorrow@example.test")
    end
  end

  it "caps wrong attempts across codes without revealing whether an ID is active" do
    travel_to guam_late_evening
    with_portal_email do
      2.times do
        id, code = start_email
        5.times do
          confirm_email(id, wrong_code(code))
          expect(response).to have_http_status(:unprocessable_entity)
        end
        travel 1.minute + 1.second
      end
      id, code = start_email
      4.times do
        confirm_email("unknown-id", wrong_code(code))
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("error")).to eq("The verification code is invalid or expired.")
      end
      confirm_email(id, wrong_code(code))
      expect_daily_limit
      [ id, "unknown-id" ].each do |verification_id|
        confirm_email(verification_id, code)
        expect_daily_limit
      end
      post "#{base}/profile/email", headers: employee_headers, params: { email: "new@example.test" }, as: :json
      expect_daily_limit
      expect(employee.reload.email).to eq("original@example.test")

      travel_to guam_late_evening.tomorrow.beginning_of_day
      id, code = start_email
      confirm_email(id, code)
      expect(response).to have_http_status(:ok), response.body
    end
  end

  it "refuses shared and generic inboxes without sending a code or identifying the other employee" do
    create(:employee, company: company, email: "shared@example.test")
    with_portal_email do
      [ "shared@example.test", "noreply@example.test" ].each do |email|
        post "#{base}/profile/email", headers: employee_headers, params: { email: email }, as: :json
        expect(response).to have_http_status(:unprocessable_entity), response.body
        expect(response.parsed_body).to eq("error" => "Use a personal email address that only you can access.",
          "code" => "personal_email_required")
      end
      expect(captured_portal_emails).to be_empty
    end
  end

  it "rechecks shared inboxes before applying a verified email" do
    with_portal_email do
      id, code = start_email
      create(:employee, company: company, email: "new@example.test")
      confirm_email(id, code)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("code")).to eq("personal_email_required")
      expect(employee.reload.email).to eq("original@example.test")
    end
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

  it "replaces an edited address, sends fresh notices, and refuses stale decisions from client and staff reviewers" do
    staff = create(:user, company: company, role: "admin", clerk_id: "user_profile_staff")
    list_portal_recipient!(company, user: staff)
    reviewer
    with_portal_email do
      id = submit_address
      admin_path = "/api/v1/admin/employee_change_requests"
      client_path = "/api/v1/client/employee_change_requests"
      reviewers = { admin_path => staff, client_path => reviewer }
      reviewers.each do |path, actor|
        get "#{path}/#{id}", headers: client_headers(actor)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch("data")).to include("can_review" => true, "status" => "pending", "note_visible_to_employee" => true)
      end

      patch "#{base}/address_requests/#{id}", params: { address: address.merge(address_line2: "Unit 2") },
        headers: employee_headers, as: :json
      expect(response).to have_http_status(:ok), response.body
      replacement = response.parsed_body.fetch("address_request")
      new_id = replacement.fetch("id")
      expect(new_id).not_to eq(id)
      expect(replacement.dig("requested", "address_line2")).to eq("Unit 2")
      expect(EmployeeChangeRequest.find(id)).to be_cancelled
      expect(EmployeeChangeRequest.find(id).proposed_changes.fetch("address_line2")).to be_nil
      expect(audits("address_requests#update").sole.record_id).to eq(new_id.to_i)
      replacement_events = PortalNotificationEvent.where(subject_type: "EmployeeChangeRequest", subject_id: new_id)
      expect(replacement_events.pluck(:event_type)).to contain_exactly("employee_change_submitted", "address_approval_requested")
      PortalNotifications::Dispatcher.run!(now: 2.days.from_now)
      expect(replacement_events.flat_map { |event| event.deliveries.pluck(:status, :user_id) })
        .to contain_exactly([ "sent", staff.id ], [ "sent", reviewer.id ])
      original_events = PortalNotificationEvent.where(subject_type: "EmployeeChangeRequest", subject_id: id)
      expect(original_events.flat_map { |event| event.deliveries.pluck(:skip_reason) }).to eq([ "resource_unavailable" ] * 2)

      reviewers.each do |path, actor|
        %w[approve reject].each do |decision|
          patch "#{path}/#{id}/#{decision}", headers: client_headers(actor)
          expect(response).to have_http_status(:conflict), response.body
        end
        get "#{path}/#{id}", headers: client_headers(actor)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch("data")).to include("status" => "cancelled", "can_review" => false)
      end
      expect(employee.reload.address_line1).to eq("100 Example Lane")
      expect(EmployeeChangeRequest.pending.where(employee: employee).sole.id).to eq(new_id.to_i)

      patch "#{client_path}/#{new_id}/approve", headers: client_headers
      expect(response).to have_http_status(:ok), response.body
      expect(employee.reload.address_line2).to eq("Unit 2")
    end
  end

  it "keeps an address request pending when an edit would overwrite a staff correction" do
    employee.update!(address_line2: "Unit 1")
    id = submit_address
    employee.update!(address_line2: "Unit 2")

    patch "#{base}/address_requests/#{id}", params: { address: address.merge(address_line1: "300 Example Lane", address_line2: "Unit 1") },
      headers: employee_headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq(
      "code" => "address_on_file_changed",
      "error" => "Your address on file was updated after you sent this request. Cancel this request, then send a new one if your address still needs to change."
    )
    expect(EmployeeChangeRequest.where(employee: employee).sole).to have_attributes(id: id.to_i, status: "pending")
    expect(employee.reload.address_line2).to eq("Unit 2")
    expect(audits("address_requests#update")).to be_empty
  end

  it "replaces a pending address request when the address on file only changed formatting" do
    employee.update!(state: "GU", address_line2: nil)
    id = submit_address
    employee.update!(state: " gu ", address_line2: " ", address_line1: " 100 Example Lane ")

    patch "#{base}/address_requests/#{id}", params: { address: address.merge(address_line2: "Unit 2") },
      headers: employee_headers, as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(EmployeeChangeRequest.find(id)).to be_cancelled
    expect(response.parsed_body.dig("address_request", "requested", "address_line2")).to eq("Unit 2")
  end

  it "keeps a cancelled address request in review history and frees the pending slot" do
    id = submit_address
    delete "#{base}/address_requests/#{id}", headers: employee_headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("address_request" => nil, "other_request_pending" => false)
    expect(EmployeeChangeRequest.find(id)).to be_cancelled
    expect(audits("address_requests#destroy").sole.record_id).to eq(id.to_i)

    get "/api/v1/client/employee_change_requests", params: { status: "cancelled" }, headers: client_headers
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ id.to_i ])
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
    ).tap { activate_employee_app!(company) }
  end

  def link_to(user, employee)
    EmployeeAccountLink.create!(user: user, company: employee.company, employee: employee, status: "active")
  end

  # REQUIRE_MFA is on here, so every login, employee-only ones included, has
  # an enrolled, freshly verified second factor.
  def employee_headers(selected_link = link, subject: selected_link.user.clerk_id, fva: nil, two_factor_enabled: true)
    bearer(subject, fva: fva || [ 0, 0 ], two_factor_enabled: two_factor_enabled)
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

  # 23:50 on a coming Guam day: after the links the before block makes, so
  # the spec doesn't depend on today's date.
  def guam_late_evening
    @guam_late_evening ||= Time.current.in_time_zone("Pacific/Guam").tomorrow.change(hour: 23, min: 50)
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

  def expect_daily_limit
    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to eq("error" => "Too many verification tries today. Try again tomorrow.",
      "code" => "email_code_daily_limit")
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
