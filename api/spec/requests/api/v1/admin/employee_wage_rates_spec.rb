require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeWageRates", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:other_department) { create(:department, company: other_company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:other_employee) { create(:employee, company: other_company, department: other_department) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "wage-rates-admin@example.com",
      name: "Wage Rates Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeWageRatesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeWageRatesController).to receive(:current_user).and_return(admin_user)
  end

  describe "GET /api/v1/admin/employee_wage_rates" do
    it "returns 404 for an employee in another company" do
      get "/api/v1/admin/employee_wage_rates", params: { employee_id: other_employee.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/admin/employee_wage_rates" do
    it "creates the wage rate under the employee lock" do
      expect_any_instance_of(Employee).to receive(:with_lock).and_call_original

      post "/api/v1/admin/employee_wage_rates",
        params: {
          employee_wage_rate: {
            employee_id: employee.id,
            compensation_revision: EmployeeCompensationChangeService.revision(employee.reload),
            label: "Regular",
            rate: 18.00,
            is_primary: true,
            active: true
          }
        },
        as: :json

      expect(response).to have_http_status(:created)
    end

    it "rejects creating a wage rate for an employee in another company" do
      expect {
        post "/api/v1/admin/employee_wage_rates",
          params: {
            employee_wage_rate: {
              employee_id: other_employee.id,
              label: "Flight Time",
              rate: 30.00,
              is_primary: true,
              active: true
            }
          },
          as: :json
      }.not_to change(EmployeeWageRate, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/admin/employee_wage_rates/:id" do
    it "updates the wage rate under the employee lock" do
      rate = employee.employee_wage_rates.create!(label: "Regular", rate: 18, is_primary: true, active: true)
      expect_any_instance_of(Employee).to receive(:with_lock).and_call_original

      patch "/api/v1/admin/employee_wage_rates/#{rate.id}",
        params: { employee_wage_rate: { rate: 20.00, compensation_revision: EmployeeCompensationChangeService.revision(employee.reload) } },
        as: :json

      expect(response).to have_http_status(:ok)
      expect(rate.reload.rate.to_f).to eq(20.0)
    end

    it "returns 404 for a wage rate in another company" do
      foreign_rate = EmployeeWageRate.create!(
        employee: other_employee,
        label: "Office Time",
        rate: 15.00,
        is_primary: true,
        active: true
      )

      patch "/api/v1/admin/employee_wage_rates/#{foreign_rate.id}",
        params: { employee_wage_rate: { rate: 20.00 } },
        as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  it "chains revisions through create, update and end and rejects a stale no-op" do
    get "/api/v1/admin/employee_wage_rates", params: { employee_id: employee.id }
    original = response.parsed_body.fetch("compensation_revision")
    post "/api/v1/admin/employee_wage_rates", params: { employee_wage_rate: {
      employee_id: employee.id, label: "Regular", rate: 18, compensation_revision: original
    } }, as: :json
    expect(response).to have_http_status(:created)
    created = response.parsed_body.fetch("compensation_revision")
    expect(created).not_to eq(original)
    id = response.parsed_body.dig("wage_rate", "id")
    endpoint = "/api/v1/admin/employee_wage_rates/#{id}"

    patch endpoint, params: { employee_wage_rate: { rate: 18, compensation_revision: original } }, as: :json
    expect(response).to have_http_status(:conflict)
    patch endpoint, params: { employee_wage_rate: { rate: 20, compensation_revision: created } }, as: :json
    expect(response).to have_http_status(:ok)
    updated = response.parsed_body.fetch("compensation_revision")
    expect(updated).not_to eq(created)
    delete endpoint, params: { employee_wage_rate: { compensation_revision: updated } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("compensation_revision")).not_to eq(updated)
  end

  describe "DELETE /api/v1/admin/employee_wage_rates/:id" do
    # M3-4: a removed rate is ended on its effective date, never deleted, so
    # its history and the payroll buckets that used it stay intact.
    it "ends the wage rate under the employee lock instead of deleting it" do
      rate = employee.employee_wage_rates.create!(label: "Regular", rate: 18, is_primary: true, active: true)
      expect_any_instance_of(Employee).to receive(:with_lock).and_call_original

      delete "/api/v1/admin/employee_wage_rates/#{rate.id}", as: :json,
        params: { employee_wage_rate: { compensation_revision: EmployeeCompensationChangeService.revision(employee.reload) } }

      expect(response).to have_http_status(:ok)
      expect(rate.reload).to have_attributes(active: false, is_primary: false)
      expect(rate.employee_wage_rate_versions.chronological.last).to have_attributes(active: false, ends_on: nil)
    end

    it "returns 404 for a wage rate in another company" do
      foreign_rate = EmployeeWageRate.create!(
        employee: other_employee,
        label: "Office Time",
        rate: 15.00,
        is_primary: true,
        active: true
      )

      delete "/api/v1/admin/employee_wage_rates/#{foreign_rate.id}"

      expect(response).to have_http_status(:not_found)
    end
  end
end
