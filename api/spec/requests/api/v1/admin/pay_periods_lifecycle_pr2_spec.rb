# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Lifecycle PR 2 Admin Pay-Run Request Gates", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Harborview Bistro") }
  let(:admin_user) { create(:user, company: company, organization: organization, role: "admin") }
  let(:org_admin) { create(:user, company: company, organization: organization, role: "org_admin") }

  before do
    ensure_verified_test_tax_years(2026)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_user_id).and_return(admin_user.id)
  end

  def create_ready_enforced_employee(first_name: "Jordan", last_name: "Sample")
    employee = create(
      :employee,
      :hourly,
      company: company,
      first_name: first_name,
      last_name: last_name,
      date_of_birth: Date.new(1994, 5, 14),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 20.00,
      pay_frequency: "biweekly",
      payment_delivery_method: "paper_check",
      readiness_gate_enforced: true
    )
    EmployeeW4Election.create!(
      EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
        company: company,
        employee: employee,
        effective_on: Date.new(2026, 1, 1),
        w4_signed_on: Date.new(2026, 1, 1),
        w4_form_version: 2020,
        source: "client_direct",
        reason: "Test W-4"
      )
    )
    employee
  end

  def create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Example", **overrides)
    create(
      :employee,
      :hourly,
      company: company,
      first_name: first_name,
      last_name: last_name,
      date_of_birth: Date.new(1995, 6, 20),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 18.00,
      pay_frequency: "biweekly",
      payment_delivery_method: nil,
      readiness_gate_enforced: true,
      **overrides
    )
  end

  describe "manual add, run_payroll, and timecard import entry-point guards" do
    it "returns 422 on manual add for Incomplete hires on regular runs and unrelated Incomplete hires on correction drafts" do
      incomplete = create_incomplete_enforced_employee
      regular_period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      post "/api/v1/admin/pay_periods/#{regular_period.id}/payroll_items",
        params: { employee_id: incomplete.id, payroll_item: { hours_worked: 40 } },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("employee_readiness_incomplete")
      expect(response.parsed_body["error"]).to include("W-4 missing")
      expect(regular_period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)

      # Also rejected on a system-generated correction draft when the employee is unrelated (no source paycheck link)
      source_worker = create_ready_enforced_employee
      source_period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 10, 1),
        end_date: Date.new(2026, 10, 14),
        pay_date: Date.new(2026, 10, 20),
        status: "draft"
      )
      source_item = source_period.payroll_items.create!(
        company: company,
        employee: source_worker,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      source_item.calculate!
      source_period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)
      PayPeriodLifecycleService.new(pay_period: source_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: source_period, actor: admin_user).commit!
      source_period.update_columns(correction_status: "voided", voided_at: Time.current, voided_by_id: org_admin.id, void_reason: "Void for redo")
      correction_run = PayPeriodCorrectionService.create_correction_run!(
        source_pay_period: source_period,
        actor: org_admin,
        reason: "Redo payroll"
      )

      post "/api/v1/admin/pay_periods/#{correction_run.id}/payroll_items",
        params: { employee_id: incomplete.id, payroll_item: { hours_worked: 8 } },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("employee_readiness_incomplete")
      expect(correction_run.payroll_items.exists?(employee_id: incomplete.id)).to be(false)
    end

    it "preserves main's 404 behavior on apply_timecard_import without pay_period_id (H2) and keeps its readiness guard harmless when pay_period_id is provided" do
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Example")
      ready = create_ready_enforced_employee(first_name: "Jordan", last_name: "Sample")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      # H2 regression: route supplies :id, not :pay_period_id, so calling without pay_period_id
      # in the body stays 404 just like main instead of reviving the unguarded endpoint.
      post "/api/v1/admin/pay_periods/#{period.id}/apply_timecard_import",
        params: {
          mappings: [
            { employee_id: ready.id, regular_hours: 40, overtime_hours: 0 }
          ]
        },
        as: :json

      expect(response).to have_http_status(:not_found)
      expect(period.payroll_items.count).to eq(0)

      # When pay_period_id is explicitly provided, the PR 2 readiness guard skips Incomplete hires safely.
      post "/api/v1/admin/pay_periods/#{period.id}/apply_timecard_import",
        params: {
          pay_period_id: period.id,
          mappings: [
            { employee_id: incomplete.id, regular_hours: 30, overtime_hours: 2 },
            { employee_id: ready.id, regular_hours: 40, overtime_hours: 0 }
          ]
        },
        as: :json

      expect(response).to have_http_status(:ok), response.body
      body = response.parsed_body
      expect(body["applied"].map { |row| row["employee_id"] }).to eq([ ready.id ])
      expect(body["skipped"].size).to eq(1)
      expect(body["skipped"].first).to include(
        "employee_id" => incomplete.id,
        "name" => "Morgan Example",
        "code" => "employee_readiness_incomplete"
      )
      expect(body["skipped"].first["reason"]).to include("W-4 missing")
      expect(body["skipped"].first["reason"]).to include("Hours were not imported")
      expect(period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)
    end

    it "rejects explicit Incomplete selection in run_payroll with exact missing-item reason" do
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Example")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: {
          employee_ids: [ incomplete.id ],
          hours: { incomplete.id.to_s => { regular: 40, overtime: 0 } }
        },
        as: :json

      expect(response).to have_http_status(:ok)
      errors = response.parsed_body.dig("results", "errors")
      expect(errors.size).to eq(1)
      expect(errors.first["employee_id"]).to eq(incomplete.id)
      expect(errors.first["error"]).to include("W-4 missing")
      expect(period.reload.status).to eq("draft")
      expect(period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)
    end
  end

  describe "GET /api/v1/admin/pay_periods/:id & POST commit safety net" do
    it "surfaces readiness_excluded_employees, stale_calculation_employees, and unverified_employee_changes and enforces HTTP 409 on commit conflict" do
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Example")
      ready = create_ready_enforced_employee(first_name: "Jordan", last_name: "Sample")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: ready,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      verification_item = EmployeeVerificationItem.create!(
        company: company,
        employee: ready,
        event_kind: "compensation_change",
        status: "pending_verification",
        affects_pay: true,
        effective_on: period.start_date,
        changed_fields: [ "pay_rate" ]
      )

      # Trigger staleness on ready employee to verify stale_calculation_employees payload
      EmployeeCompensationChangeService.new(
        employee: ready,
        pay_rate: 22.00,
        effective_on: period.start_date,
        actor: admin_user,
        source: "operator",
        reason: "Raise"
      ).call!

      get "/api/v1/admin/pay_periods/#{period.id}", as: :json
      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch("pay_period")
      expect(payload["readiness_excluded_employees"].map { |row| row["employee_id"] }).to eq([ incomplete.id ])
      expect(payload["readiness_excluded_employees"].first["reason"]).to include("W-4 missing")
      expect(payload["stale_calculation_employees"].map { |row| row["employee_id"] }).to eq([ ready.id ])
      expect(payload["unverified_employee_changes"].map { |row| row["id"] }).to eq([ verification_item.id ])

      # Recalculate and approve
      item.update!(pay_rate: 22.00)
      item.calculate!
      post "/api/v1/admin/pay_periods/#{period.id}/approve", as: :json
      expect(response).to have_http_status(:ok), response.body

      # Commit without acknowledgement -> HTTP 409 unverified_changes_changed
      post "/api/v1/admin/pay_periods/#{period.id}/commit", params: {}, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["code"]).to eq("unverified_changes_changed")

      # Commit with exact snapshot -> HTTP 200 & AuditLog metadata recorded
      post "/api/v1/admin/pay_periods/#{period.id}/commit",
        params: {
          acknowledged_verification_items: [
            { id: verification_item.id, updated_at: verification_item.updated_at.utc.iso8601(6) }
          ]
        },
        as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(period.reload.status).to eq("committed")
      expect(PayPeriodVerificationAcknowledgement.where(pay_period: period, employee_verification_item: verification_item)).to exist
      commit_log = AuditLog.where(company_id: company.id, action: "pay_periods#commit", record_id: period.id).order(:id).last
      expect(commit_log.metadata["acknowledged_verification_item_ids"]).to eq([ verification_item.id ])
    end
  end

  describe "approval_first controller regression (H1 & unchanged GET shape)" do
    it "preserves manually entered pay rates on correction runs in run_payroll and keeps GET response shape unchanged" do
      expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(false)

      legacy_employee = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Casey",
        last_name: "Legacy",
        pay_rate: 20.00,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: false
      )
      source_period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 10, 1),
        end_date: Date.new(2026, 10, 14),
        pay_date: Date.new(2026, 10, 20),
        status: "draft"
      )
      other_worker = create(:employee, :hourly, company: company, pay_rate: 25.00, readiness_gate_enforced: false)
      source_item = source_period.payroll_items.create!(
        company: company,
        employee: other_worker,
        employment_type: "hourly",
        pay_rate: 25.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      source_item.calculate!
      source_period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)
      PayPeriodLifecycleService.new(pay_period: source_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: source_period, actor: admin_user).commit!
      source_period.update_columns(correction_status: "voided", voided_at: Time.current, voided_by_id: org_admin.id, void_reason: "Void for redo")

      correction_run = PayPeriodCorrectionService.create_correction_run!(
        source_pay_period: source_period,
        actor: org_admin,
        reason: "Redo payroll"
      )
      # Unlinked correction row added by hand at a custom rate (17.50 while employee's live rate is 20.00)
      unlinked_item = correction_run.payroll_items.create!(
        company: company,
        employee: legacy_employee,
        employment_type: "hourly",
        pay_rate: 17.50,
        hours_worked: 10,
        payment_delivery_method: "paper_check"
      )

      post "/api/v1/admin/pay_periods/#{correction_run.id}/run_payroll",
        params: {
          employee_ids: [ legacy_employee.id ],
          hours: { legacy_employee.id.to_s => { regular: 10, overtime: 0 } }
        },
        as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors")).to eq([])
      expect(unlinked_item.reload.pay_rate.to_d).to eq(BigDecimal("17.50"))
      expect(unlinked_item.calculation_context_snapshot.to_h).not_to have_key("paycheck_input_fingerprint")

      get "/api/v1/admin/pay_periods/#{correction_run.id}", as: :json
      expect(response).to have_http_status(:ok), response.body
      payload = response.parsed_body.fetch("pay_period")
      expect(payload["id"]).to eq(correction_run.id)
      expect(payload["status"]).to eq("calculated")
      expect(payload["readiness_excluded_employees"]).to eq([])
      expect(payload["stale_calculation_employees"]).to eq([])
      expect(payload["unverified_employee_changes"]).to eq([])
      legacy_json = payload.fetch("payroll_items").find { |row| row["employee_id"] == legacy_employee.id }
      expect(BigDecimal(legacy_json["pay_rate"].to_s)).to eq(BigDecimal("17.50"))
    end
  end

  describe "off-cycle run purposes, timecards, excluded add-back, and M4/M6 staleness flows" do
    %w[off_cycle_tips bonus commission].each do |purpose|
      it "blocks Incomplete hires across manual add, run_payroll, and PayrollImport::ImportService on #{purpose} runs" do
        incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: purpose.camelize)
        period = create(
          :pay_period,
          company: company,
          start_date: Date.new(2026, 11, 1),
          end_date: Date.new(2026, 11, 14),
          pay_date: Date.new(2026, 11, 20),
          status: "draft",
          run_purpose: purpose,
          run_purpose_source: "operator_selected",
          includes_base_salary: false,
          includes_recurring_items: false
        )

        # Manual add
        post "/api/v1/admin/pay_periods/#{period.id}/payroll_items",
          params: { employee_id: incomplete.id, payroll_item: { bonus: 100 } },
          as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["code"]).to eq("employee_readiness_incomplete")

        # run_payroll
        post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
          params: {
            employee_ids: [ incomplete.id ],
            bonuses: { incomplete.id.to_s => 100 }
          },
          as: :json
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("results", "errors").first["error"]).to include("W-4 missing")
        expect(period.reload.status).to eq("draft")

        # Import service
        import_results = PayrollImport::ImportService.new(period, actor: admin_user).apply!(
          matched: [ { employee_id: incomplete.id, regular_hours: 0, overtime_hours: 0, total_tips: 50 } ]
        )
        expect(import_results[:success]).to be_empty
        expect(import_results[:skipped].first).to include(
          employee_id: incomplete.id,
          code: "employee_readiness_incomplete"
        )
        expect(period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)
      end
    end

    it "blocks Incomplete hires in TimecardsController#apply_to_payroll and PayPeriodExcludedEmployeesController#destroy" do
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Blocked")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      timecard = Timecard.create!(
        company: company,
        pay_period: period,
        employee_name: incomplete.full_name,
        ocr_status: "reviewed",
        reviewed_by_name: "Admin",
        reviewed_at: Time.current,
        period_start: period.start_date,
        period_end: period.end_date
      )
      PunchEntry.create!(
        timecard: timecard,
        card_day: 1,
        date: period.start_date,
        clock_in: "08:00",
        clock_out: "16:00",
        confidence: 0.95,
        review_state: "approved",
        reviewed_by_name: "Admin"
      )

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: period.id, employee_id: incomplete.id },
        as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("employee_readiness_incomplete")
      expect(response.parsed_body["error"]).to include("W-4 missing")
      expect(response.parsed_body["error"]).to include("Hours were not imported")
      expect(period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)

      PayPeriodExcludedEmployee.create!(
        pay_period: period,
        employee: incomplete,
        excluded_by: admin_user,
        reason: "Not ready yet"
      )
      delete "/api/v1/admin/pay_periods/#{period.id}/excluded_employees/#{incomplete.id}", as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("employee_readiness_incomplete")
      expect(response.parsed_body["error"]).to include("W-4 missing")
      expect(period.pay_period_excluded_employees.exists?(employee_id: incomplete.id)).to be(true)
    end

    it "runs payroll and approves cleanly for a Ready gated employee" do
      ready = create_ready_enforced_employee(first_name: "Jordan", last_name: "Ready")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: {
          employee_ids: [ ready.id ],
          hours: { ready.id.to_s => { regular: 40, overtime: 0 } }
        },
        as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors")).to eq([])
      expect(period.reload.status).to eq("calculated")
      item = period.payroll_items.find_by!(employee_id: ready.id)
      expect(item.calculation_context_snapshot["paycheck_input_fingerprint"]).to be_present

      post "/api/v1/admin/pay_periods/#{period.id}/approve", as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(period.reload.status).to eq("approved")
      expect(item.reload.payment_delivery_method).to eq("paper_check")
    end

    it "clears staleness via run_payroll but NOT via item.calculate! after manual pay_rate edit or TimecardsController#apply_to_payroll (M4)" do
      ready = create_ready_enforced_employee(first_name: "Jordan", last_name: "RateDrift")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: {
          employee_ids: [ ready.id ],
          hours: { ready.id.to_s => { regular: 40, overtime: 0 } }
        },
        as: :json
      expect(response).to have_http_status(:ok), response.body
      item = period.payroll_items.find_by!(employee_id: ready.id)

      # Case 1: Manual pay_rate edit + item.calculate! refreshes fingerprint on the old/edited rate -> STILL stale!
      item.update!(pay_rate: 17.50)
      item.calculate!
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve).map { |r| r[:employee_id] }).to eq([ ready.id ])

      post "/api/v1/admin/pay_periods/#{period.id}/approve", as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Recalculate payroll")

      # run_payroll re-syncs pay_rate from employee's dated rate and clears staleness
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: {
          employee_ids: [ ready.id ],
          hours: { ready.id.to_s => { regular: 40, overtime: 0 } }
        },
        as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.pay_rate.to_d).to eq(BigDecimal("20.00"))
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve)).to eq([])

      # Case 2 (M4): Employee gets a raise effective in this calculated period, then TimecardsController#apply_to_payroll
      # calls item.calculate! without re-syncing item.pay_rate -> stale check MUST still catch the old 20.00 rate!
      EmployeeCompensationChangeService.new(
        employee: ready,
        pay_rate: 25.00,
        effective_on: period.start_date,
        actor: admin_user,
        source: "operator",
        reason: "Raise effective for current period"
      ).call!

      timecard = Timecard.create!(
        company: company,
        pay_period: period,
        employee_name: ready.full_name,
        ocr_status: "reviewed",
        reviewed_by_name: "Admin",
        reviewed_at: Time.current,
        period_start: period.start_date,
        period_end: period.end_date
      )
      PunchEntry.create!(
        timecard: timecard,
        card_day: 1,
        date: period.start_date,
        clock_in: "08:00",
        clock_out: "16:00",
        confidence: 0.95,
        review_state: "approved",
        reviewed_by_name: "Admin"
      )

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: period.id, employee_id: ready.id },
        as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.pay_rate.to_d).to eq(BigDecimal("20.00"))
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve).map { |r| r[:employee_id] }).to eq([ ready.id ])

      post "/api/v1/admin/pay_periods/#{period.id}/approve", as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Recalculate payroll")

      # Full run_payroll re-syncs pay_rate to 25.00 and allows approval
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: { employee_ids: [ ready.id ] },
        as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.pay_rate.to_d).to eq(BigDecimal("25.00"))

      post "/api/v1/admin/pay_periods/#{period.id}/approve", as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(period.reload.status).to eq("approved")
    end
  end
end
