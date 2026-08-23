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

      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to contain_exactly(employee.id)
    end
  end

  describe "POST /api/v1/client/employees" do
    it "creates a non-payable profile and submits payroll-sensitive details for approval" do
      expect do
        post "/api/v1/client/employees",
          params: {
            employee: {
              first_name: "Taylor",
              last_name: "Cruz",
              email: "taylor@example.com",
              ssn: "123-45-6789",
              ssn_confirmation: "123-45-6789",
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
      end.to change(Employee, :count).by(1).and change(EmployeeChangeRequest, :count).by(1)

      expect(response).to have_http_status(:created)
      created = Employee.order(:id).last
      expect(created.company_id).to eq(company.id)
      expect(created.status).to eq("inactive")
      expect(created.portal_pending_approval).to eq(true)
      expect(created.pay_rate.to_f).to eq(0.0)
      expect(created.additional_withholding.to_f).to eq(0.0)
      expect(created.ssn_encrypted).to be_nil
      request = EmployeeChangeRequest.order(:id).last
      expect(request.request_kind).to eq("create")
      expect(request.proposed_changes).to include(
        "pay_rate" => 16.25,
        "additional_withholding" => 15.0,
        "ssn_encrypted" => "***-**-6789",
        "status" => "active",
        "portal_pending_approval" => false
      )
      expect(request.sensitive_payload.dig(:proposed, :ssn_encrypted)).to eq("123-45-6789")
      expect(request.attributes_before_type_cast.fetch("sensitive_payload_encrypted")).not_to include("123-45-6789")
      expect(response.parsed_body.dig("data", "ssn")).to be_nil
      expect(response.parsed_body.dig("data", "ssn_last_four")).to be_nil
      expect(response.parsed_body.dig("change_request", "id")).to eq(request.id)

      request.apply!(actor: create(:user, company: company, role: "admin"))
      expect(created.reload.status).to eq("active")
      expect(created.portal_pending_approval).to eq(false)
      expect(created.pay_rate.to_f).to eq(16.25)
      expect(created.additional_withholding.to_f).to eq(15.0)
      expect(created.ssn_encrypted).to eq("123-45-6789")
    end

    it "rejects mismatched SSN confirmation" do
      expect do
        post "/api/v1/client/employees",
          params: {
            employee: {
              first_name: "Taylor",
              last_name: "Cruz",
              employment_type: "hourly",
              pay_rate: 16.25,
              filing_status: "single",
              ssn: "123-45-6789",
              ssn_confirmation: "987-65-4321",
              hire_date: "2026-04-01",
              address_line1: "234 Marine Dr",
              city: "Hagatna",
              state: "GU",
              zip: "96910"
            }
          }
      end.not_to change(Employee, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "ssn_confirmation")).to include("does not match Social Security Number")
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
    it "redacts identifiers even if a legacy request reaches the employee action serializer" do
      legacy_request = create(:employee_change_request,
        company: company,
        employee: employee,
        requested_by: client_user,
        proposed_changes: { ssn_encrypted: "123-45-6789", contractor_ein: "98-7654321" },
        original_values: { ssn_encrypted: "987-65-4321" })
      result = ClientEmployeeUpdateService::Result.new(
        employee: employee,
        change_request: legacy_request,
        applied_direct_fields: [],
        approval_fields: %i[ssn_encrypted contractor_ein],
        changed_fields: %i[ssn_encrypted contractor_ein],
        before_values: {},
        after_values: {}
      )
      service = instance_double(ClientEmployeeUpdateService, update!: result)
      allow(ClientEmployeeUpdateService).to receive(:new).and_return(service)

      patch "/api/v1/client/employees/#{employee.id}", params: { employee: { first_name: employee.first_name } }

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("change_request", "proposed_changes", "ssn_encrypted")).to eq("[REDACTED]")
      expect(response.parsed_body.dig("change_request", "proposed_changes", "contractor_ein")).to eq("[REDACTED]")
      expect(response.parsed_body.dig("change_request", "original_values", "ssn_encrypted")).to eq("[REDACTED]")
      expect(response.body).not_to include("123-45-6789", "987-65-4321", "98-7654321")
    end

    it "applies profile-only changes without creating an approval request" do
      expect do
        patch "/api/v1/client/employees/#{employee.id}",
          params: {
            employee: {
              email: "jamie.updated@example.com",
              phone: "671-555-0199",
              address_line1: "42 Profile Ln"
            }
          }
      end.not_to change(EmployeeChangeRequest, :count)

      expect(response).to have_http_status(:ok), response.body
      expect(employee.reload.email).to eq("jamie.updated@example.com")
      expect(employee.phone).to eq("671-555-0199")
      expect(employee.address_line1).to eq("42 Profile Ln")
      expect(response.parsed_body.fetch("change_request")).to be_nil
      expect(response.parsed_body.fetch("applied_direct_fields")).to contain_exactly("email", "phone", "address_line1")
    end

    it "applies profile fields directly and submits payroll-sensitive changes for approval" do
      original_ssn = employee.ssn_encrypted

      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            address_line1: "99 Updated Ave",
            city: "Tamuning",
            pay_rate: 21.75,
            additional_withholding: 25.0,
            ssn: "123-45-6789",
            ssn_confirmation: "123-45-6789"
          }
        }

      expect(response).to have_http_status(:ok), response.body
      expect(EmployeeChangeRequest.count).to eq(1)
      expect(employee.reload.address_line1).to eq("99 Updated Ave")
      expect(employee.city).to eq("Tamuning")
      expect(employee.pay_rate.to_f).to eq(18.0)
      expect(employee.additional_withholding.to_f).to eq(10.0)
      expect(employee.ssn_encrypted).to eq(original_ssn)

      request = EmployeeChangeRequest.order(:id).last
      expect(request.request_kind).to eq("update")
      expect(request.proposed_changes).to include(
        "pay_rate" => 21.75,
        "additional_withholding" => 25.0,
        "ssn_encrypted" => "***-**-6789"
      )
      expect(request.direct_changes_applied).to include(
        "address_line1" => "99 Updated Ave",
        "city" => "Tamuning"
      )
      expect(request.attributes_before_type_cast.fetch("sensitive_payload_encrypted")).not_to include("123-45-6789")

      body = response.parsed_body
      expect(body.fetch("applied_direct_fields")).to contain_exactly("address_line1", "city")
      expect(body.fetch("message")).to include("submitted for approval")
      expect(body.dig("change_request", "id")).to eq(request.id)
      expect(body.dig("data", "ssn")).to be_nil
      expect(body.dig("data", "ssn_last_four")).to eq(employee.ssn_last_four)

      log = AuditLog.order(:id).last
      expect(log.metadata.fetch("change_request_id")).to eq(request.id)
      expect(log.metadata.fetch("approval_fields")).to include("pay_rate", "additional_withholding", "ssn_encrypted")
      expect(log.metadata.dig("after_values", "ssn_encrypted")).to eq("Ending in 6789")

      request.apply!(actor: create(:user, company: company, role: "admin"))
      expect(employee.reload.pay_rate.to_f).to eq(21.75)
      expect(employee.additional_withholding.to_f).to eq(25.0)
      expect(employee.ssn_encrypted).to eq("123-45-6789")
    end

    it "preserves an existing wage rate identity through review and approval" do
      wage_rate = employee.employee_wage_rates.create!(
        label: "Regular",
        rate: 18.0,
        is_primary: true,
        active: true
      )

      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            wage_rates: [
              { id: wage_rate.id, label: "Regular", rate: 19.75, is_primary: true, active: true }
            ]
          }
        }

      expect(response).to have_http_status(:ok), response.body
      request = EmployeeChangeRequest.order(:id).last
      expect(request.proposed_changes.dig("wage_rates", 0, "id")).to eq(wage_rate.id)
      expect(request.original_values.dig("wage_rates", 0, "id")).to eq(wage_rate.id)

      expect do
        request.apply!(actor: create(:user, company: company, role: "admin"))
      end.not_to change(EmployeeWageRate, :count)
      expect(wage_rate.reload.rate.to_f).to eq(19.75)
    end

    it "rejects a wage rate id belonging to another employee" do
      other_employee = create(:employee, company: company, department: department)
      foreign_rate = other_employee.employee_wage_rates.create!(
        label: "Foreign",
        rate: 99.0,
        is_primary: true,
        active: true
      )

      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            wage_rates: [
              { id: foreign_rate.id, label: "Foreign", rate: 20.0, is_primary: true, active: true }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "wage_rates")).to include("must reference rates belonging to this employee")
      expect(EmployeeChangeRequest.where(employee: employee)).to be_empty
      expect(foreign_rate.reload.rate.to_f).to eq(99.0)
    end

    it "captures approval originals after acquiring the employee lock" do
      intervening_update_applied = false
      allow_any_instance_of(Employee).to receive(:lock!).and_wrap_original do |method, *args|
        unless intervening_update_applied
          Employee.where(id: employee.id).update_all(pay_rate: 19.25)
          intervening_update_applied = true
        end
        method.call(*args)
      end

      patch "/api/v1/client/employees/#{employee.id}", params: { employee: { pay_rate: 22.0 } }

      expect(response).to have_http_status(:ok), response.body
      request = EmployeeChangeRequest.order(:id).last
      expect(request.original_values.fetch("pay_rate")).to eq(19.25)
      expect(request.proposed_changes.fetch("pay_rate")).to eq(22.0)
      expect(employee.reload.pay_rate.to_f).to eq(19.25)
    end

    it "rolls back direct fields when another payroll-sensitive request is already pending" do
      create(:employee_change_request,
        company: company,
        employee: employee,
        requested_by: client_user,
        proposed_changes: { pay_rate: 20.0 },
        original_values: { pay_rate: 18.0 })

      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            address_line1: "Should Not Apply",
            pay_rate: 22.0
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "base")).to include("A payroll-sensitive change request is already pending for this employee")
      expect(employee.reload.address_line1).to eq("1 Main St")
      expect(employee.pay_rate.to_f).to eq(18.0)
      expect(EmployeeChangeRequest.where(employee: employee, status: :pending).count).to eq(1)
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

    it "rejects an in-place W-2 to 1099 change" do
      patch "/api/v1/client/employees/#{employee.id}",
        params: {
          employee: {
            employment_type: "contractor",
            contractor_type: "individual",
            contractor_pay_type: "flat_fee"
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "employment_type")).to include(
        "cannot change between W-2 and 1099 in place; create a new worker record"
      )
      expect(employee.reload.employment_type).to eq("hourly")
    end
  end

  describe "GET /api/v1/client/employees/:id" do
    it "returns only the saved SSN last four for replacement semantics" do
      employee.update!(ssn_encrypted: "123-45-6789")

      get "/api/v1/client/employees/#{employee.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "ssn")).to be_nil
      expect(response.parsed_body.dig("data", "ssn_last_four")).to eq("6789")
    end
  end
end
