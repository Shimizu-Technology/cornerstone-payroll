# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client management delayed request revocation", type: :request do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: :org_admin) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let!(:assignment) { create(:company_assignment, user: actor, company: company, granted_by: admin, client_management: true) }
  let!(:employee) { create(:employee, company: company, pay_rate: 18) }
  let(:year_input) do
    { tax_year: 2026, prior_year_wage_status: "unknown", source_reference: "Employee signed statement",
      reason: "Verified annual evidence" }
  end
  let(:reminder_attributes) { { enabled: true, days_before_due: 2, recipients: [ "payroll@example.test" ] } }

  def authenticate(controller)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_company).and_return(company)
  end

  def revoke_during_lock(model)
    allow_any_instance_of(model).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
  end

  %w[approve reject].each do |action|
    context "employee change #{action}" do
      let!(:change_request) do
        create(:employee_change_request, company: company, employee: employee,
          requested_by: create(:user, company: company, organization: company.organization, role: :client),
          proposed_changes: { pay_rate: 23.5 }, original_values: { pay_rate: 18 })
      end
      let(:path) { "/api/v1/admin/employee_change_requests/#{change_request.id}/#{action}" }

      before { authenticate(Api::V1::Admin::EmployeeChangeRequestsController) }

      it "allows an explicitly granted accountant to #{action} without changing their role" do
        patch path, params: { review_notes: "Reviewed evidence" }
        expect(response).to have_http_status(:ok), response.body
        expect(change_request.reload.status).to eq(action == "approve" ? "approved" : "rejected")
        expect(actor.reload.role).to eq("accountant")
      end

      it "leaves employee, request and audit unchanged after revocation during request locking" do
        revoke_during_lock(EmployeeChangeRequest)
        expect(AuditLog).not_to receive(:record!)

        patch path, params: { review_notes: "Reviewed evidence" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("error")).to include("Client configuration access required")
        expect(change_request.reload).to have_attributes(status: "pending", reviewed_by_id: nil, reviewed_at: nil)
        expect(employee.reload.pay_rate).to eq(18.to_d)
      end
    end
  end

  context "retirement year inputs" do
    let(:path) { "/api/v1/admin/employees/#{employee.id}/retirement_year_inputs" }
    before { authenticate(Api::V1::Admin::EmployeeRetirementYearInputsController) }

    it "allows a granted accountant to append audited client evidence" do
      expect { post path, params: { retirement_year_input: year_input } }.to change(EmployeeRetirementYearInput, :count).by(1)
      expect(response).to have_http_status(:created), response.body
      expect(EmployeeRetirementYearInput.last).to have_attributes(company_id: company.id, created_by_id: actor.id)
      expect(AuditLog.where(action: "employee_retirement_year_inputs#create", company_id: company.id)).to exist
    end

    it "writes no evidence or audit after revocation during employee locking" do
      revoke_during_lock(Employee)
      expect(AuditLog).not_to receive(:record!)

      expect { post path, params: { retirement_year_input: year_input } }.not_to change(EmployeeRetirementYearInput, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  context "retirement elections" do
    let(:path) { "/api/v1/admin/employees/#{employee.id}/retirement_elections" }
    let(:attributes) { { effective_on: Date.current, participating: true, traditional_rate: 0.06, reason: "Signed election" } }
    before { authenticate(Api::V1::Admin::EmployeeRetirementElectionsController) }

    it "allows a granted accountant to append an election and synchronize the legacy rate" do
      post path, params: { retirement_election: attributes }

      expect(response).to have_http_status(:created), response.body
      expect(employee.employee_retirement_elections.sole.created_by_id).to eq(actor.id)
      expect(employee.reload.retirement_rate).to eq(0.06.to_d)
      expect(actor.reload.role).to eq("accountant")
    end

    it "writes no election, legacy rate or audit after revocation during employee locking" do
      original_rate = employee.retirement_rate
      revoke_during_lock(Employee)
      expect(AuditLog).not_to receive(:record!)

      expect { post path, params: { retirement_election: attributes } }.not_to change(EmployeeRetirementElection, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Client configuration access required")
      expect(employee.reload.retirement_rate).to eq(original_rate)
    end
  end

  context "reminder configuration" do
    before { authenticate(Api::V1::Admin::PayrollReminderConfigsController) }

    it "allows a granted accountant to save client reminder settings" do
      put "/api/v1/admin/payroll_reminder_config", params: { payroll_reminder_config: reminder_attributes }
      expect(response).to have_http_status(:ok), response.body
      expect(company.reload.payroll_reminder_config).to have_attributes(enabled: true, days_before_due: 2)
    end

    it "does not save or audit after revocation during the company lock" do
      config = create(:payroll_reminder_config, company: company, days_before_due: 3)
      revoke_during_lock(Company)
      expect(AuditLog).not_to receive(:record!)

      put "/api/v1/admin/payroll_reminder_config", params: { payroll_reminder_config: reminder_attributes }

      expect(response).to have_http_status(:forbidden)
      expect(config.reload).to have_attributes(enabled: false, days_before_due: 3, recipients: [])
    end

    it "rechecks after waiting for the existing reminder row as well as the company" do
      config = create(:payroll_reminder_config, company: company, days_before_due: 3)
      revoke_during_lock(PayrollReminderConfig)
      expect(AuditLog).not_to receive(:record!)

      put "/api/v1/admin/payroll_reminder_config", params: { payroll_reminder_config: reminder_attributes }

      expect(response).to have_http_status(:forbidden)
      expect(config.reload).to have_attributes(enabled: false, days_before_due: 3, recipients: [])
    end

    context "provider dispatch" do
      before do
        create(:payroll_reminder_config, company: company, **reminder_attributes)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("RESEND_API_KEY").and_return("synthetic-test-key")
        allow(ENV).to receive(:[]).with("RESEND_FROM_EMAIL").and_return("payroll@example.test")
      end

      it "sends the granted client's test through the stubbed provider" do
        expect(Resend::Emails).to receive(:send).with(hash_including(to: "payroll@example.test")).once
        post "/api/v1/admin/payroll_reminder_config/test"
        expect(response).to have_http_status(:ok), response.body
      end

      it "does not dispatch or audit after revocation while preparing email content" do
        allow_any_instance_of(Api::V1::Admin::PayrollReminderConfigsController).to receive(:test_email_html).and_wrap_original do |original|
          html = original.call
          assignment.update!(client_management: false)
          html
        end
        expect(Resend::Emails).not_to receive(:send)
        expect(AuditLog).not_to receive(:record!)

        post "/api/v1/admin/payroll_reminder_config/test"

        expect(response).to have_http_status(:forbidden)
      end

      it "rechecks before each recipient and stops after a grant is revoked by the first dispatch" do
        company.payroll_reminder_config.update!(recipients: [ "first@example.test", "second@example.test" ])
        expect(Resend::Emails).to receive(:send).with(hash_including(to: "first@example.test")).once do
          assignment.update!(client_management: false)
        end
        expect(Resend::Emails).not_to receive(:send).with(hash_including(to: "second@example.test"))
        expect(AuditLog).not_to receive(:record!)

        post "/api/v1/admin/payroll_reminder_config/test"

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
