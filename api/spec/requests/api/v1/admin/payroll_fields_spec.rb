# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollFields", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "payroll-fields-admin@example.com",
      name: "Payroll Fields Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollFieldsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollFieldsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::EmployeePayrollFieldsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeePayrollFieldsController).to receive(:current_user).and_return(admin_user)
  end

  describe "POST /api/v1/admin/payroll_fields" do
    it "creates a company-scoped payroll field" do
      post "/api/v1/admin/payroll_fields", params: {
        payroll_field: {
          name: "Auto Loan",
          kind: "deduction",
          tax_treatment: "post_tax_deduction",
          category: "loan",
          amount_type: "fixed",
          default_amount: 75.00,
          show_in_payroll_grid: true
        }
      }

      expect(response).to have_http_status(:created)
      json = response.parsed_body.fetch("payroll_field")
      expect(json["name"]).to eq("Auto Loan")
      expect(json["company_id"]).to eq(company.id)
      expect(json["tax_treatment"]).to eq("post_tax_deduction")
    end

    it "rejects a mismatched type and tax treatment" do
      post "/api/v1/admin/payroll_fields", params: {
        payroll_field: {
          name: "Bad Field",
          kind: "addition",
          tax_treatment: "post_tax_deduction",
          category: "other",
          amount_type: "fixed"
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join).to include("Tax treatment")
    end
  end

  describe "GET /api/v1/admin/payroll_fields" do
    it "only returns fields for the current company" do
      PayrollFieldDefinition.create!(company: company, name: "Rent", kind: "deduction", tax_treatment: "post_tax_deduction", category: "rent")
      PayrollFieldDefinition.create!(company: other_company, name: "Foreign Rent", kind: "deduction", tax_treatment: "post_tax_deduction", category: "rent")

      get "/api/v1/admin/payroll_fields"

      names = response.parsed_body.fetch("payroll_fields").map { |field| field["name"] }
      expect(names).to contain_exactly("Rent")
    end
  end

  describe "POST /api/v1/admin/employees/:employee_id/payroll_fields" do
    it "only lists active employee payroll field assignments" do
      active_field = PayrollFieldDefinition.create!(company: company, name: "Active Field", kind: "deduction", tax_treatment: "post_tax_deduction", category: "other")
      inactive_field = PayrollFieldDefinition.create!(company: company, name: "Inactive Field", kind: "deduction", tax_treatment: "post_tax_deduction", category: "other")
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: active_field, amount: 10, active: true)
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: inactive_field, amount: 10, active: false)

      get "/api/v1/admin/employees/#{employee.id}/payroll_fields"

      names = response.parsed_body.fetch("employee_payroll_fields").map { |assignment| assignment.dig("payroll_field", "name") }
      expect(names).to contain_exactly("Active Field")
    end

    it "assigns an existing company payroll field to an employee" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "401(k)",
        kind: "deduction",
        tax_treatment: "pre_tax_deduction",
        category: "retirement",
        amount_type: "percentage",
        default_percentage: 0
      )

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields", params: {
        employee_payroll_field: {
          payroll_field_definition_id: field.id,
          percentage: 5,
          active: true
        }
      }

      expect(response).to have_http_status(:created)
      json = response.parsed_body.fetch("employee_payroll_field")
      expect(json["payroll_field_definition_id"]).to eq(field.id)
      expect(json["percentage"]).to eq(5.0)
      expect(json.dig("payroll_field", "name")).to eq("401(k)")
    end

    it "reactivates an inactive assignment instead of failing uniqueness validation" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Insurance",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "insurance"
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 25, active: false)

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields", params: {
        employee_payroll_field: {
          payroll_field_definition_id: field.id,
          amount: 50,
          active: true
        }
      }

      expect(response).to have_http_status(:created)
      expect(employee.employee_payroll_fields.where(payroll_field_definition: field).count).to eq(1)
      assignment = employee.employee_payroll_fields.find_by!(payroll_field_definition: field)
      expect(assignment).to be_active
      expect(assignment.amount.to_f).to eq(50.0)
    end

    it "does not assign another company's payroll field" do
      field = PayrollFieldDefinition.create!(
        company: other_company,
        name: "Foreign 401(k)",
        kind: "deduction",
        tax_treatment: "pre_tax_deduction",
        category: "retirement",
        amount_type: "percentage"
      )

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields", params: {
        employee_payroll_field: {
          payroll_field_definition_id: field.id,
          percentage: 5,
          active: true
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
