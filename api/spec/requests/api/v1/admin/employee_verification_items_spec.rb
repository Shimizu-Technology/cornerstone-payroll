# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Staff employee verification queue", type: :request do
  include EmployeeLinkHelpers
  include EmployeeLifecyclePr4Helpers

  let(:company) { create(:company, name: "Fictional Payroll Client") }
  let(:role) { "manager" }
  let(:delegated) { false }
  let(:staff) { create(:user, company: company, role: role, name: "Morgan Staff", email: "morgan@example.test", clerk_id: "user_verify_staff") }
  let(:client) do
    create(:user, :with_client_assignment, company: company, role: "client", name: "Sloane Owner",
      email: "sloane@example.test", clerk_id: "user_verify_client")
  end
  let(:employee) { create_lifecycle_worker!(company, payment_delivery_method: "direct_deposit") }
  let(:item) do
    EmployeeVerificationItem.create!(company: company, employee: employee, source_actor: client,
      event_kind: "identity_tax_change", affects_pay: true, before_values: { ssn_encrypted: "900-11-2244" },
      after_values: { ssn_encrypted: "900-11-2233", nested: { contractor_ein: "90-0003333" } },
      metadata: { tax_filing_impact: { committed_tax_years: [ 2026 ] }, possible_self_created_hire: true })
  end
  let(:queue_path) { "/api/v1/admin/employee_verification_items" }
  let(:inbox_path) { "/api/v1/admin/client_inbox" }

  before do
    create(:company_assignment, company: company, user: staff, client_management: delegated,
      granted_by: (create(:user, company: company, role: "org_admin", name: "Riley Grantor", email: "grantor@example.test") if delegated))
  end

  def headers(user = staff)
    bearer(user.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => company.id.to_s)
  end

  context "with the mode still locked" do
    it "keeps approval-first edits in the existing request queue and leaves PR 4 dormant" do
      expect(CompanyFeatures.for(company).employee_lifecycle_mode).to eq("approval_first")
      expect(OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES).to have_key("client_portal.employee_lifecycle_mode")
      employee.update!(readiness_gate_enforced: false)
      item
      expect do
        patch "/api/v1/client/employees/#{employee.id}", headers: headers(client),
          params: { employee: { pay_rate: 28 } }, as: :json
      end.to change(EmployeeChangeRequest, :count).by(1).and change(EmployeeVerificationItem, :count).by(0)
      expect(employee.reload.pay_rate).to eq(15)
      expect(PortalNotificationEvent.where(event_type: "employee_verification_queued")).to be_empty

      get queue_path, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_lifecycle_disabled")
      post "#{queue_path}/#{item.id}/verify", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(item.reload.status).to eq("pending_verification")
      get "#{inbox_path}/counts", headers: headers
      expect(response.parsed_body.fetch("data")).not_to have_key("pending_verifications")
      expect(PortalNotifications::Preferences.categories_for(staff)).not_to have_key("employee_verifications")
    end
  end

  context "with client-managed mode activated" do
    before do
      unlock_lifecycle_mode!
      create_client_managed_profile!(company)
    end

    [
      [ "accountant", false, :forbidden ], [ "accountant", true, :ok ], [ "manager", false, :ok ],
      [ "admin", false, :ok ], [ "org_admin", false, :ok ], [ "super_admin", false, :ok ]
    ].each do |candidate, has_delegation, status|
      context "as #{candidate}#{' with client_management' if has_delegation}" do
        let(:role) { candidate }
        let(:delegated) { has_delegation }

        it "permits payroll operations to read and enforces client management on both writes" do
          get queue_path, headers: headers, params: { employee_id: item.employee_id }
          expect(response).to have_http_status(:ok), response.body
          expect(response.parsed_body.fetch("data").sole).to include("id" => item.id, "source_actor_id" => client.id)
          get "#{queue_path}/#{item.id}", headers: headers
          expect(response).to have_http_status(:ok), response.body

          post "#{queue_path}/#{item.id}/return_to_client", headers: headers,
            params: { return_note: "Please confirm the tax form details." }, as: :json
          expect(response).to have_http_status(status), response.body
          expect(item.reload.status).to eq(status == :ok ? "returned_to_client" : "pending_verification")
          if status == :ok
            expect(PortalNotificationEvent.find_by!(event_type: "employee_verification_returned", subject: item).deliveries.pluck(:user_id)).to eq([ client.id ])
          end

          post "#{queue_path}/#{item.id}/verify", headers: headers, params: { verification_note: "Reviewed." }, as: :json
          expect(response).to have_http_status(status), response.body
          expect(item.reload.status).to eq(status == :ok ? "verified" : "pending_verification")
        end
      end
    end

    it "scopes filters and search to the selected company and exposes masked details and warnings" do
      item.update!(event_kind: "termination", metadata: item.metadata.merge("post_termination_committed_pay_period_ids" => [ 99 ]))
      foreign_company = create(:company, organization: company.organization)
      foreign_employee = create_lifecycle_worker!(foreign_company)
      foreign = EmployeeVerificationItem.create!(company: foreign_company, employee: foreign_employee, event_kind: "termination", affects_pay: true)
      committed = create(:pay_period, :committed, company: company)
      approved = create(:pay_period, company: company, status: "approved", pay_date: committed.pay_date + 2.weeks,
        start_date: committed.start_date + 2.weeks, end_date: committed.end_date + 2.weeks)
      create(:payroll_item, company: company, pay_period: approved, employee: employee)
      PayPeriodVerificationAcknowledgement.create!(company: company, pay_period: committed, employee: employee,
        employee_verification_item: item, acknowledged_by: staff, acknowledged_at: Time.current,
        item_status_snapshot: item.status, item_updated_at_snapshot: item.updated_at)

      get queue_path, headers: headers, params: { status: item.status, event_kind: "termination", affects_pay: true, search: "quinn ex", per_page: 1 }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("meta")).to include("per_page" => 1, "total_count" => 1)
      expect(response.parsed_body.fetch("data").sole).to include("id" => item.id)

      get "#{queue_path}/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      get "#{queue_path}/#{item.id}", headers: headers
      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body.fetch("data")
      expect(data["before_values"]).to eq("ssn_encrypted" => "***-**-2244")
      expect(data["after_values"]).to include("ssn_encrypted" => "***-**-2233", "nested" => { "contractor_ein" => "Ending in 3333" })
      expect(data["readiness_checklist"]["missing_keys"]).to include("tax_form")
      expect(data["warnings"]).to include("review_final_pay" => true, "committed_pay_period_ids" => [ committed.id ],
        "post_termination_committed_pay_period_ids" => [ 99 ], "possible_self_created_hire" => true,
        "direct_deposit_missing_bank_details" => true, "approved_pay_period_ids" => [ approved.id ],
        "tax_filing_impact" => { "committed_tax_years" => [ 2026 ] })
      expect(data["commit_acknowledgements"].sole).to include("pay_period_id" => committed.id)
    end

    it "links a staff fix to its employee audit and refuses a stale or repeated decision" do
      item
      note = "short"
      post "#{queue_path}/#{item.id}/return_to_client", headers: headers, params: { return_note: note[0, 4] }, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      post "#{queue_path}/#{item.id}/verify", headers: headers, params: { updated_at: 1.day.ago.utc.iso8601(6) }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["code"]).to eq("verification_item_changed")

      post "#{queue_path}/#{item.id}/verify", headers: headers, params: { fixed_by_staff: true }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      patch "/api/v1/admin/employees/#{employee.id}", headers: headers, params: { employee: { job_title: "Example technician" } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      edit = AuditLog.find_by!(action: "employees#update", company: company, record_id: employee.id)

      post "#{queue_path}/#{item.id}/verify", headers: headers, params: { fixed_by_staff: true, staff_edit_audit_id: edit.id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload).to have_attributes(status: "verified", verified_by: staff, fixed_by_staff: true)
      expect(response.parsed_body.dig("data", "audit_references").sole).to include("staff_edit_audit_id" => edit.id)

      post "#{queue_path}/#{item.id}/return_to_client", headers: headers,
        params: { return_note: "This should never send." }, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "rolls back a send-back when its audit write fails" do
      allow(AuditLog).to receive(:record!).and_call_original
      allow(AuditLog).to receive(:record!).with(hash_including(action: "employee_verification_items#return_to_client"))
        .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

      post "#{queue_path}/#{item.id}/return_to_client", headers: headers, params: { return_note: "Please confirm the signed date." }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.status).to eq("pending_verification")
      expect(PortalNotificationEvent.where(subject: item)).to be_empty
    end

    it "requeues the verification and alert when the client responds without an employee edit" do
      post "#{queue_path}/#{item.id}/return_to_client", headers: headers,
        params: { return_note: "Please confirm the signed date." }, as: :json
      expect(response).to have_http_status(:ok), response.body

      expect do
        post "/api/v1/client/verification_items/#{item.id}/respond", headers: headers(client),
          params: { note: "The date on the synthetic form is correct." }, as: :json
      end.to change { PortalNotificationEvent.where(event_type: "employee_verification_queued", subject: item).count }.by(1)
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.status).to eq("pending_verification")
    end

    context "in the Client Inbox" do
      let(:role) { "org_admin" }

      it "lists authorized verification work, counts only live work, and updates the count after review" do
        item
        demo_company = create(:company, organization: company.organization, demo: true, name: "Example Demo")
        create_client_managed_profile!(demo_company)
        demo_item = EmployeeVerificationItem.create!(company: demo_company, employee: create_lifecycle_worker!(demo_company),
          event_kind: "new_hire", affects_pay: true)

        get inbox_path, headers: headers, params: { kind: "employee_verification", status: "waiting" }
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("data").pluck("id")).to contain_exactly(item.id, demo_item.id)
        get "#{inbox_path}/counts", headers: headers
        expect(response.parsed_body.fetch("data")).to include("pending_verifications" => 1, "waiting_count" => 1)

        post "#{queue_path}/#{item.id}/verify", headers: headers, as: :json
        expect(response).to have_http_status(:ok), response.body
        get "#{inbox_path}/counts", headers: headers
        expect(response.parsed_body.fetch("data")).to include("pending_verifications" => 0, "waiting_count" => 0)
      end
    end
  end
end
