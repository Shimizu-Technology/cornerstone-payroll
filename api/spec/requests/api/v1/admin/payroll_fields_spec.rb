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
    it "keeps accountants from changing reusable payroll definitions" do
      accountant = create(:user, company: company, organization: company.organization, role: "accountant")
      allow_any_instance_of(Api::V1::Admin::PayrollFieldsController)
        .to receive(:current_user).and_return(accountant)

      post "/api/v1/admin/payroll_fields", params: {
        payroll_field: {
          name: "Unauthorized Field",
          kind: "deduction",
          tax_treatment: "post_tax_deduction",
          category: "other"
        }
      }

      expect(response).to have_http_status(:forbidden)
      expect(PayrollFieldDefinition.where(name: "Unauthorized Field")).not_to exist
    end

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

    it "persists report grouping metadata for QuickBooks-style retirement reports" do
      post "/api/v1/admin/payroll_fields", params: {
        payroll_field: {
          name: "401(k) Pre-Tax",
          kind: "deduction",
          tax_treatment: "pre_tax_deduction",
          category: "retirement",
          reporting_group: PayrollReportingGroups::GROUP_401K_PRE_TAX,
          amount_type: "percentage",
          default_percentage: 4.0
        }
      }

      expect(response).to have_http_status(:created)
      json = response.parsed_body.fetch("payroll_field")
      expect(json["reporting_group"]).to eq(PayrollReportingGroups::GROUP_401K_PRE_TAX)
      expect(PayrollFieldDefinition.find(json["id"]).reporting_group).to eq(PayrollReportingGroups::GROUP_401K_PRE_TAX)
    end

    it "returns validation errors when a duplicate create hits the database unique index" do
      allow_any_instance_of(PayrollFieldDefinition).to receive(:save)
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint"))

      post "/api/v1/admin/payroll_fields", params: {
        payroll_field: {
          name: "Duplicate Field",
          kind: "deduction",
          tax_treatment: "post_tax_deduction",
          category: "other",
          amount_type: "fixed"
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to include("duplicate key value")
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

    it "keeps employee-only fields off the client-wide list and shows them only to their owner" do
      coworker = create(:employee, company: company, department: department)
      personal = PayrollFieldDefinition.create!(company: company, owner_employee: employee, name: "Phone allowance", kind: "addition", tax_treatment: "taxable_addition")
      PayrollFieldDefinition.create!(company: company, owner_employee: coworker, name: "Phone allowance", kind: "addition", tax_treatment: "taxable_addition")

      get "/api/v1/admin/payroll_fields"
      expect(response.parsed_body.fetch("payroll_fields")).to be_empty

      get "/api/v1/admin/payroll_fields", params: { employee_id: employee.id }
      expect(response.parsed_body.fetch("payroll_fields").map { |field| field.fetch("id") }).to eq([ personal.id ])
    end
  end

  describe "POST /api/v1/admin/employees/:employee_id/payroll_fields/create_personal" do
    let(:payload) do
      {
        payroll_field: { name: "Phone allowance", kind: "addition", tax_treatment: "taxable_addition", category: "phone", amount_type: "fixed" },
        employee_payroll_field: { amount: 35, start_date: "2026-09-21", notes: "Approved by payroll admin" }
      }
    end

    it "atomically creates an employee-only definition and dated assignment" do
      post "/api/v1/admin/employees/#{employee.id}/payroll_fields/create_personal", params: payload

      expect(response).to have_http_status(:created)
      field = PayrollFieldDefinition.find(response.parsed_body.dig("payroll_field", "id"))
      assignment = employee.employee_payroll_fields.find_by!(payroll_field_definition: field)
      expect(field.owner_employee_id).to eq(employee.id)
      expect(assignment.amount.to_f).to eq(35.0)
      expect(assignment.start_date).to eq(Date.new(2026, 9, 21))
      expect(assignment.effective_amount_for(100)).to eq(35)
    end

    it "does not leave an orphan definition when the payday range is invalid" do
      invalid = payload.deep_merge(employee_payroll_field: { end_date: "2026-09-20" })
      expect { post "/api/v1/admin/employees/#{employee.id}/payroll_fields/create_personal", params: invalid }
        .not_to change(PayrollFieldDefinition, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "prevents assigning an employee-only definition to another worker" do
      post "/api/v1/admin/employees/#{employee.id}/payroll_fields/create_personal", params: payload
      field_id = response.parsed_body.dig("payroll_field", "id")
      coworker = create(:employee, company: company, department: department)

      post "/api/v1/admin/employees/#{coworker.id}/payroll_fields", params: {
        employee_payroll_field: { payroll_field_definition_id: field_id, amount: 35 }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(coworker.employee_payroll_fields).to be_empty
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

      expect(response).to have_http_status(:ok)
      expect(employee.employee_payroll_fields.where(payroll_field_definition: field).count).to eq(1)
      assignment = employee.employee_payroll_fields.find_by!(payroll_field_definition: field)
      expect(assignment).to be_active
      expect(assignment.amount.to_f).to eq(50.0)
    end

    it "does not assign another company's employee loan" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Loan Payroll Field",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )
      other_department = create(:department, company: other_company)
      other_employee = create(:employee, company: other_company, department: other_department)
      other_loan = EmployeeLoan.create!(
        company: other_company,
        employee: other_employee,
        name: "Other Company Loan",
        original_amount: 500,
        current_balance: 500,
        payment_amount: 50,
        status: "active"
      )

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields", params: {
        employee_payroll_field: {
          payroll_field_definition_id: field.id,
          amount: 50,
          employee_loan_id: other_loan.id,
          active: true
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_payroll_fields.where(payroll_field_definition: field)).not_to exist
      expect(response.parsed_body.fetch("errors")).to include("Loan not found for this employee")
    end

    it "does not assign another employee's loan from the same company" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Employee Loan Field",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )
      coworker = create(:employee, company: company, department: department)
      coworker_loan = EmployeeLoan.create!(
        company: company,
        employee: coworker,
        name: "Coworker Loan",
        original_amount: 500,
        current_balance: 500,
        payment_amount: 50,
        status: "active"
      )

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields", params: {
        employee_payroll_field: {
          payroll_field_definition_id: field.id,
          amount: 50,
          employee_loan_id: coworker_loan.id,
          active: true
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_payroll_fields.where(payroll_field_definition: field)).not_to exist
      expect(response.parsed_body.fetch("errors")).to include("Loan not found for this employee")
    end

    it "returns a validation response when assignment creation hits a uniqueness race" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Race Field",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "other"
      )
      allow_any_instance_of(EmployeePayrollField).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value"))

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields", params: {
        employee_payroll_field: {
          payroll_field_definition_id: field.id,
          amount: 50,
          active: true
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to be_present
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

    it "rejects an invalid replacement loan without detaching the saved balance ledger" do
      field = PayrollFieldDefinition.create!(company: company, name: "Tracked loan", kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan", amount_type: "fixed")
      loan = EmployeeLoan.create!(company: company, employee: employee, name: "Existing balance", original_amount: 500, current_balance: 500)
      assignment = EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, employee_loan: loan, amount: 50)

      patch "/api/v1/admin/employees/#{employee.id}/payroll_fields/#{assignment.id}", params: {
        employee_payroll_field: { employee_loan_id: -1, amount: 100 }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(assignment.reload.employee_loan_id).to eq(loan.id)
      expect(assignment.amount).to eq(50)
      expect(loan.reload.current_balance).to eq(500)
    end

    it "rejects the entire bulk update when a supplied loan cannot be linked" do
      field = PayrollFieldDefinition.create!(company: company, name: "Tracked loan", kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan", amount_type: "fixed")
      loan = EmployeeLoan.create!(company: company, employee: employee, name: "Existing balance", original_amount: 500, current_balance: 500)
      assignment = EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, employee_loan: loan, amount: 50)
      rent = PayrollFieldDefinition.create!(company: company, name: "Rent", kind: "deduction", tax_treatment: "post_tax_deduction", category: "rent")

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields/bulk_update", params: {
        employee_payroll_fields: [
          { payroll_field_definition_id: rent.id, amount: 25 },
          { id: assignment.id, payroll_field_definition_id: field.id, employee_loan_id: -1, amount: 100 }
        ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_payroll_fields.count).to eq(1)
      expect(assignment.reload.employee_loan_id).to eq(loan.id)
      expect(assignment.amount).to eq(50)
    end

    it "bulk-updates employee payroll field assignments atomically" do
      rent = PayrollFieldDefinition.create!(company: company, name: "Rent", kind: "deduction", tax_treatment: "post_tax_deduction", category: "rent")
      retirement = PayrollFieldDefinition.create!(company: company, name: "401(k)", kind: "deduction", tax_treatment: "pre_tax_deduction", category: "retirement", amount_type: "percentage")

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields/bulk_update", params: {
        employee_payroll_fields: [
          { payroll_field_definition_id: rent.id, amount: 25, active: true },
          { payroll_field_definition_id: retirement.id, percentage: 5, active: true }
        ]
      }

      expect(response).to have_http_status(:ok)
      expect(employee.employee_payroll_fields.count).to eq(2)
      expect(employee.employee_payroll_fields.find_by!(payroll_field_definition: rent).amount.to_f).to eq(25.0)
      expect(employee.employee_payroll_fields.find_by!(payroll_field_definition: retirement).percentage.to_f).to eq(5.0)
    end

    it "rejects duplicate active payroll fields in bulk payloads" do
      rent = PayrollFieldDefinition.create!(company: company, name: "Rent", kind: "deduction", tax_treatment: "post_tax_deduction", category: "rent")

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields/bulk_update", params: {
        employee_payroll_fields: [
          { payroll_field_definition_id: rent.id, amount: 25, active: true },
          { payroll_field_definition_id: rent.id, amount: 30, active: true }
        ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_payroll_fields.count).to eq(0)
      expect(response.parsed_body.fetch("errors").join).to include("duplicate")
    end

    it "rolls back bulk assignment updates when one entry fails" do
      rent = PayrollFieldDefinition.create!(company: company, name: "Rent", kind: "deduction", tax_treatment: "post_tax_deduction", category: "rent")
      invalid_foreign_field = PayrollFieldDefinition.create!(company: other_company, name: "Foreign", kind: "deduction", tax_treatment: "post_tax_deduction", category: "other")

      post "/api/v1/admin/employees/#{employee.id}/payroll_fields/bulk_update", params: {
        employee_payroll_fields: [
          { payroll_field_definition_id: rent.id, amount: 25, active: true },
          { payroll_field_definition_id: invalid_foreign_field.id, amount: 30, active: true }
        ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_payroll_fields.count).to eq(0)
    end

    it "returns a validation response when assignment update hits a uniqueness race" do
      field = PayrollFieldDefinition.create!(company: company, name: "Update Race", kind: "deduction", tax_treatment: "post_tax_deduction", category: "other")
      assignment = EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 10)
      allow_any_instance_of(EmployeePayrollField).to receive(:update).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value"))

      patch "/api/v1/admin/employees/#{employee.id}/payroll_fields/#{assignment.id}", params: {
        employee_payroll_field: { amount: 20 }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to include("duplicate key value")
    end

    it "returns a validation response when assignment archive fails validation" do
      field = PayrollFieldDefinition.create!(company: company, name: "Archive Failure", kind: "deduction", tax_treatment: "post_tax_deduction", category: "other")
      assignment = EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 10)
      allow_any_instance_of(EmployeePayrollField).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(assignment))

      delete "/api/v1/admin/employees/#{employee.id}/payroll_fields/#{assignment.id}"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to be_present
    end
  end
end
