# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client employee portal safety", type: :request do
  let!(:company) { create(:company, name: "Portal Safety Co") }
  let!(:department) { create(:department, company: company, name: "Kitchen") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "safety-client@example.com") }
  let!(:hourly) do
    create(:employee, company: company, department: department, first_name: "Lino", last_name: "Quinata",
      employment_type: "hourly", pay_rate: 12.00, address_line1: "1 Main St", city: "Hagåtña", state: "GU", zip: "96910")
  end
  let!(:business) do
    create(:employee, :business_contractor, company: company, department: department,
      first_name: "Tano", last_name: "Builders", business_name: "Tano Builders LLC", contractor_ein: "98-7654321")
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user_id).and_return(client_user.id)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_company).and_return(company)
  end

  describe "contractor EIN masking" do
    it "returns only the EIN's last four in the list and the detail" do
      get "/api/v1/client/employees"
      expect(response).to have_http_status(:ok)
      row = response.parsed_body.fetch("data").find { |data| data.fetch("id") == business.id }
      expect(row).not_to have_key("contractor_ein")
      expect(row.fetch("contractor_ein_last_four")).to eq("4321")
      expect(response.body).not_to include("98-7654321", "987654321", "7654321")

      get "/api/v1/client/employees/#{business.id}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).not_to have_key("contractor_ein")
      expect(response.parsed_body.dig("data", "contractor_ein_last_four")).to eq("4321")
      expect(response.body).not_to include("7654321")
    end

    it "does not echo the full EIN after a client update" do
      patch "/api/v1/client/employees/#{business.id}", params: { employee: { job_title: "Framing" } }

      expect(response).to have_http_status(:ok), response.body
      expect(response.body).not_to include("7654321")
      expect(response.parsed_body.dig("data", "contractor_ein_last_four")).to eq("4321")
    end

    it "treats a blank EIN as keeping the stored EIN, like a blank SSN" do
      patch "/api/v1/client/employees/#{business.id}",
        params: { employee: { job_title: "Framing", contractor_ein: "" } }

      expect(response).to have_http_status(:ok), response.body
      expect(EmployeeChangeRequest.count).to eq(0)
      expect(business.reload.contractor_ein).to eq("98-7654321")
    end

    it "submits a replacement EIN for approval without exposing it" do
      patch "/api/v1/client/employees/#{business.id}", params: { employee: { contractor_ein: "12-3456789" } }

      expect(response).to have_http_status(:ok), response.body
      request = EmployeeChangeRequest.order(:id).last
      expect(request.proposed_changes.fetch("contractor_ein")).to eq("Ending in 6789")
      expect(response.body).not_to include("12-3456789", "3456789")
      expect(business.reload.contractor_ein).to eq("98-7654321")

      request.apply!(actor: create(:user, company: company, role: "admin"))
      expect(business.reload.contractor_ein).to eq("12-3456789")
    end
  end

  describe "contractor settings on W-2 workers" do
    before do
      # Older records predate the column defaults; the form fills these in.
      hourly.update_columns(contractor_type: nil, contractor_pay_type: nil, business_name: nil)
    end

    let(:form_payload) do
      {
        pay_rate: 13.50,
        contractor_type: "individual",
        contractor_pay_type: "flat_fee",
        business_name: "",
        contractor_ein: "",
        w9_on_file: false
      }
    end

    it "keeps contractor defaults out of an hourly worker's change request and off the saved worker" do
      patch "/api/v1/client/employees/#{hourly.id}", params: { employee: form_payload }

      expect(response).to have_http_status(:ok), response.body
      request = EmployeeChangeRequest.order(:id).last
      expect(request.proposed_changes.keys).to contain_exactly("pay_rate")
      expect(request.original_values.keys).to contain_exactly("pay_rate")
      expect(response.parsed_body.fetch("change_request").fetch("proposed_changes").keys).to contain_exactly("pay_rate")

      request.apply!(actor: create(:user, company: company, role: "manager").tap { |user| CompanyAssignment.create!(user: user, company: company) })
      hourly.reload
      expect(hourly.pay_rate.to_f).to eq(13.5)
      expect(hourly.contractor_type).to be_nil
      expect(hourly.contractor_pay_type).to be_nil
    end

    it "does not save contractor keys from a request submitted before the fix" do
      request = EmployeeChangeRequest.create!(
        company: company,
        employee: hourly,
        requested_by: client_user,
        request_kind: "update",
        proposed_changes: { "pay_rate" => 13.5, "contractor_type" => "individual", "contractor_pay_type" => "flat_fee" },
        original_values: { "pay_rate" => 12.0, "contractor_type" => nil, "contractor_pay_type" => nil },
        direct_changes_applied: {},
        sensitive_payload: { proposed: {}, original: {} }
      )

      request.apply!(actor: create(:user, company: company, role: "admin"))

      hourly.reload
      expect(request.reload.status).to eq("approved")
      expect(hourly.pay_rate.to_f).to eq(13.5)
      expect(hourly.contractor_type).to be_nil
      expect(hourly.contractor_pay_type).to be_nil
    end

    it "still accepts contractor settings for a contractor" do
      patch "/api/v1/client/employees/#{business.id}", params: { employee: { contractor_pay_type: "hourly" } }

      expect(response).to have_http_status(:ok), response.body
      expect(EmployeeChangeRequest.order(:id).last.proposed_changes).to include("contractor_pay_type" => "hourly")
    end
  end

  describe "list size" do
    it "caps per_page" do
      get "/api/v1/client/employees", params: { per_page: 5000 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "per_page")).to eq(Api::V1::Client::EmployeesController::MAX_PER_PAGE)
    end

    it "keeps an explicit smaller page size" do
      get "/api/v1/client/employees", params: { per_page: 1 }

      expect(response.parsed_body.fetch("data").size).to eq(1)
      expect(response.parsed_body.dig("meta", "total_pages")).to eq(2)
    end
  end

  describe "audit reliability" do
    it "writes exactly one client-portal audit row with the change" do
      expect do
        patch "/api/v1/client/employees/#{hourly.id}", params: { employee: { job_title: "Line Cook" } }
      end.to change(AuditLog, :count).by(1)

      log = AuditLog.order(:id).last
      expect(log.action).to eq("client_employees#update")
      expect(log.metadata.fetch("source")).to eq("client_portal")
      expect(log.user).to eq(client_user)
    end

    it "rolls back an edit when its audit row cannot be written" do
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit insert failed")

      patch "/api/v1/client/employees/#{hourly.id}",
        params: { employee: { job_title: "Unaudited", address_line1: "99 Unaudited Rd", pay_rate: 20 } }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.fetch("error")).to include("was not saved")
      hourly.reload
      expect(hourly.job_title).not_to eq("Unaudited")
      expect(hourly.address_line1).to eq("1 Main St")
      expect(EmployeeChangeRequest.count).to eq(0)
    end

    it "rolls back a new hire when its audit row cannot be written" do
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit insert failed")

      expect do
        post "/api/v1/client/employees", params: {
          employee: {
            first_name: "Nina", last_name: "Newhire", ssn: "123-45-6789", ssn_confirmation: "123-45-6789",
            employment_type: "hourly", pay_rate: 15, filing_status: "single", department_id: department.id,
            hire_date: "2026-04-01", w4_effective_on: "2026-04-01",
            address_line1: "234 Marine Dr", city: "Hagåtña", state: "GU", zip: "96910"
          }
        }
      end.not_to change { [ Employee.count, EmployeeChangeRequest.count ] }

      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
