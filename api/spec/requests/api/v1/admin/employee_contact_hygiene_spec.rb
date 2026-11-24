# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin Employee Contact Hygiene", type: :request do
  let(:organization) { create(:organization) }
  let(:company_a) { create(:company, organization: organization, name: "MoSa's Demo") }
  let(:company_b) { create(:company, organization: organization, name: "Island Bakery") }
  let(:other_org) { create(:organization) }
  let(:other_org_company) { create(:company, organization: other_org, name: "External Co") }

  let(:admin_user) { create(:user, company: company_a, organization: organization, role: "org_admin", email: "org-admin-hygiene@example.com") }
  let(:manager_user) do
    user = create(:user, company: company_a, organization: organization, role: "manager", email: "manager-hygiene@example.com")
    CompanyAssignment.create!(user: user, company: company_a)
    user
  end
  let(:accountant_user) do
    user = create(:user, company: company_a, organization: organization, role: "accountant", email: "accountant-hygiene@example.com")
    CompanyAssignment.create!(user: user, company: company_a, client_management: false)
    user
  end
  let(:delegated_accountant) do
    user = create(:user, company: company_a, organization: organization, role: "accountant", email: "delegated-hygiene@example.com")
    CompanyAssignment.create!(user: user, company: company_a, client_management: true, granted_by: admin_user)
    user
  end
  let(:client_user) { create(:user, company: company_a, organization: organization, role: "client", email: "client-hygiene@example.com") }

  before do
    # 5 records sharing a family email at company_a (unmarked -> candidate only, never auto-clearable).
    5.times do |i|
      create(:employee, company: company_a, first_name: "Family#{i}", last_name: "Cruz", status: "active",
                        email: "cruz.family@example.com")
    end

    # Shared inbox across company_a and company_b (unmarked initially, later explicitly marked as placeholder).
    3.times do |i|
      create(:employee, company: company_a, first_name: "ActiveA#{i}", last_name: "Worker", status: "active",
                        email: "shared-inbox@example.com", email_verified_at: 1.day.ago)
    end
    create(:employee, company: company_a, first_name: "InactiveA", last_name: "Worker", status: "inactive",
                      email: "shared-inbox@example.com")
    2.times do |i|
      create(:employee, company: company_b, first_name: "ActiveB#{i}", last_name: "Worker", status: "active",
                        email: "shared-inbox@example.com")
    end

    # Structural placeholder email.
    create(:employee, company: company_a, first_name: "Placeholder", last_name: "Person", status: "active",
                      email: "noemail@example.com")
    # Unique personal email.
    create(:employee, company: company_a, first_name: "Unique", last_name: "Person", status: "active",
                      email: "unique.person@example.com", phone: "+16715550199")
    # Other organization record.
    create(:employee, company: other_org_company, first_name: "OtherOrg", last_name: "Person", status: "active",
                      email: "noemail@example.com")
  end

  describe "GET /api/v1/admin/employee_contact_hygiene/shared_emails" do
    it "surfaces duplicate candidates without marking them clearable and scopes counts to configurable companies" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      body = response.parsed_body

      company_a_entry = body["companies"].find { |c| c["company_id"] == company_a.id }
      family_entry = company_a_entry["emails"].find { |e| e["email"] == "cruz.family@example.com" }
      expect(family_entry).to include(
        "total_count" => 5,
        "classification" => "shared",
        "clearable" => false,
        "marked_placeholder" => false
      )

      placeholder_entry = company_a_entry["emails"].find { |e| e["email"] == "noemail@example.com" }
      expect(placeholder_entry).to include(
        "total_count" => 1,
        "classification" => "placeholder",
        "clearable" => true
      )

      # Never leaks unique personal emails, other orgs, or employee names/phones.
      expect(response.body).not_to include("unique.person@example.com", "ActiveA0", "External Co", "+16715550199")
    end

    it "scopes organization_total_count and companies_count strictly to companies the staff user can configure" do
      # delegated_accountant can configure company_a ONLY (not company_b).
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(delegated_accountant)

      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      body = response.parsed_body

      expect(body["companies"].map { |c| c["company_id"] }).to eq([ company_a.id ])
      shared_entry = body["companies"].first["emails"].find { |e| e["email"] == "shared-inbox@example.com" }
      expect(shared_entry).to include(
        "total_count" => 4,
        "companies_count" => 1,
        "organization_total_count" => 4
      )
      expect(shared_entry["reasons"]).not_to include("shared_across_companies")
    end

    it "forbids accountants without client management and client users" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(accountant_user)
      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      expect(response).to have_http_status(:forbidden)

      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "explicit placeholder marking and bulk clear" do
    it "refuses to bulk-clear an unmarked family duplicate even with 5 records" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "cruz.family@example.com" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/mark this address as a placeholder/i)
      expect(company_a.employees.where("LOWER(email) = ?", "cruz.family@example.com").count).to eq(5)
    end

    it "allows staff to explicitly mark a placeholder (audited), bulk-clear one company at a time, and retry idempotently as a 200 no-op" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      # Unmarked shared-inbox@example.com cannot be bulk-cleared yet.
      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "shared-inbox@example.com" }
      expect(response).to have_http_status(:unprocessable_entity)

      # Staff marks shared-inbox@example.com as a placeholder (audited).
      expect do
        post "/api/v1/admin/employee_contact_hygiene/placeholder_emails",
             headers: { "X-Company-Id" => company_a.id.to_s },
             params: { email: "Shared-Inbox@example.com", reason: "Old MoSa shared inbox" }
      end.to change(EmployeePlaceholderEmail, :count).by(1)
        .and change { AuditLog.where(action: "employee_contact_hygiene#mark_placeholder_email").count }.by(1)

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["data"]).to include("email" => "shared-inbox@example.com", "marked" => true, "changed" => true)

      # Report and validator now agree it is a clearable placeholder.
      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      company_a_entry = response.parsed_body["companies"].find { |c| c["company_id"] == company_a.id }
      shared_entry = company_a_entry["emails"].find { |e| e["email"] == "shared-inbox@example.com" }
      expect(shared_entry).to include("classification" => "placeholder", "clearable" => true, "marked_placeholder" => true)

      # Bulk-clear company_a only.
      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "shared-inbox@example.com" }

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["data"]).to include(
        "company_id" => company_a.id,
        "email" => "shared-inbox@example.com",
        "cleared_count" => 4,
        "active_cleared_count" => 3,
        "inactive_cleared_count" => 1
      )
      expect(company_a.employees.where("LOWER(email) = ?", "shared-inbox@example.com").count).to eq(0)
      expect(company_b.employees.where("LOWER(email) = ?", "shared-inbox@example.com").count).to eq(2)

      # Retry after a successful clear returns 200 with 0 rows changed and writes NO duplicate audit rows.
      expect do
        post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
             headers: { "X-Company-Id" => company_a.id.to_s },
             params: { company_id: company_a.id, email: "shared-inbox@example.com" }
      end.not_to change(AuditLog, :count)

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["data"]).to include("cleared_count" => 0, "active_cleared_count" => 0, "inactive_cleared_count" => 0)

      # Unmarking removes it from the placeholder list with an audit row.
      expect do
        delete "/api/v1/admin/employee_contact_hygiene/placeholder_emails",
               headers: { "X-Company-Id" => company_a.id.to_s },
               params: { email: "shared-inbox@example.com" }
      end.to change(EmployeePlaceholderEmail, :count).by(-1)
        .and change { AuditLog.where(action: "employee_contact_hygiene#unmark_placeholder_email").count }.by(1)
      expect(response).to have_http_status(:ok)
    end

    it "allows managers on assigned companies to clear structural placeholders and rejects unassigned companies" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(manager_user)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_b.id, email: "noemail@example.com" }
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "noemail@example.com" }
      expect(response).to have_http_status(:ok)
    end
  end
end
