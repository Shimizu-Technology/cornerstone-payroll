# frozen_string_literal: true

require "rails_helper"

# The client namespace serves client-role users only, and only for companies
# they are assigned to. Staff use the admin namespace.
RSpec.describe "Client portal boundary", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "MoSa Boundary QA") }
  let(:other_company) { create(:company, organization: organization, name: "Boundary Bistro QA") }
  let!(:employee) { create(:employee, company: company, first_name: "Lino", last_name: "Quinata", pay_rate: 12) }
  let!(:other_employee) { create(:employee, company: other_company, first_name: "Other", last_name: "Worker") }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }
  let(:client_user) { create(:user, company: company, organization: organization, role: "client", platform_owner: false) }

  def act_as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
  end

  def client_read_paths
    [
      "/api/v1/client/employees",
      "/api/v1/client/employees/#{employee.id}",
      "/api/v1/client/employee_intake_settings",
      "/api/v1/client/departments",
      "/api/v1/client/documents",
      "/api/v1/client/portal_threads",
      "/api/v1/client/employee_change_requests",
      "/api/v1/client/pay_periods",
      "/api/v1/client/reports/dashboard",
      "/api/v1/client/reports/annual_payroll_summary"
    ]
  end

  %w[accountant manager admin org_admin].each do |role|
    context "as #{role} staff" do
      let(:staff_user) { create(:user, company: company, organization: organization, role: role, platform_owner: false) }

      before do
        CompanyAssignment.create!(user: staff_user, company: company)
        act_as(staff_user)
      end

      it "is refused on every client read endpoint" do
        client_read_paths.each do |path|
          get path, headers: headers
          expect(response).to have_http_status(:forbidden), "#{path} returned #{response.status}"
          expect(response.parsed_body.fetch("error")).to eq("Client portal access required")
        end
      end

      it "cannot edit an employee through the client namespace or leave a client-portal audit row" do
        expect do
          patch "/api/v1/client/employees/#{employee.id}", headers: headers,
            params: { employee: { job_title: "Edited by staff", pay_rate: 30 } }
        end.not_to change { [ AuditLog.count, EmployeeChangeRequest.count ] }

        expect(response).to have_http_status(:forbidden)
        expect(employee.reload.job_title).not_to eq("Edited by staff")
      end

      it "cannot create departments or conversations through the client namespace" do
        expect do
          post "/api/v1/client/departments", headers: headers, params: { department: { name: "Staff via portal" } }
        end.not_to change(Department, :count)
        expect(response).to have_http_status(:forbidden)

        expect do
          post "/api/v1/client/portal_threads", headers: headers, params: { subject: "Staff via portal", body: "Hi" }
        end.not_to change(ClientPortalThread, :count)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  context "as a client user" do
    before do
      CompanyAssignment.create!(user: client_user, company: company)
      act_as(client_user)
    end

    it "still reaches every client read endpoint for the assigned company" do
      client_read_paths.each do |path|
        get path, headers: headers
        expect(response).to have_http_status(:ok), "#{path} returned #{response.status}: #{response.body}"
      end
    end

    it "is refused when the request targets an unassigned company" do
      client_read_paths.reject { |path| path.include?("/employees/") }.each do |path|
        get path, headers: { "X-Company-Id" => other_company.id.to_s }
        expect(response).to have_http_status(:forbidden), "#{path} returned #{response.status}"
      end
    end

    it "cannot reach another company's employee through its own company scope" do
      get "/api/v1/client/employees/#{other_employee.id}", headers: headers
      expect(response).to have_http_status(:not_found)

      expect do
        patch "/api/v1/client/employees/#{other_employee.id}", headers: headers,
          params: { employee: { job_title: "Cross-company edit" } }
      end.not_to change(AuditLog, :count)
      expect(response).to have_http_status(:not_found)
      expect(other_employee.reload.job_title).not_to eq("Cross-company edit")

      get "/api/v1/client/employees", headers: headers
      expect(response.parsed_body.fetch("data").map { |row| row.fetch("id") }).to contain_exactly(employee.id)
    end
  end
end
