# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeNotes", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:other_company) { create(:company, organization: organization) }
  let(:employee) { create(:employee, company: company) }
  let(:other_employee) { create(:employee, company: other_company) }
  let(:admin) { create(:user, company: company, organization: organization, role: :admin, name: "Dafne Admin") }
  let(:accountant) { create(:user, company: company, organization: organization, role: :accountant, name: "Roke Staff") }
  let(:client_user) { create(:user, company: company, organization: organization, role: :client, name: "Client Portal") }
  let(:employee_user) { create(:user, company: company, organization: organization, role: :employee, name: "Worker Portal") }
  let(:current_actor) { admin }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(current_actor)
  end

  describe "GET /api/v1/admin/employees/:employee_id/notes" do
    it "returns notes newest first with author name and hidden flags" do
      older = create(
        :employee_note,
        company: company,
        employee: employee,
        created_by: accountant,
        body: "First note about W-4 date.",
        created_at: 2.hours.ago
      )
      newer = create(
        :employee_note,
        :hidden,
        company: company,
        employee: employee,
        created_by: admin,
        hidden_by: accountant,
        hidden_reason: "Duplicate entry",
        body: "Duplicate note text.",
        created_at: 1.hour.ago
      )

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.fetch("data")
      expect(rows.map { |row| row["id"] }).to eq([ newer.id, older.id ])

      expect(rows.first).to include(
        "id" => newer.id,
        "created_by_name" => "Dafne Admin",
        "hidden" => true,
        "hidden_by_name" => "Roke Staff",
        "hidden_reason" => "Duplicate entry"
      )
      expect(rows.second).to include(
        "id" => older.id,
        "body" => "First note about W-4 date.",
        "created_by_name" => "Roke Staff",
        "hidden" => false,
        "hidden_reason" => nil
      )
    end
  end

  describe "POST /api/v1/admin/employees/:employee_id/notes" do
    let(:current_actor) { accountant }

    it "creates a note and records an audit entry without the note body in metadata" do
      body = "Roke said her start date was Nov 15; the W-4 says Nov 16."

      expect {
        post "/api/v1/admin/employees/#{employee.id}/notes",
             params: { note: { body: body } },
             headers: headers,
             as: :json
      }.to change(EmployeeNote, :count).by(1)
        .and change(AuditLog, :count).by(1)

      expect(response).to have_http_status(:created)
      note_id = response.parsed_body.dig("data", "id")
      expect(response.parsed_body.fetch("data")).to include(
        "id" => note_id,
        "body" => body,
        "created_by_name" => "Roke Staff",
        "hidden" => false
      )

      audit = AuditLog.order(:id).last
      expect(audit.action).to eq("employee_notes#create")
      expect(audit.company_id).to eq(company.id)
      expect(audit.record_type).to eq("employee_notes")
      expect(audit.record_id).to eq(note_id)
      expect(audit.metadata).to include(
        "employee_id" => employee.id,
        "note_id" => note_id,
        "body_length" => body.length
      )
      expect(audit.metadata.to_json).not_to include("Nov 15")
      expect(audit.metadata.to_json).not_to include(body)
    end

    it "rejects SSN-like patterns with a clear validation message" do
      expect {
        post "/api/v1/admin/employees/#{employee.id}/notes",
             params: { note: { body: "W-4 SSN listed as 123-45-6789" } },
             headers: headers,
             as: :json
      }.not_to change(EmployeeNote, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "body").join(" ")).to match(/SSN/i)
    end

    it "rejects account or card-like 12+ digit runs with a clear validation message" do
      expect {
        post "/api/v1/admin/employees/#{employee.id}/notes",
             params: { note: { body: "Bank account number 987654321098" } },
             headers: headers,
             as: :json
      }.not_to change(EmployeeNote, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "body").join(" ")).to match(/bank account or card number/i)
    end

    it "rejects blank note bodies" do
      post "/api/v1/admin/employees/#{employee.id}/notes",
           params: { note: { body: "   " } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "body")).to include("can't be blank")
    end
  end

  describe "PATCH /api/v1/admin/employees/:employee_id/notes/:id/hide" do
    let!(:note) do
      create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Start date mismatch on intake form")
    end

    it "hides a note with a required reason and records an audit entry without the body" do
      reason = "Confirmed Nov 16 on signed W-4; note superseded"

      expect {
        patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide",
              params: { note: { reason: reason } },
              headers: headers,
              as: :json
      }.to change(AuditLog, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).to include(
        "id" => note.id,
        "hidden" => true,
        "hidden_by_name" => "Dafne Admin",
        "hidden_reason" => reason
      )

      audit = AuditLog.order(:id).last
      expect(audit.action).to eq("employee_notes#hide")
      expect(audit.company_id).to eq(company.id)
      expect(audit.record_type).to eq("employee_notes")
      expect(audit.record_id).to eq(note.id)
      expect(audit.metadata).to include(
        "employee_id" => employee.id,
        "note_id" => note.id,
        "body_length" => note.body.length,
        "hidden_reason_length" => reason.length
      )
      expect(audit.metadata.to_json).not_to include(note.body)
    end

    it "rejects hiding without a reason" do
      patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide",
            params: { note: { reason: "  " } },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "hidden_reason")).to include("is required to hide a note")
      expect(note.reload).not_to be_hidden
    end
  end

  describe "authorization, capability, and company scoping" do
    let!(:note) { create(:employee_note, company: company, employee: employee, created_by: admin) }

    it "denies client-role users on read, create, and hide" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/admin/employees/#{employee.id}/notes", params: { note: { body: "Client attempt" } }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide", params: { note: { reason: "Nope" } }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "denies employee-role users" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(employee_user)

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "denies staff who do not have access to the company" do
      unassigned_staff = create(:user, company: other_company, organization: organization, role: :accountant)
      create(:company_assignment, user: unassigned_staff, company: other_company)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(unassigned_staff)

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/admin/employees/#{employee.id}/notes", params: { note: { body: "No access" } }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "enforces StaffRolePolicy payroll_operations capability" do
      allow(StaffRolePolicy).to receive(:allowed?).and_call_original
      allow(StaffRolePolicy).to receive(:allowed?).with(accountant, :payroll_operations, company: anything).and_return(false)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(accountant)

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "denies cross-company header/path mismatches" do
      other_note = create(:employee_note, company: other_company, employee: other_employee, created_by: admin)

      get "/api/v1/admin/employees/#{other_employee.id}/notes", headers: headers
      expect(response).to have_http_status(:not_found)

      post "/api/v1/admin/employees/#{other_employee.id}/notes",
           params: { note: { body: "Cross company" } },
           headers: headers,
           as: :json
      expect(response).to have_http_status(:not_found)

      patch "/api/v1/admin/employees/#{employee.id}/notes/#{other_note.id}/hide",
            params: { note: { reason: "Cross company hide" } },
            headers: headers,
            as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "exposes no client API route and no update or delete route" do
      get "/api/v1/client/employees/#{employee.id}/notes", headers: headers
      expect(response).to have_http_status(:not_found)

      patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}", params: { note: { body: "Edited" } }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)

      delete "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "respects TestWorkspaceAccessPolicy for reviewer vs operator on test workspaces" do
      test_workspace = create(
        :company,
        organization: organization,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: company,
        migration_rehearsal_status: "ready"
      )
      test_employee = create(:employee, company: test_workspace)
      reviewer = create(:user, company: company, organization: organization, role: :accountant)
      create(:company_assignment, user: reviewer, company: test_workspace, workspace_access_level: "reviewer")

      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(reviewer)
      tw_headers = { "X-Company-Id" => test_workspace.id.to_s }

      get "/api/v1/admin/employees/#{test_employee.id}/notes", headers: tw_headers
      expect(response).to have_http_status(:ok)

      post "/api/v1/admin/employees/#{test_employee.id}/notes",
           params: { note: { body: "Reviewer write blocked" } },
           headers: tw_headers,
           as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
