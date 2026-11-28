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
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_user) { @admin_user || staff_manager }
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_user_id) { (@admin_user || staff_manager).id }
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_company).and_return(company)
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

  describe "client portal lifecycle display" do
    before do
      allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_user) { @acting_user }
      allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_company_id).and_return(company.id)
    end

    it "returns the effective locked mode without attaching lifecycle edit context" do
      get "/api/v1/companies"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("companies")).to include(
        a_hash_including("id" => company.id, "employee_lifecycle_mode" => "approval_first")
      )

      employee = create(:employee, :hourly, company: company)
      get "/api/v1/client/employees/#{employee.id}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).not_to have_key("lifecycle_edit_context")
      expect(response.parsed_body.fetch("data")).not_to have_key("current_w4_election")
    end

    it "reports activated mode and gives the manager a rehire preview while keeping viewer access read-only" do
      unlock_and_enable_client_managed!
      employee = create(
        :employee, :hourly, company: company, first_name: "Rowan", last_name: "Fixture",
        status: "terminated", termination_date: Date.new(2026, 10, 15), payment_delivery_method: nil
      )
      employee.update_columns(readiness_gate_enforced: true)

      get "/api/v1/companies"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("companies")).to include(
        a_hash_including("id" => company.id, "employee_lifecycle_mode" => "client_managed")
      )

      get "/api/v1/client/employees/#{employee.id}"
      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.fetch("readiness").fetch("missing_keys")).to include("payment_method")
      context = data.fetch("lifecycle_edit_context")
      expect(context).to include("own_record" => false, "today" => PayrollBusinessClock.today.iso8601)
      expect(context.fetch("rehire_readiness")).to include(
        "rehire_or_grandfathered" => true, "readiness_gate_enforced" => true
      )
      expect(context.fetch("rehire_readiness").fetch("missing_keys")).not_to include("payment_method")

      @acting_user = client_viewer
      get "/api/v1/client/employees/#{employee.id}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).to have_key("readiness")
      expect(response.parsed_body.fetch("data")).not_to have_key("lifecycle_edit_context")
    end

    it "serializes the currently effective W-4 profile without internal evidence or a future election" do
      unlock_and_enable_client_managed!
      travel_to(Time.utc(2026, 11, 20, 12)) do
        employee = create(:employee, :hourly, company: company)
        current = employee.employee_w4_elections.create!(
          company: company, effective_on: Date.new(2026, 11, 1), filing_status: "married",
          additional_withholding: 42, w4_signed_on: Date.new(2026, 10, 29),
          source: "client_direct", reason: "Internal fixture note", w4_source_reference: "Fixture signed W-4",
          created_by: client_manager
        )
        employee.employee_w4_elections.create!(
          company: company, effective_on: Date.new(2026, 12, 1), filing_status: "single",
          source: "client_direct", reason: "Scheduled fixture", created_by: client_manager
        )

        get "/api/v1/client/employees/#{employee.id}"
        expect(response).to have_http_status(:ok)
        election = response.parsed_body.fetch("data").fetch("current_w4_election")
        expect(election).to include(
          "id" => current.id, "effective_on" => "2026-11-01", "filing_status" => "married",
          "additional_withholding" => "42.0", "w4_signed_on" => "2026-10-29", "source" => "client_direct"
        )
        expect(election.keys).not_to include("reason", "w4_source_reference", "created_by_id")
      end
    end

    it "includes reportable off-cycle paychecks in edit warnings and reserves approved regular runs for termination" do
      unlock_and_enable_client_managed!
      employee = create(:employee, :hourly, company: company)
      calculated = create(:pay_period, :calculated, company: company, run_purpose: "bonus",
                          start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20))
      approved = create(:pay_period, :approved, company: company, run_purpose: "commission",
                        start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 23), pay_date: Date.new(2026, 11, 28))
      correction = create(:pay_period, :calculated, company: company, run_purpose: "correction",
                          start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 6), pay_date: Date.new(2026, 12, 11))
      [ calculated, approved, correction ].each do |period|
        create(:payroll_item, company: company, pay_period: period, employee: employee)
      end
      reversed = create(:pay_period, :calculated, company: company, run_purpose: "bonus",
                        start_date: Date.new(2026, 12, 7), end_date: Date.new(2026, 12, 13), pay_date: Date.new(2026, 12, 18))
      reversed_item = create(:payroll_item, company: company, pay_period: reversed, employee: employee)
      reversed_item.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: staff_manager.id, payroll_reversal_reason: "Fixture reversal")

      get "/api/v1/client/employees/#{employee.id}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "lifecycle_edit_context")).to include(
        "calculated_through" => "2026-11-15", "calculated_pay_date" => "2026-11-20",
        "approved_pay_date" => "2026-11-28", "approved_runs" => []
      )
    end

    it "filters returned employees before pagination and ignores the filter in approval-first mode" do
      plain = create(:employee, :hourly, company: company, last_name: "Aardvark")
      returned = create(:employee, :hourly, company: company, last_name: "Sample")
      EmployeeVerificationItems::Recorder.record!(
        employee: returned, actor: client_manager, event_kind: "profile_change",
        changed_fields: [ "job_title" ], before_values: { "job_title" => nil }, after_values: { "job_title" => "Baker" }
      ).update!(status: "returned_to_client", return_note: "Please confirm the worker’s title.", returned_by: staff_manager, returned_at: Time.current)

      get "/api/v1/client/employees", params: { needs_attention: true, per_page: 1 }
      expect(response.parsed_body.fetch("data").pluck("id")).to eq([ plain.id ])
      expect(response.parsed_body.dig("meta", "total_count")).to eq(2)

      unlock_and_enable_client_managed!
      get "/api/v1/client/employees", params: { needs_attention: true, per_page: 1 }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").pluck("id")).to eq([ returned.id ])
      expect(response.parsed_body.dig("meta", "total_count")).to eq(1)
    end
  end

  describe "approval_first regression (default mode after unlock)" do
    it "unlocks client_portal.employee_lifecycle_mode while keeping every default company approval_first and 100% unchanged" do
      expect(OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES).not_to have_key("client_portal.employee_lifecycle_mode")
      expect(CompanyFeatures::LOCKED_OFF).not_to include("client_portal.employee_lifecycle_mode")
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

    it "preserves approval_first PATCH semantics for own-address vs pay+SSN requests and avoids per-row CompanyFeatures queries on GET /client/employees" do
      ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
          client_portal_enabled: true,
          employee_portal_enabled: true,
          options: { "employee_portal" => { "features" => { "profile_requests" => true } } }
        )
      )
      EmployeeAppActivation.create!(company: company, part: EmployeeAppSwitch::MASTER, activated_by: staff_manager, activated_at: Time.current)
      EmployeeAppActivation.create!(company: company, part: "employee_portal.features.profile_requests", activated_by: staff_manager, activated_at: Time.current)

      own_emp = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Sloane",
        last_name: "Owner",
        email: "sloane.owner@example.test",
        address_line1: "100 Old Rd",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )
      EmployeeAccountLink.create!(company: company, employee: own_emp, user: client_manager, status: "active", activated_at: 1.week.ago)

      other_emp = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Casey",
        last_name: "Coworker",
        ssn_encrypted: "900-10-2030",
        pay_rate: 18.00
      )

      # Own-record address edit stays profile_address? with nil sensitive_payload
      patch "/api/v1/client/employees/#{own_emp.id}", params: {
        employee: { address_line1: "200 New Rd" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      addr_req = EmployeeChangeRequest.where(employee: own_emp).order(:id).last
      expect(addr_req.own_record).to be(true)
      expect(addr_req.profile_address?).to be(true)
      expect(addr_req.sensitive_payload_encrypted).to be_nil

      # Non-own pay + SSN edit routes through approval_first EmployeeChangeRequest with zero verification items
      expect do
        patch "/api/v1/client/employees/#{other_emp.id}", params: {
          employee: {
            pay_rate: 22.50,
            ssn: "900-55-6677",
            ssn_confirmation: "900-55-6677"
          }
        }, as: :json
      end.to change(EmployeeChangeRequest, :count).by(1).and change(EmployeeVerificationItem, :count).by(0)
      expect(response).to have_http_status(:ok), response.body
      pay_req = EmployeeChangeRequest.where(employee: other_emp).order(:id).last
      expect(pay_req.own_record).to be(false)
      expect(pay_req.profile_address?).to be(false)
      expect(pay_req.sensitive_payload.dig(:proposed, :ssn_encrypted)).to eq("900-55-6677")

      # M1: GET /client/employees in approval_first must NOT issue per-row ClientOperatingProfile queries
      count_profile_queries = lambda do
        queries = []
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA" || payload[:cached]

          sql = payload[:sql].to_s
          queries << sql if sql.include?("client_operating_profiles")
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          get "/api/v1/client/employees"
        end
        expect(response).to have_http_status(:ok)
        queries.size
      end

      queries_with_two = count_profile_queries.call
      4.times do |idx|
        create(:employee, :hourly, company: company, first_name: "List#{idx}", last_name: "Worker")
      end
      queries_with_six = count_profile_queries.call

      expect(queries_with_two).to eq(1)
      expect(queries_with_six).to eq(1)
      expect(response.parsed_body.fetch("data").all? { |row| !row.key?("readiness") }).to be(true)
    end
  end

  describe "client_managed employee creation, direct edits, verification coalescing, terminate, and rehire" do
    before do
      unlock_and_enable_client_managed!
    end

    it "creates an Incomplete hire directly with readiness_gate_enforced=true, transitions to Ready on update, and records verification items" do
      travel_to(Time.utc(2026, 11, 20, 12)) do
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

      # Cross-company index filtering never leaks other company's items (M3)
      get "/api/v1/client/verification_items", params: { employee_id: other_worker.id }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).to eq([])

      # Malformed employee_id filter (array or non-numeric) returns 422
      get "/api/v1/client/verification_items", params: { employee_id: [ worker.id.to_s ] }
      expect(response).to have_http_status(:unprocessable_content)
      get "/api/v1/client/verification_items", params: { employee_id: "not-an-id" }
      expect(response).to have_http_status(:unprocessable_content)

      # Responding to an item that is NOT returned_to_client returns 422 (M3)
      post "/api/v1/client/verification_items/#{returned_item.id}/respond",
           params: { note: "Second response after already resubmitted" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      # Responding to an item acknowledged in a committed pay run leaves the acknowledged row and its snapshot untouched,
      # creating a new pending_verification item linked through prior_unverified_item_id
      committed_period = create(:pay_period, company: company, status: "committed", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      ack_returned = EmployeeVerificationItem.create!(
        company: company,
        employee: worker,
        event_kind: "compensation_change",
        status: "returned_to_client",
        affects_pay: true,
        changed_fields: [ "pay_rate" ],
        before_values: { "pay_rate" => 18.0 },
        after_values: { "pay_rate" => 21.0 },
        returned_by: staff_manager,
        returned_at: 1.hour.ago,
        return_note: "Confirm rate change"
      )
      original_updated_at = ack_returned.updated_at
      PayPeriodVerificationAcknowledgement.create!(
        company: company,
        pay_period: committed_period,
        employee_verification_item: ack_returned,
        employee: worker,
        acknowledged_by: staff_manager,
        acknowledged_at: Time.current,
        item_status_snapshot: ack_returned.status,
        item_updated_at_snapshot: original_updated_at
      )

      expect do
        post "/api/v1/client/verification_items/#{ack_returned.id}/respond",
             params: { note: "Confirmed rate is accurate." }, as: :json
      end.to change(EmployeeVerificationItem, :count).by(1)
      expect(response).to have_http_status(:ok), response.body
      expect(ack_returned.reload.status).to eq("returned_to_client")
      expect(ack_returned.updated_at.utc.iso8601(6)).to eq(original_updated_at.utc.iso8601(6))

      replacement = EmployeeVerificationItem.find(response.parsed_body.dig("data", "id"))
      expect(replacement.id).not_to eq(ack_returned.id)
      expect(replacement.status).to eq("pending_verification")
      expect(replacement.metadata["prior_unverified_item_id"]).to eq(ack_returned.id)
      expect(replacement.metadata["client_response_note"]).to eq("Confirmed rate is accurate.")
    end

    it "reuses the existing open linked pending item when responding repeatedly to an acknowledged returned item (B2)" do
      worker = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Resubmit")
      committed_period = create(
        :pay_period,
        company: company,
        status: "committed",
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20)
      )
      ack_returned = EmployeeVerificationItem.create!(
        company: company,
        employee: worker,
        event_kind: "compensation_change",
        status: "returned_to_client",
        affects_pay: true,
        changed_fields: [ "pay_rate" ],
        before_values: { "pay_rate" => 18.0 },
        after_values: { "pay_rate" => 21.0 },
        returned_by: staff_manager,
        returned_at: 1.hour.ago,
        return_note: "Confirm rate change"
      )
      original_updated_at = ack_returned.updated_at
      PayPeriodVerificationAcknowledgement.create!(
        company: company,
        pay_period: committed_period,
        employee_verification_item: ack_returned,
        employee: worker,
        acknowledged_by: staff_manager,
        acknowledged_at: Time.current,
        item_status_snapshot: ack_returned.status,
        item_updated_at_snapshot: original_updated_at
      )

      notes = [
        "First response: confirmed rate matches offer.",
        "Second response: double-checked pay table.",
        "Third response: manager signed off."
      ]
      returned_ids = []

      notes.each do |note_text|
        post "/api/v1/client/verification_items/#{ack_returned.id}/respond",
             params: { note: note_text }, as: :json
        expect(response).to have_http_status(:ok), response.body
        returned_ids << response.parsed_body.dig("data", "id")
      end

      expect(returned_ids.uniq.size).to eq(1)
      linked_items = EmployeeVerificationItem
        .where(company: company, employee: worker)
        .where("metadata ->> 'prior_unverified_item_id' = ?", ack_returned.id.to_s)
        .to_a
      expect(linked_items.size).to eq(1)

      linked = linked_items.first
      expect(linked.id).to eq(returned_ids.first)
      expect(linked.id).not_to eq(ack_returned.id)
      expect(linked.status).to eq("pending_verification")
      notes.each do |note_text|
        expect(linked.metadata["client_response_note"]).to include(note_text)
        expect(response.parsed_body.dig("data", "client_response_note")).to include(note_text)
      end

      expect(ack_returned.reload.status).to eq("returned_to_client")
      expect(ack_returned.updated_at.utc.iso8601(6)).to eq(original_updated_at.utc.iso8601(6))
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

        expect(response.parsed_body.dig("data", "lifecycle_edit_context", "rehire_readiness")).to be_present
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
        expect(response.parsed_body.dig("data", "lifecycle_edit_context")).to include(
          "own_record" => false, "rehire_readiness" => nil
        )
        rehire_item = EmployeeVerificationItem.where(employee: worker, event_kind: "rehire").last
        expect(rehire_item).to be_present
        expect(rehire_item.changed_fields).to include("readiness_gate_enforced")
        expect(rehire_item.before_values["readiness_gate_enforced"]).to be(false)
        expect(rehire_item.after_values["readiness_gate_enforced"]).to be(true)
        expect(AuditLog.where(company_id: company.id, action: "client_employees#rehire", record_id: worker.id)).to exist

        # Rehire when readiness_gate_enforced is ALREADY true omits readiness_gate_enforced from changed_fields/before/after
        already_gated_terminated = create(
          :employee,
          :hourly,
          company: company,
          first_name: "Avery",
          last_name: "AlreadyGated",
          status: "terminated",
          hire_date: Date.new(2026, 1, 1),
          termination_date: Date.new(2026, 10, 15),
          readiness_gate_enforced: true
        )
        post "/api/v1/client/employees/#{already_gated_terminated.id}/rehire", params: {
          effective_date: "2026-11-19"
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        gated_rehire_item = EmployeeVerificationItem.where(employee: already_gated_terminated, event_kind: "rehire").last
        expect(gated_rehire_item.changed_fields).to eq(%w[status termination_date])
        expect(gated_rehire_item.before_values).not_to have_key("readiness_gate_enforced")
        expect(gated_rehire_item.after_values).not_to have_key("readiness_gate_enforced")

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

      # 1. Duplicate SSN rejected on client create (regardless of dash formatting) using direct deterministic SQL lookup (L7)
      undashed_existing = create(:employee, :hourly, company: company, first_name: "Undashed", last_name: "Worker", ssn_encrypted: "900556677")
      ssn_queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        sql = payload[:sql].to_s
        ssn_queries << sql if sql.include?("ssn_encrypted")
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        post "/api/v1/client/employees", params: {
          employee: {
            first_name: "New",
            last_name: "Dup",
            employment_type: "hourly",
            ssn: "900445566",
            ssn_confirmation: "900445566"
          }
        }, as: :json
      end
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "ssn")).to include("This Social Security Number is already assigned to another employee in this company.")
      expect(ssn_queries.any? { |sql| sql.include?("SELECT 1 AS one") && sql.include?("ssn_encrypted") }).to be(true)
      expect(ssn_queries.none? { |sql| sql.include?('SELECT "employees"."id", "employees"."ssn_encrypted"') }).to be(true)

      # Dashed submission also collides against undashed DB row
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "New",
          last_name: "DupTwo",
          employment_type: "hourly",
          ssn: "900-55-6677",
          ssn_confirmation: "900-55-6677"
        }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("details", "ssn")).to include("This Social Security Number is already assigned to another employee in this company.")
      expect(undashed_existing.reload.ssn_encrypted).to eq("900556677")

      # N1: Non-canonical stored SSN formats (dots, trailing space, odd grouping, parentheses) are still caught via normalized-digit fallback
      [
        [ "dots", "900.11.2233", "900-11-2233" ],
        [ "trailing_space", "900-11-2234 ", "900-11-2234" ],
        [ "odd_grouping", "9001-12235", "900-11-2235" ],
        [ "parentheses", "(900)112236", "900-11-2236" ]
      ].each do |label, stored_format, submitted_format|
        create(:employee, :hourly, company: company, first_name: "Stored", last_name: label.camelize, ssn_encrypted: stored_format)
        other_editor = create(:employee, :hourly, company: company, first_name: "Edit", last_name: label.camelize, ssn_encrypted: "900-90-0001")

        post "/api/v1/client/employees", params: {
          employee: {
            first_name: "CreateDup",
            last_name: label.camelize,
            employment_type: "hourly",
            ssn: submitted_format,
            ssn_confirmation: submitted_format
          }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content), "Expected create duplicate rejection for #{label} (#{stored_format})"
        expect(response.parsed_body.dig("details", "ssn")).to include("This Social Security Number is already assigned to another employee in this company.")

        patch "/api/v1/client/employees/#{other_editor.id}", params: {
          employee: { ssn: submitted_format, ssn_confirmation: submitted_format }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content), "Expected update duplicate rejection for #{label} (#{stored_format})"
        expect(response.parsed_body.dig("details", "ssn")).to include("This Social Security Number is already assigned to another employee in this company.")
      end

      # Post-lock SSN confirmation: if another writer changed the employee's SSN before the lock,
      # submitting the stale pre-lock SSN without ssn_confirmation is still rejected with 422.
      stale_ssn_emp = create(:employee, :hourly, company: company, first_name: "Race", last_name: "Ssn", ssn_encrypted: "900-71-8293")
      mutated_ssn = false
      allow(Employee).to receive(:find_by).and_wrap_original do |method, *args, **kwargs|
        loaded = method.call(*args, **kwargs)
        if !mutated_ssn && loaded&.id == stale_ssn_emp.id
          mutated_ssn = true
          Employee.find(stale_ssn_emp.id).update!(ssn_encrypted: "900-71-9999")
        end
        loaded
      end
      patch "/api/v1/client/employees/#{stale_ssn_emp.id}", params: {
        employee: { ssn: "900-71-8293" }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content), response.body
      expect(response.parsed_body.dig("details", "ssn_confirmation")).to be_present
      expect(stale_ssn_emp.reload.ssn_digits).to eq("900719999")
      allow(Employee).to receive(:find_by).and_call_original

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

      # 3b. Replacing a legacy duplicated SSN with a unique new SSN succeeds (does not match the replaced SSN)
      patch "/api/v1/client/employees/#{existing_a.id}", params: {
        employee: { ssn: "900-44-9999", ssn_confirmation: "900-44-9999" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(existing_a.reload.ssn_encrypted).to eq("900-44-9999")
      existing_a.update_columns(ssn_encrypted: "900-44-5566")

      # 4. Staff edits through the admin endpoint on existing shared-SSN records succeed (M3: no global model validation!)
      @admin_user = staff_manager
      patch "/api/v1/admin/employees/#{existing_b.id}", params: {
        employee: { job_title: "Sous Chef" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(existing_b.reload.job_title).to eq("Sous Chef")

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
      # M2: staff-only tax_filing_impact metadata is NOT leaked in client response
      returned_tax_item = response.parsed_body.fetch("verification_items").find { |i| i["event_kind"] == "identity_tax_change" }
      expect(returned_tax_item.fetch("metadata")).not_to have_key("tax_filing_impact")
      expect(returned_tax_item.fetch("metadata")).not_to have_key("prior_unverified_item_id")
    end

    it "creates pay-affecting verification items for retirement/match rates and covers every writable field in ClientEmployeeUpdateService (H1)" do
      worker = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Morgan",
        last_name: "Benefits",
        pay_rate: 20.0,
        retirement_rate: 0.0,
        roth_retirement_rate: 0.0,
        employer_retirement_match_rate: 0.0,
        employer_roth_match_rate: 0.0
      )

      patch "/api/v1/client/employees/#{worker.id}", params: {
        employee: {
          retirement_rate: 0.08,
          roth_retirement_rate: 0.02,
          employer_retirement_match_rate: 0.04,
          employer_roth_match_rate: 0.01
        }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body

      worker.reload
      expect(worker.retirement_rate.to_f).to eq(0.08)
      expect(worker.employer_retirement_match_rate.to_f).to eq(0.04)

      comp_item = EmployeeVerificationItem.where(employee: worker, event_kind: "compensation_change").order(:id).last
      expect(comp_item).to be_present
      expect(comp_item.affects_pay).to be(true)
      expect(comp_item.changed_fields).to include(
        "retirement_rate",
        "roth_retirement_rate",
        "employer_retirement_match_rate",
        "employer_roth_match_rate"
      )

      # Guard: every writable field in ClientEmployeeUpdateService must be either
      # in a pay-affecting verification group or explicitly in PROFILE_CHANGE_FIELDS.
      pay_fields = ClientEmployeeUpdateService::PAY_AFFECTING_VERIFICATION_FIELDS
      non_pay_fields = ClientEmployeeUpdateService::PROFILE_CHANGE_FIELDS
      covered_fields = (pay_fields + non_pay_fields).uniq

      unlisted = ClientEmployeeUpdateService::WRITABLE_FIELDS - covered_fields
      expect(unlisted).to eq([]), "Unlisted writable fields must be classified as pay-affecting or PROFILE_CHANGE_FIELDS: #{unlisted.inspect}"

      # Every APPROVAL_FIELDS + PAYMENT_METHOD_FIELD entry MUST be pay-affecting (never non-pay or unlisted).
      pay_required = ClientEmployeeUpdateService::APPROVAL_FIELDS + [ ClientEmployeeUpdateService::PAYMENT_METHOD_FIELD ]
      missing_from_pay = pay_required - pay_fields
      expect(missing_from_pay).to eq([]), "Pay-affecting fields missing from verification groups: #{missing_from_pay.inspect}"
      expect(pay_required & non_pay_fields).to eq([])

      # Table-driven live write check over every pay-required field
      salary_worker = create(
        :employee,
        :salary,
        company: company,
        first_name: "Syd",
        last_name: "Salary",
        pay_rate: 52_000.0,
        salary_type: "annual",
        pay_frequency: "biweekly",
        ssn_encrypted: "900-31-4159",
        payment_delivery_method: "paper_check",
        default_custom_earnings: [ { "label" => "Legacy Stipend", "amount" => 50.0 } ],
        default_payroll_adjustments: [ { "label" => "Legacy Uniform", "amount" => 15.0, "treatment" => "post_tax_deduction", "active" => true } ]
      )
      contractor_worker = create(
        :employee,
        :contractor,
        company: company,
        first_name: "Cory",
        last_name: "Contractor",
        contractor_type: "business",
        business_name: "Old Co LLC",
        contractor_ein: "90-1234567",
        contractor_pay_type: "flat_fee",
        w9_on_file: false
      )
      hourly_worker = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Hayden",
        last_name: "Hourly",
        pay_rate: 18.0,
        pay_frequency: "biweekly",
        filing_status: "single",
        allowances: 0,
        additional_withholding: 0,
        w4_dependent_credit: 0,
        w4_step2_multiple_jobs: false,
        w4_step4a_other_income: 0,
        w4_step4b_deductions: 0,
        w4_form_version: 2020,
        w4_signed_on: Date.new(2026, 1, 1),
        w4_effective_on: Date.new(2026, 1, 1),
        w4_source_reference: "W4-OLD",
        payment_delivery_method: "paper_check"
      )

      field_samples = {
        ssn_encrypted: [ hourly_worker, { ssn_encrypted: "900-31-4160" }, ->(e) { e.require_ssn_confirmation = true; e.ssn_confirmation = "900-31-4160" } ],
        employment_type: [ hourly_worker, { employment_type: "salary", salary_type: "annual", pay_rate: 48_000.0 }, nil ],
        salary_type: [ salary_worker, { salary_type: "per_period", pay_rate: 2_000.0 }, nil ],
        pay_rate: [ salary_worker, { pay_rate: 2_100.0 }, nil ],
        pay_frequency: [ salary_worker, { pay_frequency: "semimonthly" }, nil ],
        filing_status: [ hourly_worker, { filing_status: "married", w4_signed_on: Date.new(2026, 2, 1), w4_effective_on: Date.new(2026, 2, 1), w4_election_received: true }, nil ],
        allowances: [ hourly_worker, { allowances: 2, w4_signed_on: Date.new(2026, 2, 2), w4_effective_on: Date.new(2026, 2, 2), w4_election_received: true }, nil ],
        additional_withholding: [ hourly_worker, { additional_withholding: 25.0, w4_signed_on: Date.new(2026, 2, 3), w4_effective_on: Date.new(2026, 2, 3), w4_election_received: true }, nil ],
        w4_dependent_credit: [ hourly_worker, { w4_dependent_credit: 500.0, w4_signed_on: Date.new(2026, 2, 4), w4_effective_on: Date.new(2026, 2, 4), w4_election_received: true }, nil ],
        w4_step2_multiple_jobs: [ hourly_worker, { w4_step2_multiple_jobs: true, w4_signed_on: Date.new(2026, 2, 5), w4_effective_on: Date.new(2026, 2, 5), w4_election_received: true }, nil ],
        w4_step4a_other_income: [ hourly_worker, { w4_step4a_other_income: 100.0, w4_signed_on: Date.new(2026, 2, 6), w4_effective_on: Date.new(2026, 2, 6), w4_election_received: true }, nil ],
        w4_step4b_deductions: [ hourly_worker, { w4_step4b_deductions: 200.0, w4_signed_on: Date.new(2026, 2, 7), w4_effective_on: Date.new(2026, 2, 7), w4_election_received: true }, nil ],
        w4_form_version: [ hourly_worker, { w4_form_version: 2021, w4_signed_on: Date.new(2026, 2, 8), w4_effective_on: Date.new(2026, 2, 8), w4_election_received: true }, nil ],
        w4_signed_on: [ hourly_worker, { w4_signed_on: Date.new(2026, 2, 9), w4_effective_on: Date.new(2026, 2, 9), w4_election_received: true }, nil ],
        w4_source_reference: [ hourly_worker, { w4_source_reference: "W4-NEW", w4_signed_on: Date.new(2026, 2, 10), w4_effective_on: Date.new(2026, 2, 10), w4_election_received: true }, nil ],
        w4_effective_on: [ hourly_worker, { w4_signed_on: Date.new(2026, 2, 11), w4_effective_on: Date.new(2026, 2, 12), w4_election_received: true }, nil ],
        w4_election_received: [ hourly_worker, { w4_signed_on: Date.new(2026, 2, 12), w4_effective_on: Date.new(2026, 2, 13), w4_election_received: true }, nil ],
        retirement_rate: [ salary_worker, { retirement_rate: 0.05 }, nil ],
        roth_retirement_rate: [ salary_worker, { roth_retirement_rate: 0.03 }, nil ],
        employer_retirement_match_rate: [ salary_worker, { employer_retirement_match_rate: 0.04 }, nil ],
        employer_roth_match_rate: [ salary_worker, { employer_roth_match_rate: 0.02 }, nil ],
        business_name: [ contractor_worker, { business_name: "New Co LLC" }, nil ],
        contractor_ein: [ contractor_worker, { contractor_ein: "90-7654321" }, nil ],
        contractor_type: [ contractor_worker, { contractor_type: "individual", ssn_encrypted: "900-31-4161" }, ->(e) { e.require_ssn_confirmation = true; e.ssn_confirmation = "900-31-4161" } ],
        contractor_pay_type: [ contractor_worker, { contractor_pay_type: "hourly", pay_rate: 45.0 }, nil ],
        w9_on_file: [ contractor_worker, { w9_on_file: true }, nil ],
        default_custom_earnings: [ salary_worker, { default_custom_earnings: [] }, nil ],
        default_payroll_adjustments: [ salary_worker, { default_payroll_adjustments: [] }, nil ],
        wage_rates: [ contractor_worker, { wage_rates: [ { label: "Field", rate: 50.0, is_primary: true, active: true } ] }, nil ],
        payment_delivery_method: [ salary_worker, { payment_delivery_method: "direct_deposit" }, nil ]
      }

      expect(field_samples.keys).to match_array(pay_required)
      pay_required.each do |field|
        emp, attrs, setup = field_samples.fetch(field)
        EmployeeVerificationItem.where(employee_id: emp.id).update_all(superseded_by_id: nil)
        EmployeeVerificationItem.where(employee_id: emp.id).delete_all
        emp.reload
        setup&.call(emp)
        res = ClientEmployeeUpdateService.new(employee: emp, attrs: attrs, requested_by: client_manager, company: company).update!
        expect(res.changed_fields.map(&:to_s)).to include(field.to_s), "Expected res.changed_fields to include #{field}"
        pay_items = res.verification_items.select { |item| item.affects_pay && item.changed_fields.include?(field.to_s) }
        expect(pay_items).not_to be_empty, "Expected pay-affecting verification item for field #{field}"
      end
    end

    it "handles contractor W-4 payloads, explicit unchanged w4_effective_on, coalesced multi-field baselines, and period-matched W-4 readiness on index" do
      # 1. Contractors must not report W-4 fields in applied_direct_fields or create w4_change verification items
      contractor = create(:employee, :contractor, company: company, first_name: "Casey", last_name: "ContractorW4")
      expect do
        patch "/api/v1/client/employees/#{contractor.id}", params: {
          employee: {
            filing_status: "married",
            w4_signed_on: "2026-11-01",
            w4_effective_on: "2026-11-01",
            w4_election_received: true,
            job_title: "Consultant"
          }
        }, as: :json
      end.not_to change { EmployeeVerificationItem.where(employee: contractor, event_kind: "w4_change").count }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("applied_direct_fields")).to eq([ "job_title" ])

      # 1b. Contractor creation with W-4 fields / w4_election_received does not apply or report W-4 fields
      expect do
        post "/api/v1/client/employees", params: {
          employee: {
            first_name: "Casey",
            last_name: "NewContractorW4",
            employment_type: "contractor",
            contractor_type: "individual",
            contractor_pay_type: "flat_fee",
            filing_status: "married",
            w4_signed_on: "2026-11-01",
            w4_effective_on: "2026-11-01",
            w4_election_received: true
          }
        }, as: :json
      end.not_to change(EmployeeW4Election, :count)
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body.fetch("applied_direct_fields")).not_to include(
        "w4_election_received", "filing_status", "w4_signed_on", "w4_effective_on"
      )
      contractor_hire_item = EmployeeVerificationItem.order(:id).last
      expect(contractor_hire_item.event_kind).to eq("new_hire")
      expect(contractor_hire_item.changed_fields).not_to include(
        "w4_election_received", "filing_status", "w4_signed_on", "w4_effective_on"
      )
      expect(contractor_hire_item.after_values.keys).not_to include(
        "w4_election_received", "filing_status", "w4_signed_on", "w4_effective_on"
      )

      # 2. Explicitly submitted w4_effective_on is preserved even when matching the current value; omitted date falls back to next unapproved pay date
      later_period = create(
        :pay_period,
        company: company,
        status: "draft",
        cycle: "regular",
        run_purpose: "regular",
        start_date: Date.new(2026, 12, 1),
        end_date: Date.new(2026, 12, 14),
        pay_date: Date.new(2026, 12, 19)
      )
      w4_worker = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Drew",
        last_name: "Withholding",
        filing_status: "single",
        w4_effective_on: Date.new(2026, 11, 1),
        w4_signed_on: Date.new(2026, 11, 1),
        w4_form_version: 2020
      )
      EmployeeW4Election.create!(
        EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
          company: company,
          employee: w4_worker,
          filing_status: "single",
          effective_on: Date.new(2026, 11, 1),
          w4_signed_on: Date.new(2026, 11, 1),
          w4_form_version: 2020,
          source: "client_direct",
          reason: "Initial W-4"
        )
      )

      patch "/api/v1/client/employees/#{w4_worker.id}", params: {
        employee: {
          filing_status: "married",
          w4_effective_on: "2026-11-01"
        }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(w4_worker.employee_w4_elections.recent_first.first.effective_on).to eq(Date.new(2026, 11, 1))

      patch "/api/v1/client/employees/#{w4_worker.id}", params: {
        employee: {
          additional_withholding: 35.0
        }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(w4_worker.employee_w4_elections.recent_first.first.effective_on).to eq(later_period.pay_date)

      # 3. Coalescing preserves the earliest before_value for every field across all open items (not only open_items.last)
      coalesce_emp = create(:employee, :salary, company: company, first_name: "Blake", last_name: "Coalesce", salary_type: "annual", pay_rate: 50_000.0)
      committed_run = create(:pay_period, company: company, status: "committed", start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 14), pay_date: Date.new(2026, 10, 20))
      item_a = EmployeeVerificationItems::Recorder.record!(
        employee: coalesce_emp,
        actor: client_manager,
        event_kind: "compensation_change",
        changed_fields: [ "pay_rate" ],
        before_values: { "pay_rate" => 48_000.0 },
        after_values: { "pay_rate" => 50_000.0 }
      )
      PayPeriodVerificationAcknowledgement.create!(
        company: company,
        pay_period: committed_run,
        employee_verification_item: item_a,
        employee: coalesce_emp,
        acknowledged_by: staff_manager,
        acknowledged_at: Time.current,
        item_status_snapshot: item_a.status,
        item_updated_at_snapshot: item_a.updated_at
      )
      EmployeeVerificationItems::Recorder.record!(
        employee: coalesce_emp,
        actor: client_manager,
        event_kind: "compensation_change",
        changed_fields: [ "salary_type" ],
        before_values: { "salary_type" => "annual" },
        after_values: { "salary_type" => "variable" }
      )
      item_c = EmployeeVerificationItems::Recorder.record!(
        employee: coalesce_emp,
        actor: client_manager,
        event_kind: "compensation_change",
        changed_fields: [ "salary_type" ],
        before_values: { "salary_type" => "variable" },
        after_values: { "salary_type" => "annual" }
      )
      expect(item_c.before_values["pay_rate"]).to eq(48_000.0)
      expect(item_c.before_values["salary_type"]).to eq("annual")

      # 4. GET /client/employees?rates_on=<entry.end_date> uses the authorized submission entry's payday (not an unrelated earlier-paying run sharing end_date)
      travel_to(Time.utc(2026, 12, 15, 12)) do
        period_a = create(
          :pay_period,
          company: company,
          status: "draft",
          cycle: "regular",
          run_purpose: "regular",
          start_date: Date.new(2026, 11, 17),
          end_date: Date.new(2026, 11, 30),
          pay_date: Date.new(2026, 12, 5)
        )
        # Another approved regular run sharing end_date Dec 14 with an earlier payday (Dec 17)
        create(
          :pay_period,
          :approved,
          company: company,
          cycle: "regular",
          run_purpose: "regular",
          start_date: Date.new(2026, 12, 8),
          end_date: Date.new(2026, 12, 14),
          pay_date: Date.new(2026, 12, 17)
        )
        PayrollSubmissionPeriod.create!(
          company: company,
          start_date: later_period.start_date,
          end_date: later_period.end_date,
          pay_date: later_period.pay_date,
          pay_period: later_period,
          source: "pay_period"
        )
        dated_w4_worker = create(
          :employee,
          :hourly,
          company: company,
          first_name: "Parker",
          last_name: "Payday",
          date_of_birth: Date.new(1992, 5, 1),
          hire_date: Date.new(2026, 11, 1),
          pay_rate: 20.0,
          pay_frequency: "biweekly",
          payment_delivery_method: "paper_check",
          readiness_gate_enforced: true
        )
        EmployeeW4Election.create!(
          EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
            company: company,
            employee: dated_w4_worker,
            effective_on: Date.new(2026, 12, 18),
            w4_signed_on: Date.new(2026, 12, 1),
            w4_form_version: 2020,
            source: "client_direct",
            reason: "Between Dec 17 approved run payday and Dec 19 submission payday"
          )
        )
        allow(company).to receive(:portal_payroll_files_enabled?).and_return(true)
        expect(EmployeeReadinessEvaluator.for_pay_period(dated_w4_worker, period_a)).to be_incomplete
        expect(EmployeeReadinessEvaluator.for_pay_period(dated_w4_worker, later_period)).to be_ready

        get "/api/v1/client/employees", params: { rates_on: later_period.end_date.iso8601, per_page: 100 }
        expect(response).to have_http_status(:ok), response.body
        row = response.parsed_body.fetch("data").find { |entry| entry["id"] == dated_w4_worker.id }
        expect(row.dig("readiness", "w4_on")).to eq(later_period.pay_date.iso8601)
        expect(row.dig("readiness", "status")).to eq("ready")
      end
    end

    it "batches readiness queries in O(1) on GET /client/employees in client_managed mode and strips both effective_on keys on create (M1, L4)" do
      # L4: passing both compensation_effective_on and effective_on strips both from submitted_fields/after_values
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "Devon",
          last_name: "Effective",
          employment_type: "hourly",
          compensation_effective_on: "2026-11-01",
          effective_on: "2026-11-01"
        }
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body.fetch("applied_direct_fields")).not_to include("effective_on", "compensation_effective_on")
      created_item = EmployeeVerificationItem.order(:id).last
      expect(created_item.changed_fields).not_to include("effective_on", "compensation_effective_on")
      expect(created_item.after_values).not_to have_key("effective_on")

      # M1: O(1) readiness + CompanyFeatures queries on GET /client/employees in client_managed mode
      count_readiness_queries = lambda do
        counts = Hash.new(0)
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA" || payload[:cached]

          sql = payload[:sql].to_s
          %w[client_operating_profiles pay_periods employee_status_events payroll_items].each do |table|
            counts[table] += 1 if sql.include?(table)
          end
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          get "/api/v1/client/employees"
        end
        expect(response).to have_http_status(:ok)
        counts
      end

      counts_one = count_readiness_queries.call
      5.times do |idx|
        create(:employee, :hourly, company: company, first_name: "Batch#{idx}", last_name: "Worker", readiness_gate_enforced: true)
      end
      counts_six = count_readiness_queries.call

      expect(counts_six["client_operating_profiles"]).to eq(1)
      expect(counts_six).to eq(counts_one)
      expect(response.parsed_body.fetch("data").all? { |row| row["readiness"].is_a?(Hash) }).to be(true)

      # M1: verify rates_on passed to GET /client/employees is honored by readiness evaluation
      travel_to(Time.utc(2026, 11, 20, 12)) do
        allow(company).to receive(:portal_payroll_files_enabled?).and_return(true)
        open_period = create(
          :pay_period,
          company: company,
          status: "draft",
          start_date: Date.new(2026, 11, 1),
          end_date: Date.new(2026, 11, 14),
          pay_date: Date.new(2026, 11, 20)
        )
        PayrollSubmissionPeriod.create!(
          company: company,
          start_date: open_period.start_date,
          end_date: open_period.end_date,
          pay_date: open_period.pay_date,
          pay_period: open_period,
          source: "pay_period"
        )
        get "/api/v1/client/employees", params: { rates_on: open_period.end_date.iso8601 }
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("data").first.dig("readiness", "rates_on")).to eq(open_period.end_date.iso8601)
      end

      # Staff create and bulk import do NOT stamp readiness_gate_enforced even in client_managed mode (M3)
      @admin_user = staff_manager
      post "/api/v1/admin/employees", params: {
        employee: {
          first_name: "Staff",
          last_name: "Hire",
          employment_type: "hourly",
          pay_rate: 20.0,
          pay_frequency: "biweekly",
          filing_status: "single",
          ssn: "900-41-5263",
          ssn_confirmation: "900-41-5263",
          hire_date: "2026-10-01",
          w4_effective_on: "2026-10-01",
          address_line1: "50 Staff St",
          city: "Hagatna",
          state: "GU",
          zip: "96910"
        }
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      expect(Employee.find(response.parsed_body.dig("data", "id")).readiness_gate_enforced).to be(false)

      import_service = EmployeeBulkImport::ImportService.new(company, actor: staff_manager)
      import_result = import_service.create_employees!([
        {
          row_number: 2,
          attributes: {
            first_name: "Imported",
            last_name: "Worker",
            employment_type: "hourly",
            pay_rate: 21.0,
            pay_frequency: "biweekly",
            filing_status: "single",
            ssn_encrypted: "900-41-5264",
            hire_date: Date.new(2026, 10, 1),
            w4_effective_on: Date.new(2026, 10, 1),
            address_line1: "60 Import Ave",
            city: "Tamuning",
            state: "GU",
            zip: "96913"
          }
        }
      ])
      expect(import_result[:created]).to eq(1)
      expect(Employee.find_by!(first_name: "Imported", last_name: "Worker").readiness_gate_enforced).to be(false)
    end

    it "exposes the first editable compensation date and returns a client-facing field error for locked pay" do
      worker = create(:employee, :hourly, company: company, hire_date: Date.new(2026, 1, 1), pay_rate: 20)
      period = create(:pay_period, :approved, company: company, start_date: Date.new(2026, 11, 1),
                      end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      create(:payroll_item, company: company, pay_period: period, employee: worker)

      get "/api/v1/client/employees/#{worker.id}"
      expect(response.parsed_body.dig("data", "lifecycle_edit_context", "earliest_compensation_effective_on")).to eq("2026-11-15")

      patch "/api/v1/client/employees/#{worker.id}", params: {
        employee: { pay_rate: 24, compensation_effective_on: "2026-11-14" }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("details")).to eq(
        "compensation_effective_on" => [ "Payroll is already approved or finalized through 2026-11-14. Choose 2026-11-15 or later." ]
      )
      expect(worker.reload.pay_rate).to eq(20)
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

    it "clears existing active wage rates when wage_rates: [] is submitted in client_managed mode" do
      travel_to(Time.utc(2026, 11, 20, 12)) do
        worker = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "ClearRates", hire_date: Date.new(2026, 1, 1), pay_rate: 18.0)
        rate_row = EmployeeWageRate.create!(employee: worker, label: "Kitchen", rate: 19.50, is_primary: true, active: true)
        expect(worker.reload.wage_rates_on(PayrollBusinessClock.today).map(&:id)).to eq([ rate_row.id ])

        patch "/api/v1/client/employees/#{worker.id}", params: {
          employee: { wage_rates: [] }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("applied_direct_fields")).to include("wage_rates")
        expect(worker.reload.wage_rates_on(PayrollBusinessClock.today)).to be_empty
        expect(rate_row.reload.active).to be(false)

        comp_item = EmployeeVerificationItem.where(employee: worker, event_kind: "compensation_change").order(:id).last
        expect(comp_item).to be_present
        expect(comp_item.changed_fields).to include("wage_rates")
        expect(comp_item.after_values["wage_rates"]).to eq([])
      end
    end

    it "builds the rehire response payload inside the transaction so post-commit mutations do not mix states" do
      travel_to(Time.utc(2026, 11, 20, 12)) do
        worker = create(
          :employee,
          :hourly,
          company: company,
          first_name: "Jordan",
          last_name: "Snapshot",
          status: "terminated",
          hire_date: Date.new(2026, 1, 1),
          termination_date: Date.new(2026, 10, 15),
          readiness_gate_enforced: true
        )

        # Simulate a concurrent termination committing immediately after the outer rehire transaction commits
        mutated_after_commit = false
        tx_depth = 0
        allow(ActiveRecord::Base).to receive(:transaction).and_wrap_original do |method, *args, **kwargs, &block|
          tx_depth += 1
          begin
            res = method.call(*args, **kwargs, &block)
          ensure
            tx_depth -= 1
          end
          if tx_depth.zero? && !mutated_after_commit && worker.reload.status == "active"
            mutated_after_commit = true
            Employee.where(id: worker.id).update_all(status: "terminated", termination_date: Date.new(2026, 11, 20))
          end
          res
        end

        post "/api/v1/client/employees/#{worker.id}/rehire", params: {
          effective_date: "2026-11-19"
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(mutated_after_commit).to be(true)
        expect(response.parsed_body.dig("data", "status")).to eq("active")
        expect(response.parsed_body.dig("status_event", "resulting_status")).to eq("active")
        expect(worker.reload.status).to eq("terminated")
      end
    end
  end

  describe "security, client_viewer isolation, and dual-role no-self-dealing" do
    before do
      unlock_and_enable_client_managed!(profile_requests: true)
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

      # Client approve route returns 404 for non-address own_record requests EVEN with profile_requests ON (M3)
      patch "/api/v1/client/employee_change_requests/#{change_request.id}/approve", as: :json
      expect(response).to have_http_status(:not_found)

      other_client_manager = create(:user, company: company, organization: organization, role: "client", name: "Other Manager", email: "other.mgr@example.test")
      CompanyAssignment.create!(user: other_client_manager, company: company)
      @acting_user = other_client_manager
      patch "/api/v1/client/employee_change_requests/#{change_request.id}/approve", as: :json
      expect(response).to have_http_status(:not_found)
      @acting_user = client_manager

      # Admin approve refuses same-person reviewer (M3)
      same_person_staff = create(:user, company: company, organization: organization, role: "manager", name: "Sloane Owner", email: "sloane.staff@example.test")
      CompanyAssignment.create!(user: same_person_staff, company: company)
      email_match_self.update_columns(first_name: "Sloane", last_name: "Owner")
      @admin_user = same_person_staff
      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve", as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("Someone else must review")
      email_match_self.update_columns(first_name: "Different", last_name: "Name")

      # Cornerstone staff approves via admin endpoint and applies SSN, pay_rate, and payment_delivery_method (M3)
      @admin_user = staff_manager
      patch "/api/v1/admin/employee_change_requests/#{change_request.id}/approve", as: :json
      expect(response).to have_http_status(:ok), response.body
      email_match_self.reload
      expect(email_match_self.ssn_encrypted).to eq("900-99-8877")
      expect(email_match_self.pay_rate.to_f).to eq(40.0)
      expect(email_match_self.payment_delivery_method).to eq("direct_deposit")
      expect(AuditLog.where(company_id: company.id, action: "employee_change_requests#approve", record_id: change_request.id)).to exist

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

    it "blocks own-record identity/email bypass (H2), keeps own-record detection sticky after rename/re-email, and uses token-set name matching (L6)" do
      own_unlinked = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Sloane",
        last_name: "Owner",
        email: "sloane.owner@example.test",
        date_of_birth: Date.new(1988, 4, 10),
        hire_date: Date.new(2024, 1, 15),
        pay_rate: 28.0
      )

      # Step 1 of exact H2 repro: manager attempts to rename + re-email + alter DOB/hire_date on own record
      patch "/api/v1/client/employees/#{own_unlinked.id}", params: {
        employee: {
          first_name: "S",
          last_name: "Oakes",
          name_suffix: "Jr",
          email: "s.oakes@example.test",
          date_of_birth: "1985-05-05",
          hire_date: "2024-02-01"
        }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body

      # NONE of these identity/email fields were saved directly!
      own_unlinked.reload
      expect(own_unlinked.first_name).to eq("Sloane")
      expect(own_unlinked.last_name).to eq("Owner")
      expect(own_unlinked.email).to eq("sloane.owner@example.test")
      expect(own_unlinked.date_of_birth).to eq(Date.new(1988, 4, 10))
      expect(own_unlinked.hire_date).to eq(Date.new(2024, 1, 15))
      expect(EmployeeVerificationItem.where(employee: own_unlinked)).to be_empty

      rename_req = EmployeeChangeRequest.where(employee: own_unlinked, status: :pending).last
      expect(rename_req).to be_present
      expect(rename_req.own_record).to be(true)
      expect(rename_req.profile_address?).to be(false)
      expect(rename_req.proposed_changes).to include(
        "first_name" => "S",
        "last_name" => "Oakes",
        "name_suffix" => "Jr",
        "email" => "s.oakes@example.test",
        "date_of_birth" => "1985-05-05",
        "hire_date" => "2024-02-01"
      )

      # Client cannot self-approve even with profile_requests ON
      patch "/api/v1/client/employee_change_requests/#{rename_req.id}/approve", as: :json
      expect(response).to have_http_status(:not_found)

      # Even if Cornerstone staff approves the rename + re-email, sticky detection still catches the follow-up pay edit!
      @admin_user = staff_manager
      patch "/api/v1/admin/employee_change_requests/#{rename_req.id}/approve", as: :json
      expect(response).to have_http_status(:ok), response.body
      own_unlinked.reload
      expect(own_unlinked.first_name).to eq("S")
      expect(own_unlinked.last_name).to eq("Oakes")
      expect(own_unlinked.email).to eq("s.oakes@example.test")

      # Step 2: manager tries to raise own pay -> MUST still route to Cornerstone, NOT save directly!
      patch "/api/v1/client/employees/#{own_unlinked.id}", params: {
        employee: { pay_rate: 99.0 }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(own_unlinked.reload.pay_rate.to_f).to eq(28.0)

      pay_req = EmployeeChangeRequest.where(employee: own_unlinked, status: :pending).last
      expect(pay_req).to be_present
      expect(pay_req.own_record).to be(true)
      expect(pay_req.proposed_changes["pay_rate"]).to eq(99.0)

      # L6: token-set name matching catches middle initials, reversed order, and compound names
      middle_initial_manager = create(:user, company: company, organization: organization, role: "client", name: "Sloane M. Owner", email: "different.login@example.test")
      CompanyAssignment.create!(user: middle_initial_manager, company: company)
      target_name_emp = create(:employee, :hourly, company: company, first_name: "Sloane", last_name: "Owner", email: "worker.only@example.test", pay_rate: 22.0)

      expect(EmployeeProfileIdentity.normalized_full_name_match?("Sloane", "Owner", "Sloane M. Owner")).to be(true)
      expect(EmployeeProfileIdentity.normalized_full_name_match?("Sloane", "Owner", "Owner, Sloane")).to be(true)
      expect(EmployeeProfileIdentity.normalized_full_name_match?("Sloane Marie", "Owner", "Sloane Owner")).to be(true)
      expect(EmployeeProfileIdentity.normalized_full_name_match?("Jordan", "Sample", "Sloane M. Owner")).to be(false)

      @acting_user = middle_initial_manager
      patch "/api/v1/client/employees/#{target_name_emp.id}", params: { employee: { pay_rate: 50.0 } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(target_name_emp.reload.pay_rate.to_f).to eq(22.0)
      expect(EmployeeChangeRequest.where(employee: target_name_emp, status: :pending, own_record: true)).to exist
      @acting_user = client_manager
    end

    it "flags possible_self_created_hire=true on name or email match in DB while hiding staff-only metadata from client responses (M2, M3)" do
      # Name match
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "Sloane",
          last_name: "Owner",
          employment_type: "hourly"
        }
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      name_item = EmployeeVerificationItem.order(:id).last
      expect(name_item.event_kind).to eq("new_hire")
      expect(name_item.metadata["possible_self_created_hire"]).to be(true)
      expect(name_item.metadata["own_record_actor_id"]).to eq(client_manager.id)

      # M2: client response MUST NOT include staff-only metadata keys
      client_meta = response.parsed_body.fetch("verification_items").first.fetch("metadata")
      expect(client_meta).not_to have_key("possible_self_created_hire")
      expect(client_meta).not_to have_key("own_record_actor_id")
      expect(client_meta).to have_key("readiness_status")
      expect(client_meta).to have_key("missing_keys")

      # Email-only match (different name, same normalized email as actor; M3)
      different_name_same_email = build(
        :employee,
        :hourly,
        company: company,
        first_name: "Completely",
        last_name: "Different",
        email: "SLOANE.OWNER@example.test"
      )
      expect(EmployeeProfileIdentity.normalized_full_name_match?("Completely", "Different", client_manager.name)).to be(false)
      expect(EmployeeProfileIdentity.possible_self_created_hire?(different_name_same_email, client_manager)).to be(true)

      # End-to-end POST /client/employees with email + confirm_same_person_email (and no name match by using an actor whose name differs while validator is stubbed to allow same-person email)
      email_only_manager = create(:user, company: company, organization: organization, role: "client", name: "Operations Lead", email: "ops.lead@example.test")
      CompanyAssignment.create!(user: email_only_manager, company: company)
      @acting_user = email_only_manager
      allow(EmployeeContactValidator).to receive(:call).and_return(
        EmployeeContactValidator::Result.new(
          errors: {},
          warnings: [],
          normalized_email: "ops.lead@example.test",
          normalized_phone: nil,
          same_person_confirmation_required: false,
          same_person_confirmed: false,
          confirmation_basis: nil,
          matched_login_user: nil,
          login_email_rejected: false,
          login_email_rejection_reason: nil,
          email_error_code: nil
        )
      )
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "Completely",
          last_name: "Different",
          email: "OPS.LEAD@example.test",
          employment_type: "hourly"
        }
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      email_item = EmployeeVerificationItem.order(:id).last
      expect(email_item.event_kind).to eq("new_hire")
      expect(email_item.metadata["possible_self_created_hire"]).to be(true)
      expect(email_item.metadata["own_record_actor_id"]).to eq(email_only_manager.id)
      expect(response.parsed_body.fetch("verification_items").first.fetch("metadata")).not_to have_key("possible_self_created_hire")
      @acting_user = client_manager
    end

    it "does not combine names from different historical snapshots and uses targeted SQL in sticky_own_record? (N7, snapshot integrity)" do
      # Taylor Rivera -> Morgan Rivera -> Morgan Chen must NOT match manager "Taylor Chen",
      # while manager "Taylor Rivera" still matches via the complete historical name snapshot.
      taylor_chen = create(:user, company: company, organization: organization, role: "client", name: "Taylor Chen", email: "taylor.chen@example.test")
      taylor_rivera = create(:user, company: company, organization: organization, role: "client", name: "Taylor Rivera", email: "taylor.rivera@example.test")
      CompanyAssignment.create!(user: taylor_chen, company: company)
      CompanyAssignment.create!(user: taylor_rivera, company: company)

      renamed_emp = create(:employee, :hourly, company: company, first_name: "Taylor", last_name: "Rivera", email: "worker.renamed@example.test", pay_rate: 20.0)

      # Step 1: change first_name only (Taylor -> Morgan)
      patch "/api/v1/client/employees/#{renamed_emp.id}", params: { employee: { first_name: "Morgan" } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      first_item = EmployeeVerificationItem.where(employee: renamed_emp, event_kind: "identity_tax_change").order(:id).last
      first_item.update!(status: "verified", verified_by: staff_manager, verified_at: Time.current)

      # Step 2: change last_name only (Rivera -> Chen)
      patch "/api/v1/client/employees/#{renamed_emp.id}", params: { employee: { last_name: "Chen" } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      renamed_emp.reload

      expect(EmployeeProfileIdentity.own_record_for_client_managed?(renamed_emp, taylor_chen)).to be(false)
      expect(EmployeeProfileIdentity.own_record_for_client_managed?(renamed_emp, taylor_rivera)).to be(true)

      # N7: sticky_own_record? uses targeted JSONB key predicates rather than loading unrelated verification items
      other_emp = create(:employee, :hourly, company: company, first_name: "Unrelated", last_name: "PayOnly", email: "unrelated.pay@example.test")
      3.times do |idx|
        EmployeeVerificationItem.create!(
          company: company,
          employee: other_emp,
          event_kind: "compensation_change",
          status: "verified",
          affects_pay: true,
          changed_fields: [ "pay_rate" ],
          before_values: { "pay_rate" => 20.0 + idx },
          after_values: { "pay_rate" => 21.0 + idx }
        )
      end

      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        sql = payload[:sql].to_s
        queries << sql if sql.include?("employee_verification_items")
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        expect(EmployeeProfileIdentity.sticky_own_record?(other_emp, client_manager)).to be(false)
      end
      expect(queries.any? { |sql| sql.include?("own_record_actor_id") }).to be(true)
      expect(queries.any? { |sql| sql.include?("identity_name_before") }).to be(true)
      expect(queries.none? { |sql| !sql.include?("own_record_actor_id") && !sql.include?("identity_name_before") && !sql.include?("before_values ? 'email'") }).to be(true)
    end

    it "returns 403 self_lifecycle_forbidden only for strong own-record signals (re-checked post-lock), allows name-only matches with flagged verification items, and returns 404 on cross-company and DELETE (N2)" do
      # Strong signal 1: linked active record
      linked_self = create(:employee, :hourly, company: company, first_name: "Linked", last_name: "Self", email: "linked.only@example.test")
      EmployeeAccountLink.create!(company: company, employee: linked_self, user: client_manager, status: "active", activated_at: 1.week.ago)

      # Strong signal 2: normalized email match
      email_self_terminated = create(:employee, :hourly, company: company, first_name: "Other", last_name: "Name", email: "SLOANE.OWNER@example.test", status: "terminated", termination_date: Date.new(2026, 10, 1))

      # Strong signal 3: sticky prior own-record (even after rename + re-email)
      sticky_self = create(:employee, :hourly, company: company, first_name: "Sloane", last_name: "Owner", email: "sloane.owner@example.test")
      EmployeeChangeRequest.create!(
        company: company,
        employee: sticky_self,
        requested_by: client_manager,
        request_kind: "update",
        own_record: true,
        status: :approved,
        proposed_changes: { "pay_rate" => 30.0 },
        original_values: { "pay_rate" => 25.0 }
      )
      sticky_self.update_columns(first_name: "Renamed", last_name: "Record", email: "new.inbox@example.test")

      foreign_employee = create(:employee, :hourly, company: other_company, first_name: "Foreign", last_name: "Worker")

      post "/api/v1/client/employees/#{linked_self.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")

      post "/api/v1/client/employees/#{sticky_self.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")

      post "/api/v1/client/employees/#{email_self_terminated.id}/rehire",
           params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")

      # Post-lock own-record recheck: if staff updates employee email to match acting client before @employee.lock!, terminate still returns 403
      race_emp = create(:employee, :hourly, company: company, first_name: "Race", last_name: "Target", email: "different.before.lock@example.test")
      mutated_email = false
      allow(Employee).to receive(:find_by).and_wrap_original do |method, *args, **kwargs|
        loaded = method.call(*args, **kwargs)
        if !mutated_email && loaded&.id == race_emp.id
          mutated_email = true
          Employee.where(id: race_emp.id).update_all(email: client_manager.email)
        end
        loaded
      end
      post "/api/v1/client/employees/#{race_emp.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")
      expect(race_emp.reload.status).to eq("active")
      allow(Employee).to receive(:find_by).and_call_original

      # N2: fuzzy name-only match ("Jose Cruz Camacho" terminating different employee "Jose Camacho") SUCCEEDS and flags verification item
      camacho_manager = create(:user, company: company, organization: organization, role: "client", name: "Jose Cruz Camacho", email: "jose.cruz.camacho@example.test")
      CompanyAssignment.create!(user: camacho_manager, company: company)
      jose_camacho = create(:employee, :hourly, company: company, first_name: "Jose", last_name: "Camacho", email: "jose.camacho.worker@example.test", hire_date: Date.new(2026, 1, 1))

      @acting_user = camacho_manager
      post "/api/v1/client/employees/#{jose_camacho.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(jose_camacho.reload.status).to eq("terminated")
      term_item = EmployeeVerificationItem.where(employee: jose_camacho, event_kind: "termination").last
      expect(term_item.metadata["possible_self_lifecycle_action"]).to be(true)
      expect(term_item.metadata["possible_self_actor_id"]).to eq(camacho_manager.id)
      expect(response.parsed_body.dig("verification_item", "metadata")).not_to have_key("possible_self_lifecycle_action")
      expect(response.parsed_body.dig("verification_item", "metadata")).not_to have_key("possible_self_actor_id")

      # Rehiring the same name-only match also succeeds and flags the rehire verification item
      post "/api/v1/client/employees/#{jose_camacho.id}/rehire",
           params: { effective_date: "2026-11-15" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(jose_camacho.reload.status).to eq("active")
      rehire_flag_item = EmployeeVerificationItem.where(employee: jose_camacho, event_kind: "rehire").last
      expect(rehire_flag_item.metadata["possible_self_lifecycle_action"]).to be(true)
      @acting_user = client_manager

      post "/api/v1/client/employees/#{foreign_employee.id}/terminate",
           params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/client/employees/#{foreign_employee.id}/rehire",
           params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:not_found)

      delete "/api/v1/client/employees/#{linked_self.id}", as: :json
      expect(response.status).to be_in([ 404, 405 ])

      # LinkCheckUnavailable fails closed with HTTP 503 on update, terminate, and rehire
      allow(EmployeeProfileIdentity).to receive(:own_record?).and_raise(EmployeeProfileIdentity::LinkCheckUnavailable, "Link check unavailable")
      patch "/api/v1/client/employees/#{linked_self.id}", params: { employee: { job_title: "Chef" } }, as: :json
      expect(response).to have_http_status(:service_unavailable)
      post "/api/v1/client/employees/#{linked_self.id}/terminate", params: { effective_date: "2026-11-10", reason_category: "voluntary" }, as: :json
      expect(response).to have_http_status(:service_unavailable)
      post "/api/v1/client/employees/#{email_self_terminated.id}/rehire", params: { effective_date: "2026-11-10" }, as: :json
      expect(response).to have_http_status(:service_unavailable)
    end

    it "never escalates a name-only match into a strong own-record signal after edits or self-created hires while keeping strong signals 403 (B1)" do
      camacho_manager = create(
        :user,
        company: company,
        organization: organization,
        role: "client",
        name: "Jose Cruz Camacho",
        email: "jose.cruz.camacho@example.test"
      )
      CompanyAssignment.create!(user: camacho_manager, company: company)
      @acting_user = camacho_manager

      # Case 1: Name-only match -> job-title edit (writes profile_change verification item) -> terminate returns 200 and flags staff-side
      edited_camacho = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Jose",
        last_name: "Camacho",
        email: "jose.camacho.edited@example.test",
        hire_date: Date.new(2026, 1, 1),
        job_title: "Line Cook",
        pay_rate: 20.0
      )
      patch "/api/v1/client/employees/#{edited_camacho.id}", params: {
        employee: { job_title: "Shift Lead" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      profile_item = EmployeeVerificationItem.where(employee: edited_camacho, event_kind: "profile_change").order(:id).last
      expect(profile_item).to be_present
      expect(profile_item.metadata["own_record_actor_id"]).to eq(camacho_manager.id)
      expect(profile_item.metadata["own_record_signal"]).to eq("name_only")

      post "/api/v1/client/employees/#{edited_camacho.id}/terminate", params: {
        effective_date: "2026-11-10",
        reason_category: "voluntary"
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(edited_camacho.reload.status).to eq("terminated")
      edited_term_item = EmployeeVerificationItem.where(employee: edited_camacho, event_kind: "termination").order(:id).last
      expect(edited_term_item.metadata["possible_self_lifecycle_action"]).to be(true)
      expect(edited_term_item.metadata["possible_self_actor_id"]).to eq(camacho_manager.id)
      expect(edited_term_item.metadata["own_record_signal"]).to eq("name_only")
      expect(response.parsed_body.dig("verification_item", "metadata")).not_to have_key("possible_self_lifecycle_action")
      expect(response.parsed_body.dig("verification_item", "metadata")).not_to have_key("own_record_signal")

      # Case 1b: Name-only match -> restricted pay edit (creates own-record EmployeeChangeRequest) -> terminate still returns 200 and flags staff-side
      pay_req_camacho = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Jose",
        last_name: "Camacho",
        email: "jose.camacho.payreq@example.test",
        hire_date: Date.new(2026, 1, 1),
        pay_rate: 20.0
      )
      patch "/api/v1/client/employees/#{pay_req_camacho.id}", params: {
        employee: { pay_rate: 24.0 }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      name_only_req = EmployeeChangeRequest.where(employee: pay_req_camacho).order(:id).last
      expect(name_only_req).to be_present
      expect(name_only_req.own_record).to be(true)
      expect(name_only_req.own_record_signal).to eq("name_only")

      post "/api/v1/client/employees/#{pay_req_camacho.id}/terminate", params: {
        effective_date: "2026-11-10",
        reason_category: "voluntary"
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(pay_req_camacho.reload.status).to eq("terminated")
      pay_req_term_item = EmployeeVerificationItem.where(employee: pay_req_camacho, event_kind: "termination").order(:id).last
      expect(pay_req_term_item.metadata["possible_self_lifecycle_action"]).to be(true)
      expect(pay_req_term_item.metadata["possible_self_actor_id"]).to eq(camacho_manager.id)
      expect(pay_req_term_item.metadata["own_record_signal"]).to eq("name_only")

      # Case 2: Name-only self-created hire -> terminate returns 200 and flags staff-side
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "Jose",
          last_name: "Camacho",
          email: "jose.camacho.newhire@example.test",
          hire_date: "2026-11-01",
          employment_type: "hourly"
        }
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      hired_camacho = Employee.find(response.parsed_body.dig("data", "id"))
      hire_item = EmployeeVerificationItem.where(employee: hired_camacho, event_kind: "new_hire").order(:id).last
      expect(hire_item.metadata["possible_self_created_hire"]).to be(true)
      expect(hire_item.metadata["own_record_actor_id"]).to eq(camacho_manager.id)
      expect(hire_item.metadata["own_record_signal"]).to eq("name_only")

      post "/api/v1/client/employees/#{hired_camacho.id}/terminate", params: {
        effective_date: "2026-11-10",
        reason_category: "voluntary"
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(hired_camacho.reload.status).to eq("terminated")
      hire_term_item = EmployeeVerificationItem.where(employee: hired_camacho, event_kind: "termination").order(:id).last
      expect(hire_term_item.metadata["possible_self_lifecycle_action"]).to be(true)
      expect(hire_term_item.metadata["possible_self_actor_id"]).to eq(camacho_manager.id)
      expect(hire_term_item.metadata["own_record_signal"]).to eq("name_only")
      expect(response.parsed_body.dig("verification_item", "metadata")).not_to have_key("possible_self_lifecycle_action")
      expect(response.parsed_body.dig("verification_item", "metadata")).not_to have_key("own_record_signal")

      # Case 3: Strong signals (email match, account link, and prior strong own-record after rename/re-email) still return 403
      strong_email_self = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Jose",
        last_name: "Camacho",
        email: "JOSE.CRUZ.CAMACHO@example.test",
        hire_date: Date.new(2026, 1, 1)
      )
      post "/api/v1/client/employees/#{strong_email_self.id}/terminate", params: {
        effective_date: "2026-11-10",
        reason_category: "voluntary"
      }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")

      # Prior strong own-record edit stays strong even after the employee is renamed and re-emailed
      patch "/api/v1/client/employees/#{strong_email_self.id}", params: {
        employee: { job_title: "General Manager", pay_rate: 45.0 }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      strong_profile_item = EmployeeVerificationItem.where(employee: strong_email_self, event_kind: "profile_change").order(:id).last
      expect(strong_profile_item.metadata["own_record_signal"]).to eq("strong")
      strong_req = EmployeeChangeRequest.where(employee: strong_email_self).order(:id).last
      expect(strong_req.own_record_signal).to eq("strong")

      strong_email_self.update_columns(first_name: "Completely", last_name: "Different", email: "unrelated.after.rename@example.test")
      post "/api/v1/client/employees/#{strong_email_self.id}/terminate", params: {
        effective_date: "2026-11-10",
        reason_category: "voluntary"
      }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("self_lifecycle_forbidden")
      expect(strong_email_self.reload.status).to eq("active")

      @acting_user = client_manager
    end

    it "creates a pending own-record change request when an email-only edit is confirmed by the requester's own login with no prior ownership evidence" do
      accented_manager = create(
        :user,
        company: company,
        organization: organization,
        role: "client",
        name: "Jose Garcia",
        email: "jose.garcia@example.test"
      )
      CompanyAssignment.create!(user: accented_manager, company: company)
      # Accented employee name passes EmployeeContactValidator#login_name_matches_employee?
      # while EmployeeProfileIdentity has no prior link, audit, email, or name match.
      accented_employee = create(
        :employee,
        :hourly,
        company: company,
        first_name: "José",
        last_name: "García",
        email: "old.garcia@example.test",
        pay_rate: 22.0
      )
      expect(EmployeeProfileIdentity.own_record_for_client_managed?(accented_employee, accented_manager)).to be(false)

      @acting_user = accented_manager
      expect do
        patch "/api/v1/client/employees/#{accented_employee.id}", params: {
          employee: { email: "jose.garcia@example.test" },
          confirm_same_person_email: true
        }, as: :json
      end.to change(EmployeeChangeRequest, :count).by(1)

      expect(response).to have_http_status(:ok), response.body
      expect(accented_employee.reload.email).to eq("old.garcia@example.test")

      req = EmployeeChangeRequest.where(employee: accented_employee, status: :pending).order(:id).last
      expect(req).to be_present
      expect(req.own_record).to be(true)
      expect(req.own_record_signal).to eq("strong")
      expect(req.proposed_changes).to eq("email" => "jose.garcia@example.test")
      expect(response.parsed_body.dig("change_request", "id")).to eq(req.id)

      audit = AuditLog.where(
        company_id: company.id,
        record_type: "employees",
        record_id: accented_employee.id,
        action: "employees#confirm_same_person_email"
      ).last
      expect(audit).to be_present
      expect(audit.metadata["confirmed_login_user_id"]).to eq(accented_manager.id)
      expect(audit.metadata["email"]).to eq("jose.garcia@example.test")
      @acting_user = client_manager
    end
  end

  describe "dual-role own-record routing with profile_requests disabled" do
    before do
      unlock_and_enable_client_managed!(profile_requests: false)
    end

    it "routes own-record non-address edits to Cornerstone staff without applying pay changes" do
      expect(CompanyFeatures.for(company).employee_portal_feature?(:profile_requests)).to be(false)

      own_emp = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Sloane",
        last_name: "Owner",
        email: "sloane.owner@example.test",
        pay_rate: 25.0
      )

      patch "/api/v1/client/employees/#{own_emp.id}", params: {
        employee: { pay_rate: 45.0 }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(own_emp.reload.pay_rate.to_f).to eq(25.0)
      req = EmployeeChangeRequest.where(employee: own_emp, status: :pending).last
      expect(req).to be_present
      expect(req.own_record).to be(true)
      expect(req.proposed_changes["pay_rate"]).to eq(45.0)
    end
  end

  describe "on-demand scheduled lifecycle activation HTTP 409 conflict (M5)" do
    it "returns 409 lifecycle_mode_changed without writing when a due scheduled profile activates on request, then succeeds on retry" do
      stub_const("OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES",
                 OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES.except("client_portal.employee_lifecycle_mode"))
      stub_const("OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS",
                 OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS - [ "client_portal.employee_lifecycle_mode" ])
      stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])

      PortalNotificationRecipient.create!(company: company, user: staff_manager, team_role: "lead", added_by: staff_manager)
      due_profile = ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
          client_portal_enabled: true,
          options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
          lifecycle_mode_activated_at: nil
        )
      )

      expect do
        post "/api/v1/client/employees", params: {
          employee: { first_name: "Reload", last_name: "Required", employment_type: "hourly" }
        }, as: :json
      end.not_to change(Employee, :count)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["code"]).to eq("lifecycle_mode_changed")
      expect(due_profile.reload.lifecycle_mode_activated_at).to be_present

      # Retry succeeds in client_managed mode
      expect do
        post "/api/v1/client/employees", params: {
          employee: { first_name: "Reload", last_name: "Required", employment_type: "hourly" }
        }, as: :json
      end.to change(Employee, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns 409 lifecycle_mode_changed if another request or job flips lifecycle mode between pre-check and company lock (N3)" do
      stub_const("OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES",
                 OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES.except("client_portal.employee_lifecycle_mode"))
      stub_const("OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS",
                 OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS - [ "client_portal.employee_lifecycle_mode" ])
      stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])

      due_profile = ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
          client_portal_enabled: true,
          options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
          lifecycle_mode_activated_at: nil
        )
      )

      # Simulate concurrent activation arriving right after ensure_attempted! returns nil (already handled elsewhere)
      allow(ClientOperatingProfiles::LifecycleModeActivationService).to receive(:ensure_attempted!).and_return(nil)
      allow(company).to receive(:lock!).and_wrap_original do |method, *args|
        due_profile.update_columns(lifecycle_mode_activated_at: Time.current)
        method.call(*args)
      end

      expect do
        post "/api/v1/client/employees", params: {
          employee: { first_name: "Concurrent", last_name: "Flip", employment_type: "hourly" }
        }, as: :json
      end.not_to change(Employee, :count)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["code"]).to eq("lifecycle_mode_changed")
      expect(response.parsed_body["employee_lifecycle_mode"]).to eq("client_managed")
    end
  end
end
