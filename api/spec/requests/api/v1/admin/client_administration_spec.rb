# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Delegated administration of an existing client", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company, organization: company.organization) }
  let!(:admin) { create(:user, company: company, role: "admin") }
  let!(:accountant) { create(:user, company: company, role: "accountant") }
  let!(:assignment) { create(:company_assignment, user: accountant, company: company, client_management: true, granted_by: admin) }
  let!(:other_assignment) { create(:company_assignment, user: accountant, company: other_company) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(accountant)
  end

  def update_intake(headers: self.headers)
    patch "/api/v1/admin/employee_intake_settings", params: {
      employee_intake_settings: { enabled: true, reason: "Fictional client intake review", duration_hours: 1 }
    }, headers: headers, as: :json
  end

  it "permits and reports an explicit selected-client intake grant" do
    get "/api/v1/admin/employee_intake_settings", headers: headers
    expect(response.parsed_body.dig("data", "can_manage")).to be(true)
    update_intake
    expect(response).to have_http_status(:ok), response.body
    expect(company.reload.employee_intake_enabled_by_id).to eq(accountant.id)
    expect(company.employee_intake_expires_at).to be > Time.current
    expect(accountant.reload.role).to eq("accountant")
  end

  it "denies another assigned client and revocation without changing either company" do
    update_intake(headers: { "X-Company-Id" => other_company.id.to_s })
    expect(response).to have_http_status(:forbidden)
    expect(other_company.reload.employee_intake_expires_at).to be_nil
    assignment.update!(client_management: false)
    update_intake
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.employee_intake_expires_at).to be_nil
    get "/api/v1/admin/employee_intake_settings", headers: headers
    expect(response.parsed_body.dig("data", "can_manage")).to be(false)
  end

  it "rechecks a revoked grant after acquiring the client write lock" do
    allow_any_instance_of(Company).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      assignment.update!(client_management: false) if original.receiver.id == company.id
      original.call(*args, &block)
    end
    update_intake
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.employee_intake_expires_at).to be_nil
    expect(AuditLog.where(action: "employee_intake_settings#update")).to be_empty
  end

  it "does not promote managers into the new administration capability" do
    manager = create(:user, company: company, role: "manager")
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(manager)
    update_intake
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.employee_intake_expires_at).to be_nil
  end

  it "exposes all three scoped grants only for the intended client" do
    get "/api/v1/auth/me", headers: headers
    user = response.parsed_body.fetch("user")
    names = StaffRolePolicy::DELEGATABLE_CAPABILITIES.map(&:to_s)
    expect(user.fetch("capabilities") & names).to be_empty
    expect(user.fetch("company_capabilities").fetch(company.id.to_s)).to include(*names)
    expect(user.fetch("company_capabilities").fetch(other_company.id.to_s) & names).to be_empty
  end
end
