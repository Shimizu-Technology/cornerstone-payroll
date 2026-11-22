# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeNotes", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:other_company) { create(:company, organization: organization) }
  let(:employee) { create(:employee, company: company) }
  let(:other_employee) { create(:employee, company: other_company) }
  let(:super_admin) { create(:user, company: company, organization: organization, role: :super_admin, name: "Leon Owner") }
  let(:org_admin) { create(:user, company: company, organization: organization, role: :org_admin, name: "Org Owner") }
  let(:admin) { create(:user, company: company, organization: organization, role: :admin, name: "Dafne Admin") }
  let(:manager) { create(:user, company: company, organization: organization, role: :manager, name: "Mina Manager") }
  let(:accountant) { create(:user, company: company, organization: organization, role: :accountant, name: "Roke Staff") }
  let(:client_user) { create(:user, company: company, organization: organization, role: :client, name: "Client Portal") }
  let(:employee_user) { create(:user, company: company, organization: organization, role: :employee, name: "Worker Portal") }
  let(:current_actor) { admin }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(current_actor)
  end

  def logged_request
    output = StringIO.new
    original = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(output).tap { |logger| logger.level = :debug }
    reported = []
    callback = ->(*, payload) { reported << payload[:params] }
    ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") { yield }
    [ output.string, reported.sole ]
  ensure
    ActionController::Base.logger = original
  end

  describe "GET /api/v1/admin/employees/:employee_id/notes" do
    it "returns notes newest first, redacts body on hidden notes, and includes pagination metadata" do
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
        body: "Sensitive hidden text that must not be exposed on index.",
        created_at: 1.hour.ago
      )

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.fetch("data")
      expect(rows.map { |row| row["id"] }).to eq([ newer.id, older.id ])

      expect(rows.first).to include(
        "id" => newer.id,
        "body" => nil,
        "created_by_name" => "Dafne Admin",
        "hidden" => true,
        "hidden_by_name" => "Roke Staff",
        "hidden_reason" => "Duplicate entry"
      )
      expect(response.body).not_to include("Sensitive hidden text")

      expect(rows.second).to include(
        "id" => older.id,
        "body" => "First note about W-4 date.",
        "created_by_name" => "Roke Staff",
        "hidden" => false,
        "hidden_reason" => nil
      )
      expect(response.parsed_body.fetch("meta")).to eq(
        "limit" => Api::V1::Admin::EmployeeNotesController::INDEX_LIMIT,
        "returned_count" => 2,
        "total_count" => 2,
        "truncated" => false
      )
    end

    it "also sends body: nil for hidden notes even when the caller is super_admin" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(super_admin)
      create(
        :employee_note,
        :hidden,
        company: company,
        employee: employee,
        created_by: accountant,
        hidden_by: admin,
        hidden_reason: "Posted to wrong worker",
        body: "Must require explicit reveal"
      )

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").sole["body"]).to be_nil
      expect(response.body).not_to include("Must require explicit reveal")
    end

    it "limits the index response to the newest configured maximum and flags truncation" do
      stub_const("Api::V1::Admin::EmployeeNotesController::INDEX_LIMIT", 2)
      oldest = create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Oldest", created_at: 3.hours.ago)
      middle = create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Middle", created_at: 2.hours.ago)
      newest = create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Newest", created_at: 1.hour.ago)

      get "/api/v1/admin/employees/#{employee.id}/notes", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").map { |row| row["id"] }).to eq([ newest.id, middle.id ])
      expect(response.parsed_body.fetch("data").map { |row| row["id"] }).not_to include(oldest.id)
      expect(response.parsed_body.fetch("meta")).to eq(
        "limit" => 2,
        "returned_count" => 2,
        "total_count" => 3,
        "truncated" => true
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

    it "rejects bank account or card numbers with a clear validation message" do
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

    it "requires nested note params and rejects top-level body fallback" do
      expect {
        post "/api/v1/admin/employees/#{employee.id}/notes",
             params: { body: "Top-level body should not be accepted" },
             headers: headers,
             as: :json
      }.not_to change(EmployeeNote, :count)

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "PATCH /api/v1/admin/employees/:employee_id/notes/:id/hide" do
    let!(:note) do
      create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Start date mismatch on intake form")
    end

    it "hides a note with a required reason, redacts body in response, and records an audit entry without the body" do
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
        "body" => nil,
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

    it "rejects hiding when the reason contains an SSN or bank account number" do
      expect {
        patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide",
              params: { note: { reason: "Contained SSN 987-65-4321, acct 1234567890" } },
              headers: headers,
              as: :json
      }.not_to change(AuditLog, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "hidden_reason").join(" ")).to match(/SSN/i)
      expect(note.reload).not_to be_hidden

      expect {
        patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide",
              params: { note: { reason: "Acct no. 1234567890" } },
              headers: headers,
              as: :json
      }.not_to change(AuditLog, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "hidden_reason").join(" ")).to match(/bank account or card number/i)
      expect(note.reload).not_to be_hidden
    end

    it "requires nested note params and rejects top-level reason fallback" do
      patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide",
            params: { reason: "Top-level reason should not be accepted" },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:bad_request)
      expect(note.reload).not_to be_hidden
    end
  end

  describe "GET /api/v1/admin/employees/:employee_id/notes/:id/original" do
    let!(:hidden_note) do
      create(
        :employee_note,
        :hidden,
        company: company,
        employee: employee,
        created_by: accountant,
        hidden_by: admin,
        hidden_reason: "Entered on wrong employee profile",
        body: "Original confidential payroll context."
      )
    end

    it "allows super_admin to reveal the original body and writes an IDs-only reveal audit log" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(super_admin)

      expect {
        get "/api/v1/admin/employees/#{employee.id}/notes/#{hidden_note.id}/original", headers: headers
      }.to change(AuditLog, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).to include(
        "id" => hidden_note.id,
        "body" => "Original confidential payroll context.",
        "hidden" => true,
        "hidden_reason" => "Entered on wrong employee profile"
      )

      audit = AuditLog.order(:id).last
      expect(audit.action).to eq("employee_notes#reveal")
      expect(audit.user_id).to eq(super_admin.id)
      expect(audit.company_id).to eq(company.id)
      expect(audit.record_type).to eq("employee_notes")
      expect(audit.record_id).to eq(hidden_note.id)
      expect(audit.metadata).to eq(
        "employee_id" => employee.id,
        "note_id" => hidden_note.id
      )
      expect(audit.metadata.to_json).not_to include("Original confidential")
      expect(audit.metadata.to_json).not_to include("wrong employee")
    end

    it "allows org_admin to reveal the original body and writes an IDs-only reveal audit log" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(org_admin)

      expect {
        get "/api/v1/admin/employees/#{employee.id}/notes/#{hidden_note.id}/original", headers: headers
      }.to change(AuditLog, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "body")).to eq("Original confidential payroll context.")

      audit = AuditLog.order(:id).last
      expect(audit.action).to eq("employee_notes#reveal")
      expect(audit.metadata).to eq("employee_id" => employee.id, "note_id" => hidden_note.id)
    end

    %i[admin manager accountant client_user employee_user].each do |role_name|
      it "forbids #{role_name} from revealing a hidden note without writing an audit log" do
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(public_send(role_name))

        expect {
          get "/api/v1/admin/employees/#{employee.id}/notes/#{hidden_note.id}/original", headers: headers
        }.not_to change(AuditLog, :count)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include("Original confidential")
      end
    end

    it "rejects revealing a note that is not hidden" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(super_admin)
      visible_note = create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Visible note")

      expect {
        get "/api/v1/admin/employees/#{employee.id}/notes/#{visible_note.id}/original", headers: headers
      }.not_to change(AuditLog, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "request parameter log filtering" do
    it "replaces note and employee_note body, reason, and hidden_reason with [FILTERED]" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      filtered = filter.filter(
        "note" => { "body" => "SSN 123-45-6789", "reason" => "Sensitive mistake", "hidden_reason" => "Private reason" },
        "employee_note" => { "body" => "Acct 123456789012", "reason" => "Hide reason", "hidden_reason" => "Hidden" },
        "message" => { "body" => "Unrelated portal message" },
        "termination" => { "reason" => "Resigned" },
        "note[body]" => "123-45-6789",
        "note%5Breason%5D" => "Mistake"
      )

      expect(filtered.fetch("note")).to eq(
        "body" => "[FILTERED]",
        "reason" => "[FILTERED]",
        "hidden_reason" => "[FILTERED]"
      )
      expect(filtered.fetch("employee_note")).to eq(
        "body" => "[FILTERED]",
        "reason" => "[FILTERED]",
        "hidden_reason" => "[FILTERED]"
      )
      expect(filtered.fetch("message")).to eq("body" => "Unrelated portal message")
      expect(filtered.fetch("termination")).to eq("reason" => "Resigned")
      expect(filtered["note[body]"]).to eq("[FILTERED]")
      expect(filtered["note%5Breason%5D"]).to eq("[FILTERED]")
    end

    it "filters rejected note bodies and hide reasons from ActionController logs" do
      rejected_ssn = "123-45-6789"
      log, params = logged_request do
        post "/api/v1/admin/employees/#{employee.id}/notes",
             params: { note: { body: "Accidentally pasted #{rejected_ssn}" } },
             headers: headers,
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(params.dig("note", "body")).to eq("[FILTERED]")
      expect(log).to include("Parameters:", "[FILTERED]")
      expect(log).not_to include(rejected_ssn)

      note = create(:employee_note, company: company, employee: employee, created_by: accountant, body: "Normal note")
      hide_reason = "Unique secret hide reason 998877"
      hide_log, hide_params = logged_request do
        patch "/api/v1/admin/employees/#{employee.id}/notes/#{note.id}/hide",
              params: { note: { reason: hide_reason } },
              headers: headers,
              as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(hide_params.dig("note", "reason")).to eq("[FILTERED]")
      expect(hide_log).to include("Parameters:", "[FILTERED]")
      expect(hide_log).not_to include(hide_reason)
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
      other_note = create(:employee_note, :hidden, company: other_company, employee: other_employee, created_by: admin, hidden_by: admin)

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

      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(super_admin)
      get "/api/v1/admin/employees/#{employee.id}/notes/#{other_note.id}/original", headers: headers
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
