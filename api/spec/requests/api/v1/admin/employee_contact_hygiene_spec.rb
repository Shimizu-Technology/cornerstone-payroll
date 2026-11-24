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
    # Real shape of the data: one shared inbox across companies + a placeholder + a unique personal email.
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
    create(:employee, company: company_a, first_name: "Placeholder", last_name: "Person", status: "active",
                      email: "noemail@example.com")
    create(:employee, company: company_a, first_name: "Unique", last_name: "Person", status: "active",
                      email: "unique.person@example.com", phone: "+16715550199")
    create(:employee, company: other_org_company, first_name: "OtherOrg", last_name: "Person", status: "active",
                      email: "noemail@example.com")
  end

  describe "GET /api/v1/admin/employee_contact_hygiene/shared_emails" do
    it "lists shared and placeholder emails by company with counts and no other personal data" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }

      expect(response).to have_http_status(:ok), response.body
      body = response.parsed_body

      expect(body["summary"]).to eq(
        "companies_affected" => 2,
        "distinct_flagged_emails" => 2,
        "total_employee_records" => 7,
        "active_employee_records" => 6
      )

      company_a_entry = body["companies"].find { |c| c["company_id"] == company_a.id }
      expect(company_a_entry).to be_present
      expect(company_a_entry["total_flagged_records"]).to eq(5)
      expect(company_a_entry["active_flagged_records"]).to eq(4)

      shared_entry = company_a_entry["emails"].find { |e| e["email"] == "shared-inbox@example.com" }
      expect(shared_entry).to include(
        "total_count" => 4,
        "active_count" => 3,
        "inactive_count" => 1,
        "companies_count" => 2,
        "organization_total_count" => 6,
        "classification" => "shared_inbox"
      )

      placeholder_entry = company_a_entry["emails"].find { |e| e["email"] == "noemail@example.com" }
      expect(placeholder_entry).to include("total_count" => 1, "classification" => "placeholder")

      # Never leaks unique personal emails, other orgs, or employee names/SSNs/phones.
      expect(response.body).not_to include("unique.person@example.com")
      expect(response.body).not_to include("ActiveA0")
      expect(response.body).not_to include("External Co")
      expect(response.body).not_to include("+16715550199")
    end

    it "forbids accountants without client management and client users" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(accountant_user)
      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      expect(response).to have_http_status(:forbidden)

      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }
      expect(response).to have_http_status(:forbidden)
    end

    it "limits delegated accountants and managers to companies they can configure" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(delegated_accountant)
      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: { "X-Company-Id" => company_a.id.to_s }

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["companies"].map { |c| c["company_id"] }).to eq([ company_a.id ])
    end
  end

  describe "POST /api/v1/admin/employee_contact_hygiene/clear_shared_emails" do
    it "clears one flagged email for one company at a time, resets verification, and writes audit logs" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

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

      # Company A records are cleared and unverified.
      expect(company_a.employees.where("LOWER(email) = ?", "shared-inbox@example.com").count).to eq(0)
      cleared_employees = company_a.employees.where(email: nil)
      expect(cleared_employees.count).to eq(4)
      expect(cleared_employees.pluck(:email_verified_at).compact).to be_empty
      expect(cleared_employees.pluck(:contact_source).uniq).to eq([ "staff" ])

      # Company B is untouched (one company at a time).
      expect(company_b.employees.where("LOWER(email) = ?", "shared-inbox@example.com").count).to eq(2)

      # Company-level and per-employee audit logs exist.
      bulk_audit = AuditLog.find_by!(action: "employee_contact_hygiene#clear_shared_emails", company_id: company_a.id)
      expect(bulk_audit.metadata).to include("email" => "shared-inbox@example.com", "cleared_count" => 4)

      employee_audits = AuditLog.where(action: "employees#clear_shared_email", company_id: company_a.id)
      expect(employee_audits.count).to eq(4)

      sample_employee = cleared_employees.first
      history = RecordActivityQuery.new(record_type: "employees", record_id: sample_employee.id, company_id: company_a.id).call
      expect(history.pluck(:action)).to include("employees#clear_shared_email")
    end

    it "refuses to bulk-clear a unique non-placeholder personal email" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "unique.person@example.com" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(company_a.employees.find_by(email: "unique.person@example.com")).to be_present
    end

    it "forbids accountants without client management from clearing emails" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(accountant_user)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "shared-inbox@example.com" }

      expect(response).to have_http_status(:forbidden)
      expect(company_a.employees.where("LOWER(email) = ?", "shared-inbox@example.com").count).to eq(4)
    end

    it "allows managers on their assigned company and rejects unassigned companies" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(manager_user)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_b.id, email: "shared-inbox@example.com" }
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails",
           headers: { "X-Company-Id" => company_a.id.to_s },
           params: { company_id: company_a.id, email: "noemail@example.com" }
      expect(response).to have_http_status(:ok)
    end
  end
end
