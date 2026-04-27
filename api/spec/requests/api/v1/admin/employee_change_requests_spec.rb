# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeChangeRequests", type: :request do
  let!(:company) { create(:company, name: "Approvals Co") }
  let!(:department) { create(:department, company: company) }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "approver@example.com") }
  let!(:requester) { create(:user, company: company, role: "client", email: "requester@example.com") }
  let!(:employee) do
    create(:employee,
      company: company,
      department: department,
      first_name: "Mia",
      last_name: "Cruz",
      pay_rate: 18.0,
      additional_withholding: 10.0)
  end
  let!(:change_request) do
    create(:employee_change_request,
      company: company,
      employee: employee,
      requested_by: requester,
      proposed_changes: { pay_rate: 23.5, additional_withholding: 15.0 },
      original_values: { pay_rate: 18.0, additional_withholding: 10.0 })
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeChangeRequestsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::EmployeeChangeRequestsController).to receive(:current_user_id).and_return(admin_user.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeChangeRequestsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "PATCH /api/v1/admin/employee_change_requests/:id/approve" do
    it "applies the pending changes and marks the request approved" do
      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Looks good" }

      expect(response).to have_http_status(:ok)
      expect(employee.reload.pay_rate.to_f).to eq(23.5)
      expect(employee.additional_withholding.to_f).to eq(15.0)

      change_request.reload
      expect(change_request.status).to eq("approved")
      expect(change_request.reviewed_by_id).to eq(admin_user.id)
      expect(change_request.review_notes).to eq("Looks good")
    end

    it "does not re-apply a request that has already been reviewed" do
      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "First review" }

      expect(response).to have_http_status(:ok)
      expect(employee.reload.pay_rate.to_f).to eq(23.5)

      employee.update!(pay_rate: 31.25)

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Second review" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("must be pending")
      expect(employee.reload.pay_rate.to_f).to eq(31.25)
      expect(change_request.reload.review_notes).to eq("First review")
    end
  end

  describe "PATCH /api/v1/admin/employee_change_requests/:id/reject" do
    it "marks the request rejected without changing the employee" do
      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/reject",
        params: { review_notes: "Hold for clarification" }

      expect(response).to have_http_status(:ok)
      expect(employee.reload.pay_rate.to_f).to eq(18.0)

      change_request.reload
      expect(change_request.status).to eq("rejected")
      expect(change_request.review_notes).to eq("Hold for clarification")
    end

    it "does not reject a request that has already been approved" do
      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Approved already" }

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/reject",
        params: { review_notes: "Changing my mind" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("must be pending")
      expect(change_request.reload.status).to eq("approved")
    end
  end
end
