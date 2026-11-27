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

    it "skips Incomplete hires with exact reason in TimecardImportsController#apply without dropping Ready employees" do
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

      post "/api/v1/admin/pay_periods/#{period.id}/apply_timecard_import",
        params: {
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
end
