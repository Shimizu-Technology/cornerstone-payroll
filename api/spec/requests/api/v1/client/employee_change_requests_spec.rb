# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::EmployeeChangeRequests", type: :request do
  let!(:company) { create(:company, name: "Client Request Co") }
  let!(:department) { create(:department, company: company, name: "Payroll") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "requester@example.com") }
  let!(:other_client_user) { create(:user, company: company, role: "client", email: "other-requester@example.com") }
  let!(:employee) do
    create(:employee,
      company: company,
      department: department,
      first_name: "Mia",
      last_name: "Cruz")
  end
  let!(:other_employee) do
    create(:employee,
      company: company,
      department: department,
      first_name: "Noah",
      last_name: "Santos")
  end
  let!(:own_request) do
    create(:employee_change_request,
      company: company,
      employee: employee,
      requested_by: client_user,
      proposed_changes: { ssn_encrypted: "123-45-6789", pay_rate: 21.5 },
      original_values: { ssn_encrypted: "987-65-4321", pay_rate: 18.0 },
      direct_changes_applied: { ssn_encrypted: "123-45-6789" })
  end
  let!(:other_request) do
    create(:employee_change_request,
      company: company,
      employee: other_employee,
      requested_by: other_client_user,
      proposed_changes: { pay_rate: 24.0 },
      original_values: { pay_rate: 18.0 })
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    CompanyAssignment.create!(user: other_client_user, company: company)
    allow_any_instance_of(Api::V1::Client::EmployeeChangeRequestsController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::EmployeeChangeRequestsController).to receive(:current_user_id).and_return(client_user.id)
    allow_any_instance_of(Api::V1::Client::EmployeeChangeRequestsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "GET /api/v1/client/employee_change_requests" do
    it "returns only the current client's requests" do
      get "/api/v1/client/employee_change_requests"

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body.fetch("data").map { |row| row.fetch("id") }
      expect(ids).to contain_exactly(own_request.id)
    end
  end

  describe "GET /api/v1/client/employee_change_requests/:id" do
    it "returns the request payload for the request owner with sensitive fields redacted" do
      get "/api/v1/client/employee_change_requests/#{own_request.id}"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.dig("proposed_changes", "ssn_encrypted")).to eq("[REDACTED]")
      expect(data.dig("original_values", "ssn_encrypted")).to eq("[REDACTED]")
      expect(data.dig("direct_changes_applied", "ssn_encrypted")).to eq("[REDACTED]")
      expect(data.dig("proposed_changes", "pay_rate")).to eq(21.5)
    end

    it "does not allow a client to fetch another client's request in the same company" do
      get "/api/v1/client/employee_change_requests/#{other_request.id}"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.fetch("error")).to eq("Change request not found")
    end
  end
end
