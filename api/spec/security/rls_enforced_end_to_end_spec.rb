# frozen_string_literal: true

require "rails_helper"

# Phase 3 rehearsal: every protected table enabled and forced by the real
# enforcement code, the runtime role granted as db/rls_runtime_role.sql grants
# it, and the guard in raise mode. The transactional fixture rolls back the
# role, grants and enforcement after each example.
RSpec.describe "RLS enforced end to end", :rls, type: :request do
  include EnforcedRlsHelpers

  let(:connection) { ActiveRecord::Base.connection }
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:own_department) { TenantScope.as_system(reason: "Fixture") { create(:department, company: company, name: "Own") } }
  let!(:other_department) { TenantScope.as_system(reason: "Fixture") { create(:department, company: other_company, name: "Other") } }
  let!(:admin_user) do
    User.create!(company: company, email: "rls-enforced-#{company.id}@example.com", name: "Admin", role: "admin", active: true)
  end

  before do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
    allow_any_instance_of(Api::V1::Admin::DepartmentsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::DepartmentsController).to receive(:current_user).and_return(admin_user)
    enforce_as_runtime_role!
  end

  it "serves a company-scoped admin request and refuses another company's row" do
    get "/api/v1/admin/departments", params: { company_id: company.id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].pluck("id")).to eq([ own_department.id ])

    post "/api/v1/admin/departments", params: { company_id: company.id, department: { name: "Created under RLS" } }
    expect(response).to have_http_status(:created)

    patch "/api/v1/admin/departments/#{other_department.id}", params: { company_id: company.id, department: { name: "Taken" } }
    expect(response).to have_http_status(:not_found)
    expect(connection.select_value("SELECT current_user")).to eq("payroll_app")
    # The controller scopes by company too; a raw write shows the policy alone refuses it.
    TenantScope.with_company(company.id) do
      expect(connection.exec_update("UPDATE departments SET name = 'Taken' WHERE id = #{other_department.id}")).to eq(0)
    end
    TenantScope.as_system(reason: "Verify enforced writes") do
      expect(Department.where(company_id: company.id).pluck(:name)).to contain_exactly("Own", "Created under RLS")
      expect(other_department.reload.name).to eq("Other")
    end
  end

  it "runs a company job whose unfiltered queries see only that company" do
    stub_const("RlsEnforcedProbeJob", Class.new(ApplicationJob) do
      self.rls_mode = :company

      def perform(_company_id, department_ids)
        # No company filter here: the forced policy does the filtering.
        visible = Department.where(id: department_ids).pluck(:id)
        total = DepartmentYtdTotal.create!(department: Department.find(visible.first), year: 2031)
        [ visible, total.company_id, Department.find_by(id: department_ids.last) ]
      end
    end)

    visible, total_company, foreign = RlsEnforcedProbeJob.perform_now(company.id, [ own_department.id, other_department.id ])
    expect(visible).to eq([ own_department.id ])
    expect(total_company).to eq(company.id)
    expect(foreign).to be_nil
  end

  it "still raises on an unscoped query before PostgreSQL runs it" do
    expect { Department.count }.to raise_error(TenantScope::MissingContextError, /departments/)
  end
end
