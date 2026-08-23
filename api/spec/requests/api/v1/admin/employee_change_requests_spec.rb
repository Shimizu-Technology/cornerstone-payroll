# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeChangeRequests", type: :request do
  let!(:company) { create(:company, name: "Approvals Co") }
  let!(:other_company) { create(:company, name: "Other Co") }
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

    it "blocks approval when the reviewed source values changed after submission" do
      employee.update!(pay_rate: 19.75)

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Approve stale request" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Employee data changed after this request was submitted: pay_rate")
      expect(employee.reload.pay_rate.to_f).to eq(19.75)
      expect(change_request.reload.status).to eq("pending")
      expect(change_request.reviewed_at).to be_nil
    end

    it "never exposes a legacy plaintext SSN in the admin review payload" do
      change_request.update!(
        proposed_changes: { ssn_encrypted: "123-45-6789" },
        original_values: { ssn_encrypted: "987-65-4321" }
      )

      get "/api/v1/admin/employee_change_requests/#{change_request.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "proposed_changes", "ssn_encrypted")).to eq("***-**-6789")
      expect(response.parsed_body.dig("data", "original_values", "ssn_encrypted")).to eq("***-**-4321")
      expect(response.body).not_to include("123-45-6789", "987-65-4321")
    end

    it "fails closed when a legacy request lacks an encrypted identifier payload" do
      original_ssn = employee.ssn_encrypted
      change_request.update!(
        proposed_changes: { ssn_encrypted: "123-45-6789" },
        original_values: { ssn_encrypted: original_ssn }
      )

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Approve legacy request" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("must be resubmitted securely: ssn_encrypted")
      expect(employee.reload.ssn_encrypted).to eq(original_ssn)
      expect(change_request.reload.status).to eq("pending")
    end

    it "applies an encrypted SSN replacement without returning the full identifier" do
      original_ssn = employee.ssn_encrypted
      change_request.update!(
        proposed_changes: { ssn_encrypted: "***-**-6789" },
        original_values: { ssn_encrypted: "***-**-#{employee.ssn_last_four}" },
        sensitive_payload: {
          proposed: { ssn_encrypted: "123-45-6789" },
          original: { ssn_encrypted: original_ssn }
        }
      )

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Identity document verified" }

      expect(response).to have_http_status(:ok), response.body
      expect(employee.reload.ssn_encrypted).to eq("123-45-6789")
      expect(response.parsed_body.dig("data", "proposed_changes", "ssn_encrypted")).to eq("***-**-6789")
      expect(response.body).not_to include("123-45-6789")
    end

    it "rejects unsupported employee attributes from proposed changes" do
      change_request.update!(
        proposed_changes: {
          pay_rate: 23.5,
          company_id: other_company.id
        }
      )

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Looks good" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("unsupported fields: company_id")
      expect(employee.reload.company_id).to eq(company.id)
      expect(employee.pay_rate.to_f).to eq(18.0)
      expect(change_request.reload.status).to eq("pending")
    end

    it "does not delete omitted wage rates when approving a partial wage-rate change request" do
      regular_rate = employee.employee_wage_rates.create!(
        label: "Regular",
        rate: 18.0,
        is_primary: true,
        active: true
      )
      employee.employee_wage_rates.create!(
        label: "Overtime",
        rate: 27.0,
        is_primary: false,
        active: true
      )

      change_request.update!(
        proposed_changes: {
          wage_rates: [
            {
              id: regular_rate.id,
              label: "Regular",
              rate: 19.25,
              is_primary: true,
              active: true
            }
          ]
        }
      )

      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve",
        params: { review_notes: "Update one rate only" }

      expect(response).to have_http_status(:ok)
      expect(employee.reload.employee_wage_rates.order(:label).pluck(:label, :rate).map { |label, rate| [ label, rate.to_f ] }).to eq([
        [ "Overtime", 27.0 ],
        [ "Regular", 19.25 ]
      ])
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
