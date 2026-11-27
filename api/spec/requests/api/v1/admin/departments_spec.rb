# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Departments", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "admin-dept-#{company.id}@example.com",
      name: "Admin User",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::DepartmentsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::DepartmentsController).to receive(:current_user).and_return(admin_user)
  end

  describe "GET /api/v1/admin/departments" do
    context "with departments" do
      before do
        create_list(:department, 3, company: company)
        create(:department, company: company, active: false)
      end

      it "returns all departments for the company" do
        get "/api/v1/admin/departments", params: { company_id: company.id }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(4)
      end

      it "filters by active status" do
        get "/api/v1/admin/departments", params: { company_id: company.id, active: true }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"].length).to eq(3)
        expect(json["data"].all? { |d| d["active"] == true }).to be true
      end

      it "includes employee count" do
        dept = company.departments.first
        create_list(:employee, 3, company: company, department: dept)

        get "/api/v1/admin/departments", params: { company_id: company.id }

        json = response.parsed_body
        dept_data = json["data"].find { |d| d["id"] == dept.id }
        expect(dept_data["employee_count"]).to eq(3)
      end
    end

    context "with no departments" do
      it "returns empty array" do
        get "/api/v1/admin/departments", params: { company_id: company.id }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"]).to eq([])
      end
    end
  end

  describe "POST /api/v1/admin/departments" do
    let(:valid_params) do
      {
        department: {
          name: "Engineering",
          company_id: company.id
        }
      }
    end

    context "with valid params" do
      it "creates a department" do
        expect {
          post "/api/v1/admin/departments", params: valid_params
        }.to change(Department, :count).by(1)

        expect(response).to have_http_status(:created)
        json = response.parsed_body
        expect(json["data"]["name"]).to eq("Engineering")
        expect(json["data"]["active"]).to be true
      end
    end

    context "with invalid params" do
      it "returns error for missing name" do
        post "/api/v1/admin/departments", params: { department: { name: "", company_id: company.id } }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["error"]).to eq("Validation failed")
        expect(json["details"]).to have_key("name")
      end

      it "returns error for duplicate name in same company" do
        create(:department, company: company, name: "Engineering")

        post "/api/v1/admin/departments", params: valid_params

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["details"]).to have_key("name")
      end
    end
  end

  describe "PATCH /api/v1/admin/departments/:id" do
    let!(:department) { create(:department, company: company, name: "Original") }

    context "with valid params" do
      it "updates the department" do
        patch "/api/v1/admin/departments/#{department.id}", params: {
          department: { name: "Updated" }
        }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["data"]["name"]).to eq("Updated")
        expect(department.reload.name).to eq("Updated")
      end

      it "reloads under the company lock and audits the last persisted name" do
        employee = create(:employee, company: company, department: department)
        allow(Department).to receive(:find_by).and_wrap_original do |lookup, **attributes|
          record = lookup.call(**attributes)
          if attributes[:id].to_s == department.id.to_s
            Department.where(id: department.id).update_all(name: "Intervening name")
          end
          record
        end

        patch "/api/v1/admin/departments/#{department.id}", params: { department: { name: "Original" } }

        expect(response).to have_http_status(:ok)
        expect(department.reload.name).to eq("Original")
        audit = AuditLog.find_by!(company_id: company.id, user_id: admin_user.id, action: "departments#update", record_id: department.id)
        expect(audit.metadata.dig("before_values", "name")).to eq("Intervening name")
        activity = AuditLog.find_by!(company_id: company.id, record_type: "Employee", record_id: employee.id,
          action: "employee_organization#update")
        expect(activity.metadata.dig("after_values", "department_name")).to eq("Original")
      end

      it "can deactivate a department" do
        patch "/api/v1/admin/departments/#{department.id}", params: {
          department: { active: false }
        }

        expect(response).to have_http_status(:ok)
        expect(department.reload.active).to be false
      end
    end

    context "with invalid params" do
      it "returns error for duplicate name" do
        create(:department, company: company, name: "Taken")

        patch "/api/v1/admin/departments/#{department.id}", params: {
          department: { name: "Taken" }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["details"]).to have_key("name")
      end
    end

    it "returns 404 for non-existent department" do
      patch "/api/v1/admin/departments/99999", params: {
        department: { name: "Test" }
      }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for department in another company" do
      other_company = create(:company)
      other_department = create(:department, company: other_company)

      patch "/api/v1/admin/departments/#{other_department.id}", params: {
        department: { name: "Blocked" }
      }

      expect(response).to have_http_status(:not_found)
    end
  end
end
