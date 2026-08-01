# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Employees", type: :request do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "admin-#{company.id}@example.com",
      name: "Admin User",
      role: "admin",
      active: true
    )
  end
  let!(:accountant_user) do
    User.create!(
      company: company,
      email: "accountant-#{company.id}@example.com",
      name: "Accountant User",
      role: "accountant",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(admin_user)
  end

  describe "GET /api/v1/admin/employees" do
    context "with employees" do
      before do
        create_list(:employee, 3, company: company, department: department)
        create(:employee, company: company, status: "terminated")
      end

      it "returns paginated employees" do
        get "/api/v1/admin/employees", params: { company_id: company.id }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(4)
        expect(json["meta"]).to include("current_page", "total_pages", "total_count", "per_page")
      end

      it "filters by status" do
        get "/api/v1/admin/employees", params: { company_id: company.id, status: "active" }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(3)
        expect(json["data"].all? { |e| e["status"] == "active" }).to be true
      end

      it "filters by department" do
        other_dept = create(:department, company: company)
        create(:employee, company: company, department: other_dept)

        get "/api/v1/admin/employees", params: { company_id: company.id, department_id: department.id }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(3)
      end

      it "searches by name" do
        create(:employee, company: company, first_name: "Searchable", last_name: "Person")

        get "/api/v1/admin/employees", params: { company_id: company.id, search: "searchable" }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(1)
        expect(json["data"].first["first_name"]).to eq("Searchable")
      end

      it "searches by full name across first and last name" do
        create(:employee, company: company, first_name: "Mindy", last_name: "Wilson")

        get "/api/v1/admin/employees", params: { company_id: company.id, search: "mindy wilson" }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(1)
        expect(json["data"].first["first_name"]).to eq("Mindy")
        expect(json["data"].first["last_name"]).to eq("Wilson")
      end

      it "treats wildcard characters in search as literal input" do
        create(:employee, company: company, first_name: "100%Real", last_name: "Person")

        get "/api/v1/admin/employees", params: { company_id: company.id, search: "100%" }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(1)
        expect(json["data"].first["first_name"]).to eq("100%Real")
      end

      it "paginates results" do
        get "/api/v1/admin/employees", params: { company_id: company.id, per_page: 2 }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(2)
        expect(json["meta"]["total_pages"]).to eq(2)
        expect(json["meta"]["total_count"]).to eq(4)
      end

      it "sorts by pay rate descending" do
        create(:employee, company: company, department: department, first_name: "Low", last_name: "Rate", pay_rate: 10)
        create(:employee, company: company, department: department, first_name: "High", last_name: "Rate", pay_rate: 25)

        get "/api/v1/admin/employees", params: {
          company_id: company.id,
          sort_by: "rate",
          sort_direction: "desc"
        }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].first["pay_rate"].to_f).to eq(25.0)
      end

      it "sorts by department name ascending" do
        alpha_department = create(:department, company: company, name: "Alpha")
        beta_department = create(:department, company: company, name: "Beta")
        create(:employee, company: company, department: beta_department, first_name: "Beta", last_name: "Employee")
        create(:employee, company: company, department: alpha_department, first_name: "Alpha", last_name: "Employee")

        get "/api/v1/admin/employees", params: {
          company_id: company.id,
          sort_by: "department",
          sort_direction: "asc"
        }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        sorted_names = json["data"]
          .select { |employee| employee["last_name"] == "Employee" }
          .map { |employee| employee["first_name"] }

        expect(sorted_names).to eq(%w[Alpha Beta])
      end
    end

    context "with no employees" do
      it "returns empty array" do
        get "/api/v1/admin/employees", params: { company_id: company.id }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"]).to eq([])
        expect(json["meta"]["total_count"]).to eq(0)
      end
    end
  end

  describe "GET /api/v1/admin/employees/:id" do
    let!(:employee) { create(:employee, company: company, department: department, ssn_encrypted: "123-45-6789") }

    it "returns the employee" do
      get "/api/v1/admin/employees/#{employee.id}"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["data"]["id"]).to eq(employee.id)
      expect(json["data"]["first_name"]).to eq(employee.first_name)
    end

    it "includes SSN last 4 digits only" do
      get "/api/v1/admin/employees/#{employee.id}"

      json = response.parsed_body
      expect(json["data"]["ssn_last_four"]).to eq("6789")
      expect(json["data"]).not_to have_key("ssn_encrypted")
    end

    it "includes department info" do
      get "/api/v1/admin/employees/#{employee.id}"

      json = response.parsed_body
      expect(json["data"]["department"]).to include("id" => department.id, "name" => department.name)
    end

    it "returns 404 for non-existent employee" do
      get "/api/v1/admin/employees/99999"

      expect(response).to have_http_status(:not_found)
      json = response.parsed_body
      expect(json["error"]).to eq("Employee not found")
    end

    it "returns 404 for employee in another company" do
      other_company = create(:company)
      other_employee = create(:employee, company: other_company)

      get "/api/v1/admin/employees/#{other_employee.id}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/admin/employees" do
    let(:valid_params) do
      {
        employee: {
          first_name: "John",
          last_name: "Doe",
          email: "john.doe@example.com",
          ssn: "123-45-6789",
          ssn_confirmation: "123-45-6789",
          hire_date: "2024-01-15",
          date_of_birth: "1990-05-20",
          employment_type: "hourly",
          pay_rate: 15.00,
          filing_status: "single",
          allowances: 1,
          department_id: department.id,
          company_id: company.id,
          address_line1: "123 Test St",
          city: "Barrigada",
          state: "GU",
          zip: "96913"
        }
      }
    end

    context "with valid params" do
      it "creates an employee" do
        expect {
          post "/api/v1/admin/employees", params: valid_params
        }.to change(Employee, :count).by(1)

        expect(response).to have_http_status(:created)
        json = response.parsed_body
        expect(json["data"]["first_name"]).to eq("John")
        expect(json["data"]["last_name"]).to eq("Doe")
        expect(json["data"]["email"]).to eq("john.doe@example.com")
      end

      it "encrypts SSN and returns only last 4" do
        post "/api/v1/admin/employees", params: valid_params

        json = response.parsed_body
        expect(json["data"]["ssn_last_four"]).to eq("6789")
        expect(json["data"]).not_to have_key("ssn_encrypted")

        employee = Employee.last
        expect(employee.ssn_encrypted).to eq("123-45-6789")
      end

      it "records the created employee id in the audit log" do
        expect {
          post "/api/v1/admin/employees", params: valid_params
        }.to change(AuditLog, :count).by(1)

        log = AuditLog.last
        expect(log.action).to eq("employees#create")
        expect(log.record_id.to_s).to eq(Employee.last.id.to_s)
      end

      it "rejects a W-2 employee when filing address fields are missing" do
        params_without_address = valid_params.deep_dup
        params_without_address[:employee].merge!(address_line1: "", city: "", state: "", zip: "")

        expect {
          post "/api/v1/admin/employees", params: params_without_address
        }.not_to change(Employee, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("details").keys).to include(
          "address_line1", "city", "state", "zip"
        )
      end

      it "creates a salaried employee with a multi-million-dollar annual rate" do
        salary_params = valid_params.deep_dup
        salary_params[:employee].merge!(
          employment_type: "salary",
          salary_type: "annual",
          pay_frequency: "biweekly",
          pay_rate: 5_460_000
        )

        post "/api/v1/admin/employees", params: salary_params

        expect(response).to have_http_status(:created)
        expect(Employee.last.pay_rate).to eq(5_460_000)
      end
    end

    context "with invalid params" do
      it "rejects a missing SSN confirmation" do
        invalid_params = valid_params.deep_dup
        invalid_params[:employee].delete(:ssn_confirmation)

        post "/api/v1/admin/employees", params: invalid_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("details", "ssn_confirmation")).to include("can't be blank")
      end

      it "rejects an SSN confirmation that does not match" do
        invalid_params = valid_params.deep_dup
        invalid_params[:employee][:ssn_confirmation] = "987-65-4321"

        post "/api/v1/admin/employees", params: invalid_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("details", "ssn_confirmation")).to include("does not match Social Security Number")
      end

      it "returns errors for missing required fields" do
        post "/api/v1/admin/employees", params: { employee: { first_name: "" } }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["error"]).to eq("Validation failed")
        expect(json["details"]).to have_key("first_name")
      end

      it "returns error for invalid employment type" do
        invalid_params = valid_params.deep_dup
        invalid_params[:employee][:employment_type] = "invalid"

        post "/api/v1/admin/employees", params: invalid_params

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["details"]).to have_key("employment_type")
      end

      it "returns error for negative pay rate" do
        invalid_params = valid_params.deep_dup
        invalid_params[:employee][:pay_rate] = -10

        post "/api/v1/admin/employees", params: invalid_params

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["details"]).to have_key("pay_rate")
      end
    end

    it "allows accountants to create employees for their assigned client scope" do
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(accountant_user)

      expect {
        post "/api/v1/admin/employees", params: valid_params
      }.to change(Employee, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end

  describe "GET /api/v1/admin/employees as accountant" do
    it "still allows read access" do
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(accountant_user)

      get "/api/v1/admin/employees"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /api/v1/admin/employees/:id" do
    let!(:employee) { create(:employee, company: company, first_name: "Original") }

    context "with valid params" do
      it "updates the employee" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { first_name: "Updated" }
        }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"]["first_name"]).to eq("Updated")
        expect(employee.reload.first_name).to eq("Updated")

        audit = AuditLog.find_by!(action: "employees#update", record_id: employee.id)
        expect(audit.subject_name).to include("Updated")
        expect(audit.metadata.fetch("before_values")).to include("first_name" => "Original")
        expect(audit.metadata.fetch("after_values")).to include("first_name" => "Updated")
      end

      it "updates pay rate" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { pay_rate: 25.00 }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.reload.pay_rate).to eq(25.00)
      end

      it "updates recurring custom earnings" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: {
            default_custom_earnings: [
              { label: "Chief Stipend", amount: "125.555" },
              { label: "Bad Infinity", amount: "Infinity" },
              { label: "Bad NaN", amount: "NaN" },
              { label: "Ignored", amount: "0" },
              { label: "", amount: "50" }
            ]
          }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.reload.default_custom_earnings).to eq([
          { "label" => "Chief Stipend", "amount" => 125.56 }
        ])
      end

      it "allows updating an employee while address fields remain blank" do
        employee.update_columns(address_line1: nil, city: nil, state: nil, zip: nil)

        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { first_name: "No Address Yet" }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.reload.first_name).to eq("No Address Yet")
        expect(employee.address_line1).to be_nil
      end
    end

    context "with invalid params" do
      it "rejects an invalid replacement SSN even when its confirmation matches" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: {
            ssn: "123-45-67",
            ssn_confirmation: "123-45-67"
          }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("details", "ssn")).to include("must contain exactly 9 digits")
      end

      it "returns validation errors" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { pay_rate: -5 }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["details"]).to have_key("pay_rate")
      end
    end

    it "allows accountants to update employees" do
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(accountant_user)

      patch "/api/v1/admin/employees/#{employee.id}", params: {
        employee: { first_name: "Accountant Updated" }
      }

      expect(response).to have_http_status(:ok)
      expect(employee.reload.first_name).to eq("Accountant Updated")
    end
  end

  describe "DELETE /api/v1/admin/employees/:id" do
    let!(:employee) { create(:employee, company: company, status: "active") }

    it "soft deletes the employee by setting terminated status" do
      delete "/api/v1/admin/employees/#{employee.id}"

      expect(response).to have_http_status(:no_content)
      expect(employee.reload.status).to eq("terminated")
      expect(employee.termination_date).to eq(Date.current)

      audit = AuditLog.find_by!(action: "employees#destroy", record_id: employee.id)
      expect(audit.subject_name).to eq(employee.display_name)
      expect(audit.metadata.fetch("before_values")).to include("status" => "active")
      expect(audit.metadata.fetch("after_values")).to include("status" => "terminated")
    end

    it "does not hard delete the employee" do
      expect {
        delete "/api/v1/admin/employees/#{employee.id}"
      }.not_to change(Employee, :count)
    end

    it "returns 404 for non-existent employee" do
      delete "/api/v1/admin/employees/99999"

      expect(response).to have_http_status(:not_found)
    end
  end
end
