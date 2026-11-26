# frozen_string_literal: true

require "rails_helper"

# A direct contact edit by staff, or by a Client manager editing another
# employee, that changes the mailing address replaces the employee's pending
# address request. Left pending, the request could never be approved: its
# original values no longer match the record.
RSpec.describe "Superseding a pending employee address request", type: :request do
  include EmployeeLinkHelpers

  let(:company) { create(:company, name: "Example Bakery") }
  let(:staff) { create(:user, role: :admin, company: company, clerk_id: "user_supersede_staff") }
  let(:manager) { client_login("user_supersede_manager") }
  let(:employee) do
    create(:employee, company: company, first_name: "Riley", last_name: "Santos", address_line1: "100 Example St",
      city: "Hagatna", state: "GU", zip: "96910")
  end
  let(:employee_user) { create(:user, company: company, role: "portal_employee", clerk_id: "user_supersede_riley") }
  let(:employee_link) do
    EmployeeAccountLink.create!(user: employee_user, company: company, employee: employee, status: "active")
  end

  before do
    ClientOperatingProfile.create!(
      company: company, effective_on: Date.new(2026, 1, 1), version: 1, offering: "payroll_portals", hours_source: "manual",
      client_portal_enabled: true, employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "profile_requests" => true } } }
    )
    activate_employee_app!(company)
  end

  def client_login(clerk_id)
    create(:user, company: company, role: :client, clerk_id: clerk_id, client_access_level: "manager").tap do |user|
      CompanyAssignment.create!(user: user, company: company)
    end
  end

  def pending_request!
    create(:employee_change_request, company: company, employee: employee, requested_by: employee_user,
      requested_by_link: employee_link, proposed_changes: { address_line1: "200 Asked For Ave" },
      original_values: { address_line1: "100 Example St" })
  end

  def save_contact(actor, changes, target: employee)
    namespace = actor.client? ? "client" : "admin"
    patch "/api/v1/#{namespace}/employees/#{target.id}",
      params: { employee: changes, row_revision: target.reload.contact_revision, response_view: "contact" },
      as: :json, headers: bearer(actor.clerk_id).merge("X-Company-Id" => company.id.to_s)
  end

  def superseded_audit(request)
    AuditLog.where(action: "employee_change_requests#superseded", record_type: "employee_change_requests", record_id: request.id)
  end

  { staff: "staff", manager: "a Client manager editing another employee" }.each do |who, label|
    it "marks the pending request superseded when #{label} changes the address, and audits it" do
      request = pending_request!
      actor = public_send(who)

      save_contact(actor, { address_line1: "300 Employer Set Rd", city: "Tamuning" })
      expect(response).to have_http_status(:ok), response.body

      expect(employee.reload).to have_attributes(address_line1: "300 Employer Set Rd", city: "Tamuning")
      expect(request.reload).to have_attributes(status: "superseded", reviewed_by_id: actor.id)
      expect(request.reviewed_at).to be_present
      audit = superseded_audit(request).sole
      expect(audit).to have_attributes(user_id: actor.id, company_id: company.id)
      expect(audit.metadata).to include("employee_id" => employee.id, "replaced_fields" => %w[address_line1 city])

      # The one-pending slot is free again, so the employee can ask for another change.
      expect(EmployeeChangeRequest.where(employee: employee, status: :pending)).to be_empty

      # The employee app shows the replaced request with its own status.
      profile = TenantScope.as_system(reason: "spec") { EmployeeProfiles::Profile.new(employee_link, employee.reload).as_json }
      expect(profile[:address_request]).to include(id: request.id.to_s, status: "superseded")
      expect(profile[:other_request_pending]).to be(false)
    end

    it "leaves the request pending when #{label} changes only the mobile" do
      request = pending_request!
      save_contact(public_send(who), { phone: "671-555-0199" })
      expect(response).to have_http_status(:ok), response.body
      expect(request.reload).to be_pending
      expect(superseded_audit(request)).to be_empty
    end
  end

  it "doesn't touch a pending payroll-sensitive request when staff change the address" do
    request = create(:employee_change_request, company: company, employee: employee, requested_by: manager)
    save_contact(staff, { address_line1: "300 Employer Set Rd" })
    expect(response).to have_http_status(:ok), response.body
    expect(request.reload).to be_pending
  end

  it "still refuses a Client manager's address edit to their own record while their request is pending" do
    own_employee = create(:employee, company: company, first_name: "Morgan", last_name: "Cruz", address_line1: "1 Owner Way")
    EmployeeAccountLink.create!(user: manager, company: company, employee: own_employee, status: "active")
    request = create(:employee_change_request, company: company, employee: own_employee, requested_by: manager, own_record: true,
      proposed_changes: { address_line1: "2 Owner Way" }, original_values: { address_line1: "1 Owner Way" })

    save_contact(manager, { address_line1: "3 Owner Way" }, target: own_employee)
    expect(response).to have_http_status(:conflict), response.body
    expect(response.parsed_body).to include("code" => "address_request_pending", "pending_request_id" => request.id)
    expect(request.reload).to be_pending
    expect(own_employee.reload.address_line1).to eq("1 Owner Way")
  end

  it "takes the company, then the employee, then the request lock" do
    pending_request!
    locks = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next unless sql.include?("FOR UPDATE") || sql.include?("FOR NO KEY UPDATE")

      table = sql[/FROM "(companies|employees|employee_change_requests)"/, 1]
      locks << table if table
    end
    begin
      save_contact(staff, { address_line1: "300 Employer Set Rd" })
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    expect(response).to have_http_status(:ok), response.body

    order = %w[companies employees employee_change_requests].map { |table| locks.index(table) }
    expect(order).to all(be_present)
    expect(order).to eq(order.sort)
  end

  it "rolls the supersede back with the edit when the audit can't be written" do
    request = pending_request!
    allow(AuditLog).to receive(:record!).and_call_original
    allow(AuditLog).to receive(:record!).with(hash_including(action: "employee_change_requests#superseded")).and_raise(StandardError, "audit down")

    expect { save_contact(staff, { address_line1: "300 Employer Set Rd" }) }.to raise_error(StandardError, "audit down")
    expect(request.reload).to be_pending
    expect(employee.reload.address_line1).to eq("100 Example St")
  end
end
