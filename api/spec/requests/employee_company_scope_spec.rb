# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee saves keep their requested company", type: :request do
  let!(:home) { create(:company) }
  let!(:workspace) do
    create(:company, organization: home.organization, payroll_environment: "migration_rehearsal",
      migration_source_company: home, migration_rehearsal_status: "ready",
      test_workspace_purpose: "sandbox", test_workspace_expires_at: 1.day.from_now)
  end
  let!(:actor) { create(:user, role: "accountant", company: home, organization: home.organization) }
  let!(:grant) do
    create(:company_assignment, user: actor, company: workspace, workspace_access_level: "operator", expires_at: 1.hour.from_now)
  end
  let!(:home_employee) { create(:employee, company: home, department: nil) }
  let(:payload) do
    { employee: {
      first_name: "Synthetic", last_name: "Scope QA", ssn: "900709999", ssn_confirmation: "900709999",
      employment_type: "hourly", pay_rate: 25, pay_frequency: "semimonthly", filing_status: "single",
      hire_date: "2026-01-01", w4_effective_on: "2026-01-01", address_line1: "QA only", city: "Hagatna", state: "GU", zip: "96910",
      company_id: workspace.id
    } }
  end

  before do
    actor_id = actor.id
    allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user) { User.find(actor_id) }
  end

  def business_counts
    [ Employee.count, EmployeeWageRate.count, EmployeeW4Election.count, AuditLog.count ]
  end

  [ "", " ", "invalid", "999999999" ].each do |raw|
    it "rejects explicit #{raw.inspect} scope without a home save or read" do
      expect do
        post "/api/v1/admin/employees", headers: { "X-Company-Id" => raw }, params: payload
      end.not_to change { business_counts }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("company_context_unavailable")
      get "/api/v1/admin/employees/#{home_employee.id}", headers: { "X-Company-Id" => raw }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).not_to have_key("data")
    end
  end

  %i[expires_at revoked archived].each do |reason|
    it "rejects the stale workspace form after #{reason}, without falling home" do
      case reason
      when :expires_at then grant.update!(expires_at: 1.minute.ago)
      when :revoked then grant.destroy!
      when :archived then workspace.update!(test_workspace_archived_at: Time.current)
      end
      expect do
        post "/api/v1/admin/employees", headers: { "X-Company-Id" => workspace.id.to_s }, params: payload
      end.not_to change { business_counts }
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/admin/employees/#{home_employee.id}", headers: { "X-Company-Id" => workspace.id.to_s }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "rejects conflicting accessible header and form company instead of overwriting it" do
    create(:company_assignment, user: actor, company: home)
    expect do
      post "/api/v1/admin/employees", headers: { "X-Company-Id" => home.id.to_s }, params: payload
    end.not_to change { business_counts }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["code"]).to eq("company_context_mismatch")
  end

  it "allows a complete operator save only in its explicitly selected workspace" do
    expect do
      post "/api/v1/admin/employees", headers: { "X-Company-Id" => workspace.id.to_s }, params: payload
    end.to change(Employee, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(Employee.last.company_id).to eq(workspace.id)
    expect(Employee.last.employee_w4_elections.sole.company_id).to eq(workspace.id)
  end

  it "rechecks a grant revoked after initial authorization but before the locked save" do
    allow_any_instance_of(Company).to receive(:lock!).and_wrap_original do |method, *args|
      result = method.call(*args)
      if method.receiver.id == workspace.id
        CompanyAssignment.where(id: grant.id).update_all(expires_at: 1.minute.ago)
      end
      result
    end
    expect do
      post "/api/v1/admin/employees", headers: { "X-Company-Id" => workspace.id.to_s }, params: payload
    end.not_to change { business_counts }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["code"]).to eq("company_context_unavailable")
  end

  it "retains the no-header home read when scope was not explicitly requested" do
    grant.destroy!
    get "/api/v1/admin/employees/#{home_employee.id}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "company_id")).to eq(home.id)
  end

  it "rejects a live-company save when the staff role is removed after initial authorization" do
    allow_any_instance_of(Company).to receive(:lock!).and_wrap_original do |method, *args|
      result = method.call(*args)
      User.where(id: actor.id).update_all(role: User.roles.fetch("employee")) if method.receiver.id == home.id
      result
    end
    expect do
      post "/api/v1/admin/employees", headers: { "X-Company-Id" => home.id.to_s },
        params: { employee: payload.fetch(:employee).merge(company_id: home.id) }
    end.not_to change { business_counts }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["code"]).to eq("company_context_unavailable")
  end
end
