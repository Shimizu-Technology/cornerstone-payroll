# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayPeriods corrective paychecks", type: :request do
  let!(:tax_table) { create(:tax_table) }
  let!(:company) { Company.create!(name: "CorrCo", auto_create_fit_check: false) }
  let!(:department) { Department.create!(name: "Eng", company: company) }
  let!(:admin_user) do
    User.create!(company: company, email: "admin-corr@example.com",
                 name: "Admin", role: "admin", active: true)
  end
  let!(:employee) do
    Employee.create!(
      company: company, department: department,
      first_name: "Jane", last_name: "Doe", email: "jane@example.com",
      employment_type: "hourly", pay_rate: 15.00, pay_frequency: "biweekly",
      filing_status: "single", allowances: 0, status: "active",
      hire_date: Date.new(2024, 1, 1)
    )
  end
  let!(:original_period) do
    PayPeriod.create!(
      company: company,
      start_date: Date.new(2024, 1, 1),
      end_date:   Date.new(2024, 1, 14),
      pay_date:   Date.new(2024, 1, 19),
      status:     "committed",
      committed_at: Time.current
    )
  end
  let!(:original_item) do
    item = original_period.payroll_items.build(
      employee: employee, company_id: company.id,
      employment_type: "hourly", pay_rate: 15.00, hours_worked: 60
    )
    PayrollCalculator.for(employee, item).calculate
    item.save!
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024).add_payroll_item!(item)
    company.assign_check_numbers!([item])
    item.reload
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(admin_user.id)
  end

  describe "POST /api/v1/admin/pay_periods/:id/corrective_paycheck_preview" do
    it "returns deltas without persisting" do
      expect {
        post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paycheck_preview",
             params: { employee_id: employee.id, corrected_inputs: { hours_worked: 80 } },
             as: :json
      }.not_to change(PayPeriod, :count)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["original"]["gross_pay"]).to be_within(0.01).of(900.00)
      expect(json["corrected"]["gross_pay"]).to be_within(0.01).of(1200.00)
      expect(json["deltas"]["gross_pay"]).to be_within(0.01).of(300.00)
      expect(json["meta"]["will_generate_check"]).to eq(true)
    end

    it "404s when employee is not in this company" do
      other_company = Company.create!(name: "Other")
      other_dept = Department.create!(name: "X", company: other_company)
      other_emp = Employee.create!(
        company: other_company, department: other_dept,
        first_name: "X", last_name: "Y", email: "x@y.com",
        employment_type: "hourly", pay_rate: 10, pay_frequency: "biweekly",
        filing_status: "single", allowances: 0, status: "active",
        hire_date: Date.today
      )
      post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paycheck_preview",
           params: { employee_id: other_emp.id, corrected_inputs: { hours_worked: 80 } },
           as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "422s when service raises (e.g. employee not in original period)" do
      lone_emp = Employee.create!(
        company: company, department: department,
        first_name: "L", last_name: "Z", email: "l@z.com",
        employment_type: "hourly", pay_rate: 10, pay_frequency: "biweekly",
        filing_status: "single", allowances: 0, status: "active",
        hire_date: Date.today
      )
      post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paycheck_preview",
           params: { employee_id: lone_emp.id, corrected_inputs: { hours_worked: 80 } },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/corrective_paychecks" do
    it "creates and commits the supplemental period and returns the corrective item" do
      expect {
        post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paychecks",
             params: {
               employee_id:      employee.id,
               corrected_inputs: { hours_worked: 80 },
               pay_date:         "2024-01-26",
               reason:           "Wrong hours reported"
             },
             as: :json
      }.to change(PayPeriod, :count).by(1)
        .and change(PayrollItem, :count).by(1)

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["original_pay_period_id"]).to eq(original_period.id)
      expect(json["supplemental_pay_period"]["cycle"]).to eq("supplemental")
      expect(json["supplemental_pay_period"]["corrects_pay_period_id"]).to eq(original_period.id)
      expect(json["supplemental_pay_period"]["status"]).to eq("committed")
      expect(json["corrective_payroll_item"]["correction_reason"]).to eq("Wrong hours reported")
      expect(json["corrective_payroll_item"]["check_number"]).to be_present
    end

    it "422s on bad params" do
      post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paychecks",
           params: {
             employee_id:      employee.id,
             corrected_inputs: { hours_worked: 60 }, # no change
             pay_date:         "2024-01-26",
             reason:           "no-op"
           },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "422s when reason is missing" do
      post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paychecks",
           params: {
             employee_id:      employee.id,
             corrected_inputs: { hours_worked: 80 },
             pay_date:         "2024-01-26"
           },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Regression for the strong-params controller-layer fix (Greptile P2).
    # Until this commit the controller called `params[:corrected_inputs].to_unsafe_h`,
    # which forwarded *every* key the client sent into the service. The
    # service's own `.slice(*CORRECTABLE_INPUT_FIELDS)` still dropped
    # unknown keys before they reached AR — so this was safe in practice
    # — but the controller layer was no longer expressing the
    # permitted shape. Now we permit explicitly: arbitrary extra keys
    # (`voided`, `id`, `gross_pay`, `withholding_tax`, etc.) must be
    # dropped before the service ever sees them.
    it "drops keys outside CORRECTABLE_INPUT_FIELDS at the controller layer" do
      expect(IssueCorrectivePaycheckService).to receive(:issue!) do |**kwargs|
        # The controller helper is the layer being tested — assert that
        # it only forwards keys we explicitly permit, no matter what
        # the client sends.
        forwarded = kwargs[:corrected_inputs]
        expect(forwarded.keys.map(&:to_s)).to contain_exactly("hours_worked", "bonus")
        expect(forwarded).not_to have_key("voided")
        expect(forwarded).not_to have_key("id")
        expect(forwarded).not_to have_key("gross_pay")
        expect(forwarded).not_to have_key("withholding_tax")
        # Stub a successful return so the controller can render a 201.
        # The shape only needs to satisfy `pay_period_json` /
        # `payroll_item_summary_json` enough to render — easiest is to
        # reuse real records from the let! blocks.
        [original_period, original_period.payroll_items.first]
      end

      post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paychecks",
           params: {
             employee_id: employee.id,
             corrected_inputs: {
               hours_worked:    80,
               bonus:           50,
               voided:          true,        # not in allow-list — must be dropped
               id:              999_999,     # not in allow-list — must be dropped
               gross_pay:       9_999.99,    # service-computed — must be dropped
               withholding_tax: 1_234.56     # service-computed — must be dropped
             },
             pay_date: "2024-01-26",
             reason:   "Strong-params drop check"
           },
           as: :json
    end

    # Regression for the `audit_actions` registration (Greptile P2).
    # `:corrective_paychecks` was missing from the allow-list, so
    # admin actions on this endpoint were being made invisible to the
    # generic AuditLog stream that powers the compliance/admin
    # activity views. The new endpoint mutates payroll state (creates
    # a supplemental period + corrective item, mutates YTD), so it
    # belongs in the same stream as commit/void/run_payroll.
    it "writes a generic AuditLog row when issuing a corrective paycheck" do
      expect {
        post "/api/v1/admin/pay_periods/#{original_period.id}/corrective_paychecks",
             params: {
               employee_id:      employee.id,
               corrected_inputs: { hours_worked: 80 },
               pay_date:         "2024-01-26",
               reason:           "Audit-log regression"
             },
             as: :json
      }.to change { AuditLog.where(action: "pay_periods#corrective_paychecks").count }.by(1)

      expect(response).to have_http_status(:created)
      log = AuditLog.where(action: "pay_periods#corrective_paychecks").last
      expect(log.user_id).to eq(admin_user.id)
      expect(log.record_type).to eq("pay_periods")
      expect(log.record_id.to_s).to eq(original_period.id.to_s)
    end
  end

  describe "GET /api/v1/admin/pay_periods/:id/supplemental_pay_periods" do
    it "lists supplementals linked to the original period" do
      IssueCorrectivePaycheckService.issue!(
        original_pay_period: original_period,
        employee: employee,
        corrected_inputs: { hours_worked: 80 },
        pay_date: Date.new(2024, 1, 26),
        reason: "first",
        actor: admin_user
      )

      get "/api/v1/admin/pay_periods/#{original_period.id}/supplemental_pay_periods"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["supplemental_pay_periods"].length).to eq(1)
      sp = json["supplemental_pay_periods"].first
      expect(sp["cycle"]).to eq("supplemental")
      expect(sp["payroll_items"].length).to eq(1)
      expect(sp["payroll_items"].first["correction_reason"]).to eq("first")
      expect(sp["totals"]["gross_delta"]).to be_within(0.01).of(300.00)
    end

    it "422s when called on a supplemental itself" do
      _, _ = IssueCorrectivePaycheckService.issue!(
        original_pay_period: original_period,
        employee: employee,
        corrected_inputs: { hours_worked: 80 },
        pay_date: Date.new(2024, 1, 26),
        reason: "first",
        actor: admin_user
      )
      supplemental = PayPeriod.supplemental_cycle.first

      get "/api/v1/admin/pay_periods/#{supplemental.id}/supplemental_pay_periods"
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/admin/pay_periods/:id (show) on a regular period" do
    it "exposes the new correction-related fields in pay_period_json" do
      get "/api/v1/admin/pay_periods/#{original_period.id}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      pp = json["pay_period"]
      expect(pp["cycle"]).to eq("regular")
      expect(pp).to have_key("can_issue_corrective_paycheck")
      expect(pp["can_issue_corrective_paycheck"]).to eq(true)
      expect(pp["supplemental_pay_periods_count"]).to eq(0)
    end
  end
end
