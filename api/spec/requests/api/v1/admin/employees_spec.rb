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

      it "filters the migrated employee setup review queue" do
        review_employee = create(
          :employee,
          company:,
          configuration_source: "quickbooks_history",
          configuration_review_status: "needs_review",
          configuration_review_items: [
            { "code" => "time_off_setup_not_imported", "message" => "Review time off", "fields" => [] }
          ]
        )

        get "/api/v1/admin/employees", params: {
          company_id: company.id,
          configuration_review_status: "needs_review"
        }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch("data").pluck("id")).to eq([ review_employee.id ])
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
    let!(:employee) do
      create(:employee,
        company: company,
        department: department,
        ssn_encrypted: "123-45-6789",
        job_title: "Payroll Specialist")
    end

    it "returns the employee" do
      get "/api/v1/admin/employees/#{employee.id}"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["data"]["id"]).to eq(employee.id)
      expect(json["data"]["first_name"]).to eq(employee.first_name)
      expect(json["data"]["job_title"]).to eq("Payroll Specialist")
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

    it "includes the current, upcoming, and immutable retirement election history" do
      current = employee.employee_retirement_elections.create!(
        company: company,
        effective_on: Date.current - 30,
        participating: true,
        traditional_rate: 0.05,
        source: "staff",
        reason: "Initial signed election"
      )
      upcoming = employee.employee_retirement_elections.create!(
        company: company,
        effective_on: Date.current + 15,
        participating: true,
        traditional_rate: 0.07,
        source: "staff",
        reason: "Signed increase"
      )

      get "/api/v1/admin/employees/#{employee.id}"

      data = response.parsed_body.fetch("data")
      expect(data.dig("current_retirement_election", "id")).to eq(current.id)
      expect(data.dig("upcoming_retirement_election", "id")).to eq(upcoming.id)
      expect(data.fetch("retirement_elections").map { |row| row.fetch("id") }).to eq([ upcoming.id, current.id ])
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

  describe "POST /api/v1/admin/employees/:id/resolve_configuration_review_item" do
    let!(:employee) do
      create(
        :employee,
        company:,
        configuration_source: "quickbooks_history",
        configuration_review_status: "needs_review",
        configuration_review_items: [
          { "code" => "time_off_setup_not_imported", "message" => "Review time off", "fields" => [] }
        ]
      )
    end

    it "lets assigned Cornerstone accountants document and finish an imported setup review" do
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(accountant_user)

      post "/api/v1/admin/employees/#{employee.id}/resolve_configuration_review_item", params: {
        code: "time_off_setup_not_imported",
        resolution_note: "Employer confirmed this balance is not carried into payroll.",
        acknowledgement: EmployeeConfigurationReviewService::ACKNOWLEDGEMENT
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "configuration_review_status")).to eq("complete")
      expect(response.parsed_body.dig("data", "configuration_review_resolutions", 0)).to include(
        "item_code" => "time_off_setup_not_imported",
        "reviewed_by_name" => accountant_user.name
      )
    end

    it "does not accept a resolution without a documented review" do
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(accountant_user)

      post "/api/v1/admin/employees/#{employee.id}/resolve_configuration_review_item", params: {
        code: "time_off_setup_not_imported",
        resolution_note: "",
        acknowledgement: EmployeeConfigurationReviewService::ACKNOWLEDGEMENT
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Document what was verified or corrected")
      expect(employee.reload.configuration_review_status).to eq("needs_review")
    end

    it "returns forbidden without changing review evidence for an unauthorized actor" do
      inactive_accountant = create(
        :user,
        company:,
        organization: company.organization,
        role: "accountant",
        active: false
      )
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(inactive_accountant)
      original_items = employee.configuration_review_items.deep_dup

      expect do
        post "/api/v1/admin/employees/#{employee.id}/resolve_configuration_review_item", params: {
          code: "time_off_setup_not_imported",
          resolution_note: "Attempted client review.",
          acknowledgement: EmployeeConfigurationReviewService::ACKNOWLEDGEMENT
        }
      end.not_to change(EmployeeConfigurationReviewResolution, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => "Cornerstone payroll access is required")
      expect(employee.reload.configuration_review_items).to eq(original_items)
      expect(employee.configuration_review_status).to eq("needs_review")
    end
  end

  describe "POST /api/v1/admin/employees" do
    let(:valid_params) do
      {
        employee: {
          first_name: "John",
          last_name: "Doe",
          job_title: "Controller",
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
        expect(json["data"]["job_title"]).to eq("Controller")
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

      it "rejects a department from another company" do
        other_department = create(:department, company: create(:company))
        cross_company_params = valid_params.deep_dup
        cross_company_params[:employee][:department_id] = other_department.id

        expect {
          post "/api/v1/admin/employees", params: cross_company_params
        }.not_to change(Employee, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body).dig("details", "department_id")).to include("does not belong to this company")
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

      it "creates a business contractor with legal name and EIN instead of SSN" do
        contractor_params = valid_params.deep_dup
        contractor_params[:employee].merge!(
          employment_type: "contractor",
          contractor_type: "business",
          contractor_pay_type: "flat_fee",
          business_name: "AIRE Services LLC",
          contractor_ein: "12-3456789",
          ssn: "",
          ssn_confirmation: ""
        )

        post "/api/v1/admin/employees", params: contractor_params

        expect(response).to have_http_status(:created)
        expect(Employee.last).to have_attributes(
          contractor_type: "business",
          business_name: "AIRE Services LLC",
          contractor_ein: "12-3456789",
          ssn_encrypted: nil
        )
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
    let!(:employee) { create(:employee, company: company, department: department, first_name: "Original") }

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

      it "appends effective-dated W-4 history while leaving the prior election intact" do
        EmployeeW4ElectionChangeService.new(
          employee: employee,
          attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
            .merge(w4_effective_on: Date.new(2024, 1, 1)),
          actor: admin_user,
          source: "employee_creation",
          reason: "Initial W-4"
        ).call!

        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: {
            filing_status: "married",
            w4_effective_on: "2026-10-01",
            w4_change_reason: "New signed W-4 received"
          }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.employee_w4_elections.count).to eq(2)
        employee.employee_w4_elections.reload
        expect(employee.w4_election_on(Date.new(2026, 9, 30)).filing_status).to eq("single")
        expect(employee.w4_election_on(Date.new(2026, 10, 1)).filing_status).to eq("married")
        expect(response.parsed_body.dig("data", "w4_elections").length).to eq(2)
      end

      it "rejects an unexplained W-4 change" do
        EmployeeW4ElectionChangeService.new(
          employee: employee,
          attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
            .merge(w4_effective_on: Date.new(2024, 1, 1)),
          actor: admin_user,
          source: "employee_creation",
          reason: "Initial W-4"
        ).call!

        expect {
          patch "/api/v1/admin/employees/#{employee.id}", params: {
            employee: { filing_status: "married", w4_effective_on: "2026-10-01" }
          }
        }.not_to change(EmployeeW4Election, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("details", "w4_change_reason").join).to match(/explain/i)
        expect(employee.reload.filing_status).to eq("single")
      end

      it "updates and returns the employee job title" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { job_title: "Senior Payroll Specialist" }
        }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "job_title")).to eq("Senior Payroll Specialist")
        expect(employee.reload.job_title).to eq("Senior Payroll Specialist")
      end

      it "allows changing between hourly and salary within W-2 treatment" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { employment_type: "salary", salary_type: "annual", pay_rate: 52_000 }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.reload).to have_attributes(employment_type: "salary", pay_rate: 52_000.to_d)
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

      it "saves a verified hire date with unchanged unformatted imported SSN and preserves address review" do
        review_items = [
          { "code" => "verify_hire_date", "message" => "Verify hire date", "fields" => [ "hire_date" ] },
          { "code" => "employee_address_missing", "message" => "Verify address", "fields" => %w[address_line1 city state zip] }
        ]
        employee.update!(configuration_source: "quickbooks_history", configuration_review_status: "needs_review",
          configuration_review_items: review_items, ssn_encrypted: "000000001", hire_date: nil,
          address_line1: nil, city: nil, state: nil, zip: nil)
        original_rate = employee.pay_rate
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { hire_date: "2025-05-28", ssn: "000-00-0001" }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.reload.hire_date).to eq(Date.new(2025, 5, 28))
        expect(employee.configuration_review_items).to eq(review_items)
        expect(employee.configuration_review_status).to eq("needs_review")
        expect(employee.address_line1).to be_nil
        expect(employee.pay_rate).to eq(original_rate)
      end

      it "still requires confirmation for a genuine identifier change" do
        patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { ssn: "000-00-0099" } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("details", "ssn_confirmation")).to include("can't be blank")
      end

      it "rejects an implausible hire year without saving other submitted changes" do
        original_name = employee.first_name
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { hire_date: "0006-04-20", first_name: "Changed" }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("details", "hire_date")).to include("must have a year between 1900 and next year")
        expect(employee.reload.first_name).to eq(original_name)
      end

      it "requires legacy incomplete filing data to be completed before saving edits" do
        employee.update_columns(address_line1: nil, city: nil, state: nil, zip: nil)

        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { first_name: "No Address Yet" }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("details").keys).to include("address_line1", "city", "state", "zip")
        expect(employee.reload.first_name).not_to eq("No Address Yet")
        expect(employee.address_line1).to be_nil
      end
    end

    context "with invalid params" do
      it "rejects a department from another company without changing the employee" do
        original_department_id = employee.department_id
        other_department = create(:department, company: create(:company))

        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { department_id: other_department.id }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body).dig("details", "department_id")).to include("does not belong to this company")
        expect(employee.reload.department_id).to eq(original_department_id)
      end

      it "rejects an in-place W-2 to 1099 change" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
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

  describe "POST /api/v1/admin/employees/:id/transition_tax_classification" do
    let!(:contractor) do
      create(:employee, :contractor,
        company: company,
        first_name: "Transition",
        last_name: "Worker",
        ssn_encrypted: "123-45-6789",
        hire_date: Date.new(2024, 1, 1),
        address_line1: "123 Marine Corps Dr",
        city: "Hagatna",
        state: "GU",
        zip: "96910")
    end
    let(:transition_params) do
      {
        transition: {
          employment_type: "hourly",
          effective_date: Date.current.iso8601,
          reason: "Worker begins W-2 employment",
          pay_rate: 9.25,
          pay_frequency: "semimonthly",
          filing_status: "single",
          ssn: "123-45-6789",
          ssn_confirmation: "123-45-6789"
        }
      }
    end

    it "rejects non-super-admin users" do
      post "/api/v1/admin/employees/#{contractor.id}/transition_tax_classification",
        params: transition_params,
        as: :json

      expect(response).to have_http_status(:forbidden)
      expect(contractor.reload).to be_active
    end

    it "creates a linked successor for a super admin" do
      super_admin = create(:user, company: company, role: "super_admin")
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(super_admin)

      expect {
        post "/api/v1/admin/employees/#{contractor.id}/transition_tax_classification",
          params: transition_params,
          as: :json
      }.to change(Employee, :count).by(1)

      expect(response).to have_http_status(:created)
      successor = Employee.order(:id).last
      expect(response.parsed_body.dig("data", "id")).to eq(successor.id)
      expect(response.parsed_body.dig("data", "classification_history", "previous_employee", "id")).to eq(contractor.id)
      expect(contractor.reload.status).to eq("terminated")
      expect(successor.previous_employee_id).to eq(contractor.id)
    end
  end

  describe "DELETE /api/v1/admin/employees/:id" do
    let!(:employee) { create(:employee, company: company, status: "active") }

    it "requires the explicit termination workflow instead of guessing today's date" do
      delete "/api/v1/admin/employees/#{employee.id}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("error")).to match(/termination workflow/)
      expect(employee.reload).to be_active
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


  describe "POST /api/v1/admin/employees/:id/terminate" do
    let!(:employee) { create(:employee, company: company, status: "active", hire_date: Date.new(2024, 1, 1)) }
    let(:payload) do
      {
        termination: {
          effective_date: "2024-03-15",
          last_worked_on: "2024-03-14",
          reason_category: "voluntary",
          internal_notes: "Written notice received by the payroll team."
        }
      }
    end

    it "records an immutable effective-dated status event" do
      post "/api/v1/admin/employees/#{employee.id}/terminate", params: payload, as: :json

      expect(response).to have_http_status(:ok)
      expect(employee.reload).to have_attributes(status: "terminated", termination_date: Date.new(2024, 3, 15))
      expect(response.parsed_body.dig("data", "status_history", 0)).to include(
        "event_type" => "terminated",
        "effective_date" => "2024-03-15",
        "last_worked_on" => "2024-03-14",
        "internal_notes" => "Written notice received by the payroll team."
      )
    end

    it "does not let an accountant perform a status transition" do
      allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(accountant_user)

      post "/api/v1/admin/employees/#{employee.id}/terminate", params: payload, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(employee.reload).to be_active
    end
  end
end
