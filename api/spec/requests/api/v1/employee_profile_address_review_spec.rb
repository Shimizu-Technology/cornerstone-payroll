# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee profile address review", :portal_notifications, type: :request do
  let(:requests_path) { "/api/v1/client/employee_change_requests" }
  let(:confirm_path) { "/api/v1/admin/employee_contact_changes_to_confirm" }
  let(:old_address) { "100 Example Lane" }
  let(:new_address) { "200 Example Lane" }

  around do |example|
    keys = %w[AUTH_ENABLED REQUIRE_MFA EMPLOYEE_PORTAL_URL]
    previous = ENV.to_h.slice(*keys)
    ENV.update("AUTH_ENABLED" => "true", "REQUIRE_MFA" => "true", "EMPLOYEE_PORTAL_URL" => "https://employee.example.test")
    example.run
  ensure
    keys.each { |key| ENV[key] = previous[key] }
  end

  before do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
    system_read do
      @company = create(:company)
      @other_company = create(:company, organization: @company.organization)
      @requester = create(:user, company: @company, role: "client", name: "Demo Requester", clerk_id: "user_address_requester")
      @reviewer = create(:user, company: @company, role: "client", clerk_id: "user_address_reviewer")
      @staff = create(:user, company: @company, role: "admin", clerk_id: "user_address_staff")
      @employee = create(:employee, company: @company, first_name: "Demo", last_name: "Requester", address_line1: old_address)
      @coworker = create(:employee, company: @company, address_line1: old_address)
      @foreign_employee = create(:employee, company: @other_company, address_line1: old_address)
      @profile = enable_requests(@company)
      enable_requests(@other_company)
    end
    verifier = instance_double(ClerkTokenVerifier)
    allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
    [ @requester, @reviewer, @staff ].each do |user|
      allow(verifier).to receive(:verify).with("synthetic.#{user.id}").and_return(
        { "sub" => user.clerk_id, "fva" => [ 0, 0 ], "two_factor_enabled" => true }
      )
    end
  end

  it "queues an admin's own address even when that login also has a link at another company" do
    system_read do
      link(@requester, @employee)
      link(@requester, @foreign_employee)
    end
    with_portal_email(enabled: false) do
      patch_employee(@employee, @requester, address_line1: new_address, phone: "6715550100")
    end
    expect(response).to have_http_status(:ok), response.body
    id = response.parsed_body.dig("change_request", "id")
    system_read do
      expect(@employee.reload.address_line1).to eq(old_address)
      expect(EmployeeChangeRequest.find(id)).to be_own_record
      expect(EmployeeContactChangeToConfirm.where(employee: @employee).pluck(:change_kind)).to eq([ "contact" ])
      expect(PortalNotificationEvent.find_by!(subject_id: id, event_type: "address_approval_requested").deliveries.pluck(:status)).to eq([ "skipped" ])
    end

    patch "#{requests_path}/#{id}/approve", headers: headers(@requester)
    expect(response).to have_http_status(:unprocessable_entity)

    get requests_path, headers: headers(@reviewer), params: { search: "  Demo Requester  " }
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ id ])
    get "#{requests_path}/#{id}", headers: headers(@reviewer)
    expect(response.parsed_body.fetch("data")).to include("can_review" => true, "original_values" => { "address_line1" => old_address })
    expect(response.parsed_body.fetch("data")).not_to have_key("direct_changes_applied")
    observer = system_read { create(:user, company: @company, role: "client") }
    patch "#{requests_path}/#{id}/approve", headers: headers(@reviewer)
    expect(response).to have_http_status(:ok), response.body
    system_read do
      expect(@employee.reload.address_line1).to eq(new_address)
      entry = EmployeeContactChangeToConfirm.find_by!(employee: @employee, change_kind: "address")
      expect(entry).to have_attributes(changed_by: @requester, before_values: { "address_line1" => old_address },
        after_values: { "address_line1" => new_address })
      activity = PortalNotificationEvent.find_by!(subject: entry, event_type: "employee_contact_changed")
      expect(activity.deliveries.pluck(:user_id)).to eq([ observer.id ])
      decision = PortalNotificationEvent.find_by!(subject_type: "EmployeeChangeRequest", subject_id: id, event_type: "employee_change_decided")
      expect(decision.deliveries.pluck(:user_id)).to eq([ @requester.id ])
    end
  end

  it "routes same-person confirmations through review and allows Cornerstone to reject" do
    patch_employee(@employee, @requester, email: @requester.email, confirm_same_person_email: true, address_line1: new_address)
    expect(response).to have_http_status(:ok), response.body
    id = response.parsed_body.dig("change_request", "id")
    patch "/api/v1/admin/employee_change_requests/#{id}/reject", headers: headers(@staff), params: { review_notes: "Update the unit number" }
    expect(response).to have_http_status(:ok), response.body
    system_read do
      expect(@employee.reload.address_line1).to eq(old_address)
      expect(EmployeeChangeRequest.find(id)).to be_rejected
      expect(EmployeeContactChangeToConfirm.where(change_kind: "address")).to be_empty
    end
  end

  it "blocks a different login with a recorded same-person confirmation from deciding" do
    address_request = system_read do
      address_request_for(@coworker).tap do
        AuditLog.record!(user: @staff, company_id: @company.id, action: "employees#confirm_same_person_email",
          record_type: "employees", record_id: @coworker.id,
          metadata: { confirmed_login_user_id: @reviewer.id, same_person_email_confirmed: true })
      end
    end
    patch "#{requests_path}/#{address_request.id}/reject", headers: headers(@reviewer)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(system_read { address_request.reload }).to be_pending
  end

  it "exposes an employee address request, but hides another client's payroll request and foreign ids" do
    address_request, payroll_request, foreign_request = system_read do
      [ address_request_for(@employee),
        create(:employee_change_request, employee: @coworker, company: @company, requested_by: @requester),
        address_request_for(@foreign_employee) ]
    end
    get requests_path, headers: headers(@reviewer)
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ address_request.id ])
    [ payroll_request, foreign_request ].each do |record|
      get "#{requests_path}/#{record.id}", headers: headers(@reviewer)
      expect(response).to have_http_status(:not_found)
      patch "#{requests_path}/#{record.id}/approve", headers: headers(@reviewer)
      expect(response).to have_http_status(:not_found)
    end
    patch "#{requests_path}/#{payroll_request.id}/reject", headers: headers(@requester)
    expect(response).to have_http_status(:not_found)

    patch_employee(@employee, @reviewer, pay_rate: 40)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("code" => "address_request_pending", "pending_request_id" => address_request.id)
  end

  it "refuses a tagged request with a sensitive payload or a non-address field" do
    change_request = system_read do
      address_request_for(@employee).tap do |record|
        record.update_columns(proposed_changes: { address_line1: new_address, pay_rate: 40 })
      end
    end
    patch "#{requests_path}/#{change_request.id}/approve", headers: headers(@reviewer)
    expect(response).to have_http_status(:not_found)

    system_read do
      change_request.update_columns(proposed_changes: { address_line1: new_address }, sensitive_payload_encrypted: "protected")
    end
    get requests_path, headers: headers(@reviewer)
    expect(response.parsed_body.fetch("data")).to be_empty
    patch "#{requests_path}/#{change_request.id}/reject", headers: headers(@reviewer)
    expect(response).to have_http_status(:not_found)

    system_read do
      expect(change_request.reload).to be_pending
      expect(@employee.reload.address_line1).to eq(old_address)
    end
  end

  it "blocks a staff reviewer with a prior employee link" do
    change_request = system_read do
      EmployeeAccountLink.create!(user: @staff, company: @company, employee: @employee, status: :revoked)
      address_request_for(@employee)
    end
    path = "/api/v1/admin/employee_change_requests/#{change_request.id}"
    get path, headers: headers(@staff)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data")).to include("can_review" => false, "profile_address" => true)
    patch path + "/approve", headers: headers(@staff)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(system_read { change_request.reload }).to be_pending
  end

  it "keeps a mixed own-address and pay change out of the address approval path" do
    system_read { link(@requester, @employee) }
    patch_employee(@employee, @requester, address_line1: new_address, pay_rate: 40)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Submit your address separately")
    system_read do
      expect(@employee.reload.address_line1).to eq(old_address)
      expect(EmployeeChangeRequest.where(employee: @employee)).to be_empty
    end
  end

  it "preserves the current address and request state when the original changes before approval" do
    change_request = system_read { address_request_for(@employee) }
    patch_employee(@employee, @reviewer, address_line1: "300 Example Lane")
    expect(response).to have_http_status(:ok), response.body
    patch "#{requests_path}/#{change_request.id}/approve", headers: headers(@reviewer)
    expect(response).to have_http_status(:unprocessable_entity)
    system_read do
      expect(change_request.reload).to be_pending
      expect(@employee.reload.address_line1).to eq("300 Example Lane")
    end
  end

  it "skips blank-equivalent changes on existing employees" do
    system_read { @coworker.update!(address_line2: nil) }
    patch_employee(@coworker, @requester, address_line2: "")
    expect(response).to have_http_status(:ok), response.body
    system_read do
      expect(EmployeeContactChangeToConfirm.where(employee: @coworker)).to be_empty
      expect(PortalNotificationEvent.where(category: "contact_changes")).to be_empty
    end
  end

  it "records a new hire's populated contact fields only after Cornerstone approves the hire" do
    post "/api/v1/client/employees", headers: headers(@requester), params: { employee: {
      first_name: "New", last_name: "Example", employment_type: "hourly", salary_type: "hourly", pay_rate: 16.25,
      filing_status: "single", hire_date: "2026-04-01", w4_effective_on: "2026-04-01",
      ssn: "999-00-0001", ssn_confirmation: "999-00-0001", address_line1: old_address, address_line2: "",
      city: "Example City", state: "GU", zip: "96910"
    } }
    expect(response).to have_http_status(:created), response.body
    id = response.parsed_body.dig("change_request", "id")
    system_read do
      change_request = EmployeeChangeRequest.find(id)
      expect(change_request.employee).to have_attributes(portal_pending_approval: true, status: "inactive")
      expect(EmployeeContactChangeToConfirm.where(employee: change_request.employee)).to be_empty
      expect(PortalNotificationEvent.where(category: "contact_changes")).to be_empty
    end

    patch "/api/v1/admin/employee_change_requests/#{id}/approve", headers: headers(@staff)
    expect(response).to have_http_status(:ok), response.body
    system_read do
      entry = EmployeeContactChangeToConfirm.find_by!(change_kind: "address")
      expect(entry.employee).to have_attributes(portal_pending_approval: false, status: "active")
      expect(entry).to have_attributes(changed_by: @requester, after_values: {
        "address_line1" => old_address, "city" => "Example City", "state" => "GU", "zip" => "96910"
      })
    end
  end

  it "tracks direct changes, limits Confirm all to the displayed filters and snapshot, and warns without blocking creation" do
    patch_employee(@coworker, @requester, address_line1: new_address, phone: "6715550101")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("change_request")).to be_nil
    expect(system_read { @coworker.reload.address_line1 }).to eq(new_address)

    get "#{requests_path}/contact_changes", headers: headers(@reviewer)
    expect(response.parsed_body.fetch("data").pluck("change_kind")).to contain_exactly("address", "contact")
    expect(response.parsed_body.fetch("data").first).not_to have_key("confirmed_at")

    search = "  #{system_read { @coworker.full_name }}  "
    get confirm_path, headers: headers(@staff), params: { kind: "address", search: search }
    expect(response).to have_http_status(:ok), response.body
    through_id = response.parsed_body.dig("meta", "through_id")
    patch_employee(@coworker, @requester, address_line1: "300 Example Lane")
    expect(response).to have_http_status(:ok), response.body
    patch "#{confirm_path}/confirm_all", headers: headers(@staff), params: { kind: "address", through_id: through_id, search: search }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("confirmed_count")).to eq(1)

    get confirm_path, headers: headers(@staff)
    expect(response.parsed_body.fetch("data").size).to eq(2)
    entry_id = response.parsed_body.dig("data", 0, "id")
    patch "#{confirm_path}/#{entry_id}/confirm", headers: headers(@staff)
    expect(response.parsed_body.fetch("confirmed_count")).to eq(1)
    get confirm_path, headers: headers(@staff), params: { status: "confirmed" }
    expect(response.parsed_body.fetch("data").size).to eq(2)

    post "/api/v1/admin/pay_periods", headers: headers(@staff),
      params: { pay_period: { start_date: "2026-10-01", end_date: "2026-10-14", pay_date: "2026-10-16" } }
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.fetch("unconfirmed_contact_changes")).to eq(1)
  end

  it "uses the verified employee address for an opt-in decision notice and rechecks it before send" do
    change_request = system_read do
      @employee.update!(email: "worker@example.test", email_verified_at: Time.current)
      address_request_for(@employee)
    end
    patch "#{requests_path}/#{change_request.id}/reject", headers: headers(@reviewer)
    expect(response).to have_http_status(:ok), response.body

    with_portal_email do
      system_read do
        event = PortalNotifications.employee_address_decided!(change_request.reload, actor: @reviewer)
        delivery = event.deliveries.sole
        expect(delivery).to have_attributes(user_id: nil, recipient_email: "worker@example.test", status: "pending")
        expect(PortalNotifications::Email.new(audience: "employee", delivery_mode: "immediate", events: [ event ]).link)
          .to eq("https://employee.example.test")
        @employee.update!(email: "replacement@example.test")
        PortalNotifications::Dispatcher.run!(now: 3.minutes.from_now)
        expect(delivery.reload).to have_attributes(status: "skipped", skip_reason: "access_revoked")
        expect(captured_portal_emails).to be_empty
      end
    end
  end

  it "leaves the current client behavior in place while profile requests are off" do
    system_read do
      @profile.update!(employee_portal_enabled: false)
      link(@requester, @employee)
    end
    patch_employee(@employee, @requester, address_line1: new_address)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("change_request")).to be_nil
    expect(system_read { @employee.reload.address_line1 }).to eq(new_address)
    expect(system_read { EmployeeContactChangeToConfirm.count }).to eq(0)
    get confirm_path, headers: headers(@staff)
    expect(response).to have_http_status(:not_found)
  end

  def system_read(&block)
    TenantScope.as_system(reason: "Profile address review spec fixtures", &block)
  end

  def enable_requests(company)
    ClientOperatingProfile.create!(
      company: company, effective_on: Date.new(2026, 1, 1), version: 1, offering: "payroll_portals", hours_source: "manual",
      client_portal_enabled: true, employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "profile_requests" => true } } }
    )
  end

  def headers(user)
    { "Authorization" => "Bearer synthetic.#{user.id}", "X-Company-Id" => @company.id.to_s }
  end

  def patch_employee(employee, user, **attributes)
    patch "/api/v1/client/employees/#{employee.id}", headers: headers(user), params: { employee: attributes }
  end

  def link(user, employee)
    EmployeeAccountLink.create!(user: user, company: employee.company, employee: employee, status: "active")
  end

  def address_request_for(employee)
    user = create(:user, company: employee.company, role: "portal_employee")
    create(:employee_change_request, company: employee.company, employee: employee,
      requested_by: user, requested_by_link: link(user, employee),
      proposed_changes: { address_line1: new_address }, original_values: { address_line1: employee.address_line1 })
  end
end
