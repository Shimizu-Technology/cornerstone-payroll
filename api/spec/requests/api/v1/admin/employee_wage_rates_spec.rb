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

  describe "DELETE /api/v1/admin/employee_wage_rates/:id" do
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
