# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee Contact Details API (Staff and Client)", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:other_organization) { create(:organization) }
  let(:other_company) { create(:company, organization: other_organization) }

  let(:admin_user) { create(:user, company: company, organization: organization, role: "admin", email: "staff-contact@example.com", name: "Dafne Staff") }
  let(:client_user) do
    user = create(:user, company: company, organization: organization, role: "client", email: "emma.client@example.com", name: "Elena Mercer")
    CompanyAssignment.create!(user: user, company: company)
    user
  end
  let(:other_client_user) do
    user = create(:user, company: company, organization: organization, role: "client", email: "sara.client@example.com", name: "Sloane Owner")
    CompanyAssignment.create!(user: user, company: company)
    user
  end
  let!(:other_tenant_user) do
    create(:user, company: other_company, organization: other_organization, role: "client", email: "external.login@example.com", name: "External Admin")
  end

  let!(:complete_employee) do
    create(
      :employee,
      company: company,
      first_name: "Complete",
      last_name: "Worker",
      email: "complete.worker@example.com",
      phone: "+16715550101",
      address_line1: "100 Marine Corps Dr",
      city: "Hagatna",
      state: "GU",
      zip: "96910",
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
    it "returns needs_contact_details_count, contact_revision, and filters properly on admin employees index" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      get "/api/v1/admin/employees", headers: { "X-Company-Id" => company.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("meta", "needs_contact_details_count")).to eq(1)
      expect(response.parsed_body["data"].size).to eq(2)
      expect(response.parsed_body["data"].first["contact_revision"]).to be_present

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

  describe "login email identity, generic client errors, and transactional audit" do
    it "rejects a name-match attempt on another person's login even if the client edits the employee's name to match" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: {
              employee: { first_name: "Sara", last_name: "Owner", email: other_client_user.email },
              confirm_same_person_email: true
            }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("contact_validation", "same_person_confirmation_required")).to be(false)
      expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
      expect(response.body).not_to include("Sloane Owner")
      expect(missing_contact_employee.reload.email).to be_nil
    end

    it "returns one generic client error without leaking names or roles for staff and other-tenant logins" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      [ admin_user.email, other_tenant_user.email, other_client_user.email ].each do |login_email|
        patch "/api/v1/client/employees/#{missing_contact_employee.id}",
              headers: { "X-Company-Id" => company.id.to_s },
              params: { employee: { email: login_email } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.dig("contact_validation", "same_person_confirmation_required")).to be(false)
        expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
        expect(response.body).not_to include("Dafne", "External Admin", "Sloane Owner", "admin")
      end
    end

    it "accepts the signed-in user's own login email with explicit 'this is me' confirmation and audits it in the same transaction" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      # First attempt without confirmation asks for 'this is me' confirmation.
      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: client_user.email } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("contact_validation", "same_person_confirmation_required")).to be(true)

      # Second attempt with confirmation succeeds and writes confirmation audit.
      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: client_user.email }, confirm_same_person_email: true }
      expect(response).to have_http_status(:ok), response.body
      expect(missing_contact_employee.reload.email).to eq(client_user.email)

      confirm_audit = AuditLog.where(action: "employees#confirm_same_person_email", record_id: missing_contact_employee.id).newest_first.first
      expect(confirm_audit).to be_present
      expect(confirm_audit.metadata).to include(
        "same_person_email_confirmed" => true,
        "confirmed_login_user_id" => client_user.id,
        "confirmation_basis" => "self_confirmed"
      )
    end

    it "rolls back the admin save if writing the same-person confirmation audit row fails" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      allow(AuditLog).to receive(:record!).and_call_original
      allow(AuditLog).to receive(:record!).with(hash_including(action: "employees#confirm_same_person_email")).and_raise(ActiveRecord::StatementInvalid, "audit write failed")

      expect do
        patch "/api/v1/admin/employees/#{missing_contact_employee.id}",
              headers: { "X-Company-Id" => company.id.to_s },
              params: { employee: { email: client_user.email }, confirm_same_person_email: true }
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect(missing_contact_employee.reload.email).to be_nil
    end

    it "rejects a login already linked to a different employee on both client and admin endpoints" do
      EmployeeAccountLink.create!(company: company, employee: complete_employee, user: client_user, status: "active")

      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      patch "/api/v1/client/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: client_user.email }, confirm_same_person_email: true }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])

      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)
      patch "/api/v1/admin/employees/#{missing_contact_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { email: client_user.email }, confirm_same_person_email: true }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "email").first).to match(/already linked to another employee/i)
      expect(missing_contact_employee.reload.email).to be_nil
    end
  end

  describe "partial saves, verification clearing, and stale row revision 409 conflicts" do
    it "keeps the address untouched on a phone-only save" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      revision = complete_employee.contact_revision

      patch "/api/v1/client/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: {
              employee: { phone: "555-0199" },
              row_revision: revision,
              baseline_values: { phone: complete_employee.phone }
            }

      expect(response).to have_http_status(:ok), response.body
      complete_employee.reload
      expect(complete_employee.phone).to eq("+16715550199")
      expect(complete_employee.address_line1).to eq("100 Marine Corps Dr")
      expect(complete_employee.city).to eq("Hagatna")
      expect(complete_employee.zip).to eq("96910")
      expect(complete_employee.email).to eq("complete.worker@example.com")
      expect(complete_employee.email_verified_at).to be_present
      expect(complete_employee.phone_confirmed_by_employee_at).to be_nil
    end

    it "returns 409 with current values when a stale revision collides with a coworker's edit" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      stale_revision = complete_employee.contact_revision
      original_phone = complete_employee.phone

      # Coworker updates phone first.
      complete_employee.update!(phone: "+16715550144", updated_at: complete_employee.updated_at + 5.seconds)

      # Client tries to save phone with stale revision and old baseline -> 409.
      patch "/api/v1/client/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: {
              employee: { phone: "555-0188" },
              row_revision: stale_revision,
              baseline_values: { phone: original_phone }
            }

      expect(response).to have_http_status(:conflict), response.body
      body = response.parsed_body
      expect(body["code"]).to eq("contact_revision_conflict")
      expect(body["conflicting_fields"]).to eq([ "phone" ])
      expect(body.dig("current_values", "phone")).to eq("+16715550144")
      expect(body["contact_revision"]).to eq(complete_employee.reload.contact_revision)
      expect(complete_employee.phone).to eq("+16715550144")

      # Admin endpoint also returns 409 on stale revision without baseline_values.
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)
      patch "/api/v1/admin/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: {
              employee: { email: "new.email@example.com" },
              row_revision: stale_revision
            }
      expect(response).to have_http_status(:conflict), response.body
      expect(response.parsed_body["code"]).to eq("contact_revision_conflict")
      expect(complete_employee.reload.email).to eq("complete.worker@example.com")
    end

    it "merges cleanly when a coworker edited a different field than the submitted fields" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      stale_revision = complete_employee.contact_revision
      original_phone = complete_employee.phone

      # Coworker updates address only.
      complete_employee.update!(address_line1: "200 Chalan San Antonio", updated_at: complete_employee.updated_at + 5.seconds)

      # User saves phone only with baseline matching current DB phone -> succeeds and keeps coworker's address!
      patch "/api/v1/client/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: {
              employee: { phone: "555-0177" },
              row_revision: stale_revision,
              baseline_values: { phone: original_phone }
            }

      expect(response).to have_http_status(:ok), response.body
      complete_employee.reload
      expect(complete_employee.phone).to eq("+16715550177")
      expect(complete_employee.address_line1).to eq("200 Chalan San Antonio")
    end

    it "clears email_verified_at and phone_confirmed_by_employee_at when admin updates email/phone and records history" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      patch "/api/v1/admin/employees/#{complete_employee.id}",
            headers: { "X-Company-Id" => company.id.to_s },
            params: { employee: { job_title: "Lead" } }
      expect(response).to have_http_status(:ok), response.body
      expect(complete_employee.reload.email_verified_at).to be_present
      expect(complete_employee.phone_confirmed_by_employee_at).to be_present

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
