# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee Contact Details API (Staff and Client)", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:admin_user) { create(:user, company: company, organization: organization, role: "admin", email: "staff-contact@example.com", name: "Staff Admin") }
  let(:client_user) do
    user = create(:user, company: company, organization: organization, role: "client", email: "emma.client@example.com", name: "Elena Mercer")
    CompanyAssignment.create!(user: user, company: company)
    user
  end

  let!(:complete_employee) do
    create(
      :employee,
      company: company,
      first_name: "Complete",
      last_name: "Worker",
      email: "complete.worker@example.com",
      phone: "+16715550101",
      email_verified_at: 2.days.ago,
      phone_confirmed_by_employee_at: 2.days.ago
    )
  end
  let!(:missing_contact_employee) do
    create(
      :employee,
      company: company,
      first_name: "Emma",
      last_name: "Mercer",
      email: nil,
      phone: nil
    )
  end

  describe "needs_contact_details count and filter" do
    it "returns needs_contact_details_count and filters properly on admin employees index" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      get "/api/v1/admin/employees", headers: { "X-Company-Id" => company.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("meta", "needs_contact_details_count")).to eq(1)
      expect(response.parsed_body["data"].size).to eq(2)

      get "/api/v1/admin/employees", headers: { "X-Company-Id" => company.id.to_s }, params: { needs_contact_details: "true" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "needs_contact_details_count")).to eq(1)
      expect(response.parsed_body["data"].map { |row| row["id"] }).to eq([ missing_contact_employee.id ])
      expect(response.parsed_body["data"].first.dig("contact_details_status", "missing_fields")).to include("email", "phone")
    end

    it "returns needs_contact_details_count and filters properly on client employees index" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      get "/api/v1/client/employees", headers: { "X-Company-Id" => company.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("meta", "needs_contact_details_count")).to eq(1)

      get "/api/v1/client/employees", headers: { "X-Company-Id" => company.id.to_s }, params: { needs_contact_details: "true" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["id"] }).to eq([ missing_contact_employee.id ])
    end
  end

  describe "verification clearing, normalization, warnings, and same-person confirmation" do
    it "clears email_verified_at and phone_confirmed_by_employee_at when admin updates email/phone and records history" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      # Unrelated edit keeps verification timestamps intact.
      patch "/api/v1/admin/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { job_title: "Lead" } }
      expect(response).to have_http_status(:ok), response.body
      expect(complete_employee.reload.email_verified_at).to be_present
      expect(complete_employee.phone_confirmed_by_employee_at).to be_present

      # Contact edit normalizes Guam phone, sets source, and clears verification.
      patch "/api/v1/admin/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: "Updated.Worker@Example.com", phone: "555-0188" } }
      expect(response).to have_http_status(:ok), response.body
      complete_employee.reload
      expect(complete_employee.email).to eq("updated.worker@example.com")
      expect(complete_employee.phone).to eq("+16715550188")
      expect(complete_employee.contact_source).to eq("staff")
      expect(complete_employee.email_verified_at).to be_nil
      expect(complete_employee.phone_confirmed_by_employee_at).to be_nil

      history = RecordActivityQuery.new(record_type: "employees", record_id: complete_employee.id, company_id: company.id).call
      latest = history.newest_first.first
      expect(latest.metadata["changed_fields"]).to include("email", "phone", "contact_source", "email_verified_at")
    end

    it "clears email_verified_at when a client user updates email and returns coworker warnings" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      create(:employee, company: company, first_name: "Sibling", last_name: "Worker", email: "family.shared@example.com")

      patch "/api/v1/client/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: "family.shared@example.com", phone: "555-0177" } }

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["contact_warnings"].first).to include("code" => "shared_company_email")
      complete_employee.reload
      expect(complete_employee.email).to eq("family.shared@example.com")
      expect(complete_employee.phone).to eq("+16715550177")
      expect(complete_employee.contact_source).to eq("client")
      expect(complete_employee.email_verified_at).to be_nil
    end

    it "blocks placeholder emails and another person's staff login on both admin and client updates" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: "noemail@example.com" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "email").first).to match(/placeholder/i)

      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: admin_user.email }, confirm_same_person_email: true }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("contact_validation", "same_person_confirmation_required")).to be(false)
    end

    it "supports audited same-person confirmation for an unlinked dual-role login on both client and admin endpoints" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      # First attempt without confirmation returns 422 with same_person_confirmation_required: true.
      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: client_user.email } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("contact_validation", "same_person_confirmation_required")).to be(true)

      # Second attempt with explicit confirmation succeeds and is audited.
      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: client_user.email }, confirm_same_person_email: true }
      expect(response).to have_http_status(:ok), response.body
      expect(missing_contact_employee.reload.email).to eq("emma.client@example.com")

      audit = AuditLog.where(action: "client_employees#update", record_id: missing_contact_employee.id).newest_first.first
      expect(audit.metadata).to include(
        "same_person_email_confirmed" => true,
        "confirmed_login_user_id" => client_user.id
      )
    end

    it "supports search by email and AuditRecordSnapshot.subject_name fallback safely" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      get "/api/v1/admin/employees", headers: { "X-Company-Id" => company.id.to_s }, params: { search: "complete.worker@example.com" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["id"] }).to eq([ complete_employee.id ])

      expect(AuditRecordSnapshot.subject_name(complete_employee)).to eq("Complete Worker")
      expect(AuditRecordSnapshot.subject_name(missing_contact_employee)).to eq("Elena Mercer")
      email_only = Struct.new(:email).new("fallback@example.com")
      expect(AuditRecordSnapshot.subject_name(email_only)).to eq("fallback@example.com")
    end
  end
end
