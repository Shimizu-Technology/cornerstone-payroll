# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Lifecycle PR 3: Client-managed employee lifecycle API & no-self-dealing", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:organization) { create(:organization, name: "Harborview Org") }
  let!(:company) { create(:company, organization: organization, name: "Harborview Bistro") }
  let!(:other_company) { create(:company, organization: organization, name: "Pacific Trade Works") }
  let!(:department) { create(:department, company: company, name: "Kitchen") }
  let!(:client_manager) do
    create(
      :user,
      company: company,
      organization: organization,
      role: "client",
      name: "Sloane Owner",
      email: "sloane.owner@example.test"
    )
  end
  let!(:client_viewer) do
    create(
      :user,
      company: company,
      organization: organization,
      role: "client",
      client_access_level: "viewer",
      name: "Vicky Viewer",
      email: "vicky.viewer@example.test"
    )
  end
  let!(:staff_manager) do
    create(
      :user,
      company: company,
      organization: organization,
      role: "manager",
      name: "Morgan Staff",
      email: "morgan.staff@example.test"
    )
  end
  before do
    @acting_user = client_manager
    CompanyAssignment.create!(user: client_manager, company: company)
    CompanyAssignment.create!(user: client_viewer, company: company)
    CompanyAssignment.create!(user: staff_manager, company: company)

    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    allow_any_instance_of(Api::V1::Client::BaseController).to receive(:current_user) { @acting_user }
    allow_any_instance_of(Api::V1::Client::BaseController).to receive(:current_user_id) { @acting_user.id }
    allow_any_instance_of(Api::V1::Client::BaseController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Client::BaseController).to receive(:current_company).and_return(company)
  end

  def unlock_and_enable_client_managed!(profile_requests: false)
    stub_const("OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES",
               OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES.except("client_portal.employee_lifecycle_mode"))
    stub_const("OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS",
               OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS - [ "client_portal.employee_lifecycle_mode" ])
    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])

    options = {
      "client_portal" => { "employee_lifecycle_mode" => "client_managed" }
    }
    if profile_requests
      options["employee_portal"] = { "features" => { "profile_requests" => true } }
    end

    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        employee_portal_enabled: profile_requests,
        options: options,
        lifecycle_mode_activated_at: Time.current
      )
    )
    if profile_requests
      EmployeeAppActivation.create!(company: company, part: EmployeeAppSwitch::MASTER, activated_by: staff_manager, activated_at: Time.current)
      EmployeeAppActivation.create!(company: company, part: "employee_portal.features.profile_requests", activated_by: staff_manager, activated_at: Time.current)
    end
  end

  describe "approval_first regression (mode locked by default)" do
    it "keeps client_portal.employee_lifecycle_mode locked and approval_first behavior 100% unchanged" do
      expect(OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES).to have_key("client_portal.employee_lifecycle_mode")
      expect(CompanyFeatures::LOCKED_OFF).to include("client_portal.employee_lifecycle_mode")
      expect(CompanyFeatures.for(company).employee_lifecycle_mode).to eq("approval_first")
      expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(false)

      expect do
        post "/api/v1/client/employees", params: {
          employee: {
            first_name: "Quinn",
            last_name: "Example",
            employment_type: "hourly",
            pay_rate: 19.50,
            filing_status: "single",
            ssn: "900-11-2233",
            ssn_confirmation: "900-11-2233",
            hire_date: "2026-10-01",
            w4_effective_on: "2026-10-01",
            address_line1: "100 Coral Way",
            city: "Tamuning",
            state: "GU",
            zip: "96913",
            payment_delivery_method: "direct_deposit"
          }
        }, as: :json
      end.to change(Employee, :count).by(1).and change(EmployeeChangeRequest, :count).by(1)
        .and change(EmployeeVerificationItem, :count).by(0)

      expect(response).to have_http_status(:created)
      created = Employee.order(:id).last
      expect(created.status).to eq("inactive")
      expect(created.portal_pending_approval).to be(true)
      expect(created.readiness_gate_enforced).to be(false)
      expect(created.payment_delivery_method).to be_nil

      active_worker = create(:employee, :hourly, company: company, first_name: "Alex", last_name: "Legacy", pay_rate: 20.0)
      post "/api/v1/client/employees/#{active_worker.id}/terminate",
           params: { effective_date: "2026-11-15", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_lifecycle_disabled")

      terminated_worker = create(:employee, :hourly, company: company, status: "terminated", termination_date: Date.new(2026, 10, 15))
      post "/api/v1/client/employees/#{terminated_worker.id}/rehire",
           params: { effective_date: "2026-11-15" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_lifecycle_disabled")
    end
  end

  describe "client_managed employee creation, direct edits, verification coalescing, terminate, and rehire" do
    before do
      unlock_and_enable_client_managed!
    end

    it "creates an Incomplete hire directly with readiness_gate_enforced=true, transitions to Ready on update, and records verification items" do
      expect do
        post "/api/v1/client/employees", params: {
          employee: {
            first_name: "Jordan",
            last_name: "Sample",
            employment_type: "hourly"
          }
        }, as: :json
      end.to change(Employee, :count).by(1)
        .and change(EmployeeVerificationItem, :count).by(1)
        .and change(EmployeeChangeRequest, :count).by(0)

      expect(response).to have_http_status(:created), response.body
      body = response.parsed_body
      created = Employee.order(:id).last
      expect(created.status).to eq("active")
      expect(created.portal_pending_approval).to be(false)
      expect(created.readiness_gate_enforced).to be(true)
      expect(created.document_readiness_required).to be(false)
      expect(created.intake_exception).to eq({})
      expect(created.employee_document_requirements.pluck(:required_for_payroll)).to all(be(false))

      expect(body.dig("readiness", "status")).to eq("incomplete")
      expect(body.dig("readiness", "missing_keys")).to include("tax_id", "date_of_birth", "hire_date", "home_address", "pay_setup", "tax_form", "payment_method")
      expect(body["change_request"]).to be_nil

      new_hire_item = EmployeeVerificationItem.order(:id).last
      expect(new_hire_item.event_kind).to eq("new_hire")
      expect(new_hire_item.status).to eq("pending_verification")
      expect(new_hire_item.affects_pay).to be(true)
      expect(new_hire_item.metadata["possible_self_created_hire"]).to be_nil

      # Complete setup directly -> flips to Ready with no approval step, direct_deposit missing bank details flagged
      patch "/api/v1/client/employees/#{created.id}", params: {
        employee: {
          ssn: "900-12-3456",
          ssn_confirmation: "900-12-3456",
          date_of_birth: "1994-05-14",
          hire_date: "2026-11-01",
          address_line1: "200 Bayview Rd",
          city: "Hagatna",
          state: "GU",
          zip: "96910",
          pay_rate: 21.50,
          pay_frequency: "biweekly",
          filing_status: "single",
          w4_form_version: 2020,
          w4_signed_on: "2026-11-01",
          w4_effective_on: "2026-11-01",
          w4_election_received: true,
          payment_delivery_method: "direct_deposit"
        }
      }, as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("readiness", "status")).to eq("ready")
      expect(response.parsed_body.dig("readiness", "direct_deposit_missing_bank_details")).to be(true)

      created.reload
      expect(created.pay_rate.to_f).to eq(21.5)
      expect(created.payment_delivery_method).to eq("direct_deposit")
      expect(created.employee_w4_elections.recent_first.first.source).to eq("client_direct")

      payment_item = EmployeeVerificationItem.where(employee: created, event_kind: "payment_method_change").last
      expect(payment_item).to be_present
      expect(payment_item.metadata["direct_deposit_missing_bank_details"]).to be(true)

      # Subsequent unacknowledged pay edit supersedes the first compensation_change while keeping last-verified before_values
      comp_item_1 = EmployeeVerificationItem.where(employee: created, event_kind: "compensation_change").last
      expect(comp_item_1.before_values["pay_rate"]).to eq(0.0)

      patch "/api/v1/client/employees/#{created.id}", params: {
        employee: { pay_rate: 23.00 }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      comp_item_2 = EmployeeVerificationItem.where(employee: created, event_kind: "compensation_change").order(:id).last
      expect(comp_item_1.reload.status).to eq("superseded")
      expect(comp_item_1.superseded_by_id).to eq(comp_item_2.id)
      expect(comp_item_2.before_values["pay_rate"]).to eq(0.0)
      expect(comp_item_2.after_values["pay_rate"]).to eq(23.0)
      expect(comp_item_2.metadata["prior_unverified_item_id"]).to eq(comp_item_1.id)

      # Once acknowledged in a committed pay run, further edits NEVER supersede it
      committed_period = create(:pay_period, company: company, status: "committed", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      PayPeriodVerificationAcknowledgement.create!(
        company: company,
        pay_period: committed_period,
        employee_verification_item: comp_item_2,
        employee: created,
        acknowledged_by: staff_manager,
        acknowledged_at: Time.current,
        item_status_snapshot: comp_item_2.status,
        item_updated_at_snapshot: comp_item_2.updated_at
      )

      patch "/api/v1/client/employees/#{created.id}", params: {
        employee: { pay_rate: 24.50 }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      comp_item_3 = EmployeeVerificationItem.where(employee: created, event_kind: "compensation_change").order(:id).last
      expect(comp_item_3.id).not_to eq(comp_item_2.id)
      expect(comp_item_2.reload.status).to eq("pending_verification")
      expect(comp_item_3.before_values["pay_rate"]).to eq(0.0)
      expect(comp_item_3.after_values["pay_rate"]).to eq(24.5)
      expect(comp_item_3.metadata["prior_unverified_item_id"]).to eq(comp_item_2.id)
    end

    it "supports GET /client/verification_items and POST /client/verification_items/:id/respond" do
      worker = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Worker", ssn_encrypted: "900-22-3344")
      other_worker = create(:employee, :hourly, company: other_company, first_name: "Other", last_name: "Worker")

      returned_item = EmployeeVerificationItem.create!(
        company: company,
        employee: worker,
        event_kind: "identity_tax_change",
        status: "returned_to_client",
        affects_pay: true,
        changed_fields: [ "ssn_encrypted" ],
        before_values: { "ssn_encrypted" => "900-11-1111" },
        after_values: { "ssn_encrypted" => "900-22-3344" },
        returned_by: staff_manager,
        returned_at: 1.hour.ago,
        return_note: "Please confirm the last four digits match the Social Security card."
      )
      other_item = EmployeeVerificationItem.create!(
        company: other_company,
        employee: other_worker,
        event_kind: "new_hire",
        status: "returned_to_client",
        affects_pay: true,
        return_note: "Other company note"
      )

      get "/api/v1/client/verification_items", params: { status: "returned_to_client" }
      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.fetch("data")
      expect(rows.map { |row| row["id"] }).to eq([ returned_item.id ])
      expect(rows.first["before_values"]["ssn_encrypted"]).to eq("***-**-1111")
      expect(rows.first["after_values"]["ssn_encrypted"]).to eq("***-**-3344")
      expect(rows.first["return_note"]).to include("confirm the last four")

      post "/api/v1/client/verification_items/#{returned_item.id}/respond",
           params: { note: "Verified against the employee's Social Security card; digits are correct." }, as: :json
      expect(response).to have_http_status(:ok)
      expect(returned_item.reload.status).to eq("pending_verification")
      expect(returned_item.resubmitted_at).to be_present
      expect(returned_item.metadata["client_response_note"]).to include("Verified against")
      expect(AuditLog.where(company_id: company.id, action: "employee_verification_items#respond", record_id: returned_item.id)).to exist

      # Cross-company respond returns 404
      post "/api/v1/client/verification_items/#{other_item.id}/respond",
           params: { note: "Attempt cross-company" }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "terminates (retiring link, flagging backdated committed runs) and rehires (accepting legacy W-4 & NULL payment method while preserving document_readiness_required)" do
      travel_to(Time.utc(2026, 11, 20, 12)) do
        worker = create(
          :employee,
          :hourly,
          company: company,
          first_name: "Taylor",
          last_name: "Seasonal",
          date_of_birth: Date.new(1990, 3, 10),
          hire_date: Date.new(2026, 1, 1),
          pay_rate: 20.00,
          pay_frequency: "biweekly",
          payment_delivery_method: nil,
          readiness_gate_enforced: false,
          document_readiness_required: true
        )
        # Pre-2020 legacy W-4 election + pending required document requirement
        EmployeeW4Election.create!(
          EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
            company: company,
            employee: worker,
            effective_on: Date.new(2026, 1, 1),
            w4_form_version: 2019,
            source: "legacy_profile",
            reason: "Legacy W-4"
          )
        )
        EmployeeDocumentReadiness.seed_new_hire!(employee: worker, actor: staff_manager)

        portal_employee_user = create(:user, company: company, organization: organization, role: "portal_employee", email: "taylor.seasonal@example.test")
        active_link = EmployeeAccountLink.create!(
          company: company,
          employee: worker,
          user: portal_employee_user,
          status: "active",
          activated_at: 2.months.ago
        )

        # Committed regular pay period ending AFTER backdated termination date
        committed_period = create(
          :pay_period,
          company: company,
          status: "committed",
          run_purpose: "regular",
          start_date: Date.new(2026, 11, 1),
          end_date: Date.new(2026, 11, 14),
          pay_date: Date.new(2026, 11, 18)
        )
        create(:payroll_item, company: company, pay_period: committed_period, employee: worker, gross_pay: 800, net_pay: 700)

        # Future-dated termination is rejected
        post "/api/v1/client/employees/#{worker.id}/terminate", params: {
          effective_date: "2026-11-25",
          reason_category: "voluntary"
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)

        # Backdated termination succeeds, retires active link to former, flags committed run
        post "/api/v1/client/employees/#{worker.id}/terminate", params: {
          effective_date: "2026-11-10",
          last_worked_on: "2026-11-09",
          reason_category: "voluntary",
          final_pay_notes: "Pay out 16 hours accrued PTO",
          notes: "Relocating off-island"
        }, as: :json
        expect(response).to have_http_status(:ok), response.body

        expect(worker.reload.status).to eq("terminated")
        expect(worker.termination_date).to eq(Date.new(2026, 11, 10))
        expect(worker.employee_status_events.last.source).to eq("client_portal")
        expect(active_link.reload.status).to eq("former")
        expect(response.parsed_body["post_termination_committed_pay_period_ids"]).to eq([ committed_period.id ])
        expect(response.parsed_body["warnings"]).to include(a_string_including("committed payroll after 2026-11-10"))

        term_item = EmployeeVerificationItem.where(employee: worker, event_kind: "termination").last
        expect(term_item.metadata["final_pay_notes"]).to eq("Pay out 16 hours accrued PTO")
        expect(term_item.metadata["post_termination_committed_pay_period_ids"]).to eq([ committed_period.id ])
        expect(AuditLog.where(company_id: company.id, action: "client_employees#terminate", record_id: worker.id)).to exist

        # Rehire: stamps readiness_gate_enforced=true, accepts legacy W-4 & NULL payment method, preserves document_readiness_required=true
        post "/api/v1/client/employees/#{worker.id}/rehire", params: {
          effective_date: "2026-11-19",
          notes: "Returned for holiday season"
        }, as: :json
        expect(response).to have_http_status(:ok), response.body

        worker.reload
        expect(worker.status).to eq("active")
        expect(worker.termination_date).to be_nil
        expect(worker.readiness_gate_enforced).to be(true)
        expect(worker.document_readiness_required).to be(true)
        expect(response.parsed_body.dig("readiness", "status")).to eq("ready")
        expect(EmployeeVerificationItem.where(employee: worker, event_kind: "rehire")).to exist
        expect(AuditLog.where(company_id: company.id, action: "client_employees#rehire", record_id: worker.id)).to exist

        # Document gate on the rehired staff-created worker is still enforced!
        next_period = create(:pay_period, company: company, start_date: Date.new(2026, 11, 15), end_date: Date.new(2026, 11, 28), pay_date: Date.new(2026, 12, 4))
        create(:payroll_item, company: company, pay_period: next_period, employee: worker, gross_pay: 500, net_pay: 450)
        expect { EmployeeDocumentReadiness.require_payroll_ready!(next_period) }
          .to raise_error(EmployeeDocumentReadiness::BlockedError, /Resolve required new-hire documents/)
      end
    end

    it "enforces SSN double entry, service-level duplicate SSN only when SSN changes, and W-2c / filed-quarter tax_filing_impact" do
      existing_a = create(:employee, :hourly, company: company, first_name: "Pat", last_name: "Alpha", ssn_encrypted: "900-44-5566")
      existing_b = create(:employee, :hourly, company: company, first_name: "Sam", last_name: "Beta", ssn_encrypted: "900-44-5566")
      target = create(:employee, :hourly, company: company, first_name: "Robin", last_name: "Gamma", ssn_encrypted: "900-77-8899")

      # 1. Duplicate SSN rejected on client create (regardless of dash formatting)
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "New",
          last_name: "Dup",
          employment_type: "hourly",
          ssn: "900445566",
          ssn_confirmation: "900445566"
        }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "ssn")).to include("This Social Security Number is already assigned to another employee in this company.")

      # 2. SSN double-entry confirmation required on client SSN change
      patch "/api/v1/client/employees/#{target.id}", params: {
        employee: { ssn: "900-88-9900", ssn_confirmation: "900-00-0000" }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "ssn_confirmation")).to include("does not match Social Security Number")

      # 3. Non-SSN client edits on existing shared-SSN records succeed (duplicate check only runs when SSN changes!)
      patch "/api/v1/client/employees/#{existing_a.id}", params: {
        employee: { job_title: "Lead Cook" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(existing_a.reload.job_title).to eq("Lead Cook")

      # 4. Staff model updates on existing shared-SSN records succeed (no global model validation!)
      expect { existing_b.update!(job_title: "Sous Chef") }.not_to raise_error

      # 4b. W-2 <-> 1099 transition pair (previous_employee_id) is excluded from duplicate-SSN rejection
      prior_record = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Transition", ssn_encrypted: "900-66-7788", status: "terminated", termination_date: Date.new(2026, 6, 30))
      successor_record = create(:employee, :contractor, company: company, first_name: "Casey", last_name: "Transition", previous_employee: prior_record, ssn_encrypted: "900-66-0000", hire_date: Date.new(2026, 7, 1))
      patch "/api/v1/client/employees/#{successor_record.id}", params: {
        employee: { ssn: "900-66-7788", ssn_confirmation: "900-66-7788" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(successor_record.reload.ssn_encrypted).to eq("900-66-7788")

      # 5. Changing SSN on an employee with committed pay + filed quarter flags tax_filing_impact
      committed_q1 = create(:pay_period, company: company, status: "committed", start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 14), pay_date: Date.new(2026, 2, 20))
      create(:payroll_item, company: company, pay_period: committed_q1, employee: target, gross_pay: 1000, net_pay: 850)
      PayrollFilingRecord.create!(
        company: company,
        filing_type: "federal_941",
        tax_year: 2026,
        quarter: 1,
        status: "accepted",
        submitted_at: Time.current,
        confirmation_number: "CONF-2026-Q1",
        source_fingerprint: "a" * 64
      )

      patch "/api/v1/client/employees/#{target.id}", params: {
        employee: { ssn: "900-88-9900", ssn_confirmation: "900-88-9900" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["warnings"]).to include(a_string_including("W-2c / Form 941-GU"))

      tax_item = EmployeeVerificationItem.where(employee: target, event_kind: "identity_tax_change").last
      expect(tax_item.before_values["ssn_encrypted"]).to eq("***-**-8899")
      expect(tax_item.after_values["ssn_encrypted"]).to eq("***-**-9900")
      expect(tax_item.metadata["tax_filing_impact"]).to eq(
        "committed_tax_years" => [ 2026 ],
        "filed_quarters" => [ "2026-Q1" ],
        "w2c_or_941c_review_required" => true
      )
    end

    it "refuses client payment-method edit when a legacy approved run has payment_delivery_method=NULL instead of silently unapproving it" do
      worker = create(:employee, :hourly, company: company, first_name: "Jamie", last_name: "Paycheck", payment_delivery_method: "paper_check")
      approved_period = create(:pay_period, :approved, company: company, start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      legacy_item = create(:payroll_item, company: company, pay_period: approved_period, employee: worker, payment_delivery_method: nil)

      patch "/api/v1/client/employees/#{worker.id}", params: {
        employee: { payment_delivery_method: "direct_deposit" }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(approved_period.reload.status).to eq("approved")
      expect(worker.reload.payment_delivery_method).to eq("paper_check")

      # Once the approved item has a materialized payment_delivery_method, updating the future default succeeds without unapproving!
      legacy_item.update!(payment_delivery_method: "paper_check")
      patch "/api/v1/client/employees/#{worker.id}", params: {
        employee: { payment_delivery_method: "direct_deposit" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(approved_period.reload.status).to eq("approved")
      expect(legacy_item.reload.payment_delivery_method).to eq("paper_check")
      expect(worker.reload.payment_delivery_method).to eq("direct_deposit")
    end
  end

  describe "security, client_viewer isolation, and dual-role no-self-dealing" do
    before do
      unlock_and_enable_client_managed!(profile_requests: false)
    end

    it "blocks client_viewer with 403 client_view_only on every write while allowing read-only verification list" do
      worker = create(:employee, :hourly, company: company, first_name: "Riley", last_name: "Worker")
      terminated = create(:employee, :hourly, company: company, status: "terminated", termination_date: Date.new(2026, 10, 1))
      item = EmployeeVerificationItem.create!(company: company, employee: worker, event_kind: "new_hire", status: "returned_to_client", return_note: "Check")

      @acting_user = client_viewer

      get "/api/v1/client/verification_items"
      expect(response).to have_http_status(:ok)

      post "/api/v1/client/employees", params: { employee: { first_name: "New", last_name: "Hire" } }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_view_only")

      patch "/api/v1/client/employees/#{worker.id}", params: { employee: { job_title: "Edited" } }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_view_only")

      post "/api/v1/client/employees/#{worker.id}/terminate", params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_view_only")

      post "/api/v1/client/employees/#{terminated.id}/rehire", params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_view_only")

      post "/api/v1/client/verification_items/#{item.id}/respond", params: { note: "Viewer cannot respond" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_view_only")
    end

    it "routes own-record non-address edits (detected by link, email, or full name even with profile_requests OFF) to Cornerstone staff with sensitive_payload intact" do
      # Unlinked employee matching client_manager by normalized email ONLY
      email_match_self = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Different",
        last_name: "Name",
        email: "SLOANE.OWNER@example.test",
        ssn_encrypted: "900-11-1111",
        pay_rate: 25.0,
        payment_delivery_method: "paper_check"
      )

      patch "/api/v1/client/employees/#{email_match_self.id}", params: {
        employee: {
          ssn: "900-99-8877",
          ssn_confirmation: "900-99-8877",
          pay_rate: 40.0,
          payment_delivery_method: "direct_deposit"
        }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body

      # Did NOT apply directly!
      email_match_self.reload
      expect(email_match_self.ssn_encrypted).to eq("900-11-1111")
      expect(email_match_self.pay_rate.to_f).to eq(25.0)
      expect(email_match_self.payment_delivery_method).to eq("paper_check")

      change_request = EmployeeChangeRequest.order(:id).last
      expect(change_request.own_record).to be(true)
      expect(change_request.profile_address?).to be(false)
      expect(change_request.proposed_changes["ssn_encrypted"]).to eq("***-**-8877")
      expect(change_request.sensitive_payload.dig(:proposed, :ssn_encrypted)).to eq("900-99-8877")
      expect(change_request.sensitive_payload.dig(:original, :ssn_encrypted)).to eq("900-11-1111")

      # Client approve route returns 404 for non-address own_record requests
      patch "/api/v1/client/employee_change_requests/#{change_request.id}/approve", as: :json
      expect(response).to have_http_status(:not_found)

      # Cornerstone staff can approve it and it applies SSN, pay_rate, and payment_delivery_method
      change_request.apply!(actor: staff_manager)
      email_match_self.reload
      expect(email_match_self.ssn_encrypted).to eq("900-99-8877")
      expect(email_match_self.pay_rate.to_f).to eq(40.0)
      expect(email_match_self.payment_delivery_method).to eq("direct_deposit")

      # Unlinked employee matching client_manager by normalized full name ONLY -> address-only stays profile_address? with nil sensitive_payload
      name_match_self = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Sloane",
        last_name: "Owner",
        email: "other.inbox@example.test",
        address_line1: "10 Old Ln",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )
      patch "/api/v1/client/employees/#{name_match_self.id}", params: {
        employee: { address_line1: "20 New Ln" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(name_match_self.reload.address_line1).to eq("10 Old Ln")

      addr_request = EmployeeChangeRequest.where(employee: name_match_self).last
      expect(addr_request.own_record).to be(true)
      expect(addr_request.profile_address?).to be(true)
      expect(addr_request.sensitive_payload_encrypted).to be_nil

      # Linked self-record also detected
      linked_self = create(:employee, :hourly, company: company, first_name: "Alias", last_name: "Person", email: "alias@example.test", pay_rate: 20.0)
      EmployeeAccountLink.create!(company: company, employee: linked_self, user: client_manager, status: "active", activated_at: 1.week.ago)
      patch "/api/v1/client/employees/#{linked_self.id}", params: { employee: { pay_rate: 35.0 } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(linked_self.reload.pay_rate.to_f).to eq(20.0)
      expect(EmployeeChangeRequest.where(employee: linked_self, status: :pending, own_record: true)).to exist
    end

    it "flags possible_self_created_hire=true on new_hire verification item when actor email or name matches" do
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "Sloane",
          last_name: "Owner",
          employment_type: "hourly"
        }
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      item = EmployeeVerificationItem.order(:id).last
      expect(item.event_kind).to eq("new_hire")
      expect(item.metadata["possible_self_created_hire"]).to be(true)
    end

    it "returns 403 self_lifecycle_forbidden on self-terminate and self-rehire, 404 on cross-company and DELETE" do
      self_active = create(:employee, :hourly, company: company, first_name: "Sloane", last_name: "Owner", email: "different@example.test")
      self_terminated = create(:employee, :hourly, company: company, first_name: "Other", last_name: "Name", email: "sloane.owner@example.test", status: "terminated", termination_date: Date.new(2026, 10, 1))
      foreign_employee = create(:employee, :hourly, company: other_company, first_name: "Foreign", last_name: "Worker")

      post "/api/v1/client/employees/#{self_active.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")

      post "/api/v1/client/employees/#{self_terminated.id}/rehire",
           params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")

      post "/api/v1/client/employees/#{foreign_employee.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/client/employees/#{foreign_employee.id}/rehire",
           params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:not_found)

      delete "/api/v1/client/employees/#{self_active.id}", as: :json
      expect(response.status).to be_in([ 404, 405 ])

      # LinkCheckUnavailable fails closed with HTTP 503 on update, terminate, and rehire
      allow(EmployeeProfileIdentity).to receive(:own_record?).and_raise(EmployeeProfileIdentity::LinkCheckUnavailable, "Link check unavailable")
      patch "/api/v1/client/employees/#{self_active.id}", params: { employee: { job_title: "Chef" } }, as: :json
      expect(response).to have_http_status(:service_unavailable)
      post "/api/v1/client/employees/#{self_active.id}/terminate", params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:service_unavailable)
      post "/api/v1/client/employees/#{self_terminated.id}/rehire", params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
