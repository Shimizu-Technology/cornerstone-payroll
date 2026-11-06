# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll calculation history holds", type: :request do
  let!(:tax_table) { create(:tax_table, tax_year: 2026, ss_wage_base: 184500) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company, retirement_rate: "0.05") }
  let(:healthy) { create(:employee, :salary, company: company) }
  let(:prior_period) do
    create(:pay_period, :committed, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-19")
  end
  let(:period) do
    create(:pay_period, company: company, start_date: "2026-02-01", end_date: "2026-02-14", pay_date: "2026-02-19")
  end
  let(:hold_message) { PayrollCalculationHistory.message(PayrollComponentMirrors::AmbiguousHistoryError.new) }

  before do
    [ Api::V1::Admin::PayPeriodsController, Api::V1::Admin::PayrollItemsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      allow_any_instance_of(controller).to receive(:current_user_id).and_return(actor.id)
    end
  end

  # Faithful retained main-code shape: loan + 5% retirement + employer health
  # field/deduction without mirror metadata, an old correction, and a physical
  # instrument void that keeps its earned wages. No inferred identity is added.
  def upgraded_history!
    loan_type = company.deduction_types.create!(name: "Named loan", category: "post_tax", sub_category: "loan")
    EmployeeLoan.create!(company: company, employee: employee, name: "Named loan", deduction_type: loan_type,
      tracking_mode: "balance_tracked", original_amount: 500, current_balance: 470, payment_amount: 30,
      status: "active", balance_as_of: "2026-01-01", balance_source: "new_loan")
    original = create(:payroll_item, company: company, employee: employee, pay_period: prior_period,
      hours_worked: 80, bonus: 100, gross_pay: 1300, retirement_payment: 65, loan_payment: 30, net_pay: 1105,
      social_security_tax: "80.60", employer_social_security_tax: "80.60",
      medicare_tax: "18.85", employer_medicare_tax: "18.85", tax_rule_snapshot: {})
    original.payroll_item_deductions.create!(deduction_type: loan_type, label: "Named loan", category: "post_tax", amount: 30)
    field = create(:payroll_field_definition, company: company, name: "Employer health",
      kind: "employer_contribution", tax_treatment: "employer_contribution", category: "benefit")
    original.payroll_item_field_entries.create!(payroll_field_definition: field, label: field.name,
      kind: field.kind, tax_treatment: field.tax_treatment, category: field.category, amount: 25, active: true, metadata: {})
    benefit_type = company.deduction_types.create!(name: field.name, category: "employer_contribution", sub_category: "benefit")
    original.payroll_item_deductions.create!(deduction_type: benefit_type, label: field.name, category: "employer_contribution", amount: 25)
    correction_period = create(:pay_period, :committed, company: company,
      start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-26")
    create(:payroll_item, company: company, employee: employee, pay_period: correction_period,
      correction_for_payroll_item_id: original.id, hours_worked: 5, gross_pay: 75, retirement_payment: "3.75", net_pay: 65,
      tax_rule_snapshot: {}, calculation_context_snapshot: { "corrective_paycheck" => { "original_payroll_item_id" => original.id } })
    original.update_columns(voided: true, voided_at: Time.current, void_reason: "Legacy physical instrument void", check_number: "99001")
    original
  end

  def calculate_run
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: {
      employee_ids: [ employee.id, healthy.id ], hours: { employee.id.to_s => { regular: 80 } }, bonuses: { employee.id.to_s => 100 }
    }, as: :json
  end

  %w[admin accountant].each do |role|
    it "holds only the affected employee and blocks approval/commit for #{role}" do
      actor.update!(role: role)
      original = upgraded_history!
      saved = [ original.attributes, original.payroll_item_field_entries.map(&:attributes), original.payroll_item_deductions.map(&:attributes) ]
      calculate_run
      expect(response).to have_http_status(:ok), response.body
      results = response.parsed_body.fetch("results")
      expect(results.fetch("errors")).to eq([ { "employee_id" => employee.id, "name" => employee.full_name, "error" => hold_message } ])
      expect(results.fetch("success").pluck("employee_id")).to eq([ healthy.id ])
      expect(period.reload).to be_draft
      expect(period.payroll_items.find_by!(employee: healthy).gross_pay).to be_positive
      expect(period.payroll_items.find_by(employee: employee)).to be_nil
      %w[approve commit].each do |action|
        post "/api/v1/admin/pay_periods/#{period.id}/#{action}"
        expect(response).to have_http_status(:unprocessable_entity), response.body
      end
      expect(period.reload).not_to be_committed
      expect([ original.reload.attributes, original.payroll_item_field_entries.reload.map(&:attributes), original.payroll_item_deductions.reload.map(&:attributes) ]).to eq(saved)
      expect { PayrollRetirementTotals.for_item(original) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
      expect { PayrollLiabilityPostingService.post!(pay_period: prior_period, actor: actor) }
        .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /mirror identity/)
    end
  end

  it "invalidates an earlier calculated run when the YTD preload discovers a hold" do
    upgraded_history!
    period.update!(status: "calculated", calculated_at: Time.current)
    create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 1000)
    calculate_run
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors").sole.fetch("error")).to eq(hold_message)
    expect(period.reload).to be_draft
    expect(period.calculated_at).to be_nil
  end

  [ PayrollInsuranceComponents::AmbiguousHistoryError, PayrollRetirementCatchUp::UnprovedHistoryError ].each do |error_class|
    it "isolates #{error_class} in a shared preload without caching partial totals" do
      original = create(:payroll_item, company: company, employee: employee, pay_period: prior_period)
      allow(PayrollRetirementTotals).to receive(:for_item).and_wrap_original do |method, item, **kwargs|
        raise error_class, "Unproved saved history" if item.id == original.id

        method.call(item, **kwargs)
      end
      calculate_run
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors").sole.fetch("error")).to eq(PayrollCalculationHistory.message(error_class.new))
      expect(response.parsed_body.dig("results", "success").pluck("employee_id")).to eq([ healthy.id ])
      expect(period.reload).to be_draft
    end
  end

  it "returns an actionable single-item recalculation hold and invalidates old approval eligibility" do
    upgraded_history!
    period.update!(status: "calculated", calculated_at: Time.current)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 1000)
    saved = item.attributes
    post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate"
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.fetch("errors")).to eq([ hold_message ])
    expect(item.reload.attributes).to eq(saved)
    expect(period.reload).to be_draft
    post "/api/v1/admin/pay_periods/#{period.id}/approve"
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "returns a per-employee hold from imported payroll calculation and keeps the run draft" do
    upgraded_history!
    period.update!(status: "calculated", calculated_at: Time.current)
    results = PayrollImport::ImportService.new(period).apply!(matched: [
      { employee_id: employee.id, regular_hours: 80, total_tips: 0, bonus: 100 },
      { employee_id: healthy.id, regular_hours: 0, total_tips: 0 }
    ])
    expect(results.fetch(:errors).sole).to include(employee_id: employee.id, error: hold_message)
    expect(results.fetch(:success).pluck(:employee_id)).to eq([ healthy.id ])
    expect(period.reload).to be_draft
    expect(period.payroll_items.find_by(employee: employee)).to be_nil
  end

  it "rolls back auto-calculated input edits but persists the discovered history hold" do
    upgraded_history!
    period.update!(status: "calculated", calculated_at: Time.current)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period, hours_worked: 80, gross_pay: 1000)
    patch "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}",
      params: { auto_calculate: true, payroll_item: { hours_worked: 85 } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.fetch("errors")).to eq([ hold_message ])
    expect(item.reload.hours_worked).to eq(80)
    expect(item.gross_pay).to eq(1000)
    expect(period.reload).to be_draft
  end

  PayrollCalculationHistory::ERRORS.each do |error_class|
    it "isolates #{error_class} raised inside calculation after a healthy preload" do
      employee.update!(retirement_rate: 0)
      allow_any_instance_of(Employee).to receive(:ytd_totals_before).and_wrap_original do |method, **kwargs|
        raise error_class, "Unproved history during calculation" if method.receiver.id == employee.id

        method.call(**kwargs)
      end
      calculate_run
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors").sole.fetch("error")).to eq(PayrollCalculationHistory.message(error_class.new))
      expect(response.parsed_body.dig("results", "success").pluck("employee_id")).to eq([ healthy.id ])
      expect(period.reload).to be_draft
    end
  end

  PayrollCalculationHistory::ERRORS.each do |error_class|
    it "returns a structured corrective-preview hold for #{error_class}" do
      allow_any_instance_of(IssueCorrectivePaycheckService).to receive(:validate_for_preview!).and_raise(error_class, "Review saved history with an administrator")
      post "/api/v1/admin/pay_periods/#{prior_period.id}/corrective_paycheck_preview",
        params: { employee_id: employee.id, corrected_inputs: { hours_worked: 85 } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(response.parsed_body.fetch("error")).to include("Review saved history")
      expect(prior_period.supplemental_pay_periods).to be_empty
    end
  end
end
