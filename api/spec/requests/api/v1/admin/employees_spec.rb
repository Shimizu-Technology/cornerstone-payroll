# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Employees", type: :request do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company: company) }

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

      it "paginates results" do
        get "/api/v1/admin/employees", params: { company_id: company.id, per_page: 2 }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(2)
        expect(json["meta"]["total_pages"]).to eq(2)
        expect(json["meta"]["total_count"]).to eq(4)
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
  end

  describe "POST /api/v1/admin/employees" do
    let(:valid_params) do
      {
        employee: {
          first_name: "John",
          last_name: "Doe",
          email: "john.doe@example.com",
          ssn: "123-45-6789",
          hire_date: "2024-01-15",
          date_of_birth: "1990-05-20",
          employment_type: "hourly",
          pay_rate: 15.00,
          filing_status: "single",
          allowances: 1,
          department_id: department.id,
          company_id: company.id
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
    end

    context "with invalid params" do
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
      end

      it "updates pay rate" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { pay_rate: 25.00 }
        }

        expect(response).to have_http_status(:ok)
        expect(employee.reload.pay_rate).to eq(25.00)
      end
    end

    context "with invalid params" do
      it "returns validation errors" do
        patch "/api/v1/admin/employees/#{employee.id}", params: {
          employee: { pay_rate: -5 }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["details"]).to have_key("pay_rate")
      end
    end
  end

  describe "DELETE /api/v1/admin/employees/:id" do
    let!(:employee) { create(:employee, company: company, status: "active") }

    it "soft deletes the employee by setting terminated status" do
      delete "/api/v1/admin/employees/#{employee.id}"

      expect(response).to have_http_status(:no_content)
      expect(employee.reload.status).to eq("terminated")
      expect(employee.termination_date).to eq(Date.current)
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
