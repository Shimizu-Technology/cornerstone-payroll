# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::Employees", type: :request do
  let!(:company) { create(:company, name: "Client Portal Co") }
  let!(:department) { create(:department, company: company, name: "Front Desk") }
  let!(:other_company) { create(:company, name: "Other Co") }
  let!(:other_department) { create(:department, company: other_company, name: "Other Dept") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "client@example.com") }
  let!(:employee) do
    create(:employee,
      company: company,
      department: department,
      first_name: "Jamie",
      last_name: "Santos",
      pay_rate: 18.00,
      additional_withholding: 10.0,
      address_line1: "1 Main St",
      city: "Barrigada",
      state: "GU",
      zip: "96913")
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user_id).and_return(client_user.id)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_company).and_return(company)
  end

  describe "GET /api/v1/client/employees" do
    it "returns employees for the active company only" do
      create(:employee, company: other_company, first_name: "Other", last_name: "Person")

      get "/api/v1/client/employees"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to contain_exactly(employee.id)
    end
  end

  describe "POST /api/v1/client/employees" do
    it "creates a new employee directly for the client company" do
      expect do
        post "/api/v1/client/employees",
          params: {
            employee: {
              first_name: "Taylor",
              last_name: "Cruz",
              email: "taylor@example.com",
              employment_type: "hourly",
              salary_type: "hourly",
              pay_rate: 16.25,
              filing_status: "single",
              additional_withholding: 15.0,
              department_id: department.id,
              hire_date: "2026-04-01",
              address_line1: "234 Marine Dr",
              city: "Hagatna",
              state: "GU",
              zip: "96910"
            }
          }
      end.to change(Employee, :count).by(1)

      expect(response).to have_http_status(:created)
      created = Employee.order(:id).last
      expect(created.company_id).to eq(company.id)
      expect(created.pay_rate.to_f).to eq(16.25)
      expect(created.additional_withholding.to_f).to eq(15.0)
      expect(EmployeeChangeRequest.count).to eq(0)
      expect(response.parsed_body.dig("data", "ssn")).to be_nil
    end

    it "rejects department ids outside the client company" do
      expect do
        post "/api/v1/client/employees",
          params: {
            employee: {
              first_name: "Taylor",
              last_name: "Cruz",
              employment_type: "hourly",
              salary_type: "hourly",
              pay_rate: 16.25,
              department_id: other_department.id
            }
          }
      end.not_to change(Employee, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "department_id")).to include("does not belong to this company")
    end
  end

  describe "PATCH /api/v1/client/employees/:id" do
    it "applies employee updates directly, including SSN changes, without creating a change request" do
      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            address_line1: "99 Updated Ave",
            city: "Tamuning",
            pay_rate: 21.75,
            additional_withholding: 25.0,
            ssn: "123-45-6789"
          }
        }

      expect(response).to have_http_status(:ok)
      expect(employee.reload.address_line1).to eq("99 Updated Ave")
      expect(employee.city).to eq("Tamuning")
      expect(employee.pay_rate.to_f).to eq(21.75)
      expect(employee.additional_withholding.to_f).to eq(25.0)
      expect(employee.ssn_encrypted).to eq("123-45-6789")
      expect(EmployeeChangeRequest.count).to eq(0)

      body = response.parsed_body
      expect(body.fetch("applied_direct_fields")).to include("address_line1", "city", "pay_rate", "additional_withholding", "ssn_encrypted")
      expect(body.fetch("message")).to eq("Employee updated successfully")
      expect(body.dig("data", "ssn")).to be_nil
      expect(body.dig("data", "ssn_last_four")).to eq("6789")

      log = AuditLog.order(:id).last
      expect(log.metadata.dig("after_values", "ssn_encrypted")).to eq("***-**-6789")
    end

    it "rejects updates that assign a department from another company" do
      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            department_id: other_department.id
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "department_id")).to include("does not belong to this company")
      expect(employee.reload.department_id).to eq(department.id)
    end
  end

  describe "GET /api/v1/client/employees/:id" do
    it "still returns the full ssn for the explicit edit/load path" do
      employee.update!(ssn_encrypted: "123-45-6789")

      get "/api/v1/client/employees/#{employee.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "ssn")).to eq("123-45-6789")
      expect(response.parsed_body.dig("data", "ssn_last_four")).to eq("6789")
    end
  end
end
